import Foundation

/// Reading and writing the notes text for a target.
///
/// A protocol rather than a concrete type so the panel's controller can be
/// tested without touching the disk. The recording stop path reads and clears a
/// finished recording's notes through the concrete `NotesStore.take(stem:)`,
/// which is why that call is not part of this protocol.
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

    /// Where `target`'s text lives. Exposed so a driver and the recording
    /// pipeline can find a note file without duplicating the naming rule.
    func fileURL(for target: NoteTarget) -> URL
}
