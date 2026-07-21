import Foundation

/// JSON Lines / newline-delimited JSON.
///
/// Each line is an independent JSON value, so the line-based tokenizer is exact
/// here just as it is for JSON. The rules are reused verbatim from
/// `JSONLanguage` (JSONL is structurally identical to JSON); only the
/// identifier and file extensions differ.
public enum JSONLLanguage {
    /// See `JSONLanguage.buildCount`.
    nonisolated(unsafe) public static var buildCount = 0

    public static func make() -> LanguageDefinition {
        buildCount += 1
        return LanguageDefinition(
            identifier: "jsonl",
            fileExtensions: ["jsonl", "ndjson"],
            // Reuse JSON's rule set unchanged — JSONL is JSON per line.
            rules: JSONLanguage.make().rules,
            keywords: ["true", "false", "null"]
        )
    }
}
