import Foundation

/// Markdown definition (v1, line-based).
///
/// Line-approximation trade-offs accepted for v1:
/// - Whole-line constructs (headings, fenced-code lines, blockquotes) colour
///   the entire line as a single kind; inline emphasis inside a heading is not
///   separately highlighted.
/// - A ```` ``` ```` fence line is coloured, but the *content* between an
///   opening and closing fence is not tracked as code (no cross-line state), so
///   fenced-code bodies are highlighted as ordinary Markdown.
/// - Link text is coloured including its surrounding `[` `]`, and the URL
///   including its `(` `)`; the `(url)` rule uses a `]`-lookbehind so bare
///   parentheses in prose are left alone.
public enum MarkdownLanguage {
    /// See `JSONLanguage.buildCount`.
    nonisolated(unsafe) public static var buildCount = 0

    public static func make() -> LanguageDefinition {
        buildCount += 1
        return LanguageDefinition(
            identifier: "markdown",
            fileExtensions: ["md", "markdown"],
            rules: [
                // Whole-line constructs (only ever match at column 0 via `^`).
                // Fenced code delimiter line.
                LanguageRule(pattern: #"^\s*```.*"#, kind: .comment),
                // ATX heading (requires a space after the #s so "#hashtag"
                // in prose is not mistaken for a heading).
                LanguageRule(pattern: #"^#{1,6}\s.*"#, kind: .keyword),
                // Blockquote line.
                LanguageRule(pattern: #"^\s*>.*"#, kind: .comment),
                // List markers: bullet (`- ` `* ` `+ `) and ordered (`1. `).
                // Only the marker is coloured; the rest of the line still gets
                // inline treatment. `.property` (VS Code's list-bullet blue) —
                // `.punctuation` resolves to the plain text colour, which made
                // the markers look un-highlighted (user feedback).
                LanguageRule(pattern: #"^\s*[-*+]\s"#, kind: .property),
                LanguageRule(pattern: #"^\s*\d+\.\s"#, kind: .property),

                // Inline constructs (match at any position).
                // Inline code span.
                LanguageRule(pattern: #"`[^`]+`"#, kind: .string),
                // Strikethrough (~~…~~), dimmed like a comment.
                LanguageRule(pattern: #"~~[^~]+~~"#, kind: .comment),
                // Bold-italic (***…*** / ___…___) before bold, bold before
                // italic, so the longer delimiter is never eaten by the shorter.
                LanguageRule(pattern: #"\*\*\*[^*]+\*\*\*"#, kind: .keyword),
                LanguageRule(pattern: #"___[^_]+___"#, kind: .keyword),
                LanguageRule(pattern: #"\*\*[^*]+\*\*"#, kind: .keyword),
                LanguageRule(pattern: #"__[^_]+__"#, kind: .keyword),
                // Italic (*…* / _…_).
                LanguageRule(pattern: #"\*[^*\s][^*]*\*"#, kind: .keyword),
                LanguageRule(pattern: #"_[^_\s][^_]*_"#, kind: .keyword),
                // Link / image: text in brackets → property, URL in parens
                // (immediately following the `]`) → string.
                LanguageRule(pattern: #"\[[^\]]*\]"#, kind: .property),
                LanguageRule(pattern: #"(?<=\])\([^)]*\)"#, kind: .string),
            ]
        )
    }
}
