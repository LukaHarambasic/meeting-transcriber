@testable import MeetingTranscriber
import XCTest

/// Indirect coverage for the `WatchLoop.update(_:)` mutation funnel.
/// `update` is private, so the assertions exercise it through the
/// public entry-points (manual recording start/stop) and inspect
/// the resulting `snapshot` + `onStateChange` callback log.
@MainActor
final class WatchLoopUpdateFunnelTests: XCTestCase {
    /// A single funnel call carries co-located mutations atomically:
    /// `startManualRecording` flips phase to `.recording` AND sets
    /// `manualRecordingInfo` AND a fresh `detail` in one snapshot transition.
    /// Multi-step writes that could be observed mid-flight (phase changed,
    /// detail not yet) are now coherent.
    func testStartManualRecordingEmitsCoherentSnapshotTransition() async throws {
        let (loop, _) = makeTestWatchLoop()
        var observed: [WatchLoopState] = []
        loop.onStateChange = { [weak loop] _, _ in
            if let loop { observed.append(loop.snapshot) }
        }

        try await loop.startManualRecording(pid: 42, appName: "Chrome", title: "Sync")
        defer { loop.stop() }

        XCTAssertEqual(observed.count, 1, "Exactly one phase transition fires for startManualRecording")
        XCTAssertEqual(observed.first?.phase, .recording)
        XCTAssertEqual(observed.first?.detail, "Recording: Sync")
    }

    /// `onStateChange` is invoked only when the *phase* changes. `stop()`
    /// during a manual recording performs two internal funnel calls: first
    /// `cleanupManualRecording()` clears `manualRecordingInfo` alone (phase
    /// unchanged — must not fire the callback), then a second call moves the
    /// phase to `.idle` (must fire exactly once).
    func testDetailOnlyUpdateDoesNotFireOnStateChange() async throws {
        let (loop, _) = makeTestWatchLoop()
        try await loop.startManualRecording(pid: 1, appName: "Chrome", title: "Meeting")

        var transitions: [(WatchLoop.State, WatchLoop.State)] = []
        loop.onStateChange = { old, new in transitions.append((old, new)) }

        loop.stop()

        XCTAssertEqual(transitions.count, 1, "only the phase-changing update fires onStateChange")
        XCTAssertEqual(transitions.first?.0, .recording)
        XCTAssertEqual(transitions.first?.1, .idle)
    }

    /// The phase-transition callback receives the old phase observed
    /// *before* the funnel commits the new snapshot — even when the
    /// funnel mutates other fields in the same transform.
    func testOnStateChangeReportsOldPhaseBeforeCommit() async throws {
        let (loop, _) = makeTestWatchLoop()
        try await loop.startManualRecording(pid: 1, appName: "Chrome", title: "Meeting")
        var lastPair: (WatchLoop.State, WatchLoop.State)?
        loop.onStateChange = { old, new in lastPair = (old, new) }

        loop.stop()

        XCTAssertEqual(lastPair?.0, .recording)
        XCTAssertEqual(lastPair?.1, .idle)
    }

    /// Manual recording sets phase + manualRecordingInfo + detail in a
    /// single funnel call. Snapshot read after start sees all three.
    func testManualRecordingStartAtomicallyUpdatesAllFields() async throws {
        let (loop, _) = makeTestWatchLoop()
        try await loop.startManualRecording(pid: 99, appName: "Zoom", title: "Daily")
        defer { loop.stop() }

        let snap = loop.snapshot
        XCTAssertEqual(snap.phase, .recording)
        XCTAssertEqual(snap.detail, "Recording: Daily")
        XCTAssertEqual(
            snap.manualRecordingInfo,
            ManualRecordingInfo(pid: 99, appName: "Zoom", title: "Daily"),
        )
    }

    /// When `recorder.stop()` throws, the funnel still transitions to
    /// `.idle` and surfaces the error message via `lastError` — both in
    /// a single coherent snapshot, not a split mid-flight observation.
    func testStopManualRecordingSurfacesRecorderErrorThroughFunnel() async throws {
        let (loop, recorder) = makeTestWatchLoop()
        recorder.mixPath = nil // forces MockRecorder.stop() to throw .noAudioData

        try await loop.startManualRecording(pid: 7, appName: "Webex", title: "Sync")
        XCTAssertEqual(loop.snapshot.phase, .recording)

        loop.stopManualRecording()

        let snap = loop.snapshot
        XCTAssertEqual(snap.phase, .idle, "Phase still transitions to idle on stop failure")
        XCTAssertNil(snap.manualRecordingInfo, "Manual info cleared even when stop throws")
        XCTAssertEqual(snap.detail, "")
        XCTAssertNotNil(snap.lastError, "Recorder error must surface via funnel's lastError")
    }
}
