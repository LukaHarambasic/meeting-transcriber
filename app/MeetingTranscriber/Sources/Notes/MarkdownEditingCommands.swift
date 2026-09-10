import Foundation

/// Pure editing operations for the notes editor: what Return, Tab/Shift-Tab
/// and ⌘B/⌘I do to the text and the selection.
///
/// No AppKit beyond `NSRange` (UTF-16 code-unit offsets, the coordinate
/// system `NSTextView.selectedRange()` already speaks), so every rule here is
/// testable without a window — this machine cannot run a live NSTextView
/// test at all (see the repo's `swift test` note). `NotesTextView` is the
/// only caller and stays a thin translation from AppKit key events into
/// these functions and back.
///
/// Internals stay on native `String`/`Range<String.Index>` — `NSString` is a
/// legacy bridging type the repo's lint config forbids (`legacy_objc_type`);
/// `NSRange(_:in:)`/`Range(_:in:)` cross between the two coordinate systems
/// without it.
enum MarkdownEditingCommands {
    // MARK: - Return

    /// What Return should insert after `line` (the full text of the line the
    /// caret sat on, no trailing newline) when the caret is at the end of the
    /// line: `"\n"` plus this string continues a list/checkbox/numbered item.
    /// `nil` for a blank item (call `isBlankListItem` — that case should end
    /// the list, not continue it) and for ordinary prose.
    static func continuation(after line: String) -> String? {
        guard let parsed = parseListLine(line), !parsed.content.isEmpty else { return nil }
        switch parsed.kind {
        case let .bullet(marker):
            return parsed.indent + String(marker) + " "

        case .checkbox:
            // A new item is always unchecked, regardless of whether the item
            // above it was checked.
            return parsed.indent + "- [ ] "

        case let .numbered(value):
            return parsed.indent + String(value + 1) + ". "
        }
    }

    /// Whether `line` is a list/checkbox/numbered item with no content past
    /// its marker — the case where Return should end the list by clearing
    /// the marker instead of inserting another item.
    static func isBlankListItem(_ line: String) -> Bool {
        guard let parsed = parseListLine(line) else { return false }
        return parsed.content.isEmpty
    }

    /// Whether `line` is a list/checkbox/numbered item at all (blank or
    /// not). Gates Tab/Shift-Tab: those indent/outdent a list item and
    /// otherwise fall back to ordinary tab-character insertion.
    static func isListLine(_ line: String) -> Bool {
        parseListLine(line) != nil
    }

    // MARK: - Bold / italic (⌘B / ⌘I)

    /// Wraps `selection` in `token` (`"**"` for bold, `"*"` for italic), or
    /// removes an already-present wrapping — the same shortcut toggles both
    /// ways. An empty selection wraps at the caret and leaves it between the
    /// two markers, so a second press with nothing selected removes them
    /// again.
    ///
    /// A known simplification: detection only looks at the `token`-length
    /// characters immediately outside the selection, so `*` (italic) can
    /// mistake the second character of an adjoining `**` (bold) marker for
    /// its own — full nested-emphasis awareness is out of scope here, same
    /// as marker-hiding.
    static func toggleWrap(text: String, selection: NSRange, token: String) -> (text: String, selection: NSRange) {
        let tokenLength = token.utf16.count
        let before = NSRange(location: selection.location - tokenLength, length: tokenLength)
        let after = NSRange(location: NSMaxRange(selection), length: tokenLength)

        if matches(before, in: text, token), matches(after, in: text, token) {
            let withoutAfter = replacing(text, after, with: "")
            let withoutBoth = replacing(withoutAfter, before, with: "")
            let newSelection = NSRange(location: selection.location - tokenLength, length: selection.length)
            return (withoutBoth, newSelection)
        }

        let withAfter = replacing(text, NSRange(location: NSMaxRange(selection), length: 0), with: token)
        let withBoth = replacing(withAfter, NSRange(location: selection.location, length: 0), with: token)
        let newSelection = NSRange(location: selection.location + tokenLength, length: selection.length)
        return (withBoth, newSelection)
    }

    private static func matches(_ range: NSRange, in text: String, _ token: String) -> Bool {
        guard range.location >= 0, NSMaxRange(range) <= text.utf16.count else { return false }
        return substring(text, range) == token
    }

