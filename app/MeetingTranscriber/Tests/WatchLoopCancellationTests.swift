@testable import MeetingTranscriber
import XCTest

/// Historical context: issue #84 pinned that cancelling the (now-removed)
/// auto-watch task mid-recording had to *finalize* an in-flight recording
/// (`recorder.stop()` + enqueue) rather than discard it — `waitForMeetingEnd`
/// used to throw `CancellationError` on cancel, and the finalization lines
/// never ran.
///
/// Auto-detection is gone, and `stop()`'s only remaining caller path is
/// manual recording, where `WatchLoop.stop()` documents the *opposite*
/// contract on purpose: it is a shutdown primitive (app quit, tests) that
/// cancels the manual-recording monitor and drops the in-flight recorder
/// WITHOUT finalizing it; `stopManualRecording()` is the entry point that
/// stops-and-enqueues. There is no manual-path equivalent of the original
/// "cancel must finalize" invariant to re-anchor onto — the deliberate
/// current behaviour disproves it. This file now pins that current contract
/// instead, so a future change doesn't silently start finalizing under
/// `stop()` (which would risk a double-enqueue against a caller that
/// separately calls `stopManualRecording()`).
@MainActor
final class WatchLoopCancellationTests: XCTestCase {
    func testStopDuringManualRecordingCancelsMonitorAndDropsWithoutFinalizing() async throws {
        let recorder = MockRecorder()
        recorder.mixPath = URL(fileURLWithPath: "/tmp/test_mix_cancel.wav")
        let queue = try PipelineQueue(logDir: makeTempDirectory(prefix: "wl-cancel"))
        let loop = WatchLoop(
            recorderFactory: { recorder },
            pipelineQueue: queue,
            pollInterval: 0.01,
            maxDuration: 100,
            noMic: true,
        )
        loop.permissionChecker = {
            HealthCheckResult(screenRecording: .healthy, microphone: .healthy)
        }

        try await loop.startManualRecording(pid: 4242, appName: "Microsoft Teams", title: "Standup")
        XCTAssertTrue(loop.isManualRecording)

        loop.stop()

        XCTAssertFalse(loop.isManualRecording)
        XCTAssertEqual(loop.state, .idle)
        XCTAssertFalse(
            recorder.stopCalled,
            "stop() must drop the recorder without finalizing — stopManualRecording() is the entry point that stops-and-enqueues",
        )
        XCTAssertTrue(
            queue.jobs.isEmpty,
            "a recording dropped by stop() must not be enqueued",
        )
    }
}
