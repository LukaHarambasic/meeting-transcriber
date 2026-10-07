import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "NotesStore")

/// File-backed `NotesStoring`.
///
/// `outputDir` arrives as a closure rather than a value because the user can
/// change the Output Folder while the app is running and a scratch note
/// written mid-session must land wherever the setting currently points, not
/// wherever it pointed when the store was constructed.
///
/// Internally serialised with a lock (never `async`, so `NSLock` is safe to
/// take directly — see `withLock`) because three callers reach this from
/// different actors: the panel on every keystroke, the recording-stop path,
/// and the automation API.
final class NotesStore: NotesStoring, @unchecked Sendable {
    private let recordingsDir: URL
    private let outputDir: () -> URL
    private let lock = NSLock()

    private static let scratchSubdirectory = "notes"
    private static let scratchDayFormatter = DateFormatter.filenameStamp("yyyy-MM-dd")

    init(recordingsDir: URL, outputDir: @escaping () -> URL) {
        self.recordingsDir = recordingsDir
        self.outputDir = outputDir
    }

    func load(_ target: NoteTarget) -> String {
        withLock { readLocked(target) }
    }

    /// Called on every keystroke, so the write itself must be cheap and must
    /// never leave a half-written file: `write(atomically: true)` stages to a
    /// temp file and renames, the same shape `ProtocolGenerator.saveProtocol`
    /// already uses for the same reason.
    func save(_ text: String, to target: NoteTarget) {
        withLock { writeLocked(text, to: target) }
    }

    /// The notes for a finished recording, removed as they are handed over.
    ///
    /// Read-and-clear, because the text is about to become part of the job and a
    /// copy left in the staging directory would be picked up a second time by
    /// orphan recovery. Returns nil when the recording has no notes, which is the
    /// common case and not an error.
    func take(stem: String) -> String? {
        withLock {
            let url = liveRecordingURL(stem: stem)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            try? FileManager.default.removeItem(at: url)
            return text
        }
    }

    func fileURL(for target: NoteTarget) -> URL {
        switch target {
        case let .liveRecording(stem, _):
            liveRecordingURL(stem: stem)

        case let .scratch(day):
            scratchURL(day: day)
        }
    }

    // MARK: - Locked helpers (call only from inside `withLock`)

    private func readLocked(_ target: NoteTarget) -> String {
        withScratchAccess(target) {
            let url = fileURL(for: target)
            return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
    }

    private func writeLocked(_ text: String, to target: NoteTarget) {
        withScratchAccess(target) {
            let url = fileURL(for: target)
            let dir = url.deletingLastPathComponent()
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
                try FileManager.default.restrictToOwner(url)
            } catch {
                logger.error("Failed to write notes to \(url.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func liveRecordingURL(stem: String) -> URL {
        recordingsDir.appendingPathComponent(stem + RecordingFileSuffix.notes)
    }

    private func scratchURL(day: Date) -> URL {
        outputDir()
            .appendingPathComponent(Self.scratchSubdirectory, isDirectory: true)
            .appendingPathComponent(Self.scratchDayFormatter.string(from: day) + ".md")
    }

    /// Wraps `body` with `startAccessingSecurityScopedResource()` on the
    /// user-picked Output Folder, for a scratch target only — a live
    /// recording writes into the app's own staging directory and needs no
    /// scope.
    ///
    /// Must call access on `outputDir()` itself, never on the `notes`
    /// subdirectory beneath it: a security-scoped bookmark only grants access
    /// on the exact URL it resolved to, and starting access on a child path
    /// silently fails inside the App Store sandbox while appearing to work in
    /// the unsandboxed Homebrew build (the same trap `RecordOnlyDestination`
    /// documents for recordings).
    private func withScratchAccess<T>(_ target: NoteTarget, _ body: () -> T) -> T {
        guard case .scratch = target else { return body() }
        let root = outputDir()
        let accessing = root.startAccessingSecurityScopedResource()
        defer { if accessing { root.stopAccessingSecurityScopedResource() } }
        return body()
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
