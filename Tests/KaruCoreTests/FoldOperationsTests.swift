import AppKit
import Foundation
import Testing
@testable import KaruCore

// MARK: - Test rig
//
// Mirrors production wiring closely enough to exercise the folding controller
// end to end: a real NSTextView (so glyph suppression / layout actually runs),
// the shared LineIndex updated incrementally *before* folding reacts (as the
// gutter does in production), and the folding controller as the layout
// manager's delegate + a text-storage observer.

@MainActor
private final class FoldRig {
    let textView: NSTextView
    let lineIndex: LineIndex
    let folding: FoldingController

    init(_ text: String) {
        textView = NSTextView()
        textView.string = text
        lineIndex = LineIndex(text: text)
        folding = FoldingController(textView: textView, lineIndex: lineIndex)
        textView.layoutManager?.delegate = folding
    }

    /// Applies an edit through the same path production uses: mutate the storage,
    /// update the LineIndex incrementally (gutter's job, runs first), then hand
    /// the folding controller the post-edit callback.
    func edit(replace range: NSRange, with replacement: String) {
        let storage = textView.textStorage!
        let delta = (replacement as NSString).length - range.length
        storage.replaceCharacters(in: range, with: replacement)
        let edited = NSRange(location: range.location, length: (replacement as NSString).length)
        lineIndex.update(text: storage.string, editedRange: edited, changeInLength: delta)
        folding.textStorageDidProcessEditing(editedMask: .editedCharacters,
                                             editedRange: edited,
                                             changeInLength: delta,
                                             textStorage: storage)
    }

    /// Inserts `text` at `offset` (convenience for a pure insertion).
    func insert(_ text: String, at offset: Int) {
        edit(replace: NSRange(location: offset, length: 0), with: text)
    }
}

/// A nested C-style document reused by several tests. Regions (per FoldScanner):
/// (1,6), (2,5), (3,4).
private let nestedBraces = """
class A {
    func f() {
        if x {
            y()
        }
    }
}
"""

// MARK: - foldAll / unfoldAll (T12.12)

