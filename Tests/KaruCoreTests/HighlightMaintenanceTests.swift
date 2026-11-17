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
}
