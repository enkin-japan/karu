import Foundation

/// Swift definition.
///
/// Comments and strings come from `lexicalProfile` (M17 T17.3): `//` line
/// comments, nesting `/* … */` block comments, multi-line `"""…"""` and
/// single-line `"…"` strings with `\` escapes and `\(…)` interpolations
/// (scanned as code, nested strings included), and their extended-delimiter
/// forms `#"…"#` / `#"""…"""#` (any number of `#`; the escape and the
/// interpolation then need the same hashes, `\#(…)`).
///
/// Not modelled: regex literals (`/…/`, `#/…/#`) stay plain code, so a quote
/// inside one can open a string.
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

    /// Comments and strings. The hashed delimiter with zero hashes is the
    /// plain form, so one form per quote length covers `"""` and `#"""`;
    /// triple quotes first.
    public static let lexicalProfile = LexicalProfile(
        lineComments: ["//"],
        blockComments: [.init(open: "/*", close: "*/", nests: true)],
        strings: [
            .init(delimiter: .hashed(lead: "", hash: "#", quote: "\"\"\"", hashesApplyToEscapes: true),
                  multiline: true, interpolations: [.init(open: "\\(", close: ")")]),
            .init(delimiter: .hashed(lead: "", hash: "#", quote: "\"", hashesApplyToEscapes: true),
                  multiline: false, interpolations: [.init(open: "\\(", close: ")")]),
        ]
    )

    public static func make() -> LanguageDefinition {
        buildCount += 1
        return LanguageDefinition(
            identifier: "swift",
            fileExtensions: ["swift"],
            rules: [
                // Attribute (`@objc`, `@escaping`, …).
                LanguageRule(pattern: #"@\w+"#, kind: .type),
                // Numbers with `_` separators (hex / octal / binary / decimal / float).
                LanguageRule(
                    pattern: #"(?<![\w.])(?:0[xX][0-9a-fA-F_]+|0[oO][0-7_]+|0[bB][01_]+|(?:\d[\d_]*(?:\.[\d_]*)?)(?:[eE][+-]?\d+)?)"#,
                    kind: .number
                ),
                wordRule(keywords, kind: .keyword),
                // Standard-library types then global functions (disjoint from
                // keywords; rules only run in code segments).
                wordRule(types, kind: .type),
                wordRule(builtins, kind: .builtin),
            ],
            keywords: keywords,
            builtins: types + builtins,
            lexicalProfile: lexicalProfile
        )
    }
}
