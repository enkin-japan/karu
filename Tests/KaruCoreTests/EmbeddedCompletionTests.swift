import AppKit
import Foundation
import Testing
@testable import KaruCore

// M17 T17.8c — the language at the caret (plan §7 "细化"): completion in an
// HTML `<script>` / `<style>` body or a Markdown fence follows the child
// language (keywords, `.` receivers, `$`, case, strings and comments), the
// host's walkers run per embedded region (scope-only declarations, shared top
// level per language, no leaks between regions), child segments get their
// declaration roles, and the real editor path (cold caret, edits upstream,
// teardown).

// MARK: - Helpers

private let embeddedFixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // KaruCoreTests
    .deletingLastPathComponent()   // Tests
    .appendingPathComponent("Fixtures/M17/highlight", isDirectory: true)

private func fixture(_ name: String) throws -> String {
    try String(contentsOf: embeddedFixtures.appendingPathComponent(name), encoding: .utf8)
}

/// Runs the engine on `source`, whose `│` marks the caret (removed), as a
/// `language` document; the snapshot and word index are fresh.
private func complete(_ source: String, language: String, manual: Bool = false,
                      snapshot useSnapshot: Bool = true) -> CompletionResult? {
    let (text, caret) = caretText(source)
    return complete(text: text, caret: caret, language: language, manual: manual, snapshot: useSnapshot)
}

private func complete(text: String, caret: Int, language: String, manual: Bool = false,
                      snapshot useSnapshot: Bool = true) -> CompletionResult? {
    var engine = CandidateEngine()
    return complete(text: text, caret: caret, language: language, manual: manual, snapshot: useSnapshot,
                    engine: &engine)
}

private func complete(text: String, caret: Int, language: String, manual: Bool = false,
                      snapshot useSnapshot: Bool = true, engine: inout CandidateEngine) -> CompletionResult? {
    let def = LanguageRegistry.definition(forIdentifier: language)
    var request = CompletionRequest(text: text as NSString, caret: caret, languageIdentifier: language)
    request.manual = manual
    request.keywords = def?.keywords ?? []
    request.builtins = def?.builtins ?? []
    if useSnapshot {
        request.snapshot = DeclarationScan.scan(text: text, languageIdentifier: language)
        request.snapshotVersion = 1
    }
    request.words = WordIndex(text: text, languageIdentifier: language)
    request.scanner = CandidateEngine.contextScanner(for: language, definition: def)
    var checkpoints = CheckpointStore()
    return engine.complete(request, checkpoints: &checkpoints)
}

private func caretText(_ source: String) -> (String, Int) {
    let marker = (source as NSString).range(of: "│")
    precondition(marker.location != NSNotFound, "no caret marker")
    return ((source as NSString).replacingCharacters(in: marker, with: ""), marker.location)
}

/// `text` with `insert` typed after the first `after` (the caret after it).
private func typed(_ text: String, after marker: String, insert: String, occurrence: Int = 1) -> (String, Int) {
    let ns = text as NSString
    var from = 0
    var hit = NSRange(location: NSNotFound, length: 0)
    for _ in 0..<occurrence {
        hit = ns.range(of: marker, options: .literal, range: NSRange(location: from, length: ns.length - from))
        precondition(hit.location != NSNotFound, "marker \(marker) not found")
        from = NSMaxRange(hit)
    }
    let at = NSMaxRange(hit)
    return (ns.replacingCharacters(in: NSRange(location: at, length: 0), with: insert),
            at + (insert as NSString).length)
}

private func names(_ result: CompletionResult?) -> [String] { result?.candidates.map(\.name) ?? [] }

private func candidate(_ result: CompletionResult?, _ name: String) -> Candidate? {
    result?.candidates.first { $0.name == name }
}

/// Keyword / builtin-sourced names of a result.
private func keywordNames(_ result: CompletionResult?) -> Set<String> {
    Set(result?.candidates.filter { $0.source == .keyword }.map(\.name) ?? [])
}

private func vocabulary(_ language: String) -> Set<String> {
    let def = LanguageRegistry.definition(forIdentifier: language)
    return Set((def?.keywords ?? []) + (def?.builtins ?? []))
}

/// Visible binding names at the `│` of `source`.
private func visibleNames(_ source: String, language: String) -> Set<String> {
    let (text, caret) = caretText(source)
    let scan = DeclarationScan.scan(text: text, languageIdentifier: language)
    let full = Set(scan.visibleBindings(at: caret).map(\.name))
    let indexed = Set(DeclarationQueryIndex(scan: scan).visibleBindings(at: caret).map(\.name))
    #expect(full == indexed, "index and full sweep disagree at \(caret)")
    return full
}

