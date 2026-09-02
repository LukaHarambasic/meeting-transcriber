@testable import AudioTapLib
import XCTest

/// The pane name is version-dependent (macOS 15 renamed "Screen Recording" to
/// "Screen & System Audio Recording") and shared by the tap-error hint, the
/// permission UI, and the channel-health notification, so it is worth pinning.
final class SystemSettingsPathsTests: XCTestCase {
    func testScreenRecordingPathUsesSequoiaPaneName() {
        XCTAssertEqual(
            SystemSettingsPaths.screenRecordingPath(sequoiaOrLater: true),
            "System Settings → Privacy & Security → Screen & System Audio Recording",
        )
    }

    func testScreenRecordingPathUsesLegacyPaneNameBeforeSequoia() {
        XCTAssertEqual(
            SystemSettingsPaths.screenRecordingPath(sequoiaOrLater: false),
            "System Settings → Privacy & Security → Screen Recording",
        )
    }

    func testScreenRecordingResolvesToAKnownPane() {
        // The OS-resolved value must match one of the two version branches.
        let resolved = SystemSettingsPaths.screenRecording
        XCTAssertTrue(
            resolved == SystemSettingsPaths.screenRecordingPath(sequoiaOrLater: true)
                || resolved == SystemSettingsPaths.screenRecordingPath(sequoiaOrLater: false),
        )
    }

    // MARK: - Deep links

    /// Pins the **modern** pane identifier against the legacy
    /// `com.apple.preference.security` that most snippets on the subject still
    /// use. The legacy form addresses a System *Preferences* pane that stopped
    /// existing in macOS 13 and has only worked since through a compatibility
    /// remap; the modern identifier is what
    /// `/System/Library/ExtensionKit/Extensions/SecurityPrivacyExtension.appex`
    /// actually reports, and it predates this library's OS floor.
    ///
    /// Worth a test because the failure is silent in the worst way: a
    /// well-formed URL naming a pane that no longer exists still parses, so
    /// `RecordingIssue` renders its button and clicking it does nothing.
    func testDeepLinksUseTheModernPaneIdentifier() throws {
        for url in [SystemSettingsPaths.screenRecordingURL, SystemSettingsPaths.microphoneURL] {
            let resolved = try XCTUnwrap(url, "a nil URL silently drops the remedy button")
            XCTAssertEqual(resolved.scheme, "x-apple.systempreferences")
            XCTAssertTrue(
                resolved.absoluteString.contains("com.apple.settings.PrivacySecurity.extension"),
                "expected the modern pane id, got \(resolved.absoluteString)",
            )
            XCTAssertFalse(
                resolved.absoluteString.contains("com.apple.preference.security"),
                "the legacy System Preferences pane id relies on a compatibility remap",
            )
        }
    }

    /// The two links must open *different* panes — a copy-paste that pointed
    /// both at Screen Recording would send someone chasing the wrong grant.
    func testEachDeepLinkTargetsItsOwnAnchor() throws {
        let screen = try XCTUnwrap(SystemSettingsPaths.screenRecordingURL)
        let mic = try XCTUnwrap(SystemSettingsPaths.microphoneURL)
        XCTAssertTrue(screen.absoluteString.hasSuffix("?Privacy_ScreenCapture"))
        XCTAssertTrue(mic.absoluteString.hasSuffix("?Privacy_Microphone"))
        XCTAssertNotEqual(screen, mic)
    }
}
