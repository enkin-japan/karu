import AppKit
import Testing
@testable import KaruCore

/// Regression tests for the "tiny font after typing `[]` at the start of an
/// empty document" bug: the auto-close insert paths used a plain-string
/// `replaceCharacters`, which has no preceding character to inherit attributes
/// from at offset 0, so the pair (and everything typed after it) fell back to
/// the layout manager's small default font. The fix inserts attributed text
/// carrying `typingAttributes`.
@MainActor
struct AutoClosePairsAttributeTests {

    private func makeTextView() -> EditorTextView {
        let tv = EditorTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.autoClosePairsEnabled = true
        return tv
    }

    @Test func insertPairAtEmptyDocumentStartKeepsEditorFont() {
        let tv = makeTextView()
        tv.insertText("[", replacementRange: NSRange(location: 0, length: 0))
        #expect(tv.string == "[]")
        let font = tv.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(font?.pointSize == 13)
    }

    @Test func wrapSelectionKeepsEditorFont() {
        let tv = makeTextView()
        tv.insertText("abc", replacementRange: NSRange(location: 0, length: 0))
        tv.setSelectedRange(NSRange(location: 0, length: 3))
        tv.insertText("(", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(tv.string == "(abc)")
        let font = tv.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(font?.pointSize == 13)
    }
}
