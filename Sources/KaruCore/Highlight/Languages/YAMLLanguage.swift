import Foundation

/// YAML definition (v1, line-based).
///
/// YAML's indentation is structurally significant, but v1 tokenizing is purely
/// per-line colouring (ARCHITECTURE.md §3.6): keys, scalars and comments are
/// coloured where they appear without parsing the block structure.
///
/// Line-approximation trade-offs accepted for v1:
/// - Mapping keys are recognised by a trailing `:` (`key:` / `"quoted key":`);
///   a plain scalar that merely contains a colon is not mistaken for a key
///   because the key rule only fires at the start of a scan position.
/// - Multi-line scalars (`|` / `>` block scalars) are not tracked across lines;
///   each line is coloured on its own.
public enum YAMLLanguage {
    /// See `JSONLanguage.buildCount`.
    nonisolated(unsafe) public static var buildCount = 0

    public static func make() -> LanguageDefinition {
        buildCount += 1
        // Boolean / null literals surfaced to completion. YAML accepts several
        // spellings; the tokenizer's keyword rule mirrors this list.
        let keywords = [
            "true", "false", "null", "yes", "no", "on", "off",
        ]
        let kw = keywords.joined(separator: "|")

        return LanguageDefinition(
            identifier: "yaml",
            fileExtensions: ["yaml", "yml"],
            rules: [
                // Document markers (start of line only).
                LanguageRule(pattern: #"^(?:---|\.\.\.)"#, kind: .punctuation),
                // Quoted mapping keys (win over the generic string rule).
                LanguageRule(pattern: #""[^"\n]*"(?=\s*:)"#, kind: .property),
                LanguageRule(pattern: #"'[^'\n]*'(?=\s*:)"#, kind: .property),
                // Plain mapping key: an identifier immediately followed by `:`.
                LanguageRule(pattern: #"[A-Za-z_][\w.-]*(?=\s*:(?:\s|$))"#, kind: .property),
                // Comment (a `#` reached outside a string).
                LanguageRule(pattern: #"#.*"#, kind: .comment),
                // Quoted scalar values.
                LanguageRule(pattern: #""(?:[^"\\]|\\.)*""#, kind: .string),
                LanguageRule(pattern: #"'(?:[^']|'')*'"#, kind: .string),
                // Anchors / aliases (`&anchor`, `*alias`) and tags (`!!str`).
                LanguageRule(pattern: #"[&*][A-Za-z_][\w-]*"#, kind: .type),
                LanguageRule(pattern: #"!!?[A-Za-z_][\w-]*"#, kind: .type),
                // Boolean / null keywords, plus the `~` null shorthand.
                LanguageRule(pattern: "\\b(?:\(kw))\\b", kind: .keyword),
                LanguageRule(pattern: #"~"#, kind: .keyword),
                // Numbers (integer / float, optional exponent).
                LanguageRule(
                    pattern: #"(?<![\w.])[+-]?(?:0[xX][0-9a-fA-F]+|(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?)"#,
                    kind: .number
                ),
            ],
            keywords: keywords,
            builtins: []
        )
    }
}
