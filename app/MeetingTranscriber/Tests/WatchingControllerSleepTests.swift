@testable import MeetingTranscriber
import XCTest

/// The sleep half of the recording-durability fix: what happens when the Mac
/// sleeps anyway (a closed lid, Apple menu → Sleep, a flat battery), which no
/// power assertion can prevent, and what happens on the way back.
@MainActor
final class WatchingControllerSleepTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "WatchingControllerSleepTests")
    }

    override func tearDown() async throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        try await super.tearDown()
    }

    /// Named rather than written as a `{ 0 }` literal at the call site:
    /// SwiftLint's `trailing_closure` rule rejects a closure literal in the
    /// final argument position.
    private static let nothingToRecover: () -> Int = { 0 }

    /// Give a just-launched start its few main-actor hops. Mirrors the wait in
    /// `WatchingControllerManualRecordingTests` — the start is a `Task`, so
    /// there is nothing to await from here.
    private func settle() async {
        for _ in 0 ..< 20 {
            await Task.yield()
        }
    }

    // MARK: - Going to sleep

    /// The recording is finalized rather than left running into the sleep. A
    /// recording left running comes back as a half-written file with no clean
    /// end, which is what the user saw: "it stops recording and nothing
    /// happens".
    func testSleepFinalizesAndSavesTheActiveRecording() async {
        let notifier = RecordingNotifier()
        let controller = makeWatchingController(
            logDir: tmpDir, notifier: notifier, permissionHealth: .allHealthy,
        )
        controller.beginManualRecording(.meeting)
        await settle()
        XCTAssertTrue(controller.isManualRecording, "precondition: something is recording")

        controller.finalizeForSleep()

        XCTAssertFalse(controller.isManualRecording, "the recording must be finalized, not abandoned")
        XCTAssertNil(controller.watchLoop)
        XCTAssertTrue(
            notifier.calls.contains { $0.title == "Recording Saved" },
            "the user has to learn the recording ended and that the audio survived",
        )
    }

    /// The common case now that the power assertion blocks idle sleep: the Mac
    /// sleeps with nothing recording, and the handler must be silent rather than
    /// announce a recording that never existed.
    func testSleepWithNothingRecordingIsSilent() {
        let notifier = RecordingNotifier()
        let controller = makeWatchingController(
            logDir: tmpDir, notifier: notifier, permissionHealth: .allHealthy,
        )

        controller.finalizeForSleep()

        XCTAssertTrue(notifier.calls.isEmpty)
        XCTAssertNil(controller.watchLoop)
    }

    // MARK: - Waking up

    /// Sleeps that give no notice (kernel panic, flat battery, observers cut
    /// short mid-mix) leave tracks with no mix. That was already recoverable —
    /// but only at launch, which for a menu-bar app that never quits could be
    /// weeks away.
    func testWakeRecoversAnInterruptedRecording() {
        let notifier = RecordingNotifier()
        let recoverCalls = ManagedCounter()
        let recover: () -> Int = {
            _ = recoverCalls.increment()
            return 1
        }
        let controller = makeWatchingController(
            logDir: tmpDir, notifier: notifier, permissionHealth: .allHealthy,
            recoverInterrupted: recover,
        )

        controller.recoverAfterWake()

        XCTAssertEqual(recoverCalls.value, 1)
        XCTAssertTrue(
            notifier.calls.contains { $0.title == "Recording Recovered" },
            "a recovered recording appearing in the queue unannounced is a surprise, not a feature",
        )
    }

    func testWakeWithNothingToRecoverIsSilent() {
        let notifier = RecordingNotifier()
        let controller = makeWatchingController(
            logDir: tmpDir, notifier: notifier, permissionHealth: .allHealthy,
            recoverInterrupted: Self.nothingToRecover,
        )

        controller.recoverAfterWake()

        XCTAssertTrue(notifier.calls.isEmpty, "nothing recovered, nothing to say")
    }

    /// The load-bearing guard. The wake scan runs with `minAge: 0`, so with a
    /// recording still live it would re-mix tracks that are still being written
    /// to — corrupting the recording it exists to protect. Reachable in practice
    /// whenever the assertion did its job and the display merely slept.
    func testWakeDoesNotTouchALiveRecording() async {
        let recoverCalls = ManagedCounter()
        let recover: () -> Int = {
            _ = recoverCalls.increment()
            return 1
        }
        let controller = makeWatchingController(
            logDir: tmpDir, permissionHealth: .allHealthy,
            recoverInterrupted: recover,
        )
        controller.beginManualRecording(.meeting)
        await settle()
        XCTAssertTrue(controller.isManualRecording, "precondition: something is recording")
        addTeardownBlock { await controller.stopManualRecording() }

        controller.recoverAfterWake()

        XCTAssertEqual(
            recoverCalls.value, 0,
            "re-mixing the tracks of a running recording would corrupt it",
        )
    }
}
