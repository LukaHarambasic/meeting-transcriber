import Foundation

/// YAML frontmatter prepended to every protocol `.md`.
///
/// Exists so the `.md` is machine-readable without anything having to parse
/// prose back out of it. Everything here is already known to the pipeline at
/// the moment the protocol is written; re-deriving any of it from the body
/// later would be guesswork.
///
/// Pure and separate from the writer for the usual reason: the interesting
/// behaviour is the escaping, and a frontmatter block that a parser rejects is
/// worse than none — the file looks fine to a human and every agent reading it
/// fails on the same line.
struct ProtocolFrontmatter: Equatable {
    /// Bumped when a field is removed or its meaning changes, so a consumer can
    /// refuse a file it does not understand instead of silently misreading it.
    /// Adding an optional field does not need a bump.
    static let schemaVersion = 1

    var title: String
    /// Meeting start, or nil for an import or a recovered recording.
    ///
    /// Deliberately optional and deliberately never defaulted to "now": the
    /// pipeline's rule is that processing time must never be presented as
    /// meeting time. A consumer seeing no `date` knows the time is unknown,
    /// which is true and useful; a consumer seeing the wrong date does not.
    var startedAt: Date?
    var durationSeconds: Int?
    /// Human participants, when known. Usually empty: the roster reader went
    /// with meeting auto-detection.
    var participants: [String]
    /// Speaker labels as they appear in the transcript body, so a renaming tool
    /// knows what to look for without parsing the transcript first.
    var speakers: [String]
    var appName: String?
    var engine: String?
    var language: String?
    /// Audio location relative to the protocol, when the app kept a copy.
    var audioPath: String?

    // MARK: - Rendering

    /// The complete block, `---` fences included, with a trailing blank line so
    /// the body starts cleanly.
    func render(generatedBy: String = Self.defaultGeneratorTag) -> String {
        var lines = ["---"]
        lines.append("schema: \(Self.schemaVersion)")
        lines.append("title: \(Self.quote(title))")
        if let startedAt {
            lines.append("date: \(Self.dateFormatter.string(from: startedAt))")
            lines.append("time: \(Self.quote(Self.timeFormatter.string(from: startedAt)))")
        }
        if let durationSeconds {
            lines.append("duration_seconds: \(durationSeconds)")
        }
        lines.append("participants: \(Self.flowList(participants))")
        lines.append("speakers: \(Self.flowList(speakers))")
        if let appName, !appName.isEmpty {
            lines.append("app: \(Self.quote(appName))")
        }
        if let engine, !engine.isEmpty {
            lines.append("engine: \(Self.quote(engine))")
        }
        if let language, !language.isEmpty {
            lines.append("language: \(Self.quote(language))")
        }
        if let audioPath, !audioPath.isEmpty {
            lines.append("audio: \(Self.quote(audioPath))")
        }
        // Always last and always present: a file with no provenance cannot be
        // told apart from one a human wrote by hand.
        lines.append("generated_by: \(Self.quote(generatedBy))")
        lines.append("tags: []")
        lines.append("---")
        return lines.joined(separator: "\n") + "\n\n"
    }

    static var defaultGeneratorTag: String {
        "meeting-transcriber \(Bundle.main.appVersion)"
    }

    // MARK: - YAML escaping

    /// Double-quoted YAML scalar.
    ///
    /// Always quoted, never bare. A bare scalar is where YAML frontmatter goes
    /// wrong in ways nobody notices: a title containing `: ` becomes a nested
    /// mapping, one starting with `#` becomes a comment, one that reads as
    /// `yes`/`no`/`null`/`1.0` becomes a bool, null or float, and a leading `-`
    /// or `[` starts a collection. Meeting titles are user- and app-supplied,
    /// so all of those are reachable.
    ///
    /// Inside double quotes YAML needs exactly backslash and double-quote
    /// escaped; the control characters a title could carry (a newline pasted
    /// from a calendar entry, a tab) are escaped rather than emitted raw,
    /// because a raw newline would end the scalar and shift every following
    /// line into the wrong field.
    static func quote(_ value: String) -> String {
        var out = ""
        for character in value.unicodeScalars {
            switch character {
            case "\\": out += "\\\\"

            case "\"": out += "\\\""

            case "\n": out += "\\n"

            case "\r": out += "\\r"

            case "\t": out += "\\t"

            default:
                // Other C0 controls have no legal raw form in a quoted scalar.
                if character.value < 0x20 {
                    out += String(format: "\\x%02x", character.value)
                } else {
                    out.unicodeScalars.append(character)
                }
            }
        }
        return "\"" + out + "\""
    }

    /// Flow-style list (`[]` when empty), each element quoted.
    ///
    /// Flow rather than block style so an empty list is representable on one
    /// line: block style has no empty form, and emitting the key with nothing
    /// under it yields `null` rather than `[]`, which a consumer doing
    /// `for p in participants` then trips over.
    static func flowList(_ values: [String]) -> String {
        guard !values.isEmpty else { return "[]" }
        return "[" + values.map(quote).joined(separator: ", ") + "]"
    }

    // MARK: - Derivation

    /// Speaker labels in the order they first appear in the transcript.
    ///
    /// The transcript's real shape is `[00:01] Luka: text` — the bracket holds a
    /// **timestamp**, and the speaker follows it. The first version of this read
    /// the bracket as the label and produced `speakers: ["00:01"]`, which is
    /// worse than producing nothing: a renaming tool would have gone looking for
    /// a speaker called "00:01".
    ///
    /// Both shapes are handled, because the un-timestamped `[Label] text` form
    /// is what a diarized-but-unnamed transcript looks like:
    /// - `[00:01] Luka: text`  → `Luka`
    /// - `[Speaker 1] text`    → `Speaker 1`
    ///
    /// First-appearance order rather than sorted, so `speakers` reads the way
    /// the meeting did.
    static func speakers(inTranscript transcript: String) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for line in transcript.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let label = speakerLabel(inLine: String(line)),
                  seen.insert(label).inserted
            else { continue }
            ordered.append(label)
        }
        return ordered
    }

    /// The speaker on one transcript line, or nil if it carries none.
    ///
    /// Internal rather than private so the two shapes can be asserted directly;
    /// the timestamp case is the one that was wrong.
    static func speakerLabel(inLine line: String) -> String? {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
        let inner = String(line[line.index(after: line.startIndex) ..< close])
        guard !inner.isEmpty else { return nil }

        // A bracket of digits and colons is a timestamp, so the speaker is the
        // `Name:` that follows it.
        if !isTimestamp(inner) {
            return inner
        }
        let rest = line[line.index(after: close)...].drop { $0 == " " }
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let name = rest[..<colon].trimmingCharacters(in: .whitespaces)
        // A cap, because a line with no speaker but a colon later in the prose
        // would otherwise yield a sentence as a "speaker".
        guard !name.isEmpty, name.count <= 40 else { return nil }
        return name
    }

    /// Whether a bracket's contents are a timestamp rather than a name.
    /// Deliberately shape-based (digits and colons only) rather than a strict
    /// `HH:MM:SS` match, so an hours-long meeting's `1:02:03` counts too.
    private static func isTimestamp(_ value: String) -> Bool {
        value.allSatisfy { $0.isNumber || $0 == ":" } && value.contains(":")
    }

    // Pinned POSIX/Gregorian: these are machine-read fields, so a regional
    // calendar or a localised month name would break every consumer.
    private static let dateFormatter = DateFormatter.filenameStamp("yyyy-MM-dd")
    private static let timeFormatter = DateFormatter.filenameStamp("HH:mm")
}
