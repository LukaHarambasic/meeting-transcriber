@testable import MeetingTranscriber
import XCTest

final class RecordingConfirmationPolicyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func policy(
        interval: TimeInterval = 1800,
        grace: TimeInterval = 300,
        attentionWindow: TimeInterval = 300,
    ) -> RecordingConfirmationPolicy {
        RecordingConfirmationPolicy(interval: interval, grace: grace, attentionWindow: attentionWindow)
    }

    /// Convenience wrapper pinning the two new parameters to values that
    /// cannot themselves change the outcome, so tests about the interval and
    /// grace machinery read exactly as they did before those parameters
    /// existed. `.noSpeechObserved` never satisfies rule 1 (it is not
    /// `.lastSpeech`), and `.deliverable` never triggers `.keepUnanswerable`.
    private func step(
        _ policy: RecordingConfirmationPolicy,
        now: Date,
        confirmedAt: Date,
        promptedAt: Date?,
        attendance: RecordingAttendance = .noSpeechObserved,
        deliverability: AskDeliverability = .deliverable,
    ) -> RecordingConfirmationDecision {
        policy.step(
            now: now, confirmedAt: confirmedAt, promptedAt: promptedAt,
            attendance: attendance, deliverability: deliverability,
        )
    }

    // MARK: - Before the interval

    func testNothingDueImmediatelyAfterStart() {
        XCTAssertEqual(
            step(policy(), now: start, confirmedAt: start, promptedAt: nil),
            .wait,
        )
    }

    func testNothingDueOneSecondBeforeTheInterval() {
        XCTAssertEqual(
            step(policy(), now: start + 1799, confirmedAt: start, promptedAt: nil),
            .wait,
        )
    }

    // MARK: - The ask

    func testPromptDueExactlyAtTheInterval() {
        XCTAssertEqual(
            step(policy(), now: start + 1800, confirmedAt: start, promptedAt: nil),
            .prompt,
        )
    }

    /// A recording confirmed at minute 30 must not be asked again until minute
    /// 60. Without resetting on confirmation, every subsequent poll would be
    /// past the interval and the user would be asked every three seconds.
    func testConfirmingResetsTheInterval() {
        let confirmed = start + 1800
        XCTAssertEqual(
            step(policy(), now: confirmed + 10, confirmedAt: confirmed, promptedAt: nil),
            .wait,
        )
        XCTAssertEqual(
            step(policy(), now: confirmed + 1800, confirmedAt: confirmed, promptedAt: nil),
            .prompt,
        )
    }

    // MARK: - The grace period

    func testOutstandingPromptWaitsThroughTheGracePeriod() {
        let prompted = start + 1800
        XCTAssertEqual(
            step(policy(), now: prompted + 299, confirmedAt: start, promptedAt: prompted),
            .wait,
        )
    }

    func testUnansweredPromptStopsTheRecordingAtTheGraceDeadline() {
        let prompted = start + 1800
        XCTAssertEqual(
            step(policy(), now: prompted + 300, confirmedAt: start, promptedAt: prompted),
            .stopUnconfirmed,
        )
    }

    /// An outstanding ask suspends the interval entirely. Otherwise a user who
    /// lets one prompt sit would get a second prompt stacked on the first, and
    /// the grace deadline would silently move with it.
    func testOutstandingPromptIsNotReAsked() {
        let prompted = start + 1800
        // Long past a second interval, but still inside the grace period.
        let policy = policy(interval: 100, grace: 10000)
        XCTAssertEqual(
            step(policy, now: prompted + 5000, confirmedAt: start, promptedAt: prompted),
            .wait,
        )
    }

    // MARK: - Attendance beats an outstanding, expired prompt

    /// The rule the rewrite exists for: speech heard inside the attention
    /// window must win even when a prompt is outstanding and already past its
    /// grace deadline, or the exact failure this policy was rewritten for (a
    /// live meeting stopped mid-sentence) recurs every time a lull happens to
    /// straddle the grace window.
    func testRecentSpeechBeatsAnExpiredOutstandingPrompt() {
        let prompted = start + 1800
        let heardAt = prompted + 400 // well past the 300s grace deadline
        XCTAssertEqual(
            step(
                policy(), now: heardAt + 1, confirmedAt: start, promptedAt: prompted,
                attendance: .lastSpeech(heardAt), deliverability: .deliverable,
            ),
            .attended,
        )
    }

    /// Speech exactly at the attention-window boundary still counts (`<`, not
    /// `<=`, is the excluded side — see the next test).
    func testSpeechJustInsideTheAttentionWindowIsAttended() {
        let heardAt = start
        XCTAssertEqual(
            step(
                policy(), now: heardAt + 299, confirmedAt: start, promptedAt: nil,
                attendance: .lastSpeech(heardAt),
            ),
            .attended,
        )
    }

    /// A `.lastSpeech` older than `attentionWindow` must behave exactly like
    /// `.noSpeechObserved`: this is the "meeting ended and the room went
    /// quiet" case the feature exists to catch, so stale speech cannot go on
    /// protecting the recording forever. Exact boundary: speech heard exactly
    /// `attentionWindow` before `now` (`== attentionWindow`, not `<`) no longer
    /// counts, so the grace deadline on the outstanding prompt is free to fire.
    func testStaleSpeechAtExactlyTheAttentionWindowStopsTheRecording() {
        let prompted = start + 1800
        let heardAt = prompted // heard exactly at prompt-time, now sits attentionWindow past that
        XCTAssertEqual(
            step(
                policy(), now: prompted + 300, confirmedAt: start, promptedAt: prompted,
                attendance: .lastSpeech(heardAt), deliverability: .deliverable,
            ),
            .stopUnconfirmed,
        )
    }

    /// One step further than the boundary test above, using a fresh grace
    /// deadline rather than the same instant as the attention-window edge, so
    /// the stale-speech path is exercised independently of the boundary math.
    func testStaleSpeechDoesNotPreventAStop() {
        let heardAt = start
        let prompted = start + 1800
        XCTAssertEqual(
            step(
                policy(), now: prompted + 300, confirmedAt: start, promptedAt: prompted,
                attendance: .lastSpeech(heardAt), deliverability: .deliverable,
            ),
            .stopUnconfirmed,
        )
    }

    // MARK: - Unmonitored can never stop a recording

    /// No level data at all means the app has neither an answer nor evidence
    /// either way. Reading that absence as "nobody is there" would recreate
    /// the exact bug this rewrite removes for a different reason (no levels,
    /// instead of an undelivered notification), so `.unmonitored` must defer
    /// to `WatchLoop.maxDuration` instead of ever producing `.stopUnconfirmed`.
    func testUnmonitoredNeverStopsEvenWithADeliverableAsk() {
        let prompted = start + 1800
        XCTAssertEqual(
            step(
                policy(), now: prompted + 300, confirmedAt: start, promptedAt: prompted,
                attendance: .unmonitored, deliverability: .deliverable,
            ),
            .keepUnanswerable,
        )
    }

    // MARK: - Undeliverable asks can never stop a recording

    /// A suppressed notification produces the same silence as an absent user.
    /// Reading it as a real answer is the exact bug report this policy exists
    /// to fix.
    func testSuppressedAskKeepsTheRecording() {
        let prompted = start + 1800
        XCTAssertEqual(
            step(
                policy(), now: prompted + 300, confirmedAt: start, promptedAt: prompted,
                attendance: .noSpeechObserved, deliverability: .suppressed,
            ),
            .keepUnanswerable,
        )
    }

    /// `.unknown` counts as not answerable: the cost of wrongly assuming
    /// delivery is a stopped meeting, and that cost is not symmetric with the
    /// cost of wrongly assuming suppression (a recording that runs to the
    /// four-hour cap and says so in the menu).
    func testUnknownDeliverabilityKeepsTheRecording() {
        let prompted = start + 1800
        XCTAssertEqual(
            step(
                policy(), now: prompted + 300, confirmedAt: start, promptedAt: prompted,
                attendance: .noSpeechObserved, deliverability: .unknown,
            ),
            .keepUnanswerable,
        )
    }

    // MARK: - Defaults

    /// The requested cadence, pinned as a value rather than re-derived: the
    /// notification body quotes the grace in minutes, so a change here changes
    /// user-facing text too.
    func testDefaultsAreThirtyMinutesAndFiveMinutes() {
        XCTAssertEqual(RecordingConfirmationPolicy.defaultInterval, 30 * 60)
        XCTAssertEqual(RecordingConfirmationPolicy.defaultGrace, 5 * 60)
        XCTAssertEqual(RecordingConfirmationPolicy.defaultAttentionWindow, 5 * 60)
        let defaults = RecordingConfirmationPolicy()
        XCTAssertEqual(defaults.interval, 30 * 60)
        XCTAssertEqual(defaults.grace, 5 * 60)
        XCTAssertEqual(defaults.attentionWindow, 5 * 60)
    }

    func testPromptBodyNamesTheGraceInMinutes() {
        XCTAssertTrue(
            policy(grace: 300).promptBody.contains("5 minutes"),
            "the ask has to state the deadline it actually enforces",
        )
    }
}
