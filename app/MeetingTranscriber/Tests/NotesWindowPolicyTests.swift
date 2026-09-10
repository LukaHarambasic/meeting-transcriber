import AppKit
@testable import MeetingTranscriber
import XCTest

/// Unit coverage for the notes panel's window policy. `sharingType = .none`
/// is the property this whole feature depends on (measured separately, on
/// the real WindowServer, in the manual `/tmp/w2-probe` driver referenced in
/// the review notes — not repeatable in a headless XCTest), so this suite
/// pins that `apply(to:)` actually sets it rather than re-deriving the
/// screen-capture behaviour itself.
@MainActor
final class NotesWindowPolicyTests: XCTestCase {
    /// Build a panel whose relevant properties start in the OPPOSITE of the
    /// policy's target state, so each assertion proves `apply` actually
    /// changed it (an identity stub would leave `sharingType == .readOnly`
    /// and fail).
    ///
    /// The seeded `collectionBehavior` carries flags that are mutually
    /// exclusive with the ones `apply` sets: `.fullScreenNone` (same group as
    /// `.fullScreenAuxiliary`) and `.managed` (same group as
    /// `.canJoinAllSpaces`). `.ignoresCycle` is an unrelated bit that must
    /// survive untouched.
    private func makeUnpolicedPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true,
        )
        panel.sharingType = .readOnly
        panel.hidesOnDeactivate = true
        panel.level = .normal
        panel.collectionBehavior = [.managed, .fullScreenNone, .ignoresCycle]
        return panel
    }

    func testExcludesFromScreenCapture() {
        let panel = makeUnpolicedPanel()
        NotesWindowPolicy.apply(to: panel)
        XCTAssertEqual(
            panel.sharingType, .none,
            "notes panel must be excluded from screen capture / sharing (the whole point of the feature)",
        )
    }

    func testKeepsPanelVisibleWhenAppDeactivates() {
        let panel = makeUnpolicedPanel()
        NotesWindowPolicy.apply(to: panel)
        XCTAssertFalse(
            panel.hidesOnDeactivate,
            "notes panel must not hide when the app loses focus",
        )
    }

    func testFloatsAboveOtherAppWindows() {
        let panel = makeUnpolicedPanel()
        NotesWindowPolicy.apply(to: panel)
        XCTAssertEqual(
            panel.level, .floating,
            "notes panel should stay on top so it is one click away during a meeting",
        )
    }

    func testJoinsAllSpacesAndFullScreen() {
        let panel = makeUnpolicedPanel()
        NotesWindowPolicy.apply(to: panel)
        XCTAssertTrue(
            panel.collectionBehavior.contains(.canJoinAllSpaces),
            "notes panel should follow the user across Spaces",
        )
        XCTAssertTrue(
            panel.collectionBehavior.contains(.fullScreenAuxiliary),
            "notes panel should show over full-screen apps",
        )
    }

    func testClearsConflictingSpaceAndFullScreenBits() {
        let panel = makeUnpolicedPanel()
        NotesWindowPolicy.apply(to: panel)
        // `.canJoinAllSpaces` / `.fullScreenAuxiliary` are each in a
        // mutually-exclusive group; the conflicting members must be removed,
        // otherwise AppKit silently ignores the flags we want.
        XCTAssertFalse(
            panel.collectionBehavior.contains(.managed),
            "conflicting Space-participation bit must be cleared",
        )
        XCTAssertFalse(
            panel.collectionBehavior.contains(.fullScreenNone),
            "conflicting full-screen bit must be cleared so .fullScreenAuxiliary takes effect",
        )
    }

    func testPreservesUnrelatedCollectionBehaviorBits() {
        let panel = makeUnpolicedPanel()
        NotesWindowPolicy.apply(to: panel)
        XCTAssertTrue(
            panel.collectionBehavior.contains(.ignoresCycle),
            "apply must not clobber unrelated collection-behavior flags",
        )
    }

    func testIsIdempotent() {
        let panel = makeUnpolicedPanel()
        NotesWindowPolicy.apply(to: panel)
        let afterFirst = panel.collectionBehavior
        NotesWindowPolicy.apply(to: panel)
        XCTAssertEqual(panel.collectionBehavior, afterFirst)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertEqual(panel.level, .floating)
        XCTAssertEqual(panel.sharingType, .none)
    }
}
