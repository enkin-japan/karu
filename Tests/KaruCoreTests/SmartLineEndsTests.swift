import AppKit
import Testing
@testable import KaruCore

// T14.2 — ⌘←/⌘→ go to the *logical* line's ends (soft wrap must not matter),
// with VS Code Home semantics: first non-whitespace first, column 0 on repeat.

@MainActor
@Test func smartLineStartGoesToFirstNonWhitespace() {
    let text = "    let x = 1\n"
    // Caret mid-line → first non-whitespace (offset 4).
    #expect(EditorTextView.smartLineStart(text: text, caret: 9) == 4)
}

@MainActor
@Test func smartLineStartTogglesToColumnZero() {
    let text = "    let x = 1\n"
    // Already at first non-whitespace → column 0; from column 0 → back to 4.
    #expect(EditorTextView.smartLineStart(text: text, caret: 4) == 0)
    #expect(EditorTextView.smartLineStart(text: text, caret: 0) == 4)
}

@MainActor
@Test func smartLineStartOnUnindentedLine() {
    let text = "plain\n"
    // First non-whitespace *is* column 0: both presses stay put.
    #expect(EditorTextView.smartLineStart(text: text, caret: 3) == 0)
    #expect(EditorTextView.smartLineStart(text: text, caret: 0) == 0)
}

@MainActor
@Test func smartLineEndStopsBeforeTerminator() {
    let text = "abc\ndef\n"
    #expect(EditorTextView.smartLineEnd(text: text, caret: 1) == 3)   // line 1
    #expect(EditorTextView.smartLineEnd(text: text, caret: 5) == 7)   // line 2
}

@MainActor
@Test func smartLineEndsHandleDocumentEdges() {
    #expect(EditorTextView.smartLineStart(text: "", caret: 0) == 0)
    #expect(EditorTextView.smartLineEnd(text: "", caret: 0) == 0)
    let noTerminator = "tail"
    #expect(EditorTextView.smartLineEnd(text: noTerminator, caret: 0) == 4)
    // Caret past the end clamps instead of trapping.
    #expect(EditorTextView.smartLineEnd(text: noTerminator, caret: 99) == 4)
}

@MainActor
@Test func whitespaceOnlyLineTogglesBetweenEnds() {
    let text = "    \nx\n"
    // First non-whitespace scan stops at the terminator (offset 4).
    #expect(EditorTextView.smartLineStart(text: text, caret: 2) == 4)
    #expect(EditorTextView.smartLineStart(text: text, caret: 4) == 0)
}
