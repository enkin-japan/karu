import AppKit
import Testing
@testable import KaruCore

/// Regressions from the 2026-11-17 maintenance review of identifier
/// colouring and the same-word highlight (LEDGER VH1–VH6), through the real
/// editor window wiring.
@Suite("Highlight maintenance 2026-11", .serialized)
@MainActor
struct HighlightMaintenanceTests {
    /// An editor window on a temporary file (language from its extension).
    @MainActor final class Editor {
        let directory: URL
        let controller = EditorWindowController()

        init(_ text: String, fileName: String) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("KaruHighlightMaintenance-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(fileName)
            try text.write(to: url, atomically: true, encoding: .utf8)
            controller.sessionStore = SessionStore(
                defaults: UserDefaults(suiteName: "KaruHighlightMaintenance-\(UUID().uuidString)")!)
            controller.draftStore = DraftStore(directory: directory.appendingPathComponent("drafts", isDirectory: true))
            controller.load(url: url)
            textView.layoutManager!.ensureLayout(for: textView.textContainer!)
        }

        var textView: NSTextView { controller.textViewForTesting }
        var ns: NSString { textView.textStorage!.mutableString }

        func close() {
            controller.documentAnalysis?.cancelPendingWork()
            controller.close()
            try? FileManager.default.removeItem(at: directory)
        }

        func foreground(at index: Int) -> NSColor? {
            textView.layoutManager!.temporaryAttribute(.foregroundColor, atCharacterIndex: index,
                                                       effectiveRange: nil) as? NSColor
        }

        func background(at index: Int) -> NSColor? {
            textView.layoutManager!.temporaryAttribute(.backgroundColor, atCharacterIndex: index,
                                                       effectiveRange: nil) as? NSColor
        }

        /// The foreground colour of the `occurrence`-th (1-based) `word`.
        func foreground(of word: String, occurrence: Int = 1) -> NSColor? {
            var from = 0
            var hit = NSRange(location: NSNotFound, length: 0)
            for _ in 0..<occurrence {
                hit = ns.range(of: word, options: .literal, range: NSRange(location: from, length: ns.length - from))
                guard hit.location != NSNotFound else { return nil }
                from = NSMaxRange(hit)
            }
            return foreground(at: hit.location)
        }

        /// Lets the deferred viewport repaint, the debounced declaration
        /// rescan and its publication run.
        func settle() async {
            let deadline = Date().addingTimeInterval(10)
            repeat {
                try? await Task.sleep(for: .milliseconds(120))
            } while controller.documentAnalysis.declarations == nil && Date() < deadline
            try? await Task.sleep(for: .milliseconds(60))
        }

        /// Lets the debounced same-word scan (200 ms) run.
        func waitForWordScan() async {
            try? await Task.sleep(for: .milliseconds(350))
        }

        /// Selects `range` and opens the find bar, which seeds its query from
        /// the selection.
        func find(_ range: NSRange) {
            textView.setSelectedRange(range)
            controller.showFindBar(nil)
        }

        func caret(_ location: Int) {
            textView.setSelectedRange(NSRange(location: location, length: 0))
        }

        /// Types `text` at the selection, as the keyboard does.
        func type(_ text: String) {
            textView.insertText(text, replacementRange: textView.selectedRange())
        }

        /// Indices in `range` (default: the whole document) that carry a
        /// background.
        func tinted(in range: NSRange? = nil) -> [Int] {
            let range = range ?? NSRange(location: 0, length: ns.length)
            return (range.location..<NSMaxRange(range)).filter { background(at: $0) != nil }
        }

        /// Lets main-queue work queued by an edit run.
        func pump(milliseconds: Int = 30) async {
            try? await Task.sleep(for: .milliseconds(milliseconds))
        }
    }

    private let theme = HighlightTheme()

    // MARK: - VH1: declarations written by an edit that also repaints at once

    /// A multi-line paste grows the text view, which repaints the viewport
    /// before the declaration rescan; the rescan must repaint that band.
    @Test func pastedDeclarationsAreColouredOnceTheRescanLands() async throws {
        let editor = try Editor(String(repeating: "x = 1\n", count: 400), fileName: "sample.py")
        defer { editor.close() }
        await editor.settle()
        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        editor.textView.insertText("def g(tally):\n    return tally\n\n", replacementRange: NSRange(location: 0, length: 0))
        await editor.settle()
        #expect(editor.controller.documentAnalysis.declarations != nil)
        #expect(editor.foreground(of: "g") === theme.color(for: .symbolFunction))
        #expect(editor.foreground(of: "tally") === theme.color(for: .parameter))
    }