// MARK: - Caret language (engine)

@Suite("EmbeddedCompletion — caret language", .serialized)
struct EmbeddedCaretLanguageTests {

    /// page.html: the first script completes JavaScript (its keywords and
    /// builtins, its region's declarations), not HTML.
    @Test func javascriptScriptInPageHTML() throws {
        let page = try fixture("embedded/page.html")
        let js = vocabulary("javascript")
        let (text, caret) = typed(page, after: "items.reduce((s, i) => s + i.price, 0) / 100;\n", insert: "    co")
        let result = complete(text: text, caret: caret, language: "html")
        #expect(result?.context.languageIdentifier == "javascript")
        #expect(candidate(result, "const")?.source == .keyword)
        #expect(candidate(result, "console")?.source == .keyword)    // a JS builtin
        #expect(keywordNames(result).isSubset(of: js))
        let (text2, caret2) = typed(page, after: "app.innerHTML = html; ", insert: "re")
        let result2 = complete(text: text2, caret: caret2, language: "html")
        #expect(candidate(result2, "return")?.source == .keyword)
        // The region's own bindings come from the snapshot.
        let (text3, caret3) = typed(page, after: "app.innerHTML = html; ", insert: "to")
        #expect(candidate(complete(text: text3, caret: caret3, language: "html"), "total")?.source
                == .fileDeclaration)
    }

    /// HTML text and Markdown prose keep the host's behaviour: no keywords,
    /// no region names, the same list as without a declaration snapshot.
    @Test func hostTextIsUnchanged() throws {
        let page = try fixture("embedded/page.html")
        for (marker, insert) in [("<p>Text after the scripts ", "to"), ("<title>", "ap"), ("<head>\n", "re")] {
            let (text, caret) = typed(page, after: marker, insert: insert)
            let result = complete(text: text, caret: caret, language: "html")
            #expect(result.map { $0.context.languageIdentifier == "html" } ?? true)
            #expect(keywordNames(result).isEmpty)
            #expect(!(result?.candidates.contains { $0.source == .fileDeclaration || $0.source == .scope } ?? false))
            #expect(names(result) == names(complete(text: text, caret: caret, language: "html", snapshot: false)))
        }
        let fences = try fixture("embedded/fences.md")
        for (marker, insert) in [("Text between fences ", "la"), ("# Fenced ", "to"), ("JavaScript via the ", "co")] {
            let (text, caret) = typed(fences, after: marker, insert: insert)
            let result = complete(text: text, caret: caret, language: "markdown")
            #expect(result.map { $0.context.languageIdentifier == "markdown" } ?? true)
            #expect(keywordNames(result).isEmpty)
            #expect(!(result?.candidates.contains { $0.source == .fileDeclaration || $0.source == .scope } ?? false))
            #expect(names(result) == names(complete(text: text, caret: caret, language: "markdown", snapshot: false)))
        }
    }

    /// fences.md: a python fence completes Python; a js fence JavaScript;
    /// an unknown-language fence and the fence's opener line stay Markdown.
    @Test func fencesInMarkdown() throws {
        let fences = try fixture("embedded/fences.md")
        let (text, caret) = typed(fences, after: "\"\"\"Docstring inside a fence.\"\"\"\n", insert: "    re")
        let python = complete(text: text, caret: caret, language: "markdown")
        #expect(python?.context.languageIdentifier == "python")
        #expect(candidate(python, "return")?.source == .keyword)
        #expect(keywordNames(python).isSubset(of: vocabulary("python")))
        // Parameters of the enclosing function.
        let (text2, caret2) = typed(fences, after: "\"\"\"Docstring inside a fence.\"\"\"\n", insert: "    pr")
        #expect(candidate(complete(text: text2, caret: caret2, language: "markdown"), "prices")?.source == .scope)

        let (text3, caret3) = typed(fences, after: "/* block comment */ console.log(label);\n", insert: "co")
        let js = complete(text: text3, caret: caret3, language: "markdown")
        #expect(js?.context.languageIdentifier == "javascript")
        #expect(candidate(js, "const")?.source == .keyword)

        let (text4, caret4) = typed(fences, after: "```brainfuck\n", insert: "re")
        let unknown = complete(text: text4, caret: caret4, language: "markdown")
        #expect(unknown.map { $0.context.languageIdentifier == "markdown" } ?? true)
        #expect(keywordNames(unknown).isEmpty)
    }

    /// A css `<style>` body completes as CSS: CSS's (empty) keyword list, no
    /// JavaScript words, `$` is no identifier character.
    @Test func cssStyleBody() throws {
        let page = try fixture("embedded/page.html")
        let (text, caret) = typed(page, after: "color: var(--accent);\n", insert: "      co")
        let result = complete(text: text, caret: caret, language: "html")
        #expect(result?.context.languageIdentifier == "css")
        #expect(result?.context.position == .code)
        #expect(candidate(result, "const").map { $0.source == .documentWord } ?? true)
        #expect(keywordNames(result).isSubset(of: vocabulary("css")))
        #expect(names(result).contains("color"))
        // A start tag stays HTML.
        let start = complete("<style med│ia=\"x\">a { color: red }</style>", language: "html", manual: true)
        #expect(start.map { $0.context.languageIdentifier == "html" } ?? true)
    }

    /// `$` is an identifier character inside an HTML script, not around it.
    @Test func dollarIdentifiersInAScript() {
        let source = "<p>$el</p>\n<script>\nconst $element = document.body;\n$el│\n</script>\n"
        let result = complete(source, language: "html")
        #expect(result?.context.prefix == "$el")
        #expect(names(result).first == "$element")
        let host = complete("<script>\nconst $element = 1;\n</script>\n<p>$el│</p>\n", language: "html", manual: true)
        #expect(host.map { $0.context.prefix == "el" } ?? true)
    }

    /// A `.` after a receiver with usage evidence opens with an empty
    /// prefix inside a script (JS receiver rules); `this.` reads the class.
    @Test func dotTriggerWithReceiverEvidence() {
        let source = "<div>user.name</div>\n<script>\nconst user = load();\nuser.profile = 1;\nuser.save();\nuser.│\n</script>\n"
        let result = complete(source, language: "html")
        #expect(result?.context.memberAccess?.receiver == "user")
        #expect(Set(names(result)) == ["profile", "save"])
        // `this.` members of a class in the script.
        let members = complete("<script>\nclass Box {\n  constructor() { this.width = 1; }\n  area() { return this.│ }\n}\n</script>\n",
                               language: "html")
        #expect(members?.context.memberAccess?.isSelfOrThis == true)
        #expect(names(members).contains("width"))
        // Without evidence: nothing on `.` alone.
        #expect(complete("<script>\nconst q = 1;\nzed.│\n</script>\n", language: "html") == nil)
    }

    /// Strings and comments of the child suppress the automatic popup;
    /// a manual request gives document words there.
    @Test func childStringsAndCommentsSuppressAutoPopup() {
        let words = "<p>alpha alphabet</p>\n"
        #expect(complete(words + "<script>\nconst s = \"al│\";\n</script>\n", language: "html") == nil)
        #expect(complete(words + "<script>\n// al│\n</script>\n", language: "html") == nil)
        #expect(complete(words + "<script>\n/* al│ */\n</script>\n", language: "html") == nil)
        #expect(complete(words + "```python\nx = 'al│'\n```\n", language: "markdown") == nil)
        #expect(complete(words + "```python\n# al│\n```\n", language: "markdown") == nil)
        let manual = complete(words + "<script>\n// al│\n</script>\n", language: "html", manual: true)
        #expect(manual?.context.position == .comment)
        #expect(names(manual).contains("alphabet"))
        // Template interpolation in the child is code.
        let interpolation = complete("<script>\nconst alpha = 1;\nconst s = `${al│}`;\n</script>\n", language: "html")
        #expect(interpolation?.context.position == .code)
        #expect(names(interpolation).contains("alpha"))
    }

    /// JSX children text inside a `<script>` is a string position.
    @Test func jsxTextInsideAScriptIsAString() {
        let source = "<script>\nconst alpha = 1;\nconst el = <div className=\"x\">hello al│</div>;\n</script>\n"
        #expect(complete(source, language: "html") == nil)
        let manual = complete(source, language: "html", manual: true)
        #expect(manual?.context.position == .string)
        #expect(manual?.context.languageIdentifier == "javascript")
        let expression = complete("<script>\nconst alpha = 1;\nconst el = <div>{al│}</div>;\n</script>\n", language: "html")
        #expect(expression?.context.position == .code)
        #expect(names(expression).contains("alpha"))
    }

    /// Strings are content in a json fence: plain-text completion there.
    @Test func jsonFenceStringsAreContent() {
        let source = "Prose\n\n```json\n{ \"alphabet\": 1, \"al│\": 2 }\n```\n"
        let result = complete(source, language: "markdown")
        #expect(result?.context.languageIdentifier == "json")
        #expect(result?.context.position == .plainText)
        #expect(names(result).contains("alphabet"))
    }

    /// The engine's caches include the child vocabularies, built once per
    /// language and released by `reset()`.
    @Test func childVocabulariesAreCachedAndReleased() throws {
        let page = try fixture("embedded/page.html")
        var engine = CandidateEngine()
        let (text, caret) = typed(page, after: "app.innerHTML = html; ", insert: "re")
        _ = complete(text: text, caret: caret, language: "html", engine: &engine)
        #expect(engine.cachedVocabularyLanguages == ["javascript"])
        let (text2, caret2) = typed(page, after: "color: var(--accent);\n", insert: "      co")
        _ = complete(text: text2, caret: caret2, language: "html", engine: &engine)
        #expect(engine.cachedVocabularyLanguages == ["javascript", "css"])
        #expect(engine.vocabularyBytes > 0)
        engine.reset()
        #expect(!engine.holdsState)
        #expect(engine.cachedVocabularyLanguages.isEmpty)
    }

    /// Without a mappable caret (an unmappable journal) a child body still
    /// gets the top-level names of its language's regions, never another
    /// language's.
    @Test func unmappableJournalKeepsTheRegionLanguage() {
        let (text, caret) = caretText("```js\nconst jsAlpha = 1;\n```\n\n```python\npyAlpha = 2\n```\n\n"
                                      + "```js\nlet b = 0;\nal│\n```\n")
        let def = LanguageRegistry.definition(forIdentifier: "markdown")
        var request = CompletionRequest(text: text as NSString, caret: caret, languageIdentifier: "markdown")
        request.snapshot = DeclarationScan.scan(text: text, languageIdentifier: "markdown")
        request.snapshotVersion = 1
        for _ in 0...EditJournal.capacity {
            request.snapshotJournal.record(editedRange: NSRange(location: 0, length: 0), changeInLength: 0)
        }
        request.scanner = CandidateEngine.contextScanner(for: "markdown", definition: def)
        var engine = CandidateEngine()
        var checkpoints = CheckpointStore()
        let manual = { () -> CompletionResult? in
            var r = request
            r.manual = true
            return engine.complete(r, checkpoints: &checkpoints)
        }()
        #expect(candidate(manual, "jsAlpha")?.source == .fileDeclaration)
        #expect(candidate(manual, "pyAlpha") == nil)
    }

    /// Case rules follow the child: an SQL fence dedupes case-insensitively.
    @Test func sqlFenceIsCaseInsensitive() {
        let source = "```sql\nSELECT Total, total FROM t;\nto│\n```\n"
        let result = complete(source, language: "markdown")
        #expect(result?.context.languageIdentifier == "sql")
        #expect(result?.context.isCaseSensitive == false)
        #expect(names(result).filter { $0.lowercased() == "total" }.count == 1)
    }
}

