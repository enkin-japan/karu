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
/// Categories (T17.7, VS Code's YAML grammar): keys are tags
/// (`entity.name.tag`, the merge key `<<` too), plain and block scalars
/// `.markupValue` (string colour, blue in Light Modern), anchors / aliases a
/// control `&` / `*` and a variable name, block-scalar indicators control.
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

    /// Comments, quoted scalars and block scalars. A doubled `''` in a
    /// single-quoted scalar and `\` escapes in a double-quoted one are
    /// escapes (T17.7).
    public static let lexicalProfile = LexicalProfile(
        lineComments: ["#"],
        lineCommentPrecededBy: " \t",
        strings: [
            .init(delimiter: .fixed(open: "\"", close: "\""), multiline: true,
                  escapeForms: [.hex2, .unicode4, .unicode8], precededBy: quoteContext),
            .init(delimiter: .fixed(open: "'", close: "'"), multiline: true, escape: nil,
                  doubledCloseEscapes: true, doubledCloseIsEscape: true, precededBy: quoteContext),
        ],
        lineBlocks: [.indentedBlock(bodyKind: .markupValue)]
    )

    /// A scalar that is a number, boolean or null on its own (then not a
    /// plain string scalar).
    private static let literalScalar =
        #"(?:[-+]?(?:0[xX][0-9a-fA-F]+|(?:\d[\d_]*(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?|\.inf|\.nan)|true|false|null|yes|no|on|off|True|False|Null|TRUE|FALSE|NULL|~)"#

    /// A plain scalar value in block context: after `key: ` or a `- ` item
    /// marker, up to a ` #` comment or the line end
    /// (`string.unquoted.plain.out`).
    static let plainScalarRule = LanguageRule(
        pattern: #"(?<=[ \t])(?<=:[ \t]{1,16}|^[ \t]{0,64}-[ \t]{1,8})(?!"# + literalScalar + #"[ \t]*(?:#|$))[^\s#&*!|>'"\[\]{},%@`][^\r\n]*?(?=[ \t]+#|[ \t]*$)"#,
        kind: .markupValue)

    /// A plain scalar item of a flow sequence or mapping (`[a, b]`).
    static let flowScalarRule = LanguageRule(
        pattern: #"(?<=[\[,][ \t]{0,8})(?!"# + literalScalar + #"[ \t]*[,\]}])[^\s#&*!|>'"\[\]{},][^\r\n#,\[\]{}]*?(?=[ \t]*[,\]}])"#,
        kind: .markupValue)

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
                // Plain mapping key: an identifier immediately followed by `:`
                // (`entity.name.tag`: the tag colour, as in VS Code); the
                // merge key `<<` a keyword.
                LanguageRule(pattern: #"[A-Za-z_][\w.-]*(?=\s*:(?:\s|$))"#, kind: .tagName),
                LanguageRule(pattern: #"<<(?=\s*:)"#, kind: .tagName),
                // Anchors / aliases: `&` / `*` (`keyword.control.flow`) and
                // the name (`variable.other`); tags (`!!str`).
                LanguageRule(pattern: #"[&*](?=[A-Za-z_])"#, kind: .controlKeyword),
                LanguageRule(pattern: #"(?<=[&*])[A-Za-z_][\w-]*"#, kind: .symbolVariable),
                LanguageRule(pattern: #"!!?[A-Za-z_][\w-]*"#, kind: .type),
                // Block scalar indicator (`|`, `>`; control) and its chomping
                // sign (keyword).
                LanguageRule(pattern: #"[|>](?=[-+1-9]{0,2}[ \t]*(?:#|$))"#, kind: .controlKeyword),
                LanguageRule(pattern: #"(?<=[|>][1-9]?)[-+](?=[1-9]?[ \t]*(?:#|$))"#, kind: .keyword),
                plainScalarRule,
                flowScalarRule,
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
