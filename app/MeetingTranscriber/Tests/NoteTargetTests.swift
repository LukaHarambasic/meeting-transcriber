@testable import MeetingTranscriber
import XCTest

/// `NoteTarget`'s only decision: what a ⌘T timestamp reads as.
///
/// The format is load-bearing rather than cosmetic — it is meant to match the
/// transcript's own `[mm:ss]` stamps so a note pasted beside a transcript line
/// reads as the same kind of thing, and `ProtocolFrontmatter.speakerLabel`
/// classifies a bracket of digits and colons as a timestamp rather than a
/// speaker name. A stamp in some other shape would be read as a speaker.
final class NoteTargetTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    func testScratchTargetHasNoTimestamp() {
        let target = NoteTarget.scratch(day: start)
        XCTAssertNil(target.elapsedStamp(at: start.addingTimeInterval(90)))
    }

    func testLiveTargetStampsMinutesAndSeconds() {
        let target = NoteTarget.liveRecording(stem: "20260909_143000", startedAt: start)
        XCTAssertEqual(target.elapsedStamp(at: start), "[00:00]")
        XCTAssertEqual(target.elapsedStamp(at: start.addingTimeInterval(9)), "[00:09]")
        XCTAssertEqual(target.elapsedStamp(at: start.addingTimeInterval(754)), "[12:34]")
    }

    /// Past an hour the stamp grows an hours field rather than counting to
    /// `[74:00]`, which no transcript reader would parse as 1h14m.
    func testLiveTargetStampsHoursOncePastOne() {
        let target = NoteTarget.liveRecording(stem: "20260909_143000", startedAt: start)
        XCTAssertEqual(target.elapsedStamp(at: start.addingTimeInterval(3723)), "[1:02:03]")
    }

    /// A `now` before the recording start is reachable (the panel and the
    /// recorder read different clocks) and must not produce a negative stamp.
    func testStampClampsNegativeElapsedToZero() {
        let target = NoteTarget.liveRecording(stem: "20260909_143000", startedAt: start)
        XCTAssertEqual(target.elapsedStamp(at: start.addingTimeInterval(-30)), "[00:00]")
    }

    /// The stem is what makes a note findable from the recording, so the two
    /// cases must be distinguishable without pattern matching at every call site.
    func testRecordingStemIsPresentOnlyForALiveRecording() {
        XCTAssertEqual(
            NoteTarget.liveRecording(stem: "20260909_143000", startedAt: start).recordingStem,
            "20260909_143000",
        )
        XCTAssertNil(NoteTarget.scratch(day: start).recordingStem)
        XCTAssertTrue(NoteTarget.liveRecording(stem: "s", startedAt: start).isLive)
        XCTAssertFalse(NoteTarget.scratch(day: start).isLive)
    }
}
