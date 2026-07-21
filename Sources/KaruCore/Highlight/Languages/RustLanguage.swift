import Foundation

/// Rust definition (v1, line-based).
///
/// Line-approximation trade-offs accepted for v1:
/// - `//` line comments (including `///` doc comments) are exact; `/* … */`
///   block comments are approximated per line with no cross-line state.
/// - Raw strings (`r"…"`, `r#"…"#`) are coloured only in their single-line form.
/// - Lifetimes (`'a`) are coloured like properties; a character literal
///   (`'x'`) is detected first so it is not mistaken for a lifetime.
/// - Macro invocations (`println!`, `vec!`) are coloured like functions via the
///   `word!` rule.
public enum RustLanguage {
    /// See `JSONLanguage.buildCount`.
    nonisolated(unsafe) public static var buildCount = 0

    public static let keywords: [String] = [
        "as", "async", "await", "break", "const", "continue", "crate", "dyn",
        "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in",
        "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return",
        "self", "Self", "static", "struct", "super", "trait", "true", "type",
        "union", "unsafe", "use", "where", "while",
    ]

    /// Common standard-library types / enum variants, coloured as types.
    public static let types: [String] = [
        "Option", "Result", "Some", "None", "Ok", "Err", "Vec", "String",
        "Box", "Rc", "Arc", "Cell", "RefCell", "HashMap", "HashSet", "BTreeMap",
        "bool", "char", "str", "i8", "i16", "i32", "i64", "i128", "isize",
        "u8", "u16", "u32", "u64", "u128", "usize", "f32", "f64",
    ]

    /// Builds a `\b(word1|word2|…)\b` rule producing `kind`.
    static func wordRule(_ words: [String], kind: TokenKind) -> LanguageRule {
        LanguageRule(pattern: "\\b(?:\(words.joined(separator: "|")))\\b", kind: kind)
    }

    public static func make() -> LanguageDefinition {
        buildCount += 1
        return LanguageDefinition(
            identifier: "rust",
            fileExtensions: ["rs"],
            rules: [
                // Line comment (covers `//` and `///`).
                LanguageRule(pattern: #"//.*"#, kind: .comment),
                // Block comment: complete-on-line, then open-to-end-of-line.
                LanguageRule(pattern: #"/\*.*?\*/"#, kind: .comment),
                LanguageRule(pattern: #"/\*.*"#, kind: .comment),
                // Raw strings (single-line form), then normal strings.
                LanguageRule(pattern: ##"r#"(?:[^"]|"(?!#))*"#"##, kind: .string),
                LanguageRule(pattern: #"r"[^"]*""#, kind: .string),
                LanguageRule(pattern: #""(?:[^"\\]|\\.)*""#, kind: .string),
                // Character literal before lifetime, so `'x'` is not a lifetime.
                LanguageRule(pattern: #"'(?:[^'\\]|\\.)'"#, kind: .string),
                // Lifetime annotation.
                LanguageRule(pattern: #"'[A-Za-z_]\w*"#, kind: .property),
                // Macro invocation (`println!`, `vec!`), coloured like a function.
                LanguageRule(pattern: #"\b[A-Za-z_]\w*!"#, kind: .builtin),
                // Numbers with `_` separators and optional type suffix.
                LanguageRule(
                    pattern: #"(?<![\w.])(?:0[xX][0-9a-fA-F_]+|0[oO][0-7_]+|0[bB][01_]+|(?:\d[\d_]*(?:\.[\d_]*)?)(?:[eE][+-]?\d+)?)(?:[iuf](?:8|16|32|64|128|size))?"#,
                    kind: .number
                ),
                wordRule(keywords, kind: .keyword),
                wordRule(types, kind: .type),
            ],
            keywords: keywords,
            builtins: types
        )
    }
}
