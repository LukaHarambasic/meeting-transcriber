@testable import MeetingTranscriber
import XCTest

/// Failed jobs age out of the queue so a month-old failure does not sit in the
/// menu forever. Covers the pure rule (`ErrorJobPrune`) and the three places
/// `PipelineQueue` applies it: snapshot load, enqueue and a terminal transition.
@MainActor
// swiftlint:disable:next attributes balanced_xctest_lifecycle
final class PipelineQueueErrorPruneTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let day: TimeInterval = 86400

    // swiftlint:disable implicitly_unwrapped_optional
    private var tmpDir: URL!
    // swiftlint:enable implicitly_unwrapped_optional

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "error_prune_test")
    }

    /// `enqueuedAt` is a `let` stamped at init, so a job from the past is
    /// built by round-tripping through the same JSON the snapshot stores.
    private func makeJob(
        title: String,
        state: JobState,
        enqueuedAgo: TimeInterval,
        mixPath: URL? = nil,
    ) throws -> PipelineJob {
        let job = PipelineJob(
            meetingTitle: title, appName: "Teams",
            mixPath: mixPath, appPath: nil, micPath: nil, micDelay: 0,
        )
        let data = try JSONEncoder().encode(job)
        var dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        dict["enqueuedAt"] = Date().addingTimeInterval(-enqueuedAgo).timeIntervalSinceReferenceDate
        dict["state"] = state.rawValue
        let aged = try JSONSerialization.data(withJSONObject: dict)
        return try JSONDecoder().decode(PipelineJob.self, from: aged)
    }

    private func titles(_ queue: PipelineQueue) -> [String] {
        queue.jobs.map(\.meetingTitle)
    }

    // MARK: - Pure rule

    func testErrorJobOlderThanLifetimeIsStale() {
        XCTAssertTrue(ErrorJobPrune.isStale(
            state: .error, enqueuedAt: now.addingTimeInterval(-day - 1), now: now, lifetime: day,
        ))
    }

    func testErrorJobYoungerThanLifetimeIsKept() {
        XCTAssertFalse(ErrorJobPrune.isStale(
            state: .error, enqueuedAt: now.addingTimeInterval(-day + 60), now: now, lifetime: day,
        ))
    }

    func testOnlyErrorJobsEverExpire() {
        let monthAgo = now.addingTimeInterval(-30 * day)
        for state in [JobState.waiting, .transcribing, .diarizing, .generatingProtocol, .speakerNamingPending, .done] {
            XCTAssertFalse(
                ErrorJobPrune.isStale(state: state, enqueuedAt: monthAgo, now: now, lifetime: day),
                "\(state) must never be pruned for age",
            )
        }
    }

    func testDefaultLifetimeIsTwentyFourHours() {
        XCTAssertEqual(ErrorJobPrune.defaultLifetime, 24 * 3600)
        XCTAssertEqual(PipelineQueue(logDir: tmpDir).errorJobLifetime, 24 * 3600)
    }

    // MARK: - Snapshot load

    func testLoadSnapshotDropsStaleErrorJobsAndKeepsTheRest() throws {
        let audio = tmpDir.appendingPathComponent("old_mix.wav")
        try Data("fake audio".utf8).write(to: audio)
        let freshAudio = tmpDir.appendingPathComponent("fresh_mix.wav")
        try Data("fake audio".utf8).write(to: freshAudio)

        let jobs = try [
            makeJob(title: "Old failure", state: .error, enqueuedAgo: 30 * day, mixPath: audio),
            makeJob(title: "Fresh failure", state: .error, enqueuedAgo: 3600, mixPath: freshAudio),
            makeJob(title: "Old but waiting", state: .waiting, enqueuedAgo: 30 * day, mixPath: freshAudio),
        ]
        try JSONEncoder().encode(jobs)
            .write(to: tmpDir.appendingPathComponent(PipelineSnapshot.snapshotFilename))

        let queue = PipelineQueue(logDir: tmpDir)
        queue.loadSnapshot()

        XCTAssertEqual(Set(titles(queue)), ["Fresh failure", "Old but waiting"])
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: audio.path),
            "pruning a failed job must never delete its audio",
        )
    }

    func testLoadSnapshotPrunedJobsStayGoneAfterTheNextRestart() async throws {
        let audio = tmpDir.appendingPathComponent("old_mix.wav")
        try Data("fake audio".utf8).write(to: audio)
        let stale = try makeJob(title: "Old failure", state: .error, enqueuedAgo: 30 * day, mixPath: audio)
        try JSONEncoder().encode([stale])
            .write(to: tmpDir.appendingPathComponent(PipelineSnapshot.snapshotFilename))

        let first = PipelineQueue(logDir: tmpDir)
        first.loadSnapshot()
        await first.awaitSnapshotFlush()

        let second = PipelineQueue(logDir: tmpDir)
        second.loadSnapshot()
        XCTAssertTrue(second.jobs.isEmpty, "the pruned snapshot must have been rewritten without the job")
    }

    func testLoadSnapshotHonoursInjectedLifetime() throws {
        let audio = tmpDir.appendingPathComponent("mix.wav")
        try Data("fake audio".utf8).write(to: audio)
        let job = try makeJob(title: "Two hours old", state: .error, enqueuedAgo: 7200, mixPath: audio)
        try JSONEncoder().encode([job])
            .write(to: tmpDir.appendingPathComponent(PipelineSnapshot.snapshotFilename))

        let queue = PipelineQueue(logDir: tmpDir, errorJobLifetime: 3600)
        queue.loadSnapshot()
        XCTAssertTrue(queue.jobs.isEmpty)
    }

    // MARK: - Running queue

    func testEnqueueShedsStaleErrorJobs() throws {
        let queue = PipelineQueue(logDir: tmpDir)
        try queue.insertJobForTesting(makeJob(title: "Old failure", state: .error, enqueuedAgo: 3 * day))
        try queue.insertJobForTesting(makeJob(title: "Fresh failure", state: .error, enqueuedAgo: 60))

        queue.enqueue(PipelineJob(
            meetingTitle: "New", appName: "Teams",
            mixPath: URL(fileURLWithPath: "/tmp/new_mix.wav"), appPath: nil, micPath: nil, micDelay: 0,
        ))

        XCTAssertEqual(Set(titles(queue)), ["Fresh failure", "New"])
    }

    func testTerminalTransitionShedsOtherStaleFailuresButKeepsTheOneThatJustFailed() throws {
        let queue = PipelineQueue(logDir: tmpDir)
        // Waited two days before failing: it must still be seen once.
        let justFailed = try makeJob(title: "Just failed", state: .waiting, enqueuedAgo: 2 * day)
        try queue.insertJobForTesting(makeJob(title: "Old failure", state: .error, enqueuedAgo: 3 * day))
        queue.insertJobForTesting(justFailed)

        queue.updateJobState(id: justFailed.id, to: .error, error: "boom")

        XCTAssertEqual(titles(queue), ["Just failed"])
        XCTAssertEqual(queue.jobs.first?.state, .error)
    }

    func testPruneRecordsMissingTerminalRecordBeforeRemoving() throws {
        let store = TerminalJobStore(path: tmpDir.appendingPathComponent("terminal_jobs.json"))
        let queue = PipelineQueue(logDir: tmpDir, terminalJobStore: store)
        let old = try makeJob(title: "Old failure", state: .error, enqueuedAgo: 3 * day)
        queue.insertJobForTesting(old)

        queue.pruneStaleErrorJobs()

        XCTAssertTrue(queue.jobs.isEmpty)
        let record = try XCTUnwrap(store.lookup(jobID: old.id), "API readback must survive the removal")
        XCTAssertEqual(record.meetingTitle, "Old failure")
        XCTAssertEqual(record.state, .error)
    }

    func testPruneDoesNotOverwriteAnExistingTerminalRecord() throws {
        let store = TerminalJobStore(path: tmpDir.appendingPathComponent("terminal_jobs.json"))
        let queue = PipelineQueue(logDir: tmpDir, terminalJobStore: store)
        var old = try makeJob(title: "Old failure", state: .error, enqueuedAgo: 3 * day)
        old.error = "original reason"
        queue.insertJobForTesting(old)
        store.record(JobStatusDTO(job: old))

        queue.pruneStaleErrorJobs()

        XCTAssertEqual(store.records.filter { $0.jobID == old.id.uuidString }.count, 1)
        XCTAssertEqual(store.lookup(jobID: old.id)?.error, "original reason")
    }
}
