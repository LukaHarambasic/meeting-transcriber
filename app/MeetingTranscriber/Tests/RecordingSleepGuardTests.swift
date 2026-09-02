@testable import MeetingTranscriber
import XCTest

/// Pins that a recording takes the "don't idle-sleep" power assertion and gives
/// it back, and that a failed stop still saves the audio.
///
/// These drive `WatchLoop` rather than `RecordingPowerAssertion`, deliberately.
/// The assertion type is four IOKit calls whose effect a test cannot observe;
/// what can break, and what actually broke here, is the *wiring* — whether the
/// start path takes it and whether every stop path gives it back.
@MainActor
final class RecordingSleepGuardTests: XCTestCase {
    /// A recorder whose `stop()` succeeds (MockRecorder throws
    /// `RecorderError.noAudioData` when `mixPath` is nil).
    private func workingRecorder() -> MockRecorder {
        let recorder = MockRecorder()
        recorder.mixPath = URL(fileURLWithPath: "/tmp/sleep_guard_mix.wav")
        return recorder
    }

    /// `pollInterval` is parked at an hour: these tests drive the stop paths
    /// directly, and a live monitor would race them.
    /// Named rather than written as a default `{ 0 }` literal: SwiftLint's
    /// `trailing_closure` rule rejects a closure literal in the final argument
    /// position at every call site.
    private static let noSalvage: () -> Int = { 0 }

    private func makeLoop(
        recorder: MockRecorder,
        blocker: SpySleepBlocker,
        notifier: any AppNotifying = SilentNotifier(),
        salvage: @escaping () -> Int = RecordingSleepGuardTests.noSalvage,
    ) -> WatchLoop {
        let loop = WatchLoop(
            recorderFactory: { recorder },
            pollInterval: 3600,
            notifier: notifier,
            pidAliveCheck: { _ in true },
            sleepBlocker: blocker,
            salvageInterrupted: salvage,
        )
        loop.permissionChecker = {
            HealthCheckResult(screenRecording: .healthy, microphone: .healthy)
        }
        return loop
    }

    // MARK: - Holding the assertion

    func testRecordingHoldsTheAssertion() async throws {
        let blocker = SpySleepBlocker()
        let loop = makeLoop(recorder: workingRecorder(), blocker: blocker)

        try await loop.startMeetingRecording()
        defer { loop.stop() }

        XCTAssertTrue(blocker.isHeld, "a running recording must keep the Mac awake")
        XCTAssertEqual(blocker.holdCount, 1)
        XCTAssertEqual(blocker.releaseCount, 0)
        XCTAssertFalse(
            blocker.lastReason?.isEmpty ?? true,
            "the reason is what shows up in `pmset -g assertions`",
        )
    }

    func testStoppingReleasesTheAssertion() async throws {
        let blocker = SpySleepBlocker()
        let loop = makeLoop(recorder: workingRecorder(), blocker: blocker)

        try await loop.startMeetingRecording()
        loop.stopManualRecording()

        XCTAssertFalse(blocker.isHeld, "an idle app must not keep the Mac awake")
        XCTAssertEqual(blocker.releaseCount, 1)
    }

    /// The shutdown path (app quit) drops the recorder without finalizing it and
    /// must still give the assertion back — otherwise quitting mid-recording
    /// leaves the Mac unable to idle-sleep for the rest of the boot.
    func testShutdownReleasesTheAssertion() async throws {
        let blocker = SpySleepBlocker()
        let loop = makeLoop(recorder: workingRecorder(), blocker: blocker)

        try await loop.startMeetingRecording()
        loop.stop()

        XCTAssertFalse(blocker.isHeld)
        XCTAssertEqual(blocker.releaseCount, 1)
    }

    /// A start that never opened capture must not leave an assertion behind:
    /// nothing would ever release it, because no recording owns it.
    func testRefusedStartTakesNoAssertion() async {
        let blocker = SpySleepBlocker()
        let loop = makeLoop(recorder: workingRecorder(), blocker: blocker)
        loop.permissionChecker = {
            HealthCheckResult(screenRecording: .denied, microphone: .healthy)
        }

        do {
            try await loop.startMeetingRecording()
            XCTFail("a denied Screen Recording grant must refuse a system-tap recording")
        } catch {
            XCTAssertEqual(blocker.holdCount, 0, "no recording, no assertion")
            XCTAssertFalse(blocker.isHeld)
        }
    }

    // MARK: - Salvage on a failed stop

    /// "If an error occurs, save the rest": a `stop()` that throws leaves the
    /// per-track WAVs and the in-progress marker on disk, and the stop path has
    /// to re-mix them now rather than leaving them until the app next launches —
    /// which, for a menu-bar app that never quits, could be weeks.
    func testFailedStopSalvagesTheAudio() async throws {
        let blocker = SpySleepBlocker()
        let notifier = RecordingNotifier()
        let salvageCalls = ManagedCounter()
        let salvage: () -> Int = {
            _ = salvageCalls.increment()
            return 1
        }
        let loop = makeLoop(
            recorder: MockRecorder(), // no mixPath → stop() throws
            blocker: blocker,
            notifier: notifier,
            salvage: salvage,
        )

        try await loop.startMeetingRecording()
        loop.stopManualRecording()

        XCTAssertEqual(salvageCalls.value, 1, "a failed stop must attempt recovery immediately")
        XCTAssertTrue(
            notifier.calls.contains { $0.title == "Recording Salvaged" },
            "the user has to be told the audio survived; the failure alone reads as a loss",
        )
        XCTAssertNotNil(loop.snapshot.lastError, "the failure itself is still reported")
        XCTAssertFalse(blocker.isHeld, "a failed stop still releases the assertion")
    }

    /// Nothing recoverable means no reassuring notification. Claiming a salvage
    /// that did not happen is worse than saying nothing at all.
    func testFailedStopWithNothingToSalvageStaysQuiet() async throws {
        let notifier = RecordingNotifier()
        let loop = makeLoop(
            recorder: MockRecorder(),
            blocker: SpySleepBlocker(),
            notifier: notifier,
            salvage: Self.noSalvage,
        )

        try await loop.startMeetingRecording()
        loop.stopManualRecording()

        XCTAssertFalse(notifier.calls.contains { $0.title == "Recording Salvaged" })
        XCTAssertNotNil(loop.snapshot.lastError)
    }

    /// A successful stop must not run the recovery scan — it would re-read the
    /// staging directory on every ordinary stop for nothing.
    func testSuccessfulStopDoesNotSalvage() async throws {
        let salvageCalls = ManagedCounter()
        let salvage: () -> Int = {
            _ = salvageCalls.increment()
            return 0
        }
        let loop = makeLoop(
            recorder: workingRecorder(),
            blocker: SpySleepBlocker(),
            salvage: salvage,
        )

        try await loop.startMeetingRecording()
        loop.stopManualRecording()

        XCTAssertEqual(salvageCalls.value, 0)
    }

    // MARK: - Clearing a stale failure

    /// A new recording supersedes the last one's failure. Without this the
    /// menu's issue row keeps naming an error the user has visibly moved past,
    /// and the icon keeps its red dot through a healthy recording.
    func testStartingClearsThePreviousFailure() async throws {
        let loop = makeLoop(recorder: MockRecorder(), blocker: SpySleepBlocker())

        try await loop.startMeetingRecording()
        loop.stopManualRecording()
        XCTAssertNotNil(loop.snapshot.lastError)

        try await loop.startMeetingRecording()
        defer { loop.stop() }
        XCTAssertNil(loop.snapshot.lastError, "a started recording clears the stale failure")
    }
}
