import AppKit
import SwiftUI

/// `NSTextView` subclass carrying the editing behaviours the pure
/// `MarkdownEditingCommands` describe: Return continues (or ends) a
/// list/checkbox/numbered item, Tab/Shift-Tab indent/outdent one, ⌘B/⌘I
/// toggle-wrap the selection, ⌘T inserts a timestamp, Escape closes the panel.
///
/// Every override here does the minimum AppKit plumbing (read the current
/// line/selection, ask a pure function what should happen, write the result
/// back) — the decision itself always lives in `MarkdownEditingCommands` or
/// `MarkdownLiveStyle`, which is what this machine can actually test (no
/// window is needed to construct or drive this class directly; see
/// `NotesEditorViewTests`).
///
/// Stays on native `String`/`Range<String.Index>` internally and bridges to
/// `NSRange` only via `NSRange(_:in:)`/`Range(_:in:)` — `NSString` is a
/// legacy bridging type the repo's lint config forbids (`legacy_objc_type`).
final class NotesMarkdownTextView: NSTextView {
    /// The ⌘T insertion text (`NotesController.timestamp()`), or nil for a
    /// scratch note — matching the controller's own contract.
    var onInsertTimestamp: (() -> String?)?
    /// Escape — `NotesController.close()`.
    var onEscape: (() -> Void)?

    // MARK: - Return

    override func insertNewline(_ sender: Any?) {
        let text = string
        let caret = selectedRange().location
        guard let point = Range(NSRange(location: caret, length: 0), in: text) else {
            super.insertNewline(sender)
            return
        }
        let lineSwiftRange = text.lineRange(for: point)
        let line = Self.stripLineTerminator(String(text[lineSwiftRange]))
        let lineRange = NSRange(lineSwiftRange, in: text)
        let contentEnd = lineRange.location + line.utf16.count

        // Only the shapes described in the brief are special-cased: caret at
        // the end of a list/checkbox/numbered line. Anywhere else (mid-line,
        // or a line that isn't a list item) is ordinary Return.
        guard caret == contentEnd else {
            super.insertNewline(sender)
            return
        }

        if MarkdownEditingCommands.isBlankListItem(line) {
            let markerRange = NSRange(location: lineRange.location, length: contentEnd - lineRange.location)
            guard shouldChangeText(in: markerRange, replacementString: "") else { return }
            textStorage?.replaceCharacters(in: markerRange, with: "")
            didChangeText()
            setSelectedRange(NSRange(location: lineRange.location, length: 0))
            return
        }

        if let continuation = MarkdownEditingCommands.continuation(after: line) {
            let insertion = "\n" + continuation
            let range = selectedRange()
            guard shouldChangeText(in: range, replacementString: insertion) else { return }
            textStorage?.replaceCharacters(in: range, with: insertion)
            didChangeText()
            setSelectedRange(NSRange(location: range.location + insertion.utf16.count, length: 0))
            return
        }

        super.insertNewline(sender)
    }

    // MARK: - Tab / Shift-Tab

    override func insertTab(_ sender: Any?) {
        guard currentLineIsListLine() else {
            super.insertTab(sender)
            return
        }
        apply(MarkdownEditingCommands.indent(text: string, selection: selectedRange()))
    }

    override func insertBacktab(_ sender: Any?) {
        guard currentLineIsListLine() else {
            super.insertBacktab(sender)
            return
        }
        apply(MarkdownEditingCommands.outdent(text: string, selection: selectedRange()))
    }

    private func currentLineIsListLine() -> Bool {
        let text = string
        guard let point = Range(NSRange(location: selectedRange().location, length: 0), in: text) else { return false }
        let line = Self.stripLineTerminator(String(text[text.lineRange(for: point)]))
        return MarkdownEditingCommands.isListLine(line)
    }

    // MARK: - ⌘B / ⌘I / ⌘T

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let key = event.charactersIgnoringModifiers?.lowercased()
        else {
            return super.performKeyEquivalent(with: event)
        }

