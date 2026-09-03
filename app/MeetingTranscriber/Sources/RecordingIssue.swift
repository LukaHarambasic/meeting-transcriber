import AudioTapLib
import Foundation

/// The one thing currently standing between the user and a working recording,
/// in the form the menu bar renders it: a headline, the detail behind it, and
/// the settings pane that fixes it.
///
/// This exists because the app had no way to say *what* was wrong. Every
/// problem — a denied grant, a failed stop, a dead capture channel — was
/// signalled the same way, by a red mark on the menu-bar icon, while the menu
/// itself said only "Idle". A denied Screen Recording grant refuses every
/// recording that taps an app (`HealthCheckResult.recordingRefusalReason`), and
/// the entire report of that refusal was a notification banner that had
/// auto-dismissed by the time anyone opened the menu to ask why nothing
/// happened. The badge says *that* something is wrong; this says *what*, and
/// stays on screen until it is fixed.
struct RecordingIssue: Equatable {
    /// Where the user goes to fix it, for the problems a settings pane can fix.
    /// `nil` on `RecordingIssue.remedy` means the detail text is the whole
    /// remedy — there is no pane that would help.
    enum Remedy: Equatable {
        case openScreenRecording
        case openMicrophone

        /// Pane to open, or nil if the URL literal failed to parse (see
        /// `SystemSettingsPaths`). A nil drops the button and keeps the text.
        var settingsURL: URL? {
            switch self {
            case .openScreenRecording: SystemSettingsPaths.screenRecordingURL
            case .openMicrophone: SystemSettingsPaths.microphoneURL
            }
        }

        var buttonTitle: String {
            switch self {
            case .openScreenRecording: "Open Screen Recording Settings"
            case .openMicrophone: "Open Microphone Settings"
            }
        }
    }

    let headline: String
    let detail: String
    let remedy: Remedy?
}

extension RecordingIssue {
    /// The single most important problem right now, or nil when there is none.
    ///
    /// One issue rather than a list: the menu bar has room for one line the user
    /// will actually read, and a stack of three problems reads as noise where
    /// one reads as an instruction.
    ///
    /// Precedence is by what blocks a recording from *starting*, not by
    /// severity. A missing grant comes first because it refuses the recording
    /// outright and is the only entry here the user can fix in ten seconds. A
    /// recording error comes next: it names a recording that already failed. A
    /// dead capture channel comes last — that recording is running, and is
    /// producing at least one usable track.
    ///
    /// - Parameters:
    ///   - permissionProblems: `HealthCheckResult.problems`, in its own order.
    ///   - recordingError: `WatchLoop.lastError`, cleared when the next
    ///     recording starts, so this only ever names the most recent failure.
    ///   - micSilent: the mic channel is silent while the other carries audio.
    ///   - appSilent: the app-audio channel is silent while the mic carries it.
    static func compose(
        permissionProblems: [PermissionProblem],
        recordingError: String?,
        micSilent: Bool,
        appSilent: Bool,
    ) -> RecordingIssue? {
        if let problem = permissionProblems.first {
            return RecordingIssue(
                headline: problem.description,
                detail: permissionDetail(for: problem),
                remedy: remedy(for: problem),
            )
        }
        if let recordingError, !recordingError.isEmpty {
            return RecordingIssue(
                headline: "Last recording failed",
                detail: recordingError,
                remedy: nil,
            )
        }
        if micSilent {
            return RecordingIssue(
                headline: "Microphone is silent",
                detail: ChannelHealthController.asymmetricSilenceMessage(for: .mic),
                remedy: .openMicrophone,
            )
        }
        if appSilent {
            return RecordingIssue(
                headline: "App audio is silent",
                detail: ChannelHealthController.asymmetricSilenceMessage(for: .app),
                remedy: .openScreenRecording,
            )
        }
        return nil
    }

    /// What a denied or broken grant actually costs, in one short sentence.
    ///
    /// Deliberately short. This renders as a row in the menu-bar dropdown, and
    /// a menu sizes itself to its widest item: the first version named the full
    /// System Settings path here and stretched the whole menu across the
    /// screen. The path belongs on the button that opens it, not in prose, and
    /// the restart hint belongs nowhere until it is true (a `.broken` grant
    /// carries its own toggle-off-and-on remedy in
    /// `PermissionProblem.description`, which is already the headline).
    private static func permissionDetail(for problem: PermissionProblem) -> String {
        switch problem {
        case .screenRecordingDenied, .screenRecordingBroken:
            "Recording is refused without it."

        case .microphoneDenied, .microphoneBroken:
            "Your own voice will not be recorded."
        }
    }

    private static func remedy(for problem: PermissionProblem) -> Remedy {
        switch problem {
        case .screenRecordingDenied, .screenRecordingBroken: .openScreenRecording
        case .microphoneDenied, .microphoneBroken: .openMicrophone
        }
    }
}
