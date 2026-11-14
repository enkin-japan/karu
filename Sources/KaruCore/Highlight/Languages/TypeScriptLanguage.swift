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
/// literals with `${…}`, regex literals as atoms). Only the `.ts`
/// extension is registered — JSX (`.tsx`) is out of scope for v1, so its
/// angle-bracket syntax is not handled.
public enum TypeScriptLanguage {
    /// See `JSONLanguage.buildCount`.
    nonisolated(unsafe) public static var buildCount = 0

    /// TypeScript-only declaration / modifier keywords (added to JS's set;
    /// `as` is a control keyword in both).
    static let extraKeywords: [String] = [
        "interface", "type", "enum", "namespace", "declare", "readonly",
        "keyof", "infer", "satisfies", "implements", "private", "public",
        "protected", "abstract", "is", "override",
    ]

    /// Built-in primitive type names, coloured as types (`void` too: VS Code
    /// scopes it `support.type.primitive` in TypeScript).
    static let typeNames: [String] = [
        "never", "unknown", "any", "string", "number", "boolean", "symbol",
        "object", "bigint", "void",
    ]

    /// TypeScript-only utility types, added to JS's built-in classes.
    static let extraBuiltins: [String] = [
        "Partial", "Required", "Readonly", "Record", "Pick", "Omit",
        "Exclude", "Extract", "NonNullable", "ReturnType", "Parameters",
        "Awaited", "Capitalize", "Uncapitalize", "Uppercase", "Lowercase",
        "InstanceType", "ConstructorParameters",
    ]

    public static func make() -> LanguageDefinition {
        buildCount += 1
        let otherKeywords = JavaScriptLanguage.otherKeywords.filter { $0 != "void" } + extraKeywords
        let keywords = JavaScriptLanguage.controlKeywords + otherKeywords
        let builtins = JavaScriptLanguage.builtins + extraBuiltins
        return LanguageDefinition(
            identifier: "typescript",
            fileExtensions: ["ts"],
            rules: JavaScriptLanguage.rules(controls: JavaScriptLanguage.controlKeywords, keywords: otherKeywords,
                                            typeWords: typeNames,
                                            builtinTypes: JavaScriptLanguage.builtinTypes + extraBuiltins,
                                            builtinFunctions: JavaScriptLanguage.builtinFunctions),
            keywords: keywords + typeNames,
            builtins: builtins,
            lexicalProfile: JavaScriptLanguage.lexicalProfile,
            identifierPolicy: JavaScriptLanguage.identifierPolicy
        )
    }
}