@MainActor
@Test func foldAllFoldsEveryRegion() {
    let rig = FoldRig(nestedBraces)
    rig.folding.foldAll()
    // Every header line reports as folded.
    #expect(rig.folding.foldedHeaderLines() == [1, 2, 3])
    #expect(rig.folding.foldState(atLine: 1) == .folded)
    #expect(rig.folding.foldState(atLine: 2) == .folded)
    #expect(rig.folding.foldState(atLine: 3) == .folded)
    // The union of hidden lines (2...6) is hidden; the outermost header stays visible.
    #expect(rig.folding.isLineHidden(1) == false)
    for line in 2...6 { #expect(rig.folding.isLineHidden(line) == true) }
}

@MainActor
@Test func unfoldAllClearsEverything() {
    let rig = FoldRig(nestedBraces)
    rig.folding.foldAll()
    rig.folding.unfoldAll()
    #expect(rig.folding.foldedHeaderLines() == [])
    for line in 1...7 { #expect(rig.folding.isLineHidden(line) == false) }
    #expect(rig.folding.foldState(atLine: 1) == .foldable)
}

@MainActor
@Test func foldAllOnPlainDocumentIsNoOp() {
    let rig = FoldRig("let a = 1\nlet b = 2\n")
    rig.folding.foldAll()
    #expect(rig.folding.foldedHeaderLines() == [])
}

@MainActor
@Test func unfoldAllWhenNothingFoldedIsNoOp() {
    let rig = FoldRig(nestedBraces)
    rig.folding.unfoldAll()
    #expect(rig.folding.foldedHeaderLines() == [])
}

// MARK: - foldCurrent / unfoldCurrent innermost selection (T12.12)

@MainActor
@Test func foldCurrentPicksInnermostRegion() {
    let rig = FoldRig(nestedBraces)
    // Line 4 sits inside all three regions; the innermost is (3,4).
    rig.folding.foldCurrent(atLine: 4)
    #expect(rig.folding.foldedHeaderLines() == [3])
    #expect(rig.folding.hiddenLineCount(forHeader: 3) == 1) // hides line 4 only
}

@MainActor
@Test func foldCurrentOnHeaderLineCountsAsContained() {
    let rig = FoldRig(nestedBraces)
    // Caret on header line 2: the innermost region whose span covers line 2 is
    // (2,5) itself (start == line).
    rig.folding.foldCurrent(atLine: 2)
    #expect(rig.folding.foldedHeaderLines() == [2])
}

@MainActor
@Test func foldCurrentOutsideAnyRegionIsNoOp() {
    let rig = FoldRig(nestedBraces)
    rig.folding.foldCurrent(atLine: 7) // the lone closing brace, in no region body
    #expect(rig.folding.foldedHeaderLines() == [])
}

@MainActor
@Test func unfoldCurrentPicksInnermostFolded() {
    let rig = FoldRig(nestedBraces)
    rig.folding.foldAll() // 1,2,3 all folded
    // Caret conceptually on header 3 (innermost). Unfold just it.
    rig.folding.unfoldCurrent(atLine: 3)
    #expect(rig.folding.foldedHeaderLines() == [1, 2])
}

@MainActor
@Test func unfoldCurrentWhenNothingFoldedIsNoOp() {
    let rig = FoldRig(nestedBraces)
    rig.folding.unfoldCurrent(atLine: 4)
    #expect(rig.folding.foldedHeaderLines() == [])
}

// MARK: - Persistence across edits (T12.13)

@MainActor
@Test func foldSurvivesEditBelowIt() {
    // def block: header 1, hidden body 2..3. Fold it, then edit line 4 (below).
    let rig = FoldRig("def f():\n    a = 1\n    b = 2\nx = 3\n")
    rig.folding.toggleFold(atLine: 1)
    #expect(rig.folding.foldedHeaderLines() == [1])

    // Append to line 4 ("x = 3") — well below the fold.
    let line4Start = rig.lineIndex.offsetRange(ofLine: 4).lowerBound
    rig.insert("456", at: line4Start + 1)

    // Fold unchanged: still header 1 hiding 2..3.
    #expect(rig.folding.foldedHeaderLines() == [1])
    #expect(rig.folding.hiddenLineCount(forHeader: 1) == 2)
    #expect(rig.folding.isLineHidden(2) == true)
    #expect(rig.folding.isLineHidden(3) == true)
}

@MainActor
@Test func foldShiftsWhenLinesInsertedAbove() {
    // Fold the def block (header 1, body 2..3), then insert two lines at the very
    // top so the whole block shifts down by two lines.
    let rig = FoldRig("def f():\n    a = 1\n    b = 2\nx = 3\n")
    rig.folding.toggleFold(atLine: 1)

    rig.insert("top1\ntop2\n", at: 0)

    // The block is now header 3, hidden body 4..5.
    #expect(rig.folding.foldedHeaderLines() == [3])
    #expect(rig.folding.hiddenLineCount(forHeader: 3) == 2)
    #expect(rig.folding.isLineHidden(4) == true)
    #expect(rig.folding.isLineHidden(5) == true)
    #expect(rig.folding.isLineHidden(1) == false)
    #expect(rig.folding.isLineHidden(3) == false) // header stays visible
}

@MainActor
@Test func foldAboveEditDoesNotMove() {
    // Two independent def blocks. Fold the first (header 1, body 2..3), then edit
    // the second block (below) — the first fold must not move.
    let rig = FoldRig("def f():\n    a = 1\n    b = 2\ndef g():\n    c = 3\n    d = 4\n")
    rig.folding.toggleFold(atLine: 1)
    #expect(rig.folding.foldedHeaderLines() == [1])

    // Edit inside the second block (line 5).
    let line5Start = rig.lineIndex.offsetRange(ofLine: 5).lowerBound
    rig.insert("z", at: line5Start + 4)

    #expect(rig.folding.foldedHeaderLines() == [1])
    #expect(rig.folding.hiddenLineCount(forHeader: 1) == 2)
}

@MainActor
@Test func foldDroppedWhenEditCrossesItsBoundary() {
    // Two folds. Fold both. Then delete a range that starts inside the first
    // fold's hidden body and extends past its end — the first fold intersects the
    // edit and is dropped; the second (below, shifted) survives.
    let rig = FoldRig("def f():\n    a = 1\n    b = 2\ndef g():\n    c = 3\n    d = 4\n")
    rig.folding.toggleFold(atLine: 1) // header 1, hides 2..3
    rig.folding.toggleFold(atLine: 4) // header 4, hides 5..6
    #expect(rig.folding.foldedHeaderLines() == [1, 4])

    // Delete from inside line 2 through into line 3 (crosses within fold 1's body,
    // but stays above fold 2).
    let l2 = rig.lineIndex.offsetRange(ofLine: 2).lowerBound
    let l3end = rig.lineIndex.offsetRange(ofLine: 3).lowerBound + 2
    rig.edit(replace: NSRange(location: l2 + 2, length: l3end - (l2 + 2)), with: "")

    // Fold 1 dropped; fold 2 survives (its header line shifted up).
    let headers = rig.folding.foldedHeaderLines()
    #expect(headers.count == 1)
    #expect(rig.folding.isLineHidden(1) == false) // fold 1 gone → its body visible
}

@MainActor
@Test func orphanFoldDroppedOnLazyValidationAfterHeaderBreaks() {
    // Fold the def block, then edit the *header* line so it no longer ends with a
    // colon (destroying its foldability) without touching the hidden body. The
    // offset-shift maintenance can't notice; the lazy validation on the next
    // regions() scan (via foldState) must drop it.
    let rig = FoldRig("def f():\n    a = 1\n    b = 2\nx = 3\n")
    rig.folding.toggleFold(atLine: 1)
    #expect(rig.folding.foldedHeaderLines() == [1])

    // Replace the ":" at the end of the header with a space → not foldable.
    let colon = rig.lineIndex.offsetRange(ofLine: 1).lowerBound + 7 // "def f()" is 7 chars, ':' at index 7
    rig.edit(replace: NSRange(location: colon, length: 1), with: " ")

    // Force a rescan + validation (foldState triggers regions()).
    _ = rig.folding.foldState(atLine: 1)
    #expect(rig.folding.foldedHeaderLines() == [])
    #expect(rig.folding.isLineHidden(2) == false)
}

@MainActor
@Test func multipleFoldsMixedSurviveAndDrop() {
    // Three def blocks; fold all three, then insert lines above the second block.
    // The first stays put, the second and third shift down together.
    let text = """
    def a():
        x = 1
    def b():
        y = 2
    def c():
        z = 3
    """
    let rig = FoldRig(text)
    rig.folding.toggleFold(atLine: 1) // hides 2
    rig.folding.toggleFold(atLine: 3) // hides 4
    rig.folding.toggleFold(atLine: 5) // hides 6
    #expect(rig.folding.foldedHeaderLines() == [1, 3, 5])

    // Insert a blank line just before "def b()" (start of line 3).
    let line3Start = rig.lineIndex.offsetRange(ofLine: 3).lowerBound
    rig.insert("\n", at: line3Start)

    // Fold 1 unchanged (header 1), folds 2 & 3 shift down by one line (4, 6).
    #expect(rig.folding.foldedHeaderLines() == [1, 4, 6])
    #expect(rig.folding.isLineHidden(2) == true) // fold 1 body
    #expect(rig.folding.isLineHidden(5) == true) // fold 2 body (was 4)
    #expect(rig.folding.isLineHidden(7) == true) // fold 3 body (was 6)
}

// MARK: - Performance smoke (not a strict timing assertion)

@MainActor
@Test func foldAllThenManyEditsCompletesQuickly() {
    // 2000 lines of nested-ish brace blocks, fold-all, then 50 insertions.
    var lines: [String] = []
    for i in 0..<500 {
        lines.append("func f\(i)() {")
        lines.append("    body()")
        lines.append("    more()")
        lines.append("}")
    }
    let rig = FoldRig(lines.joined(separator: "\n"))
    rig.folding.foldAll()
    #expect(!rig.folding.foldedHeaderLines().isEmpty)

    // 50 insertions near the end of the document (below most folds).
    let tail = (rig.textView.string as NSString).length
    for _ in 0..<50 {
        rig.insert("x", at: tail)
    }
    // Folds still present and queries answer (correctness under load).
    #expect(!rig.folding.foldedHeaderLines().isEmpty)
    _ = rig.folding.isLineHidden(3)
}
