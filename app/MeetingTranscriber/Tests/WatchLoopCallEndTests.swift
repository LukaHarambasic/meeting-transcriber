@testable import MeetingTranscriber
import XCTest

/// Drives the call-end rule through the live `monitorManualRecording` poll loop
/// with a `TestClock`, so what is asserted is the wiring `CallEndPolicyTests`
/// cannot reach: that the monitor consults the rule at all, that the setting is
/// read on every poll, that a stop also enqueues, and that the production
/// controller hands its loop the probe and the setting.
///
/// The probe is scripted as a function of virtual seconds since the recording
/// began, so "the call lasts two seconds, then every other app lets go" is
/// stated as such rather than as a sequence of poll counts.
@MainActor
final class WatchLoopCallEndTests: XCTestCase {
    private let poll: TimeInterval = 0.1
    /// Short virtual thresholds: the clock is fake, but a small multiple of the
    /// poll keeps the number of yields low.
    private let policy = CallEndPolicy(minimumCallDuration: 0.3, releaseGrace: 0.3)

    /// How long past the moment a stop would be due the "stays recording" tests
    /// keep the loop running before asserting. Several grace periods.
    private let observeFor: TimeInterval = 3

    // The scripts the probe follows, as functions of seconds since the start.
    // Named functions rather than closure literals at the call sites, for the
    // same trailing-closure reason as `usage` below.

    /// A call that lasts a second, after which every other app lets go.
    private static func callForOneSecond(_ elapsed: TimeInterval) -> MicUsage {
        elapsed < 1.0 ? .held : .free
    }

    private static func alwaysHeld(_: TimeInterval) -> MicUsage {
        .held
    }

    private static func alwaysFree(_: TimeInterval) -> MicUsage {
        .free
    }

    /// A call that lasts a second, after which the probe stops being able to tell.
    private static func callThenUnknown(_ elapsed: TimeInterval) -> MicUsage {
        elapsed < 1.0 ? .held : .unknown
    }

    private func makeLoop(
        clock: TestClock,
        notifier: any AppNotifying = SilentNotifier(),
        enabled: @escaping () -> Bool = { true },
        mic: @escaping (TimeInterval) -> MicUsage,
    ) -> (loop: WatchLoop, recorder: MockRecorder, started: Date) {
        let recorder = MockRecorder()
        recorder.mixPath = URL(fileURLWithPath: "/tmp/call_end_mix.wav")
        let started = clock.now
        // Named, not a closure literal at the call: the last argument of an
        // initializer call as a literal is a trailing-closure violation.
        let usage: () -> MicUsage = { mic(clock.now.timeIntervalSince(started)) }
        let loop = WatchLoop(
            recorderFactory: { recorder },
            pollInterval: poll,
            notifier: notifier,
            nowProvider: { clock.now },
            sleepProvider: { await clock.sleep(for: $0) },
            pidAliveCheck: { _ in true }, // never exits, so only the call-end rule can stop it
            sleepBlocker: SpySleepBlocker(),
            salvageInterrupted: { 0 },
            autoStopWhenCallEnds: enabled,
            callEndPolicy: policy,
            micUsage: usage,
        )
        loop.permissionChecker = { _ in
            HealthCheckResult(screenRecording: .healthy, microphone: .healthy)
        }
        return (loop, recorder, started)
    }

    /// Lets virtual time run `seconds` past the recording's start, failing
    /// loudly if it never gets there so a stalled loop cannot pass as "stayed
    /// recording".
    private func runVirtualTime(_ clock: TestClock, since started: Date, seconds: TimeInterval) async {
        await waitFor(clock.now.timeIntervalSince(started) > seconds, timeout: .seconds(5))
        XCTAssertGreaterThan(clock.now.timeIntervalSince(started), seconds, "the monitor loop stopped polling")
    }

    // MARK: - The stop

    func testStopsAndSavesWhenEveryOtherAppReleasesTheMicrophone() async throws {
        let clock = TestClock()
        let notifier = RecordingNotifier()
        let (loop, recorder, _) = makeLoop(clock: clock, notifier: notifier, mic: Self.callForOneSecond)

        try await loop.startMeetingRecording()
        defer { loop.stop() }

        await waitFor(loop.snapshot.phase == .idle, timeout: .seconds(5))
        XCTAssertEqual(loop.snapshot.phase, .idle, "the call ended and the recording kept going")
        XCTAssertTrue(recorder.stopCalled, "the stop must go through the normal save path")
        let told = notifier.calls.first { $0.title == "Recording Stopped" }
        XCTAssertEqual(told?.body, "The call ended, so the recording was stopped and saved.")
    }

    func testDoesNotStopWhileAnotherAppStillHoldsTheMicrophone() async throws {
        let clock = TestClock()
        let (loop, recorder, started) = makeLoop(clock: clock, mic: Self.alwaysHeld)

        try await loop.startMeetingRecording()
        defer { loop.stop() }

        await runVirtualTime(clock, since: started, seconds: observeFor)
        XCTAssertEqual(loop.state, .recording)
        XCTAssertFalse(recorder.stopCalled)
    }

