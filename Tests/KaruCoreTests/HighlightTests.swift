import AppKit
import Foundation
import Testing
@testable import KaruCore

// MARK: - Helpers

private func isolatedDefaults() -> UserDefaults {
    let name = "HighlightTests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

/// Tokenizes `line` and returns `(text, kind)` pairs for readable assertions.
private func spans(_ def: LanguageDefinition, _ line: String) -> [(text: String, kind: TokenKind)] {
    let ns = line as NSString
    return def.tokenize(line: line).map { (ns.substring(with: $0.range), $0.kind) }
}

/// Kind assigned to the first token whose text equals `text`, or nil.
private func kind(of text: String, in pairs: [(text: String, kind: TokenKind)]) -> TokenKind? {
    pairs.first { $0.text == text }?.kind
}

// MARK: - JSON tokenizer classification

@Test func jsonClassifiesKeysValuesNumbersLiteralsPunctuation() {
    let json = JSONLanguage.make()
    let pairs = spans(json, #"{"name": "x", "n": 1.5e2, "ok": true}"#)

    // Key strings (followed by a colon) are properties; value strings are strings.
    #expect(kind(of: #""name""#, in: pairs) == .property)
    #expect(kind(of: #""n""#, in: pairs) == .property)
    #expect(kind(of: #""ok""#, in: pairs) == .property)
    #expect(kind(of: #""x""#, in: pairs) == .string)

    // Number, literal, punctuation.
    #expect(kind(of: "1.5e2", in: pairs) == .number)
    #expect(kind(of: "true", in: pairs) == .keyword)
    #expect(kind(of: "{", in: pairs) == .punctuation)
    #expect(kind(of: ":", in: pairs) == .punctuation)
    #expect(kind(of: ",", in: pairs) == .punctuation)
    #expect(kind(of: "}", in: pairs) == .punctuation)
}

@Test func jsonClassifiesNegativeAndFractionalNumbers() {
    let json = JSONLanguage.make()
    let pairs = spans(json, #"[-0.5, 42, 1E-3, false, null]"#)
    #expect(kind(of: "-0.5", in: pairs) == .number)
    #expect(kind(of: "42", in: pairs) == .number)
    #expect(kind(of: "1E-3", in: pairs) == .number)
    #expect(kind(of: "false", in: pairs) == .keyword)
    #expect(kind(of: "null", in: pairs) == .keyword)
    #expect(kind(of: "[", in: pairs) == .punctuation)
    #expect(kind(of: "]", in: pairs) == .punctuation)
}

@Test func jsonEscapedQuotesStayInsideStringToken() {
    let json = JSONLanguage.make()
    // A value string containing an escaped quote must be one token.
    let pairs = spans(json, #"{"k": "a\"b"}"#)
    #expect(kind(of: #""k""#, in: pairs) == .property)
    #expect(kind(of: #""a\"b""#, in: pairs) == .string)
}

@Test func tokenizerLeavesWhitespaceUntokenized() {
    let json = JSONLanguage.make()
    let tokens = json.tokenize(line: "  {")
    // Leading spaces produce no token; only the brace is classified.
    #expect(tokens.count == 1)
    #expect(tokens.first?.kind == .punctuation)
    #expect(tokens.first?.range == NSRange(location: 2, length: 1))
}

// MARK: - Built-in identifier colouring (T10.2)

@Test func pythonBuiltinFunctionsAreColouredAsBuiltin() {
    let py = PythonLanguage.make()
    let pairs = spans(py, "print(len(items))")
    #expect(kind(of: "print", in: pairs) == .builtin)
    #expect(kind(of: "len", in: pairs) == .builtin)
    // A user identifier that is not a built-in stays untokenized (plain).
    #expect(kind(of: "items", in: pairs) == nil)
}

@Test func pythonBuiltinDoesNotOverrideKeywordOrSelf() {
    let py = PythonLanguage.make()
    // `open` is a built-in, `for`/`in` keywords, `self` a property — each keeps
    // its own classification (built-in rule runs after keyword and self/cls).
    let pairs = spans(py, "for self in open(path): return type(self)")
    #expect(kind(of: "for", in: pairs) == .keyword)
    #expect(kind(of: "in", in: pairs) == .keyword)
    #expect(kind(of: "return", in: pairs) == .keyword)
    #expect(kind(of: "self", in: pairs) == .property)
    #expect(kind(of: "open", in: pairs) == .builtin)
    #expect(kind(of: "type", in: pairs) == .builtin)
}

@Test func builtinsInsideStringsAndCommentsAreNotColoured() {
    let py = PythonLanguage.make()
    let pairs = spans(py, #"x = "print len open"  # print open len"#)
    // The quoted text and the comment are single tokens; no built-in token is
    // emitted for the built-in words that live inside them.
    #expect(kind(of: #""print len open""#, in: pairs) == .string)
    #expect(kind(of: "# print open len", in: pairs) == .comment)
    #expect(pairs.contains { $0.kind == .builtin } == false)
}

@Test func javascriptBuiltinGlobalsAreColoured() {
    let js = JavaScriptLanguage.make()
    let pairs = spans(js, "console.log(Math.max(a, b));")
    #expect(kind(of: "console", in: pairs) == .builtin)
    #expect(kind(of: "Math", in: pairs) == .builtin)
    // `log`/`max` are member names, not top-level built-ins → untokenized.
    #expect(kind(of: "log", in: pairs) == nil)
}

@Test func typescriptInheritsJavaScriptBuiltins() {
    let ts = TypeScriptLanguage.make()
    let pairs = spans(ts, "const p: Promise<number> = fetch(url);")
    #expect(kind(of: "Promise", in: pairs) == .builtin)
    #expect(kind(of: "fetch", in: pairs) == .builtin)
    #expect(kind(of: "number", in: pairs) == .type)   // primitive type still wins
    #expect(kind(of: "const", in: pairs) == .keyword)
}

@Test func cBuiltinLibraryFunctionsAreColoured() {
    let c = CLanguage.make()
    let pairs = spans(c, #"printf("%d", strlen(s));"#)
    #expect(kind(of: "printf", in: pairs) == .builtin)
    #expect(kind(of: "strlen", in: pairs) == .builtin)
}

@Test func cppInheritsCBuiltinsAndAddsStdLib() {
    let cpp = CppLanguage.make()
    let pairs = spans(cpp, "std::cout << printf();")
    #expect(kind(of: "std", in: pairs) == .builtin)
    #expect(kind(of: "cout", in: pairs) == .builtin)
    #expect(kind(of: "printf", in: pairs) == .builtin)   // inherited from C
    #expect(kind(of: "::", in: pairs) == .punctuation)
}

@Test func csharpJavaAndBashBuiltinsAreColoured() {
    let cs = CSharpLanguage.make()
    #expect(kind(of: "Console", in: spans(cs, "Console.WriteLine(x);")) == .builtin)

    let java = JavaLanguage.make()
    #expect(kind(of: "System", in: spans(java, "System.out.println(x);")) == .builtin)

    let bash = BashLanguage.make()
    let pairs = spans(bash, "echo hi | grep x")
    #expect(kind(of: "echo", in: pairs) == .builtin)
    #expect(kind(of: "grep", in: pairs) == .builtin)
}

// MARK: - Theme: Dark/Light Modern palette + dynamic appearance

@Test func themeBuiltinSharesFunctionColour() {
    let theme = HighlightTheme()
    #expect(theme.color(for: .builtin) === theme.color(for: .symbolFunction))
    #expect(theme.color(for: .property) === theme.color(for: .symbolVariable))
    #expect(theme.color(for: .plain) == nil)
    // The syntax kinds all resolve to a colour.
    for k in [TokenKind.keyword, .string, .number, .comment, .type, .builtin] {
        #expect(theme.color(for: k) != nil)
    }
}

@Test func themeColoursFlipBetweenLightAndDarkAppearance() {
    let theme = HighlightTheme()
    let dark = NSAppearance(named: .darkAqua)!
    let light = NSAppearance(named: .aqua)!

    func resolve(_ kind: TokenKind, _ appearance: NSAppearance) -> NSColor? {
        var out: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            out = theme.color(for: kind)?.usingColorSpace(.sRGB)
        }
        return out
    }

    // Keyword blue differs: Dark Modern #569CD6 vs Light Modern #0000FF.
    let darkKeyword = resolve(.keyword, dark)
    let lightKeyword = resolve(.keyword, light)
    #expect(darkKeyword != nil && lightKeyword != nil)
    #expect(darkKeyword != lightKeyword)

    // The Dark Modern keyword resolves close to #569CD6.
    #expect(abs((darkKeyword?.redComponent ?? 0) - 0x56 / 255.0) < 0.02)
    #expect(abs((darkKeyword?.greenComponent ?? 0) - 0x9C / 255.0) < 0.02)
    #expect(abs((darkKeyword?.blueComponent ?? 0) - 0xD6 / 255.0) < 0.02)
}

// MARK: - Registry lookup

@Test func registryResolvesJSONCaseInsensitively() {
    #expect(LanguageRegistry.definition(forExtension: "json")?.identifier == "json")
    #expect(LanguageRegistry.definition(forExtension: "JSON")?.identifier == "json")
}

@Test func registryReturnsNilForUnknownExtension() {
    #expect(LanguageRegistry.definition(forExtension: "txt") == nil)
    #expect(LanguageRegistry.definition(forExtension: "") == nil)
}

// MARK: - Lazy loading

@Test func supportedExtensionsDoesNotBuildDefinitions() {
    // Listing supported extensions must not invoke any language factory.
    let before = JSONLanguage.buildCount
    #expect(LanguageRegistry.supportedExtensions.contains("json"))
    #expect(JSONLanguage.buildCount == before)
}

@Test func unknownExtensionNeverBuildsJSON() {
    // Resolving an unregistered extension must not build JSON.
    let before = JSONLanguage.buildCount
    _ = LanguageRegistry.definition(forExtension: "nope")
    #expect(JSONLanguage.buildCount == before)
}

@Test func factoryClosureIsNotInvokedUntilCalled() {
    // Demonstrates the lazy pattern directly: holding the factory does nothing.
    var built = false
    let factory: () -> LanguageDefinition = {
        built = true
        return JSONLanguage.make()
    }
    #expect(built == false)
    _ = factory()
    #expect(built == true)
}

// MARK: - Module gating / released state

@MainActor
@Test func disablingModuleReleasesLanguageState() {
    // Route module notifications through a private center so this test does not
    // perturb suites observing `NotificationCenter.default`.
    let center = NotificationCenter()
    let defaults = isolatedDefaults()
    let settings = ModuleSettings(defaults: defaults, center: center)

    let scrollView = NSScrollView()
    let textView = EditorTextView()
    scrollView.documentView = textView

    let engine = HighlightEngine(textView: textView,
                                 scrollView: scrollView,
                                 moduleSettings: settings,
                                 moduleCenter: center)
    engine.setLanguage(fileExtension: "json")

    // Enabled + language resolved → runtime state held.
    #expect(engine.isModuleEnabled)
    #expect(engine.isRuntimeStateReleased == false)

    // Disabling the module must release language state.
    settings.setEnabled(false, for: .highlight)
    #expect(engine.isModuleEnabled == false)
    #expect(engine.isRuntimeStateReleased)

    // Re-enabling rebuilds it from the remembered extension.
    settings.setEnabled(true, for: .highlight)
    #expect(engine.isModuleEnabled)
    #expect(engine.isRuntimeStateReleased == false)
}

@MainActor
@Test func engineStartsDisabledWhenModuleOff() {
    let center = NotificationCenter()
    let defaults = isolatedDefaults()
    let settings = ModuleSettings(defaults: defaults, center: center)
    settings.setEnabled(false, for: .highlight)

    let scrollView = NSScrollView()
    let textView = EditorTextView()
    scrollView.documentView = textView

    let engine = HighlightEngine(textView: textView,
                                 scrollView: scrollView,
                                 moduleSettings: settings,
                                 moduleCenter: center)
    engine.setLanguage(fileExtension: "json")

    // Module off from the start: no runtime state despite a known language.
    #expect(engine.isModuleEnabled == false)
    #expect(engine.isRuntimeStateReleased)
}

// MARK: - Anchored-search boundary regressions (T10.2 review)

/// `\b` in a rule must respect the character *before* the match position: the
/// tokenizer advances through unmatched identifiers one character at a time, and
/// without transparent bounds the search-range start acted as a fake word
/// boundary — colouring the `in` inside `main`, the `print` inside `sprint`,
/// and the `1` inside `x1`.
@Test func keywordDoesNotMatchInsideIdentifier() {
    let def = LanguageRegistry.definition(forIdentifier: "python")!
    for line in ["def main(argv):", "def maintain(x):"] {
        let ns = line as NSString
        for token in def.tokenize(line: line) where token.kind == .keyword {
            #expect(ns.substring(with: token.range) == "def",
                    "unexpected keyword token in \(line)")
        }
    }
}

@Test func builtinDoesNotMatchInsideIdentifier() {
    let def = LanguageRegistry.definition(forIdentifier: "python")!
    let tokens = def.tokenize(line: "sprints = 3")
    #expect(!tokens.contains { $0.kind == .builtin })
}

@Test func numberDoesNotMatchInsideIdentifier() {
    let def = LanguageRegistry.definition(forIdentifier: "python")!
    let tokens = def.tokenize(line: "x1 = y")
    #expect(!tokens.contains { $0.kind == .number })
}
