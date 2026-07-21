import AppKit
import Foundation
import Testing
@testable import KaruCore

// Exercises `WordIndex.symbolTable(text:languageIdentifier:)`, the classified
// in-document symbol scan feeding the highlighter (T7.4), plus its union
// compatibility shim `symbols(text:…)` still consumed by completion.

private func isolatedDefaults() -> UserDefaults {
    let name = "SymbolTableTests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

// MARK: - Python

@Test func pythonSymbolTableClassifiesDefClassAndAssignments() {
    let source = """
    import os

    THRESHOLD = 10
    name = "x"

    class Widget:
        def render(self):
            count = 0
            if count == THRESHOLD:
                return compute()

    def helper(a, b):
        pass
    """
    let table = WordIndex.symbolTable(text: source, languageIdentifier: "python")

    #expect(table.functions.contains("render"))
    #expect(table.functions.contains("helper"))
    #expect(table.types.contains("Widget"))
    #expect(table.variables.contains("THRESHOLD"))
    #expect(table.variables.contains("name"))
    #expect(table.variables.contains("count"))

    // `compute` is a call, not a declaration → uncategorised.
    #expect(table.functions.contains("compute") == false)
    // A `==` comparison must not be read as an assignment.
    #expect(table.variables.contains("if") == false)
    // Categories are disjoint: a def/class name is not also a variable.
    #expect(table.variables.contains("render") == false)
    #expect(table.variables.contains("Widget") == false)
}

// MARK: - JavaScript / TypeScript

@Test func javascriptSymbolTableClassifiesFunctionClassBindingsAndArrows() {
    let source = """
    function greet(name) { return name; }
    class Panel {}
    const answer = 42;
    let counter = 0;
    var legacy = true;
    const handler = (event) => event.type;
    const load = async (url) => fetch(url);
    """
    let table = WordIndex.symbolTable(text: source, languageIdentifier: "javascript")

    #expect(table.functions.contains("greet"))
    #expect(table.types.contains("Panel"))
    #expect(table.variables.contains("answer"))
    #expect(table.variables.contains("counter"))
    #expect(table.variables.contains("legacy"))

    // Arrow-function bindings land in functions, not variables.
    #expect(table.functions.contains("handler"))
    #expect(table.functions.contains("load"))
    #expect(table.variables.contains("handler") == false)
    #expect(table.variables.contains("load") == false)
}

@Test func typescriptSharesTheJavaScriptClassification() {
    let source = "class Model {}\nconst id = 1;\nfunction build() {}"
    let table = WordIndex.symbolTable(text: source, languageIdentifier: "typescript")
    #expect(table.types.contains("Model"))
    #expect(table.variables.contains("id"))
    #expect(table.functions.contains("build"))
}

// MARK: - C family

@Test func cSymbolTableUsesCallHeuristicAndSkipsControlWords() {
    let source = """
    struct Point { int x; };
    int compute(int n) {
        if (n) return n;
        while (n) n--;
        return compute(n);
    }
    """
    let table = WordIndex.symbolTable(text: source, languageIdentifier: "c")

    #expect(table.types.contains("Point"))
    #expect(table.functions.contains("compute"))

    // Control-flow words that look like calls must not be treated as symbols.
    #expect(table.functions.contains("if") == false)
    #expect(table.functions.contains("while") == false)
    #expect(table.functions.contains("return") == false)

    // C has no variable heuristic; that bucket stays empty.
    #expect(table.variables.isEmpty)
}

// MARK: - Unsupported languages

@Test func unsupportedLanguageYieldsEmptyTable() {
    #expect(WordIndex.symbolTable(text: "anything here", languageIdentifier: "markdown") == .empty)
    #expect(WordIndex.symbolTable(text: "anything here", languageIdentifier: "").isEmpty)
    #expect(WordIndex.symbolTable(text: "SELECT 1", languageIdentifier: "sql").isEmpty)
}

// MARK: - Union / completion compatibility

@Test func symbolsIsTheUnionOfTheTable() {
    let source = """
    class Widget:
        def render(self):
            pass

    total = 0
    """
    let table = WordIndex.symbolTable(text: source, languageIdentifier: "python")
    let flat = WordIndex.symbols(text: source, languageIdentifier: "python")

    #expect(flat == table.all)
    #expect(flat == table.functions.union(table.types).union(table.variables))
    #expect(flat.contains("Widget"))
    #expect(flat.contains("render"))
    #expect(flat.contains("total"))
}

// MARK: - Module gating (highlighter releases the symbol table)

@MainActor
@Test func disablingModuleReleasesSymbolTableState() {
    let center = NotificationCenter()
    let defaults = isolatedDefaults()
    let settings = ModuleSettings(defaults: defaults, center: center)

    let scrollView = NSScrollView()
    let textView = EditorTextView()
    textView.string = "def helper():\n    pass\n"
    scrollView.documentView = textView

    let engine = HighlightEngine(textView: textView,
                                 scrollView: scrollView,
                                 moduleSettings: settings,
                                 moduleCenter: center)
    engine.setLanguage(identifier: "python")

    // Enabled + language resolved → runtime state (incl. symbol table) held.
    #expect(engine.isModuleEnabled)
    #expect(engine.isRuntimeStateReleased == false)

    // Disabling the module must release the symbol table as well.
    settings.setEnabled(false, for: .highlight)
    #expect(engine.isRuntimeStateReleased)

    // Re-enabling rebuilds the runtime state from the remembered language.
    settings.setEnabled(true, for: .highlight)
    #expect(engine.isRuntimeStateReleased == false)
}
