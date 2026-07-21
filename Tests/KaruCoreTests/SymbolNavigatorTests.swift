import AppKit
import Foundation
import Testing
@testable import KaruCore

// Exercises the positional symbol scan feeding the "Jump to Symbol" navigator
// (T8.4): `WordIndex.scanSymbolLocations` (name + kind + exact name range, in
// document order) and `SymbolNavigator.filter` (case-insensitive substring
// matching). The navigator UI itself is a thin AppKit shell over these.

private func location(_ locations: [WordIndex.SymbolLocation],
                      named name: String) -> WordIndex.SymbolLocation? {
    locations.first { $0.name == name }
}

// MARK: - Python: name + kind + range

@Test func scanLocatesPythonDeclarationsWithExactNameRanges() {
    let source = """
    class Widget:
        def render(self):
            count = 0
    """
    let ns = source as NSString
    let locations = WordIndex.scanSymbolLocations(text: source, languageIdentifier: "python")

    // Document order: class → def → assignment.
    #expect(locations.map(\.name) == ["Widget", "render", "count"])
    #expect(locations.map(\.kind) == [.type, .function, .variable])

    // Ranges are the *name* capture group (used to select the identifier on jump).
    #expect(location(locations, named: "Widget")?.range == ns.range(of: "Widget"))
    #expect(location(locations, named: "render")?.range == ns.range(of: "render"))
    #expect(location(locations, named: "count")?.range == ns.range(of: "count"))
}

// MARK: - JavaScript: arrow binding classified as a function, not a variable

@Test func scanLocatesJavaScriptDeclarationsAndArrowFunctions() {
    let source = """
    class Panel {}
    function greet(name) { return name; }
    const answer = 42;
    const handler = (event) => event.type;
    """
    let ns = source as NSString
    let locations = WordIndex.scanSymbolLocations(text: source, languageIdentifier: "javascript")

    #expect(locations.map(\.name) == ["Panel", "greet", "answer", "handler"])
    #expect(locations.map(\.kind) == [.type, .function, .variable, .function])

    // `handler` is an arrow binding: listed once, as a function, at its name range
    // (never duplicated as a variable).
    let handler = location(locations, named: "handler")
    #expect(handler?.kind == .function)
    #expect(handler?.range == ns.range(of: "handler"))
    #expect(locations.filter { $0.name == "handler" }.count == 1)

    #expect(location(locations, named: "answer")?.range == ns.range(of: "answer"))
    #expect(location(locations, named: "greet")?.range == ns.range(of: "greet"))
}

// MARK: - C: struct type + call heuristic, control words skipped

@Test func scanLocatesCTypesAndFunctionsSkippingControlWords() {
    let source = """
    struct Point { int x; };
    int compute(int n) {
        if (n) return n;
        return n;
    }
    """
    let ns = source as NSString
    let locations = WordIndex.scanSymbolLocations(text: source, languageIdentifier: "c")

    let point = location(locations, named: "Point")
    #expect(point?.kind == .type)
    #expect(point?.range == ns.range(of: "Point"))

    let compute = location(locations, named: "compute")
    #expect(compute?.kind == .function)
    #expect(compute?.range == ns.range(of: "compute"))

    // Point precedes compute in document order.
    #expect(locations.map(\.name).firstIndex(of: "Point")! <
            locations.map(\.name).firstIndex(of: "compute")!)

    // Control-flow words that look like calls must never appear.
    #expect(location(locations, named: "if") == nil)
    #expect(location(locations, named: "return") == nil)
}

// MARK: - Unsupported / empty documents

@Test func scanReturnsEmptyForUnsupportedOrEmptyDocuments() {
    #expect(WordIndex.scanSymbolLocations(text: "anything", languageIdentifier: "markdown").isEmpty)
    #expect(WordIndex.scanSymbolLocations(text: "", languageIdentifier: "python").isEmpty)
    #expect(WordIndex.scanSymbolLocations(text: "def f(): pass", languageIdentifier: "").isEmpty)
}

// MARK: - Consistency with the completion/highlight symbol table

@Test func scanNamesAgreeWithTheClassifiedSymbolTable() {
    let source = """
    class Widget:
        def render(self):
            count = 0

    total = 1
    """
    let table = WordIndex.symbolTable(text: source, languageIdentifier: "python")
    let scanned = WordIndex.scanSymbolLocations(text: source, languageIdentifier: "python")

    // The positional scan and the set-based table are the same classification
    // over the same shared patterns, so their name sets match per category.
    #expect(Set(scanned.filter { $0.kind == .function }.map(\.name)) == table.functions)
    #expect(Set(scanned.filter { $0.kind == .type }.map(\.name)) == table.types)
    #expect(Set(scanned.filter { $0.kind == .variable }.map(\.name)) == table.variables)
}

// MARK: - Navigator filter (case-insensitive substring)

@MainActor
@Test func navigatorFilterMatchesCaseInsensitiveSubstrings() {
    let source = """
    def renderView(): pass
    def compute(): pass
    total = 0
    """
    let locations = WordIndex.scanSymbolLocations(text: source, languageIdentifier: "python")

    // Empty query returns the full document-order list unchanged.
    #expect(SymbolNavigator.filter(locations, query: "").map(\.name) == locations.map(\.name))
    #expect(SymbolNavigator.filter(locations, query: "   ").map(\.name) == locations.map(\.name))

    // Case-insensitive substring anywhere in the name.
    #expect(SymbolNavigator.filter(locations, query: "render").map(\.name) == ["renderView"])
    #expect(SymbolNavigator.filter(locations, query: "VIEW").map(\.name) == ["renderView"])
    #expect(SymbolNavigator.filter(locations, query: "o").map(\.name).sorted() == ["compute", "total"])
    #expect(SymbolNavigator.filter(locations, query: "zzz").isEmpty)
}

// MARK: - Navigator releases all runtime state on close

@MainActor
@Test func navigatorReleasesStateWhenClosed() {
    let textView = NSTextView()
    textView.string = "def helper():\n    pass\n"
    let navigator = SymbolNavigator(textView: textView)

    var closed = false
    navigator.present(languageIdentifier: "python") { closed = true }
    #expect(navigator.isVisible)

    // A jump to the selected symbol closes the panel and fires the release hook.
    textView.window?.orderOut(nil)
    navigator.perform(NSSelectorFromString("panelResignedKey"))
    #expect(navigator.isVisible == false)
    #expect(closed)
}