// MARK: - Declarations per region

@Suite("EmbeddedCompletion — declarations", .serialized)
struct EmbeddedDeclarationTests {

    /// Classic scripts share their globals: script 1's bindings are visible
    /// in script 2 (also through the engine, as file declarations).
    @Test func scriptBindingsAreVisibleInLaterScripts() {
        let source = "<script>\nconst first = 1;\nfunction helper(arg) { return arg; }\n</script>\n<p>x</p>\n"
            + "<script>\nlet second = first;\n│\n</script>\n"
        let names = visibleNames(source, language: "html")
        #expect(names.isSuperset(of: ["first", "helper", "second"]))
        #expect(!names.contains("arg"))
        let (text, caret) = caretText(source)
        let (live, at) = typed(text, after: "let second = first;\n", insert: "he")
        _ = caret
        #expect(candidate(complete(text: live, caret: at, language: "html"), "helper")?.source == .fileDeclaration)
    }

    /// A python fence's function parameters are visible only inside it;
    /// consecutive python fences continue the same top level.
    @Test func pythonFenceParametersStayInTheirFunction() {
        let head = "Intro\n\n```python\ndef area(width, height):\n    return width * height\n```\n\nMore text\n\n```py\n"
        let inside = visibleNames("Intro\n\n```python\ndef area(width, height):\n    │return width * height\n```\n",
                                  language: "markdown")
        #expect(inside.isSuperset(of: ["area", "width", "height"]))
        let later = visibleNames(head + "total = area(2, 3)\n│\n```\n", language: "markdown")
        #expect(later.isSuperset(of: ["area", "total"]))
        #expect(later.isDisjoint(with: ["width", "height"]))
        let prose = visibleNames(head + "x = 1\n```\n\nProse │here\n", language: "markdown")
        #expect(prose.isEmpty)
    }

