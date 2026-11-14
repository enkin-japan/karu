import Foundation

/// Rust definition.
///
/// Comments and strings come from `lexicalProfile` (M17 T17.2): `//` line
/// comments (including `///` / `//!` doc comments), nesting `/* … */` block
/// comments, `"…"` strings that may span lines (with `\` escapes, and `b` /
/// `c` prefixes), raw strings `r"…"` / `r#"…"#` (any number of hashes, `b` /
/// `c` prefixes, no escapes). Character literals (`'x'`, `'\''`, `b'x'`) and
/// lifetimes (`'a`) are atoms, so a `'"'` never opens a string.
/// - Lifetimes are coloured like properties; character literals like strings.
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

    /// Comments, strings, raw strings, character literals and lifetimes.
    public static let lexicalProfile = LexicalProfile(
        lineComments: ["//"],
        blockComments: [.init(open: "/*", close: "*/", nests: true)],
        strings: [
            // Raw (byte / C) strings: `r"…"`, `r#"…"#`, `br##"…"##`, `cr"…"`.
            .init(prefixes: ["b", "c"], delimiter: .hashed(lead: "r", hash: "#", quote: "\"",
                                                            hashesApplyToEscapes: false),
                  multiline: true, escape: nil),
            // Ordinary (byte / C) strings; they may span lines.
            .init(prefixes: ["b", "c"], delimiter: .fixed(open: "\"", close: "\""), multiline: true),
        ],
        atoms: [
            // Character / byte literal, before the lifetime so `'x'` wins.
            .init(pattern: #"'(?:[^'\\\r\n]|\\(?:x[0-9A-Fa-f]{2}|u\{[0-9A-Fa-f_]{1,6}\}|[^\r\n]))'"#,
                  firstCharacters: "'", kind: .string, prefixes: ["b"]),
            // Lifetime / label.
            .init(pattern: #"'[A-Za-z_][A-Za-z0-9_]*"#, firstCharacters: "'", kind: .property),
        ]
    )

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
            builtins: types,
            lexicalProfile: lexicalProfile
        )
    }
}
