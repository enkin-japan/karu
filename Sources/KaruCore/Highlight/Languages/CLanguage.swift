import Foundation

/// C definition.
///
/// Comments and strings come from `lexicalProfile` (M17 T17.3): `//` line
/// comments, non-nesting `/* … */` block comments that span lines, and
/// single-line `"…"` strings with `\` escapes (escape + newline continues the
/// line) and the `L` / `u` / `U` / `u8` encoding prefixes. Character literals
/// (`'x'`, `'\''`, `L'x'`) are atoms, so a `'"'` never opens a string; an
/// apostrophe right after an identifier or digit (C++14 `1'000'000`) is not
/// one. The regex rules cover the rest inside code segments:
/// - Preprocessor directives are matched line-locally as `^\s*#\w+` (e.g. the
///   `#include` / `#define` token, including any leading indentation); an
///   `#include <header>` name is a string (a rule, see `lexicalProfile`), the
///   rest of a directive (macro body, …) is not specially coloured.
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

    /// Encoding prefixes of string and character literals.
    static let encodingPrefixes = ["L", "u", "U", "u8"]

    /// Character literal atom, shared with C++ (and its shape with Java, C#
    /// and Go). The lookbehind keeps an apostrophe directly after an
    /// identifier or digit unit — a C++14 digit separator — from starting
    /// one, unless that unit ends an encoding prefix (`L'x'`, `u8'x'`).
    static let charLiteral = LexicalProfile.AtomForm(
        pattern: #"(?:(?<=\b(?:L|u|U|u8))|(?<![A-Za-z0-9_]))'(?:[^'\\\r\n]|\\[^\r\n])+'"#,
        firstCharacters: "'", kind: .string, prefixes: encodingPrefixes)

    /// Comments, strings and character literals. `keepsStringRules`: the
    /// `#include <header>` name is a string only in that context, so it
    /// stays a rule (`includeRule`).
    public static let lexicalProfile = LexicalProfile(
        lineComments: ["//"],
        blockComments: [.init(open: "/*", close: "*/")],
        strings: [
            .init(prefixes: encodingPrefixes, delimiter: .fixed(open: "\"", close: "\""), multiline: false),
        ],
        atoms: [charLiteral],
        keepsStringRules: true
    )

    /// The `<header>` of `#include <header>`, coloured as a string (the only
    /// `.string` rule; quoted literals are the profile's).
    static let includeRule = LanguageRule(pattern: #"(?<=#include)[ \t]*<[^>\r\n]*>"#, kind: .string)

    /// Preprocessor / include / number rules shared with C++ (comments,
    /// strings and character literals are the profile's).
    static func baseRules() -> [LanguageRule] {
        [
            // Preprocessor directive token (only matches at the start of the
            // line, via `^`).
            LanguageRule(pattern: #"^\s*#\w+"#, kind: .type),
            includeRule,
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
                // (disjoint sets); rules only run in code segments, so a
                // built-in word inside a string or comment is never reached.
                wordRule(builtins, kind: .builtin),
            ],
            keywords: keywords,
            builtins: builtins,
            lexicalProfile: lexicalProfile
        )
    }
}