    /// An unclosed `{` or an unterminated `def` in one region ends with it:
    /// the next region starts at its own top level.
    @Test func unbalancedRegionsDoNotLeak() {
        let html = "<script>\nfunction broken(a) { let inner = 1;\n</script>\n<script>\nlet y = 2;\n│\n</script>\n"
        let names = visibleNames(html, language: "html")
        #expect(names.isSuperset(of: ["broken", "y"]))
        #expect(names.isDisjoint(with: ["a", "inner"]))
        let (text, caret) = caretText(html)
        let scan = DeclarationScan.scan(text: text, languageIdentifier: "html")
        #expect(scan.scopeChain(at: caret).map(\.kind) == [.embedded, .module])
        let regions = scan.scopes.filter { $0.kind == .embedded }
        #expect(regions.count == 2)
        for scope in scan.scopes where scope.kind != .module && scope.kind != .embedded {
            let region = regions.first { $0.start <= scope.start && scope.start < $0.end }
            #expect(region != nil && scope.end <= region!.end, "scope \(scope) leaks out of its region")
        }

        let md = "```python\ndef broken(p):\n    q = (1,\n```\n\n```python\nz = 3\n│\n```\n"
        let py = visibleNames(md, language: "markdown")
        #expect(py.isSuperset(of: ["broken", "z"]))
        #expect(py.isDisjoint(with: ["p", "q"]))
    }

