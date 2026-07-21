import Foundation

/// Bash/zsh shell script definition (v1, line-based).
///
/// Line-approximation trade-offs accepted for v1:
/// - A shebang (`#!…`) is only recognised as such at the very start of the
///   line (`^#!`); this is exact for the first line of a script, but a
///   `#!` appearing later in a line (rare, and not a shebang there) would
///   also match since there is no "line 1 only" state.
/// - Variable expansion (`$VAR`, `${VAR}`) is only tokenized when it appears
///   outside a string; a `$VAR` inside a double-quoted string is not split
///   out separately because the whole quoted string is matched as one token
///   first (mirroring the other languages' string-priority behaviour).
///   Single-quoted strings never expand variables in real Bash, which this
///   matches naturally.
/// - Command substitution (`` `…` `` / `$(…)`) and here-docs are not
///   specially recognised.
public enum BashLanguage {
    /// See `JSONLanguage.buildCount`.
    nonisolated(unsafe) public static var buildCount = 0

    static let keywords: [String] = [
        "if", "then", "else", "elif", "fi", "for", "while", "do", "done",
        "case", "esac", "function", "in", "select", "until", "return", "exit",
        "local", "export", "readonly", "declare", "source", "alias", "set",
        "unset", "shift", "trap",
    ]

    public static func make() -> LanguageDefinition {
        buildCount += 1
        return LanguageDefinition(
            identifier: "bash",
            fileExtensions: ["sh", "bash", "zsh"],
            rules: [
                // Shebang (line-start only, via `^`).
                LanguageRule(pattern: #"^#!.*"#, kind: .type),
                // Comment.
                LanguageRule(pattern: #"#.*"#, kind: .comment),
                // Strings.
                LanguageRule(pattern: #""(?:[^"\\]|\\.)*""#, kind: .string),
                LanguageRule(pattern: #"'[^']*'"#, kind: .string),
                // Variable expansion.
                LanguageRule(pattern: #"\$\{[^}]*\}"#, kind: .property),
                LanguageRule(pattern: #"\$\w+"#, kind: .property),
                // Keywords.
                LanguageRule(pattern: "\\b(?:\(keywords.joined(separator: "|")))\\b", kind: .keyword),
                // Numbers.
                LanguageRule(pattern: #"(?<![\w.])\d+(?:\.\d+)?"#, kind: .number),
            ],
            keywords: keywords
        )
    }
}
