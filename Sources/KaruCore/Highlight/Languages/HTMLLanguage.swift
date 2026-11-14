import Foundation

/// HTML definition.
///
/// Comments come from `lexicalProfile` (M17 T17.3): `<!-- … -->` spans lines.
/// The profile has no string forms — quotes only delimit attribute values
/// inside a tag, and a quote in text content is plain text — so attribute
/// values stay single-line regex rules (`keepsStringRules`), which run in
/// the code outside comments.
///
/// Remaining approximations:
/// - Attribute names are matched as any `name=` token and attribute values as
///   any quoted string on one line, without verifying they sit inside a tag;
///   a value spanning lines is not coloured, and a `<!--` inside a value
///   opens a comment.
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
                // Tag name, including the opening `<` or `</` (e.g. `<div`,
                // `</span`, `<my-element`).
                LanguageRule(pattern: #"</?[a-zA-Z][\w-]*"#, kind: .keyword),
                // Attribute value strings.
                LanguageRule(pattern: #""[^"]*""#, kind: .string),
                LanguageRule(pattern: #"'[^']*'"#, kind: .string),
                // Entity reference (`&amp;`, `&#169;`).
                LanguageRule(pattern: #"&#?\w+;"#, kind: .number),
                // Attribute name (a word immediately before `=`).
                LanguageRule(pattern: #"[\w-]+(?==)"#, kind: .property),
            ],
            lexicalProfile: lexicalProfile
        )
    }
}
