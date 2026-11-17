import Foundation

/// Go definition.
///
/// Comments and strings come from `lexicalProfile` (M17 T17.3): `//` line
/// comments, non-nesting `/* … */` block comments that span lines, raw
/// (back-quoted) strings that span lines without escapes, single-line
/// interpreted `"…"` strings, and rune literals (`'"'`, `'\''`) as atoms.
///
/// **Categories by position** (T17.7, VS Code's Go grammar): control-flow
/// keywords (`import`, `defer`, `go`, `range`, …) apart from the others;
/// `nil` / `true` / `false` / `iota` keywords; the package name a type;
/// `name(` a call; printf verbs in strings placeholders; every other
/// identifier a variable, `const` names constants. Escapes: `\xHH`, octal,
/// `\uHHHH`, `\UHHHHHHHH`.
public enum GoLanguage {
    /// See `JSONLanguage.buildCount`.
    nonisolated(unsafe) public static var buildCount = 0

    /// Control-flow keywords (`keyword.control`).
    public static let controlKeywords: [String] = [
        "break", "case", "continue", "default", "defer", "else", "fallthrough",
        "for", "go", "goto", "if", "import", "range", "return", "select", "switch",
    ]

    /// The other keywords and the predeclared constants.
    public static let otherKeywords: [String] = [
        "chan", "const", "func", "interface", "map", "package", "struct", "type",
        "var", "nil", "true", "false", "iota",
    ]

    /// The 25 Go keywords (completion's list).
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

    /// Predeclared functions, coloured as built-ins.
    public static let builtinFunctions: [String] = [
        "len", "cap", "make", "new", "append", "copy", "delete", "panic",
        "recover", "print", "println", "close", "complex", "real", "imag",
    ]

    /// Predeclared functions and constants (completion's list).
    public static let builtins: [String] = builtinFunctions + ["nil", "iota", "true", "false"]

    /// Go's identifiers (T17.7): every name a variable, `const` names
    /// constants; functions, types and parameters at their declarations. A
    /// bare function name yields to a parameter or local of the same name
    /// (VH5, `functionNamesYieldToLocalBindings`).
    static let identifierPolicy: IdentifierPolicy = {
        var roles = IdentifierPolicy.declarationRoles
        roles[.variable] = .symbolVariable
        roles[.property] = .symbolVariable
        return IdentifierPolicy(otherIdentifiers: .symbolVariable, roles: roles,
                                constDeclarationsAreConstants: true, functionNamesYieldToLocalBindings: true)
    }()

    /// Builds a `\b(word1|word2|…)\b` rule producing `kind`.
    static func wordRule(_ words: [String], kind: TokenKind) -> LanguageRule {
        LanguageRule(pattern: "\\b(?:\(words.joined(separator: "|")))\\b", kind: kind)
    }

    /// Comments, raw and interpreted strings, rune literals.
    public static let lexicalProfile = LexicalProfile(
        lineComments: ["//"],
        blockComments: [.init(open: "/*", close: "*/")],
        strings: [
            .init(delimiter: .fixed(open: "`", close: "`"), multiline: true, escape: nil),
            .init(delimiter: .fixed(open: "\"", close: "\""), multiline: false,
                  escapeForms: [.hex2, .octal, .unicode4, .unicode8]),
        ],
        atoms: [
            .init(pattern: #"'(?:[^'\\\r\n]|\\[^\r\n])+'"#, firstCharacters: "'", kind: .string),
        ]
    )

    public static func make() -> LanguageDefinition {
        buildCount += 1
        return LanguageDefinition(
            identifier: "go",
            fileExtensions: ["go"],
            rules: [
                // Numbers: hex / octal / binary / decimal / float, `_` separators,
                // optional exponent and imaginary `i` suffix.
                LanguageRule(
                    pattern: #"(?<![\w.])(?:0[xX][0-9a-fA-F_]+|0[oO][0-7_]+|0[bB][01_]+|(?:\d[\d_]*(?:\.[\d_]*)?|\.\d[\d_]*)(?:[eE][+-]?\d+)?i?)"#,
                    kind: .number
                ),
                // The package clause's name (`entity.name.type.package`).
                LanguageRule(pattern: #"(?<=\bpackage[ \t]{1,8})[A-Za-z_]\w*"#, kind: .type),
                wordRule(controlKeywords, kind: .controlKeyword),
                wordRule(otherKeywords, kind: .keyword),
                // Predeclared types then built-in functions (disjoint from
                // keywords; rules only run in code segments).
                wordRule(types, kind: .type),
                wordRule(builtinFunctions, kind: .builtin),
                SyntaxRules.call(),
            ],
            keywords: keywords,
            builtins: types + builtins,
            lexicalProfile: lexicalProfile,
            stringRules: [SyntaxRules.printfPlaceholder],
            identifierPolicy: identifierPolicy
        )
    }
}