    /// No visibility across languages, nor from the host.
    @Test func noCrossLanguageVisibility() {
        let md = "```js\nconst jsName = 1;\n```\n\n```python\npyName = 2\n│\n```\n\n```ts\nconst tsName: number = 3;\n```\n"
        let python = visibleNames(md, language: "markdown")
        #expect(python.contains("pyName"))
        #expect(python.isDisjoint(with: ["jsName", "tsName"]))
        let (text, _) = caretText(md)
        let jsCaret = NSMaxRange((text as NSString).range(of: "const jsName = 1;"))
        let scan = DeclarationScan.scan(text: text, languageIdentifier: "markdown")
        #expect(Set(scan.visibleBindings(at: jsCaret).map(\.name)) == ["jsName"])
        // The engine in the python fence offers no JavaScript name.
        let (live, at) = typed(text, after: "pyName = 2\n", insert: "js")
        #expect(candidate(complete(text: live, caret: at, language: "markdown"), "jsName")?.source != .fileDeclaration)
        let (live2, at2) = typed(text, after: "pyName = 2\n", insert: "py")
        #expect(candidate(complete(text: live2, caret: at2, language: "markdown"), "pyName")?.source
                == .fileDeclaration)
    }

    /// Region declarations are scope-only: no navigator items, no table, no
    /// completion symbols; the fixtures' navigator output is unchanged
    /// (HTML and Markdown list nothing).
    @Test func regionDeclarationsAreNotListed() throws {
        for (name, language) in [("embedded/page.html", "html"), ("embedded/fences.md", "markdown"),
                                 ("html.html", "html"), ("markdown.md", "markdown")] {
            let text = try fixture(name)
            let scan = DeclarationScan.scan(text: text, languageIdentifier: language)
            #expect(scan.locations.isEmpty, "\(name)")
            #expect(scan.completionSymbols.isEmpty, "\(name)")
            #expect(scan.table.all.isEmpty, "\(name)")
            #expect(scan.declarations.allSatisfy { !$0.isListed }, "\(name)")
            #expect(WordIndex.scanSymbolLocations(text: text, languageIdentifier: language).isEmpty)
        }
        let page = DeclarationScan.scan(text: try fixture("embedded/page.html"), languageIdentifier: "html")
        #expect(Set(page.declarations.map(\.name)).isSuperset(of: ["app", "total", "html", "render", "state", "label"]))
        #expect(page.scopes.filter { $0.kind == .embedded }.map(\.name) == ["javascript", "javascript"])
        let fences = DeclarationScan.scan(text: try fixture("embedded/fences.md"), languageIdentifier: "markdown")
        #expect(fences.scopes.filter { $0.kind == .embedded }.map(\.name)
                == ["python", "javascript", "typescript", "python"])
    }

    /// Sliced scanning with any budgets equals one pass, and the query
    /// index agrees with the full sweep everywhere.
    @Test func slicedScanEqualsOnePassAndIndexAgrees() throws {
        var docs: [(String, String)] = [
            (try fixture("embedded/page.html"), "html"), (try fixture("embedded/fences.md"), "markdown"),
            (try fixture("html.html"), "html"), (try fixture("markdown.md"), "markdown"),
        ]
        docs.append(("<script>\nvar g = 1;\nfunction f(a) { if (a) { let b = a; }\n</script>\n<style>p{}</style>"
                     + "<script type=\"module\">import { x } from './x.js';\nclass K { m() { this.v = x; } }\n</script>"
                     + "\r\n<script>\nfor (const i of g) {}\n", "html"))
        docs.append(("# T\n\n```python\nclass A:\n    def m(self, p):\n        global G\n        G = p\n```\n"
                     + "```rust\nfn main() { let v = 1; }\nimpl S { fn s(&self) {} }\n```\n~~~go\nfunc g(x int) {}\n~~~\n"
                     + "```tsx\nconst C = ({ name }: P) => <div>{name}</div>;\n```\n```python\nunterminated(\n", "markdown"))
        var rng = SystemRandomNumberGenerator()
        for (text, language) in docs {
            let ns = text as NSString
            let whole = DeclarationScan.scan(text: text, languageIdentifier: language)
            for budget in [1, 7, 64, 513] + (0..<3).map({ _ in Int.random(in: 2...200, using: &rng) }) {
                var scanner = DeclarationScanner(languageIdentifier: language)
                while !scanner.step(ns, budgetUnits: budget) {}
                #expect(scanner.scan == whole, "\(language) budget \(budget)")
                #expect(scanner.droppedOutOfOrder == 0)
            }
            let index = DeclarationQueryIndex(scan: whole)
            for offset in stride(from: 0, through: ns.length, by: max(1, ns.length / 160)) {
                let full = whole.visibleBindings(at: offset).map { "\($0.name)@\($0.scopeDepth)" }
                let fast = index.visibleBindings(at: offset).map { "\($0.name)@\($0.scopeDepth)" }
                #expect(Set(full) == Set(fast), "\(language) at \(offset)")
                #expect(whole.scopeChain(at: offset) == index.scopeChain(at: offset))
            }
        }
    }

    /// `var` and `global` stop at the region; the end of a body (before the
    /// end tag) is still in the region.
    @Test func regionIsTheTopLevel() {
        let html = "<script>\nfunction f() { var local = 1; }\nvar top = 2;\n</script>\n<script>\nfu│</script>\n"
        let names = visibleNames(html, language: "html")
        #expect(names.isSuperset(of: ["f", "top"]))
        #expect(!names.contains("local"))
        let (text, caret) = caretText(html)
        let chain = DeclarationScan.scan(text: text, languageIdentifier: "html").scopeChain(at: caret)
        #expect(chain.first?.kind == .embedded)
    }
}

