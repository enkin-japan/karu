import Foundation

/// TOML definition.
///
/// Comments and strings come from `lexicalProfile` (M17 T17.3): `#` line
/// comments; multi-line basic `"""…"""` (with `\` escapes, so a trailing `\`
/// joins lines) and literal `'''…'''` strings (no escapes), listed before the
/// single-line basic `"…"` and literal `'…'` forms. A quoted key — a string
/// followed by `=` on its line — is `.property` (`propertyStringFollower`).
///
/// Remaining approximations:
/// - A multi-line string ends at the first `"""` / `'''`, so the one or two
///   extra quotes TOML allows right before the closer (`""""`) are not
///   modelled.
/// - Table headers (`[table]`, `[[array]]`) are recognised only at the start of
///   a line, so an inline array (`x = [1, 2]`) is not mistaken for a table. In
///   a header with a quoted part (`[owner."key"]`) only the part before the
///   quote is coloured as the header; the quoted part is a string.
public enum TOMLLanguage {
    /// See `JSONLanguage.buildCount`.
    nonisolated(unsafe) public static var buildCount = 0

    /// Comments and the four string forms (triple-quoted first).
    public static let lexicalProfile = LexicalProfile(
        lineComments: ["#"],
        strings: [
            .init(delimiter: .fixed(open: "\"\"\"", close: "\"\"\""), multiline: true),
            .init(delimiter: .fixed(open: "'''", close: "'''"), multiline: true, escape: nil),
            .init(delimiter: .fixed(open: "\"", close: "\""), multiline: false),
            .init(delimiter: .fixed(open: "'", close: "'"), multiline: false, escape: nil),
        ]
    )

    public static func make() -> LanguageDefinition {
        buildCount += 1
        let keywords = ["true", "false"]
        let kw = keywords.joined(separator: "|")

        return LanguageDefinition(
            identifier: "toml",
            fileExtensions: ["toml"],
            rules: [
                // Table headers (start of line): array-of-tables before table,
                // then the part of a header before a quoted key.
                LanguageRule(pattern: #"^\[\[[^\]]*\]\]"#, kind: .type),
                LanguageRule(pattern: #"^\[[^\]]*\]"#, kind: .type),
                LanguageRule(pattern: #"^\[\[?[^\]"'\r\n]*(?=["'])"#, kind: .type),
                // Bare key: an identifier immediately followed by `=`.
                LanguageRule(pattern: #"[A-Za-z0-9_-]+(?=\s*=)"#, kind: .property),
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
            builtins: [],
            lexicalProfile: lexicalProfile,
            propertyStringFollower: #"[ \t]*="#
        )
    }
}
