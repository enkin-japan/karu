import Foundation

/// C# definition.
///
/// Comments and strings come from `lexicalProfile` (M17 T17.3):
/// - `//` line comments and non-nesting `/* … */` block comments.
/// - Raw strings `"""…"""` (a run of N ≥ 3 quotes closes with exactly N,
///   multi-line, no escapes); interpolated raw strings `$"""…{x}…"""`.
///   `$$"""…{{x}}…"""` is approximated: `{{` opens the interpolation and the
///   first `}` closes it, so the second `}` reads as string content and a
///   single `{` stays literal (more `$` signs are not modelled).
/// - Verbatim strings `@"…"` (multi-line, no escapes, `""` is a quote) and
///   interpolated verbatim strings `$@"…"` / `@$"…"`.
/// - Interpolated strings `$"…{x}…"` (single-line, `\` escapes, `{{` is a
///   literal brace) and ordinary `"…"` strings.
/// - Interpolation holes are scanned as code (nested strings included).
/// - Character literals (`'"'`) are atoms, so they never open a string.
///
/// The regex rules cover the rest in code segments:
/// - Attributes are matched only in their simplest form `[Name]` (no
///   arguments); `[Obsolete("reason")]` is not recognised as a single token.
///
/// **Categories by position** (T17.7, VS Code's C# grammar): control-flow
/// keywords (`using` directives, `foreach … in`, `yield`) apart from the
/// others; `using` / `namespace` names types; `name(` a call; `obj.` and
/// `.Member` variables; library types (`List`, `Task`) types. Every other
/// identifier is a variable (the grammar scopes them so). Interpolation
/// holes' `{` / `}` are `.interpolationDelimiter` (plan §6; VS Code leaves
/// them uncoloured), and a verbatim string's `""` is string text (VS Code
/// colours it as an escape). Escapes: `\xH…`, `\uHHHH`, `\UHHHHHHHH`.
public enum CSharpLanguage {
    /// See `JSONLanguage.buildCount`.
    nonisolated(unsafe) public static var buildCount = 0

    /// Control-flow keywords (`keyword.control`, `keyword.other.directive.using`).
    static let controlKeywords: [String] = [
        "if", "else", "for", "foreach", "while", "do", "switch", "case", "default",
        "break", "continue", "return", "yield", "try", "catch", "finally", "throw",
        "goto", "using", "in", "await", "when",
    ]

    static let otherKeywords: [String] = [
        "class", "struct", "interface", "enum", "namespace",
        "public", "private", "protected", "internal", "static", "readonly",
        "const", "var", "new", "this", "base", "null", "true", "false",
        "void", "int", "string", "bool", "double", "char", "byte", "short", "uint",
        "ulong", "float", "decimal", "long", "object", "dynamic", "async",
        "is", "as", "out", "ref", "params", "get", "set", "value", "record", "init",
        "required", "sealed", "abstract", "virtual", "override", "partial", "where",
        "select", "from", "typeof", "nameof", "default",
    ]

    static let keywords: [String] = controlKeywords + otherKeywords

    /// Library types (`List`, `Task`), coloured as types.
    static let libraryTypes: [String] = [
        "String", "Int32", "Int64", "Double", "Decimal", "Boolean", "Object", "List",
        "Dictionary", "HashSet", "Queue", "Stack", "IEnumerable", "IList",
        "IDictionary", "Task", "ValueTask", "Action", "Func", "Predicate",
        "Exception", "ArgumentException", "InvalidOperationException",
        "NullReferenceException", "Guid", "DateTime", "TimeSpan",
    ]

    static let builtins: [String] = libraryTypes + [
        "Console", "WriteLine", "Write", "ReadLine", "Math", "Length", "Count",
        "ToString", "Equals", "GetHashCode", "Linq", "Select", "Where",
        "FirstOrDefault", "ToList", "ToArray",
    ]

    /// The names of a `using` directive or `namespace` declaration
    /// (`entity.name.type.namespace`).
    static let namespaceRule = LanguageRule(
        pattern: #"(?<=[ \t.])(?<=^[ \t]{0,32}(?:global[ \t]{1,8})?(?:using|namespace)[ \t]{1,8}(?:[\w.]{0,120}))[A-Za-z_]\w*"#,
        kind: .type)

