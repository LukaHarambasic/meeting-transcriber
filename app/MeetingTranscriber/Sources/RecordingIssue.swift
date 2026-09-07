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
        case openNotifications

        /// Pane to open, or nil if the URL literal failed to parse (see
        /// `SystemSettingsPaths`). A nil drops the button and keeps the text.
        var settingsURL: URL? {
            switch self {
            case .openScreenRecording: SystemSettingsPaths.screenRecordingURL
            case .openMicrophone: SystemSettingsPaths.microphoneURL
            case .openNotifications: SystemSettingsPaths.notificationsURL
            }
        }

        var buttonTitle: String {
            switch self {
            case .openScreenRecording: "Open Screen Recording Settings"
            case .openMicrophone: "Open Microphone Settings"
            case .openNotifications: "Open Notifications Settings"
            }
        }
    }

    /// The whole message, in one line. There is deliberately no second
    /// explanatory field: the headline plus `remedy`'s button title already say
    /// what is wrong and what to do, and a sentence restating the consequence
    /// only widened the menu — a menu sizes itself to its widest item.
    let headline: String
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
    /// dead capture channel comes next after that — that recording is running,
    /// and is producing at least one usable track.
    ///
    /// `askUnanswerable` comes last, and deliberately after every other case
    /// including the silent channels, because it blocks nothing: the recording
    /// this ask belongs to is running (or already finished) and complete, and
    /// what is degraded is only the unattended-recording safeguard that would
    /// otherwise have stopped it unasked. A silent capture channel, by
    /// contrast, is costing real audio right now, on the very recording the
    /// menu is describing — that is strictly more urgent than a safeguard that
    /// stayed off, and must win the one line the menu has room for.
    ///
    /// - Parameters:
    ///   - permissionProblems: `HealthCheckResult.problems`, in its own order.
    ///   - recordingError: `WatchLoop.lastError`, cleared when the next
    ///     recording starts, so this only ever names the most recent failure.
    ///   - micSilent: the mic channel is silent while the other carries audio.
    ///   - appSilent: the app-audio channel is silent while the mic carries it.
    ///   - askUnanswerable: a "Still recording?" ask was posted during this
    ///     recording and the system could not show it (notifications
    ///     suppressed), so the automatic stop that ask would otherwise have
    ///     armed stayed off for this recording.
    static func compose(
        permissionProblems: [PermissionProblem],
        recordingError: String?,
        micSilent: Bool,
        appSilent: Bool,
        askUnanswerable: Bool,
    ) -> RecordingIssue? {
        if let problem = permissionProblems.first {
            return RecordingIssue(
                headline: problem.description,
                remedy: remedy(for: problem),
            )
        }
        if let recordingError, !recordingError.isEmpty {
            // The error itself is the headline: "Last recording failed" plus a
            // separate detail line said less, in two rows, than the message does
            // in one.
            return RecordingIssue(headline: recordingError, remedy: nil)
        }
        if micSilent {
            return RecordingIssue(headline: "Microphone is silent", remedy: .openMicrophone)
        }
        if appSilent {
            return RecordingIssue(headline: "App audio is silent", remedy: .openScreenRecording)
        }
        if askUnanswerable {
            return RecordingIssue(
                // Names the cause as well as the consequence, because the
                // remedy button opens the Notifications pane and a headline
                // that mentioned only the consequence left that button
                // unexplained.
                headline: "Notifications are off, so this recording won't stop on its own.",
                remedy: .openNotifications,
            )
        }
        return nil
    }

    private static func remedy(for problem: PermissionProblem) -> Remedy {
        switch problem {
        case .screenRecordingDenied, .screenRecordingBroken: .openScreenRecording
        case .microphoneDenied, .microphoneBroken: .openMicrophone
        }
    }
}
