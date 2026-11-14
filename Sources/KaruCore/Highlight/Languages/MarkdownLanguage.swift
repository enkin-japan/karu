import Foundation

/// Markdown definition.
///
/// `lexicalProfile` (M17 T17.3) tracks `<!-- -->` comments across lines and
/// fenced code blocks (``` or ~~~, up to 3 spaces of indentation, closed by a
/// run at least as long of the same marker). The opener and closer lines are
/// uncoloured (`.plain`); the body of a fence whose info string names a
/// known language (`fenceLanguages`, T17.8a) is scanned and coloured as that
/// language, any other body stays one `.plain` token, as VS Code shows a
/// fence of an unknown language. Everything else is line rules, which run
/// outside comments and fences only; the inline-code / link-URL `.string`
/// rules and the comment-coloured block quote / strikethrough rules stay
/// active (`keepsStringRules`, `keepsCommentRules`).
///
/// Categories (T17.7): headings `.heading` (bold), the block-quote `>` a
/// comment, emphasis `*x*` the control colour and `**x**` the keyword colour
/// (Dark Modern's `markup.italic` / `markup.bold`), link text a string,
/// backslash escapes escapes.
///
/// Line-approximation trade-offs:
/// - A heading colours the entire line as a single kind; inline emphasis
///   inside a heading is not separately highlighted.
/// - A fence inside a block quote or a list item indented by 4+ spaces is
///   not recognised; `<!--` inside inline code still opens a comment.
/// - Embedding is one level deep: a fence inside a `markdown` fence is a
///   plain block, and a `<script>` in an `html` fence stays HTML text.
/// - Link text is coloured without its `[` `]`; the URL after `](` stays
///   uncoloured (VS Code only underlines it); bare parentheses in prose are
///   left alone.
public enum MarkdownLanguage {
    /// See `JSONLanguage.buildCount`.
    nonisolated(unsafe) public static var buildCount = 0

    /// The profile without embedded languages (also the `markdown` fence
    /// child's, so the table below can refer to it).
    static let baseProfile = LexicalProfile(
        blockComments: [.init(open: "<!--", close: "-->")],
        lineBlocks: [.fence(bodyKind: .plain)],
        keepsStringRules: true,
        keepsCommentRules: true
    )

    /// Fence languages (T17.8a): the child's definition identifier, the
    /// profile it is scanned with (Python's analysis profile: its colouring
    /// uses Python's code rules, not `PythonTokenizer`) and the info-string
    /// words selecting it (lowercased first word).
    public static let fenceLanguages: [LexicalProfile.EmbeddedLanguage] = [
        .init(identifier: "python", profile: PythonLanguage.analysisProfile,
              aliases: ["python", "py", "python3", "py3"]),
        .init(identifier: "javascript", profile: JavaScriptLanguage.lexicalProfile,
              aliases: ["javascript", "js", "jsx", "mjs", "cjs", "node"]),
        .init(identifier: "typescript", profile: TypeScriptLanguage.lexicalProfile,
              aliases: ["typescript", "ts", "mts", "cts"]),
        .init(identifier: "bash", profile: BashLanguage.lexicalProfile,
              aliases: ["bash", "sh", "shell", "zsh", "shellscript", "console"]),
        .init(identifier: "json", profile: JSONLanguage.lexicalProfile, aliases: ["json", "jsonc", "json5"]),
        .init(identifier: "jsonl", profile: JSONLanguage.lexicalProfile, aliases: ["jsonl", "ndjson"]),
        .init(identifier: "yaml", profile: YAMLLanguage.lexicalProfile, aliases: ["yaml", "yml"]),
        .init(identifier: "toml", profile: TOMLLanguage.lexicalProfile, aliases: ["toml"]),
        .init(identifier: "html", profile: HTMLLanguage.lexicalProfile, aliases: ["html", "htm", "xhtml"]),
        .init(identifier: "xml", profile: XMLPlistLanguage.lexicalProfile, aliases: ["xml", "plist", "svg"]),
        .init(identifier: "css", profile: CSSLanguage.lexicalProfile, aliases: ["css"]),
        .init(identifier: "c", profile: CLanguage.lexicalProfile, aliases: ["c", "h"]),
        .init(identifier: "cpp", profile: CppLanguage.lexicalProfile,
              aliases: ["cpp", "c++", "cc", "cxx", "hpp", "hh"]),
        .init(identifier: "csharp", profile: CSharpLanguage.lexicalProfile, aliases: ["csharp", "cs", "c#"]),
        .init(identifier: "java", profile: JavaLanguage.lexicalProfile, aliases: ["java"]),
        .init(identifier: "go", profile: GoLanguage.lexicalProfile, aliases: ["go", "golang"]),
        .init(identifier: "rust", profile: RustLanguage.lexicalProfile, aliases: ["rust", "rs"]),
        .init(identifier: "swift", profile: SwiftLanguage.lexicalProfile, aliases: ["swift"]),
        .init(identifier: "sql", profile: SQLLanguage.lexicalProfile, aliases: ["sql"]),
        .init(identifier: "markdown", profile: baseProfile, aliases: ["markdown", "md"]),
        // T17.8b: TypeScript JSX (JavaScript fences have JSX on).
        .init(identifier: "typescriptreact", profile: TypeScriptReactLanguage.lexicalProfile,
              aliases: ["tsx", "typescriptreact"]),
    ]

