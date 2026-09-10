@testable import MeetingTranscriber
import XCTest

/// `NotesMerge`'s pure markdown surgery: putting notes text into a protocol
/// document without disturbing anything else in it.
final class NotesMergeTests: XCTestCase {
    // MARK: - section(notes:)

    func testSectionIsHeadingBlankLineThenNotesVerbatim() {
        XCTAssertEqual(NotesMerge.section(notes: "Ask about budget"), "## Notes\n\nAsk about budget")
    }

    // MARK: - merged(document:notes:) — no existing section

    /// No frontmatter: the section goes at the very top, and everything else
    /// — including `## Full Transcript` at the end — survives untouched.
    func testInsertsAtTopWhenNoFrontmatterAndNoExistingSection() {
        let doc = """
        # Meeting Protocol - Standup

        ## Summary
        Stuff happened.

        ---

        ## Full Transcript

        [00:01] Luka: hi
        """
        let result = NotesMerge.merged(document: doc, notes: "Remember to follow up")

        XCTAssertTrue(result.hasPrefix("## Notes\n\nRemember to follow up\n\n# Meeting Protocol"))
        XCTAssertTrue(result.contains("## Full Transcript\n\n[00:01] Luka: hi"))
        XCTAssertEqual(result.components(separatedBy: "## Notes").count, 2)
    }

    /// Frontmatter present: the section goes right after the closing fence,
    /// before the protocol body, and `## Full Transcript` is untouched.
    func testInsertsAfterFrontmatterWhenNoExistingSection() {
        let doc = """
        ---
        schema: 1
        title: "Standup"
        ---

        # Meeting Protocol - Standup

        ## Summary
        Stuff happened.

        ---

        ## Full Transcript

        [00:01] Luka: hi
        """
        let result = NotesMerge.merged(document: doc, notes: "Ask about budget")

        XCTAssertTrue(result.contains("title: \"Standup\"\n---\n\n## Notes\n\nAsk about budget\n\n# Meeting Protocol"))
        XCTAssertTrue(result.contains("## Full Transcript\n\n[00:01] Luka: hi"))
        XCTAssertEqual(result.components(separatedBy: "## Notes").count, 2)
    }

    // MARK: - merged(document:notes:) — existing section

    /// Appending to an existing section adds underneath the current content,
    /// separated by a blank line, without repeating the heading, and keeps
    /// the document's own `---` divider attached to `## Full Transcript`
    /// rather than swallowing it into the Notes section's content.
    func testAppendsUnderneathExistingSection() {
        let doc = """
        # Meeting Protocol - Standup

        ## Notes

        First note.

        ---

        ## Full Transcript

        [00:01] Luka: hi
        """
        let expected = """
        # Meeting Protocol - Standup

        ## Notes

        First note.

        Second note.

        ---

        ## Full Transcript

        [00:01] Luka: hi
        """
        XCTAssertEqual(NotesMerge.merged(document: doc, notes: "Second note."), expected)
    }

    /// Merging twice must not produce two `## Notes` headings, and every
    /// appended block must survive.
    func testAppendingTwiceProducesExactlyOneHeading() {
        let doc = "## Notes\n\nFirst.\n\n---\n\n## Full Transcript\n\ntext"
        let once = NotesMerge.merged(document: doc, notes: "Second.")
        let twice = NotesMerge.merged(document: once, notes: "Third.")

        XCTAssertEqual(twice.components(separatedBy: "## Notes").count, 2)
        XCTAssertTrue(twice.contains("First."))
        XCTAssertTrue(twice.contains("Second."))
        XCTAssertTrue(twice.contains("Third."))
        XCTAssertTrue(twice.contains("## Full Transcript\n\ntext"))
    }

    // MARK: - Empty notes

    func testEmptyNotesLeavesDocumentByteIdentical() {
        let doc = "## Notes\n\nExisting.\n\n---\n\n## Full Transcript\n\ntext"
        XCTAssertEqual(NotesMerge.merged(document: doc, notes: ""), doc)
    }

    func testWhitespaceOnlyNotesLeavesDocumentByteIdentical() {
        let doc = "## Notes\n\nExisting.\n\n---\n\n## Full Transcript\n\ntext"
        XCTAssertEqual(NotesMerge.merged(document: doc, notes: "   \n\n  "), doc)
    }
}
