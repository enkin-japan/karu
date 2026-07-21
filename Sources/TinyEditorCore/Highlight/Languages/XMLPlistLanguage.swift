import Foundation

/// XML / plist definition (v1, line-based).
///
/// Modelled directly on `HTMLLanguage`, with two additions: an XML
/// declaration (`<?xml … ?>`) and a `<!DOCTYPE …>` are coloured as `.type`
/// rather than left untokenized.
///
/// Line-approximation trade-offs accepted for v1 (inherited from HTML):
/// - `<!-- … -->` comments are approximated per line (complete-on-line, or
///   open-to-end-of-line); a comment spanning multiple lines is only
///   coloured on its opening line. The same applies to the XML declaration
///   and `<!DOCTYPE …>`.
/// - Attribute names are matched as any `name=` token and attribute values
///   as any quoted string, without verifying they sit inside a tag.
public enum XMLPlistLanguage {
    /// See `JSONLanguage.buildCount`.
    nonisolated(unsafe) public static var buildCount = 0

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
                // Comment: complete-on-line, then open-to-end-of-line.
                LanguageRule(pattern: #"<!--.*?-->"#, kind: .comment),
                LanguageRule(pattern: #"<!--.*"#, kind: .comment),
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
            ]
        )
    }
}
