import Foundation

/// XML / plist definition.
///
/// Modelled on `HTMLLanguage`, with two additions: an XML declaration
/// (`<?xml … ?>`) and a `<!DOCTYPE …>` are coloured as `.type` rather than
/// left untokenized.
///
/// Comments and CDATA come from `lexicalProfile` (M17 T17.3): `<!-- … -->`
/// comments and `<![CDATA[ … ]]>` sections (a string without escapes, as VS
/// Code colours it) span lines. As in HTML there are no quote string forms;
/// attribute values stay single-line regex rules (`keepsStringRules`).
///
/// Remaining approximations (shared with HTML):
/// - The XML declaration and `<!DOCTYPE …>` are matched per line
///   (complete-on-line, or open-to-end-of-line).
/// - Attribute names are matched as any `name=` token and attribute values
///   as any quoted string on one line, without verifying they sit inside a
///   tag; a value spanning lines is not coloured.
public enum XMLPlistLanguage {
    /// See `JSONLanguage.buildCount`.
    nonisolated(unsafe) public static var buildCount = 0

    /// Comments and CDATA sections; attribute strings stay rules.
    public static let lexicalProfile = LexicalProfile(
        blockComments: [.init(open: "<!--", close: "-->")],
        strings: [
            .init(delimiter: .fixed(open: "<![CDATA[", close: "]]>"), multiline: true, escape: nil),
        ],
        keepsStringRules: true
    )

    public static func make() -> LanguageDefinition {
        buildCount += 1
        return LanguageDefinition(
            identifier: "xml",
            fileExtensions: ["xml", "plist", "svg", "xib", "storyboard"],
            rules: [
                // XML declaration: complete-on-line, then open-to-end-of-line.
                LanguageRule(pattern: #"<\?.*?\?>"#, kind: .type),
                LanguageRule(pattern: #"<\?.*"#, kind: .type),
                // DOCTYPE: complete-on-line, then open-to-end-of-line.
                LanguageRule(pattern: #"<!DOCTYPE.*?>"#, kind: .type),
                LanguageRule(pattern: #"<!DOCTYPE.*"#, kind: .type),
                // Tag name, including the opening `<` or `</` and any
                // namespace prefix (e.g. `<key`, `</string`, `<ns:tag`).
                LanguageRule(pattern: #"</?[a-zA-Z][\w:-]*"#, kind: .keyword),
                // Attribute value strings.
                LanguageRule(pattern: #""[^"]*""#, kind: .string),
                LanguageRule(pattern: #"'[^']*'"#, kind: .string),
                // Entity reference (`&amp;`, `&#169;`).
                LanguageRule(pattern: #"&#?\w+;"#, kind: .number),
                // Attribute name (a word immediately before `=`).
                LanguageRule(pattern: #"[\w:-]+(?==)"#, kind: .property),
            ],
            lexicalProfile: lexicalProfile
        )
    }
}
