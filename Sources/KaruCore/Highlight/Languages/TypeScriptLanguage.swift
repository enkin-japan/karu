import Foundation

/// TypeScript definition.
///
/// Built on top of `JavaScriptLanguage`: it reuses JS's lexical profile,
/// number rule and full keyword set, adding the TypeScript-only keywords and
/// the built-in primitive type names. Primitive types (`string`, `number`,
/// `boolean`, …) are classified as `.type`; declaration/modifier words
/// (`interface`, `readonly`, `public`, …) as `.keyword`.
///
/// Shares JavaScript's comments, strings, template literals with `${…}` and
/// regex literals, **without JSX** (`lexicalProfile`): in `.ts`, `<T>x` is a
/// type assertion and `<T>(x: T) => x` a generic arrow. `.tsx` files are
/// TypeScript JSX (`TypeScriptReactLanguage`, identifier `typescriptreact`):
/// the same rules with JSX on.
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

    /// JavaScript's comments, strings and regex literals; no JSX.
    public static let lexicalProfile = JavaScriptLanguage.baseProfile

    /// The rule set, keywords and built-ins of TypeScript, for `identifier`
    /// and `extensions` (shared with TypeScript JSX).
    static func definition(identifier: String, fileExtensions: [String],
                           lexicalProfile: LexicalProfile) -> LanguageDefinition {
        let otherKeywords = JavaScriptLanguage.otherKeywords.filter { $0 != "void" } + extraKeywords
        let keywords = JavaScriptLanguage.controlKeywords + otherKeywords
        let builtins = JavaScriptLanguage.builtins + extraBuiltins
        return LanguageDefinition(
            identifier: identifier,
            fileExtensions: fileExtensions,
            rules: JavaScriptLanguage.rules(controls: JavaScriptLanguage.controlKeywords, keywords: otherKeywords,
                                            typeWords: typeNames,
                                            builtinTypes: JavaScriptLanguage.builtinTypes + extraBuiltins,
                                            builtinFunctions: JavaScriptLanguage.builtinFunctions),
            keywords: keywords + typeNames,
            builtins: builtins,
            lexicalProfile: lexicalProfile,
            identifierPolicy: JavaScriptLanguage.identifierPolicy
        )
    }

    public static func make() -> LanguageDefinition {
        buildCount += 1
        return definition(identifier: "typescript", fileExtensions: ["ts"], lexicalProfile: lexicalProfile)
    }
}
