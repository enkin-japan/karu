import Foundation

/// Bash/zsh shell script definition.
///
/// Comments, strings and heredocs come from `lexicalProfile` (M17 T17.3):
/// - `#` starts a comment only at a line start or after a blank or one of
///   `;|&()` (`lineCommentPrecededBy`), so `$#`, `${#x}` and `a#b` stay code;
///   a shebang is a comment, as in VS Code.
/// - `'…'` is raw and may span lines; `$'…'` has `\` escapes; `"…"` spans
///   lines with `\` escapes and `$(…)`, `${…}` and `` `…` `` interpolations
///   scanned as code (nested quotes inside included: `"$(echo ")")"`).
/// - Heredocs (`<<EOF`, `<<-EOF` with tab-stripped terminator, `<<'EOF'`,
///   `<<"EOF"`, `<<\EOF`; `<<<` is a here-string): the body is one string
///   token, the opener and terminator lines stay code (VS Code leaves them
///   uncoloured).
///
/// Compromises (plan §4 "什么时候妥协"): only the first heredoc of a line is
/// tracked (`cat <<A <<B`); an unquoted heredoc body is not interpolated
/// (VS Code colours `$var` / `$(…)` inside it); `x<<y` in arithmetic reads
/// as a heredoc opener; top-level `` `…` `` and `$(…)` are plain code.
public enum BashLanguage {
    /// See `JSONLanguage.buildCount`.
    nonisolated(unsafe) public static var buildCount = 0

    static let keywords: [String] = [
        "if", "then", "else", "elif", "fi", "for", "while", "do", "done",
        "case", "esac", "function", "in", "select", "until", "return", "exit",
        "local", "export", "readonly", "declare", "source", "alias", "set",
        "unset", "shift", "trap",
    ]

    static let builtins: [String] = [
        "echo", "printf", "read", "cd", "ls", "cp", "mv", "rm", "mkdir",
        "rmdir", "touch", "cat", "grep", "sed", "awk", "cut", "sort",
        "uniq", "head", "tail", "wc", "find", "xargs", "chmod", "chown",
        "curl", "wget", "tar", "gzip", "date", "sleep", "kill", "ps",
        "env", "dirname", "basename", "pwd", "which", "test", "true",
        "false",
    ]

    /// Comments, strings, interpolations and heredocs (see the type comment).
    public static let lexicalProfile = LexicalProfile(
        lineComments: ["#"],
        lineCommentPrecededBy: " \t;|&()",
        strings: [
            .init(prefixes: ["$"], prefixRequired: true, delimiter: .fixed(open: "'", close: "'"), multiline: true),
            .init(delimiter: .fixed(open: "'", close: "'"), multiline: true, escape: nil),
            .init(delimiter: .fixed(open: "\"", close: "\""), multiline: true,
                  interpolations: [.init(open: "$(", close: ")"), .init(open: "${", close: "}"),
                                   .init(open: "`", close: "`")]),
        ],
        lineBlocks: [.heredoc(bodyKind: .string)]
    )

    public static func make() -> LanguageDefinition {
        buildCount += 1
        return LanguageDefinition(
            identifier: "bash",
            fileExtensions: ["sh", "bash", "zsh"],
            rules: [
                // Variable expansion.
                LanguageRule(pattern: #"\$\{[^}]*\}"#, kind: .property),
                LanguageRule(pattern: #"\$\w+"#, kind: .property),
                // Keywords.
                LanguageRule(pattern: "\\b(?:\(keywords.joined(separator: "|")))\\b", kind: .keyword),
                // Common commands / builtins after keywords; a word that is both
                // (e.g. `set`) already matched as a keyword. Rules only run in
                // code segments, and `$…` expansions are consumed earlier, so a
                // command word inside a string, comment or heredoc is never
                // reached here.
                LanguageRule(pattern: "\\b(?:\(builtins.joined(separator: "|")))\\b", kind: .builtin),
                // Numbers.
                LanguageRule(pattern: #"(?<![\w.])\d+(?:\.\d+)?"#, kind: .number),
            ],
            keywords: keywords,
            builtins: builtins,
            lexicalProfile: lexicalProfile
        )
    }
}
