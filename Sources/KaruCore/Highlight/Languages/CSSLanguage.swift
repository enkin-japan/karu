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
///
/// Categories (T17.7, VS Code's CSS grammar): at-rules control keywords
/// (`keyword.control.at-rule`), function names (`var(`, `calc(`) functions,
/// custom properties (`--x`) variables, hex colours strings
/// (`constant.other.color.rgb-value`, the string colour in Dark Modern).
/// Selectors (`#d7ba7d` dark / `#800000` light) have no matching kind and stay
/// uncoloured. Escapes: `\H…` (1–6 hex digits).
public enum CSSLanguage {
    /// See `JSONLanguage.buildCount`.
    nonisolated(unsafe) public static var buildCount = 0

    /// Comments and strings.
    public static let lexicalProfile = LexicalProfile(
        blockComments: [.init(open: "/*", close: "*/")],
        strings: [
            .init(delimiter: .fixed(open: "\"", close: "\""), multiline: false, escapeForms: [.cssHex]),
            .init(delimiter: .fixed(open: "'", close: "'"), multiline: false, escapeForms: [.cssHex]),
        ],
        // The hex-colour rule is a `.string` rule in code.
        keepsStringRules: true
    )

    public static func make() -> LanguageDefinition {
        buildCount += 1
        return LanguageDefinition(
            identifier: "css",
            fileExtensions: ["css"],
            rules: [
                // At-rules (`@media`, `@import`, `@keyframes`, …).
                LanguageRule(pattern: #"@[\w-]+"#, kind: .controlKeyword),
                // !important.
                LanguageRule(pattern: #"!\s*important\b"#, kind: .keyword),
                // Hex colour.
                LanguageRule(pattern: #"#[0-9a-fA-F]{3,8}\b"#, kind: .string),
                // Function name (`var(`, `calc(`, `url(`).
                LanguageRule(pattern: #"[A-Za-z_-][\w-]*(?=\()"#, kind: .builtin),
                // Custom property (`--accent`), declared or used.
                LanguageRule(pattern: #"--[\w-]+"#, kind: .symbolVariable),
                // Property name (a word immediately before a colon):
                // `support.type.property-name.css` (T17.15d).
                LanguageRule(pattern: #"[\w-]+(?=\s*:)"#, kind: .cssProperty),
                // Number with optional unit / percentage.
                LanguageRule(pattern: #"-?(?:\d*\.\d+|\d+)(?:[a-zA-Z%]+)?"#, kind: .number),
            ],
            lexicalProfile: lexicalProfile
        )
    }
}
