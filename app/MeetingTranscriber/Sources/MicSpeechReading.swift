import Foundation

/// What the live speech detector on the microphone has heard in the current
/// recording, as the quiet-room rule consumes it.
///
/// Two cases rather than an optional date, because "not listening" and
/// "listening, nothing heard yet" decide differently: the first is no evidence
/// at all and can never stop a recording, while the second is exactly the
/// empty-room case once it has lasted long enough.
enum MicSpeechReading: Equatable {
    /// No detector is running for this recording: the recording has no
    /// microphone channel, the speech model is still loading, or it failed to
    /// load.
    case unavailable
    /// The detector has been running since `since`. `lastSpeech` is when it
    /// last heard speech, or nil when it has heard none since it started.
    case listening(since: Date, lastSpeech: Date?)
}
