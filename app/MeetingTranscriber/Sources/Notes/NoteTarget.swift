import Foundation

/// Where the text in the notes panel is written.
///
/// A note always has exactly one target and the panel names it, so a note typed
/// with nothing recording can never be mistaken for a note on a meeting. The two
/// cases are the only two answers the app can give honestly: either a recording
/// is running, in which case its stem identifies the meeting whose `.md` the text
/// will end up in, or none is, in which case the text belongs to a day.
///
/// The live case carries `startedAt` so a meeting-relative timestamp can be
/// produced without reaching back into `WatchLoop` — the panel is shown and
/// hidden independently of the recording lifecycle, and a controller that had to
/// ask the recorder for the start time every keystroke would be coupled to it for
/// one number that never changes.
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

    /// Meeting-relative timestamp for insertion at the cursor (⌘T), or nil when
    /// there is no meeting to be relative to.
    ///
    /// Formatted like the transcript's own stamps (`[12:34]`, and `[1:02:03]`
    /// once a meeting passes an hour) so a note pasted beside a transcript line
    /// reads as the same kind of thing. A `now` earlier than the recording start
    /// yields `[00:00]` rather than a negative stamp: clocks and the panel are
    /// not synchronised, and a stamp of `[-00:01]` is worse than a rounded one.
    func elapsedStamp(at now: Date) -> String? {
        switch self {
        case let .liveRecording(_, startedAt):
            let elapsed: TimeInterval = now.timeIntervalSince(startedAt)
            return Self.stamp(elapsed: elapsed)

        case .scratch:
            return nil
        }
    }

    /// Hoisted out of `elapsedStamp` and explicitly typed throughout: the repo
    /// treats a function body over 300 ms of type-checking as a build error, and
    /// arithmetic-plus-interpolation in one expression is the shape that trips it.
    static func stamp(elapsed: TimeInterval) -> String {
        let clamped: Int = elapsed > 0 ? Int(elapsed) : 0
        let hours: Int = clamped / 3600
        let minutes: Int = (clamped % 3600) / 60
        let seconds: Int = clamped % 60
        let mm = String(format: "%02d", minutes)
        let ss = String(format: "%02d", seconds)
        if hours > 0 {
            return "[" + String(hours) + ":" + mm + ":" + ss + "]"
        }
        return "[" + mm + ":" + ss + "]"
    }
}
