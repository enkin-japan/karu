import Foundation

/// JavaScript / Node definition (v1, line-based).
///
/// Line-approximation trade-offs accepted for v1:
/// - `//` line comments are exact; `/* … */` block comments are approximated:
///   a block that opens and closes on one line is coloured, and an opening line
///   colours to end-of-line, but interior and closing lines of a multi-line
///   block comment are not tracked (no cross-line state).
/// - Template literals are treated per line the same way; `${…}`
///   interpolations are not tokenized separately, and a template spanning
///   multiple lines is only coloured on its opening line.
/// - **Regex literals are intentionally not highlighted.** Distinguishing `/`
///   as the start of a regex from a division operator needs real lexer state
///   (it depends on the preceding token); getting it wrong miscolours ordinary
///   arithmetic, so v1 leaves `/…/` as plain text.
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

    /// Comment, string and number rules shared with TypeScript.
    static func baseRules() -> [LanguageRule] {
        [
            // Line comment.
            LanguageRule(pattern: #"//.*"#, kind: .comment),
            // Block comment: complete-on-line, then open-to-end-of-line.
            LanguageRule(pattern: #"/\*.*?\*/"#, kind: .comment),
            LanguageRule(pattern: #"/\*.*"#, kind: .comment),
            // Strings: double, single, and template (per-line approximation).
            LanguageRule(pattern: #""(?:[^"\\]|\\.)*""#, kind: .string),
            LanguageRule(pattern: #"'(?:[^'\\]|\\.)*'"#, kind: .string),
            LanguageRule(pattern: #"`(?:[^`\\]|\\.)*`"#, kind: .string),
            LanguageRule(pattern: #"`(?:[^`\\]|\\.)*"#, kind: .string),
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
            rules: baseRules() + [wordRule(keywords, kind: .keyword)],
            keywords: keywords,
            builtins: builtins
        )
    }
}
