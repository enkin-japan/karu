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
///
/// **Categories by position** (T17.7, VS Code's Swift grammar): control-flow
/// keywords (`import`, `guard`, `in`, …) apart from the others; the imported
/// module a type; `name(` a call and an argument label (`f(of: 1)`) a
/// function; `.member` a variable; `$0` a keyword; enum case names
/// constants. References to variables stay uncoloured (as VS Code; file-level
/// variables stay in the navigator, `identifierPolicy` only drops their
/// colour). Escapes: `\u{…}`.
public enum SwiftLanguage {
    /// See `JSONLanguage.buildCount`.
    nonisolated(unsafe) public static var buildCount = 0

    public static let keywords: [String] = controlKeywords + otherKeywords

    /// Control-flow keywords (`keyword.control`).
    public static let controlKeywords: [String] = [
        "if", "else", "for", "while", "repeat", "do", "switch", "case", "default",
        "break", "continue", "return", "fallthrough", "guard", "defer", "where",
        "in", "try", "catch", "throw", "import", "yield",
    ]

    public static let otherKeywords: [String] = [
        "func", "var", "let", "class", "struct", "enum", "protocol",
        "extension", "init", "deinit", "throws", "rethrows", "async", "await",
        "actor", "as", "is", "public", "private", "internal", "fileprivate", "open",
        "static", "final", "lazy", "weak", "unowned", "mutating", "nonmutating",
        "override", "convenience", "required", "subscript", "typealias",
        "associatedtype", "inout", "some", "any", "self", "Self", "super",
        "nil", "true", "false", "willSet", "didSet", "get", "set",
    ]

    /// Swift's identifiers (T17.7): functions and types from the table,
    /// variables only at nothing — VS Code colours neither `let` / `var`
    /// declarations nor references; parameters at their declarations. A
    /// bare function name yields to a parameter, local (closure parameters
    /// included) or property of the same name (VH5,
    /// `functionNamesYieldToLocalBindings`); `#selector(name)` and
    /// trailing-closure calls of an unshadowed function keep the colour.
    static let identifierPolicy = IdentifierPolicy(tableVariables: false,
                                                   roles: IdentifierPolicy.declarationRoles,
                                                   functionNamesYieldToLocalBindings: true)

    /// An argument label in a call or parameter list (`f(of: 1)`,
    /// `func f(_ a: Int, at b: Int)`): VS Code colours it as a function.
    static let labelRule = LanguageRule(
        pattern: #"(?<=[(,][ \t]{0,8})[A-Za-z_]\w*(?=(?:[ \t]+[A-Za-z_]\w*)?[ \t]*:(?!:))"#, kind: .symbolFunction)

    /// Enum case names: after `case`, and after commas on such a line
    /// (`variable.other.enummember`). The cheap context checks come first,
    /// so the long lookbehind only runs after `case ` or a comma.
    static let enumCaseRule = LanguageRule(
        pattern: #"(?<=[ \t,])(?=[A-Za-z_]\w*[ \t]*(?:,|=|\(|$|//|/\*))(?<=\bcase[ \t]{1,8}|,[ \t]{0,4})(?<=^[ \t]{0,32}(?:indirect[ \t]{1,8})?case[ \t]{1,8}(?:[A-Za-z_]\w{0,40}(?:\([^()\r\n]{0,80}\))?[ \t]{0,4},[ \t]{0,4}){0,8})[A-Za-z_]\w*"#,
        kind: .constant)

    /// The `case` of an enum case declaration (`case a, b`) is a declaration
    /// keyword, not the control keyword of a `switch` (`case .a:`).
    static let enumCaseKeywordRule = LanguageRule(
        pattern: #"case(?<=^[ \t]{0,32}(?:indirect[ \t]{1,8})?case)(?=[ \t]+[A-Za-z_]\w*(?:\([^()\r\n]{0,80}\))?[ \t]*(?:,|=|$|//|/\*))"#,
        kind: .keyword)

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
                  multiline: true, escapeForms: [.unicodeBraced], interpolations: [.init(open: "\\(", close: ")")]),
            .init(delimiter: .hashed(lead: "", hash: "#", quote: "\"", hashesApplyToEscapes: true),
                  multiline: false, escapeForms: [.unicodeBraced], interpolations: [.init(open: "\\(", close: ")")]),
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
                // The imported module (`entity.name.type`).
                LanguageRule(pattern: #"(?<=\bimport[ \t]{1,8})[A-Za-z_]\w*"#, kind: .type),
                labelRule,
                enumCaseKeywordRule,
                enumCaseRule,
                wordRule(controlKeywords, kind: .controlKeyword),
                wordRule(otherKeywords, kind: .keyword),
                // `$0` closure arguments.
                LanguageRule(pattern: #"\$\d+"#, kind: .keyword),
                // Standard-library types then global functions (disjoint from
                // keywords; rules only run in code segments).
                wordRule(types, kind: .type),
                wordRule(builtins, kind: .builtin),
                SyntaxRules.call(),
                SyntaxRules.member(.symbolVariable),
            ],
            keywords: keywords,
            builtins: types + builtins,
            lexicalProfile: lexicalProfile,
            identifierPolicy: identifierPolicy
        )
    }
}