    /// C#'s identifiers (T17.7): the whole table, every other name a
    /// variable. A bare method name (a method group) yields to a parameter,
    /// local, field or property of the same name (VH5,
    /// `functionNamesYieldToLocalBindings`).
    static let identifierPolicy: IdentifierPolicy = {
        var roles = IdentifierPolicy.declarationRoles
        roles[.variable] = .symbolVariable
        roles[.property] = .symbolVariable
        return IdentifierPolicy(otherIdentifiers: .symbolVariable, roles: roles,
                                functionNamesYieldToLocalBindings: true)
    }()

    /// `\xH…`, `\uHHHH`, `\UHHHHHHHH`.
    static let escapeForms: LexicalProfile.EscapeForms = [.hexRun, .unicode4, .unicode8]

    /// Interpolation hole of `$"…"` / `$@"…"` (`{{` is a literal brace).
    private static let hole = LexicalProfile.InterpolationForm(open: "{", close: "}", escapedOpen: "{{")

    /// Comments, the string family (most specific opener first: `$$"""`
    /// before `$"""` before `"""`; `$@"` / `@$"` before `@"` and `$"`) and
    /// character literals.
    public static let lexicalProfile = LexicalProfile(
        lineComments: ["//"],
        blockComments: [.init(open: "/*", close: "*/")],
        strings: [
            .init(prefixes: ["$$"], prefixRequired: true, delimiter: .repeatedQuote(quote: "\"", minimum: 3),
                  multiline: true, escape: nil, interpolations: [.init(open: "{{", close: "}")]),
            .init(prefixes: ["$"], prefixRequired: true, delimiter: .repeatedQuote(quote: "\"", minimum: 3),
                  multiline: true, escape: nil, interpolations: [.init(open: "{", close: "}")]),
            .init(delimiter: .repeatedQuote(quote: "\"", minimum: 3), multiline: true, escape: nil),
            .init(prefixes: ["$@", "@$"], prefixRequired: true, delimiter: .fixed(open: "\"", close: "\""),
                  multiline: true, escape: nil, doubledCloseEscapes: true, doubledCloseIsEscape: true,
                  interpolations: [hole]),
            .init(prefixes: ["@"], prefixRequired: true, delimiter: .fixed(open: "\"", close: "\""),
                  multiline: true, escape: nil, doubledCloseEscapes: true, doubledCloseIsEscape: true),
            .init(prefixes: ["$"], prefixRequired: true, delimiter: .fixed(open: "\"", close: "\""),
                  multiline: false, escapeForms: escapeForms, interpolations: [hole]),
            .init(delimiter: .fixed(open: "\"", close: "\""), multiline: false, escapeForms: escapeForms),
        ],
        atoms: [
            .init(pattern: #"'(?:[^'\\\r\n]|\\[^\r\n])+'"#, firstCharacters: "'", kind: .string),
        ],
        // VS Code leaves C# interpolation braces in the punctuation colour.
        interpolationDelimiterKind: .punctuation
    )

    public static func make() -> LanguageDefinition {
        buildCount += 1
        return LanguageDefinition(
            identifier: "csharp",
            fileExtensions: ["cs"],
            rules: [
                // Attribute, e.g. `[Obsolete]`.
                LanguageRule(pattern: #"\[\w+\]"#, kind: .type),
                namespaceRule,
                SyntaxRules.words(controlKeywords, .controlKeyword),
                SyntaxRules.words(otherKeywords, .keyword),
                SyntaxRules.call(),
                SyntaxRules.object(),
                SyntaxRules.member(.symbolVariable),
                // Library types after keywords (disjoint); attributes are
                // consumed earlier, and rules only run in code segments, so a
                // built-in word inside a string or comment is never reached.
                SyntaxRules.words(libraryTypes, .type),
                // Numbers: hex or decimal/float with optional exponent and
                // numeric-type suffix.
                LanguageRule(
                    pattern: #"(?<![\w.])(?:0[xX][0-9a-fA-F_]+[uUlL]*|(?:\d[\d_]*(?:\.[\d_]*)?|\.[\d_]+)(?:[eE][+-]?\d+)?[fFdDmMuUlL]*)"#,
                    kind: .number
                ),
            ],
            keywords: keywords,
            builtins: builtins,
            lexicalProfile: lexicalProfile,
            identifierPolicy: identifierPolicy
        )
    }
}
