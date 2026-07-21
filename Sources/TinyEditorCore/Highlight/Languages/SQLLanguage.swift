import Foundation

/// SQL definition (v1, line-based).
///
/// Line-approximation trade-offs accepted for v1:
/// - `--` line comments are exact; `/* … */` block comments are
///   approximated: complete-on-line is coloured exactly, an opening line
///   colours to end-of-line, and interior/closing lines of a multi-line
///   block comment are not tracked (no cross-line state).
/// - Keywords are matched case-insensitively (`(?i)`), matching real-world
///   SQL where `select` / `SELECT` / `Select` are all valid; identifiers
///   that happen to collide with a keyword spelling are still coloured as
///   keywords (no symbol-table awareness).
/// - String literals use the standard SQL `''` escape for an embedded quote;
///   dialect-specific quoting (backtick identifiers, `$$`-quoted bodies,
///   etc.) is out of scope for v1.
public enum SQLLanguage {
    /// See `JSONLanguage.buildCount`.
    nonisolated(unsafe) public static var buildCount = 0

    static let keywords: [String] = [
        "SELECT", "FROM", "WHERE", "AND", "OR", "NOT", "NULL", "IS", "IN",
        "LIKE", "BETWEEN", "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "FULL",
        "CROSS", "ON", "AS", "ORDER", "BY", "GROUP", "HAVING", "LIMIT",
        "OFFSET", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE",
        "CREATE", "TABLE", "INDEX", "VIEW", "DROP", "ALTER", "ADD", "COLUMN",
        "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "UNIQUE", "DEFAULT",
        "CHECK", "CONSTRAINT", "DISTINCT", "UNION", "ALL", "EXISTS", "CASE",
        "WHEN", "THEN", "ELSE", "END", "CAST", "COUNT", "SUM", "AVG", "MIN",
        "MAX",
    ]

    public static func make() -> LanguageDefinition {
        buildCount += 1
        return LanguageDefinition(
            identifier: "sql",
            fileExtensions: ["sql"],
            rules: [
                // Line comment.
                LanguageRule(pattern: #"--.*"#, kind: .comment),
                // Block comment: complete-on-line, then open-to-end-of-line.
                LanguageRule(pattern: #"/\*.*?\*/"#, kind: .comment),
                LanguageRule(pattern: #"/\*.*"#, kind: .comment),
                // String (`''` is the escape for an embedded quote).
                LanguageRule(pattern: #"'(?:[^']|'')*'"#, kind: .string),
                // Keywords, case-insensitive.
                LanguageRule(pattern: "(?i)\\b(?:\(keywords.joined(separator: "|")))\\b", kind: .keyword),
                // Numbers.
                LanguageRule(
                    pattern: #"(?<![\w.])(?:\d+\.\d*|\.\d+|\d+)"#,
                    kind: .number
                ),
            ],
            keywords: keywords
        )
    }
}
