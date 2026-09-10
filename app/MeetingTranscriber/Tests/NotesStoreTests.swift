@testable import MeetingTranscriber
import XCTest

/// `NotesStore`'s file layer: where notes text lands on disk, that saves are
/// atomic and owner-only, and that `take` clears what it reads.
///
/// Every fixture uses a real temporary directory (`makeTempDirectory`,
/// `Tests/TestHelpers.swift`) rather than a sentinel path — a path that
/// doesn't exist would make every read/write assertion here vacuous.
final class NotesStoreTests: XCTestCase {
    private func makeStore(recordingsDir: URL, outputDir: @escaping () -> URL) -> NotesStore {
        NotesStore(recordingsDir: recordingsDir, outputDir: outputDir)
    }

    private func makeDirs() throws -> (recordings: URL, output: URL) {
        let recordings = try makeTempDirectory(prefix: "notes_store_recordings")
        let output = try makeTempDirectory(prefix: "notes_store_output")
        return (recordings, output)
    }

    // MARK: - Live recording target

    func testLoadWithNoFileReturnsEmptyString() throws {
        let (recordings, output) = try makeDirs()
        let store = makeStore(recordingsDir: recordings) { output }
        let target = NoteTarget.liveRecording(stem: "20260909_090000", startedAt: Date())

        XCTAssertEqual(store.load(target), "")
    }

    func testSaveThenLoadRoundTripsForLiveRecording() throws {
        let (recordings, output) = try makeDirs()
        let store = makeStore(recordingsDir: recordings) { output }
        let target = NoteTarget.liveRecording(stem: "20260909_090000", startedAt: Date())

        store.save("hello live", to: target)

        XCTAssertEqual(store.load(target), "hello live")
    }

    func testLiveRecordingFileURLUsesTheNotesSuffixInRecordingsDir() throws {
        let (recordings, output) = try makeDirs()
        let store = makeStore(recordingsDir: recordings) { output }
        let target = NoteTarget.liveRecording(stem: "20260909_090000", startedAt: Date())

        XCTAssertEqual(
            store.fileURL(for: target),
            recordings.appendingPathComponent("20260909_090000" + RecordingFileSuffix.notes),
        )
    }

    /// Notes are meeting content, so a saved file must carry the same
    /// owner-only 0600 mode as transcripts and protocol markdown.
    func testSaveRestrictsFileToOwnerOnly() throws {
        let (recordings, output) = try makeDirs()
        let store = makeStore(recordingsDir: recordings) { output }
        let target = NoteTarget.liveRecording(stem: "20260909_090000", startedAt: Date())

        store.save("secret meeting content", to: target)

        let attrs = try FileManager.default.attributesOfItem(atPath: store.fileURL(for: target).path)
        let permissions = try XCTUnwrap(attrs[.posixPermissions] as? Int)
        XCTAssertEqual(permissions, FileManager.ownerOnlyPermissions)
    }

    func testAppendAddsABlockToExistingText() throws {
        let (recordings, output) = try makeDirs()
        let store = makeStore(recordingsDir: recordings) { output }
        let target = NoteTarget.liveRecording(stem: "20260909_090000", startedAt: Date())

        store.save("hello live", to: target)
        store.append("more", to: target)

        XCTAssertEqual(store.load(target), "hello live\n\nmore")
    }

    func testAppendWithNoExistingTextWritesTheTextAlone() throws {
        let (recordings, output) = try makeDirs()
        let store = makeStore(recordingsDir: recordings) { output }
        let target = NoteTarget.liveRecording(stem: "20260909_090000", startedAt: Date())

        store.append("first block", to: target)

        XCTAssertEqual(store.load(target), "first block")
    }

    // MARK: - take(stem:)

    /// `take` is read-and-clear: a copy left behind in the staging directory
    /// would be picked up a second time by orphan recovery.
    func testTakeReturnsAndRemovesTheNotesFile() throws {
        let (recordings, output) = try makeDirs()
        let store = makeStore(recordingsDir: recordings) { output }
        let target = NoteTarget.liveRecording(stem: "20260909_090000", startedAt: Date())
        store.save("hello live", to: target)

        let taken = store.take(stem: "20260909_090000")

        XCTAssertEqual(taken, "hello live")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(for: target).path))
    }

    /// No notes is the common case, not an error.
    func testTakeOnAStemWithNoNotesReturnsNil() throws {
        let (recordings, output) = try makeDirs()
        let store = makeStore(recordingsDir: recordings) { output }

        XCTAssertNil(store.take(stem: "no_such_stem"))
    }

    func testTakeTwiceReturnsNilTheSecondTime() throws {
        let (recordings, output) = try makeDirs()
        let store = makeStore(recordingsDir: recordings) { output }
        let target = NoteTarget.liveRecording(stem: "20260909_090000", startedAt: Date())
        store.save("hello live", to: target)

        _ = store.take(stem: "20260909_090000")

        XCTAssertNil(store.take(stem: "20260909_090000"))
    }

    // MARK: - Scratch target

    func testScratchSaveThenLoadRoundTrips() throws {
        let (recordings, output) = try makeDirs()
        let store = makeStore(recordingsDir: recordings) { output }
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let target = NoteTarget.scratch(day: day)

        store.save("scratch text", to: target)

        XCTAssertEqual(store.load(target), "scratch text")
    }

    func testScratchFileLivesUnderOutputDirNotesSubdirectory() throws {
        let (recordings, output) = try makeDirs()
        let store = makeStore(recordingsDir: recordings) { output }
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let target = NoteTarget.scratch(day: day)

        let url = store.fileURL(for: target)

        XCTAssertEqual(url.deletingLastPathComponent(), output.appendingPathComponent("notes"))
        XCTAssertEqual(url.pathExtension, "md")
    }

    /// `outputDir` arrives as a closure, not a value, because the user can
    /// change the Output Folder while the app is running. A write must read
    /// the closure at write time, not cache whatever it returned at
    /// construction.
    func testOutputDirClosureIsReReadOnEveryCall() throws {
        let recordings = try makeTempDirectory(prefix: "notes_store_recordings")
        let firstOutput = try makeTempDirectory(prefix: "notes_store_output_1")
        let secondOutput = try makeTempDirectory(prefix: "notes_store_output_2")
        var currentOutput = firstOutput
        let store = makeStore(recordingsDir: recordings) { currentOutput }
        let target = NoteTarget.scratch(day: Date(timeIntervalSince1970: 1_700_000_000))

        store.save("in first dir", to: target)
        currentOutput = secondOutput
        store.save("in second dir", to: target)

        XCTAssertEqual(store.load(target), "in second dir")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: secondOutput.appendingPathComponent("notes")
                    .appendingPathComponent(store.fileURL(for: target).lastPathComponent).path,
            ),
        )
    }
}
