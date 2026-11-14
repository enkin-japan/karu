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
/// Categories (T17.7, VS Code's shell grammar): control-flow keywords
/// (`if`, `do`, `case`, …) apart from declaration keywords (`local`,
/// `export`); the command word of a simple command a function (also a
/// function declaration's name); options (`-x`, `--long`) keywords; other
/// bare words arguments (strings); assignment names, `for` variables,
/// `$name` / `${name}` (also inside double quotes) variables; `$(`, `${` and
/// their closers inside a string keep the string colour.
///
/// Compromises (plan §4 "什么时候妥协"): only the first heredoc of a line is
/// tracked (`cat <<A <<B`); an unquoted heredoc body is not interpolated
/// (VS Code colours `$var` / `$(…)` inside it); `x<<y` in arithmetic reads
/// as a heredoc opener; top-level `` `…` `` and `$(…)` are plain code.
public enum BashLanguage {
    /// See `JSONLanguage.buildCount`.
    nonisolated(unsafe) public static var buildCount = 0

    /// Control-flow keywords (`keyword.control`).
    static let controlKeywords: [String] = [
        "if", "then", "else", "elif", "fi", "for", "while", "do", "done",
        "case", "esac", "in", "select", "until", "return", "break", "continue",
    ]

    /// Declaration keywords (`storage.type`, `storage.modifier`).
    static let otherKeywords: [String] = [
        "function", "local", "export", "readonly", "declare", "typeset", "alias",
    ]

    static let keywords: [String] = controlKeywords + otherKeywords + [
        "exit", "source", "set", "unset", "shift", "trap",
    ]

    /// A word in command position — at a line start, after `;` `&` `|` `(`
    /// `` ` `` or after `then` / `do` / `else` — that is not a keyword, an
    /// assignment or a `case` pattern (`macos-*)`): the command name
    /// (`entity.name.command`, the function colour). Also a function
    /// declaration's name (`usage() {`). Leading blanks are part of the token.
    static let commandRule = LanguageRule(
        pattern: #"(?:(?<=^)|(?<=[;&|`])|(?<=(?:^|[^=])\()|(?<=\b(?:then|do|else|time|exec)[ \t]))[ \t]*(?!(?:if|then|else|elif|fi|for|while|until|do|done|case|esac|in|select|function|break|continue|return|local|export|readonly|declare|typeset|alias)\b)(?![A-Z_][A-Z0-9_]*[ \t]*$)[A-Za-z_./][\w./-]*(?![\w./-]*(?:\+?=|[*?|)]|\[))"#,
        kind: .symbolFunction)

    /// A `for` loop's variable.
    static let forVariableRule = LanguageRule(
        pattern: #"(?<=\bfor[ \t]{1,8})[A-Za-z_]\w*"#, kind: .symbolVariable)

    /// Any other bare word after a blank (or an array's `(`): a command
    /// argument, which VS Code scopes `string.unquoted.argument`. Not a
    /// redirection's file descriptor (`2>`), not an all-caps word alone on
    /// its line (a `<<-` heredoc terminator), and only words with a letter,
    /// digit, `/` or `.` (no operators such as `==`).
    static let argumentRule = LanguageRule(
        pattern: #"(?<=[ \t(])(?!\d+[<>])(?![A-Z_][A-Z0-9_]*[ \t]*$(?<=^[ \t]{1,64}[A-Z_][A-Z0-9_]{0,63}[ \t]{0,8}))(?=[^\s;|&()<>"'`$#\\=]*[\w/.])[^\s;|&()<>"'`$#\\=]+"#,
        kind: .string)

    /// The name `function` declares.
    static let functionNameRule = LanguageRule(
        pattern: #"(?<=\bfunction[ \t]{1,8})[A-Za-z_][\w.-]*"#, kind: .symbolFunction)

    /// An assignment's name (`NAME=`, `local x=1`, `a+=b`): `variable.other`.
    static let assignmentRule = LanguageRule(
        pattern: #"(?<!\w)(?=[A-Za-z_]\w*\+?=)(?:(?<=^)|(?<=^[ \t]{1,64})|(?<=[;&|(][ \t]{0,8})|(?<=\b(?:local|export|readonly|declare|typeset)[ \t]{1,8}(?:-[A-Za-z]{1,4}[ \t]{1,4})?))[A-Za-z_]\w*"#,
        kind: .symbolVariable)

    /// A command option (`-euo`, `--tags`): `constant.other.option`, the
    /// keyword colour.
    static let optionRule = LanguageRule(pattern: #"(?<=[ \t])--?[A-Za-z][\w-]*"#, kind: .keyword)

    static let builtins: [String] = [
        "echo", "printf", "read", "cd", "ls", "cp", "mv", "rm", "mkdir",
        "rmdir", "touch", "cat", "grep", "sed", "awk", "cut", "sort",
        "uniq", "head", "tail", "wc", "find", "xargs", "chmod", "chown",
        "curl", "wget", "tar", "gzip", "date", "sleep", "kill", "ps",
        "env", "dirname", "basename", "pwd", "which", "test", "true",
        "false", "exit", "source", "set", "unset", "shift", "trap", "eval",
        "exec", "wait",
    ]

    /// Comments, strings, interpolations and heredocs (see the type comment).
    public static let lexicalProfile = LexicalProfile(
        lineComments: ["#"],
        lineCommentPrecededBy: " \t;|&()",
        strings: [
            .init(prefixes: ["$"], prefixRequired: true, delimiter: .fixed(open: "'", close: "'"), multiline: true),
            .init(delimiter: .fixed(open: "'", close: "'"), multiline: true, escape: nil),
            .init(delimiter: .fixed(open: "\"", close: "\""), multiline: true, variablePrefix: "$",
                  interpolations: [.init(open: "$(", close: ")"), .init(open: "${", close: "}"),
                                   .init(open: "`", close: "`")]),
        ],
        lineBlocks: [.heredoc(bodyKind: .string)],
        // `argumentRule` is a `.string` rule in code.
        keepsStringRules: true,
        // `$(`, `${`, `` ` `` and their closers keep the string colour (VS
        // Code's shell grammar scopes them inside the string).
        interpolationDelimiterKind: .string
    )

    public static func make() -> LanguageDefinition {
        buildCount += 1
        return LanguageDefinition(
            identifier: "bash",
            fileExtensions: ["sh", "bash", "zsh"],
            rules: [
                // Variable expansion: the name only (`${#x[@]}`: `x`), and
                // `$name` / `$1` / `$@` whole.
                LanguageRule(pattern: #"(?<=\$\{[#!]?)[A-Za-z_]\w*"#, kind: .symbolVariable),
                LanguageRule(pattern: #"\$(?:[A-Za-z_]\w*|[0-9@#?*$!-])"#, kind: .symbolVariable),
                assignmentRule,
                // Keywords.
                SyntaxRules.words(controlKeywords, .controlKeyword),
                SyntaxRules.words(otherKeywords, .keyword),
                functionNameRule,
                forVariableRule,
                commandRule,
                optionRule,
                // Common commands / builtins elsewhere (rules only run in code
                // segments, and `$…` expansions are consumed earlier, so a
                // command word inside a string, comment or heredoc is never
                // reached here).
                LanguageRule(pattern: "\\b(?:\(builtins.joined(separator: "|")))\\b", kind: .builtin),
                // Numbers.
                LanguageRule(pattern: #"(?<![\w.])\d+(?:\.\d+)?"#, kind: .number),
                argumentRule,
            ],
            keywords: keywords,
            builtins: builtins,
            lexicalProfile: lexicalProfile
        )
    }
}
