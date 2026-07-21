import Foundation

/// TypeScript definition (v1, line-based).
///
/// Built on top of `JavaScriptLanguage`: it reuses JS's comment / string /
/// number rules and full keyword set, adding the TypeScript-only keywords and
/// the built-in primitive type names. Primitive types (`string`, `number`,
/// `boolean`, …) are classified as `.type`; declaration/modifier words
/// (`interface`, `readonly`, `public`, …) as `.keyword`.
///
/// Trade-offs: inherits every JS line-approximation (block comments, template
/// literals, no regex literals). Only the `.ts` extension is registered — JSX
/// (`.tsx`) is out of scope for v1, so its angle-bracket syntax is not handled.
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

    public static func make() -> LanguageDefinition {
        buildCount += 1
        let keywords = JavaScriptLanguage.keywords + extraKeywords
        return LanguageDefinition(
            identifier: "typescript",
            fileExtensions: ["ts"],
            rules: JavaScriptLanguage.baseRules() + [
                // Types before keywords (disjoint word sets, but keep types
                // visible as `.type`).
                JavaScriptLanguage.wordRule(typeNames, kind: .type),
                JavaScriptLanguage.wordRule(keywords, kind: .keyword),
            ],
            keywords: keywords + typeNames
        )
    }
}
