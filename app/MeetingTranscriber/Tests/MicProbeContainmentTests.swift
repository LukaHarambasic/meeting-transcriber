import AVFoundation
@testable import MeetingTranscriber
import XCTest

/// Guards the one rule that keeps the app from wrecking the user's Bluetooth
/// playback: nothing proactive may open the microphone.
///
/// Opening an input drags a headset out of A2DP into HFP and back. The app used
/// to run a ~150 ms `AVAudioEngine` probe at launch and on every
/// `didBecomeActive`, and opening the menu bar dropdown activates the app, so
/// the user's music broke every time they looked at the menu.
///
/// Two halves, because each is blind to the other's regression:
///
/// 1. The pure half pins that the passive verdict can never be `.broken`, i.e.
///    that it reaches its answer without a probe result.
/// 2. The source half pins *who may call the probing entry points*. That is the
///    part with no runtime expression: a unit test cannot observe "this code
///    path opened the HAL" on a machine that may have no input device, and the
///    realistic regression is someone reaching for `checkMicrophoneLive()` in a
///    new proactive caller because the name reads like the default. A grep is a
///    weak guard and the honest one available.
final class MicProbeContainmentTests: XCTestCase {
    // MARK: - Pure

    func testPassiveMicrophoneCheckTakesAuthorizedAtFaceValue() {
        // The whole point: no probe ran, so `.broken` is not a verdict this can
        // reach. A regression that wired a failed probe in here would return
        // `.broken` and light the menu bar's red error dot.
        XCTAssertEqual(PermissionHealthCheck.checkMicrophonePassive(authStatus: .authorized), .healthy)
    }

    func testPassiveMicrophoneCheckStillReportsRefusals() {
        // Skipping the probe must not turn the check into a rubber stamp: a
        // denied grant is knowable without opening anything, and a recording
        // still has to be refused for it.
        XCTAssertEqual(PermissionHealthCheck.checkMicrophonePassive(authStatus: .denied), .denied)
        XCTAssertEqual(PermissionHealthCheck.checkMicrophonePassive(authStatus: .restricted), .denied)
        XCTAssertEqual(PermissionHealthCheck.checkMicrophonePassive(authStatus: .notDetermined), .notDetermined)
    }

    func testOnlyMicrophoneCapturingSourcesJustifyAProbe() {
        // `runForRecordingStart` probes exactly when this is true, so the
        // routing rule is pinned here rather than inside the untestable call.
        for source in [RecordingSource.appOnly(pid: 1), .systemOnly] {
            XCTAssertFalse(source.capturesMicrophone, "\(source) opens no mic and must not be probed")
        }
        for source in [RecordingSource.appAndMic(pid: 1), .systemAndMic, .micOnly] {
            XCTAssertTrue(source.capturesMicrophone, "\(source) opens the mic anyway, so a probe is free")
        }
    }

    // MARK: - Source containment

    /// Files allowed to name a device-opening check. `PermissionHealthCheck`
    /// defines them; `WatchLoop` and `WatchingController` are the recording
    /// gate, the one path where the recorder opens the same device moments
    /// later so the probe costs the user nothing.
    private static let probeCallers: Set<String> = [
        "PermissionHealthCheck.swift",
        "WatchLoop.swift",
        "WatchingController.swift",
    ]

    /// Symbols that open, or route to opening, the input device.
    ///
    /// `runLive` is the name this all wore before the split, when it was the
    /// default for every proactive caller. It is listed so re-introducing that
    /// shape trips the guard rather than quietly restoring the bug.
    private static let probingSymbols = [
        "probeMicrophone",
        "checkMicrophoneLive",
        "runForRecordingStart",
        "runLive",
    ]

    func testNoProactiveCallerReachesTheProbingCheck() {
        let offenders = Self.sourceFiles()
            .filter { !Self.probeCallers.contains($0.lastPathComponent) }
            .filter { url in
                let text = try? String(contentsOf: url, encoding: .utf8)
                return Self.probingSymbols.contains { text?.contains($0) == true }
            }
            .map(\.lastPathComponent)
            .sorted()

        XCTAssertEqual(
            offenders, [],
            """
            These files name a permission check that opens the microphone. \
            Proactive callers (launch, activation, /state, the menu) must use \
            PermissionHealthCheck.runPassive(), which touches no audio device — \
            see its doc comment for why debouncing is not an alternative.
            """,
        )
    }

    func testPermissionsControllerDefaultsToThePassiveCheck() throws {
        // The caller, not the helper: every proactive check in the app runs
        // through this default, and swapping it back is a one-line change that
        // breaks no other test (issue: menu bar dropdown killing Bluetooth audio).
        let source = try String(
            contentsOf: Self.sourcesDir.appendingPathComponent("PermissionsController.swift"),
            encoding: .utf8,
        )
        XCTAssertTrue(
            source.contains("= { PermissionHealthCheck.runPassive() }"),
            "PermissionsController's default probe must be the device-free runPassive()",
        )
    }

    // MARK: - Helpers

    /// `#filePath` → .../Tests/MicProbeContainmentTests.swift, so Sources is a
    /// sibling of Tests.
    private static var sourcesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // MeetingTranscriber/
            .appendingPathComponent("Sources")
    }

    private static func sourceFiles() -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: sourcesDir,
            includingPropertiesForKeys: nil,
        )
        let files = (enumerator?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "swift" }
        // A scan that silently found nothing would pass forever.
        XCTAssertGreaterThan(files.count, 50, "Source scan found almost no files — check sourcesDir")
        return files
    }
}
