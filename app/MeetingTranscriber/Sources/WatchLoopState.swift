import Foundation

/// Value-type snapshot of `WatchLoop`'s four observable fields. The class
/// keeps the fields as `@Observable` stored properties (so SwiftUI bindings
/// continue working); `WatchLoopState` is the form tests and other readers
/// (e.g. the RPC state snapshot) use for equality checks against a single
/// value rather than four field-wise comparisons.
struct WatchLoopState: Equatable {
    var phase: WatchLoop.State
    var lastError: String?
    var detail: String
    var manualRecordingInfo: ManualRecordingInfo?

    /// Initial state at `WatchLoop` construction. Matches the field
    /// defaults declared on the class — see `WatchLoop.init`.
    static let initial = Self(
        phase: .idle,
        lastError: nil,
        detail: "",
        manualRecordingInfo: nil,
    )
}

/// The read-only views of the loop's own state. They touch nothing private, so
/// they live next to the value type they produce rather than in `WatchLoop.swift`.
extension WatchLoop {
    var isActive: Bool {
        state != .idle
    }

    /// What the live recording captures, or nil when nothing is recording.
    /// The channel-health monitors need it: they see only per-channel levels,
    /// and -120 dBFS means both "never opened" and "stopped delivering".
    ///
    /// Derived from the fields the `.recording` transition publishes, not
    /// mirrored in a stored property. `apply` commits every field before it
    /// calls `onStateChange`, and the channel-health wiring reads this from
    /// inside that callback, so a stored mirror would have to be assigned
    /// before the phase in every start path. Missing that in one of them reads
    /// as nil and silently disables the indicator for that whole path, which is
    /// not a failure any of the flags downstream can distinguish from a quiet
    /// recording.
    var activeRecordingSource: RecordingSource? {
        guard state == .recording, let info = manualRecordingInfo else { return nil }
        if let pid = info.pid { return .forApp(pid: pid, noMic: noMic) }
        // A pid-less manual recording is either the microphone-only entry
        // point or "Record Meeting" — both target no single process, so
        // `pid` alone cannot tell them apart. `appName` can: it is never
        // user-supplied for either (`startMicrophoneRecording` and
        // `startMeetingRecording` always pass their own fixed
        // `ManualRecordingInfo` constant), so this reads the same fixed
        // identity the job and the record-only sidecar already agree on,
        // not user input that could collide with it.
        return info.appName == ManualRecordingInfo.meetingAppName
            ? .forSystem(noMic: noMic)
            : .micOnly
    }

    /// Value-type view of the four observable fields. Useful for tests,
    /// `AppState+RPC` snapshots, and as the input/output shape for the
    /// upcoming pure-function reducer slice.
    var snapshot: WatchLoopState {
        WatchLoopState(
            phase: state,
            lastError: lastError,
            detail: detail,
            manualRecordingInfo: manualRecordingInfo,
        )
    }
}
