import Foundation

/// User-facing macOS System Settings navigation paths, kept in one place so the
/// tap-error hint, the permission UI, and the channel-health notification all
/// name the pane identically. macOS 15 (Sequoia) renamed the "Screen Recording"
/// pane to "Screen & System Audio Recording"; the app supports macOS 14.2+, so
/// the correct label depends on the running OS.
public enum SystemSettingsPaths {
    /// Path to the pane that gates screen capture and system-audio recording —
    /// the permission the CATapDescription process tap needs (or falls back to).
    /// Callers add their own lead-in / trailing action text.
    public static var screenRecording: String {
        let sequoiaOrLater = if #available(macOS 15, *) {
            true
        } else {
            false
        }
        return screenRecordingPath(sequoiaOrLater: sequoiaOrLater)
    }

    /// Pure form of ``screenRecording`` so both OS branches are unit-testable
    /// without faking the running OS version.
    static func screenRecordingPath(sequoiaOrLater: Bool) -> String {
        let pane = sequoiaOrLater ? "Screen & System Audio Recording" : "Screen Recording"
        return "System Settings → Privacy & Security → \(pane)"
    }

    /// Bundle identifier of the Privacy & Security pane in System Settings.
    ///
    /// The **modern** identifier, deliberately, not the widely-copied legacy
    /// `com.apple.preference.security`. That legacy form addresses a System
    /// *Preferences* pane that stopped existing in macOS 13 and has only worked
    /// since through a compatibility remap — a remap with no guarantee behind
    /// it, and one this app cannot afford to bet a button on. Checked on
    /// macOS 26: `/System/Library/ExtensionKit/Extensions/SecurityPrivacyExtension.appex`
    /// reports exactly this identifier, and it has existed since macOS 13,
    /// which is below this app's 14.2 floor — so the modern form is available
    /// on every OS the app supports and needs no fallback.
    ///
    /// A dead URL would be the worst outcome here: `RecordingIssue` renders the
    /// button only when the URL parses, so a bad *scheme* drops the button
    /// honestly, but a well-formed URL naming a pane that no longer exists gives
    /// the user a button that silently does nothing.
    private static let privacyPaneID = "com.apple.settings.PrivacySecurity.extension"

    /// Deep link that opens the Screen Recording pane directly.
    ///
    /// Lives next to the label rather than at the call site for the same reason
    /// the label does: a UI that prints one pane's name and opens another is
    /// worse than one that only prints. The anchor (`Privacy_ScreenCapture`) is
    /// unchanged by the Sequoia rename, so unlike the label this needs no OS
    /// branch. Force-unwrapping is avoided even though the literal is constant —
    /// a nil here means no button rather than a crash in the menu bar.
    public static var screenRecordingURL: URL? {
        settingsURL(anchor: "Privacy_ScreenCapture")
    }

    /// Deep link that opens the Microphone pane directly. See
    /// ``screenRecordingURL`` for why this is a URL rather than a bare string.
    public static var microphoneURL: URL? {
        settingsURL(anchor: "Privacy_Microphone")
    }

    /// Both anchors are advertised by the pane binary on macOS 26, and both
    /// predate the app's OS floor. `internal` so a test can pin the shape
    /// without the two public accessors having to agree by copy-paste.
    static func settingsURL(anchor: String) -> URL? {
        URL(string: "x-apple.systempreferences:\(privacyPaneID)?\(anchor)")
    }
}
