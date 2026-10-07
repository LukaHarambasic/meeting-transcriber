@testable import MeetingTranscriber
import XCTest

/// Records every save so a test can read what reached which target.
private final class RecordingNotesStore: NotesStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    func load(_ target: NoteTarget) -> String {
        lock.lock()
        defer { lock.unlock() }
        return storage[key(target)] ?? ""
    }

    func save(_ text: String, to target: NoteTarget) {
        lock.lock()
        defer { lock.unlock() }
        storage[key(target)] = text
    }

    func append(_ text: String, to target: NoteTarget) {
        lock.lock()
        defer { lock.unlock() }
        storage[key(target), default: ""] += text
    }

    func take(stem _: String) -> String? {
        nil
    }

    func fileURL(for _: NoteTarget) -> URL {
        URL(fileURLWithPath: "/tmp/notes-controller-tests.md")
    }

    private func key(_ target: NoteTarget) -> String {
        switch target {
        case let .liveRecording(stem, _): "live-\(stem)"

        case let .scratch(day): "scratch-\(Int(day.timeIntervalSince1970))"
        }
    }
}

/// `NotesController.recordingStateChanged`: a stop closes the panel, a start
/// leaves its visibility alone. The scene wiring that forwards the recording
/// flag cannot be instantiated in a test, so the decision lives here.
@MainActor
final class NotesControllerTests: XCTestCase {
    private let live = NoteTarget.liveRecording(stem: "20261007_100000", startedAt: Date(timeIntervalSince1970: 1_791_000_000))
    private let scratch = NoteTarget.scratch(day: Date(timeIntervalSince1970: 1_791_000_000))

    /// A controller whose resolved target follows `recording`, standing in for
    /// the real resolver that reads the recorder's state.
    private func makeController(store: RecordingNotesStore, recording: @escaping () -> Bool) -> NotesController {
        let liveTarget: NoteTarget = live
        let scratchTarget: NoteTarget = scratch
        return NotesController(store: store) { recording() ? liveTarget : scratchTarget }
    }

    func testStopClosesOpenPanelAndKeepsMeetingTextOnRecordingTarget() {
        let store = RecordingNotesStore()
        var recording = true
        let controller: NotesController = makeController(store: store) { recording }
        controller.open()
        controller.text = "decision: ship on Friday"
        XCTAssertTrue(controller.isVisible)

        recording = false
        controller.recordingStateChanged(isRecording: false)

        XCTAssertFalse(controller.isVisible)
        XCTAssertEqual(store.load(live), "decision: ship on Friday")
        XCTAssertEqual(store.load(scratch), "", "meeting text must not reach the scratch note")
        XCTAssertEqual(controller.target, scratch)
        XCTAssertEqual(controller.text, "", "the scratch note is loaded, not the meeting text")
    }

    func testStopThenReopenShowsTheDaysScratchNote() {
        let store = RecordingNotesStore()
        store.save("earlier today", to: scratch)
        var recording = true
        let controller: NotesController = makeController(store: store) { recording }
        controller.open()
        controller.text = "in the meeting"

        recording = false
        controller.recordingStateChanged(isRecording: false)
        controller.open()

        XCTAssertTrue(controller.isVisible)
        XCTAssertEqual(controller.target, scratch)
        XCTAssertEqual(controller.text, "earlier today")
    }

    func testStartRetargetsWithoutChangingVisibility() {
        let store = RecordingNotesStore()
        var recording = false
        let controller: NotesController = makeController(store: store) { recording }

        recording = true
        controller.recordingStateChanged(isRecording: true)
        XCTAssertFalse(controller.isVisible, "a start must not open a closed panel")
        XCTAssertEqual(controller.target, live)

        controller.open()
        recording = false
        controller.recordingStateChanged(isRecording: false)
        controller.open()
        recording = true
        controller.recordingStateChanged(isRecording: true)
        XCTAssertTrue(controller.isVisible, "a start must not close an open panel")
        XCTAssertEqual(controller.target, live)
    }
}
