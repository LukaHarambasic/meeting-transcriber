import Foundation

/// Everything derived from `customOutputDirBookmark`. The bookmark itself has to
/// stay a stored property on the class so `@Observable` can track it; the rest
/// lives here to keep `AppSettings.swift` under its `file_length` budget.
extension AppSettings {
    /// Resolved URL from the stored bookmark, or nil when none is set
    /// or the bookmark no longer resolves. Read-only: security-scoped *access*
    /// is the caller's job — every call site does its own paired
    /// `startAccessingSecurityScopedResource()` / `stopAccessing…`.
    ///
    /// A stale bookmark still resolves, so this deliberately does not repair it.
    /// `body` reads this through `effectiveOutputDir`, and repairing here would
    /// write to observed state from inside a view update. `repairStaleCustomOutputDirBookmark()`
    /// does that once at launch instead.
    var customOutputDir: URL? {
        var isStale = false
        return resolveCustomOutputDir(isStale: &isStale)
    }

    /// The effective output directory: custom choice or ~/Downloads/MeetingTranscriber/.
    var effectiveOutputDir: URL {
        customOutputDir ?? AppPaths.downloadsProtocolsDir
    }

    /// Store a user-selected directory as a bookmark (security-scoped in the
    /// sandboxed App Store build only, see `bookmarkCreationOptions`).
    func setCustomOutputDir(_ url: URL) {
        guard let data = makeBookmark(for: url) else { return }
        customOutputDirBookmark = data
    }

    /// Clear the custom output directory, reverting to the default.
    func clearCustomOutputDir() {
        customOutputDirBookmark = nil
    }

    /// Re-create the bookmark when macOS reports it stale (the folder moved or
    /// was renamed). Call once at launch, off the view-update path — see the note
    /// on `customOutputDir`. No-op when no bookmark is set or it still resolves.
    func repairStaleCustomOutputDirBookmark() {
        var isStale = false
        guard let url = resolveCustomOutputDir(isStale: &isStale), isStale,
              let refreshed = makeBookmark(for: url)
        else { return }
        customOutputDirBookmark = refreshed
    }

    // MARK: - Helpers

    private func resolveCustomOutputDir(isStale: inout Bool) -> URL? {
        guard let data = customOutputDirBookmark else { return nil }
        return try? URL(
            resolvingBookmarkData: data,
            options: Self.bookmarkResolutionOptions,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale,
        )
    }

    private func makeBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(
            options: Self.bookmarkCreationOptions,
            includingResourceValuesForKeys: nil,
            relativeTo: nil,
        )
    }

    // Security scope only where a sandbox needs it. A security-scoped bookmark
    // is tied to the code signature of the app that made it, and the Homebrew
    // build is ad-hoc signed, so every rebuild is a different app to macOS:
    // resolving with `.withSecurityScope` then fails ("isn't in the correct
    // format") and the output folder silently fell back to Downloads after an
    // install. That build is not sandboxed, so plain bookmarks are enough, and a
    // plain resolution also reads the scoped bookmarks older builds stored.
    #if APPSTORE
        private static let bookmarkResolutionOptions: URL.BookmarkResolutionOptions = .withSecurityScope
        private static let bookmarkCreationOptions: URL.BookmarkCreationOptions = .withSecurityScope
    #else
        private static let bookmarkResolutionOptions: URL.BookmarkResolutionOptions = []
        private static let bookmarkCreationOptions: URL.BookmarkCreationOptions = []
    #endif
}