        switch key {
        case "b":
            apply(MarkdownEditingCommands.toggleWrap(text: string, selection: selectedRange(), token: "**"))
            return true

        case "i":
            apply(MarkdownEditingCommands.toggleWrap(text: string, selection: selectedRange(), token: "*"))
            return true

        case "t":
            insertTimestamp()
            return true

        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    /// Called for both the ⌘T shortcut and the header's timestamp button
    /// (via `NotesTextView.timestampTrigger`), so both insert at the live
    /// caret through the same path.
    func insertTimestamp() {
        guard let stamp = onInsertTimestamp?() else { return }
        insertText(stamp + " ", replacementRange: selectedRange())
    }

    // MARK: - Escape

    override func cancelOperation(_: Any?) {
        onEscape?()
    }

    // MARK: - Whole-text command application

    /// `MarkdownEditingCommands.indent`/`outdent`/`toggleWrap` return a whole
    /// new text plus the resulting selection; notes are a few kilobytes (see
    /// `NotesStoring`), so replacing the full `textStorage` contents per
    /// keystroke costs less than diffing for a minimal edit.
    private func apply(_ result: (text: String, selection: NSRange)) {
        guard let storage = textStorage else { return }
        let full = NSRange(location: 0, length: string.utf16.count)
        guard shouldChangeText(in: full, replacementString: result.text) else { return }
        storage.replaceCharacters(in: full, with: result.text)
        didChangeText()
        setSelectedRange(result.selection)
    }

    private static func stripLineTerminator(_ line: String) -> String {
        if line.hasSuffix("\r\n") { return String(line.dropLast(2)) }
        if line.hasSuffix("\n") || line.hasSuffix("\r") { return String(line.dropLast()) }
        return line
    }
}

/// Bridges `NotesMarkdownTextView` into SwiftUI: syncs `text` both ways,
/// re-applies `MarkdownLiveStyle` after every change, and relays the header's
/// timestamp button through `timestampTrigger` so the button and ⌘T insert at
/// the same live caret position via the same `NotesMarkdownTextView.insertTimestamp()`.
struct NotesTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var timestampTrigger: Bool
    var onInsertTimestamp: () -> String?
    var onClose: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NotesMarkdownTextView()
        textView.delegate = context.coordinator
        textView.onInsertTimestamp = onInsertTimestamp
        textView.onEscape = onClose
        textView.string = text
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.drawsBackground = false
        textView.font = Self.baseFont
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]
        textView.setAccessibilityIdentifier(A11yID.notesEditor)
        Self.applyStyle(to: textView)

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context _: Context) {
        guard let textView = nsView.documentView as? NotesMarkdownTextView else { return }
        textView.onInsertTimestamp = onInsertTimestamp
        textView.onEscape = onClose

        if textView.string != text {
            textView.string = text
            Self.applyStyle(to: textView)
        }

        if timestampTrigger {
            textView.insertTimestamp()
            // Deferred: flipping the binding back synchronously here would
            // mutate state during this same SwiftUI update pass.
            DispatchQueue.main.async { timestampTrigger = false }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NotesMarkdownTextView else { return }
            text = textView.string
            NotesTextView.applyStyle(to: textView)
        }
    }

    // MARK: - Styling

    static let baseFont = NSFont.systemFont(ofSize: 13)

    static func applyStyle(to textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let text = storage.string
        let fullLength = text.utf16.count
        let full = NSRange(location: 0, length: fullLength)
        storage.beginEditing()
        storage.setAttributes([.font: baseFont, .foregroundColor: NSColor.labelColor], range: full)
        for run in MarkdownLiveStyle.runs(in: text) where NSMaxRange(run.range) <= fullLength {
            storage.addAttributes(attributes(for: run.style), range: run.range)
        }
        storage.endEditing()
    }

    private static func attributes(for style: MarkdownLiveStyle.Style) -> [NSAttributedString.Key: Any] {
        switch style {
        case let .heading(level):
            [.font: headingFont(level: level)]

        case .bold:
            [.font: NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)]

        case .italic:
            [.font: NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)]

        case .code:
            [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ]

        case .listMarker:
            [.foregroundColor: NSColor.controlAccentColor]

        case let .checkbox(checked):
            [.foregroundColor: checked ? NSColor.systemGreen : NSColor.controlAccentColor]

        case .quote:
            [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask),
            ]

        case .syntax:
            [.foregroundColor: NSColor.secondaryLabelColor]
        }
    }

    private static func headingFont(level: Int) -> NSFont {
        let size: CGFloat = switch level {
        case 1: 22
        case 2: 19
        case 3: 17
        default: 15
        }
        return NSFontManager.shared.convert(NSFont.systemFont(ofSize: size), toHaveTrait: .boldFontMask)
    }
}
