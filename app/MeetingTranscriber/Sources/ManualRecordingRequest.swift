import Foundation

/// What the user asked `WatchingController` to record by hand.
///
/// The two menu entry points differ only in what they target, and everything
/// around the start (the ownership guards, settling a racing auto start,
/// building the loop, the notification) is identical. Carrying the difference
/// as a value keeps that shared body in one place instead of two copies that
/// drift.
enum ManualRecordingRequest {
    case app(pid: pid_t, appName: String, title: String)
    case microphone

    /// "Record Meeting": the whole system output plus the microphone, for an
    /// in-room meeting playing through the speakers rather than any one app.
    case meeting
}

extension ManualRecordingRequest {
    /// Whether this request opens a CATap process/system tap. `.app` and
    /// `.meeting` both do; only `.microphone` opens no tap at all. Read before
    /// a manual start to decide whether the Screen Recording grant needs
    /// asking for — the one such start has no up-front moment for, unlike
    /// `startWatching`.
    var capturesAppAudio: Bool {
        switch self {
        case .app, .meeting: true
        case .microphone: false
        }
    }
}

/// How a manual-recording start ended.
///
/// The menu ignores it — a click is fire-and-forget and learns the outcome from
/// the notification the start path already posts. The automation API cannot:
/// it has to answer the caller with a status code, and "the microphone is
/// denied" and "the recorder failed" are a different answer to the same POST.
/// Retrying the first changes nothing until someone opens System Settings,
/// which is exactly the line between 412 and 503.
enum ManualRecordingStartResult: Equatable {
    case started

    /// A recording was already in progress when the start reached the point of
    /// taking the loop over. Decided there rather than only at the caller's
    /// guard, because that guard runs before the task is scheduled and the watch
    /// loop can enter a meeting in between.
    case blockedByActiveRecording

    /// A permission this recording needs is denied or broken, so nothing was
    /// captured. Raised by `WatchLoop` from the same gate the auto-detect path
    /// uses, rather than re-derived here, so the refusal names the permission
    /// that actually blocks *this* source.
    case permissionRefused

    /// The recorder itself would not start.
    case failed
}
