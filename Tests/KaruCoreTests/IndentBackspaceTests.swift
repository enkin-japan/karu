import AppKit
import Testing
@testable import KaruCore

// T14.10 — backspace in leading spaces snaps the indent to the next lower
// multiple of the indent width (user spec: width 4, 11 → 8 → 4 → 0; 9 → 8).

@MainActor
@Test func indentBackspaceSnapsToMultiples() {
    let width = 4
    func remaining(_ spaces: Int) -> Int? {
        let text = String(repeating: " ", count: spaces) + "x\n"
        guard let r = EditorTextView.indentBackspaceRange(text: text, caret: spaces, width: width) else {
            return nil
        }
        return spaces - r.length
    }
    #expect(remaining(11) == 8)
    #expect(remaining(9) == 8)
    #expect(remaining(8) == 4)
    #expect(remaining(4) == 0)
    #expect(remaining(3) == 0)
    #expect(remaining(1) == 0)
}

@MainActor
@Test func indentBackspaceOnLaterLineUsesLineLocalColumn() {
    let text = "def f():\n        return\n"
    // Caret after the 8 leading spaces of line 2 (offset 9 + 8 = 17).
    let r = EditorTextView.indentBackspaceRange(text: text, caret: 17, width: 4)
    #expect(r == NSRange(location: 13, length: 4)) // 8 → 4, line-local
}

@MainActor
@Test func indentBackspaceDeclinesOutsideLeadingSpaces() {
    // Text before the caret → default handling.
    #expect(EditorTextView.indentBackspaceRange(text: "  ab\n", caret: 4, width: 4) == nil)
    // A tab in the prefix → default handling (tab deletes as itself).
    #expect(EditorTextView.indentBackspaceRange(text: "\t  x\n", caret: 3, width: 4) == nil)
    // Caret at line start / document start / empty text.
    #expect(EditorTextView.indentBackspaceRange(text: "  x\n  y\n", caret: 4, width: 4) == nil)
    #expect(EditorTextView.indentBackspaceRange(text: "x", caret: 0, width: 4) == nil)
    #expect(EditorTextView.indentBackspaceRange(text: "", caret: 0, width: 4) == nil)
}

@MainActor
@Test func indentBackspaceEndToEndDeletesAndIsUndoable() {
    let tv = EditorTextView()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView?.addSubview(tv)
    window.makeFirstResponder(tv)
    tv.allowsUndo = true
    tv.string = "           x\n" // 11 leading spaces
    tv.setSelectedRange(NSRange(location: 11, length: 0))
    tv.deleteBackward(nil)
    #expect(tv.string == "        x\n") // 11 → 8
    #expect(tv.selectedRange() == NSRange(location: 8, length: 0))
    tv.deleteBackward(nil)
    #expect(tv.string == "    x\n")     // 8 → 4
    // Both deletes ran in one runloop turn, so they coalesce into a single
    // undo group here (each real keypress is its own group in the app).
    tv.undoManager?.undo()
    #expect(tv.string == "           x\n")
    window.orderOut(nil)
}

