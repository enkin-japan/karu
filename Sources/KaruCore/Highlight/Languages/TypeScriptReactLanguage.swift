import Foundation

/// TypeScript JSX (`.tsx`, identifier `typescriptreact`, M17 T17.8b): the
/// TypeScript definition with JSX on (`LexicalProfile.JSXForm`, see
/// `JavaScriptLanguage`). In an expression position a type parameter list
/// stays code — `<T,>(x: T) => x`, `<T extends X>(…) =>`, `<T = X>`,
/// `<const T>` — as TypeScript requires in `.tsx`; `<T>(x) => x` there is
/// an element, as in TypeScript. A tag name may take type arguments
/// (`<Badge<string> …>`, identifiers coloured as types).
///
/// Approximation: the decision is text-only, so a generic function *type*
/// after `:` or `=` written without `,` / `extends` (`let f: <T>(x: T) => T`,
/// `type F = <T>(x: T) => T`) opens an element.
public enum TypeScriptReactLanguage {
    /// See `JSONLanguage.buildCount`.
    nonisolated(unsafe) public static var buildCount = 0

    /// TypeScript's profile with TSX's JSX.
    public static let lexicalProfile: LexicalProfile = {
        var profile = JavaScriptLanguage.baseProfile
        profile.jsx = LexicalProfile.JSXForm(context: JavaScriptLanguage.regexContext, typeScript: true)
        return profile
    }()

    public static func make() -> LanguageDefinition {
        buildCount += 1
        return TypeScriptLanguage.definition(identifier: "typescriptreact", fileExtensions: ["tsx"],
                                             lexicalProfile: lexicalProfile)
    }
}
