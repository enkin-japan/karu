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