    /// The same in C, where references take their colour from the symbol
    /// table: a use of the pasted function's name (not in call form, which
    /// the rules colour by themselves) is coloured without another edit.
    @Test func referenceToAPastedFunctionIsColoured() async throws {
        let text = "int main(void) {\n    handler = helper;\n    return 0;\n}\n" + String(repeating: "// filler\n", count: 400)
        let editor = try Editor(text, fileName: "sample.c")
        defer { editor.close() }
        await editor.settle()
        #expect(editor.foreground(of: "helper") !== theme.color(for: .symbolFunction))
        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        editor.textView.insertText("int helper(int v) {\n    return v;\n}\n\n", replacementRange: NSRange(location: 0, length: 0))
        await editor.settle()
        #expect(editor.foreground(of: "helper", occurrence: 1) === theme.color(for: .symbolFunction))
        #expect(editor.foreground(of: "helper", occurrence: 2) === theme.color(for: .symbolFunction))
    }

    /// Typing a declaration and pressing Return within the rescan debounce.
    @Test func declarationTypedJustBeforeReturnIsColoured() async throws {
        let editor = try Editor(String(repeating: "x = 1\n", count: 400), fileName: "sample.py")
        defer { editor.close() }
        await editor.settle()
        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        editor.textView.insertText("\n", replacementRange: NSRange(location: 0, length: 0))
        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        await editor.settle()
        for character in "def run(speed):" {
            editor.textView.insertText(String(character), replacementRange: editor.textView.selectedRange())
        }
        editor.textView.insertNewline(nil)
        await editor.settle()
        #expect(editor.foreground(of: "run") === theme.color(for: .symbolFunction))
        #expect(editor.foreground(of: "speed") === theme.color(for: .parameter))
    }

    // MARK: - VH3: the search background wins over the word / bracket tints

