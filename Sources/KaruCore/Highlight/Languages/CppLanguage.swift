import Foundation

/// C++ definition.
///
/// Built on top of `CLanguage`: it reuses C's preprocessor / number rules,
/// character-literal atom and keyword set, adding the C++-only keywords and
/// the `::` scope-resolution operator.
///
/// Comments and strings come from `lexicalProfile` (M17 T17.3): C's profile
/// plus raw string literals `R"delim(…)delim"` (any delimiter of up to 16
/// units, spanning lines, no escapes, with the `L` / `u` / `U` / `u8`
/// prefixes). A digit separator (`1'000'000`) never starts a character
/// literal (see `CLanguage.charLiteral`).
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

    /// C++-only standard-library identifiers, added to `CLanguage.builtins`.
    static let extraBuiltins: [String] = [
        "std", "cout", "cin", "cerr", "endl", "string", "vector", "map",
        "set", "unordered_map", "unordered_set", "array", "deque", "queue",
        "stack", "pair", "tuple", "make_pair", "make_tuple", "shared_ptr",
        "unique_ptr", "weak_ptr", "make_shared", "make_unique", "move",
        "forward", "swap", "sort", "find", "begin", "end", "size",
        "push_back", "emplace_back", "insert", "erase", "clear", "nullopt",
        "optional", "variant", "function",
    ]

    /// C's comments, strings and character literals plus raw strings (listed
    /// first, so `R"(` is not read as `R` + an ordinary string); keeps C's
    /// `#include <header>` string rule.
    public static let lexicalProfile = LexicalProfile(
        lineComments: ["//"],
        blockComments: [.init(open: "/*", close: "*/")],
        strings: [
            .init(prefixes: CLanguage.encodingPrefixes, delimiter: .cppRaw, multiline: true, escape: nil),
            .init(prefixes: CLanguage.encodingPrefixes, delimiter: .fixed(open: "\"", close: "\""), multiline: false),
        ],
        atoms: [CLanguage.charLiteral],
        keepsStringRules: true
    )

    public static func make() -> LanguageDefinition {
        buildCount += 1
        let keywords = CLanguage.keywords + extraKeywords
        let builtins = CLanguage.builtins + extraBuiltins
        return LanguageDefinition(
            identifier: "cpp",
            fileExtensions: ["cpp", "cc", "cxx", "hpp", "hh"],
            rules: [
                // Preprocessor directive token (line-start only).
                LanguageRule(pattern: #"^\s*#\w+"#, kind: .type),
                CLanguage.includeRule,
                // Scope resolution operator.
                LanguageRule(pattern: #"::"#, kind: .punctuation),
                // Keywords (C's set plus C++-only additions).
                CLanguage.wordRule(keywords, kind: .keyword),
                // Standard-library identifiers (C's set plus C++-only
                // additions), after keywords and disjoint from them.
                CLanguage.wordRule(builtins, kind: .builtin),
                // Numbers (same shape as C).
                LanguageRule(
                    pattern: #"(?<![\w.])(?:0[xX][0-9a-fA-F]+[uUlL]*|(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?[uUlLfF]*)"#,
                    kind: .number
                ),
            ],
            keywords: keywords,
            builtins: builtins,
            lexicalProfile: lexicalProfile
        )
    }
}
