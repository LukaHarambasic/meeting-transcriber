@testable import MeetingTranscriber
import XCTest

/// The call-end rule on its own: when each outcome becomes due, asserted in
/// plain seconds with no loop, clock or CoreAudio involved. Whether the monitor
/// consults it at all is `WatchLoopCallEndTests`' job.
///
/// Each test varies one dimension and keeps the others at the values a real
/// call would have, so a rule that is wrong shows up as the one test about it
/// failing rather than as a pile of unrelated ones.
@MainActor
final class CallEndPolicyTests: XCTestCase {
    /// One observation: what the probe said, this many seconds into the recording.
    private struct Poll {
        let at: TimeInterval
        let usage: MicUsage
    }

    private let start = Date(timeIntervalSince1970: 1_000_000)
    private let policy = CallEndPolicy(minimumCallDuration: 60, releaseGrace: 120)

    private func poll(_ at: TimeInterval, _ usage: MicUsage) -> Poll {
        Poll(at: at, usage: usage)
    }

    /// Feeds the polls through the policy and returns the offsets at which it
    /// said stop, the decision at every poll, and the state the last poll left
    /// behind.
    private func run(_ polls: [Poll]) -> (stops: [TimeInterval], decisions: [CallEndDecision], state: CallEndState) {
        var state = CallEndState()
        var stops: [TimeInterval] = []
        var decisions: [CallEndDecision] = []
        for poll in polls {
            let (next, decision) = policy.step(
                state: state,
                micUsage: poll.usage,
                now: start.addingTimeInterval(poll.at),
            )
            state = next
            decisions.append(decision)
            if decision == .stopCallEnded { stops.append(poll.at) }
        }
        return (stops, decisions, state)
    }

    /// A poll every 10 s over `range` (inclusive of both ends), all reporting `usage`.
    private func polls(_ range: ClosedRange<Int>, _ usage: MicUsage) -> [Poll] {
        stride(from: range.lowerBound, through: range.upperBound, by: 10).map { poll(TimeInterval($0), usage) }
    }

    func testDefaultsAreAMinuteToArmAndTwoMinutesToRelease() {
        XCTAssertEqual(CallEndPolicy().minimumCallDuration, 60)
        XCTAssertEqual(CallEndPolicy().releaseGrace, 120)
    }

    func testSettingDefaultsOnAndPersists() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "call-end-setting-\(UUID().uuidString)"))
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.autoStopWhenCallEnds, "the recording the user forgot to stop is the whole point")
        settings.autoStopWhenCallEnds = false
        XCTAssertFalse(AppSettings(defaults: defaults).autoStopWhenCallEnds, "the choice has to survive a relaunch")
    }

    // MARK: - The call has to be seen

    func testSustainedCallThenReleasePastGraceStops() {
        // Held 0...300, released from 310; grace 120 ends at 430.
        let result = run(polls(0 ... 300, .held) + polls(310 ... 430, .free))
        XCTAssertEqual(result.stops, [430], "stops at the first poll a full grace after the release began")
    }

    func testBriefMicUseNeverArmsTheRule() {
        // 20 s of dictation, then the microphone is free for a long time.
        let result = run(polls(0 ... 20, .held) + polls(30 ... 2000, .free))
        XCTAssertEqual(result.stops, [], "a short burst is not a call")
        XCTAssertFalse(result.state.callSeen)
    }

    func testNoCallEverSeenNeverStops() {
        XCTAssertEqual(run(polls(0 ... 5000, .free)).stops, [])
    }

    func testCallIsSeenExactlyAtTheMinimumDuration() {
        XCTAssertFalse(run([poll(0, .held), poll(59, .held)]).state.callSeen, "59 s is not yet a call")
        XCTAssertTrue(run([poll(0, .held), poll(60, .held)]).state.callSeen, "60 s is")
    }

    func testTwoShortBurstsDoNotAddUpToACall() {
        // 40 s held, a gap, 40 s held again: neither run reaches a minute.
        let result = run(polls(0 ... 40, .held) + [poll(50, .free)] + polls(60 ... 100, .held))
        XCTAssertFalse(result.state.callSeen)
    }

    // MARK: - The release has to last

    func testReleaseShorterThanGraceDoesNotStop() {
        let result = run([poll(0, .held), poll(60, .held), poll(70, .free), poll(189, .free)])
        XCTAssertEqual(result.decisions, [.wait, .wait, .wait, .wait], "119 s of release is not enough")
    }

    func testReleaseOfExactlyTheGraceStops() {
        let result = run([poll(0, .held), poll(60, .held), poll(70, .free), poll(190, .free)])
        XCTAssertEqual(result.decisions.last, .stopCallEnded)
    }

    func testUsingTheMicAgainRestartsTheCountdown() {
        // Armed, released at 70, back on at 160 (a second meeting), released
        // again at 170. The first countdown would have fired at 190; the
        // restarted one fires at 290.
        let result = run([
            poll(0, .held), poll(60, .held),
            poll(70, .free), poll(150, .free),
            poll(160, .held),
            poll(170, .free), poll(190, .free), poll(280, .free), poll(290, .free),
        ])
        XCTAssertEqual(result.stops, [290])
    }

    func testReuseClearsTheReleaseClockButKeepsTheRecordingArmed() {
        let result = run([poll(0, .held), poll(60, .held), poll(70, .free), poll(150, .free), poll(160, .held)])
        XCTAssertNil(result.state.releasedSince)
        XCTAssertTrue(result.state.callSeen, "the recording stays armed through a later call")
    }

    // MARK: - Unknown is no evidence

    func testUnknownNeverStopsAnArmedRecording() {
        let result = run([poll(0, .held), poll(60, .held)] + polls(70 ... 5000, .unknown))
        XCTAssertEqual(result.stops, [])
    }

    func testUnknownDoesNotAdvanceARunningCountdown() {
        // Released at 70, then 190 s of nothing known, then released again at
        // 270. Counting the gap would stop at 270; the countdown instead has to
        // be observed afresh, so it starts at 270 and stops at 390.
        let result = run([
            poll(0, .held), poll(60, .held),
            poll(70, .free),
            poll(80, .unknown),
            poll(270, .free),
            poll(380, .free), poll(390, .free),
        ])
        XCTAssertEqual(result.stops, [390])
    }

    func testUnknownDoesNotCountTowardArming() {
        // Held, unknown for the middle, held again: no unbroken minute was seen.
        let result = run([poll(0, .held), poll(30, .unknown), poll(70, .held)])
        XCTAssertFalse(result.state.callSeen)
    }

    func testUnknownDoesNotUndoACallAlreadySeen() {
        let result = run([poll(0, .held), poll(60, .held), poll(70, .unknown)])
        XCTAssertTrue(result.state.callSeen)
    }
}
