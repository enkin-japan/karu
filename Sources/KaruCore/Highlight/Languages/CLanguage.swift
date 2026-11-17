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
///
/// **Categories by position** (T17.7, as VS Code's C grammar scopes them):
/// preprocessor directives and control-flow keywords are control keywords; a
/// `#define`d name a keyword; `name(` a function call; `obj.` / `obj->` and
/// the member after them variables; printf conversions in strings
/// (`%zu`) placeholders. Other identifiers stay uncoloured: VS Code colours
/// neither local variables nor struct / typedef names in C, only function
/// names and parameters at their declarations (`identifierPolicy`).
/// Escapes: `\xH…`, `\uHHHH`, `\UHHHHHHHH`, octal.
public enum CLanguage {
    /// See `JSONLanguage.buildCount`.
    nonisolated(unsafe) public static var buildCount = 0

    /// Control-flow keywords (`keyword.control`).
    public static let controlKeywords: [String] = [
        "if", "else", "for", "while", "do", "switch", "case", "default", "break",
        "continue", "return", "goto",
    ]

    /// The other C keywords (`storage.type`, `storage.modifier`,
    /// `keyword.operator.sizeof`), with the standard typedefs and streams VS
    /// Code scopes like them (`size_t`, `stderr`, `NULL`).
    public static let otherKeywords: [String] = [
        "int", "char", "long", "short", "unsigned", "signed", "float", "double",
        "void", "struct", "union", "enum", "typedef", "static", "extern",
        "const", "volatile", "register", "auto", "sizeof", "inline", "restrict",
        "_Bool", "bool", "size_t", "ssize_t", "ptrdiff_t", "intptr_t", "uintptr_t",
        "int8_t", "int16_t", "int32_t", "int64_t", "uint8_t", "uint16_t", "uint32_t",
        "uint64_t", "stdin", "stdout", "stderr", "NULL", "true", "false",
    ]

    /// C keywords (completion's list). Exposed so `CppLanguage` can extend
    /// this set rather than duplicate it.
    public static let keywords: [String] = controlKeywords + otherKeywords

    /// C standard-library functions / macros (`support.function`). Exposed
    /// so `CppLanguage` can extend this set rather than duplicate it.
    public static let builtins: [String] = [
        "printf", "fprintf", "sprintf", "snprintf", "scanf", "fscanf",
        "sscanf", "malloc", "calloc", "realloc", "free", "memcpy", "memmove",
        "memset", "strlen", "strcpy", "strncpy", "strcmp", "strncmp",
        "strcat", "fopen", "fclose", "fread", "fwrite", "fseek", "ftell",
        "fflush", "fgets", "fputs", "putchar", "getchar", "puts", "exit",
        "abort", "assert", "FILE", "EOF",
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
            .init(prefixes: encodingPrefixes, delimiter: .fixed(open: "\"", close: "\""), multiline: false,
                  escapeForms: .cStyle),
        ],
        atoms: [charLiteral],
        keepsStringRules: true
    )

    /// The `<header>` of `#include <header>`, coloured as a string (the only
    /// `.string` rule; quoted literals are the profile's).
    static let includeRule = LanguageRule(pattern: #"(?<=#include)[ \t]*<[^>\r\n]*>"#, kind: .string)

    /// Preprocessor directive token (only at a line start, via `^`):
    /// `keyword.control.directive`.
    static let directiveRule = LanguageRule(pattern: #"^\s*#\s*\w+"#, kind: .controlKeyword)

    /// The name a `#define` introduces (`entity.name.function.preprocessor`,
    /// the keyword colour).
    static let macroNameRule = LanguageRule(pattern: #"(?<=#define[ \t]{1,8})[A-Za-z_]\w*"#, kind: .keyword)

    /// C's identifiers (T17.7): functions from the table (declarations and
    /// `name(` calls) and function / parameter roles; no variable or type
    /// colours for references. A bare function name yields to a parameter
    /// or local of the same name (VH5, `functionNamesYieldToLocalBindings`).
    static let identifierPolicy = IdentifierPolicy(tableTypes: false, tableVariables: false,
                                                   roles: [.function: .symbolFunction, .method: .symbolFunction,
                                                           .parameter: .parameter],
                                                   functionNamesYieldToLocalBindings: true)

    /// Preprocessor / include / number rules shared with C++ (comments,
    /// strings and character literals are the profile's).
    static func baseRules() -> [LanguageRule] {
        [
            directiveRule,
            macroNameRule,
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
                wordRule(controlKeywords, kind: .controlKeyword),
                wordRule(otherKeywords, kind: .keyword),
                // Standard-library functions / macros after keywords
                // (disjoint sets); rules only run in code segments, so a
                // built-in word inside a string or comment is never reached.
                wordRule(builtins, kind: .builtin),
                SyntaxRules.call(),
                SyntaxRules.object(arrow: true),
                SyntaxRules.member(.symbolVariable, arrow: true),
            ],
            keywords: keywords,
            builtins: builtins,
            lexicalProfile: lexicalProfile,
            stringRules: [SyntaxRules.printfPlaceholder],
            identifierPolicy: identifierPolicy
        )
    }
}
