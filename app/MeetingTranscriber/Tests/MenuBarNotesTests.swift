@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// One wiring test for the menu's "Notes" row: it exists and calls
/// `onOpenNotes` when pressed. A separate file from `MenuBarViewTests.swift`
/// (owned by another unit) so this unit's addition doesn't collide with it.
@MainActor
final class MenuBarNotesTests: XCTestCase {
    private func makeView(onOpenNotes: @escaping () -> Void) -> MenuBarView {
        MenuBarView(
            status: nil,
            issue: nil,
            pipelineQueue: PipelineQueue(),
            onRecordMeeting: {},
            manualRecordingPendingOrActive: false,
            onStopManualRecording: nil,
            onOpenLastProtocol: {},
            onOpenProtocolsFolder: {},
            onOpenSettings: {},
            onOpenNotes: onOpenNotes,
            onNameSpeakers: nil,
            onQuit: {}, // swiftlint:disable:this trailing_closure
        )
    }

    func testNotesRowIsRendered() throws {
        let sut = makeView {}
        XCTAssertNoThrow(try sut.inspect().find(button: "Notes"))
    }

    func testNotesRowCallsOnOpenNotes() throws {
        var called = false
        let sut = makeView { called = true }
        try sut.inspect().find(button: "Notes").tap()
        XCTAssertTrue(called, "pressing the Notes row must call onOpenNotes")
    }
}