    // MARK: - Indent / outdent (Tab / Shift-Tab)

    static let indentUnit = "  "

    /// Adds `indentUnit` at the start of the line the selection begins on.
    static func indent(text: String, selection: NSRange) -> (text: String, selection: NSRange) {
        guard let line = lineRange(at: selection.location, in: text) else { return (text, selection) }
        let unitLength = indentUnit.utf16.count
        let newText = replacing(text, NSRange(location: line.location, length: 0), with: indentUnit)
        let newSelection = NSRange(location: selection.location + unitLength, length: selection.length)
        return (newText, newSelection)
    }

    /// Removes up to `indentUnit`'s worth of leading whitespace (or a single
    /// leading tab) from the line the selection begins on. A no-op when the
    /// line has no leading whitespace to remove.
    static func outdent(text: String, selection: NSRange) -> (text: String, selection: NSRange) {
        guard let line = lineRange(at: selection.location, in: text) else { return (text, selection) }
        let lineText = substring(text, line)
        let removable = leadingRemovableCount(lineText)
        guard removable > 0 else { return (text, selection) }

        let newText = replacing(text, NSRange(location: line.location, length: removable), with: "")
        let shift = min(removable, selection.location - line.location)
        let newSelection = NSRange(location: selection.location - shift, length: selection.length)
        return (newText, newSelection)
    }

    private static func leadingRemovableCount(_ line: String) -> Int {
        if line.first == "\t" { return 1 }
        let maxCount = indentUnit.utf16.count
        var count = 0
        for character in line {
            guard count < maxCount, character == " " else { break }
            count += 1
        }
        return count
    }

    // MARK: - NSRange <-> String helpers

    /// The NSRange (UTF-16, in `text`'s own coordinates) of the line
    /// containing UTF-16 offset `location`, or nil when `location` doesn't
    /// land on a valid boundary.
    private static func lineRange(at location: Int, in text: String) -> NSRange? {
        guard let point = Range(NSRange(location: location, length: 0), in: text) else { return nil }
        return NSRange(text.lineRange(for: point), in: text)
    }

    private static func substring(_ text: String, _ range: NSRange) -> String {
        guard let swiftRange = Range(range, in: text) else { return "" }
        return String(text[swiftRange])
    }

    private static func replacing(_ text: String, _ range: NSRange, with replacement: String) -> String {
        guard let swiftRange = Range(range, in: text) else { return text }
        return text.replacingCharacters(in: swiftRange, with: replacement)
    }

    // MARK: - List-line parsing

    private enum ListKind: Equatable {
        case bullet(Character)
        case checkbox(checked: Bool)
        case numbered(Int)
    }

    private struct ParsedListLine {
        let indent: String
        let kind: ListKind
        let content: String
    }

    private static func parseListLine(_ line: String) -> ParsedListLine? {
        let full = NSRange(location: 0, length: line.utf16.count)

        if let match = checkboxRegex?.firstMatch(in: line, range: full) {
            let indent = substring(line, match.range(at: 1))
            let checked = substring(line, match.range(at: 3)).lowercased() == "x"
            let content = substring(line, match.range(at: 4))
            return ParsedListLine(indent: indent, kind: .checkbox(checked: checked), content: content)
        }
        if let match = numberedRegex?.firstMatch(in: line, range: full) {
            let indent = substring(line, match.range(at: 1))
            let number = Int(substring(line, match.range(at: 2))) ?? 0
            let content = substring(line, match.range(at: 3))
            return ParsedListLine(indent: indent, kind: .numbered(number), content: content)
        }
        if let match = bulletRegex?.firstMatch(in: line, range: full) {
            let indent = substring(line, match.range(at: 1))
            let markerString = substring(line, match.range(at: 2))
            guard let markerChar = markerString.first else { return nil }
            let content = substring(line, match.range(at: 3))
            return ParsedListLine(indent: indent, kind: .bullet(markerChar), content: content)
        }
        return nil
    }

    private static let checkboxRegex = try? NSRegularExpression(pattern: #"^(\s*)([-*+]) \[([ xX])\] (.*)$"#)
    private static let numberedRegex = try? NSRegularExpression(pattern: #"^(\s*)(\d+)\. (.*)$"#)
    private static let bulletRegex = try? NSRegularExpression(pattern: #"^(\s*)([-*+]) (.*)$"#)
}
