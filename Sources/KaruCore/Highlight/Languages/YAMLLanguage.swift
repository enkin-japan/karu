import Foundation

/// YAML definition.
///
/// Comments, quoted scalars and block scalars come from `lexicalProfile`
/// (M17 T17.3); keys, anchors, tags, keywords and numbers are line rules.
/// - `#` starts a comment only at a line start or after a blank, so
///   `https://x/#a` and `a#b` stay scalar text.
/// - `"…"` (`\` escapes) and `'…'` (doubled `''`) may span lines, and open
///   only where a quoted scalar can start: after `:`, `-`, `[`, `{`, `,`, `?`
///   or first on the line (`StringForm.precededBy`), so `don't` and
///   `say "hi"` inside a plain scalar stay plain. A quoted string followed
///   by `:` is a key (`.property`).
/// - Block scalars (`|`, `>`, with `-` / `+` / digit indicators): the body is
///   one string token and ends before the first non-blank line indented no
///   deeper than the parent node (`LexicalProfile.LineBlockForm.indentedBlock`).
///
/// Compromises: the parent indentation is read from the indicator's line
/// (spaces and `- ` markers), not from the block structure, and an explicit
/// indentation indicator is not used; flow collections and plain multi-line
/// scalars are not tracked.
public enum YAMLLanguage {
    /// See `JSONLanguage.buildCount`.
    nonisolated(unsafe) public static var buildCount = 0

    /// Where a quoted scalar may start (see the type comment).
    static let quoteContext = LexicalProfile.AtomContext(characters: ":-[{,?", lineStart: true)

    /// Comments, quoted scalars and block scalars.
    public static let lexicalProfile = LexicalProfile(
        lineComments: ["#"],
        lineCommentPrecededBy: " \t",
        strings: [
            .init(delimiter: .fixed(open: "\"", close: "\""), multiline: true, precededBy: quoteContext),
            .init(delimiter: .fixed(open: "'", close: "'"), multiline: true, escape: nil,
                  doubledCloseEscapes: true, precededBy: quoteContext),
        ],
        lineBlocks: [.indentedBlock(bodyKind: .string)]
    )

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
                // Plain mapping key: an identifier immediately followed by `:`.
                LanguageRule(pattern: #"[A-Za-z_][\w.-]*(?=\s*:(?:\s|$))"#, kind: .property),
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
            builtins: [],
            lexicalProfile: lexicalProfile,
            // Quoted mapping keys: a quoted scalar followed by `:`.
            propertyStringFollower: #"\s*:"#
        )
    }
}
