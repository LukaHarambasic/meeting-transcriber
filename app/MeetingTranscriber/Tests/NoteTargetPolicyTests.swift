@testable import MeetingTranscriber
import XCTest

/// `NoteTargetPolicy`'s only decision: which of the two `NoteTarget` cases a
/// note being typed right now resolves to.
///
/// The interesting cases are the partial ones — a stem with no start date and
/// the reverse — because a real recorder should never produce them, but the
/// policy still has to answer honestly rather than crash: a note must always
/// have somewhere to go.
final class NoteTargetPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let started = Date(timeIntervalSince1970: 999_000)

    func testStemAndStartDateResolveToLiveRecording() {
        let target = NoteTargetPolicy.target(
            recordingStem: "20260909_143000", recordingStartedAt: started, now: now,
        )
        XCTAssertEqual(target, .liveRecording(stem: "20260909_143000", startedAt: started))
    }

    func testNeitherStemNorStartDateResolvesToScratch() {
        let target = NoteTargetPolicy.target(recordingStem: nil, recordingStartedAt: nil, now: now)
        XCTAssertEqual(target, .scratch(day: now))
    }

    /// A stem with no start date should never happen in practice, but the
    /// policy still owes an answer: a live target with no real start time
    /// would produce a meaningless elapsed stamp, so it falls back to scratch.
    func testStemWithNoStartDateResolvesToScratch() {
        let target = NoteTargetPolicy.target(
            recordingStem: "20260909_143000", recordingStartedAt: nil, now: now,
        )
        XCTAssertEqual(target, .scratch(day: now))
    }

    /// A start date with no stem (the recording just stopped) cannot be
    /// found again by the pipeline, which reads notes by stem, so it also
    /// falls back to scratch rather than producing an unreachable target.
    func testStartDateWithNoStemResolvesToScratch() {
        let target = NoteTargetPolicy.target(
            recordingStem: nil, recordingStartedAt: started, now: now,
        )
        XCTAssertEqual(target, .scratch(day: now))
    }
}
