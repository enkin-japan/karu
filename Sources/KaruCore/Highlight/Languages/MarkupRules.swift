import Foundation

/// Tag-level rules shared by HTML and XML (M17 T17.7, VS Code's markup
/// grammars): `<`, `</`, `<!`, `<?`, `>`, `/>`, `?>` are tag punctuation
/// (`punctuation.definition.tag`), the name after them a tag name, a word
/// inside a tag before `=` (or a bare attribute) an attribute name, a quoted
/// value after `=` a string, an entity (`&amp;`) a keyword
/// (`constant.character.entity`). All single-line: a tag spanning lines
/// keeps only the `name=` attribute rule on its continuation lines.
enum MarkupRules {
    /// `<`, `</`, `<!`, `<?` before a name.
    static let tagOpen = LanguageRule(pattern: #"</?(?=[A-Za-z_])|<[!?](?=[A-Za-z_])"#, kind: .tagPunctuation)

    /// The tag name after `<` / `</` (with a namespace prefix: `ns:tag`).
    static let tagName = LanguageRule(pattern: #"(?<=</?)[A-Za-z_][\w:.-]*"#, kind: .tagName)

    /// `>`, `/>`, `?>` closing a tag opened on the same line.
    static let tagClose = LanguageRule(pattern: #"(?=[/?]?>)(?<=<[A-Za-z_!?/][^<>\r\n]{0,400})[/?]?>"#,
                                       kind: .tagPunctuation)

    /// A quoted attribute value (after `=`): `.markupValue` (blue in Light
    /// Modern).
    static let doubleQuotedValue = LanguageRule(pattern: #"(?<==[ \t]{0,8})"[^"\r\n]*""#, kind: .markupValue)
    static let singleQuotedValue = LanguageRule(pattern: #"(?<==[ \t]{0,8})'[^'\r\n]*'"#, kind: .markupValue)

    /// An entity / character reference.
    static let entity = LanguageRule(pattern: #"&#?\w+;"#, kind: .keyword)

    /// An attribute name inside a tag opened on the same line, followed by
    /// `=`, `>`, `/>` or `?>` (a bare one before another attribute is not
    /// recognised); then any `name=` (a continuation line).
    static let attributeInTag = LanguageRule(
        pattern: #"(?<=[ \t])(?=[\w:.-]+[ \t]*(?:=|/?>|\?>))(?<=<[A-Za-z_?][^<>\r\n]{0,400}[ \t])[\w:.-]+"#,
        kind: .attributeName)
    static let attributeBeforeEquals = LanguageRule(pattern: #"[\w:.-]+(?==)"#, kind: .attributeName)

    /// A declaration keyword after `<!` (`DOCTYPE`, `ENTITY`, …) and the name
    /// it declares (`keyword.other`).
    static let declarationKeyword = LanguageRule(pattern: #"(?<=<!)[A-Za-z]+"#, kind: .keyword)
    static let declaredName = LanguageRule(
        pattern: #"(?<=<!(?:DOCTYPE|ENTITY|ELEMENT|ATTLIST)[ \t]{1,8})[\w:.-]+"#, kind: .keyword)
}
