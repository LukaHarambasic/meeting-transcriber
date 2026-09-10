import Foundation

/// Pure markdown surgery for putting notes text into a protocol document.
///
/// Line-based rather than regex-based so the two entry points reason about
/// the same unit (a whole line) as the headings they search for, and so the
/// rest of the document can be spliced back in completely unchanged — which
/// is what keeps `## Full Transcript` untouched no matter where it sits.
enum NotesMerge {
    /// The one spelling of the heading. A sibling unit composing a fresh
    /// document uses this via `section(notes:)` rather than writing the
    /// string itself, so the heading text has exactly one home.
    static let heading = "## Notes"

    /// The canonical `## Notes` block: heading, one blank line, then the
    /// notes verbatim. Used both to build a fresh document and, internally,
    /// as the shape a first-time insertion into an existing document takes.
    static func section(notes: String) -> String {
        heading + "\n\n" + notes
    }

    /// Put `notes` into `document`, which may already contain a `## Notes`
    /// section.
    ///
    /// Empty or whitespace-only `notes` leaves `document` byte-identical —
    /// there is nothing to merge, and a no-op call (the panel saves on every
    /// keystroke) must never touch a document that has nothing to add.
    static func merged(document: String, notes: String) -> String {
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNotes.isEmpty else { return document }

        var lines = document.components(separatedBy: "\n")
        if let headingIndex = lines.firstIndex(of: heading) {
            appendToExistingSection(&lines, headingIndex: headingIndex, trimmedNotes: trimmedNotes)
        } else {
            insertNewSection(&lines, trimmedNotes: trimmedNotes)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Existing `## Notes` section

    /// Appends `trimmedNotes` underneath the existing section's content,
    /// separated by a blank line, without repeating the heading. Everything
    /// from the next `##` heading onward (including `## Full Transcript`) is
    /// carried through unchanged.
    ///
    /// A generated document separates its trailing section from
    /// `## Full Transcript` with its own `---` horizontal rule, which is a
    /// document-level divider, not part of the previous section's content.
    /// When the existing `## Notes` section ends in one, it is treated as
    /// belonging with the next heading and re-emitted after the appended
    /// notes rather than swallowed into the section body.
    private static func appendToExistingSection(
        _ lines: inout [String], headingIndex: Int, trimmedNotes: String,
    ) {
        let nextHeadingIndex = lines[(headingIndex + 1)...]
            .firstIndex { $0.hasPrefix("## ") } ?? lines.count

        var existing = Array(lines[(headingIndex + 1) ..< nextHeadingIndex])
        trimBlankEdges(&existing)
        var trailingDivider = false
        if existing.last == "---" {
            existing.removeLast()
            trimBlankEdges(&existing)
            trailingDivider = true
        }

        var block = [""]
        if !existing.isEmpty {
            block.append(contentsOf: existing)
            block.append("")
        }
        block.append(contentsOf: trimmedNotes.components(separatedBy: "\n"))
        if trailingDivider {
            block.append("")
            block.append("---")
        }

        var replacement = Array(lines[0 ... headingIndex])
        replacement.append(contentsOf: block)
        if nextHeadingIndex < lines.count {
            replacement.append("")
            replacement.append(contentsOf: lines[nextHeadingIndex...])
        }
        lines = replacement
    }

    /// Removes leading and trailing blank (whitespace-only) lines in place.
    private static func trimBlankEdges(_ lines: inout [String]) {
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
    }

    // MARK: - No existing section

    /// Inserts a fresh `## Notes` section right after the YAML frontmatter
    /// block, or at the very top when there is none. Never reaches into the
    /// rest of the document beyond finding that one insertion point, so
    /// `## Full Transcript` (wherever it sits) is carried through unchanged.
    private static func insertNewSection(_ lines: inout [String], trimmedNotes: String) {
        let sectionLines = section(notes: trimmedNotes).components(separatedBy: "\n")

        guard let closingFenceIndex = frontmatterClosingFenceIndex(in: lines) else {
            var replacement = sectionLines
            replacement.append("")
            replacement.append(contentsOf: lines)
            lines = replacement
            return
        }

        var bodyStart = closingFenceIndex + 1
        while bodyStart < lines.count, lines[bodyStart].trimmingCharacters(in: .whitespaces).isEmpty {
            bodyStart += 1
        }

        var replacement = Array(lines[0 ... closingFenceIndex])
        replacement.append("")
        replacement.append(contentsOf: sectionLines)
        if bodyStart < lines.count {
            replacement.append("")
            replacement.append(contentsOf: lines[bodyStart...])
        }
        lines = replacement
    }

    /// Index of the closing `---` fence of a leading YAML frontmatter block
    /// (opening `---` as the very first line, arbitrary lines, closing
    /// `---`), or nil when the document does not open with one.
    private static func frontmatterClosingFenceIndex(in lines: [String]) -> Int? {
        guard lines.first == "---", lines.count > 1 else { return nil }
        for index in 1 ..< lines.count where lines[index] == "---" {
            return index
        }
        return nil
    }
}
