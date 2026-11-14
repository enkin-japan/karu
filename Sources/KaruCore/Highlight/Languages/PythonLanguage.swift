import Foundation

/// Python lexical categories. `PythonTokenizer` handles string prefixes,
/// nested f-string expressions, escaped braces and streamed triple-quoted
/// strings; these regex rules classify code outside strings and inside fields.
/// This is lexical highlighting, not a Python parser or language server.
public enum PythonLanguage {
    /// See `JSONLanguage.buildCount`.
    nonisolated(unsafe) public static var buildCount = 0

    /// Python's string and comment structure as a generic `LexicalProfile`,
    /// for **analysis only** (M17 T17.4a: the declaration scanner reads
    /// declarations from code segments only). Highlighting keeps
    /// `PythonTokenizer`: the T17.2 experiment
    /// (`PythonProfileExperimentTests`) showed the cross-line structure agrees
    /// with it, but the generic scanner has no notion of f-string format specs
    /// and conversions, which the tokenizer colours.
    ///
    /// Prefixes r / u / b / f and their two-letter combinations, any case;
    /// single-line quotes (backslash-newline continues), triple quotes over
    /// lines; f-string `{…}` fields are code (`{{` is an escaped brace). A
    /// format spec after `:` and `!r` / `!s` / `!a` read as code, which is
    /// harmless for declarations (no binding form looks like them).
    public static let analysisProfile: LexicalProfile = {
        typealias Form = LexicalProfile.StringForm
        let field = LexicalProfile.InterpolationForm(open: "{", close: "}", escapedOpen: "{{")
        let formatted = ["f", "fr", "rf"]
        let other = ["r", "u", "b", "br", "rb"]
        var forms: [Form] = []
        for quote in ["\"\"\"", "'''"] {
            forms.append(Form(prefixes: formatted, prefixRequired: true, prefixCaseInsensitive: true,
                              delimiter: .fixed(open: quote, close: quote), multiline: true,
                              interpolations: [field]))
            forms.append(Form(prefixes: other, prefixCaseInsensitive: true,
                              delimiter: .fixed(open: quote, close: quote), multiline: true))
        }
        for quote in ["\"", "'"] {
            forms.append(Form(prefixes: formatted, prefixRequired: true, prefixCaseInsensitive: true,
                              delimiter: .fixed(open: quote, close: quote), multiline: false,
                              interpolations: [field]))
            forms.append(Form(prefixes: other, prefixCaseInsensitive: true,
                              delimiter: .fixed(open: quote, close: quote), multiline: false))
        }
        return LexicalProfile(lineComments: ["#"], strings: forms)
    }()

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
        let builtins = [
            "print", "len", "range", "str", "int", "float", "bool", "list",
            "dict", "set", "tuple", "open", "input", "type", "isinstance",
            "issubclass", "enumerate", "zip", "map", "filter", "sorted",
            "reversed", "sum", "min", "max", "abs", "round", "repr", "hash",
            "id", "super", "property", "staticmethod", "classmethod",
            "getattr", "setattr", "hasattr", "delattr", "callable", "iter",
            "next", "vars", "dir", "format", "any", "all", "divmod", "pow",
            "chr", "ord", "hex", "oct", "bin", "bytes", "bytearray",
            "frozenset", "complex", "slice", "object", "Exception",
            "ValueError", "TypeError", "KeyError", "IndexError",
            "AttributeError", "RuntimeError", "StopIteration",
            "FileNotFoundError", "NotImplementedError", "self", "__init__",
            "__name__", "__main__",
        ]
        let bw = builtins.joined(separator: "|")

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
                // Built-in functions / types / common globals (after keywords
                // and self/cls, so those keep their own colour; strings and
                // comments are consumed earlier, so a built-in word inside them
                // is never matched here).
                LanguageRule(pattern: "\\b(?:\(bw))\\b", kind: .builtin),
                // Numbers: hex/oct/bin, decimal/float with `_` separators,
                // optional exponent and imaginary `j` suffix. The lookbehind
                // stops a digit inside an identifier (e.g. `x1`) from matching.
                LanguageRule(
                    pattern: #"(?<![\w.])(?:0[xX][0-9a-fA-F_]+|0[oO][0-7_]+|0[bB][01_]+|(?:\d[\d_]*(?:\.[\d_]*)?|\.[\d_]+)(?:[eE][+-]?\d+)?[jJ]?)"#,
                    kind: .number
                ),
            ],
            keywords: keywords,
            builtins: builtins
        )
    }
}
