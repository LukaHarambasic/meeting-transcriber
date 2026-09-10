@testable import MeetingTranscriber
import XCTest

/// Composition tests for the enqueue-carries-notes wiring: a stem derived
/// from the recorder's own output files must reach `takeNotes`, and whatever
/// `takeNotes` returns must land on the enqueued `PipelineJob`. Asserted end
/// to end (drive a real recording through `WatchLoop`, read the job the real
/// `PipelineQueue` received) rather than unit-by-unit, because "derive a
/// stem" and "call takeNotes" and "assign job.notes" could each stay green
/// individually while the wiring between them is missing.
@MainActor
final class WatchLoopNotesTests: XCTestCase {
    func testEnqueueCarriesNotesForRecordingStemToJob() async throws {
        let recorder = MockRecorder()
        recorder.mixPath = URL(fileURLWithPath: "/tmp/20260101_120000_mix.wav")

        let queue = PipelineQueue()
        var requestedStems: [String] = []
        let notesProvider: (String) -> String? = { stem in
            requestedStems.append(stem)
            return stem == "20260101_120000" ? "- Decided to ship notes\n- Follow up with Alice" : nil
        }
        let loop = WatchLoop(
            recorderFactory: { recorder },
            pipelineQueue: queue,
            pollInterval: 0.01,
            maxDuration: 10,
            noMic: true,
            takeNotes: notesProvider,
        )
        loop.permissionChecker = { _ in
            HealthCheckResult(screenRecording: .healthy, microphone: .healthy)
        }

        try await loop.startManualRecording(pid: 9999, appName: "Microsoft Teams", title: "Test Meeting")
        loop.stopManualRecording()

        let job = try XCTUnwrap(queue.jobs.first, "stopManualRecording must enqueue a job")
        XCTAssertEqual(
            requestedStems, ["20260101_120000"],
            "enqueue must ask takeNotes for the recording's own stem, exactly once",
        )
        XCTAssertEqual(
            job.notes, "- Decided to ship notes\n- Follow up with Alice",
            "whatever takeNotes returns for the recording's stem must land on the enqueued job",
        )
    }

    /// A recording whose stem can't be derived from any of its output files
    /// (no audio matches the `_mix.wav`/`_app.wav`/`_mic.wav` convention)
    /// must still enqueue — nil notes, never a dropped job, and `takeNotes`
    /// must never be asked for a stem that doesn't exist.
    func testEnqueueWithUnderivableStemStillEnqueuesWithNilNotes() async throws {
        let recorder = MockRecorder()
        recorder.mixPath = URL(fileURLWithPath: "/tmp/recording.wav") // no suffix WatchLoop recognizes

        let queue = PipelineQueue()
        var takeNotesCallCount = 0
        let notesProvider: (String) -> String? = { _ in
            takeNotesCallCount += 1
            return "should never be reached"
        }
        let loop = WatchLoop(
            recorderFactory: { recorder },
            pipelineQueue: queue,
            pollInterval: 0.01,
            maxDuration: 10,
            noMic: true,
            takeNotes: notesProvider,
        )
        loop.permissionChecker = { _ in
            HealthCheckResult(screenRecording: .healthy, microphone: .healthy)
        }

        try await loop.startManualRecording(pid: 9999, appName: "Microsoft Teams", title: "Test Meeting")
        loop.stopManualRecording()

        let job = try XCTUnwrap(queue.jobs.first, "a recording with an underivable stem must still enqueue")
        XCTAssertNil(job.notes)
        XCTAssertEqual(takeNotesCallCount, 0, "takeNotes must not be called for a stem that couldn't be derived")
    }
}
