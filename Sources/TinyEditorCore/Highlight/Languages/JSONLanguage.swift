import Foundation

/// JSON language definition — the reference sample for T3.1.
///
/// JSON has no multi-line constructs, so the line-based tokenizer is exact.
/// Rule order matters: the key rule (a string immediately followed by a colon)
/// is listed before the value-string rule so object keys are classified as
/// `.property` and everything else quoted as `.string`.
public enum JSONLanguage {
    /// Number of times `make()` has run this process. Used only by tests to
    /// prove that definitions are built lazily / on demand.
    nonisolated(unsafe) public static var buildCount = 0

    /// Builds a fresh JSON definition. Callers should go through
    /// `LanguageRegistry` (which caches); this is the registry's factory.
    public static func make() -> LanguageDefinition {
        buildCount += 1
        return LanguageDefinition(
            identifier: "json",
            fileExtensions: ["json"],
            rules: [
                // Key: a string whose closing quote is followed by a colon.
                LanguageRule(pattern: #""(?:[^"\\]|\\.)*"(?=\s*:)"#, kind: .property),
                // Value string.
                LanguageRule(pattern: #""(?:[^"\\]|\\.)*""#, kind: .string),
                // Number: optional sign, int part, optional fraction, optional
                // exponent (covers e.g. -0.5, 42, 1.5e2, 1E-3).
                LanguageRule(pattern: #"-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?"#, kind: .number),
                // Literals.
                LanguageRule(pattern: #"\b(?:true|false|null)\b"#, kind: .keyword),
                // Structural punctuation.
                LanguageRule(pattern: #"[{}\[\]:,]"#, kind: .punctuation),
            ],
            keywords: ["true", "false", "null"]
        )
    }
}
