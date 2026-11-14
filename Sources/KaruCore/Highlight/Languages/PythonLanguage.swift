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

    /// Control-flow keywords (`keyword.control.flow` / `.import` in VS Code's
    /// MagicPython grammar). `in` is one too (`for x in`); the soft keywords
    /// `match` / `case` are control only at a statement start
    /// (`softKeywordRule`), so `match = …` stays a name.
    public static let controlKeywords: [String] = [
        "if", "elif", "else", "for", "while", "break", "continue", "return", "pass",
        "raise", "try", "except", "finally", "with", "as", "assert", "del", "yield",
        "await", "import", "from", "in",
    ]

    /// The other keywords and literals (`storage.type`, `keyword.operator`,
    /// `constant.language`).
    public static let otherKeywords: [String] = [
        "def", "class", "lambda", "global", "nonlocal", "is", "not", "and", "or",
        "None", "True", "False", "async",
    ]

    /// Built-in types and exceptions (`support.type`, `support.type.exception`).
    public static let builtinTypes: [String] = [
        "str", "int", "float", "bool", "list", "dict", "set", "tuple", "bytes",
        "bytearray", "frozenset", "complex", "object", "type", "super", "property",
        "staticmethod", "classmethod", "slice", "memoryview", "BaseException",
        "Exception", "ValueError", "TypeError", "KeyError", "IndexError",
        "AttributeError", "RuntimeError", "StopIteration", "FileNotFoundError",
        "NotImplementedError", "OSError", "IOError", "ImportError", "NameError",
        "ZeroDivisionError", "AssertionError", "LookupError", "PermissionError",
        "TimeoutError", "KeyboardInterrupt", "SystemExit", "UnicodeDecodeError",
        "UnicodeEncodeError",
    ]

    /// Built-in functions (`support.function.builtin`) and `__init__`
    /// (`support.function.magic`).
    public static let builtinFunctions: [String] = [
        "print", "len", "range", "open", "input", "isinstance", "issubclass",
        "enumerate", "zip", "map", "filter", "sorted", "reversed", "sum", "min",
        "max", "abs", "round", "repr", "hash", "id", "getattr", "setattr",
        "hasattr", "delattr", "callable", "iter", "next", "vars", "dir", "format",
        "any", "all", "divmod", "pow", "chr", "ord", "hex", "oct", "bin", "__init__",
    ]

    /// `match` / `case` at a statement start, not used as a name (`match =`,
    /// `match.x`, `match(…)`, `match[0]`; `case [x]:` is a pattern).
    static let softKeywordRule = LanguageRule(
        pattern: #"^[ \t]*(?:match|case)\b(?![ \t]*[=.,):]|[(\[])"#, kind: .controlKeyword)

    /// A keyword argument in a call on the same line (`f(a, key=1)`):
    /// `variable.parameter.function-call`, the parameter colour.
    static let keywordArgumentRule = LanguageRule(
        pattern: #"(?<!\w)(?=[A-Za-z_]\w*[ \t]*=(?!=))(?<=\([ \t]{0,8}|\([^()\r\n]{0,160},[ \t]{0,8})[A-Za-z_]\w*"#,
        kind: .parameter)

    /// Python's identifiers (M17 T17.7): VS Code colours no references to
    /// declared names, only the declarations themselves — `def` / `class`
    /// names and parameters — so the symbol table is not used for colour.
    static let identifierPolicy = IdentifierPolicy(tableFunctions: false, tableTypes: false,
                                                   tableVariables: false,
                                                   roles: IdentifierPolicy.declarationRoles)

    public static func make() -> LanguageDefinition {
        buildCount += 1
        let keywords = controlKeywords + otherKeywords + ["match", "case"]
        let builtins = builtinFunctions + builtinTypes + ["self", "__name__", "__main__"]
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
                // Decorator (`entity.name.function.decorator`, `@` included).
                LanguageRule(pattern: #"@\w+(?:\.\w+)*"#, kind: .symbolFunction),
                softKeywordRule,
                SyntaxRules.words(controlKeywords, .controlKeyword),
                SyntaxRules.words(otherKeywords, .keyword),
                // self / cls (`variable.language.special`).
                LanguageRule(pattern: #"\b(?:self|cls)\b"#, kind: .keyword),
                keywordArgumentRule,
                // Built-in types / functions after keywords and self / cls;
                // strings and comments are consumed earlier, so a built-in
                // word inside them is never matched here.
                SyntaxRules.words(builtinTypes, .type),
                SyntaxRules.words(builtinFunctions, .builtin),
                // `__name__` (`support.variable.magic`).
                LanguageRule(pattern: #"\b__name__\b"#, kind: .symbolVariable),
                // Numbers: hex/oct/bin, decimal/float with `_` separators,
                // optional exponent and imaginary `j` suffix. The lookbehind
                // stops a digit inside an identifier (e.g. `x1`) from matching.
                LanguageRule(
                    pattern: #"(?<![\w.])(?:0[xX][0-9a-fA-F_]+|0[oO][0-7_]+|0[bB][01_]+|(?:\d[\d_]*(?:\.[\d_]*)?|\.[\d_]+)(?:[eE][+-]?\d+)?[jJ]?)"#,
                    kind: .number
                ),
            ],
            keywords: keywords,
            builtins: builtins,
            identifierPolicy: identifierPolicy
        )
    }
}
