import Foundation

/// JavaScript / Node definition.
///
/// Comments and strings come from `lexicalProfile` (M17 T17.2, shared with
/// TypeScript): `//` line comments, non-nesting `/* … */` block comments that
/// span lines, `'…'` / `"…"` single-line strings with `\` escapes (escape +
/// newline continues the line), and multi-line template literals whose
/// `${…}` interpolations are scanned as code (nested templates and object
/// literals inside included). The regex rules cover numbers, keywords and
/// built-ins inside code segments only.
///
/// **Regex literals** (M17 T17.3) are an atom (coloured as a string until the
/// regex colour of T17.7), so quotes, `//` and `/*` inside one stay inert.
/// Whether a `/` starts one or divides is decided from the text before it
/// (`regexContext`): the previous non-whitespace unit, across lines, must be
/// an operator or opening punctuation, or the word before it a keyword that
/// precedes an expression (`return /re/`); else — after an identifier,
/// number, `)` or `]` — it is division (`a / b / c`, `f(x) / 2`). The literal
/// must close on its line; the atom has no lookahead past its end, so a cut
/// line can never make it match where the whole line does not.
/// Approximations: `++` / `--` before a `/` read as operators (`i++ / 2 / x`
/// reads `/ 2 /` as a regex); `}` counts as a block end, so `}` followed by
/// `/re/` is a regex (VS Code reads division there); `<` is left out so a JSX
/// closing tag `</p>` is never a regex.
public enum JavaScriptLanguage {
    /// See `JSONLanguage.buildCount`.
    nonisolated(unsafe) public static var buildCount = 0

    /// JavaScript reserved words / common globals. Exposed so `TypeScript`
    /// can extend this set rather than duplicate it.
    public static let keywords: [String] = [
        "var", "let", "const", "function", "return", "if", "else", "for",
        "while", "do", "switch", "case", "break", "continue", "new", "delete",
        "typeof", "instanceof", "in", "of", "class", "extends", "super", "this",
        "null", "undefined", "true", "false", "async", "await", "yield",
        "import", "export", "default", "from", "try", "catch", "finally",
        "throw", "void", "static", "get", "set",
    ]

    /// JavaScript / Node built-in globals and standard-library identifiers.
    /// Exposed so `TypeScript` can extend this set rather than duplicate it.
    public static let builtins: [String] = [
        "console", "Math", "JSON", "Object", "Array", "String", "Number",
        "Boolean", "Symbol", "Promise", "Set", "Map", "WeakMap", "WeakSet",
        "Date", "RegExp", "Error", "TypeError", "RangeError", "parseInt",
        "parseFloat", "isNaN", "isFinite", "encodeURIComponent",
        "decodeURIComponent", "fetch", "window", "document", "setTimeout",
        "setInterval", "clearTimeout", "clearInterval",
        "requestAnimationFrame", "require", "module", "exports", "process",
        "globalThis", "structuredClone", "queueMicrotask",
    ]

    /// What may precede a regex literal (see the type comment).
    static let regexContext = LexicalProfile.AtomContext(
        characters: "(,=:[!&|?{};+-*%>~^",
        words: ["return", "typeof", "instanceof", "in", "of", "new", "delete", "void", "throw",
                "case", "do", "else", "yield", "await"]
    )

    /// Comments, strings, template literals and regex literals, shared with
    /// TypeScript.
    public static let lexicalProfile = LexicalProfile(
        lineComments: ["//"],
        blockComments: [.init(open: "/*", close: "*/")],
        strings: [
            .init(delimiter: .fixed(open: "\"", close: "\""), multiline: false),
            .init(delimiter: .fixed(open: "'", close: "'"), multiline: false),
            .init(delimiter: .fixed(open: "`", close: "`"), multiline: true,
                  interpolations: [.init(open: "${", close: "}")]),
        ],
        atoms: [
            // `/body/flags`: escapes, and classes in which `/` is literal.
            .init(pattern: #"/(?![/*])(?:\\[^\r\n]|\[(?:\\[^\r\n]|[^\]\\\r\n])*\]|[^/\\\[\r\n])+/[dgimsuyv]*"#,
                  firstCharacters: "/", kind: .string, precededBy: regexContext),
        ]
    )

    /// Number rule shared with TypeScript (comments and strings are the
    /// profile's).
    static func baseRules() -> [LanguageRule] {
        [
            // Numbers: hex / octal / binary / decimal / float, with optional
            // BigInt `n` suffix. Lookbehind avoids matching digits mid-identifier.
            LanguageRule(
                pattern: #"(?<![\w.])(?:0[xX][0-9a-fA-F]+n?|0[bB][01]+n?|0[oO][0-7]+n?|\d[\d_]*n|(?:\d[\d_]*(?:\.[\d_]*)?|\.\d[\d_]*)(?:[eE][+-]?\d+)?)"#,
                kind: .number
            ),
        ]
    }

    /// Builds a `\b(word1|word2|…)\b` rule producing `kind`.
    static func wordRule(_ words: [String], kind: TokenKind) -> LanguageRule {
        LanguageRule(pattern: "\\b(?:\(words.joined(separator: "|")))\\b", kind: kind)
    }

    public static func make() -> LanguageDefinition {
        buildCount += 1
        return LanguageDefinition(
            identifier: "javascript",
            fileExtensions: ["js", "mjs", "cjs"],
            rules: baseRules() + [
                wordRule(keywords, kind: .keyword),
                // Built-in globals after keywords (disjoint sets); rules only
                // run in code segments, so a built-in word inside a string or
                // comment is never reached here.
                wordRule(builtins, kind: .builtin),
            ],
            keywords: keywords,
            builtins: builtins,
            lexicalProfile: lexicalProfile
        )
    }
}
