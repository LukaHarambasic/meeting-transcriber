@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// Interaction + write-back tests for non-button Settings controls (Picker,
/// Stepper) and a first LiveCaptionsOverlay render test. The existing suite drove
/// only Toggle `.tap()`; Picker `.select()` / Stepper `.increment()` / the
/// captions TimelineView had zero coverage. Each control is driven and the
/// resulting `AppSettings` write-back (or rendered identifier) is asserted, so a
/// broken binding — not just a missing control — fails the test.
@MainActor
final class SettingsInteractionTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var defaults: UserDefaults!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        // Isolated per-test suite (pid+uuid) so a killed test never leaks into the
        // dev app's `.standard` plist — mirrors SettingsViewTests.
        suiteName = "SettingsInteractionTests-\(getpid())-\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: suiteName) else {
            XCTFail("could not create test UserDefaults suite")
            return
        }
        defaults = suite
    }

    override func tearDown() async throws {
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    private func makeSettings() -> AppSettings {
        AppSettings(defaults: defaults)
    }

    // MARK: - Picker write-back

    func testEnginePickerSelectionWritesBackToSettings() throws {
        let settings = makeSettings()
        settings.transcriptionEngine = .whisperKit
        let view = TranscriptionSettingsView(
            settings: settings,
            whisperKitEngine: WhisperKitEngine(),
            parakeetEngine: ParakeetEngine(),
        )

        let picker = try view.inspect().find(ViewType.Picker.self) { picker in
            try picker.labelView().text().string() == "Engine"
        }
        try picker.select(value: TranscriptionEngineSetting.parakeet)

        XCTAssertEqual(settings.transcriptionEngine, .parakeet, "selecting the picker value must flip the setting")
    }

    func testLLMProviderPickerSelectionWritesBackToSettings() throws {
        let settings = makeSettings()
        settings.protocolProvider = .none
        let view = OutputSettingsView(settings: settings)

        let picker = try view.inspect().find(ViewType.Picker.self) { picker in
            try picker.labelView().text().string() == "LLM Provider"
        }
        try picker.select(value: ProtocolProvider.openAICompatible)

        XCTAssertEqual(settings.protocolProvider, .openAICompatible)
    }

    // MARK: - Toggle write-back

    /// Asserts the opposite of what the control showed rather than a fixed value,
    /// so moving the default breaks no test about wiring. The default has its
    /// own test beside the call-end rule's.
    func testAutoStopWhenCallEndsToggleWritesBackToSettings() throws {
        let settings = makeSettings()
        let before = settings.autoStopWhenCallEnds
        let view = GeneralSettingsView(settings: settings)

        let body = try view.inspect()
        XCTAssertNoThrow(try body.find(viewWithAccessibilityIdentifier: A11yID.autoStopWhenCallEndsToggle))
        // Located by label like the other bare-`Toggle` tests: a `Toggle` that
        // carries the identifier itself is not a container to search below.
        let toggle = try body.find(ViewType.Toggle.self) { toggle in
            try toggle.labelView().text().string() == "Stop recording when the call ends"
        }
        try toggle.tap()

        XCTAssertEqual(settings.autoStopWhenCallEnds, !before, "the control must write the opposite of what it showed")
    }

    // MARK: - LiveCaptionsOverlay render

    func testLiveCaptionsOverlayBackendIdentifierTracksActiveBackend() throws {
        let state = LiveCaptionsState()
        state.applyFinalized("hello", channel: .mic)

        // No active backend → the backend label (inside the TimelineView) is absent.
        XCTAssertThrowsError(
            try LiveCaptionsOverlay(state: state).inspect()
                .find(viewWithAccessibilityIdentifier: A11yID.liveCaptionBackend),
            "with no active backend the label must not render",
        )

        // Active backend → the label appears, reachable through the TimelineView.
        state.setActiveBackend("Parakeet EOU")
        XCTAssertNoThrow(
            try LiveCaptionsOverlay(state: state).inspect()
                .find(viewWithAccessibilityIdentifier: A11yID.liveCaptionBackend),
            "an active backend must render the label",
        )
    }
}
