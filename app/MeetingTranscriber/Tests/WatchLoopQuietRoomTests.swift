@testable import MeetingTranscriber
import XCTest

/// Drives the quiet-room rule through the live `monitorManualRecording` poll
/// loop with a `TestClock`: that the monitor consults the rule at all, that the
/// one setting gates it, that it reads the shared microphone sample, and that
/// the stop goes through the normal save path with the user told.
///
/// The detector and the microphone probe are scripted as functions of virtual
/// seconds since the recording began.
@MainActor
final class WatchLoopQuietRoomTests: XCTestCase {
    private let poll: TimeInterval = 0.1
    private let policy = QuietRoomPolicy(quietWindow: 0.5)

    /// How long past the moment a stop would be due the "stays recording" tests
    /// keep the loop running before asserting. Several windows.
    private let observeFor: TimeInterval = 3

    private func makeLoop(
        clock: TestClock,
        notifier: any AppNotifying = SilentNotifier(),
        enabled: @escaping () -> Bool = { true },
        usage: @escaping (TimeInterval) -> MicUsage,
        speech: (() -> MicSpeechReading)? = nil,
    ) -> (loop: WatchLoop, recorder: MockRecorder, started: Date) {
        let recorder = MockRecorder()
        recorder.mixPath = URL(fileURLWithPath: "/tmp/quiet_room_mix.wav")
        let started = clock.now
        let probe: () -> MicUsage = { usage(clock.now.timeIntervalSince(started)) }
        // The detector has been listening since the recording began and has
        // never heard anything, unless a test scripts something else.
        let silent: () -> MicSpeechReading = { .listening(since: started, lastSpeech: nil) }
        let loop = WatchLoop(
            recorderFactory: { recorder },
            pollInterval: poll,
            notifier: notifier,
            nowProvider: { clock.now },
            sleepProvider: { await clock.sleep(for: $0) },
            pidAliveCheck: { _ in true }, // never exits, so only the end rules can stop it
            sleepBlocker: SpySleepBlocker(),
            salvageInterrupted: { 0 },
            autoStopWhenMeetingEnds: enabled,
            micUsage: probe,
            micSpeech: speech ?? silent,
            quietRoomPolicy: policy,
        )
        loop.permissionChecker = { _ in
            HealthCheckResult(screenRecording: .healthy, microphone: .healthy)
        }
        return (loop, recorder, started)
    }

    private func runVirtualTime(_ clock: TestClock, since started: Date, seconds: TimeInterval) async {
        await waitFor(clock.now.timeIntervalSince(started) > seconds, timeout: .seconds(5))
        XCTAssertGreaterThan(clock.now.timeIntervalSince(started), seconds, "the monitor loop stopped polling")
    }

    private static func alwaysFree(_: TimeInterval) -> MicUsage {
        .free
    }

    private static func alwaysHeld(_: TimeInterval) -> MicUsage {
        .held
    }

    // MARK: - The stop

    func testStopsAndNotifiesAfterTheQuietWindowWithAFreeMicrophone() async throws {
        let clock = TestClock()
        let notifier = RecordingNotifier()
        let (loop, recorder, _) = makeLoop(clock: clock, notifier: notifier, usage: Self.alwaysFree)

        try await loop.startMeetingRecording()
        defer { loop.stop() }

        await waitFor(loop.snapshot.phase == .idle, timeout: .seconds(5))
        XCTAssertEqual(loop.snapshot.phase, .idle, "nobody spoke and the recording kept going")
        XCTAssertTrue(recorder.stopCalled, "the stop must go through the normal save path")
        let told = notifier.calls.first { $0.title == "Recording Stopped" }
        XCTAssertEqual(told?.body, "Nobody has spoken for 1 minute, so the recording was stopped and saved.")
    }

    /// Control for the stays-recording tests: speech keeps arriving, so the
    /// reading's clock never reaches the window. Without it the stop test could
    /// pass for a reason that has nothing to do with the reading.
    func testRecentSpeechKeepsTheRecordingGoing() async throws {
        let clock = TestClock()
        let started = clock.now
        let speech: () -> MicSpeechReading = {
            .listening(since: started, lastSpeech: clock.now)
        }
        let (loop, recorder, _) = makeLoop(clock: clock, usage: Self.alwaysFree, speech: speech)

        try await loop.startMeetingRecording()
        defer { loop.stop() }

        await runVirtualTime(clock, since: started, seconds: observeFor)
        XCTAssertEqual(loop.state, .recording)
        XCTAssertFalse(recorder.stopCalled)
    }

    func testNeverStopsWhileAnotherAppHoldsTheMicrophone() async throws {
        let clock = TestClock()
        let (loop, recorder, started) = makeLoop(clock: clock, usage: Self.alwaysHeld)

        try await loop.startMeetingRecording()
        defer { loop.stop() }

        await runVirtualTime(clock, since: started, seconds: observeFor)
        XCTAssertEqual(loop.state, .recording, "a held microphone is a call, which the call-end rule owns")
        XCTAssertFalse(recorder.stopCalled)
    }

    func testDefaultUnavailableReadingNeverStops() async throws {
        let clock = TestClock()
        let unavailable: () -> MicSpeechReading = { .unavailable }
        let (loop, recorder, started) = makeLoop(clock: clock, usage: Self.alwaysFree, speech: unavailable)

        try await loop.startMeetingRecording()
        defer { loop.stop() }

        await runVirtualTime(clock, since: started, seconds: observeFor)
        XCTAssertEqual(loop.state, .recording)
        XCTAssertFalse(recorder.stopCalled)
    }

    func testSwitchedOffNeverStops() async throws {
        let clock = TestClock()
        let (loop, recorder, started) = makeLoop(clock: clock, enabled: { false }, usage: Self.alwaysFree)

        try await loop.startMeetingRecording()
        defer { loop.stop() }

        await runVirtualTime(clock, since: started, seconds: observeFor)
        XCTAssertEqual(loop.state, .recording, "one setting gates both rules")
        XCTAssertFalse(recorder.stopCalled)
    }

    /// Both rules read one microphone sample per poll. The quiet-room step asks
    /// for its reading once per poll it runs, so with the call-end rule never
    /// stopping the two counts must stay equal; a second `micUsage()` read
    /// inside either rule would double the first.
    func testMicrophoneIsSampledOncePerPoll() async throws {
        let clock = TestClock()
        let counter = ReadCounter()
        let started = clock.now
        let usage: (TimeInterval) -> MicUsage = { _ in
            counter.usage += 1
            return .held
        }
        let speech: () -> MicSpeechReading = {
            counter.speech += 1
            return .listening(since: started, lastSpeech: nil)
        }
        let (loop, _, _) = makeLoop(clock: clock, usage: usage, speech: speech)

        try await loop.startMeetingRecording()
        defer { loop.stop() }

        await waitFor(counter.speech >= 5, timeout: .seconds(5))
        XCTAssertGreaterThanOrEqual(counter.speech, 5, "the monitor stopped polling")
        XCTAssertEqual(counter.usage, counter.speech, "each poll must read the microphone once and share it")
    }

    /// A loop built without a speech closure gets the shipped default. Reads
    /// the stored property, so deleting the default fails here and not only in
    /// the tests above that inject their own.
    func testLoopBuiltWithoutADetectorReadsUnavailable() {
        let loop = WatchLoop()
        XCTAssertEqual(loop.micSpeech(), .unavailable)
        XCTAssertEqual(loop.quietRoomPolicy, QuietRoomPolicy())
    }
}

/// Counts how often each scripted probe was read.
private final class ReadCounter {
    var usage = 0
    var speech = 0
}
