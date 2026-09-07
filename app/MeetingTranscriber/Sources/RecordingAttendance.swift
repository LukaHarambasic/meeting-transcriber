import Foundation

/// What the capture levels say about whether anyone is still in the meeting,
/// as `RecordingConfirmationPolicy` consumes it.
///
/// This exists because the still-recording check used to decide entirely on
/// whether a notification had been answered, and stopped a live 55-minute
/// meeting at 35 minutes because the ask was never delivered (the app's
/// notifications were muted at the OS level, and `.timeSensitive` needs a
/// provisioning profile this machine does not have — see
/// `NotificationUrgency` and `scripts/lib/signing.sh`). Speech on either
/// channel is direct evidence the recording is wanted, and it is evidence the
/// app already had: `ChannelHealthController` polls per-channel dBFS at 10 Hz
/// and `SilentRecordingMonitor` already classifies it against a speech
/// threshold. The check was simply never shown it.
///
/// Three cases rather than an optional `Date`, because "no speech seen while
/// watching" and "not watching" must decide differently. The first is the
/// abandoned-recording case the whole feature exists for. The second cannot
/// prove absence, so it falls back to the ask-and-stop behaviour instead of
/// quietly disabling the runaway guard whenever the level indicator is off.
enum RecordingAttendance: Equatable {
    /// Speech was last heard on either channel at this time.
    case lastSpeech(Date)

    /// Levels are being read, and no speech has been heard for the whole
    /// recording so far. The abandoned-room case.
    case noSpeechObserved

    /// No level data at all: the level indicator is disabled, or the recorder
    /// went away. Silence can be neither proven nor ruled out.
    case unmonitored
}

/// Whether the still-recording ask can actually reach the user.
///
/// Load-bearing, not diagnostic. The policy stops a recording only when an ask
/// went unanswered, and "unanswered" is only meaningful if it was *asked*. A
/// suppressed notification produces an identical silence to an absent user, so
/// without this the app reads its own delivery failure as the user's absence
/// and stops the recording — which is exactly what happened.
///
/// `unknown` is treated as undeliverable on purpose. The cost of assuming
/// delivery wrongly is a stopped meeting; the cost of assuming suppression
/// wrongly is a recording that keeps running until the four-hour cap and says
/// so in the menu. Those are not comparable.
enum AskDeliverability: Equatable {
    /// The system will show an alert for this app.
    case deliverable

    /// Notifications are off, or alerts are disabled, for this app.
    case suppressed

    /// Not yet queried, or the query failed.
    case unknown

    /// Whether an unanswered ask may be read as a real answer.
    ///
    /// A computed property rather than `== .deliverable` at each call site, so
    /// the `unknown` policy above lives in one place instead of being
    /// re-decided by every caller.
    var canBeAnswered: Bool {
        self == .deliverable
    }
}
