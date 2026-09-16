import Foundation

/// Where the text in the notes panel is written.
///
/// A note always has exactly one target and the panel names it, so a note typed
/// with nothing recording can never be mistaken for a note on a meeting. The two
/// cases are the only two answers the app can give honestly: either a recording
/// is running, in which case its stem identifies the meeting whose `.md` the text
/// will end up in, or none is, in which case the text belongs to a day.
///
/// The live case carries `startedAt` so the panel's header can show when the
/// recording began without reaching back into `WatchLoop` — the panel is shown
/// and hidden independently of the recording lifecycle, and a controller that
/// had to ask the recorder for the start time every keystroke would be coupled
/// to it for one number that never changes.
enum NoteTarget: Equatable, Sendable {
    /// A recording in progress. `stem` is the recorder's own filename stem
    /// (`yyyyMMdd_HHmmss`), which is what makes the note findable from the
    /// recording's audio files and from a recovered job.
    case liveRecording(stem: String, startedAt: Date)
    /// No recording. The note belongs to this calendar day.
    case scratch(day: Date)

    /// The recording stem, or nil for a scratch note. The pipeline reads notes
    /// by stem, so this is also the answer to "will this text reach an `.md`".
    var recordingStem: String? {
        switch self {
        case let .liveRecording(stem, _): stem

        case .scratch: nil
        }
    }

    var isLive: Bool {
        recordingStem != nil
    }

    /// Recording start for the live case, the day for a scratch note. Used by
    /// the panel's header and by the scratch file's name.
    var referenceDate: Date {
        switch self {
        case let .liveRecording(_, startedAt): startedAt

        case let .scratch(day): day
        }
    }
}
