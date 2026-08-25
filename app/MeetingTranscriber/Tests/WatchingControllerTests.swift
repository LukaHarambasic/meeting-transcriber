@testable import MeetingTranscriber
import XCTest

/// Unit tests for `WatchingController` exercised on a bare controller (no full
/// `AppState`), focusing on the manual-recording lifecycle and the injection
/// seams it exposes: `ensureMicAccess` and `requestScreenRecording`.
@MainActor
final class WatchingControllerTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "WatchingControllerTests")
    }

    override func tearDown() async throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        try await super.tearDown()
    }

    /// Builds a `WatchingController` wired to real (but inert) sibling
    /// controllers and the supplied seams. The pipeline gets a queue on an
    /// isolated `logDir` so `rebuild()` touches no production path.
    private func makeController(
        ensureMicAccess: @escaping () async -> Bool = { true },
        requestScreenRecording: @escaping () -> Void = {},
        startJoinTimeout: Duration = WatchingController.defaultStartJoinTimeout,
    ) -> WatchingController {
        makeWatchingController(
            logDir: tmpDir,
            ensureMicAccess: ensureMicAccess,
            requestScreenRecording: requestScreenRecording,
            startJoinTimeout: startJoinTimeout,
        )
    }

    // MARK: - requestScreenRecording seam

    /// Asking is what registers the app in the Screen Recording list, and until
    /// it is listed there is no switch for the user to turn on. A manual start
    /// that captures app audio (the app-picker path) is the moment the
    /// window-title lookup that needs it happens.
    func testManualRecordingWithAppAudioRequestsScreenRecording() async {
        var requested = false
        // Not trailing-closure: a trailing closure binds to the last param
        // (`ensureMicAccess`), not `requestScreenRecording`.
        // swiftlint:disable:next trailing_closure
        let controller = makeController(requestScreenRecording: { requested = true })
        addTeardownBlock { await controller.watchLoop?.stop() }

        controller.startManualRecording(pid: 1234, appName: "Chrome", title: "Standup")
        await waitFor(requested)

        XCTAssertTrue(requested, "a manual recording that captures app audio must ask for Screen Recording")
    }

    /// A microphone-only manual recording captures no app audio, so it must not
    /// raise the Screen Recording request at all.
    func testMicrophoneOnlyRecordingDoesNotRequestScreenRecording() async {
        var requested = false
        // swiftlint:disable:next trailing_closure
        let controller = makeController(requestScreenRecording: { requested = true })
        addTeardownBlock { await controller.watchLoop?.stop() }

        controller.startMicrophoneRecording()
        await waitFor(controller.watchLoop != nil)

        XCTAssertFalse(requested, "a microphone-only recording must not ask for Screen Recording")
    }

    // MARK: - ensureMicAccess seam

    func testStartManualRecordingAwaitsInjectedMicAccess() async {
        var micAccessCalled = false
        // Not trailing-closure: a trailing closure binds to the last param
        // (`requestScreenRecording`), not `ensureMicAccess`.
        // swiftlint:disable:next trailing_closure
        let controller = makeController(ensureMicAccess: {
            micAccessCalled = true
            return true
        })
        addTeardownBlock { await controller.watchLoop?.stop() }

        controller.startManualRecording(pid: 1234, appName: "Chrome", title: "Standup")
        await waitFor(micAccessCalled)

        XCTAssertTrue(micAccessCalled, "startManualRecording must await the injected mic-access gate")
    }

    // MARK: - Manual recording lifecycle

    func testStopManualRecordingClearsLoop() async throws {
        let controller = makeController()
        let (loop, _) = makeTestWatchLoop()
        controller.watchLoop = loop
        try await loop.startManualRecording(pid: 42, appName: "Chrome", title: "Meeting")

        controller.stopManualRecording()

        XCTAssertNil(controller.watchLoop)
    }

    /// `beginManualRecording` guards re-entry with `manualStartTask`. Two starts
    /// in quick succession both running would let the second replace the field
    /// while the first is still in flight, whose `defer` then clears the
    /// second's registration while it is still running.
    func testSecondManualStartWhileOneIsInFlightIsIgnored() async {
        let micGate = AsyncGate()
        // swiftlint:disable:next trailing_closure
        let controller = makeController(ensureMicAccess: {
            await micGate.wait()
            return true
        })
        addTeardownBlock {
            await micGate.open()
            await controller.watchLoop?.stop()
        }

        controller.startManualRecording(pid: 1, appName: "Chrome", title: "First")
        await waitFor { await micGate.hasWaiter }
        controller.startManualRecording(pid: 2, appName: "Chrome", title: "Second")
        // Let a second task run if the guard failed to stop one being created.
        for _ in 0 ..< 50 {
            await Task.yield()
        }

        let waiters = await micGate.waiterCount
        XCTAssertEqual(waiters, 1, "a second manual start must not run while one is in flight")
    }
}