    func testNeverSeenCallDoesNotStop() async throws {
        let clock = TestClock()
        let (loop, recorder, started) = makeLoop(clock: clock, mic: Self.alwaysFree)

        try await loop.startMeetingRecording()
        defer { loop.stop() }

        await runVirtualTime(clock, since: started, seconds: observeFor)
        XCTAssertEqual(loop.state, .recording, "an in-person meeting has no call to end")
        XCTAssertFalse(recorder.stopCalled)
    }

    /// A probe that cannot tell must never end a recording, whatever came
    /// before it. This is also what every loop built without the argument gets.
    func testUnknownProbeNeverStopsAfterACall() async throws {
        let clock = TestClock()
        let (loop, recorder, started) = makeLoop(clock: clock, mic: Self.callThenUnknown)

        try await loop.startMeetingRecording()
        defer { loop.stop() }

        await runVirtualTime(clock, since: started, seconds: observeFor)
        XCTAssertEqual(loop.state, .recording)
        XCTAssertFalse(recorder.stopCalled)
    }

    // MARK: - The setting

    /// Control for the next two: the same script as the stop test, with the
    /// setting off. Without it the stop test could be passing for a reason that
    /// has nothing to do with the setting.
    func testSwitchedOffNeverStops() async throws {
        let clock = TestClock()
        let (loop, recorder, started) = makeLoop(clock: clock, enabled: { false }, mic: Self.callForOneSecond)

        try await loop.startMeetingRecording()
        defer { loop.stop() }

        await runVirtualTime(clock, since: started, seconds: observeFor)
        XCTAssertEqual(loop.state, .recording)
        XCTAssertFalse(recorder.stopCalled)
    }

    /// Read at every poll, not once at the start: the setting is off for the
    /// first half second of a call that lasts a second, and switching it on
    /// while the call is still going must be enough.
    func testSwitchingTheSettingOnMidRecordingTakesEffect() async throws {
        let clock = TestClock()
        let begin = clock.now
        let (loop, recorder, _) = makeLoop(
            clock: clock,
            enabled: { clock.now.timeIntervalSince(begin) >= 0.5 },
            mic: Self.callForOneSecond,
        )

        try await loop.startMeetingRecording()
        defer { loop.stop() }

        await waitFor(loop.snapshot.phase == .idle, timeout: .seconds(5))
        XCTAssertEqual(loop.snapshot.phase, .idle)
        XCTAssertTrue(recorder.stopCalled)
    }

    // MARK: - Per recording

    /// The first recording sees a long call and is stopped by hand while it is
    /// still going. The second begins after every app has let go: nothing in it
    /// was ever a call, so the first one's must not carry over and end it.
    func testACallSeenInOneRecordingDoesNotArmTheNext() async throws {
        let clock = TestClock()
        let held = HeldBox()
        let script: (TimeInterval) -> MicUsage = { _ in held.value }
        let (loop, recorder, first) = makeLoop(clock: clock, mic: script)

        try await loop.startMeetingRecording()
        await runVirtualTime(clock, since: first, seconds: 1.0)
        XCTAssertEqual(loop.state, .recording, "the first call is still going")
        loop.stopManualRecording()
        XCTAssertEqual(loop.state, .idle)

        held.value = .free
        recorder.stopCalled = false
        try await loop.startMeetingRecording()
        defer { loop.stop() }
        let second = clock.now

        await runVirtualTime(clock, since: second, seconds: observeFor)
        XCTAssertEqual(loop.state, .recording)
        XCTAssertFalse(recorder.stopCalled)
    }

    // MARK: - Production wiring

    /// The loop the production controller builds has to carry the probe and the
    /// setting. Loop-level tests above inject both themselves, so deleting the
    /// controller's pass-through leaves them all green; this reads them back off
    /// the loop the controller made.
    func testControllerHandsItsLoopTheProbeAndTheSetting() async throws {
        let tmpDir = try makeTempDirectory(prefix: "WatchLoopCallEndTests")
        let probe: () -> MicUsage = { .held }
        let controller = makeWatchingController(
            logDir: tmpDir,
            permissionHealth: .allHealthy,
            micUsage: probe,
        )
        addTeardownBlock { await controller.stopManualRecording() }

        let outcome = await controller.applyRecordAction(.start)
        XCTAssertEqual(outcome, .changed)

        let loop = try XCTUnwrap(controller.watchLoop)
        XCTAssertEqual(loop.micUsage(), .held, "the controller's probe never reached its loop")
        XCTAssertTrue(loop.autoStopWhenCallEnds(), "the setting defaults to on and the loop must read it")
        controller.settings.autoStopWhenCallEnds = false
        XCTAssertFalse(loop.autoStopWhenCallEnds(), "the loop must read the live setting, not a copy")
    }
}

/// Mutable box so a scripted probe can be flipped between two recordings.
private final class HeldBox {
    var value: MicUsage = .held
}