// MARK: - Highlighting roles in child segments

@Suite("EmbeddedCompletion — child roles", .serialized)
@MainActor
struct EmbeddedRoleTests {
    private let theme = HighlightTheme()

    private func painter(_ text: String, language: String) -> (HighlightEngine, EditorTextView, NotificationCenter) {
        let center = NotificationCenter()
        let frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        let scrollView = NSScrollView(frame: frame)
        let textView = EditorTextView(frame: frame)
        textView.isVerticallyResizable = true
        textView.textContainer?.containerSize = NSSize(width: 700, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView
        textView.string = text
        let name = "EmbeddedRoleTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let engine = HighlightEngine(textView: textView, scrollView: scrollView,
                                     moduleSettings: ModuleSettings(defaults: defaults, center: center),
                                     moduleCenter: center)
        engine.setLanguage(identifier: language)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        engine.appearanceDidChange()
        return (engine, textView, center)
    }

    private func colour(_ textView: NSTextView, of word: String, occurrence: Int = 1) -> NSColor? {
        let ns = textView.string as NSString
        var from = 0
        var hit = NSRange(location: NSNotFound, length: 0)
        for _ in 0..<occurrence {
            hit = ns.range(of: word, options: .literal, range: NSRange(location: from, length: ns.length - from))
            guard hit.location != NSNotFound else { return nil }
            from = NSMaxRange(hit)
        }
        return textView.layoutManager!.temporaryAttribute(.foregroundColor, atCharacterIndex: hit.location,
                                                          effectiveRange: nil) as? NSColor
    }

