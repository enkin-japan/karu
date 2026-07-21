import Foundation

/// Go definition (v1, line-based).
///
/// Line-approximation trade-offs accepted for v1:
/// - `//` line comments are exact; `/* … */` block comments are approximated
///   per line (complete-on-line, then open-to-end-of-line) with no cross-line
///   state.
/// - Raw string literals (back-quoted) may legally span lines in Go; only their
///   single-line form is coloured here.
public enum GoLanguage {
    /// See `JSONLanguage.buildCount`.
    nonisolated(unsafe) public static var buildCount = 0

    /// The 25 Go keywords.
    public static let keywords: [String] = [
        "break", "case", "chan", "const", "continue", "default", "defer",
        "else", "fallthrough", "for", "func", "go", "goto", "if", "import",
        "interface", "map", "package", "range", "return", "select", "struct",
        "switch", "type", "var",
    ]

    /// Predeclared types, coloured as types.
    public static let types: [String] = [
        "bool", "byte", "rune", "string", "error", "int", "int8", "int16",
        "int32", "int64", "uint", "uint8", "uint16", "uint32", "uint64",
        "uintptr", "float32", "float64", "complex64", "complex128", "any",
    ]

    /// Predeclared functions and constants, coloured as built-ins.
    public static let builtins: [String] = [
        "len", "cap", "make", "new", "append", "copy", "delete", "panic",
        "recover", "print", "println", "close", "complex", "real", "imag",
        "nil", "iota", "true", "false",
    ]

    /// Builds a `\b(word1|word2|…)\b` rule producing `kind`.
    static func wordRule(_ words: [String], kind: TokenKind) -> LanguageRule {
        LanguageRule(pattern: "\\b(?:\(words.joined(separator: "|")))\\b", kind: kind)
    }

    public static func make() -> LanguageDefinition {
        buildCount += 1
        return LanguageDefinition(
            identifier: "go",
            fileExtensions: ["go"],
            rules: [
                // Line comment.
                LanguageRule(pattern: #"//.*"#, kind: .comment),
                // Block comment: complete-on-line, then open-to-end-of-line.
                LanguageRule(pattern: #"/\*.*?\*/"#, kind: .comment),
                LanguageRule(pattern: #"/\*.*"#, kind: .comment),
                // Interpreted, raw (back-quoted) and rune literals.
                LanguageRule(pattern: #""(?:[^"\\]|\\.)*""#, kind: .string),
                LanguageRule(pattern: #"`[^`]*`"#, kind: .string),
                LanguageRule(pattern: #"'(?:[^'\\]|\\.)*'"#, kind: .string),
                // Numbers: hex / octal / binary / decimal / float, `_` separators,
                // optional exponent and imaginary `i` suffix.
                LanguageRule(
                    pattern: #"(?<![\w.])(?:0[xX][0-9a-fA-F_]+|0[oO][0-7_]+|0[bB][01_]+|(?:\d[\d_]*(?:\.[\d_]*)?|\.\d[\d_]*)(?:[eE][+-]?\d+)?i?)"#,
                    kind: .number
                ),
                wordRule(keywords, kind: .keyword),
                // Predeclared types then built-in functions (disjoint from
                // keywords; strings and comments are consumed earlier).
                wordRule(types, kind: .type),
                wordRule(builtins, kind: .builtin),
            ],
            keywords: keywords,
            builtins: types + builtins
        )
    }
}
