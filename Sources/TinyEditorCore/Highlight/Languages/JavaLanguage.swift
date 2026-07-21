import Foundation

/// Java definition (v1, line-based).
///
/// Line-approximation trade-offs accepted for v1:
/// - `//` line comments are exact; `/* … */` block comments (and Javadoc
///   `/** … */`) are approximated: complete-on-line is coloured exactly, an
///   opening line colours to end-of-line, and interior/closing lines of a
///   multi-line block comment are not tracked (no cross-line state).
/// - Text blocks (`"""…"""`, Java 15+) are not specially handled; only
///   single-line double-quoted strings are tokenized.
/// - Annotations are matched as `@\w+` only — annotation arguments
///   (`@SuppressWarnings("x")`) are not part of the token.
public enum JavaLanguage {
    /// See `JSONLanguage.buildCount`.
    nonisolated(unsafe) public static var buildCount = 0

    static let keywords: [String] = [
        "class", "interface", "enum", "extends", "implements", "public",
        "private", "protected", "static", "final", "abstract", "native",
        "synchronized", "transient", "volatile", "if", "else", "for", "while",
        "do", "switch", "case", "break", "continue", "return", "new", "this",
        "super", "null", "true", "false", "void", "int", "long", "short",
        "byte", "char", "float", "double", "boolean", "try", "catch",
        "finally", "throw", "throws", "import", "package", "instanceof",
        "var", "record", "sealed", "permits", "yield",
    ]

    public static func make() -> LanguageDefinition {
        buildCount += 1
        return LanguageDefinition(
            identifier: "java",
            fileExtensions: ["java"],
            rules: [
                // Line comment.
                LanguageRule(pattern: #"//.*"#, kind: .comment),
                // Block comment: complete-on-line, then open-to-end-of-line.
                LanguageRule(pattern: #"/\*.*?\*/"#, kind: .comment),
                LanguageRule(pattern: #"/\*.*"#, kind: .comment),
                // String.
                LanguageRule(pattern: #""(?:[^"\\]|\\.)*""#, kind: .string),
                // Annotation, e.g. `@Override`.
                LanguageRule(pattern: #"@\w+"#, kind: .type),
                // Keywords.
                LanguageRule(pattern: "\\b(?:\(keywords.joined(separator: "|")))\\b", kind: .keyword),
                // Numbers: hex / binary / decimal / float, with `_`
                // separators and an optional `L` / `f` / `d` suffix. The
                // lookbehind avoids matching digits mid-identifier.
                LanguageRule(
                    pattern: #"(?<![\w.])(?:0[xX][0-9a-fA-F_]+[lL]?|0[bB][01_]+[lL]?|(?:\d[\d_]*(?:\.[\d_]*)?|\.[\d_]+)(?:[eE][+-]?\d+)?[lLfFdD]?)"#,
                    kind: .number
                ),
            ]
        )
    }
}
