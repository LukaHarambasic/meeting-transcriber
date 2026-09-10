import Foundation

/// `AppState`'s notes composition, split out of that file for its 600-line cap.
///
/// All three are `static` factories with declared return types rather than
/// inline expressions in `init`, and that is load-bearing rather than tidiness:
/// built inline, their closures pushed `AppState.init`'s type-check to 358 ms
/// against the 300 ms limit the package enforces as a build error.
extension AppState {
    /// The notes file layer.
    ///
    /// `outputDir` is a closure, not a value: the user can repoint the Output
    /// Folder while the app runs, and a scratch note written after that belongs
    /// in the new folder.
    static func makeNotesStore(settings: AppSettings) -> NotesStore {
        NotesStore(
            recordingsDir: AppPaths.recordingsDir,
            // Not trailing-closure: it would detach the closure from the label
            // saying which directory it resolves, the same reason the
            // `RPCServerController` call in `AppState.init` is written this way.
            // swiftlint:disable:next trailing_closure
            outputDir: { [settings] in settings.effectiveOutputDir },
        )
    }

    /// The panel's controller.
    ///
    /// `resolveTarget` asks the recording lifecycle where a note belongs, so the
    /// panel follows a recording starting or stopping without holding a
    /// reference to the loop. No loop at all means nothing is recording, which
    /// is a scratch note for today.
    static func makeNotesController(
        store: NotesStore,
        watching: WatchingController,
    ) -> NotesController {
        let resolveTarget: () -> NoteTarget = { [weak watching] in
            watching?.watchLoop?.noteTarget ?? .scratch(day: Date())
        }
        return NotesController(store: store, resolveTarget: resolveTarget)
    }

    /// Hands a finished recording's notes to the enqueue path, which is the
    /// point where they become part of the job and stop being a loose file.
    static func makeTakeNotes(store: NotesStore) -> (String) -> String? {
        { [store] stem in store.take(stem: stem) }
    }
}
