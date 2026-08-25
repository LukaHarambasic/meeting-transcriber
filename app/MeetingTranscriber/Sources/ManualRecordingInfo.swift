import Foundation

/// Info about a manually started recording session.
struct ManualRecordingInfo: Equatable {
    /// The process being recorded, or nil for a microphone-only recording,
    /// which targets no process at all. Also what the monitor watches: with no
    /// PID there is nothing that can exit, so only the duration cap ends it.
    let pid: pid_t?
    let appName: String
    let title: String
}

extension ManualRecordingInfo {
    /// Identity for a microphone-only recording (issue #633). There is no app
    /// to name and no window title to read, and the recording's file stem
    /// already carries the timestamp, so one fixed pair stays unambiguous
    /// across sessions. Named constants rather than literals because the job,
    /// the record-only sidecar and the tests all have to agree on them.
    static let microphoneAppName = "Microphone"
    static let microphoneTitle = "Microphone Recording"

    /// Identity for a "Record Meeting" (system-wide) recording, for the same
    /// reason as the microphone pair above: there is no single app to name, and
    /// the job, the record-only sidecar and the tests all have to agree.
    static let meetingAppName = "Meeting"
    static let meetingTitle = "Meeting Recording"
}
