@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// Settings → Notes: one wiring test per control, per the rule that the view
/// layer is pinned for wiring and nothing else (logic states live at the
/// `AppSettings` layer, not enumerated through the view).
@MainActor
final class NotesSettingsTests: XCTestCase {
    private func freshSettings() -> AppSettings {
        let defaults = UserDefaults(suiteName: "notes-settings-\(UUID().uuidString)")!
        // swiftlint:disable:previous force_unwrapping
        return AppSettings(defaults: defaults)
    }

    func testViewRendersWithDefaultSettings() throws {
        let settings = freshSettings()
        let view = NotesSettingsView(settings: settings)
        XCTAssertNoThrow(try view.inspect())
    }

    func testHotkeyToggleWritesBackToSettings() throws {
        let settings = freshSettings()
        let before = settings.notesHotkeyEnabled
        let view = NotesSettingsView(settings: settings)
        let toggle = try view.inspect().find(viewWithAccessibilityIdentifier: A11yID.notesHotkeyToggle)
        try toggle.find(ViewType.Toggle.self).tap()
        XCTAssertEqual(
            settings.notesHotkeyEnabled, !before,
            "the control must write the opposite of what it showed",
        )
    }

    func testFeedToProtocolToggleWritesBackToSettings() throws {
        let settings = freshSettings()
        let before = settings.notesFeedToProtocol
        let view = NotesSettingsView(settings: settings)
        let toggle = try view.inspect().find(viewWithAccessibilityIdentifier: A11yID.notesFeedToProtocolToggle)
        try toggle.find(ViewType.Toggle.self).tap()
        XCTAssertEqual(
            settings.notesFeedToProtocol, !before,
            "the control must write the opposite of what it showed",
        )
    }
}
