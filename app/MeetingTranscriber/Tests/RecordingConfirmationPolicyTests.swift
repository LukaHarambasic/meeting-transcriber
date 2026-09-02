@testable import MeetingTranscriber
import XCTest

final class RecordingConfirmationPolicyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func policy(
        interval: TimeInterval = 1800,
        grace: TimeInterval = 300,
    ) -> RecordingConfirmationPolicy {
        RecordingConfirmationPolicy(interval: interval, grace: grace)
    }

    // MARK: - Before the interval

    func testNothingDueImmediatelyAfterStart() {
        XCTAssertEqual(
            policy().step(now: start, confirmedAt: start, promptedAt: nil),
            .wait,
        )
    }

    func testNothingDueOneSecondBeforeTheInterval() {
        XCTAssertEqual(
            policy().step(now: start + 1799, confirmedAt: start, promptedAt: nil),
            .wait,
        )
    }

    // MARK: - The ask

    func testPromptDueExactlyAtTheInterval() {
        XCTAssertEqual(
            policy().step(now: start + 1800, confirmedAt: start, promptedAt: nil),
            .prompt,
        )
    }

    /// A recording confirmed at minute 30 must not be asked again until minute
    /// 60. Without resetting on confirmation, every subsequent poll would be
    /// past the interval and the user would be asked every three seconds.
    func testConfirmingResetsTheInterval() {
        let confirmed = start + 1800
        XCTAssertEqual(
            policy().step(now: confirmed + 10, confirmedAt: confirmed, promptedAt: nil),
            .wait,
        )
        XCTAssertEqual(
            policy().step(now: confirmed + 1800, confirmedAt: confirmed, promptedAt: nil),
            .prompt,
        )
    }

    // MARK: - The grace period

    func testOutstandingPromptWaitsThroughTheGracePeriod() {
        let prompted = start + 1800
        XCTAssertEqual(
            policy().step(now: prompted + 299, confirmedAt: start, promptedAt: prompted),
            .wait,
        )
    }

    func testUnansweredPromptStopsTheRecordingAtTheGraceDeadline() {
        let prompted = start + 1800
        XCTAssertEqual(
            policy().step(now: prompted + 300, confirmedAt: start, promptedAt: prompted),
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
            policy.step(now: prompted + 5000, confirmedAt: start, promptedAt: prompted),
            .wait,
        )
    }

    // MARK: - Defaults

    /// The requested cadence, pinned as a value rather than re-derived: the
    /// notification body quotes the grace in minutes, so a change here changes
    /// user-facing text too.
    func testDefaultsAreThirtyMinutesAndFiveMinutes() {
        XCTAssertEqual(RecordingConfirmationPolicy.defaultInterval, 30 * 60)
        XCTAssertEqual(RecordingConfirmationPolicy.defaultGrace, 5 * 60)
        let defaults = RecordingConfirmationPolicy()
        XCTAssertEqual(defaults.interval, 30 * 60)
        XCTAssertEqual(defaults.grace, 5 * 60)
    }

    func testPromptBodyNamesTheGraceInMinutes() {
        XCTAssertTrue(
            policy(grace: 300).promptBody.contains("5 minutes"),
            "the ask has to state the deadline it actually enforces",
        )
    }
}
