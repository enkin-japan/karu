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
///
/// **Categories by position** (T17.7, VS Code's C++ grammar): C's, plus
/// `new`, `delete`, `using`, `operator` and the `co_*` keywords as control
/// keywords (Dark / Light Modern colour them so), a name before `::` a type
/// (`entity.name.scope-resolution`), standard containers types and
/// `cout` / `endl` variables. Every other identifier is a variable (the C++
/// grammar scopes them `variable.other`).
public enum CppLanguage {
    /// See `JSONLanguage.buildCount`.
    nonisolated(unsafe) public static var buildCount = 0

    /// C++-only control keywords (`keyword.control`, and the operators Dark /
    /// Light Modern colour like them).
    static let extraControlKeywords: [String] = [
        "try", "catch", "throw", "co_await", "co_yield", "co_return", "new",
        "delete", "using", "operator",
    ]

    /// C++-only keywords, added to `CLanguage.otherKeywords` (duplicates
    /// such as `auto` / `inline`, already in the C set, are omitted here).
    static let extraKeywords: [String] = [
        "class", "namespace", "template", "typename", "public", "private",
        "protected", "virtual", "override", "final", "this", "nullptr",
        "constexpr", "consteval", "constinit", "decltype", "friend", "mutable",
        "explicit", "static_cast", "dynamic_cast", "const_cast", "reinterpret_cast",
        "concept", "requires", "noexcept", "wchar_t", "char8_t", "char16_t", "char32_t",
    ]

    /// Standard-library types (`std::string`), coloured as types.
    static let libraryTypes: [String] = [
        "std", "string", "string_view", "vector", "set", "unordered_map",
        "unordered_set", "array", "deque", "queue", "stack", "pair", "tuple",
        "shared_ptr", "unique_ptr", "weak_ptr", "optional", "variant", "function",
    ]

    /// Standard-library functions, coloured as built-ins.
    static let libraryFunctions: [String] = [
        "make_pair", "make_tuple", "make_shared", "make_unique", "move", "forward",
        "swap", "sort", "find",
    ]

    /// Standard-library objects (`std::cout`), variables like every other
    /// name; listed for completion only (with the member functions).
    static let libraryVariables: [String] = [
        "cout", "cin", "cerr", "endl", "nullopt", "map", "begin", "end", "size",
        "push_back", "emplace_back", "insert", "erase", "clear",
    ]

    /// C++-only standard-library identifiers, added to `CLanguage.builtins`.
    static let extraBuiltins: [String] = libraryTypes + libraryFunctions + libraryVariables

    /// C's comments, strings and character literals plus raw strings (listed
    /// first, so `R"(` is not read as `R` + an ordinary string); keeps C's
    /// `#include <header>` string rule.
    public static let lexicalProfile = LexicalProfile(
        lineComments: ["//"],
        blockComments: [.init(open: "/*", close: "*/")],
        strings: [
            .init(prefixes: CLanguage.encodingPrefixes, delimiter: .cppRaw, multiline: true, escape: nil),
            .init(prefixes: CLanguage.encodingPrefixes, delimiter: .fixed(open: "\"", close: "\""), multiline: false,
                  escapeForms: .cStyle),
        ],
        atoms: [CLanguage.charLiteral],
        keepsStringRules: true
    )

    /// C++'s identifiers (T17.7): the whole table, every other name a
    /// variable; functions, types and parameters at their declarations. A
    /// bare function name yields to a parameter, local or member of the same
    /// name (VH5, `functionNamesYieldToLocalBindings`).
    static let identifierPolicy: IdentifierPolicy = {
        var roles = IdentifierPolicy.declarationRoles
        roles[.variable] = .symbolVariable
        roles[.property] = .symbolVariable
        return IdentifierPolicy(otherIdentifiers: .symbolVariable, roles: roles,
                                functionNamesYieldToLocalBindings: true)
    }()

    public static func make() -> LanguageDefinition {
        buildCount += 1
        let controls = CLanguage.controlKeywords + extraControlKeywords
        let others = CLanguage.otherKeywords + extraKeywords
        let keywords = controls + others
        let builtins = CLanguage.builtins + extraBuiltins
        return LanguageDefinition(
            identifier: "cpp",
            fileExtensions: ["cpp", "cc", "cxx", "hpp", "hh"],
            rules: [
                CLanguage.directiveRule,
                CLanguage.macroNameRule,
                CLanguage.includeRule,
                // Scope resolution operator.
                LanguageRule(pattern: #"::"#, kind: .punctuation),
                // Keywords (C's set plus C++-only additions).
                CLanguage.wordRule(controls, kind: .controlKeyword),
                CLanguage.wordRule(others, kind: .keyword),
                SyntaxRules.call(),
                // `name::` (also `std::`) before the library words; a
                // namespace's declared name.
                SyntaxRules.scopeQualifier,
                LanguageRule(pattern: #"(?<=\bnamespace[ \t]{1,8})[A-Za-z_]\w*"#, kind: .type),
                SyntaxRules.member(.symbolVariable, arrow: true),
                CLanguage.wordRule(libraryTypes, kind: .type),
                CLanguage.wordRule(CLanguage.builtins + libraryFunctions, kind: .builtin),
                // Numbers (same shape as C).
                LanguageRule(
                    pattern: #"(?<![\w.])(?:0[xX][0-9a-fA-F]+[uUlL]*|(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?[uUlLfF]*)"#,
                    kind: .number
                ),
            ],
            keywords: keywords,
            builtins: builtins,
            lexicalProfile: lexicalProfile,
            stringRules: [SyntaxRules.printfPlaceholder],
            identifierPolicy: identifierPolicy
        )
    }
}
