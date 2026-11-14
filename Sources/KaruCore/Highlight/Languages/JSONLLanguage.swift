import Foundation

/// JSON Lines / newline-delimited JSON.
///
/// Each line is an independent JSON value, so JSONL is JSON's definition
/// (rules, string profile, key follower) under another identifier and file
/// extensions.
public enum JSONLLanguage {
    /// See `JSONLanguage.buildCount`.
    nonisolated(unsafe) public static var buildCount = 0

    public static func make() -> LanguageDefinition {
        buildCount += 1
        return LanguageDefinition(
            identifier: "jsonl",
            fileExtensions: ["jsonl", "ndjson"],
            // Reuse JSON's rules, profile and key follower — JSONL is JSON per line.
            rules: JSONLanguage.rules(),
            keywords: ["true", "false", "null"],
            lexicalProfile: JSONLanguage.lexicalProfile,
            propertyStringFollower: JSONLanguage.keyFollower
        )
    }
}