    @Test func searchColourSurvivesTheWordTint() async throws {
        let text = "value value other value\n"
        let editor = try Editor(text, fileName: "sample.txt")
        defer { editor.close() }
        await editor.settle()
        editor.find(NSRange(location: 0, length: 5))
        let search = try #require(editor.background(at: 0))
        let values = [0, 6, 18]
        for location in values { #expect(editor.background(at: location) === search) }

        editor.caret(8)                 // inside the second `value`
        await editor.waitForWordScan()
        for location in values { #expect(editor.background(at: location) === search) }

        editor.caret(14)                // inside `other`
        await editor.waitForWordScan()
        for location in values { #expect(editor.background(at: location) === search) }

        // Hiding the bar wipes the search colour; the word tint for the caret
        // in a `value` comes back without another caret move.
        editor.caret(8)
        await editor.waitForWordScan()
        editor.controller.findBarForTesting.hide()
        let tint = try #require(editor.background(at: 6))
        #expect(tint !== search)
        for location in values { #expect(editor.background(at: location) === tint) }
        #expect(editor.background(at: 14) == nil)
    }

    @Test func searchColourSurvivesTheBracketTint() async throws {
        let editor = try Editor("f(ab) zz\n", fileName: "sample.txt")
        defer { editor.close() }
        await editor.settle()
        editor.find(NSRange(location: 1, length: 1))      // search for `(`
        let search = try #require(editor.background(at: 1))
        #expect(editor.background(at: 4) == nil)

        editor.caret(2)                                   // just past `(`
        #expect(editor.background(at: 1) === search)
        let bracket = try #require(editor.background(at: 4))
        #expect(bracket !== search)

        editor.caret(7)                                   // away from the pair
        #expect(editor.background(at: 1) === search)
        #expect(editor.background(at: 4) == nil)

        // Hiding the bar with the caret at the pair repaints the pair.
        editor.caret(2)
        editor.controller.findBarForTesting.hide()
        #expect(editor.background(at: 1) === bracket)
        #expect(editor.background(at: 4) === bracket)
    }

    /// A search match on `)` keeps the search colour after an edit inside the
    /// pair re-tints it, and after the caret leaves the pair.
    @Test func searchColourSurvivesTheBracketTintAfterAnEdit() async throws {
        let editor = try Editor("g(ab) )\n", fileName: "sample.txt")
        defer { editor.close() }
        await editor.settle()
        editor.find(NSRange(location: 4, length: 1))      // search for `)`
        let search = try #require(editor.background(at: 6))
        #expect(editor.background(at: 4) === search)

        editor.caret(4)                                   // just before `)`
        let bracket = try #require(editor.background(at: 1))
        #expect(bracket !== search)
        #expect(editor.background(at: 4) === search)

        editor.type("c")                                  // `g(abc|) )`
        await editor.pump()
        #expect(editor.background(at: 1) === bracket)
        #expect(editor.background(at: 5) === search)
        #expect(editor.background(at: 7) === search)

        editor.caret(3)                                   // away from the pair
        #expect(editor.background(at: 1) == nil)
        #expect(editor.background(at: 5) === search)
        #expect(editor.background(at: 7) === search)
    }

    // MARK: - The bracket tint follows edits

    @Test func bracketTintFollowsTypingAfterTheOpener() async throws {
        let editor = try Editor("x(y)\n", fileName: "sample.txt")
        defer { editor.close() }
        await editor.settle()
        editor.caret(2)
        #expect(editor.background(at: 1) != nil)
        #expect(editor.background(at: 3) != nil)
        editor.type("a")                                  // `x(a|y)`
        editor.caret(0)
        #expect(editor.tinted() == [])
        await editor.pump()
        #expect(editor.tinted() == [])
    }

    @Test func bracketTintFollowsAPaste() async throws {
        let editor = try Editor("call(arg)\nzz\n", fileName: "sample.txt")
        defer { editor.close() }
        await editor.settle()
        editor.caret(5)
        #expect(editor.background(at: 8) != nil)
        editor.type("first, ")
        editor.caret(editor.ns.length)
        #expect(editor.background(at: 15) == nil)
        #expect(editor.tinted() == [])
    }

    @Test func deletingTheOpenerClearsTheCloser() async throws {
        let editor = try Editor("ab (c)\n", fileName: "sample.txt")
        defer { editor.close() }
        await editor.settle()
        editor.caret(4)
        #expect(editor.background(at: 5) != nil)
        editor.textView.deleteBackward(nil)               // `ab |c)`
        #expect(editor.background(at: 4) == nil)
        await editor.pump()
        #expect(editor.background(at: 4) == nil)
        editor.caret(0)
        #expect(editor.tinted() == [])
    }

    /// Typing `)` inside a word with the same-word tint: the word
    /// highlighter's asynchronous clear covers the whole paragraph, and the
    /// new pair's tint must come back over it.
    @Test func bracketTintSurvivesTheWordTintClear() async throws {
        let editor = try Editor("(foo) foo\n", fileName: "sample.txt")
        defer { editor.close() }
        await editor.settle()
        editor.caret(3)                                   // `(fo|o) foo`
        await editor.waitForWordScan()
        let word = try #require(editor.background(at: 6))
        #expect(editor.background(at: 1) === word)

        editor.type(")")                                  // `(fo)|o) foo`
        let bracket = try #require(editor.background(at: 0))
        #expect(bracket !== word)
        #expect(editor.background(at: 3) === bracket)

        await editor.pump(milliseconds: 20)               // the asynchronous clear
        #expect(editor.background(at: 0) === bracket)
        #expect(editor.background(at: 3) === bracket)

        await editor.pump(milliseconds: 420)              // and the rescan
        #expect(editor.background(at: 0) === bracket)
        #expect(editor.background(at: 3) === bracket)
        #expect(editor.background(at: 5) == nil)
    }

    /// Undo puts the caret back beside `(`, so the pair is re-tinted where it
    /// was; redo then shifts the closer again.
    @Test func bracketTintFollowsUndoAndRedo() async throws {
        let editor = try Editor("x(y)\nzz\n", fileName: "sample.txt")
        defer { editor.close() }
        await editor.settle()
        editor.caret(2)
        editor.type("a")
        editor.type("b")
        let undoManager = try #require(editor.textView.undoManager)
        #expect(undoManager.canUndo)
        undoManager.undo()                                // `x(|y)`
        #expect(editor.tinted() == [1, 3])
        undoManager.redo()                                // `x(ab|y)`
        editor.caret(editor.ns.length - 2)                // inside `zz`
        let line = editor.ns.lineRange(for: NSRange(location: 0, length: 0))
        #expect(editor.tinted(in: line) == [])
        await editor.pump()
        #expect(editor.tinted(in: line) == [])
    }

    /// Forward delete of the closer does not move the caret, so only the
    /// text-change path can clear the opener.
    @Test func forwardDeletingTheCloserClearsTheOpener() async throws {
        let editor = try Editor("x()\n", fileName: "sample.txt")
        defer { editor.close() }
        await editor.settle()
        editor.caret(2)
        #expect(editor.background(at: 1) != nil)
        editor.textView.deleteForward(nil)                // `x(|`
        await editor.pump()
        #expect(editor.background(at: 1) == nil)
        #expect(editor.tinted() == [])
    }

    /// Text that replaces a tinted bracket programmatically carries no tint
    /// once the caret moves away.
    @Test func replacedBracketCarriesNoTint() async throws {
        let editor = try Editor("x(y)\n", fileName: "sample.txt")
        defer { editor.close() }
        await editor.settle()
        editor.caret(2)
        #expect(editor.background(at: 1) != nil)
        let storage = try #require(editor.textView.textStorage)
        storage.replaceCharacters(in: NSRange(location: 1, length: 1), with: "[")
        editor.textView.didChangeText()
        #expect(editor.background(at: 1) == nil)
        editor.caret(0)
        #expect(editor.tinted() == [])
        await editor.pump()
        #expect(editor.tinted() == [])
    }

    /// A batched edit reports the union of its changes. A tinted bracket
    /// inside that union that no change touched keeps its character; it must
    /// carry no leftover tint once the caret leaves.
    @Test func batchedEditAroundABracketLeavesNoTint() async throws {
        let editor = try Editor("x(y)\n", fileName: "sample.txt")
        defer { editor.close() }
        await editor.settle()
        editor.caret(2)
        #expect(editor.tinted() == [1, 3])
        let storage = try #require(editor.textView.textStorage)
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 2, length: 1), with: "zz")
        storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "w")
        storage.endEditing()
        editor.textView.didChangeText()                   // `w(zz)`
        editor.caret(0)
        #expect(editor.tinted() == [])
        await editor.pump()
        #expect(editor.tinted() == [])
    }

    // MARK: - VH2: the word tint follows scrolling

    @Test func wordTintFollowsScrolling() async throws {
        let text = String(repeating: "alpha beta gamma\n\n", count: 1500)
        let editor = try Editor(text, fileName: "sample.txt")
        defer { editor.close() }
        await editor.settle()
        let length = editor.ns.length
        let lastAlpha = editor.ns.range(of: "alpha", options: .backwards).location

        editor.caret(2)
        editor.textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        await editor.waitForWordScan()
        #expect(editor.background(at: 0) != nil)
        #expect(editor.background(at: lastAlpha) == nil)

        editor.textView.scrollRangeToVisible(NSRange(location: length, length: 0))
        await editor.waitForWordScan()
        #expect(editor.background(at: lastAlpha) != nil)
        #expect(editor.background(at: 0) == nil)

        // A caret in whitespace (an empty line) paints nothing, scrolled or not.
        editor.textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        editor.caret(17)
        await editor.waitForWordScan()
        #expect(editor.background(at: 18) == nil)
        editor.textView.scrollRangeToVisible(NSRange(location: length, length: 0))
        await editor.waitForWordScan()
        #expect(editor.background(at: lastAlpha) == nil)
    }

    // MARK: - VH6: `$` is a word character in JS / TS only

    @Test func dollarFollowsTheLanguage() async throws {
        let js = try Editor("$value value\n", fileName: "sample.js")
        defer { js.close() }
        await js.settle()
        js.caret(3)
        await js.waitForWordScan()
        #expect(js.background(at: 0) == nil)
        #expect(js.background(at: 7) == nil)

        for fileName in ["sample.py", "sample.txt"] {
            let other = try Editor("$value value\n", fileName: fileName)
            defer { other.close() }
            await other.settle()
            other.caret(3)
            await other.waitForWordScan()
            #expect(other.background(at: 1) != nil, "\(fileName)")
            #expect(other.background(at: 7) != nil, "\(fileName)")
            #expect(other.background(at: 0) == nil, "\(fileName)")
        }
    }
}
