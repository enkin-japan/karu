import Foundation

/// HTML definition.
///
/// Comments come from `lexicalProfile` (M17 T17.3): `<!-- … -->` spans lines.
/// The profile has no string forms — quotes only delimit attribute values
/// inside a tag, and a quote in text content is plain text — so attribute
/// values stay single-line regex rules (`keepsStringRules`), which run in
/// the code outside comments.
///
/// **Embedded languages** (T17.8a, plan §7): `<script>` and `<style>` are
/// raw-text elements of the profile. A script without `type`, with a
/// JavaScript MIME type or `module` is scanned and coloured as JavaScript, a
/// style as CSS; any other script type (`text/template`, and the JSON types
/// `application/json`, `importmap`, `application/ld+json`, which VS Code
/// leaves uncoloured too) is plain text. The body ends at the first
/// `</script` / `</style` whatever the child's state, as in a browser; the
/// start and end tags keep the HTML rules.
///
/// Categories (T17.7): tag punctuation, tag names, attribute names, values
/// and entities as VS Code's HTML grammar colours them (`MarkupRules`).
///
/// Remaining approximations:
/// - Tags are recognised line by line: on a tag's continuation lines only
///   `name=` attributes are coloured; a value spanning lines is not
///   coloured, and a `<!--` inside a value opens a comment.
/// - Attribute values of other tags are rules, not scanner strings: a
///   `<script>` written inside one (`title="<script>"`) opens a script.
/// - A plain-text script body is not coloured as HTML (VS Code colours the
///   tags of a `text/template` body).
public enum HTMLLanguage {
    /// See `JSONLanguage.buildCount`.
    nonisolated(unsafe) public static var buildCount = 0

    /// `type` values whose script body is JavaScript (the HTML standard's
    /// JavaScript MIME type essences, `module`, Babel / JSX, and the empty
    /// value).
    public static let javaScriptTypes: [String] = [
        "", "module", "text/javascript", "application/javascript", "application/ecmascript",
        "application/x-ecmascript", "application/x-javascript", "text/ecmascript", "text/javascript1.0",
        "text/javascript1.1", "text/javascript1.2", "text/javascript1.3", "text/javascript1.4",
        "text/javascript1.5", "text/jscript", "text/livescript", "text/x-ecmascript", "text/x-javascript",
        "text/babel", "text/jsx", "application/babel",
    ]

    /// Comments, and `<script>` / `<style>` bodies as JavaScript / CSS
    /// (embeds 1 and 2); attribute strings stay rules.
    public static let lexicalProfile = LexicalProfile(
        blockComments: [.init(open: "<!--", close: "-->")],
        keepsStringRules: true,
        embeds: [
            .init(identifier: "javascript", profile: JavaScriptLanguage.lexicalProfile),
            .init(identifier: "css", profile: CSSLanguage.lexicalProfile),
        ],
        rawTextElements: [
            .init(name: "script", language: 1,
                  typeLanguages: Dictionary(uniqueKeysWithValues: javaScriptTypes.map { ($0, 1) }),
                  otherTypesLanguage: 0),
            // VS Code colours every style body as CSS.
            .init(name: "style", language: 2, otherTypesLanguage: 2),
        ]
    )

    public static func make() -> LanguageDefinition {
        buildCount += 1
        return LanguageDefinition(
            identifier: "html",
            fileExtensions: ["html", "htm"],
            rules: [
                MarkupRules.tagOpen,
                // `<!DOCTYPE` (`entity.name.tag.doctype`) and its root name
                // (an attribute name in VS Code's HTML grammar).
                LanguageRule(pattern: #"(?<=<!)[A-Za-z]+"#, kind: .tagName),
                LanguageRule(pattern: #"(?<=<!DOCTYPE[ \t]{1,8})[\w:.-]+"#, kind: .attributeName),
                MarkupRules.tagName,
                MarkupRules.tagClose,
                MarkupRules.doubleQuotedValue,
                MarkupRules.singleQuotedValue,
                MarkupRules.entity,
                MarkupRules.attributeInTag,
                MarkupRules.attributeBeforeEquals,
            ],
            lexicalProfile: lexicalProfile
        )
    }
}
