import Foundation

/// JavaScript / Node definition.
///
/// Comments and strings come from `lexicalProfile` (M17 T17.2, shared with
/// TypeScript): `//` line comments, non-nesting `/* … */` block comments that
/// span lines, `'…'` / `"…"` single-line strings with `\` escapes (escape +
/// newline continues the line), and multi-line template literals whose
/// `${…}` interpolations are scanned as code (nested templates and object
/// literals inside included). The regex rules cover numbers, keywords and
/// built-ins inside code segments only.
///
/// **Regex literals** (M17 T17.3) are an atom (`.regex`, split into body,
/// escapes, quantifiers, groups and flags by `LanguageDefinition.regexTokens`
/// since T17.7), so quotes, `//` and `/*` inside one stay inert.
/// Whether a `/` starts one or divides is decided from the text before it
/// (`regexContext`): the previous non-whitespace unit, across lines, must be
/// an operator or opening punctuation, or the word before it a keyword that
/// precedes an expression (`return /re/`); else — after an identifier,
/// number, `)` or `]` — it is division (`a / b / c`, `f(x) / 2`). The literal
/// must close on its line; the atom has no lookahead past its end, so a cut
/// line can never make it match where the whole line does not.
/// Approximations: `++` / `--` before a `/` read as operators (`i++ / 2 / x`
/// reads `/ 2 /` as a regex); `}` counts as a block end, so `}` followed by
/// `/re/` is a regex (VS Code reads division there); `<` is left out so a JSX
/// closing tag `</p>` is never a regex.
///
/// **Categories by position** (T17.7, as VS Code's grammar scopes them):
/// control-flow keywords (`keyword.control`: `import`, `return`, `if`, …)
/// apart from the other keywords; `=>` a keyword; `name(` a function call;
/// an all-caps name (`MAX_SIZE`) a constant; `obj.` an object and `.name` a
/// property (variables); built-in classes types, built-in functions
/// built-ins. Every other identifier is a variable; declarations take their
/// role (`const` bindings constants, parameters, functions, classes) —
/// `identifierPolicy`. Escapes in strings and templates: `\xHH`,
/// `\uHHHH`, `\u{…}`, legacy octal.
public enum JavaScriptLanguage {
    /// See `JSONLanguage.buildCount`.
    nonisolated(unsafe) public static var buildCount = 0

    /// Control-flow keywords (`keyword.control.*` in VS Code's grammar).
    public static let controlKeywords: [String] = [
        "if", "else", "for", "while", "do", "switch", "case", "default", "break",
        "continue", "return", "yield", "await", "try", "catch", "finally", "throw",
        "import", "export", "from", "as", "with",
    ]

    /// The other reserved words and literals (`storage.type`,
    /// `keyword.operator.expression`, `constant.language`, …).
    public static let otherKeywords: [String] = [
        "var", "let", "const", "function", "new", "delete", "typeof", "instanceof",
        "in", "of", "class", "extends", "super", "this", "null", "undefined", "true",
        "false", "async", "void", "static", "get", "set", "NaN", "Infinity",
    ]

    /// JavaScript reserved words / common globals (completion's list).
    /// Exposed so `TypeScript` can extend this set rather than duplicate it.
    public static let keywords: [String] = controlKeywords + otherKeywords

    /// Built-in classes, coloured as types (`support.class`,
    /// `entity.name.type`) unless called (`new Map()`, a function) or used as
    /// an object (`Object.keys`, a variable).
    public static let builtinTypes: [String] = [
        "Object", "Array", "String", "Number", "Boolean", "Symbol", "BigInt",
        "Promise", "Set", "Map", "WeakMap", "WeakSet", "Date", "RegExp", "Error",
        "TypeError", "RangeError", "SyntaxError",
    ]

    /// Built-in functions (`support.function`).
    public static let builtinFunctions: [String] = [
        "parseInt", "parseFloat", "isNaN", "isFinite", "encodeURIComponent",
        "decodeURIComponent", "fetch", "setTimeout", "setInterval", "clearTimeout",
        "clearInterval", "requestAnimationFrame", "require", "structuredClone",
        "queueMicrotask",
    ]

    /// Built-in objects VS Code colours as variables (no rule needed: every
    /// other identifier is a variable); listed for completion.
    public static let builtinVariables: [String] = [
        "console", "Math", "JSON", "window", "document", "module", "exports",
        "process", "globalThis",
    ]

    /// JavaScript / Node built-in globals and standard-library identifiers
    /// (completion's list). Exposed so `TypeScript` can extend this set
    /// rather than duplicate it.
    public static let builtins: [String] = builtinVariables + builtinTypes + builtinFunctions

