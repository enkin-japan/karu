import Foundation

/// CSS definition.
///
/// Comments and strings come from `lexicalProfile` (M17 T17.3): non-nesting
/// `/* … */` comments that span lines, and single-line `"…"` / `'…'` strings
/// with `\` escapes (escape + newline continues the string). The regex rules
/// cover the rest in code segments:
/// - Property names are matched as any `name:` token, so a pseudo-class in a
///   selector (e.g. the `a` in `a:hover`) can be mis-coloured as a property.
///   Distinguishing declaration blocks from selectors needs brace/state
///   tracking, which is out of scope for the per-line tokenizer.
public enum CSSLanguage {
    /// See `JSONLanguage.buildCount`.
    nonisolated(unsafe) public static var buildCount = 0

    /// Comments and strings.
    public static let lexicalProfile = LexicalProfile(
        blockComments: [.init(open: "/*", close: "*/")],
        strings: [
            .init(delimiter: .fixed(open: "\"", close: "\""), multiline: false),
            .init(delimiter: .fixed(open: "'", close: "'"), multiline: false),
        ]
    )

    public static func make() -> LanguageDefinition {
        buildCount += 1
        return LanguageDefinition(
            identifier: "css",
            fileExtensions: ["css"],
            rules: [
                // At-rules (`@media`, `@import`, `@keyframes`, …).
                LanguageRule(pattern: #"@[\w-]+"#, kind: .keyword),
                // !important.
                LanguageRule(pattern: #"!\s*important\b"#, kind: .keyword),
                // Hex colour.
                LanguageRule(pattern: #"#[0-9a-fA-F]{3,8}\b"#, kind: .number),
                // Property name (a word immediately before a colon).
                LanguageRule(pattern: #"[\w-]+(?=\s*:)"#, kind: .property),
                // Number with optional unit / percentage.
                LanguageRule(pattern: #"-?(?:\d*\.\d+|\d+)(?:[a-zA-Z%]+)?"#, kind: .number),
            ],
            lexicalProfile: lexicalProfile
        )
    }
}
