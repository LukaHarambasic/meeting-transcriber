@testable import MeetingTranscriber
import XCTest

/// Manual-recording ownership rules for `WatchingController`, in their own file
/// because `WatchingControllerTests` sits at the 600-line cap.
@MainActor
final class WatchingControllerManualRecordingTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "WatchingControllerManualRecordingTests")
    }

    override func tearDown() async throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        try await super.tearDown()
    }

    /// The "No Microphone (app audio only)" setting has to be enforced here,
    /// not only by the menu item's `.disabled`. A disabled control is an
    /// explanation, never an enforcement: the automation API reaches this same
    /// method, and without the guard it would record the one thing that setting
    /// exists to keep off tape.
    func testMicrophoneRecordingIsRefusedWhenTheUserTurnedTheMicrophoneOff() async {
        let controller = makeWatchingController(logDir: tmpDir, noMic: true)

        controller.startMicrophoneRecording()

        // A start that was not refused builds its loop within a few main-actor
        // hops; nothing to await here, so give it those hops before asserting.
        for _ in 0 ..< 20 {
            await Task.yield()
        }

        XCTAssertNil(controller.watchLoop, "no recording may begin while the microphone is switched off")
        XCTAssertFalse(controller.isManualRecording)
    }

    func testMicrophoneRecordingStartsWhenTheMicrophoneIsAllowed() async {
        // Control for the refusal above: without it a method that never starts
        // anything would pass just as well.
        // Seeded health: without it the loop runs a live TCC probe whose answer
        // depends on the runner, and this test asserts a start *succeeds*.
        let controller = makeWatchingController(
            logDir: tmpDir, noMic: false, permissionHealth: .allHealthy,
        )
        addTeardownBlock { await controller.stopManualRecording() }

        controller.startMicrophoneRecording()
        for _ in 0 ..< 20 {
            await Task.yield()
        }

        XCTAssertTrue(controller.isManualRecording)
    }

    // MARK: - What the user is told

    /// A start reports itself. These two live here rather than at the
    /// `AppState` level, where they used to accept either outcome because the
    /// production recorder decided it by whether the machine had a usable input
    /// device: this is the level that owns the recorder seam, so each outcome
    /// can be asked for and asserted on its own.
    func testAStartedRecordingIsReportedToTheUser() async {
        let notifier = RecordingNotifier()
        let controller = makeWatchingController(
            logDir: tmpDir, notifier: notifier, permissionHealth: .allHealthy,
        )
        addTeardownBlock { await controller.stopManualRecording() }

        controller.startManualRecording(pid: 1234, appName: "Chrome", title: "Standup")
        // Wait for the report, not for `isManualRecording`: the loop sets that
        // inside the start, one statement before the notification, so waiting
        // on it can win the race and read an empty list.
        await waitFor(!notifier.calls.isEmpty, timeout: .seconds(2))

        XCTAssertEqual(notifier.calls.first?.title, "Manual Recording")
        XCTAssertTrue(controller.isManualRecording)
    }

    /// The other outcome, and the one that matters more: capture that cannot
    /// open has to be reported. A silent failure is indistinguishable from a
    /// recording in progress, so the user finds out when the protocol never
    /// arrives.
    func testACaptureThatCannotOpenIsReportedToTheUser() async {
        let notifier = RecordingNotifier()
        let controller = makeWatchingController(
            // Explicit label and all arguments on one line: `make` takes several
            // function-type parameters, so binding by position is the trap the
            // RPC integration tests warn about — and splitting the last argument
            // onto its own line is what lets the formatter turn it back into the
            // trailing closure this comment exists to prevent.
            // swiftlint:disable:next trailing_closure
            logDir: tmpDir, notifier: notifier, permissionHealth: .allHealthy, makeRecorder: { ThrowingRecorder() },
        )
        addTeardownBlock { await controller.stopManualRecording() }

        controller.startManualRecording(pid: 1234, appName: "Chrome", title: "Standup")
        await waitFor(!notifier.calls.isEmpty, timeout: .seconds(2))

        XCTAssertEqual(notifier.calls.first?.title, "Error")
        XCTAssertFalse(controller.isManualRecording, "a start that failed is not a recording")
    }

    /// Issue #624: a second manual start while one is already recording used to
    /// overwrite `watchLoop` without stopping the live loop, so its audio was
    /// never enqueued while its recorder kept capturing, retained by its own
    /// monitor task and unreachable. The refusal is what prevents the loss; the
    /// picker is only what explains it.
    func testSecondManualStartIsRefusedWhileOneIsRecording() async throws {
        let micGate = AsyncGate()
        // swiftlint:disable:next trailing_closure
        let controller = makeWatchingController(logDir: tmpDir, ensureMicAccess: {
            await micGate.wait()
            return true
        })
        let (loop, _) = makeTestWatchLoop()
        controller.watchLoop = loop
        try await loop.startManualRecording(pid: 99, appName: "Chrome", title: "Meeting")
        addTeardownBlock {
            await micGate.open()
            await loop.stop()
        }

        controller.startManualRecording(pid: 1234, appName: "Safari", title: "Second")

        // Proving a negative needs a window: a start that was *not* refused
        // reaches the injected mic gate within a few main-actor hops and parks
        // there.
        await waitFor({ await micGate.hasWaiter }, timeout: .milliseconds(300))
        let reachedTheMicGate = await micGate.hasWaiter

        XCTAssertFalse(reachedTheMicGate, "a second manual start must not run while one is recording")
        XCTAssertIdentical(controller.watchLoop, loop, "the live recording's loop must still be the owner")

        // Control case, in the same test and on the same machine: without it,
        // "never reached the gate" is also what a merely slow main actor looks
        // like, and the assertion above would hold against a broken guard. The
        // loop stops itself the way `monitorManualRecording` does when the pid
        // exits, which clears `manualRecordingInfo` but leaves the controller's
        // reference in place, so this also pins that the refusal keys on
        // `isManualRecording` and not on `watchLoop != nil`.
        loop.stopManualRecording()
        XCTAssertFalse(loop.isManualRecording, "precondition for the control case")

        controller.startManualRecording(pid: 1234, appName: "Safari", title: "Third")
        await waitFor { await micGate.hasWaiter }

        let allowedAfterTheRecordingEnded = await micGate.hasWaiter
        XCTAssertTrue(
            allowedAfterTheRecordingEnded,
            "a start must be allowed once the recording ended, even though the controller still holds that loop",
        )
    }
}
