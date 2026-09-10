import Foundation

/// Decides how the notes editor should style each character of the raw
/// markdown text, without ever hiding a syntax character.
///
/// Pure: no AppKit, no NSTextView. `NotesTextView` calls `runs(in:)` after
/// every edit and turns the result into `NSAttributedString` attributes; this
/// type only decides ranges and meaning, so the decision can be tested
/// without a window (this machine cannot run a live NSTextView test at all —
/// see the repo's `swift test` note).
///
/// Ranges are `NSRange` (UTF-16), the coordinate system `NSTextStorage` and
/// `NSTextView.selectedRange()` already speak, but everything internally
/// stays on native `String`/`Range<String.Index>` — `NSString` is a legacy
/// bridging type the repo's lint config forbids (`legacy_objc_type`), and
/// `NSRange(_:in:)`/`Range(_:in:)` are the non-legacy way to cross between
/// the two coordinate systems.
///
/// Deliberately not a full markdown parser: inline emphasis (bold/italic/code)
/// is only scanned inside plain prose and inside list/checkbox/numbered-item
/// content. A heading or block-quote line's content renders as one styled
/// span with no nested emphasis scanning — hiding markers and full nesting is
/// the "different, much larger editor" the caller explicitly stays out of.
enum MarkdownLiveStyle {
    /// One styled span. Ranges are UTF-16 (`NSRange`) so they drop straight
    /// into `NSTextStorage`, and are never empty.
    struct Run: Equatable {
        let range: NSRange
        let style: Style
    }

    enum Style: Equatable {
        case heading(level: Int)
        case bold
        case italic
        case code
        case listMarker
        case checkbox(checked: Bool)
        case quote
        case syntax
    }

    /// All styled spans in `text`, in ascending, non-overlapping range order.
    static func runs(in text: String) -> [Run] {
        var result: [Run] = []
        text.enumerateSubstrings(in: text.startIndex ..< text.endIndex, options: [.byLines]) { line, substringRange, _, _ in
            guard let line else { return }
            let lineStart = NSRange(substringRange, in: text).location
            result.append(contentsOf: runsForLine(line, lineStart: lineStart))
        }
        return result
    }

    // MARK: - Per-line block detection

    private static func runsForLine(_ line: String, lineStart: Int) -> [Run] {
        let full = NSRange(location: 0, length: line.utf16.count)

        if let match = headingRegex?.firstMatch(in: line, range: full) {
            let level: Int = match.range(at: 1).length
            let content: NSRange = match.range(at: 2)
            return blockRuns(markerEnd: content.location, content: content, contentStyle: .heading(level: level), lineStart: lineStart)
        }

        if let match = quoteRegex?.firstMatch(in: line, range: full) {
            let content: NSRange = match.range(at: 2)
            return blockRuns(markerEnd: content.location, content: content, contentStyle: .quote, lineStart: lineStart)
        }

        if let match = checkboxRegex?.firstMatch(in: line, range: full) {
            let dash: NSRange = match.range(at: 2)
            let state: NSRange = match.range(at: 3)
            let box = NSRange(location: state.location - 1, length: 3)
            let checked: Bool = substring(line, state).lowercased() == "x"
            let content: NSRange = match.range(at: 4)
            var runs: [Run] = [
                shifted(dash, style: .listMarker, by: lineStart),
                shifted(box, style: .checkbox(checked: checked), by: lineStart),
            ]
            runs.append(contentsOf: inlineRuns(in: line, range: content, lineStart: lineStart))
            return runs
        }

        if let match = numberedRegex?.firstMatch(in: line, range: full) {
            let marker: NSRange = match.range(at: 2)
            let content: NSRange = match.range(at: 3)
            var runs: [Run] = [shifted(marker, style: .listMarker, by: lineStart)]
            runs.append(contentsOf: inlineRuns(in: line, range: content, lineStart: lineStart))
            return runs
        }

        if let match = bulletRegex?.firstMatch(in: line, range: full) {
            let marker: NSRange = match.range(at: 2)
            let content: NSRange = match.range(at: 3)
            var runs: [Run] = [shifted(marker, style: .listMarker, by: lineStart)]
            runs.append(contentsOf: inlineRuns(in: line, range: content, lineStart: lineStart))
            return runs
        }

        return inlineRuns(in: line, range: full, lineStart: lineStart)
    }

    /// Shared shape for heading/quote: a `.syntax` run over the marker
    /// (everything before `content`) plus one styled run over `content`.
    private static func blockRuns(markerEnd: Int, content: NSRange, contentStyle: Style, lineStart: Int) -> [Run] {
        var runs: [Run] = [shifted(NSRange(location: 0, length: markerEnd), style: .syntax, by: lineStart)]
        if content.length > 0 {
            runs.append(shifted(content, style: contentStyle, by: lineStart))
        }
        return runs
    }

    // MARK: - Inline emphasis

    /// Bold, italic and code spans inside `range` of `line`. A single
    /// combined, ordered regex (code, then bold, then italic) so adjoining
    /// markers — `**bold**` next to `*italic*` — resolve without the two
    /// patterns fighting over the same `*` characters.
    private static func inlineRuns(in line: String, range: NSRange, lineStart: Int) -> [Run] {
        guard let regex = inlineRegex else { return [] }
        var runs: [Run] = []
        for match in regex.matches(in: line, range: range) {
            let matched = substring(line, match.range)
            let delimiterLength: Int
            let style: Style
            if matched.hasPrefix("`") {
                delimiterLength = 1
                style = .code
            } else if matched.hasPrefix("**") {
                delimiterLength = 2
                style = .bold
            } else {
                delimiterLength = 1
                style = .italic
            }
            let open = NSRange(location: match.range.location, length: delimiterLength)
            let close = NSRange(location: match.range.location + match.range.length - delimiterLength, length: delimiterLength)
            let content = NSRange(
                location: match.range.location + delimiterLength,
                length: match.range.length - 2 * delimiterLength,
            )
            runs.append(shifted(open, style: .syntax, by: lineStart))
            if content.length > 0 {
                runs.append(shifted(content, style: style, by: lineStart))
            }
            runs.append(shifted(close, style: .syntax, by: lineStart))
        }
        return runs
    }

    private static func shifted(_ range: NSRange, style: Style, by offset: Int) -> Run {
        Run(range: NSRange(location: range.location + offset, length: range.length), style: style)
    }

    /// `range` (UTF-16, local to `line`) as a `String`, without bridging
    /// through `NSString`.
    private static func substring(_ line: String, _ range: NSRange) -> String {
        guard let swiftRange = Range(range, in: line) else { return "" }
        return String(line[swiftRange])
    }

    // MARK: - Patterns

    private static let headingRegex = try? NSRegularExpression(pattern: #"^(#{1,6}) (.*)$"#)
    private static let quoteRegex = try? NSRegularExpression(pattern: #"^(\s*> )(.*)$"#)
    private static let checkboxRegex = try? NSRegularExpression(pattern: #"^(\s*)([-*+]) \[([ xX])\] (.*)$"#)
    private static let numberedRegex = try? NSRegularExpression(pattern: #"^(\s*)(\d+\.) (.*)$"#)
    private static let bulletRegex = try? NSRegularExpression(pattern: #"^(\s*)([-*+]) (.*)$"#)
    private static let inlineRegex = try? NSRegularExpression(pattern: "`[^`]+`|\\*\\*[^*]+\\*\\*|\\*[^*]+\\*")
}
