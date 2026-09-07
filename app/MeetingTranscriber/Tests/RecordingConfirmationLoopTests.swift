@testable import MeetingTranscriber
import XCTest

/// Drives the still-recording check through the live
/// `monitorManualRecording` poll loop with a `TestClock`, so the ask and the
/// unanswered-ask stop are exercised where they actually run rather than only
/// in `RecordingConfirmationPolicy`'s pure `step`.
///
/// The policy tests cover *when* each outcome is due. These cover the wiring the
/// policy cannot: that the monitor consults it at all, that the ask reaches the
/// notifier, that an unanswered ask stops **and enqueues** the recording, and
/// that confirming keeps it running.
@MainActor
final class RecordingConfirmationLoopTests: XCTestCase {
    /// Short virtual timings: the clock is fake, but keeping the interval a
    /// small multiple of the poll keeps the number of yields low.
    private let interval: TimeInterval = 1.0
    private let grace: TimeInterval = 0.5
    private let poll: TimeInterval = 0.1

    /// Salvage must never be reached from these tests — an unanswered ask stops
    /// cleanly — so a call would be a bug, not a value to configure.
    private let noSalvage: () -> Int = { 0 }

    /// `MockRecorder` reports -120 dBFS on both channels unless a test raises
    /// them, so by default every loop here is a *silent* recording. That is
    /// what makes the pre-existing stop tests still mean what they meant: the
    /// levels agree the room is empty, and only the ask decides.
    private func makeLoop(
        notifier: any AppNotifying,
        clock: TestClock,
        policy: RecordingConfirmationPolicy? = nil,
        queue: PipelineQueue? = nil,
        deliverability: AskDeliverability = .deliverable,
    ) -> (WatchLoop, MockRecorder) {
        let recorder = MockRecorder()
        recorder.mixPath = URL(fileURLWithPath: "/tmp/confirmation_mix.wav")
        let loop = WatchLoop(
            recorderFactory: { recorder },
            pipelineQueue: queue,
            pollInterval: poll,
            notifier: notifier,
            nowProvider: { clock.now },
            sleepProvider: { await clock.sleep(for: $0) },
            pidAliveCheck: { _ in true }, // never exits, so only the check can stop it
            sleepBlocker: SpySleepBlocker(),
            confirmationPolicy: policy
                ?? RecordingConfirmationPolicy(interval: interval, grace: grace),
            salvageInterrupted: noSalvage,
            // Explicit `.deliverable` rather than the production default: the
            // default is `.unknown`, which the policy refuses to stop on, so
            // every "unanswered ask stops it" test would silently stop
            // asserting anything. Not trailing-closure: it would detach the
            // closure from the label naming it.
            // swiftlint:disable:next trailing_closure
            askDeliverability: { deliverability },
        )
        loop.permissionChecker = {
            HealthCheckResult(screenRecording: .healthy, microphone: .healthy)
        }
        return (loop, recorder)
    }

    private func askCount(_ notifier: RecordingNotifier) -> Int {
        notifier.calls.count { $0.title == RecordingConfirmationPolicy.promptTitle }
    }

    // MARK: - The ask

    func testAsksOnceTheIntervalElapses() async throws {
        let clock = TestClock()
        let notifier = RecordingNotifier()
        let (loop, _) = makeLoop(notifier: notifier, clock: clock)

        try await loop.startMeetingRecording()
        defer { loop.stop() }

        await waitFor(askCount(notifier) > 0, timeout: .seconds(2))
        let ask = notifier.calls.first { $0.title == RecordingConfirmationPolicy.promptTitle }
        XCTAssertNotNil(ask, "the monitor never consulted the confirmation policy")
        XCTAssertEqual(
            ask?.urgency, .timeSensitive,
            "a Focus-suppressed ask is one nobody can answer, and the grace period then stops the recording",
        )
        XCTAssertEqual(loop.state, .recording, "asking must not itself stop the recording")
    }

    /// One ask outstanding at a time. Without suspending the interval while a
    /// prompt stands, the user would be re-asked on every poll.
    func testDoesNotReAskWhileAnAskIsOutstanding() async throws {
        let clock = TestClock()
        let notifier = RecordingNotifier()
        // Grace far longer than the interval, so the window in which a second
        // ask could be posted is wide open if the suspension is missing.
        let (loop, _) = makeLoop(
            notifier: notifier,
            clock: clock,
            policy: RecordingConfirmationPolicy(interval: 0.5, grace: 100),
        )

        try await loop.startMeetingRecording()
        defer { loop.stop() }

        await waitFor(askCount(notifier) > 0, timeout: .seconds(2))
        // Let many more polls run; virtual time races far past several intervals.
        for _ in 0 ..< 50 {
            await Task.yield()
        }

        XCTAssertEqual(
            askCount(notifier), 1,
            "an outstanding ask must suspend the interval, not stack asks",
        )
    }

    // MARK: - Unanswered

