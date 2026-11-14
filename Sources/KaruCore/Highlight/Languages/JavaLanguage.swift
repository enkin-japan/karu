import Foundation

/// Java definition.
///
/// Comments and strings come from `lexicalProfile` (M17 T17.3): `//` line
/// comments, non-nesting `/* … */` block comments (Javadoc included) that
/// span lines, text blocks `"""…"""` (multi-line, `\` escapes, so `\"""` does
/// not close) before single-line `"…"` strings, and character literals
/// (`'"'`, `'\\'`) as atoms. The regex rules cover the rest in code:
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

    static let builtins: [String] = [
        "System", "out", "err", "println", "print", "printf", "String",
        "Integer", "Long", "Double", "Float", "Boolean", "Character", "Byte",
        "Short", "Object", "Math", "List", "ArrayList", "LinkedList", "Map",
        "HashMap", "TreeMap", "Set", "HashSet", "TreeSet", "Queue", "Deque",
        "Optional", "Stream", "Collectors", "Arrays", "Collections",
        "Objects", "StringBuilder", "Exception", "RuntimeException",
        "IllegalArgumentException", "NullPointerException", "Override",
        "Deprecated", "SuppressWarnings", "length", "equals", "hashCode",
        "toString", "valueOf", "parseInt",
    ]

    /// Comments, text blocks, strings and character literals.
    public static let lexicalProfile = LexicalProfile(
        lineComments: ["//"],
        blockComments: [.init(open: "/*", close: "*/")],
        strings: [
            .init(delimiter: .fixed(open: "\"\"\"", close: "\"\"\""), multiline: true),
            .init(delimiter: .fixed(open: "\"", close: "\""), multiline: false),
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
                // Annotation, e.g. `@Override`.
                LanguageRule(pattern: #"@\w+"#, kind: .type),
                // Keywords.
                LanguageRule(pattern: "\\b(?:\(keywords.joined(separator: "|")))\\b", kind: .keyword),
                // Standard-library types / members after keywords (disjoint);
                // annotations are consumed earlier, and rules only run in code
                // segments, so a built-in word inside a string or comment is
                // never reached here.
                LanguageRule(pattern: "\\b(?:\(builtins.joined(separator: "|")))\\b", kind: .builtin),
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
            lexicalProfile: lexicalProfile
        )
    }
}
