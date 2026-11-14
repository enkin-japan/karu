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
/// Categories (T17.7): as HTML (`MarkupRules`); the XML declaration and
/// processing instructions are tags (`<?`, name, attributes, `?>`),
/// `<!DOCTYPE name` / `<!ENTITY name` keywords.
///
/// Remaining approximations (shared with HTML):
/// - Tags are recognised line by line: on a tag's continuation lines only
///   `name=` attributes are coloured; a value spanning lines is not
///   coloured.
public enum XMLPlistLanguage {
    /// See `JSONLanguage.buildCount`.
    nonisolated(unsafe) public static var buildCount = 0

    /// Comments and CDATA sections; attribute strings stay rules.
    public static let lexicalProfile = LexicalProfile(
        blockComments: [.init(open: "<!--", close: "-->")],
        strings: [
            .init(delimiter: .fixed(open: "<![CDATA[", close: "]]>"), multiline: true, escape: nil),
        ],
        keepsStringRules: true,
        stringKind: .markupValue
    )

    public static func make() -> LanguageDefinition {
        buildCount += 1
        return LanguageDefinition(
            identifier: "xml",
            fileExtensions: ["xml", "plist", "svg", "xib", "storyboard"],
            rules: [
                MarkupRules.tagOpen,
                // Processing instruction / XML declaration target.
                LanguageRule(pattern: #"(?<=<\?)[A-Za-z_][\w:.-]*"#, kind: .tagName),
                MarkupRules.declarationKeyword,
                MarkupRules.declaredName,
                MarkupRules.tagName,
                MarkupRules.tagClose,
                MarkupRules.doubleQuotedValue,
                MarkupRules.singleQuotedValue,
                // A quoted literal in a declaration (`<!ENTITY e "v">`).
                LanguageRule(pattern: #""[^"\r\n]*"(?=[ \t]*>)"#, kind: .string),
                MarkupRules.entity,
                MarkupRules.attributeInTag,
                MarkupRules.attributeBeforeEquals,
            ],
            lexicalProfile: lexicalProfile
        )
    }
}
