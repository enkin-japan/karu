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

// MARK: - Python: extended variable forms (T10.2)

@Test func pythonForWithAndParametersEnterTheVariableSet() {
    let source = """
    def transform(data, factor=2, *rest, **opts):
        for item in data:
            with open("f") as handle:
                total = item * factor
        return total
    """
    let table = WordIndex.symbolTable(text: source, languageIdentifier: "python")

    // for-loop target and `as` binding.
    #expect(table.variables.contains("item"))
    #expect(table.variables.contains("handle"))
    // def parameters, each extracted individually (past `*` / `**`).
    #expect(table.variables.contains("data"))
    #expect(table.variables.contains("factor"))
    #expect(table.variables.contains("rest"))
    #expect(table.variables.contains("opts"))
    // plain assignment still works.
    #expect(table.variables.contains("total"))

    // `transform` is the function name, not a variable; `self`-style noise absent.
    #expect(table.functions.contains("transform"))
    #expect(table.variables.contains("transform") == false)
}

@Test func pythonSelfAndClsAreNotVariables() {
    let source = """
    class Box:
        def put(self, value):
            self.value = value

        @classmethod
        def make(cls):
            return cls()
    """
    let table = WordIndex.symbolTable(text: source, languageIdentifier: "python")
    // `value` is a real parameter binding; `self` / `cls` are pseudo-keywords.
    #expect(table.variables.contains("value"))
    #expect(table.variables.contains("self") == false)
    #expect(table.variables.contains("cls") == false)
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

@Test func javascriptParametersAndDestructuringEnterTheVariableSet() {
    let source = """
    function render(node, depth) { return node; }
    const scale = (factor, offset) => factor + offset;
    const { width, height } = box;
    const [first, second] = pair;
    """
    let table = WordIndex.symbolTable(text: source, languageIdentifier: "javascript")

    // Named-function parameters.
    #expect(table.variables.contains("node"))
    #expect(table.variables.contains("depth"))
    // Arrow-function parameters.
    #expect(table.variables.contains("factor"))
    #expect(table.variables.contains("offset"))
    // Object + array destructuring bindings.
    #expect(table.variables.contains("width"))
    #expect(table.variables.contains("height"))
    #expect(table.variables.contains("first"))
    #expect(table.variables.contains("second"))

    // `render` is a function; `scale` an arrow binding (function), never a variable.
    #expect(table.functions.contains("render"))
    #expect(table.functions.contains("scale"))
    #expect(table.variables.contains("scale") == false)
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
