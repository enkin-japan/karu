import Foundation

/// Content-based language detection, used as a fallback when a file's extension
/// resolves to no registered language (or the document has no name yet — pasted
/// / untitled buffers). Pure logic, no AppKit, so it stays trivially testable.
///
/// Only the leading 8 KB of text is inspected: sniffing runs on every paste /
/// edit of an untitled buffer, so the cost is capped regardless of document
/// size (ARCHITECTURE.md §1 performance budget). Detection is deliberately
/// conservative — an unrecognised buffer returns `nil` rather than guessing.
public enum LanguageSniffer {
    /// Maximum number of leading bytes inspected.
    private static let sampleByteLimit = 8 * 1024

    /// Returns a language identifier (matching `LanguageDefinition.identifier`,
    /// e.g. `"python"`) inferred from `text`, or `nil` when nothing matches.
    /// Rules are applied in priority order (see the task spec / inline notes).
    public static func sniff(_ text: String) -> String? {
        let sample = truncate(text, toBytes: sampleByteLimit)
        guard !sample.isEmpty else { return nil }
        let lines = sample.components(separatedBy: "\n")

        // 1. Shebang: the interpreter name pins the language.
        if let first = lines.first, first.hasPrefix("#!") {
            if first.contains("python") { return "python" }
            if first.range(of: "\\b(bash|zsh|sh)\\b", options: .regularExpression) != nil { return "bash" }
            if first.contains("node") { return "javascript" }
        }

        // 2. XML / HTML document markers (case-insensitive).
        let lower = sample.lowercased()
        if lower.contains("<?xml") || lower.contains("<!doctype plist") { return "xml" }
        if lower.contains("<!doctype html") || lower.contains("<html") { return "html" }

        // 3. JSON / JSONL: only when the first non-space glyph opens a container.
        if let firstNonWS = sample.first(where: { !$0.isWhitespace }),
           firstNonWS == "{" || firstNonWS == "[" {
            if let id = sniffJSON(lines: lines) { return id }
        }

        // 4. Markdown: at least two heading / fence features in the first 10 lines.
        var markdownFeatures = 0
        for line in lines.prefix(10) {
            if line.range(of: "^#{1,6} ", options: .regularExpression) != nil { markdownFeatures += 1 }
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { markdownFeatures += 1 }
        }
        if markdownFeatures >= 2 { return "markdown" }

        // 5a. ES-module imports (`import X from 'y'`) are JavaScript-only syntax —
        // Python spells it `from y import X` — so this must outrank the Python
        // rule, whose `^import\s` would otherwise claim these lines.
        if countMatchingLines(lines, "^import .* from ") >= 2 { return "javascript" }

        // 5b. Python: two or more statement-leading keywords.
        if countMatchingLines(lines, "^(def|class|import|from)\\s") >= 2 { return "python" }

        // 6. JS / TS (not distinguished — reported as javascript).
        if countMatchingLines(lines, "^(import .* from|const |let |function )") >= 2 { return "javascript" }

        // 7. C family: an angle-bracket include.
        if sample.range(of: "#include\\s*<", options: .regularExpression) != nil { return "c" }

        // 8. SQL: a statement keyword opening the first non-empty line.
        if let firstNonEmpty = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           firstNonEmpty.range(of: "(?i)^(select|insert|create|update)\\b", options: .regularExpression) != nil {
            return "sql"
        }

        return nil
    }

    // MARK: - JSON / JSONL

    /// Distinguishes a single JSON document from a JSONL stream. A JSON document
    /// parses whole (first 50 lines as a sample); a JSONL stream instead has
    /// every non-empty line parse as its own value, with two or more such lines.
    /// A truncated-and-therefore-unparseable sample simply yields no match.
    private static func sniffJSON(lines: [String]) -> String? {
        let jsonSample = lines.prefix(50).joined(separator: "\n")
        if (try? JSONFormatter.prettyPrint(jsonSample)) != nil { return "json" }

        var total = 0
        var parsed = 0
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            total += 1
            if (try? JSONFormatter.prettyPrint(trimmed)) != nil { parsed += 1 }
        }
        if total >= 2 && parsed == total { return "jsonl" }
        return nil
    }

    // MARK: - Helpers

    private static func countMatchingLines(_ lines: [String], _ pattern: String) -> Int {
        var count = 0
        for line in lines where line.range(of: pattern, options: .regularExpression) != nil {
            count += 1
        }
        return count
    }

    /// Returns the leading `maxBytes` UTF-8 bytes of `text` as a string. A cut
    /// that lands mid-scalar is tolerated (decoded lossily) — sniffing does not
    /// need byte-exact fidelity at the boundary.
    private static func truncate(_ text: String, toBytes maxBytes: Int) -> String {
        let utf8 = text.utf8
        guard utf8.count > maxBytes else { return text }
        return String(decoding: Array(utf8.prefix(maxBytes)), as: UTF8.self)
    }
}
