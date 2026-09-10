import AppKit

/// Makes the notes panel invisible to screen capture (Zoom/Teams share, or a
/// manual screenshot) and keeps it available across every Space, including a
/// full-screen one — the same recipe `NamingWindowPolicy` uses for the
/// speaker-naming window, applied here to the notes panel.
///
/// `sharingType = .none` is the load-bearing property. Measured on this
/// machine (macOS 26.5): a `.none` window is entirely absent from a
/// full-screen `screencapture` (the content behind it composites through, it
/// is not blacked out), while an otherwise identical `.readOnly` window
/// captures normally, and `screencapture -x -o -l <windowID>` on a `.none`
/// window exits 1 with "could not create image from window". This is
/// enforced by WindowServer, so a screen-sharing app cannot see the panel by
/// any route, including its own in-process screenshot endpoint.
///
/// - `hidesOnDeactivate = false` — stays visible while another app (Zoom,
///   the meeting app itself) is frontmost, which is the whole point of a
///   notes panel taken during someone else's window.
/// - `level = .floating` — stays above other apps so a note can be jotted
///   without hunting for the panel; it cannot hold key focus while the app
///   is not frontmost, but this is a `.nonactivatingPanel` so it can still
///   become key without activating the app (see `NotesWindowController`).
/// - `.canJoinAllSpaces` + `.fullScreenAuxiliary` — follows the user across
///   Spaces and shows over full-screen apps instead of being left behind on
///   the Space it opened on.
///
/// `.canJoinAllSpaces` and `.fullScreenAuxiliary` each belong to a
/// mutually-exclusive `NSWindowCollectionBehavior` group, so the conflicting
/// members are cleared before the wanted ones are unioned in — otherwise
/// AppKit silently ignores them. Unrelated flags are preserved.
enum NotesWindowPolicy {
    @MainActor
    static func apply(to panel: NSPanel) {
        panel.sharingType = .none
        panel.level = .floating
        panel.hidesOnDeactivate = false
        var behavior = panel.collectionBehavior
        // Drop the other members of the two exclusive groups we set below.
        behavior.subtract([.managed, .moveToActiveSpace, .stationary, .fullScreenPrimary, .fullScreenNone])
        behavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
        panel.collectionBehavior = behavior
    }
}
