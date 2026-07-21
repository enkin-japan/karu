import AppKit
import Foundation
import Testing
@testable import TinyEditorCore

// MARK: - Helpers

private func isolatedDefaults() -> UserDefaults {
    let name = "CompletionTests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

// MARK: - WordIndex build / rebuild

@Test func wordIndexCollectsWordsOfLengthTwoOrMore() {
    let index = WordIndex(text: "let value = compute(x)")
    // `x` (length 1) is excluded; two-plus-letter words are kept, case preserved.
    #expect(index.words.contains("let"))
    #expect(index.words.contains("value"))
    #expect(index.words.contains("compute"))
    #expect(index.words.contains("x") == false)
}

@Test func wordIndexPreservesCaseAndDeduplicates() {
    let index = WordIndex(text: "Foo foo Foo FOO")
    #expect(index.words == ["Foo", "foo", "FOO"])
}

@Test func wordIndexUpdateFullyRebuilds() {
    var index = WordIndex(text: "alpha beta")
    #expect(index.words == ["alpha", "beta"])
    index.update(text: "gamma delta")
    // A rebuild replaces the set wholesale — old words are gone.
    #expect(index.words == ["gamma", "delta"])
    #expect(index.words.contains("alpha") == false)
}

@Test func wordIndexEmptyTextYieldsNoWords() {
    #expect(WordIndex(text: "").words.isEmpty)
}

// MARK: - Symbol scanning

@Test func pythonSymbolsExtractDefAndClassNames() {
    let source = """
    class Widget:
        def render(self):
            return compute()

    def helper(a, b):
        pass
    """
    let symbols = WordIndex.symbols(text: source, languageIdentifier: "python")
    #expect(symbols.contains("Widget"))
    #expect(symbols.contains("render"))
    #expect(symbols.contains("helper"))
    // `compute` is a call, not a Python declaration → not a symbol.
    #expect(symbols.contains("compute") == false)
}

@Test func javascriptSymbolsExtractFunctionClassAndBindings() {
    let source = """
    function greet(name) { return name; }
    class Panel {}
    const answer = 42;
    let counter = 0;
    var legacy = true;
    """
    let symbols = WordIndex.symbols(text: source, languageIdentifier: "javascript")
    #expect(symbols.contains("greet"))
    #expect(symbols.contains("Panel"))
    #expect(symbols.contains("answer"))
    #expect(symbols.contains("counter"))
    #expect(symbols.contains("legacy"))
}

@Test func cLikeSymbolsSkipControlKeywordCalls() {
    let source = """
    struct Point { int x; };
    int compute(int n) {
        if (n) return n;
        while (n) n--;
        return compute(n);
    }
    """
    let symbols = WordIndex.symbols(text: source, languageIdentifier: "c")
    #expect(symbols.contains("Point"))
    #expect(symbols.contains("compute"))
    // Control-flow words that look like calls must not be treated as symbols.
    #expect(symbols.contains("if") == false)
    #expect(symbols.contains("while") == false)
    #expect(symbols.contains("return") == false)
}

@Test func unsupportedLanguageHasNoSymbols() {
    #expect(WordIndex.symbols(text: "anything here", languageIdentifier: "markdown").isEmpty)
    #expect(WordIndex.symbols(text: "anything here", languageIdentifier: "").isEmpty)
}

// MARK: - Suggestions: prefix match, case, ordering, cap

@Test func suggestionsMatchPrefixCaseInsensitivelyPreservingCase() {
    let index = WordIndex(text: "Compute Computer compile Constant")
    let hits = index.suggestions(prefix: "comp", language: [], symbols: [])
    // Case-insensitive prefix match, original casing preserved in the result.
    #expect(hits.contains("Compute"))
    #expect(hits.contains("Computer"))
    #expect(hits.contains("compile"))
    // `Constant` does not start with "comp".
    #expect(hits.contains("Constant") == false)
}

@Test func suggestionsRankSymbolsThenKeywordsThenWords() {
    // Distinct spellings so each lands in exactly one group.
    let index = WordIndex(text: "foobar")            // document word
    let hits = index.suggestions(prefix: "fo",
                                 language: ["for"],   // keyword
                                 symbols: ["foo_sym"]) // symbol
    #expect(hits == ["foo_sym", "for", "foobar"])
}

@Test func suggestionsEmptyPrefixYieldsNothing() {
    // Empty prefix guards against a runaway full-list dump.
    let index = WordIndex(text: "banana apple Cherry")
    #expect(index.suggestions(prefix: "", language: [], symbols: []).isEmpty)
}

@Test func suggestionsSortDictionaryOrderWithinGroup() {
    // Mixed-case document words sharing the prefix "ba" come back in
    // case-insensitive dictionary order (Bard < basic < Batch).
    let index = WordIndex(text: "Batch basic Bard")
    let hits = index.suggestions(prefix: "ba", language: [], symbols: [])
    #expect(hits == ["Bard", "basic", "Batch"])
}

@Test func suggestionsDeduplicateAcrossGroupsByPriority() {
    // "return" is both a keyword and a document word; it must appear once, and
    // as a keyword (higher priority than a document word) rather than twice.
    let index = WordIndex(text: "return returned")
    let hits = index.suggestions(prefix: "ret", language: ["return"], symbols: [])
    #expect(hits == ["return", "returned"])
    #expect(hits.filter { $0 == "return" }.count == 1)
}

@Test func suggestionsCapAtFifty() {
    // 60 document words sharing the prefix; only 50 come back.
    let words = (0..<60).map { "item\(String(format: "%03d", $0))" }
    let index = WordIndex(text: words.joined(separator: " "))
    let hits = index.suggestions(prefix: "item", language: [], symbols: [])
    #expect(hits.count == WordIndex.maxSuggestions)
    #expect(hits.count == 50)
}

@Test func suggestionsCapCountsSymbolsAndKeywordsFirst() {
    // Symbols and keywords occupy the earliest slots; with the cap at 50 and
    // exactly 50 symbols matching, no keyword or document word survives.
    let symbols = Set((0..<50).map { "sym\(String(format: "%03d", $0))" })
    let index = WordIndex(text: "symDocument")
    let hits = index.suggestions(prefix: "sym", language: ["symKeyword"], symbols: symbols)
    #expect(hits.count == 50)
    #expect(hits.allSatisfy { $0.hasPrefix("sym0") })
    #expect(hits.contains("symKeyword") == false)
    #expect(hits.contains("symDocument") == false)
}

// MARK: - Built-in identifiers (LanguageDefinition.builtins)

@Test func pythonBuiltinsIncludePrint() {
    let def = LanguageRegistry.definition(forIdentifier: "python")
    #expect(def?.builtins.contains("print") == true)
}

@Test func javascriptBuiltinsIncludeConsole() {
    let def = LanguageRegistry.definition(forIdentifier: "javascript")
    #expect(def?.builtins.contains("console") == true)
}

@Test func suggestionsForPythonPrefixIncludePrintBuiltin() {
    // Mirrors how `CompletionController` merges keywords + builtins before
    // querying the index (see `setLanguage`).
    guard let def = LanguageRegistry.definition(forIdentifier: "python") else {
        Issue.record("expected a python language definition")
        return
    }
    let index = WordIndex(text: "")
    let hits = index.suggestions(prefix: "pri",
                                 language: def.keywords + def.builtins,
                                 symbols: [])
    #expect(hits.contains("print"))
}

// MARK: - Module gating / released state

@MainActor
@Test func disablingCompletionReleasesIndexState() {
    let center = NotificationCenter()
    let defaults = isolatedDefaults()
    let settings = ModuleSettings(defaults: defaults, center: center)

    let textView = EditorTextView()
    textView.string = "def compute():\n    return value"

    let controller = CompletionController(textView: textView,
                                          moduleSettings: settings,
                                          moduleCenter: center)
    controller.setLanguage(fileExtension: "py")
    controller.indexDocument()

    // Enabled + indexed → runtime state held.
    #expect(controller.isModuleEnabled)
    #expect(controller.isRuntimeStateReleased == false)

    // Disabling the module must release the index and symbol state.
    settings.setEnabled(false, for: .completion)
    #expect(controller.isModuleEnabled == false)
    #expect(controller.isRuntimeStateReleased)

    // Re-enabling rebuilds from the current document.
    settings.setEnabled(true, for: .completion)
    #expect(controller.isModuleEnabled)
    #expect(controller.isRuntimeStateReleased == false)
}

@MainActor
@Test func indexingIsNoOpWhileModuleDisabled() {
    let center = NotificationCenter()
    let defaults = isolatedDefaults()
    let settings = ModuleSettings(defaults: defaults, center: center)
    settings.setEnabled(false, for: .completion)

    let textView = EditorTextView()
    textView.string = "some content here"

    let controller = CompletionController(textView: textView,
                                          moduleSettings: settings,
                                          moduleCenter: center)
    controller.indexDocument()

    // Module off from the start: no runtime state despite non-empty text.
    #expect(controller.isModuleEnabled == false)
    #expect(controller.isRuntimeStateReleased)
}
