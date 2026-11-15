import Foundation

/// JSON language definition — the reference sample for T3.1.
///
/// Strings come from `lexicalProfile` (M17 long-line slicing): one `"…"` form,
/// single-line, `\` escapes, no comments. JSON has no multi-line constructs,
/// so the profile only matters when a slice starts in the middle of a long
/// (minified) line: the scanner state then says whether it is inside a
/// string. Object keys — a string followed by optional whitespace and a colon
/// on the same line — are `.jsonKey` through `propertyStringFollower` (VS
/// Code's `support.type.property-name.json`, its own colour in Light Modern;
/// T17.15d), every other string `.string`. Numbers, literals and punctuation
/// are rules.
public enum JSONLanguage {
    /// Number of times `make()` has run this process. Used only by tests to
    /// prove that definitions are built lazily / on demand.
    nonisolated(unsafe) public static var buildCount = 0

    /// Strings only; shared with JSONL.
    public static let lexicalProfile = LexicalProfile(
        strings: [.init(delimiter: .fixed(open: "\"", close: "\""), multiline: false, escapeForms: [.unicode4])]
    )

    /// What follows a key string (`propertyStringFollower`); shared with JSONL.
    public static let keyFollower = #"\s*:"#

    /// Rules for the code between strings; shared with JSONL.
    static func rules() -> [LanguageRule] {
        [
            // Number: optional sign, int part, optional fraction, optional
            // exponent (covers e.g. -0.5, 42, 1.5e2, 1E-3).
            LanguageRule(pattern: #"-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?"#, kind: .number),
            // Literals.
            LanguageRule(pattern: #"\b(?:true|false|null)\b"#, kind: .keyword),
            // Structural punctuation.
            LanguageRule(pattern: #"[{}\[\]:,]"#, kind: .punctuation),
        ]
    }

    /// Builds a fresh JSON definition. Callers should go through
    /// `LanguageRegistry` (which caches); this is the registry's factory.
    public static func make() -> LanguageDefinition {
        buildCount += 1
        return LanguageDefinition(
            identifier: "json",
            fileExtensions: ["json"],
            rules: rules(),
            keywords: ["true", "false", "null"],
            lexicalProfile: lexicalProfile,
            propertyStringFollower: keyFollower,
            propertyStringKind: .jsonKey
        )
    }
}
