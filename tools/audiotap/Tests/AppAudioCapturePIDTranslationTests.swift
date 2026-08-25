@testable import AudioTapLib
import CoreAudio
import Darwin
import XCTest

@available(macOS 14.2, *)
final class AppAudioCapturePIDTranslationTests: XCTestCase {
    // MARK: - static translatePID

    func testTranslatePIDReturnsNilForUnknownPID() {
        // A PID well above any plausibly running process has no CoreAudio
        // process-object entry → the `kAudioObjectUnknown` guard fires.
        XCTAssertNil(AppAudioCapture.translatePID(999_999))
    }

    func testTranslatePIDForCurrentProcessReturnsValidIDOrNil() {
        // Exercises the live `AudioObjectGetPropertyData` path with a real
        // PID. Whether xctest itself has an audio process-object is
        // environment-dependent — some macOS hosts register one, some
        // don't. The function must handle both outcomes without crashing
        // and never return `kAudioObjectUnknown` masquerading as a real ID.
        if let id = AppAudioCapture.translatePID(getpid()) {
            XCTAssertNotEqual(id, AudioObjectID(kAudioObjectUnknown))
        }
    }

    // MARK: - instance translatePIDs

    func testTranslatePIDsThrowsWhenAllPIDsUntranslatable() {
        // All bogus PIDs → empty translated set → must throw rather than
        // hand a `CATapDescription` an empty processObjectIDs array (which
        // would yield a silent tap).
        let capture = AppAudioCapture(
            target: .processes([999_998, 999_999]),
            outputFileDescriptor: -1,
        )
        XCTAssertThrowsError(try capture.translatePIDs()) { error in
            let ns = error as NSError
            XCTAssertEqual(ns.domain, "audiotap")
            XCTAssertEqual(ns.code, -1)
            XCTAssertTrue(
                ns.localizedDescription.contains("Failed to translate"),
                "Error description should mention the failure: \(ns.localizedDescription)",
            )
        }
    }

    func testTranslatePIDsEmptyPidsListThrows() {
        // Defensive — production callers always pass at least one PID via
        // `resolveTapPIDs`, but the throw guards against future regressions.
        let capture = AppAudioCapture(target: .processes([]), outputFileDescriptor: -1)
        XCTAssertThrowsError(try capture.translatePIDs())
    }

    func testStartWithEmptyProcessesThrowsBeforeAnyHardwareCall() {
        // `.processes([])` must fail at `translatePIDs()`, the very first
        // thing `startCapture` does — never reach the CATapDescription /
        // aggregate-device machinery with an empty processObjectIDs array,
        // which would build a tap that listens to nothing instead of failing.
        let capture = AppAudioCapture(target: .processes([]), outputFileDescriptor: -1)
        XCTAssertThrowsError(try capture.start()) { error in
            let ns = error as NSError
            XCTAssertEqual(ns.domain, "audiotap")
            XCTAssertEqual(ns.code, -1)
            XCTAssertTrue(
                ns.localizedDescription.contains("Failed to translate"),
                "must fail at PID translation, not at a later HAL step: \(ns.localizedDescription)",
            )
        }
    }

    // MARK: - makeTapDescription

    func testMakeTapDescriptionSystemMixdownExcludesNoProcesses() {
        // `.systemMixdown` deliberately excludes nothing: the whole point is
        // to tap everything without having to name any process, so its own
        // `processes` list (what CATapDescription is told to EXCLUDE, for the
        // global-tap initializer) must be empty.
        let tap = AppAudioCapture.makeTapDescription(target: .systemMixdown, processObjectIDs: [])
        XCTAssertTrue(tap.processes.isEmpty)
    }

    func testMakeTapDescriptionProcessesCarriesExactlyTheGivenObjectIDs() {
        let ids: [AudioObjectID] = [AudioObjectID(11), AudioObjectID(22)]
        let tap = AppAudioCapture.makeTapDescription(target: .processes([]), processObjectIDs: ids)
        XCTAssertEqual(tap.processes, ids)
    }
}
