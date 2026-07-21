import Foundation

/// CSS definition (v1, line-based).
///
/// Line-approximation trade-offs accepted for v1:
/// - `/* … */` comments are approximated per line (complete-on-line, or
///   open-to-end-of-line).
/// - Property names are matched as any `name:` token, so a pseudo-class in a
///   selector (e.g. the `a` in `a:hover`) can be mis-coloured as a property.
///   Distinguishing declaration blocks from selectors needs brace/state
///   tracking, which is out of scope for the per-line tokenizer.
public enum CSSLanguage {
    /// See `JSONLanguage.buildCount`.
    nonisolated(unsafe) public static var buildCount = 0

    public static func make() -> LanguageDefinition {
        buildCount += 1
        return LanguageDefinition(
            identifier: "css",
            fileExtensions: ["css"],
            rules: [
                // Comment: complete-on-line, then open-to-end-of-line.
                LanguageRule(pattern: #"/\*.*?\*/"#, kind: .comment),
                LanguageRule(pattern: #"/\*.*"#, kind: .comment),
                // Strings.
                LanguageRule(pattern: #""[^"]*""#, kind: .string),
                LanguageRule(pattern: #"'[^']*'"#, kind: .string),
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
            ]
        )
    }
}