    /// Declaration roles of the region's child walker colour the names in
    /// child segments; references and host text keep their colours.
    @Test func childDeclarationsGetTheirRoles() {
        let (engine, textView, _) = painter(
            "<p>limit area</p>\n<script>\nconst limit = 3;\nfunction area(width) { return width * limit; }\n</script>\n",
            language: "html")
        _ = engine
        #expect(colour(textView, of: "limit", occurrence: 2) === theme.color(for: .constant))
        #expect(colour(textView, of: "area", occurrence: 2) === theme.color(for: .symbolFunction))
        #expect(colour(textView, of: "width") === theme.color(for: .parameter))
        #expect(colour(textView, of: "limit", occurrence: 1) == nil)          // host text
        #expect(colour(textView, of: "area", occurrence: 1) == nil)
        let (engine2, md, _) = painter("Text\n\n```python\ndef total(prices):\n    return prices\n```\n",
                                       language: "markdown")
        _ = engine2
        #expect(colour(md, of: "total") === theme.color(for: .symbolFunction))
        #expect(colour(md, of: "prices") === theme.color(for: .parameter))
        #expect(colour(md, of: "prices", occurrence: 2) == nil)                // a reference
    }
}

// MARK: - The editor path

private func isolatedDefaults() -> (UserDefaults, () -> Void) {
    let name = "EmbeddedCompletionUITests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return (d, { d.removePersistentDomain(forName: name) })
}

/// A real `EditorTextView` in a window with the completion controller (and
/// its own analysis) on the observer hub, as in `CompletionUITests`.
@MainActor
private final class EmbeddedHarness {
    let center = NotificationCenter()
    let settings: ModuleSettings
    let cleanDefaults: () -> Void
    let scheduler = AnalysisScheduler()
    let window: NSWindow
    let textView: EditorTextView
    let hub = TextStorageObserverHub()
    let controller: CompletionController

    init(_ text: String, language: String, caretAfter marker: String) {
        let (defaults, clean) = isolatedDefaults()
        cleanDefaults = clean
        settings = ModuleSettings(defaults: defaults, center: center)
        let frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let scrollView = NSScrollView(frame: frame)
        textView = EditorTextView(frame: frame)
        textView.allowsUndo = true
        textView.isRichText = false
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        textView.string = text
        textView.textStorage?.delegate = hub
        controller = CompletionController(textView: textView, moduleSettings: settings, moduleCenter: center,
                                          scheduler: scheduler)
        controller.labelLanguageOverride = .en
        hub.add(controller)
        textView.completionKeyHandler = controller
        window.makeFirstResponder(textView)
        controller.setLanguage(identifier: language)
        caret(after: marker)
        textView.currentEventProvider = { nil }
    }

    func caret(after marker: String) {
        let range = (textView.string as NSString).range(of: marker)
        precondition(range.location != NSNotFound, "marker \(marker) not found")
        textView.setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
    }

    func type(_ string: String) {
        for ch in string {
            let key = String(ch)
            textView.insertText(key, replacementRange: NSRange(location: NSNotFound, length: 0))
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, characters: key,
                                         charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0)!
            controller.textViewDidInsertKey(event)
        }
    }

    var names: [String] { controller.currentSuggestionsForTesting }
    var context: CompletionContext? { controller.currentContextForTesting }
    var candidates: [Candidate] { controller.currentCandidatesForTesting }

    func close() {
        controller.dismissCompletion()
        textView.textStorage?.delegate = nil
        window.close()
        cleanDefaults()
    }
}

@Suite("EmbeddedCompletion — editor path", .serialized)
@MainActor
struct EmbeddedEditorPathTests {
    private static func page(scripts: Int) -> String {
        var text = "<!DOCTYPE html>\n<html>\n<body>\n<p>Some prose about counters.</p>\n"
        for i in 0..<scripts {
            text += "<script>\nconst counter\(i) = \(i);\nfunction bump\(i)(step) { return counter\(i) + step; }\n</script>\n"
            text += "<p>between \(i)</p>\n"
        }
        return text + "</body>\n</html>\n"
    }

