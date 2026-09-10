import Foundation

/// Decides where a note being typed right now belongs.
///
/// Pure and tiny on purpose: three different callers (the panel on open, a
/// recording start/stop transition, and the automation API) all need the same
/// answer for the same inputs, and a note must always resolve to somewhere —
/// there is no "don't know yet" target.
enum NoteTargetPolicy {
    /// `recordingStem` and `recordingStartedAt` describe the recorder's
    /// current state. A recording in progress supplies both together, so
    /// `.liveRecording` is returned only when both are present.
    ///
    /// The two partial cases are decided deliberately rather than left to
    /// crash:
    /// - a stem with no start date would produce a live target whose
    ///   `elapsedStamp` has nothing to be relative to, so it falls back to
    ///   `.scratch`;
    /// - a start date with no stem (the recording just stopped, or one that
    ///   was never given a stem) cannot be found again by the pipeline, which
    ///   reads notes by stem — so it also falls back to `.scratch`.
    ///
    /// Either way the note still lands somewhere: a day's scratch file, never
    /// nowhere.
    static func target(recordingStem: String?, recordingStartedAt: Date?, now: Date) -> NoteTarget {
        if let stem = recordingStem, let startedAt = recordingStartedAt {
            return .liveRecording(stem: stem, startedAt: startedAt)
        }
        return .scratch(day: now)
    }
}
