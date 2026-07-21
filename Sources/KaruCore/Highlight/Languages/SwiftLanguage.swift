import Foundation

/// Swift definition (v1, line-based).
///
/// Line-approximation trade-offs accepted for v1:
/// - `//` line comments are exact; `/* … */` block comments are approximated
///   per line with no cross-line state.
/// - Multi-line string literals (`"""`) are coloured on their opening line to
///   end-of-line. String interpolation `\( … )` is not tokenized separately —
///   the whole literal is coloured as a string.
public enum SwiftLanguage {
    /// See `JSONLanguage.buildCount`.
    nonisolated(unsafe) public static var buildCount = 0

    public static let keywords: [String] = [
        "func", "var", "let", "class", "struct", "enum", "protocol",
        "extension", "guard", "defer", "init", "deinit", "throws", "rethrows",
        "async", "await", "actor", "if", "else", "for", "while", "repeat",
        "do", "switch", "case", "default", "break", "continue", "return",
        "where", "in", "as", "is", "try", "catch", "throw", "import",
        "public", "private", "internal", "fileprivate", "open", "static",
        "final", "lazy", "weak", "unowned", "mutating", "nonmutating",
        "override", "convenience", "required", "subscript", "typealias",
        "associatedtype", "inout", "some", "any", "self", "Self", "super",
        "nil", "true", "false", "willSet", "didSet", "get", "set",
    ]

    /// Common standard-library types, coloured as types.
    public static let types: [String] = [
        "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16",
        "UInt32", "UInt64", "Double", "Float", "Bool", "String", "Character",
        "Array", "Dictionary", "Set", "Optional", "Result", "Any", "AnyObject",
        "Void", "Error", "Never", "Data", "Date",
    ]

    /// Common global functions, coloured as built-ins.
    public static let builtins: [String] = [
        "print", "debugPrint", "min", "max", "abs", "assert",
        "precondition", "fatalError", "zip", "stride", "swap", "type",
    ]

    /// Builds a `\b(word1|word2|…)\b` rule producing `kind`.
    static func wordRule(_ words: [String], kind: TokenKind) -> LanguageRule {
        LanguageRule(pattern: "\\b(?:\(words.joined(separator: "|")))\\b", kind: kind)
    }

    public static func make() -> LanguageDefinition {
        buildCount += 1
        return LanguageDefinition(
            identifier: "swift",
            fileExtensions: ["swift"],
            rules: [
                // Line comment.
                LanguageRule(pattern: #"//.*"#, kind: .comment),
                // Block comment: complete-on-line, then open-to-end-of-line.
                LanguageRule(pattern: #"/\*.*?\*/"#, kind: .comment),
                LanguageRule(pattern: #"/\*.*"#, kind: .comment),
                // Multi-line string: complete-on-line, then open-to-end-of-line.
                LanguageRule(pattern: #""""(?:.*?"""|.*)"#, kind: .string),
                // Single-line string (interpolation coloured as part of the string).
                LanguageRule(pattern: #""(?:[^"\\]|\\.)*""#, kind: .string),
                // Attribute (`@objc`, `@escaping`, …).
                LanguageRule(pattern: #"@\w+"#, kind: .type),
                // Numbers with `_` separators (hex / octal / binary / decimal / float).
                LanguageRule(
                    pattern: #"(?<![\w.])(?:0[xX][0-9a-fA-F_]+|0[oO][0-7_]+|0[bB][01_]+|(?:\d[\d_]*(?:\.[\d_]*)?)(?:[eE][+-]?\d+)?)"#,
                    kind: .number
                ),
                wordRule(keywords, kind: .keyword),
                // Standard-library types then global functions (disjoint from
                // keywords; strings and comments are consumed earlier).
                wordRule(types, kind: .type),
                wordRule(builtins, kind: .builtin),
            ],
            keywords: keywords,
            builtins: types + builtins
        )
    }
}
