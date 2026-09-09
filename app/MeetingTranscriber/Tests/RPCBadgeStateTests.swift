#if !APPSTORE
    @testable import MeetingTranscriber
    import XCTest

    /// Covers the menu-bar `badge` field exposed in the RPC `/state` snapshot:
    /// the `BadgeKind` -> wire-string contract, that the snapshot builder wires it
    /// from `AppState.currentBadge` (not a hardcode), and that it serialises into
    /// the snapshot JSON. Lets a driver script assert the menu-bar state
    /// deterministically instead of pixel-matching a `/screenshot`.
    @MainActor
    final class RPCBadgeStateTests: XCTestCase {
        // MARK: - BadgeKind wire contract

        func testBadgeKindRawValueMapsEveryCase() {
            // Exact wire strings — a driver script asserts against these, so a
            // rename/reorder is a breaking contract change that must be deliberate.
            XCTAssertEqual(BadgeKind.inactive.rawValue, "inactive")
            XCTAssertEqual(BadgeKind.recording.rawValue, "recording")
            XCTAssertEqual(BadgeKind.transcribing.rawValue, "transcribing")
            XCTAssertEqual(BadgeKind.diarizing.rawValue, "diarizing")
            XCTAssertEqual(BadgeKind.processing.rawValue, "processing")
            XCTAssertEqual(BadgeKind.userAction.rawValue, "userAction")
            XCTAssertEqual(BadgeKind.done.rawValue, "done")
            XCTAssertEqual(BadgeKind.error.rawValue, "error")
            // Guard: every case is pinned above — a newly-added case fails this
            // count and forces the author to add its wire string here.
            XCTAssertEqual(BadgeKind.allCases.count, 8)
        }

        // MARK: - Wiring: snapshot.badge follows currentBadge (non-vacuous)

        func testSnapshotBadgeReflectsCurrentBadge() throws {
            let state = makeRPCTestState()

            // Fresh idle app -> inactive, on both the computed property and the wire.
            XCTAssertEqual(state.currentBadge, .inactive)
            XCTAssertEqual(state.rpcStateSnapshot().badge, .inactive)

            // Drive currentBadge to a NON-inactive value; the snapshot must follow.
            // A hardcoded `.inactive` in the builder would fail this.
            state.pipeline.enqueueFiles([URL(fileURLWithPath: "/tmp/meeting.wav")])
            let job = try XCTUnwrap(state.pipeline.queue.jobs.first)
            state.pipeline.queue.updateJobState(id: job.id, to: .transcribing)

            XCTAssertEqual(state.currentBadge, .transcribing)
            // Bind once — every rpcStateSnapshot() does a real speakers.json read.
            let snap = state.rpcStateSnapshot()
            XCTAssertEqual(snap.badge, .transcribing)
            XCTAssertEqual(snap.badge, state.currentBadge)
        }

        // MARK: - Serialisation

        func testBadgeSerialisesIntoSnapshotJSON() throws {
            let snapshot = RPCStateSnapshot(
                pipeline: .init(
                    isProcessing: false,
                    activeJobCount: 0,
                    waitingJobCount: 0,
                    pendingNamingJobCount: 0,
                ),
                speakerDB: .init(count: 0, recentNames: [], knownSpeakerNames: []),
                pendingNamingJobs: [],
                badge: .recording,
            )
            let json = try XCTUnwrap(String(data: snapshot.jsonData(), encoding: .utf8))
            // jsonData() is pretty-printed with sorted keys -> `"key" : "value"`;
            // a String-raw Codable enum encodes to its raw value.
            XCTAssertTrue(json.contains("\"badge\" : \"recording\""), json)
        }
    }
#endif