    /// Cold: a document opened with the caret in the middle of a script (no
    /// checkpoints, no prior scan) completes JavaScript at the first key.
    @Test func coldCaretInTheMiddleOfAScript() {
        let h = EmbeddedHarness(Self.page(scripts: 40), language: "html", caretAfter: "function bump20(step) { ")
        defer { h.close() }
        #expect(h.controller.analysis.contextCheckpoints.entries.isEmpty)
        h.type("co")
        #expect(h.context?.languageIdentifier == "javascript")
        #expect(h.names.contains("const"))
        #expect(h.names.contains("counter20"))
        #expect(h.candidates.first { $0.name == "counter20" }?.source == .fileDeclaration)
        h.type("unter")
        #expect(h.names.first?.hasPrefix("counter") == true)
        // A `$` key opens in a script (JS identifiers).
        h.caret(after: "function bump21(step) { ")
        h.type("$")
        #expect(h.controller.caretLanguageIdentifier() == "javascript")
    }

    /// Host text completes as HTML: no JavaScript keywords or names.
    @Test func hostTextKeepsHostBehaviour() {
        let h = EmbeddedHarness(Self.page(scripts: 3), language: "html", caretAfter: "<p>Some prose about ")
        defer { h.close() }
        h.type("co")
        #expect(h.context.map { $0.languageIdentifier == "html" } ?? true)
        #expect(!h.candidates.contains { $0.source == .fileDeclaration || $0.source == .keyword })
        #expect(h.controller.caretLanguageIdentifier() == "html")
        // Then into a script.
        h.caret(after: "function bump1(step) { ")
        h.type("re")
        #expect(h.context?.languageIdentifier == "javascript")
        #expect(h.names.contains("return"))
    }

    /// An edit upstream (invalidating the checkpoints) leaves the caret's
    /// language right.
    @Test func editUpstreamThenTypeInTheRegion() async {
        let h = EmbeddedHarness(Self.page(scripts: 1200), language: "html", caretAfter: "function bump700(step) { ")
        defer { h.close() }
        h.type("re")
        #expect(h.names.contains("return"))
        #expect(!h.controller.analysis.contextCheckpoints.entries.isEmpty)
        // Insert a script before everything (shifts every region).
        h.textView.setSelectedRange(NSRange(location: 0, length: 0))
        h.textView.insertText("<script>\nconst early = 1;\n</script>\n",
                              replacementRange: NSRange(location: 0, length: 0))
        h.caret(after: "function bump700(step) { re")
        h.type("t")
        #expect(h.context?.languageIdentifier == "javascript")
        #expect(h.names.contains("return"))
        // Break the region upstream: an unclosed comment before it makes the
        // caret host text of an HTML comment.
        h.textView.insertText("<!-- ", replacementRange: NSRange(location: 0, length: 0))
        h.caret(after: "function bump700(step) { ret")
        h.type("u")
        #expect(h.controller.caretLanguageIdentifier() == "html")
        #expect(h.context == nil || h.context?.languageIdentifier == "html")
    }

    /// Markdown: a python fence cold, then prose.
    @Test func markdownFenceAndProse() {
        var text = "# Notes\n\nSome prose.\n\n"
        for i in 0..<20 { text += "```python\ndef step\(i)(value):\n    return value\n```\n\nText \(i).\n\n" }
        let h = EmbeddedHarness(text, language: "markdown", caretAfter: "def step10(value):\n    ")
        defer { h.close() }
        h.type("va")
        #expect(h.context?.languageIdentifier == "python")
        #expect(h.names.first == "value")
        h.caret(after: "Some prose")
        h.type(" re")
        #expect(h.context.map { $0.languageIdentifier == "markdown" } ?? true)
        #expect(!h.candidates.contains { $0.source == .keyword || $0.source == .fileDeclaration })
    }

    /// Tearing down: the module off releases everything (the child
    /// vocabularies too); closing the window does not crash.
    @Test func teardownReleasesState() {
        let h = EmbeddedHarness(Self.page(scripts: 3), language: "html", caretAfter: "function bump1(step) { ")
        h.type("re")
        #expect(!h.names.isEmpty)
        #expect(!h.controller.isRuntimeStateReleased)
        h.settings.setEnabled(false, for: .completion)
        #expect(h.controller.isRuntimeStateReleased)
        h.settings.setEnabled(true, for: .completion)
        h.caret(after: "function bump2(step) { ")
        h.type("re")
        #expect(h.names.contains("return"))
        h.close()
        #expect(!h.controller.isCompletionActive)
        h.settings.setEnabled(false, for: .completion)
        #expect(h.controller.isRuntimeStateReleased)
    }
}
