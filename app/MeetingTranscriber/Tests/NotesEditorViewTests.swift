import AppKit
@testable import MeetingTranscriber
import SwiftUI
import ViewInspector
import XCTest

/// In-file fake `NotesStoring`. Deliberately not shared with the sibling
/// units building the panel or the real store — this file owns nothing
/// outside `Sources/Notes/NotesEditorView.swift` / `NotesTextView.swift`.
private final class FakeNotesStore: NotesStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    func load(_ target: NoteTarget) -> String {
        lock.lock()
        defer { lock.unlock() }
        return storage[key(target)] ?? ""
    }

    func save(_ text: String, to target: NoteTarget) {
        lock.lock()
        defer { lock.unlock() }
        storage[key(target)] = text
    }

    func append(_ text: String, to target: NoteTarget) {
        lock.lock()
        defer { lock.unlock() }
        storage[key(target), default: ""] += text
    }

    func take(stem _: String) -> String? {
        nil
    }

    func fileURL(for target: NoteTarget) -> URL {
        URL(fileURLWithPath: "/tmp/w1-notes-tests/\(key(target)).md")
    }

    private func key(_ target: NoteTarget) -> String {
        switch target {
        case let .liveRecording(stem, _): "live-\(stem)"

        case let .scratch(day): "scratch-\(Int(day.timeIntervalSince1970))"
        }
    }
}

/// One `XCTestCase` per repo convention (`single_test_class`): SwiftUI
/// (ViewInspector) coverage of `NotesEditorView` first, then the AppKit-layer
/// wiring of `NotesMarkdownTextView`/`NotesTextView.Coordinator` — both
/// constructible and drivable without a window (this machine cannot run
/// `swift test` for ANY package; see the repo's own note). CI is this
/// suite's first real execution.
@MainActor
final class NotesEditorViewTests: XCTestCase {
    // MARK: - Helpers