    /// The requested behaviour end to end: nobody answers, the recording stops,
    /// and — the part that matters — the audio is still handed to the pipeline.
    /// A check that stopped a recording without saving it would be worse than no
    /// check at all.
    func testUnansweredAskStopsAndEnqueuesTheRecording() async throws {
        let clock = TestClock()
        let notifier = RecordingNotifier()
        let queue = PipelineQueue()
        let (loop, recorder) = makeLoop(notifier: notifier, clock: clock, queue: queue)

        try await loop.startMeetingRecording()

        await waitFor(loop.state == .idle, timeout: .seconds(2))
        XCTAssertEqual(loop.state, .idle, "an unanswered ask must stop the recording")
        XCTAssertTrue(recorder.stopCalled)
        XCTAssertEqual(queue.jobs.count, 1, "the stopped recording must still be saved")
        XCTAssertTrue(
            notifier.calls.contains { $0.title == "Recording Stopped" },
            "the user has to learn the recording ended and where the audio went",
        )
    }

    // MARK: - Attendance

    /// The regression this whole rewrite exists for: a 55-minute meeting was
    /// stopped at 35 because the ask was never delivered and the grace expired
    /// while everyone was still talking. Measured speech must outrank an
    /// expired ask outright.
    ///
    /// This is also the test that catches the wiring going missing. Delete the
    /// `sampleAttendance(now:)` call in `monitorManualRecording` and the policy
    /// still passes all of its own tests, because it is handed
    /// `.unmonitored` forever; only an assertion at this level notices.
    func testSpeechKeepsTheRecordingRunningPastTheGrace() async throws {
        let clock = TestClock()
        let notifier = RecordingNotifier()
        let (loop, recorder) = makeLoop(notifier: notifier, clock: clock)
        // One channel only, comfortably above the speech threshold: a meeting
        // held on loudspeakers with the mic muted is still attended.
        recorder.appLevelDBFS = -20

        try await loop.startMeetingRecording()
        defer { loop.stop() }

        // Race virtual time far past interval + grace.
        for _ in 0 ..< 200 {
            await Task.yield()
        }

        XCTAssertEqual(loop.state, .recording, "speech must never let the check stop a live meeting")
        XCTAssertFalse(recorder.stopCalled)
        XCTAssertEqual(askCount(notifier), 0, "an audibly attended recording should not even be asked")
    }

    /// Attendance is re-read every poll rather than latched at the first word,
    /// so the case the feature actually exists for (a meeting that ended and a
    /// Mac still taping the room) is still caught.
    func testSpeechThatStopsNoLongerProtectsTheRecording() async throws {
        let clock = TestClock()
        let notifier = RecordingNotifier()
        let queue = PipelineQueue()
        let (loop, recorder) = makeLoop(
            notifier: notifier,
            clock: clock,
            policy: RecordingConfirmationPolicy(interval: interval, grace: grace, attentionWindow: 0.2),
            queue: queue,
        )
        recorder.appLevelDBFS = -20

        try await loop.startMeetingRecording()
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        XCTAssertEqual(loop.state, .recording, "speech should hold it open while it lasts")

        recorder.appLevelDBFS = -120 // the meeting ends, the room goes quiet

        await waitFor(loop.state == .idle, timeout: .seconds(2))
        XCTAssertEqual(loop.state, .idle, "a quiet room must still be catchable")
        XCTAssertEqual(queue.jobs.count, 1, "and the audio must still be saved")
    }

    /// An ask the system could not show is not an unanswered ask, it is an
    /// unasked one. Before this the two were indistinguishable and a recording
    /// was ended on the strength of undelivered mail.
    func testUndeliverableAskKeepsTheRecordingAndFlagsItForTheMenu() async throws {
        let clock = TestClock()
        let notifier = RecordingNotifier()
        let (loop, recorder) = makeLoop(
            notifier: notifier,
            clock: clock,
            deliverability: .suppressed,
        )

        try await loop.startMeetingRecording()
        defer { loop.stop() }

        await waitFor(loop.askUnanswerable, timeout: .seconds(2))
        for _ in 0 ..< 50 {
            await Task.yield()
        }

        XCTAssertEqual(loop.state, .recording, "a suppressed ask must not end the recording")
        XCTAssertFalse(recorder.stopCalled)
        XCTAssertTrue(
            loop.askUnanswerable,
            "the menu is the only reachable channel here, so it has to be told the auto-stop is off",
        )
    }

    // MARK: - Answered

    /// Confirming resets the clock, so the recording survives past the point an
    /// unanswered one would have been stopped.
    func testConfirmingKeepsTheRecordingRunning() async throws {
        let clock = TestClock()
        let notifier = RecordingNotifier()
        let (loop, _) = makeLoop(notifier: notifier, clock: clock)

        try await loop.startMeetingRecording()
        defer { loop.stop() }

        await waitFor(askCount(notifier) > 0, timeout: .seconds(2))
        loop.confirmStillRecording()
        XCTAssertNil(loop.confirmationPromptedAt, "confirming clears the outstanding ask")

        // The grace period's worth of virtual time passes; the recording lives.
        for _ in 0 ..< 5 {
            await Task.yield()
        }
        XCTAssertEqual(loop.state, .recording, "a confirmed recording must not be stopped")
    }

    /// A late answer — the user unlocks the Mac and clicks a banner from twenty
    /// minutes ago — must not seed state for a recording that no longer exists.
    func testConfirmingWhenNotRecordingIsIgnored() {
        let clock = TestClock()
        let (loop, _) = makeLoop(notifier: RecordingNotifier(), clock: clock)

        loop.confirmStillRecording()

        XCTAssertEqual(loop.confirmedAt, .distantPast, "nothing is recording, so nothing to confirm")
        XCTAssertEqual(loop.state, .idle)
    }
}
