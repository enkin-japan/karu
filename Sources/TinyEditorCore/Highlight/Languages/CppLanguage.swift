import Foundation

/// C++ definition (v1, line-based).
///
/// Built on top of `CLanguage`: it reuses C's comment / string / char-literal
/// / preprocessor / number rules and keyword set, adding the C++-only
/// keywords, the `::` scope-resolution operator, and raw string literals.
///
/// Line-approximation trade-offs accepted for v1 (in addition to those
/// inherited from `CLanguage`):
/// - Raw string literals `R"(...)"` are approximated per line: a literal that
///   opens and closes on the same line is coloured exactly (a custom
///   delimiter between `"` and `(`, e.g. `R"delim(...)delim"`, is not
///   recognised — only the plain `R"( … )"` form); an *opening* line colours
///   from `R"(` to end-of-line, with no cross-line state for the closing
///   line.
public enum CppLanguage {
    /// See `JSONLanguage.buildCount`.
    nonisolated(unsafe) public static var buildCount = 0

    /// C++-only keywords, added to `CLanguage.keywords` (duplicates such as
    /// `auto` / `inline`, already in the C set, are omitted here).
    static let extraKeywords: [String] = [
        "class", "namespace", "template", "typename", "public", "private",
        "protected", "virtual", "override", "final", "new", "delete", "this",
        "nullptr", "true", "false", "constexpr", "consteval", "constinit",
        "decltype", "using", "try", "catch", "throw", "operator", "friend",
        "mutable", "explicit", "static_cast", "dynamic_cast", "const_cast",
        "reinterpret_cast", "co_await", "co_yield", "co_return", "concept",
        "requires",
    ]

    public static func make() -> LanguageDefinition {
        buildCount += 1
        let keywords = CLanguage.keywords + extraKeywords
        return LanguageDefinition(
            identifier: "cpp",
            fileExtensions: ["cpp", "cc", "cxx", "hpp", "hh"],
            rules: [
                // Line comment.
                LanguageRule(pattern: #"//.*"#, kind: .comment),
                // Block comment: complete-on-line, then open-to-end-of-line.
                LanguageRule(pattern: #"/\*.*?\*/"#, kind: .comment),
                LanguageRule(pattern: #"/\*.*"#, kind: .comment),
                // Raw string literal: complete-on-line, then open-to-EOL.
                LanguageRule(pattern: #"R"\([^)]*\)""#, kind: .string),
                LanguageRule(pattern: #"R"\(.*"#, kind: .string),
                // Strings and char literals.
                LanguageRule(pattern: #""(?:[^"\\]|\\.)*""#, kind: .string),
                LanguageRule(pattern: #"'(?:[^'\\]|\\.)*'"#, kind: .string),
                // Preprocessor directive token (line-start only).
                LanguageRule(pattern: #"^\s*#\w+"#, kind: .type),
                // Scope resolution operator.
                LanguageRule(pattern: #"::"#, kind: .punctuation),
                // Keywords (C's set plus C++-only additions).
                CLanguage.wordRule(keywords, kind: .keyword),
                // Numbers (same shape as C).
                LanguageRule(
                    pattern: #"(?<![\w.])(?:0[xX][0-9a-fA-F]+[uUlL]*|(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?[uUlLfF]*)"#,
                    kind: .number
                ),
            ],
            keywords: keywords
        )
    }
}
