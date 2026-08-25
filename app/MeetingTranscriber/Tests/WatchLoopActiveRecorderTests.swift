@testable import MeetingTranscriber
import XCTest

@MainActor
private final class CapturingRecorder: RecordingProvider {
    var startCalled = false
    var stopCalled = false
    var captureOnStop: @MainActor () -> Void = {}
    let mixPath = URL(fileURLWithPath: "/tmp/test_active_recorder.wav")
    var appLevelDBFS: Double = -120
    var micLevelDBFS: Double = -120

    // Captured start(...) arg — the source only, since this file's test
    // doesn't exercise micDeviceUID threading (covered in WatchLoopTests).
    // nil until start runs, so a recorder that was never started fails an
    // equality assertion instead of passing.
    var capturedSource: RecordingSource?

    func start(source: RecordingSource, micDeviceUID _: String?, debugLogging _: Bool) {
        startCalled = true
        capturedSource = source
    }

    func stop() -> RecordingResult {
        stopCalled = true
        captureOnStop()
        return RecordingResult(
            mixPath: mixPath,
            appPath: nil,
            micPath: nil,
            micDelay: 0,
            recordingStartDate: Date(),
        )
    }
}

/// Regression coverage for the bug where a recording start never assigned
/// `activeRecorder`, leaving `AppState`'s channel-health polling task reading
/// nil on every tick — the red-tint indicator never fired during real
/// recordings. Re-anchored on the manual-recording path (the only recording
/// path left) after auto-watch/`handleMeeting` was removed; the invariant
/// pinned is unchanged: both `activeRecordingSource` and `activeRecorder`
/// must be readable synchronously from inside `onStateChange` at the moment
/// the phase moves, not merely by the time `start`/`stop` returns.
@MainActor
final class WatchLoopActiveRecorderTests: XCTestCase {
    /// `WatchingController` starts channel-health monitoring from
    /// `onStateChange`, and it needs the recording's topology to know which
    /// channels exist. `apply` fires that callback synchronously, so anything
    /// the handler reads has to be true *by the time the phase moves*, not
    /// merely by the time `start` returns. A source published after the phase
    /// leaves the handler with nil and silently disables the indicator for the
    /// whole path, which is exactly what a stored mirror invites.
    func testTheRecordingSourceIsReadableFromTheRecordingTransition() async throws {
        let recorder = CapturingRecorder()
        let loop = WatchLoop(
            recorderFactory: { recorder },
            pipelineQueue: nil,
            pollInterval: 0.01,
            maxDuration: 10,
            noMic: true,
        )
        loop.permissionChecker = {
            HealthCheckResult(screenRecording: .healthy, microphone: .healthy)
        }

        var sourceAtTransition: RecordingSource?
        loop.onStateChange = { [weak loop] _, new in
            guard new == .recording else { return }
            sourceAtTransition = loop?.activeRecordingSource
        }

        try await loop.startManualRecording(pid: 4242, appName: "Microsoft Teams", title: "Test Meeting")
        defer { loop.stop() }

        XCTAssertEqual(
            sourceAtTransition, .appOnly(pid: 4242),
            "the channel-health wiring reads this from the transition; nil there means no monitoring for manual recordings",
        )
    }

    func testActiveRecorderIsExposedDuringRecordingAndClearedAfterStop() async throws {
        let recorder = CapturingRecorder()
        let loop = WatchLoop(
            recorderFactory: { recorder },
            pipelineQueue: nil,
            pollInterval: 0.01,
            maxDuration: 10,
            noMic: true,
        )
        loop.permissionChecker = {
            HealthCheckResult(screenRecording: .healthy, microphone: .healthy)
        }

        nonisolated(unsafe) var captured: (any RecordingProvider)?
        recorder.captureOnStop = { [weak loop] in
            captured = loop?.activeRecorder
        }

        try await loop.startManualRecording(pid: 9999, appName: "Microsoft Teams", title: "Test Meeting")
        XCTAssertTrue(recorder.startCalled, "recorder.start must be called during startManualRecording")
        XCTAssertEqual(
            recorder.capturedSource, .appOnly(pid: 9999),
            "a manual start must tap the requested PID, and the loop's noMic=true must reach the recorder as an app-only source",
        )

        loop.stopManualRecording()

        XCTAssertTrue(recorder.stopCalled, "recorder.stop must be called during stopManualRecording")
        XCTAssertIdentical(
            captured as AnyObject?,
            recorder,
            "activeRecorder must reference the recorder the loop is driving while stopManualRecording runs",
        )
        XCTAssertNil(
            loop.activeRecorder,
            "activeRecorder must be cleared after stopManualRecording returns",
        )
    }
}
