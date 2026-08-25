@testable import MeetingTranscriber
import XCTest

/// Coverage for the `WatchLoopState` snapshot value type and the
/// `WatchLoop.snapshot` getter that bundles the four observable fields.
@MainActor
final class WatchLoopStateTests: XCTestCase {
    // MARK: - Equatable / initial

    func testInitialMatchesFreshLoopSnapshot() {
        let (loop, _) = makeTestWatchLoop()
        XCTAssertEqual(loop.snapshot, .initial)
    }

    func testInitialIsIdle() {
        XCTAssertEqual(WatchLoopState.initial.phase, .idle)
        XCTAssertNil(WatchLoopState.initial.lastError)
        XCTAssertEqual(WatchLoopState.initial.detail, "")
        XCTAssertNil(WatchLoopState.initial.manualRecordingInfo)
    }

    func testEqualityRequiresAllFieldsToMatch() {
        let a = WatchLoopState.initial
        var b = WatchLoopState.initial
        XCTAssertEqual(a, b)

        b.detail = "recording"
        XCTAssertNotEqual(a, b, "Snapshots with different detail must not compare equal")
    }

    // MARK: - Snapshot reflects live fields

    func testSnapshotReflectsPhaseTransition() async throws {
        let (loop, _) = makeTestWatchLoop()
        XCTAssertEqual(loop.snapshot.phase, .idle)

        try await loop.startManualRecording(pid: 42, appName: "Chrome", title: "Sync")
        XCTAssertEqual(loop.snapshot.phase, .recording)
        XCTAssertEqual(loop.snapshot.detail, "Recording: Sync")

        loop.stop()
        XCTAssertEqual(loop.snapshot.phase, .idle)
    }

    func testSnapshotReflectsManualRecordingInfo() async throws {
        let (loop, _) = makeTestWatchLoop()
        try await loop.startManualRecording(pid: 42, appName: "Chrome", title: "Sync")
        defer { loop.stop() }

        let info = try XCTUnwrap(loop.snapshot.manualRecordingInfo)
        XCTAssertEqual(info, ManualRecordingInfo(pid: 42, appName: "Chrome", title: "Sync"))
        XCTAssertEqual(loop.snapshot.phase, .recording)
    }
}
