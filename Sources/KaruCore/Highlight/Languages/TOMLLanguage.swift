import Foundation

/// TOML definition (v1, line-based).
///
/// Line-approximation trade-offs accepted for v1:
/// - Table headers (`[table]`, `[[array]]`) are recognised only at the start of
///   a line, so an inline array (`x = [1, 2]`) is not mistaken for a table.
/// - Multi-line basic / literal strings (`"""` / `'''`) are coloured on their
///   opening line to end-of-line; interior and closing lines are not tracked
///   (no cross-line state).
public enum TOMLLanguage {
    /// See `JSONLanguage.buildCount`.
    nonisolated(unsafe) public static var buildCount = 0

    public static func make() -> LanguageDefinition {
        buildCount += 1
        let keywords = ["true", "false"]
        let kw = keywords.joined(separator: "|")

        return LanguageDefinition(
            identifier: "toml",
            fileExtensions: ["toml"],
            rules: [
                // Comment.
                LanguageRule(pattern: #"#.*"#, kind: .comment),
                // Table headers (start of line): array-of-tables before table.
                LanguageRule(pattern: #"^\[\[[^\]]*\]\]"#, kind: .type),
                LanguageRule(pattern: #"^\[[^\]]*\]"#, kind: .type),
                // Quoted keys (win over the generic string rule).
                LanguageRule(pattern: #""[^"\n]*"(?=\s*=)"#, kind: .property),
                LanguageRule(pattern: #"'[^'\n]*'(?=\s*=)"#, kind: .property),
                // Bare key: an identifier immediately followed by `=`.
                LanguageRule(pattern: #"[A-Za-z0-9_-]+(?=\s*=)"#, kind: .property),
                // Multi-line strings: complete-on-line, then open-to-end-of-line.
                LanguageRule(pattern: #""""(?:.*?"""|.*)"#, kind: .string),
                LanguageRule(pattern: #"'''(?:.*?'''|.*)"#, kind: .string),
                // Single-line basic and literal strings.
                LanguageRule(pattern: #""(?:[^"\\]|\\.)*""#, kind: .string),
                LanguageRule(pattern: #"'[^'\n]*'"#, kind: .string),
                // Dates / date-times (RFC 3339), coloured as numeric literals.
                LanguageRule(
                    pattern: #"(?<![\w.])\d{4}-\d{2}-\d{2}(?:[Tt ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:[Zz]|[+-]\d{2}:\d{2})?)?"#,
                    kind: .number
                ),
                // Booleans.
                LanguageRule(pattern: "\\b(?:\(kw))\\b", kind: .keyword),
                // Numbers with `_` separators (hex / octal / binary / decimal / float).
                LanguageRule(
                    pattern: #"(?<![\w.-])[+-]?(?:0[xX][0-9a-fA-F_]+|0[oO][0-7_]+|0[bB][01_]+|(?:\d[\d_]*(?:\.[\d_]*)?)(?:[eE][+-]?\d+)?)"#,
                    kind: .number
                ),
            ],
            keywords: keywords,
            builtins: []
        )
    }
}
