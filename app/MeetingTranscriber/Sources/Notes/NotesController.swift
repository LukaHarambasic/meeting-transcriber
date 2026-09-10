import Foundation
import Observation

/// The one instance the notes panel, the hotkey and the pipeline all talk to:
/// it owns the text being edited, which target that text belongs to, and whether
/// the panel should be on screen.
///
/// Deliberately knows nothing about AppKit. `isVisible` is observed by the app
/// scene, which shows and hides the panel — the same shape the live-captions
/// overlay already uses, and what keeps this type constructible in a test.
///
/// **Every keystroke is written to disk immediately, with no debounce.** That
/// looks wasteful and is the point: the recording stop path reads the notes file
/// the moment a recording ends, so a pending debounced write is a race whose
/// prize is the last sentence the user typed — the sentence most likely to be the
/// one that mattered. A note is a few kilobytes and the write is atomic.
@Observable
@MainActor
final class NotesController {
    /// The text in the editor. Bound directly by the panel, so the write-through
    /// lives in `didSet` rather than in a method the view has to remember to call.
    var text: String = "" {
        didSet {
            guard !isLoading, text != oldValue else { return }
            store.save(text, to: target)
        }
    }

    /// Where `text` will be written. Changes when a recording starts or stops;
    /// the panel shows it so the destination is never a guess.
    private(set) var target: NoteTarget

    /// Whether the panel should be on screen. The scene observes this.
    private(set) var isVisible = false

    @ObservationIgnored private let store: any NotesStoring
    @ObservationIgnored private let resolveTarget: () -> NoteTarget
    @ObservationIgnored private let now: () -> Date

    /// Suppresses the write-through while `text` is being filled from disk, so
    /// opening the panel cannot write the file it just read.
    @ObservationIgnored private var isLoading = false

    init(
        store: any NotesStoring,
        resolveTarget: @escaping () -> NoteTarget,
        now: @escaping () -> Date = Date.init,
    ) {
        self.store = store
        self.resolveTarget = resolveTarget
        self.now = now
        let initial: NoteTarget = resolveTarget()
        self.target = initial
    }

    // MARK: - Panel lifecycle

    func toggle() {
        if isVisible {
            close()
        } else {
            open()
        }
    }

    /// Re-target against the current recording state, load that target's text,
    /// and ask for the panel.
    func open() {
        retarget()
        isVisible = true
    }

    func close() {
        isVisible = false
    }

    /// Point at whatever the current recording state implies, carrying nothing
    /// over from the previous target.
    ///
    /// Called when the panel opens and when a recording starts or stops. The
    /// text is reloaded from the new target rather than moved into it: a note
    /// typed before a recording started belongs to the day it was typed on, and
    /// silently migrating it into a meeting transcript would put words in a
    /// meeting that were not said there.
    func retarget() {
        let next: NoteTarget = resolveTarget()
        guard next != target else {
            // Same target, but the file may have grown underneath us (the
            // automation API appends without going through the panel).
            reload()
            return
        }
        target = next
        reload()
    }

    /// Fill `text` from the target's file without triggering a write-back.
    private func reload() {
        let loaded: String = store.load(target)
        isLoading = true
        text = loaded
        isLoading = false
    }

    // MARK: - Editing helpers

    /// The meeting-relative timestamp to insert at the cursor, or nil when the
    /// current target is a scratch note and there is no meeting to be relative to.
    func timestamp() -> String? {
        target.elapsedStamp(at: now())
    }

    /// The file the current text is being written to. Read by the panel's footer
    /// so "where does this go" is answerable without opening a Finder window.
    var fileURL: URL {
        store.fileURL(for: target)
    }

    /// Add a block from outside the panel (`POST /v1/notes`).
    ///
    /// Routed through the buffer rather than straight to the store, for two
    /// reasons that are both bugs otherwise. It re-targets first, because a
    /// driver that starts a recording and immediately posts a note would
    /// otherwise hit whatever target the panel last resolved, which for a panel
    /// nobody opened is the day's scratch note rather than the meeting. And it
    /// appends to `text`, so the panel's in-memory buffer and the file stay
    /// identical: writing behind the buffer's back would leave the next
    /// keystroke overwriting the file and silently dropping the posted note.
    func appendFromAutomation(_ newText: String) {
        guard !newText.isEmpty else { return }
        retarget()
        let separator: String = text.isEmpty ? "" : "\n\n"
        text += separator + newText
    }
}
