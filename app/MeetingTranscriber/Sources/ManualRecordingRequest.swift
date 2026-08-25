import Foundation

/// What the user asked `WatchingController` to record by hand.
///
/// The menu entry points differ only in what they target, and everything
/// around the start (the ownership guards, settling an in-flight start,
/// building the loop, the notification) is identical. Carrying the difference
/// as a value keeps that shared body in one place instead of copies that
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
    /// asking for.
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

    /// A permission this recording needs is denied or broken, so nothing was
    /// captured. Raised by `WatchLoop`'s own gate, so the refusal names the
    /// permission that actually blocks *this* source.
    case permissionRefused

    /// The recorder itself would not start.
    case failed
}