    private func makeController(target: NoteTarget, now: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> NotesController {
        NotesController(store: FakeNotesStore(), resolveTarget: { target }, now: { now })
    }

    private func makeTextView(text: String, caret: Int) -> NotesMarkdownTextView {
        let textView = NotesMarkdownTextView()
        textView.string = text
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        return textView
    }

    private func keyEvent(character: String, modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: 0,
        ))
    }

    // MARK: - Rendering smoke (ViewInspector)

    func testViewRendersForLiveTarget() throws {
        let controller = makeController(target: .liveRecording(stem: "20260101_120000", startedAt: Date()))
        XCTAssertNoThrow(try NotesEditorView(controller: controller).inspect())
    }

    func testViewRendersForScratchTarget() throws {
        let controller = makeController(target: .scratch(day: Date()))
        XCTAssertNoThrow(try NotesEditorView(controller: controller).inspect())
    }

    // MARK: - Header (ViewInspector)

    func testHeaderShowsRecordingStartTimeForLiveTarget() throws {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let controller = makeController(target: .liveRecording(stem: "20260101_120000", startedAt: startedAt))
        let body = try NotesEditorView(controller: controller).inspect()
        let texts = body.findAll(ViewType.Text.self)
        let found = texts.contains { (try? $0.string())?.hasPrefix("Recording since ") == true }
        XCTAssertTrue(found, "expected a header Text starting with 'Recording since '")
    }

    func testHeaderShowsDateForScratchTarget() throws {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let controller = makeController(target: .scratch(day: day))
        let expected: String = {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            return formatter.string(from: day)
        }()
        let body = try NotesEditorView(controller: controller).inspect()
        let texts = body.findAll(ViewType.Text.self)
        let found = texts.contains { (try? $0.string()) == expected }
        XCTAssertTrue(found, "expected a header Text equal to '\(expected)'")
    }

    // MARK: - Footer (ViewInspector)

    func testFooterShowsFileName() throws {
        let controller = makeController(target: .scratch(day: Date()))
        let expectedName = controller.fileURL.lastPathComponent
        let body = try NotesEditorView(controller: controller).inspect()
        let texts = body.findAll(ViewType.Text.self)
        let found = texts.contains { (try? $0.string()) == expectedName }
        XCTAssertTrue(found, "expected a footer Text equal to '\(expectedName)'")
    }

    // MARK: - Timestamp button (ViewInspector)

    func testTimestampButtonDisabledForScratchTarget() throws {
        let controller = makeController(target: .scratch(day: Date()))
        let body = try NotesEditorView(controller: controller).inspect()
        let button = try body.find(viewWithAccessibilityIdentifier: A11yID.notesTimestampButton)
        XCTAssertTrue(button.isDisabled())
    }

    func testTimestampButtonEnabledForLiveTarget() throws {
        let controller = makeController(target: .liveRecording(stem: "20260101_120000", startedAt: Date()))
        let body = try NotesEditorView(controller: controller).inspect()
        let button = try body.find(viewWithAccessibilityIdentifier: A11yID.notesTimestampButton)
        XCTAssertFalse(button.isDisabled())
    }

    func testTimestampButtonTapDoesNotThrow() throws {
        let controller = makeController(target: .liveRecording(stem: "20260101_120000", startedAt: Date()))
        let body = try NotesEditorView(controller: controller).inspect()
        let button = try body.find(viewWithAccessibilityIdentifier: A11yID.notesTimestampButton)
        XCTAssertNoThrow(try button.button().tap())
    }

    // MARK: - NotesMarkdownTextView: Return

    func testReturnAfterNonBlankBulletItemContinuesList() {
        let textView = makeTextView(text: "- item", caret: 6)
        textView.insertNewline(nil)
        XCTAssertEqual(textView.string, "- item\n- ")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 9, length: 0))
    }

    func testReturnAfterBlankBulletItemEndsListInsteadOfContinuing() {
        let textView = makeTextView(text: "- ", caret: 2)
        textView.insertNewline(nil)
        XCTAssertEqual(textView.string, "")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 0))
    }

    func testReturnMidLineFallsBackToOrdinaryNewline() {
        // Caret inside "- item", not at the end of the line — the special
        // continuation/end-list handling only applies at line end.
        let textView = makeTextView(text: "- item", caret: 2)
        textView.insertNewline(nil)
        XCTAssertEqual(textView.string, "- \nitem")
    }

    // MARK: - NotesMarkdownTextView: Tab / Shift-Tab

    func testTabOnListLineIndents() {
        let textView = makeTextView(text: "- item", caret: 2)
        textView.insertTab(nil)
        XCTAssertEqual(textView.string, "  - item")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 4, length: 0))
    }

    func testTabOnNonListLineInsertsLiteralTabInstead() {
        let textView = makeTextView(text: "plain text", caret: 0)
        textView.insertTab(nil)
        XCTAssertEqual(textView.string, "\tplain text")
    }

    func testShiftTabOnListLineOutdents() {
        let textView = makeTextView(text: "  - item", caret: 4)
        textView.insertBacktab(nil)
        XCTAssertEqual(textView.string, "- item")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 2, length: 0))
    }

    // MARK: - NotesMarkdownTextView: ⌘B / ⌘I

    func testCommandBTogglesBoldWrap() throws {
        let textView = makeTextView(text: "hello world", caret: 0)
        textView.setSelectedRange(NSRange(location: 0, length: 5))
        let event = try keyEvent(character: "b", modifiers: .command)
        XCTAssertTrue(textView.performKeyEquivalent(with: event))
        XCTAssertEqual(textView.string, "**hello** world")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 2, length: 5))
    }

    func testCommandITogglesItalicWrap() throws {
        let textView = makeTextView(text: "hello world", caret: 0)
        textView.setSelectedRange(NSRange(location: 0, length: 5))
        let event = try keyEvent(character: "i", modifiers: .command)
        XCTAssertTrue(textView.performKeyEquivalent(with: event))
        XCTAssertEqual(textView.string, "*hello* world")
    }

    // MARK: - NotesMarkdownTextView: ⌘T

    func testCommandTInsertsControllerTimestampAtCaret() throws {
        let textView = makeTextView(text: "hello world", caret: 5)
        textView.onInsertTimestamp = { "[12:34]" }
        let event = try keyEvent(character: "t", modifiers: .command)
        XCTAssertTrue(textView.performKeyEquivalent(with: event))
        XCTAssertEqual(textView.string, "hello[12:34]  world")
    }

    func testCommandTDoesNothingWhenOnInsertTimestampReturnsNil() throws {
        let textView = makeTextView(text: "hello world", caret: 5)
        textView.onInsertTimestamp = { nil }
        let event = try keyEvent(character: "t", modifiers: .command)
        XCTAssertTrue(textView.performKeyEquivalent(with: event))
        XCTAssertEqual(textView.string, "hello world")
    }

    // MARK: - NotesMarkdownTextView: Escape

    func testEscapeCallsOnEscape() {
        let textView = NotesMarkdownTextView()
        var closed = false
        textView.onEscape = { closed = true }
        textView.cancelOperation(nil)
        XCTAssertTrue(closed)
    }

    // MARK: - NotesTextView.Coordinator

    func testCoordinatorTextDidChangeWritesBackToBinding() {
        var bound = ""
        let binding = Binding<String>(get: { bound }, set: { bound = $0 })
        let coordinator = NotesTextView.Coordinator(text: binding)
        let textView = NotesMarkdownTextView()
        textView.string = "typed text"

        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))

        XCTAssertEqual(bound, "typed text")
    }

    func testCoordinatorIgnoresNotificationFromAnUnrelatedObject() {
        var bound = "unchanged"
        let binding = Binding<String>(get: { bound }, set: { bound = $0 })
        let coordinator = NotesTextView.Coordinator(text: binding)

        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: NSObject()))

        XCTAssertEqual(bound, "unchanged")
    }

    // MARK: - Live styling wiring

    /// Proves the wiring, not just the parts: `MarkdownLiveStyle.runs` is
    /// covered on its own in `MarkdownLiveStyleTests`, but this asserts
    /// `NotesTextView.applyStyle` actually turns a run into the matching
    /// `NSAttributedString` attributes on a real `NSTextStorage`.
    func testApplyStyleMutesSyntaxAndBoldsEmphasisContent() throws {
        let textView = NotesMarkdownTextView()
        textView.string = "**bold**"
        NotesTextView.applyStyle(to: textView)
        let storage = try XCTUnwrap(textView.textStorage)

        let syntaxColor = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(syntaxColor, NSColor.secondaryLabelColor, "opening ** must be muted")

        let contentFont = try XCTUnwrap(storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)
        let traits = NSFontManager.shared.traits(of: contentFont)
        XCTAssertTrue(traits.contains(.boldFontMask), "bold content must render in a bold font")
    }
}