    /// HTML comments and fenced code blocks with their embedded languages
    /// (see the type comment).
    public static let lexicalProfile: LexicalProfile = {
        var profile = baseProfile
        profile.embeds = fenceLanguages
        return profile
    }()

    public static func make() -> LanguageDefinition {
        buildCount += 1
        return LanguageDefinition(
            identifier: "markdown",
            fileExtensions: ["md", "markdown"],
            rules: [
                // Whole-line constructs (only ever match at column 0 via `^`).
                // ATX heading (requires a space after the #s so "#hashtag"
                // in prose is not mistaken for a heading); a setext heading's
                // `===` underline. Drawn bold (`HighlightTheme.isBold`).
                LanguageRule(pattern: #"^#{1,6}\s.*"#, kind: .heading),
                LanguageRule(pattern: #"^=+[ \t]*$"#, kind: .heading),
                // Block quote marker (only the `>`, as VS Code).
                LanguageRule(pattern: #"^[ \t]{0,3}>"#, kind: .comment),
                // List markers: bullet (`- ` `* ` `+ `) and ordered (`1. `).
                // Only the marker is coloured; the rest of the line still gets
                // inline treatment. `.property` (VS Code's list-bullet blue) —
                // `.punctuation` resolves to the plain text colour, which made
                // the markers look un-highlighted (user feedback).
                LanguageRule(pattern: #"^\s*[-*+]\s"#, kind: .property),
                LanguageRule(pattern: #"^\s*\d+\.\s"#, kind: .property),

                // Inline constructs (match at any position).
                // Backslash escape (`\*`).
                LanguageRule(pattern: #"\\[\\`*_{}\[\]()#+\-.!>~|]"#, kind: .escape),
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
                // Italic (*…* / _…_): `markup.italic`, which Dark Modern
                // colours like control keywords.
                LanguageRule(pattern: #"\*[^*\s][^*]*\*"#, kind: .controlKeyword),
                LanguageRule(pattern: #"_[^_\s][^_]*_"#, kind: .controlKeyword),
                // Link / image: the text in brackets a string (brackets
                // uncoloured), the URL in parens (immediately after `]`)
                // uncoloured, an optional quoted title a string.
                LanguageRule(pattern: #"(?<=\[)[^\[\]\r\n]+(?=\]\()"#, kind: .string),
                LanguageRule(pattern: #"(?<=\]\()[^)\s]*"#, kind: .plain),
                LanguageRule(pattern: #""[^"\r\n]*"(?=\))"#, kind: .string),
            ],
            lexicalProfile: lexicalProfile
        )
    }
}
