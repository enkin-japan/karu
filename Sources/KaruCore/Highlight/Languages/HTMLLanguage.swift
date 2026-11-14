import Foundation

/// HTML definition.
///
/// Comments come from `lexicalProfile` (M17 T17.3): `<!-- … -->` spans lines.
/// The profile has no string forms — quotes only delimit attribute values
/// inside a tag, and a quote in text content is plain text — so attribute
/// values stay single-line regex rules (`keepsStringRules`), which run in
/// the code outside comments.
///
/// Categories (T17.7): tag punctuation, tag names, attribute names, values
/// and entities as VS Code's HTML grammar colours them (`MarkupRules`).
///
/// Remaining approximations:
/// - Tags are recognised line by line: on a tag's continuation lines only
///   `name=` attributes are coloured; a value spanning lines is not
///   coloured, and a `<!--` inside a value opens a comment.
/// - Embedded `<script>` / `<style>` bodies are not switched to JS / CSS.
public enum HTMLLanguage {
    /// See `JSONLanguage.buildCount`.
    nonisolated(unsafe) public static var buildCount = 0

    /// Comments only; attribute strings stay rules.
    public static let lexicalProfile = LexicalProfile(
        blockComments: [.init(open: "<!--", close: "-->")],
        keepsStringRules: true
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
