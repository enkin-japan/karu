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
/// **Regex literals are intentionally not highlighted yet.** Distinguishing
/// `/` as the start of a regex from a division operator depends on the
/// preceding token; that is a T17.3 scanner hook, so `/…/` stays plain text
/// (a quote inside a regex literal can therefore still open a string).
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

    /// Comments, strings and template literals, shared with TypeScript.
    public static let lexicalProfile = LexicalProfile(
        lineComments: ["//"],
        blockComments: [.init(open: "/*", close: "*/")],
        strings: [
            .init(delimiter: .fixed(open: "\"", close: "\""), multiline: false),
            .init(delimiter: .fixed(open: "'", close: "'"), multiline: false),
            .init(delimiter: .fixed(open: "`", close: "`"), multiline: true,
                  interpolations: [.init(open: "${", close: "}")]),
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
