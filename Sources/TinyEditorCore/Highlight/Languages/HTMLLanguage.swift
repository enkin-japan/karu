import Foundation

/// HTML definition (v1, line-based).
///
/// Line-approximation trade-offs accepted for v1:
/// - `<!-- … -->` comments are approximated per line (complete-on-line, or
///   open-to-end-of-line); a comment spanning multiple lines is only coloured
///   on its opening line.
/// - Attribute names are matched as any `name=` token and attribute values as
///   any quoted string, without verifying they sit inside a tag; embedded
///   `<script>` / `<style>` bodies are not switched to JS / CSS.
public enum HTMLLanguage {
    /// See `JSONLanguage.buildCount`.
    nonisolated(unsafe) public static var buildCount = 0

    public static func make() -> LanguageDefinition {
        buildCount += 1
        return LanguageDefinition(
            identifier: "html",
            fileExtensions: ["html", "htm"],
            rules: [
                // Comment: complete-on-line, then open-to-end-of-line.
                LanguageRule(pattern: #"<!--.*?-->"#, kind: .comment),
                LanguageRule(pattern: #"<!--.*"#, kind: .comment),
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
            ]
        )
    }
}
