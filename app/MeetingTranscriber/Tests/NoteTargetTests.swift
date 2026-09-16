@testable import MeetingTranscriber
import XCTest

final class NoteTargetTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

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