    /// What may precede a regex literal (see the type comment).
    static let regexContext = LexicalProfile.AtomContext(
        characters: "(,=:[!&|?{};+-*%>~^",
        words: ["return", "typeof", "instanceof", "in", "of", "new", "delete", "void", "throw",
                "case", "do", "else", "yield", "await"]
    )

    /// Comments, strings, template literals and regex literals, shared with
    /// TypeScript.
    public static let lexicalProfile = LexicalProfile(
        lineComments: ["//"],
        blockComments: [.init(open: "/*", close: "*/")],
        strings: [
            .init(delimiter: .fixed(open: "\"", close: "\""), multiline: false, escapeForms: escapeForms),
            .init(delimiter: .fixed(open: "'", close: "'"), multiline: false, escapeForms: escapeForms),
            .init(delimiter: .fixed(open: "`", close: "`"), multiline: true, escapeForms: escapeForms,
                  interpolations: [.init(open: "${", close: "}")]),
        ],
        atoms: [
            // `/body/flags`: escapes, and classes in which `/` is literal.
            .init(pattern: #"/(?![/*])(?:\\[^\r\n]|\[(?:\\[^\r\n]|[^\]\\\r\n])*\]|[^/\\\[\r\n])+/[dgimsuyv]*"#,
                  firstCharacters: "/", kind: .regex, precededBy: regexContext),
        ]
    )

    /// `\xHH`, `\uHHHH`, `\u{…}`, legacy octal (VS Code: any `\c` is an
    /// escape too).
    static let escapeForms: LexicalProfile.EscapeForms = [.hex2, .unicode4, .unicodeBraced, .octal]

    /// Number rule shared with TypeScript (comments and strings are the
    /// profile's).
    static func numberRules() -> [LanguageRule] {
        [
            // Numbers: hex / octal / binary / decimal / float, with optional
            // BigInt `n` suffix. Lookbehind avoids matching digits mid-identifier.
            LanguageRule(
                pattern: #"(?<![\w.])(?:0[xX][0-9a-fA-F]+n?|0[bB][01]+n?|0[oO][0-7]+n?|\d[\d_]*n|(?:\d[\d_]*(?:\.[\d_]*)?|\.\d[\d_]*)(?:[eE][+-]?\d+)?)"#,
                kind: .number
            ),
        ]
    }

    /// Builds a `\b(word1|word2|…)\b` rule producing `kind`.
    static func wordRule(_ words: [String], kind: TokenKind) -> LanguageRule {
        SyntaxRules.words(words, kind)
    }

    /// The rules shared with TypeScript, given its extra word lists (ordered
    /// so that keywords win over the identifier rules, a call over a type).
    static func rules(controls: [String], keywords: [String], typeWords: [String],
                      builtinTypes: [String], builtinFunctions: [String]) -> [LanguageRule] {
        var out = numberRules()
        out.append(LanguageRule(pattern: "=>", kind: .keyword))
        out.append(wordRule(controls, kind: .controlKeyword))
        if !typeWords.isEmpty { out.append(wordRule(typeWords, kind: .type)) }
        out.append(wordRule(keywords, kind: .keyword))
        out.append(SyntaxRules.call(dollar: true))
        out.append(SyntaxRules.upperSnake(.constant, dollar: true))
        out.append(SyntaxRules.object(dollar: true))
        out.append(SyntaxRules.member(.symbolVariable, dollar: true))
        out.append(wordRule(builtinTypes, kind: .type))
        out.append(wordRule(builtinFunctions, kind: .builtin))
        return out
    }

    /// Every identifier is a variable unless classified; declarations take
    /// their role (`const` bindings constants). A function name is a
    /// function only where declared or called (`name(`): VS Code colours a
    /// reference to it (`export { f }`, a callback) as a variable, so the
    /// table's functions are not used. Shared with TypeScript.
    static let identifierPolicy: IdentifierPolicy = {
        var roles = IdentifierPolicy.declarationRoles
        for kind in [DeclarationScan.DeclarationKind.variable, .functionScopedVariable, .import, .property] {
            roles[kind] = .symbolVariable
        }
        return IdentifierPolicy(tableFunctions: false, otherIdentifiers: .symbolVariable, roles: roles,
                                constDeclarationsAreConstants: true, dollarIdentifiers: true)
    }()

    public static func make() -> LanguageDefinition {
        buildCount += 1
        return LanguageDefinition(
            identifier: "javascript",
            fileExtensions: ["js", "mjs", "cjs"],
            rules: rules(controls: controlKeywords, keywords: otherKeywords, typeWords: [],
                         builtinTypes: builtinTypes, builtinFunctions: builtinFunctions),
            keywords: keywords,
            builtins: builtins,
            lexicalProfile: lexicalProfile,
            identifierPolicy: identifierPolicy
        )
    }
}
