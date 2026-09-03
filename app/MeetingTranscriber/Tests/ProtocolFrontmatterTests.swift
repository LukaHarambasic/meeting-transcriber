@testable import MeetingTranscriber
import XCTest

/// The frontmatter's escaping and shape.
///
/// Worth testing hard because the failure is silent in the worst direction: a
/// block that a YAML parser rejects, or worse silently misreads, still looks
/// fine to a human reading the `.md`. Every agent consuming these files then
/// fails on the same line.
final class ProtocolFrontmatterTests: XCTestCase {
    private func make(
        title: String = "Standup",
        startedAt: Date? = nil,
        durationSeconds: Int? = nil,
        participants: [String] = [],
        speakers: [String] = [],
        appName: String? = nil,
        engine: String? = nil,
        language: String? = nil,
        audioPath: String? = nil,
    ) -> ProtocolFrontmatter {
        ProtocolFrontmatter(
            title: title,
            startedAt: startedAt,
            durationSeconds: durationSeconds,
            participants: participants,
            speakers: speakers,
            appName: appName,
            engine: engine,
            language: language,
            audioPath: audioPath,
        )
    }

    // MARK: - Shape

    func testRenderIsFencedAndEndsWithABlankLine() {
        let out = make().render(generatedBy: "test")
        XCTAssertTrue(out.hasPrefix("---\n"))
        XCTAssertTrue(out.hasSuffix("---\n\n"), "the body must start on a clean line")
    }

    /// `schema` is what lets a consumer refuse a file it does not understand
    /// rather than misread it, so it is never optional.
    func testSchemaAndProvenanceAreAlwaysPresent() {
        let out = make().render(generatedBy: "meeting-transcriber 9.9.9")
        XCTAssertTrue(out.contains("schema: \(ProtocolFrontmatter.schemaVersion)"))
        XCTAssertTrue(out.contains("generated_by: \"meeting-transcriber 9.9.9\""))
    }

    /// Empty lists must render as `[]`, not as an absent value. A key with
    /// nothing under it parses as `null`, and a consumer iterating it trips.
    func testEmptyListsRenderAsEmptyFlowLists() {
        let out = make().render(generatedBy: "test")
        XCTAssertTrue(out.contains("participants: []"))
        XCTAssertTrue(out.contains("speakers: []"))
    }

    /// The pipeline's standing rule: processing time is never presented as
    /// meeting time. An import has no start, so it gets no `date` at all.
    func testNoDateWhenTheStartIsUnknown() {
        let out = make(startedAt: nil).render(generatedBy: "test")
        XCTAssertFalse(out.contains("date:"))
        XCTAssertFalse(out.contains("time:"))
    }

    func testDateAndTimeAreMachineReadable() {
        // 2026-09-03 14:34 local.
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 3
        components.hour = 14; components.minute = 34
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        guard let date = calendar.date(from: components) else {
            XCTFail("could not build the fixture date")
            return
        }
        let out = make(startedAt: date).render(generatedBy: "test")
        XCTAssertTrue(out.contains("date: 2026-09-03"), out)
        XCTAssertTrue(out.contains("time: \"14:34\""), out)
    }

    func testOptionalFieldsAreOmittedRatherThanEmptied() {
        let out = make(appName: "", engine: nil, language: "", audioPath: nil)
            .render(generatedBy: "test")
        for key in ["app:", "engine:", "language:", "audio:", "duration_seconds:"] {
            XCTAssertFalse(out.contains(key), "\(key) should be absent, not empty")
        }
    }

    // MARK: - Escaping

    /// Every one of these is a real meeting title and every one of them changes
    /// meaning if emitted bare: `: ` opens a nested mapping, `#` a comment,
    /// `yes`/`null` become a bool and a null, `1.0` a float, and a leading `-`
    /// or `[` starts a collection.
    func testTitlesThatWouldChangeTypeOrStructureAreQuoted() {
        for title in ["Standup: daily", "#retro", "yes", "no", "null", "1.0", "- sync", "[draft]", ""] {
            let out = make(title: title).render(generatedBy: "test")
            XCTAssertTrue(
                out.contains("title: \(ProtocolFrontmatter.quote(title))"),
                "title \(title.debugDescription) must be quoted",
            )
        }
    }

    func testQuotesAndBackslashesAreEscaped() {
        XCTAssertEqual(ProtocolFrontmatter.quote(#"a "b" c"#), #""a \"b\" c""#)
        XCTAssertEqual(ProtocolFrontmatter.quote(#"a\b"#), #""a\\b""#)
    }

    /// A raw newline would end the scalar and shift every following line into
    /// the wrong field — the one escaping bug that corrupts the whole block
    /// rather than one value.
    func testControlCharactersCannotBreakOutOfTheScalar() {
        let rendered = ProtocolFrontmatter.quote("a\nb\tc\rd")
        XCTAssertEqual(rendered, #""a\nb\tc\rd""#)
        XCTAssertFalse(rendered.contains("\n"), "a literal newline escapes the scalar")
    }

    func testATitleWithANewlineKeepsTheBlockOneLinePerField() {
        let out = make(title: "Standup\nparticipants: [\"injected\"]").render(generatedBy: "test")
        let fieldLines = out.split(separator: "\n").filter { $0.hasPrefix("participants:") }
        XCTAssertEqual(fieldLines, ["participants: []"], "a title must not be able to forge a field")
    }

    func testListElementsAreQuotedIndividually() {
        XCTAssertEqual(ProtocolFrontmatter.flowList(["a", "b: c"]), #"["a", "b: c"]"#)
        XCTAssertEqual(ProtocolFrontmatter.flowList([]), "[]")
    }

    // MARK: - Speaker derivation

    func testSpeakersAreTakenInFirstAppearanceOrder() {
        let transcript = """
        [Speaker 2] hello
        [Speaker 1] hi
        [Speaker 2] again
        """
        XCTAssertEqual(
            ProtocolFrontmatter.speakers(inTranscript: transcript),
            ["Speaker 2", "Speaker 1"],
            "order should read the way the meeting did, not sorted",
        )
    }

    func testUnlabelledTranscriptYieldsNoSpeakers() {
        XCTAssertEqual(ProtocolFrontmatter.speakers(inTranscript: "just some text\nand more"), [])
    }

    /// A line missing its closing bracket must not swallow the rest of the
    /// transcript into one enormous "speaker".
    func testMalformedLabelIsIgnored() {
        XCTAssertEqual(ProtocolFrontmatter.speakers(inTranscript: "[Speaker 1 hello\nworld"), [])
    }

    func testEmptyLabelIsIgnored() {
        XCTAssertEqual(ProtocolFrontmatter.speakers(inTranscript: "[] hello"), [])
    }
}
