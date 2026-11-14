import Foundation

/// Java definition.
///
/// Comments and strings come from `lexicalProfile` (M17 T17.3): `//` line
/// comments, non-nesting `/* … */` block comments (Javadoc included) that
/// span lines, text blocks `"""…"""` (multi-line, `\` escapes, so `\"""` does
/// not close) before single-line `"…"` strings, and character literals
/// (`'"'`, `'\\'`) as atoms. The regex rules cover the rest in code:
/// - Annotations: the name after `@` is a type (`@` itself uncoloured, as
///   VS Code); annotation arguments are not part of the token.
///
/// **Categories by position** (T17.7, VS Code's Java grammar): control-flow
/// keywords (`new` included, `keyword.control.new`) apart from the others;
/// primitive types types (`storage.type.primitive`); `name(` a call; `obj.`
/// and `.member` variables; library classes types; the names of an `import`
/// line uncoloured. Local variables are not coloured at their uses, only at
/// their declarations (with parameters, fields, methods and classes).
/// Escapes: `\uHHHH`, octal.
public enum JavaLanguage {
    /// See `JSONLanguage.buildCount`.
    nonisolated(unsafe) public static var buildCount = 0

    static let controlKeywords: [String] = [
        "if", "else", "for", "while", "do", "switch", "case", "default", "break",
        "continue", "return", "try", "catch", "finally", "throw", "new", "yield",
    ]

    static let primitiveTypes: [String] = [
        "void", "int", "long", "short", "byte", "char", "float", "double", "boolean",
    ]

    static let otherKeywords: [String] = [
        "class", "interface", "enum", "extends", "implements", "public",
        "private", "protected", "static", "final", "abstract", "native",
        "synchronized", "transient", "volatile", "this", "super", "null", "true",
        "false", "throws", "import", "package", "instanceof", "var", "record",
        "sealed", "permits",
    ]

    static let keywords: [String] = controlKeywords + primitiveTypes + otherKeywords

    /// Library classes, coloured as types.
    static let libraryTypes: [String] = [
        "String", "Integer", "Long", "Double", "Float", "Boolean", "Character", "Byte",
        "Short", "Object", "Math", "List", "ArrayList", "LinkedList", "Map",
        "HashMap", "TreeMap", "Set", "HashSet", "TreeSet", "Queue", "Deque",
        "Optional", "Stream", "Collectors", "Arrays", "Collections",
        "Objects", "StringBuilder", "Exception", "RuntimeException",
        "IllegalArgumentException", "NullPointerException", "Override",
        "Deprecated", "SuppressWarnings",
    ]

    static let builtins: [String] = libraryTypes + [
        "System", "out", "err", "println", "print", "printf", "length", "equals",
        "hashCode", "toString", "valueOf", "parseInt",
    ]

    /// The qualified name of an `import` / `package` line (uncoloured, as VS
    /// Code: `storage.modifier.import`).
    static let importRule = LanguageRule(
        pattern: #"(?<=[ \t])(?<=\b(?:import|package)[ \t]{1,8}(?:static[ \t]{1,8})?)[\w.*]+"#, kind: .plain)

    /// Java's identifiers (T17.7): functions and types from the table;
    /// variables only at their declarations.
    static let identifierPolicy: IdentifierPolicy = {
        var roles = IdentifierPolicy.declarationRoles
        roles[.variable] = .symbolVariable
        roles[.property] = .symbolVariable
        return IdentifierPolicy(tableVariables: false, roles: roles)
    }()

    /// Comments, text blocks, strings and character literals.
    public static let lexicalProfile = LexicalProfile(
        lineComments: ["//"],
        blockComments: [.init(open: "/*", close: "*/")],
        strings: [
            .init(delimiter: .fixed(open: "\"\"\"", close: "\"\"\""), multiline: true,
                  escapeForms: [.unicode4, .octal]),
            .init(delimiter: .fixed(open: "\"", close: "\""), multiline: false, escapeForms: [.unicode4, .octal]),
        ],
        atoms: [
            .init(pattern: #"'(?:[^'\\\r\n]|\\[^\r\n])+'"#, firstCharacters: "'", kind: .string),
        ]
    )

    public static func make() -> LanguageDefinition {
        buildCount += 1
        return LanguageDefinition(
            identifier: "java",
            fileExtensions: ["java"],
            rules: [
                // Annotation name, e.g. the `Override` of `@Override`.
                LanguageRule(pattern: #"(?<=@)[A-Za-z_]\w*"#, kind: .type),
                importRule,
                SyntaxRules.words(controlKeywords, .controlKeyword),
                SyntaxRules.words(primitiveTypes, .type),
                SyntaxRules.words(otherKeywords, .keyword),
                SyntaxRules.call(),
                SyntaxRules.object(),
                SyntaxRules.member(.symbolVariable),
                // Library classes after keywords (disjoint); annotations are
                // consumed earlier, and rules only run in code segments, so a
                // built-in word inside a string or comment is never reached.
                SyntaxRules.words(libraryTypes, .type),
                // Numbers: hex / binary / decimal / float, with `_`
                // separators and an optional `L` / `f` / `d` suffix. The
                // lookbehind avoids matching digits mid-identifier.
                LanguageRule(
                    pattern: #"(?<![\w.])(?:0[xX][0-9a-fA-F_]+[lL]?|0[bB][01_]+[lL]?|(?:\d[\d_]*(?:\.[\d_]*)?|\.[\d_]+)(?:[eE][+-]?\d+)?[lLfFdD]?)"#,
                    kind: .number
                ),
            ],
            keywords: keywords,
            builtins: builtins,
            lexicalProfile: lexicalProfile,
            identifierPolicy: identifierPolicy
        )
    }
}
