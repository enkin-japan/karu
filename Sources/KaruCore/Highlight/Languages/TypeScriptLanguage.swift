import Foundation

/// TypeScript definition.
///
/// Built on top of `JavaScriptLanguage`: it reuses JS's lexical profile,
/// number rule and full keyword set, adding the TypeScript-only keywords and
/// the built-in primitive type names. Primitive types (`string`, `number`,
/// `boolean`, …) are classified as `.type`; declaration/modifier words
/// (`interface`, `readonly`, `public`, …) as `.keyword`.
///
/// Shares JavaScript's `lexicalProfile` (cross-line block comments, template
/// literals with `${…}`; regex literals not yet highlighted). Only the `.ts`
/// extension is registered — JSX (`.tsx`) is out of scope for v1, so its
/// angle-bracket syntax is not handled.
public enum TypeScriptLanguage {
    /// See `JSONLanguage.buildCount`.
    nonisolated(unsafe) public static var buildCount = 0

    /// TypeScript-only declaration / modifier keywords (added to JS's set).
    static let extraKeywords: [String] = [
        "interface", "type", "enum", "namespace", "declare", "readonly",
        "keyof", "infer", "as", "satisfies", "implements", "private", "public",
        "protected", "abstract",
    ]

    /// Built-in primitive type names, coloured as types.
    static let typeNames: [String] = [
        "never", "unknown", "any", "string", "number", "boolean", "symbol",
        "object",
    ]

    /// TypeScript-only utility types, added to JS's built-in set.
    static let extraBuiltins: [String] = [
        "Partial", "Required", "Readonly", "Record", "Pick", "Omit",
        "Exclude", "Extract", "NonNullable", "ReturnType", "Parameters",
        "Awaited",
    ]

    public static func make() -> LanguageDefinition {
        buildCount += 1
        let keywords = JavaScriptLanguage.keywords + extraKeywords
        let builtins = JavaScriptLanguage.builtins + extraBuiltins
        return LanguageDefinition(
            identifier: "typescript",
            fileExtensions: ["ts"],
            rules: JavaScriptLanguage.baseRules() + [
                // Types before keywords (disjoint word sets, but keep types
                // visible as `.type`).
                JavaScriptLanguage.wordRule(typeNames, kind: .type),
                JavaScriptLanguage.wordRule(keywords, kind: .keyword),
                // Built-in globals / utility types last (disjoint from the
                // above); rules only run in code segments.
                JavaScriptLanguage.wordRule(builtins, kind: .builtin),
            ],
            keywords: keywords + typeNames,
            builtins: builtins,
            lexicalProfile: JavaScriptLanguage.lexicalProfile
        )
    }
}
