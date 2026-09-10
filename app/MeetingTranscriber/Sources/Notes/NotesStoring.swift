import Foundation

/// Reading and writing the notes text for a target.
///
/// A protocol rather than a concrete type because three unrelated callers reach
/// it — the panel (every keystroke), the recording stop path (read-and-clear),
/// and the automation API (append without knowing the current text) — and only
/// the last two can be exercised without a window on screen.
///
/// Synchronous and `Sendable` rather than `@MainActor`: the stop path and the RPC
/// handler are not the panel's actor, and notes files are a few kilobytes, so an
/// atomic write costs less than the ceremony of hopping actors to perform it.
/// Implementations must therefore be internally serialised.
protocol NotesStoring: Sendable {
    /// The whole current text for `target`, or empty when there is none.
    func load(_ target: NoteTarget) -> String

    /// Replace `target`'s text. Called on every keystroke, so it must be cheap
    /// and must never leave a partially written file behind.
    func save(_ text: String, to target: NoteTarget)

    /// Add a block to `target` without needing its current text — the shape the
    /// automation API needs, and the only safe one while the panel is open and
    /// owns the buffer.
    func append(_ text: String, to target: NoteTarget)

    /// The notes for a finished recording, removed as they are handed over.
    ///
    /// Read-and-clear, because the text is about to become part of the job and a
    /// copy left in the staging directory would be picked up a second time by
    /// orphan recovery. Returns nil when the recording has no notes, which is the
    /// common case and not an error.
    func take(stem: String) -> String?

    /// Where `target`'s text lives. Exposed so a driver and the recording
    /// pipeline can find a note file without duplicating the naming rule.
    func fileURL(for target: NoteTarget) -> URL
}
