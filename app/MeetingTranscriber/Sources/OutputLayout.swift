import Foundation

/// Where a finished job's files go inside the user's output folder.
///
/// One definition, because the layout used to be eight `appendingPathComponent`
/// calls spread across five files, and a folder name typed in one place and not
/// another is invisible until a re-diarization cannot find its sidecars.
///
/// The shape is deliberate: **transcripts are the output, everything else is
/// plumbing.**
/// ```
/// <outputDir>/20260903_1430_standup_3913da4c.md   ← the artifact
/// <outputDir>/.audio/…_16k.wav, …_segments.json   ← working files, hidden
/// ```
/// Transcripts sit at the top level rather than under `protocols/` so the
/// output folder is a folder of transcripts, and the working files sit under a
/// dot-prefixed directory so Finder hides them rather than presenting them as
/// something to read.
enum OutputLayout {
    /// Where the `.md` transcripts land: the output folder itself.
    ///
    /// A function rather than a constant, so every call site reads as a lookup
    /// against this type and a future change of mind has one place to happen.
    static func transcriptsDir(in outputDir: URL) -> URL {
        outputDir
    }

    /// Working files a later re-diarization or re-assignment needs: the 16 kHz
    /// resamples and the cached segment JSON.
    ///
    /// Dot-prefixed so Finder and most file pickers hide it. These are not
    /// archives and not something to open; the recording's own audio is deleted
    /// once its transcript exists (see `AudioPersistenceAction.delete`).
    static func workDir(in outputDir: URL) -> URL {
        outputDir.appendingPathComponent(".audio", isDirectory: true)
    }

    // The pre-`.audio` read-fallback helpers (`legacyWorkDir`,
    // `legacyTranscriptsDir`, `existing`) were removed here. Their doc comments
    // claimed they kept an older install's sidecars and transcripts reachable,
    // but nothing ever called them, so that compatibility was described and
    // never wired up: a job made before the layout change was already
    // unreadable. They were invisible for nine commits because the analyze job
    // needs a successful build log to run `unused_declaration`, and the build
    // was broken for all of them. Reinstating the behaviour means wiring the
    // read paths, not restoring these; the code is in git history.
}
