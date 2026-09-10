@testable import MeetingTranscriber
import XCTest

/// Composition tests for the notes-reach-the-protocol wiring: a job carrying
/// notes must both (a) hand them to the protocol generator as context, and
/// (b) get them written verbatim under `## Notes` in the saved `.md` — the
/// two are independent wiring lines in `PipelineQueue+Stages.swift`, and each
/// assertion below is chosen so dropping either line alone fails only its own
/// assertion, with the other still passing. No `tearDown`: `makeTempDirectory`
/// self-registers cleanup via `addTeardownBlock`, matching the pattern already
/// used elsewhere (e.g. `PipelineQueueTests`).
@MainActor
// swiftlint:disable:next attributes balanced_xctest_lifecycle
final class ProtocolNotesTests: XCTestCase {
    // swiftlint:disable implicitly_unwrapped_optional
    private var tmpDir: URL!
    private var protocolsDir: URL!
    // swiftlint:enable implicitly_unwrapped_optional

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "protocol_notes_test")
        protocolsDir = tmpDir.appendingPathComponent("protocols")
        try FileManager.default.createDirectory(at: protocolsDir, withIntermediateDirectories: true)
    }

    private func makeQueue(
        protocolGen: (any ProtocolGenerating)?,
        notesFeedToProtocol: @escaping () -> Bool = { true },
    ) -> PipelineQueue {
        PipelineQueue(
            engine: MockEngine(),
            diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { protocolGen },
            outputDir: tmpDir,
            logDir: tmpDir,
            notesFeedToProtocol: notesFeedToProtocol,
        )
    }

    private func makeJobWithNotes(_ notes: String?) -> PipelineJob {
        var job = PipelineJob(
            meetingTitle: "Weekly Sync", appName: "Teams",
            mixPath: nil, appPath: nil, micPath: nil, micDelay: 0,
        )
        job.notes = notes
        return job
    }

    /// Both halves of the wiring at once: the generator receives the notes,
    /// and the saved `.md` contains them verbatim.
    func testNotesReachBothTheGeneratorAndTheSavedMarkdown() async throws {
        let mock = MockProtocolGen()
        let queue = makeQueue(protocolGen: mock)
        let job = makeJobWithNotes("- decided X\n- ask Bob")
        queue.insertJobForTesting(job)

        await queue.generateProtocol(
            jobID: job.id, transcript: "[SPEAKER_0] hello", title: job.meetingTitle, protocolsDir: protocolsDir,
        )

        XCTAssertEqual(mock.capturedNotes, "- decided X\n- ask Bob", "notes must reach the generator as context")

        let mdPath = try XCTUnwrap(queue.jobs.first?.protocolPath)
        let saved = try String(contentsOf: mdPath, encoding: .utf8)
        XCTAssertTrue(
            saved.contains("## Notes\n\n- decided X\n- ask Bob"),
            "verbatim notes section missing from saved .md: \(saved)",
        )
    }

    /// `notesFeedToProtocol == false` must stop the generator feed while
    /// leaving the verbatim section untouched — the whole contract of that
    /// flag is that it only controls what the LLM sees.
    func testNotesFeedToProtocolFalseKeepsVerbatimButStopsFeed() async throws {
        let mock = MockProtocolGen()
        let queue = makeQueue(protocolGen: mock) { false }
        let job = makeJobWithNotes("- private plan")
        queue.insertJobForTesting(job)

        await queue.generateProtocol(
            jobID: job.id, transcript: "[SPEAKER_0] hi", title: job.meetingTitle, protocolsDir: protocolsDir,
        )

        XCTAssertNil(mock.capturedNotes, "the feed must be off when notesFeedToProtocol() returns false")

        let mdPath = try XCTUnwrap(queue.jobs.first?.protocolPath)
        let saved = try String(contentsOf: mdPath, encoding: .utf8)
        XCTAssertTrue(
            saved.contains("## Notes\n\n- private plan"),
            "the verbatim section must not depend on the feed flag: \(saved)",
        )
    }

    /// No generator configured at all (`AppSettings.protocolProvider ==
    /// .none`): there is no protocol body, but the notes must still reach the
    /// user. This is the path where verbatim is the entire feature.
    func testNoProtocolGeneratorStillWritesNotesVerbatim() async throws {
        let queue = makeQueue(protocolGen: nil)
        let job = makeJobWithNotes("- solo note, no LLM configured")
        queue.insertJobForTesting(job)

        await queue.generateProtocol(
            jobID: job.id, transcript: "[SPEAKER_0] hi", title: job.meetingTitle, protocolsDir: protocolsDir,
        )

        let mdPath = try XCTUnwrap(
            queue.jobs.first?.protocolPath,
            "a job with notes must produce a .md even with no protocol generator configured",
        )
        let saved = try String(contentsOf: mdPath, encoding: .utf8)
        XCTAssertTrue(
            saved.contains("## Notes\n\n- solo note, no LLM configured"),
            "verbatim notes missing from the no-generator fallback: \(saved)",
        )
    }

    /// The generator throwing must not take the notes down with it: the
    /// warning path still leaves a notes-only artifact behind.
    func testGeneratorFailureStillWritesNotesVerbatim() async throws {
        let mock = MockProtocolGen()
        mock.shouldThrow = true
        let queue = makeQueue(protocolGen: mock)
        let job = makeJobWithNotes("- surviving a generation failure")
        queue.insertJobForTesting(job)

        await queue.generateProtocol(
            jobID: job.id, transcript: "[SPEAKER_0] hi", title: job.meetingTitle, protocolsDir: protocolsDir,
        )

        XCTAssertEqual(queue.jobs.first?.warnings, ["Transcript generation failed; raw text saved"])
        let mdPath = try XCTUnwrap(
            queue.jobs.first?.protocolPath,
            "a failed LLM call must not drop the user's notes",
        )
        let saved = try String(contentsOf: mdPath, encoding: .utf8)
        XCTAssertTrue(
            saved.contains("## Notes\n\n- surviving a generation failure"),
            "verbatim notes missing from the generation-failure fallback: \(saved)",
        )
    }

    /// A job with no notes at all must not gain a `.md` from the no-generator
    /// path — pins the guard that keeps this feature a no-op for every job
    /// that predates it.
    func testNoNotesAndNoGeneratorWritesNothing() async {
        let queue = makeQueue(protocolGen: nil)
        let job = makeJobWithNotes(nil)
        queue.insertJobForTesting(job)

        await queue.generateProtocol(
            jobID: job.id, transcript: "[SPEAKER_0] hi", title: job.meetingTitle, protocolsDir: protocolsDir,
        )

        XCTAssertNil(queue.jobs.first?.protocolPath, "no notes and no generator must produce no .md at all")
    }
}
