import Foundation

/// C definition (v1, line-based).
///
/// Line-approximation trade-offs accepted for v1:
/// - `//` line comments are exact; `/* … */` block comments are approximated:
///   a block that opens and closes on one line is coloured, and an opening
///   line colours to end-of-line, but interior and closing lines of a
///   multi-line block comment are not tracked (no cross-line state).
/// - Preprocessor directives are matched line-locally as `^\s*#\w+` (e.g. the
///   `#include` / `#define` token, including any leading indentation); the
///   remainder of the directive (the header name, macro body, …) is not
///   specially coloured.
/// - Numbers accept the common integer/float suffixes (`u`, `U`, `l`, `L`,
///   `f`, `F`) but do not validate that a given suffix combination is
///   actually legal C.
public enum CLanguage {
    /// See `JSONLanguage.buildCount`.
    nonisolated(unsafe) public static var buildCount = 0

    /// C keywords. Exposed so `CppLanguage` can extend this set rather than
    /// duplicate it.
    public static let keywords: [String] = [
        "int", "char", "long", "short", "unsigned", "signed", "float", "double",
        "void", "struct", "union", "enum", "typedef", "static", "extern",
        "const", "volatile", "register", "auto", "if", "else", "for", "while",
        "do", "switch", "case", "default", "break", "continue", "return",
        "goto", "sizeof", "inline", "restrict",
    ]

    /// C standard-library functions / macros / common typedefs. Exposed so
    /// `CppLanguage` can extend this set rather than duplicate it.
    public static let builtins: [String] = [
        "printf", "fprintf", "sprintf", "snprintf", "scanf", "fscanf",
        "sscanf", "malloc", "calloc", "realloc", "free", "memcpy", "memmove",
        "memset", "strlen", "strcpy", "strncpy", "strcmp", "strncmp",
        "strcat", "fopen", "fclose", "fread", "fwrite", "fseek", "ftell",
        "fflush", "fgets", "fputs", "putchar", "getchar", "puts", "exit",
        "abort", "assert", "NULL", "FILE", "size_t", "stdin", "stdout",
        "stderr", "EOF",
    ]

    /// Builds a `\b(word1|word2|…)\b` rule producing `kind`.
    static func wordRule(_ words: [String], kind: TokenKind) -> LanguageRule {
        LanguageRule(pattern: "\\b(?:\(words.joined(separator: "|")))\\b", kind: kind)
    }

    /// Comment / string / char-literal / preprocessor / number rules shared
    /// with C++.
    static func baseRules() -> [LanguageRule] {
        [
            // Line comment.
            LanguageRule(pattern: #"//.*"#, kind: .comment),
            // Block comment: complete-on-line, then open-to-end-of-line.
            LanguageRule(pattern: #"/\*.*?\*/"#, kind: .comment),
            LanguageRule(pattern: #"/\*.*"#, kind: .comment),
            // Strings and char literals.
            LanguageRule(pattern: #""(?:[^"\\]|\\.)*""#, kind: .string),
            LanguageRule(pattern: #"'(?:[^'\\]|\\.)*'"#, kind: .string),
            // Preprocessor directive token (only matches at the start of the
            // line, via `^`).
            LanguageRule(pattern: #"^\s*#\w+"#, kind: .type),
            // Numbers: hex with integer suffixes, or decimal/float with
            // optional exponent and integer/float suffixes. The lookbehind
            // stops a digit inside an identifier (e.g. `x1`) from matching.
            LanguageRule(
                pattern: #"(?<![\w.])(?:0[xX][0-9a-fA-F]+[uUlL]*|(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?[uUlLfF]*)"#,
                kind: .number
            ),
        ]
    }

    public static func make() -> LanguageDefinition {
        buildCount += 1
        return LanguageDefinition(
            identifier: "c",
            fileExtensions: ["c", "h"],
            rules: baseRules() + [
                wordRule(keywords, kind: .keyword),
                // Standard-library functions / macros / typedefs after keywords
                // (disjoint sets); comments, strings and preprocessor lines are
                // consumed in `baseRules()`, so a built-in word inside one is
                // never reached here.
                wordRule(builtins, kind: .builtin),
            ],
            keywords: keywords,
            builtins: builtins
        )
    }
}
