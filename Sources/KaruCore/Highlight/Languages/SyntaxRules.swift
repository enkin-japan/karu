import Foundation

/// Rule builders shared by the language definitions (M17 T17.7: syntax
/// categories by position, plan §6). Each mirrors a scope VS Code's grammars
/// assign by a cheap textual cue; which languages use which is decided per
/// language against the `Tests/Fixtures/M17/highlight` references (see the
/// language files). Rules run only in code segments, in list order, first
/// match wins at a position — so keyword rules go before the identifier
/// rules here.
enum SyntaxRules {
    /// `\b(?:w1|w2|…)\b` producing `kind`.
    static func words(_ words: [String], _ kind: TokenKind) -> LanguageRule {
        LanguageRule(pattern: "\\b(?:\(words.joined(separator: "|")))\\b", kind: kind)
    }

    /// Identifier pattern with or without `$` (JS / TS).
    private static func identifier(dollar: Bool) -> (head: String, guardBefore: String, body: String) {
        dollar ? ("[A-Za-z_$]", "(?<![\\w$])", "[\\w$]*") : ("[A-Za-z_]", "(?<!\\w)", "\\w*")
    }

    /// `name(` (optional blanks before the parenthesis): a call, coloured as
    /// a function (`entity.name.function` / `meta.function-call`). Must come
    /// after the keyword rules (`if (`, `return (`).
    static func call(dollar: Bool = false) -> LanguageRule {
        let id = identifier(dollar: dollar)
        return LanguageRule(pattern: "\(id.guardBefore)\(id.head)\(id.body)(?=[ \\t]*\\()", kind: .symbolFunction)
    }

    /// A name right after `.` (or `->` with `arrow`): a member access,
    /// `kind` (a property → `.symbolVariable`; Rust fields → `.plain`). A
    /// member call is caught first by `call`.
    static func member(_ kind: TokenKind, arrow: Bool = false, dollar: Bool = false) -> LanguageRule {
        let id = identifier(dollar: dollar)
        let before = arrow ? "(?<=\\.|->)" : "(?<=\\.)"
        return LanguageRule(pattern: "\(before)\(id.head)\(id.body)", kind: kind)
    }

    /// A name directly followed by `.name` (or `->name`): the object of a
    /// member access (`variable.other.object`), `.symbolVariable`.
    static func object(arrow: Bool = false, dollar: Bool = false) -> LanguageRule {
        let id = identifier(dollar: dollar)
        let after = arrow ? "(?=[ \\t]*(?:\\.|->)[ \\t]*[A-Za-z_$])" : "(?=[ \\t]*\\.[ \\t]*[A-Za-z_$])"
        return LanguageRule(pattern: "\(id.guardBefore)\(id.head)\(id.body)\(after)", kind: .symbolVariable)
    }

    /// An all-caps identifier of at least two units with a letter
    /// (`MAX_SIZE`, `A1`; not `HTTPServer`, not `T`): `kind` — `.constant`
    /// in JS / TS (`variable.other.constant`), `.plain` in Rust
    /// (`constant.other.caps`, uncoloured).
    static func upperSnake(_ kind: TokenKind, dollar: Bool = false) -> LanguageRule {
        let guardBefore = dollar ? "(?<![\\w$])" : "(?<!\\w)"
        let guardAfter = dollar ? "(?![\\w$])" : "(?!\\w)"
        return LanguageRule(pattern: "\(guardBefore)(?=[A-Z0-9_]*[A-Z])[A-Z_][A-Z0-9_]+\(guardAfter)", kind: kind)
    }

    /// A name directly followed by `::`: a path / scope qualifier
    /// (`entity.name.scope-resolution`, Rust paths), `.type`.
    static let scopeQualifier = LanguageRule(pattern: #"(?<!\w)[A-Za-z_]\w*(?=::)"#, kind: .type)

    /// A printf conversion inside a string (`%s`, `%-5.2f`, `%zu`; Go's
    /// `%v`, `%q`, `%w`, `%T`; `%%` not included): `constant.other.placeholder`,
    /// `.symbolVariable`.
    static let printfPlaceholder = LanguageRule(
        pattern: #"%(?:[-+ #0]{0,4}(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|h|ll|l|L|z|j|t|q)?[diouxXeEfFgGaAcspnqvwT])"#,
        kind: .symbolVariable)
}
