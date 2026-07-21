import Foundation

/// Python definition (v1, line-based).
///
/// Line-approximation trade-offs accepted for v1:
/// - Triple-quoted strings are approximated per line: a triple quote that both
///   opens and closes on one line is coloured exactly; an *opening* line
///   colours from the triple quote to end-of-line. A line that only *closes* a
///   multi-line string (text preceding a trailing `'''`) is not detected as a
///   string, because there is no cross-line state.
/// - Prefixed strings (f / r / b / u, and their combinations) are treated the
///   same as plain strings; f-string interpolations `{…}` are not tokenized
///   separately.
public enum PythonLanguage {
    /// See `JSONLanguage.buildCount`.
    nonisolated(unsafe) public static var buildCount = 0

    public static func make() -> LanguageDefinition {
        buildCount += 1
        let keywords = [
            "def", "class", "if", "elif", "else", "for", "while", "return",
            "import", "from", "as", "with", "try", "except", "finally", "raise",
            "lambda", "pass", "break", "continue", "global", "nonlocal", "yield",
            "assert", "del", "is", "in", "not", "and", "or", "None", "True",
            "False", "async", "await", "match", "case",
        ]
        let kw = keywords.joined(separator: "|")

        return LanguageDefinition(
            identifier: "python",
            fileExtensions: ["py", "pyw"],
            rules: [
                // Triple-quoted strings (optional string prefix). Complete-on-line
                // form first, then the open-to-end-of-line fallback.
                LanguageRule(pattern: #"[rRbBfFuU]{0,2}"""(?:.*?"""|.*)"#, kind: .string),
                LanguageRule(pattern: #"[rRbBfFuU]{0,2}'''(?:.*?'''|.*)"#, kind: .string),
                // Single-line strings with optional prefix.
                LanguageRule(pattern: #"[rRbBfFuU]{0,2}"(?:[^"\\]|\\.)*""#, kind: .string),
                LanguageRule(pattern: #"[rRbBfFuU]{0,2}'(?:[^'\\]|\\.)*'"#, kind: .string),
                // Comment (reached only outside strings, which are consumed first).
                LanguageRule(pattern: #"#.*"#, kind: .comment),
                // Decorator.
                LanguageRule(pattern: #"@\w+(?:\.\w+)*"#, kind: .type),
                // Keywords.
                LanguageRule(pattern: "\\b(?:\(kw))\\b", kind: .keyword),
                // self / cls.
                LanguageRule(pattern: #"\b(?:self|cls)\b"#, kind: .property),
                // Numbers: hex/oct/bin, decimal/float with `_` separators,
                // optional exponent and imaginary `j` suffix. The lookbehind
                // stops a digit inside an identifier (e.g. `x1`) from matching.
                LanguageRule(
                    pattern: #"(?<![\w.])(?:0[xX][0-9a-fA-F_]+|0[oO][0-7_]+|0[bB][01_]+|(?:\d[\d_]*(?:\.[\d_]*)?|\.[\d_]+)(?:[eE][+-]?\d+)?[jJ]?)"#,
                    kind: .number
                ),
            ]
        )
    }
}
