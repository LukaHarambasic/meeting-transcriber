import Foundation
@testable import MeetingTranscriber
import XCTest

/// `MarkdownLiveStyle` is pure Foundation (no AppKit), so these run without a
/// window or a live NSTextView — which matters here, since this machine
/// cannot run `swift test` for ANY package (no Xcode; see the repo's own
/// note). CI is this suite's first real execution; the same assertions were
/// proven locally against a throwaway `swiftc` driver copy of the two
/// source files before this file was written (see the W1 unit report).
final class MarkdownLiveStyleTests: XCTestCase {
    // MARK: - Heading

    func testHeadingProducesSyntaxAndHeadingRun() {
        let runs = MarkdownLiveStyle.runs(in: "# Heading one")
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].style, .syntax)
        XCTAssertEqual(runs[0].range, NSRange(location: 0, length: 2))
        XCTAssertEqual(runs[1].style, .heading(level: 1))
        XCTAssertEqual(runs[1].range, NSRange(location: 2, length: 11))
    }

    func testHeadingLevelMatchesHashCount() {
        let runs = MarkdownLiveStyle.runs(in: "### Level three")
        XCTAssertEqual(runs.last?.style, .heading(level: 3))
    }

    func testSevenHashesIsNotAHeading() {
        // Not valid markdown (max level 6); falls through to plain prose.
        let runs = MarkdownLiveStyle.runs(in: "####### not a heading")
        XCTAssertTrue(runs.allSatisfy { $0.style != .heading(level: 6) })
    }

    // MARK: - Inline emphasis

    func testBoldProducesThreeRuns() {
        let runs = MarkdownLiveStyle.runs(in: "This is **bold** text")
        XCTAssertEqual(runs.count, 3)
        XCTAssertEqual(runs[0].style, .syntax)
        XCTAssertEqual(runs[1].style, .bold)
        XCTAssertEqual(runs[1].range, NSRange(location: 10, length: 4))
        XCTAssertEqual(runs[2].style, .syntax)
    }

    func testItalicProducesThreeRuns() {
        let runs = MarkdownLiveStyle.runs(in: "This is *italic* text")
        XCTAssertEqual(runs.count, 3)
        XCTAssertEqual(runs[1].style, .italic)
        XCTAssertEqual(runs[1].range, NSRange(location: 9, length: 6))
    }

    func testCodeSpanProducesThreeRuns() {
        let runs = MarkdownLiveStyle.runs(in: "Use `let x = 1` here")
        XCTAssertEqual(runs.count, 3)
        XCTAssertEqual(runs[1].style, .code)
        XCTAssertEqual(runs[1].range, NSRange(location: 5, length: 9))
    }

    /// Regression guard for the ambiguity a naive "bold OR italic" scan hits:
    /// with the wrong alternation, italic's `*` swallows one star of an
    /// adjoining `**` marker and neither span comes out right.
    func testAdjoiningBoldAndItalicDoNotSwallowEachOther() {
        let runs = MarkdownLiveStyle.runs(in: "**bold** and *italic*")
        let bold = runs.first { $0.style == .bold }
        let italic = runs.first { $0.style == .italic }
        XCTAssertEqual(bold?.range, NSRange(location: 2, length: 4))
        XCTAssertEqual(italic?.range, NSRange(location: 14, length: 6))
    }

    // MARK: - Lists

    func testBulletMarkerIsListMarker() {
        let runs = MarkdownLiveStyle.runs(in: "- a bullet item")
        XCTAssertEqual(runs.first?.style, .listMarker)
        XCTAssertEqual(runs.first?.range, NSRange(location: 0, length: 1))
    }

    func testUncheckedCheckboxRuns() {
        let runs = MarkdownLiveStyle.runs(in: "- [ ] unchecked item")
        XCTAssertEqual(runs[0].style, .listMarker)
        XCTAssertEqual(runs[1].style, .checkbox(checked: false))
        XCTAssertEqual(runs[1].range, NSRange(location: 2, length: 3))
    }

    func testCheckedCheckboxIsDistinctFromUnchecked() {
        let runs = MarkdownLiveStyle.runs(in: "- [x] done item")
        XCTAssertEqual(runs[1].style, .checkbox(checked: true))
        XCTAssertNotEqual(runs[1].style, .checkbox(checked: false))
    }

    func testNumberedMarkerIsListMarker() {
        let runs = MarkdownLiveStyle.runs(in: "1. first numbered item")
        XCTAssertEqual(runs.first?.style, .listMarker)
        XCTAssertEqual(runs.first?.range, NSRange(location: 0, length: 2))
    }

    // MARK: - Quote

    func testQuoteMarkerIsSyntaxAndContentIsQuote() {
        let runs = MarkdownLiveStyle.runs(in: "> a quoted line")
        XCTAssertEqual(runs[0].style, .syntax)
        XCTAssertEqual(runs[1].style, .quote)
    }

    // MARK: - Multi-line offsets

    func testSecondLineOffsetAccountsForFirstLineAndNewline() {
        let runs = MarkdownLiveStyle.runs(in: "line one\n- item two\n**bold** three")
        let listRun = runs.first { $0.style == .listMarker }
        XCTAssertEqual(listRun?.range.location, 9)
        XCTAssertTrue(runs.contains { $0.style == .bold })
    }

    // MARK: - Plain prose

    func testPlainProseHasNoRuns() {
        XCTAssertTrue(MarkdownLiveStyle.runs(in: "plain prose, nothing special").isEmpty)
    }
}
