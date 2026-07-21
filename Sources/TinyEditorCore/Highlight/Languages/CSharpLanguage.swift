import Foundation

/// C# definition (v1, line-based).
///
/// Line-approximation trade-offs accepted for v1:
/// - `//` line comments are exact; `/* … */` block comments are
///   approximated: complete-on-line is coloured exactly, an opening line
///   colours to end-of-line, and interior/closing lines of a multi-line
///   block comment are not tracked (no cross-line state).
/// - Verbatim strings `@"…"` are approximated per line the same way
///   (`""` — the verbatim escape for a literal quote — is accepted within a
///   complete-on-line match); a verbatim string spanning multiple lines is
///   only coloured on its opening line.
/// - Interpolated strings `$"…"` are coloured as a whole string token;
///   `{…}` interpolation holes are not tokenized separately, matching the
///   template-literal trade-off used for JS/TS.
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

    public static func make() -> LanguageDefinition {
        buildCount += 1
        return LanguageDefinition(
            identifier: "csharp",
            fileExtensions: ["cs"],
            rules: [
                // Line comment.
                LanguageRule(pattern: #"//.*"#, kind: .comment),
                // Block comment: complete-on-line, then open-to-end-of-line.
                LanguageRule(pattern: #"/\*.*?\*/"#, kind: .comment),
                LanguageRule(pattern: #"/\*.*"#, kind: .comment),
                // Verbatim string: complete-on-line (accepting `""` escapes),
                // then open-to-end-of-line.
                LanguageRule(pattern: #"@"(?:[^"]|"")*""#, kind: .string),
                LanguageRule(pattern: #"@".*"#, kind: .string),
                // Interpolated string.
                LanguageRule(pattern: #"\$"(?:[^"\\]|\\.)*""#, kind: .string),
                // Plain string.
                LanguageRule(pattern: #""(?:[^"\\]|\\.)*""#, kind: .string),
                // Attribute, e.g. `[Obsolete]`.
                LanguageRule(pattern: #"\[\w+\]"#, kind: .type),
                // Keywords.
                LanguageRule(pattern: "\\b(?:\(keywords.joined(separator: "|")))\\b", kind: .keyword),
                // Numbers: hex or decimal/float with optional exponent and
                // numeric-type suffix.
                LanguageRule(
                    pattern: #"(?<![\w.])(?:0[xX][0-9a-fA-F_]+[uUlL]*|(?:\d[\d_]*(?:\.[\d_]*)?|\.[\d_]+)(?:[eE][+-]?\d+)?[fFdDmMuUlL]*)"#,
                    kind: .number
                ),
            ],
            keywords: keywords,
            builtins: builtins
        )
    }
}
