import Foundation
@testable import MeetingTranscriber
import XCTest

/// `MarkdownEditingCommands` is pure Foundation (no AppKit), so these run
/// without a window — this machine cannot run `swift test` for ANY package
/// (no Xcode; see the repo's own note). CI is this suite's first real
/// execution; the same assertions were proven locally against a throwaway
/// `swiftc` driver copy of the source file before this file was written (see
/// the W1 unit report).
final class MarkdownEditingCommandsTests: XCTestCase {
    // MARK: - continuation

    func testBulletContinuationReusesMarker() {
        XCTAssertEqual(MarkdownEditingCommands.continuation(after: "- buy milk"), "- ")
    }

    func testBulletContinuationPreservesMarkerCharacter() {
        XCTAssertEqual(MarkdownEditingCommands.continuation(after: "* buy milk"), "* ")
    }

    func testCheckboxContinuationIsAlwaysUnchecked() {
        XCTAssertEqual(MarkdownEditingCommands.continuation(after: "- [ ] task one"), "- [ ] ")
    }

    func testCheckboxContinuationUncheckedEvenAfterACheckedItem() {
        XCTAssertEqual(MarkdownEditingCommands.continuation(after: "- [x] task one"), "- [ ] ")
    }

    func testNumberedContinuationIncrements() {
        XCTAssertEqual(MarkdownEditingCommands.continuation(after: "2. second"), "3. ")
    }

    func testContinuationPreservesIndent() {
        XCTAssertEqual(MarkdownEditingCommands.continuation(after: "  - nested"), "  - ")
    }

    func testBlankBulletItemReturnsNilContinuation() {
        XCTAssertNil(MarkdownEditingCommands.continuation(after: "- "))
    }

    func testOrdinaryProseReturnsNilContinuation() {
        XCTAssertNil(MarkdownEditingCommands.continuation(after: "Just a sentence."))
    }

    // MARK: - isBlankListItem

    func testBlankBulletItemIsDetected() {
        XCTAssertTrue(MarkdownEditingCommands.isBlankListItem("- "))
    }

    func testBlankCheckboxItemIsDetected() {
        XCTAssertTrue(MarkdownEditingCommands.isBlankListItem("- [ ] "))
    }

    func testBlankNumberedItemIsDetected() {
        XCTAssertTrue(MarkdownEditingCommands.isBlankListItem("3. "))
    }

    func testNonBlankBulletItemIsNotBlank() {
        XCTAssertFalse(MarkdownEditingCommands.isBlankListItem("- buy milk"))
    }

    func testOrdinaryProseIsNotABlankListItem() {
        XCTAssertFalse(MarkdownEditingCommands.isBlankListItem("Just a sentence."))
    }

    // MARK: - isListLine

    func testBulletLineIsAListLine() {
        XCTAssertTrue(MarkdownEditingCommands.isListLine("- buy milk"))
    }

    func testBlankBulletLineIsStillAListLine() {
        XCTAssertTrue(MarkdownEditingCommands.isListLine("- "))
    }

    func testProseIsNotAListLine() {
        XCTAssertFalse(MarkdownEditingCommands.isListLine("Just a sentence."))
    }

    // MARK: - toggleWrap (⌘B / ⌘I)

    func testWrapInsertsTokenOnBothSidesAndKeepsSelectionOverContent() {
        let selection = NSRange(location: 0, length: 5) // "hello"
        let result = MarkdownEditingCommands.toggleWrap(text: "hello world", selection: selection, token: "**")
        XCTAssertEqual(result.text, "**hello** world")
        XCTAssertEqual(result.selection, NSRange(location: 2, length: 5))
    }

    func testWrapThenWrapAgainRoundTrips() {
        let text = "hello world"
        let selection = NSRange(location: 0, length: 5)
        let wrapped = MarkdownEditingCommands.toggleWrap(text: text, selection: selection, token: "**")
        let unwrapped = MarkdownEditingCommands.toggleWrap(text: wrapped.text, selection: wrapped.selection, token: "**")
        XCTAssertEqual(unwrapped.text, text)
        XCTAssertEqual(unwrapped.selection, selection)
    }

    func testEmptySelectionWrapInsertsBothMarkersAroundCaret() {
        let selection = NSRange(location: 5, length: 0)
        let result = MarkdownEditingCommands.toggleWrap(text: "hello", selection: selection, token: "**")
        XCTAssertEqual(result.text, "hello****")
        XCTAssertEqual(result.selection, NSRange(location: 7, length: 0))
    }

    func testEmptySelectionSecondToggleRemovesBothMarkers() {
        let text = "hello"
        let selection = NSRange(location: 5, length: 0)
        let wrapped = MarkdownEditingCommands.toggleWrap(text: text, selection: selection, token: "**")
        let unwrapped = MarkdownEditingCommands.toggleWrap(text: wrapped.text, selection: wrapped.selection, token: "**")
        XCTAssertEqual(unwrapped.text, text)
        XCTAssertEqual(unwrapped.selection, selection)
    }

    // MARK: - indent / outdent (Tab / Shift-Tab)

    func testIndentPrependsIndentUnit() {
        let selection = NSRange(location: 3, length: 0)
        let result = MarkdownEditingCommands.indent(text: "- item", selection: selection)
        XCTAssertEqual(result.text, "  - item")
        XCTAssertEqual(result.selection, NSRange(location: 5, length: 0))
    }

    func testIndentThenOutdentRoundTrips() {
        let text = "- item"
        let selection = NSRange(location: 3, length: 0)
        let indented = MarkdownEditingCommands.indent(text: text, selection: selection)
        let outdented = MarkdownEditingCommands.outdent(text: indented.text, selection: indented.selection)
        XCTAssertEqual(outdented.text, text)
        XCTAssertEqual(outdented.selection, selection)
    }

    func testOutdentOnUnindentedLineIsANoOp() {
        let text = "- item"
        let selection = NSRange(location: 0, length: 0)
        let result = MarkdownEditingCommands.outdent(text: text, selection: selection)
        XCTAssertEqual(result.text, text)
        XCTAssertEqual(result.selection, selection)
    }
}
