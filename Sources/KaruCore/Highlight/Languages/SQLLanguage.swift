import Foundation

/// SQL definition.
///
/// Comments and strings come from `lexicalProfile` (M17 T17.3): `--` line
/// comments, non-nesting `/* … */` block comments, and `'…'` strings that
/// span lines with the doubled `''` escape and no backslash escapes. Quoted
/// identifiers `"…"` and MySQL back-quoted names are coloured as strings the
/// same way (as VS Code's SQL grammar does). PostgreSQL dollar quoting
/// (`$$…$$`) is not modelled: VS Code treats a function body there as code
/// too.
///
/// The regex rules cover the rest in code segments:
/// - Keywords are matched case-insensitively (`(?i)`), matching real-world
///   SQL where `select` / `SELECT` / `Select` are all valid; identifiers
///   that happen to collide with a keyword spelling are still coloured as
///   keywords (no symbol-table awareness).
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
        "WHEN", "THEN", "ELSE", "END", "CAST", "IF", "RETURNS", "RETURN",
        "BEGIN", "COMMIT", "ROLLBACK", "WITH", "RECURSIVE", "ASC", "DESC",
        // Types (`storage.type`, the keyword colour).
        "INT", "INTEGER", "BIGINT", "SMALLINT", "TINYINT", "DECIMAL", "NUMERIC",
        "REAL", "FLOAT", "DOUBLE", "PRECISION", "CHAR", "VARCHAR", "TEXT",
        "BOOLEAN", "BOOL", "DATE", "TIME", "TIMESTAMP", "INTERVAL", "BLOB",
        "SERIAL", "BIGSERIAL", "UUID", "JSON", "JSONB",
    ]

    /// Aggregate functions (`support.function.aggregate`).
    static let functions: [String] = ["COUNT", "SUM", "AVG", "MIN", "MAX"]

    /// Comments, strings and quoted identifiers.
    public static let lexicalProfile = LexicalProfile(
        lineComments: ["--"],
        blockComments: [.init(open: "/*", close: "*/")],
        strings: [
            .init(delimiter: .fixed(open: "'", close: "'"), multiline: true, escape: nil, doubledCloseEscapes: true),
            .init(delimiter: .fixed(open: "\"", close: "\""), multiline: true, escape: nil, doubledCloseEscapes: true),
            .init(delimiter: .fixed(open: "`", close: "`"), multiline: true, escape: nil, doubledCloseEscapes: true),
        ]
    )

    public static func make() -> LanguageDefinition {
        buildCount += 1
        return LanguageDefinition(
            identifier: "sql",
            fileExtensions: ["sql"],
            rules: [
                // Aggregate functions, then keywords, case-insensitive.
                LanguageRule(pattern: "(?i)\\b(?:\(functions.joined(separator: "|")))\\b(?=\\s*\\()",
                             kind: .builtin),
                LanguageRule(pattern: "(?i)\\b(?:\(keywords.joined(separator: "|")))\\b", kind: .keyword),
                // Numbers.
                LanguageRule(
                    pattern: #"(?<![\w.])(?:\d+\.\d*|\.\d+|\d+)"#,
                    kind: .number
                ),
            ],
            keywords: keywords + functions,
            lexicalProfile: lexicalProfile
        )
    }
}
