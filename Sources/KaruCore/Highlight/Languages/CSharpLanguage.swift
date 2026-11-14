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
public enum CSharpLanguage {
    /// See `JSONLanguage.buildCount`.
    nonisolated(unsafe) public static var buildCount = 0

    static let keywords: [String] = [
        "class", "struct", "interface", "enum", "namespace", "using",
        "public", "private", "protected", "internal", "static", "readonly",
        "const", "var", "new", "this", "base", "null", "true", "false", "if",
        "else", "for", "foreach", "while", "do", "switch", "case", "break",
        "continue", "return", "void", "int", "string", "bool", "double",
        "float", "decimal", "long", "object", "dynamic", "async", "await",
        "try", "catch", "finally", "throw", "is", "as", "in", "out", "ref",
        "params", "get", "set", "value", "record", "init", "required",
        "sealed", "abstract", "virtual", "override", "partial", "where",
        "select", "from",
    ]

    static let builtins: [String] = [
        "Console", "WriteLine", "Write", "ReadLine", "String", "Int32",
        "Int64", "Double", "Decimal", "Boolean", "Object", "Math", "List",
        "Dictionary", "HashSet", "Queue", "Stack", "IEnumerable", "IList",
        "IDictionary", "Task", "ValueTask", "Action", "Func", "Predicate",
        "Exception", "ArgumentException", "InvalidOperationException",
        "NullReferenceException", "Length", "Count", "ToString", "Equals",
        "GetHashCode", "nameof", "typeof", "Guid", "DateTime", "TimeSpan",
        "Linq", "Select", "Where", "FirstOrDefault", "ToList", "ToArray",
    ]

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
                  multiline: true, escape: nil, doubledCloseEscapes: true, interpolations: [hole]),
            .init(prefixes: ["@"], prefixRequired: true, delimiter: .fixed(open: "\"", close: "\""),
                  multiline: true, escape: nil, doubledCloseEscapes: true),
            .init(prefixes: ["$"], prefixRequired: true, delimiter: .fixed(open: "\"", close: "\""),
                  multiline: false, interpolations: [hole]),
            .init(delimiter: .fixed(open: "\"", close: "\""), multiline: false),
        ],
        atoms: [
            .init(pattern: #"'(?:[^'\\\r\n]|\\[^\r\n])+'"#, firstCharacters: "'", kind: .string),
        ]
    )

    public static func make() -> LanguageDefinition {
        buildCount += 1
        return LanguageDefinition(
            identifier: "csharp",
            fileExtensions: ["cs"],
            rules: [
                // Attribute, e.g. `[Obsolete]`.
                LanguageRule(pattern: #"\[\w+\]"#, kind: .type),
                // Keywords.
                LanguageRule(pattern: "\\b(?:\(keywords.joined(separator: "|")))\\b", kind: .keyword),
                // Built-in library types / members after keywords (disjoint);
                // attributes are consumed earlier, and rules only run in code
                // segments, so a built-in word inside a string or comment is
                // never reached here.
                LanguageRule(pattern: "\\b(?:\(builtins.joined(separator: "|")))\\b", kind: .builtin),
                // Numbers: hex or decimal/float with optional exponent and
                // numeric-type suffix.
                LanguageRule(
                    pattern: #"(?<![\w.])(?:0[xX][0-9a-fA-F_]+[uUlL]*|(?:\d[\d_]*(?:\.[\d_]*)?|\.[\d_]+)(?:[eE][+-]?\d+)?[fFdDmMuUlL]*)"#,
                    kind: .number
                ),
            ],
            keywords: keywords,
            builtins: builtins,
            lexicalProfile: lexicalProfile
        )
    }
}
