import AppKit
import Testing
@testable import KaruCore

/// Regression tests for the two critical v0.8.x bugs (2026-07-22):
/// 1. Paste dead: `pasteAsPlainText` + restricted `readablePasteboardTypes`
///    silently no-ops on macOS 26 beta — paste is now implemented explicitly.
/// 2. Crash in FoldScanner: gutter draw with a transiently desynced
///    LineIndex/string pair read past the string's end — the scanner now
///    guards on length consistency.
@MainActor
struct PasteRegressionTests {
    private func makeTextView() -> EditorTextView {
        let tv = EditorTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.allowsUndo = true // matches makeEditorView's production configuration
        return tv
    }

    @Test func pasteInsertsPlainText() {
        let tv = makeTextView()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("pasted text", forType: .string)
        tv.paste(nil)
        #expect(tv.string == "pasted text")
    }

    @Test func pasteStripsRichAttributesAndKeepsEditorFont() {
        let tv = makeTextView()
        let pb = NSPasteboard.general
        pb.clearContents()
        let rich = NSAttributedString(string: "line1\nline2",
                                      attributes: [.font: NSFont.boldSystemFont(ofSize: 30)])
        pb.writeObjects([rich])
        tv.paste(nil)
        #expect(tv.string == "line1\nline2")
        let font = tv.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(font?.pointSize == 13)
    }

    @Test func pasteReplacesSelection() {
        let tv = makeTextView()
        tv.insertText("hello world", replacementRange: NSRange(location: 0, length: 0))
        tv.setSelectedRange(NSRange(location: 0, length: 5))
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("bye", forType: .string)
        tv.paste(nil)
        #expect(tv.string == "bye world")
        #expect(tv.selectedRange() == NSRange(location: 3, length: 0))
    }

    @Test func pasteIsUndoable() {
        let tv = makeTextView()
        // A bare NSTextView has no undo manager; production views get one from
        // their window, so host the view in one for the undo assertion.
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                           styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = tv
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("abc", forType: .string)
        tv.paste(nil)
        #expect(tv.string == "abc")
        tv.undoManager?.undo()
        #expect(tv.string == "")
    }
}

struct FoldScannerGuardTests {
    /// A LineIndex indexed for longer text than the string handed to the
    /// scanner (the desynced pair from the crash report) must yield an empty
    /// scan, never an out-of-range read.
    @Test func desyncedLineIndexDoesNotCrash() {
        let longText = "{\n  a\n  b\n}\nmore lines here\n{\n x\n}\n"
        let lineIndex = LineIndex(text: longText)
        let shorterText = "{\n  a\n}"
        let regions = FoldScanner.regions(text: shorterText, lineIndex: lineIndex)
        #expect(regions.isEmpty)
    }

    @Test func syncedPairStillScans() {
        let text = "{\n  a\n  b\n}\n"
        let lineIndex = LineIndex(text: text)
        let regions = FoldScanner.regions(text: text, lineIndex: lineIndex)
        #expect(!regions.isEmpty)
    }
}

@MainActor
struct LineIndexSyncStress {
    /// Simulates realistic typing (auto-close, newline auto-indent, deletes,
    /// undo/redo, IME marked text) through a full EditorWindowController stack
    /// and asserts the shared LineIndex stays byte-consistent with the storage
    /// after every single edit.
    @Test func typingKeepsLineIndexInSync() {
        let controller = EditorWindowController()
        _ = controller.window
        guard let tv = controller.window?.contentView?.firstSubviewOfType(EditorTextView.self) else {
            Issue.record("no text view"); return
        }
        let li = Mirror(reflecting: controller).children.first { $0.label == "lineIndex" }?.value as? LineIndex
        guard let lineIndex = li else { Issue.record("no lineIndex"); return }

        func check(_ step: String) {
            let ns = tv.string as NSString
            #expect(lineIndex.length == ns.length, "desync after \(step): index=\(lineIndex.length) ns=\(ns.length)")
            let last = lineIndex.offsetRange(ofLine: lineIndex.lineCount)
            #expect(last.upperBound <= ns.length, "line range past end after \(step)")
        }

        let keys: [String] = ["f", "u", "n", "c", " ", "m", "(", ")", "{", "\n",
                              "l", "e", "t", " ", "x", " ", "=", " ", "\"", "h", "i", "\"", "\n",
                              "[", "1", ",", "2", "]", "\n"]
        for k in keys {
            if k == "\n" { tv.insertNewline(nil) } else {
                tv.insertText(k, replacementRange: NSRange(location: NSNotFound, length: 0))
            }
            check("type '\(k)'")
        }
        for _ in 0..<8 { tv.deleteBackward(nil); check("backspace") }
        tv.undoManager?.undo(); check("undo")
        tv.undoManager?.undo(); check("undo2")
        tv.undoManager?.redo(); check("redo")
        tv.setMarkedText("に", selectedRange: NSRange(location: 0, length: 0),
                         replacementRange: NSRange(location: NSNotFound, length: 0)); check("marked1")
        tv.setMarkedText("にほ", selectedRange: NSRange(location: 0, length: 0),
                         replacementRange: NSRange(location: NSNotFound, length: 0)); check("marked2")
        tv.insertText("日本", replacementRange: NSRange(location: NSNotFound, length: 0)); check("commit")
    }
}

private extension NSView {
    func firstSubviewOfType<T: NSView>(_ type: T.Type) -> T? {
        for sub in subviews {
            if let hit = sub as? T { return hit }
            if let hit = sub.firstSubviewOfType(type) { return hit }
        }
        return nil
    }
}
