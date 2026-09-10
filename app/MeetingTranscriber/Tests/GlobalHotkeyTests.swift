import Carbon.HIToolbox
@testable import MeetingTranscriber
import XCTest

/// Unit coverage for the Carbon hotkey registration lifecycle.
///
/// Delivering a real synthetic keypress and asserting the handler fired is
/// out of scope here (and manual-QA-only per the repo's GUI testing rules):
/// it would require driving WindowServer from the test process, the same
/// class of thing `/ui/press` exists for on live app windows, which this
/// pure-SPM XCTest target cannot reach. Instead these tests pin the
/// observable registration lifecycle — the part a regression is likely to
/// break (a `stop()` or `deinit` that forgets to call
/// `UnregisterEventHotKey`, silently leaking the OS-level claim on the key
/// combo forever).
///
/// Uses a Control+Shift+F5 combo, not the app's real ⌥⌘N, so these tests
/// never collide with a real running instance of the app on the same
/// machine.
@MainActor
final class GlobalHotkeyTests: XCTestCase {
    private let testKeyCode: UInt32 = 96 // F5
    private let testModifiers = UInt32(shiftKey | controlKey)

    func testRegistersSuccessfully() {
        let hotkey = GlobalHotkey(keyCode: testKeyCode, modifiers: testModifiers) {}
        XCTAssertTrue(hotkey.isRegistered)
        hotkey.stop()
    }

    func testStopUnregistersSoTheSameComboCanBeReclaimed() {
        let first = GlobalHotkey(keyCode: testKeyCode, modifiers: testModifiers) {}
        XCTAssertTrue(first.isRegistered)
        first.stop()

        let second = GlobalHotkey(keyCode: testKeyCode, modifiers: testModifiers) {}
        XCTAssertTrue(
            second.isRegistered,
            "stop() must release the OS-level registration, not just flip a flag",
        )
        second.stop()
    }

    func testStopIsIdempotent() {
        let hotkey = GlobalHotkey(keyCode: testKeyCode, modifiers: testModifiers) {}
        hotkey.stop()
        hotkey.stop()
        XCTAssertFalse(hotkey.isRegistered)
    }

    func testSecondRegistrationOfTheSameComboFails() {
        let first = GlobalHotkey(keyCode: testKeyCode, modifiers: testModifiers) {}
        XCTAssertTrue(first.isRegistered)

        let second = GlobalHotkey(keyCode: testKeyCode, modifiers: testModifiers) {}
        XCTAssertFalse(second.isRegistered, "Carbon refuses a duplicate hotkey registration")

        first.stop()
        second.stop()
    }

    func testDeinitReleasesTheRegistrationWithoutExplicitStop() {
        var hotkey: GlobalHotkey? = GlobalHotkey(keyCode: testKeyCode, modifiers: testModifiers) {}
        XCTAssertTrue(hotkey?.isRegistered ?? false)
        hotkey = nil

        let after = GlobalHotkey(keyCode: testKeyCode, modifiers: testModifiers) {}
        XCTAssertTrue(
            after.isRegistered,
            "deinit must unregister the hotkey; otherwise the combo stays claimed after the owner is gone",
        )
        after.stop()
    }
}
