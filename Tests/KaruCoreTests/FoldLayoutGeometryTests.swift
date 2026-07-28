import AppKit
import Foundation
import Testing
@testable import KaruCore

// T13.9 — folding must reflow the *following* lines' fragments, not just the
// hidden ones. User bug (2026-07-28, debug/test.json screenshots): after a
// fold the closing line stayed logically visible (gutter numbered it) but its
// text drew at the stale pre-fold position — an empty ghost row where the
// gutter number sat, content one row below (or, after fold-all, off in the
// old spot entirely, reading as "the closing bracket disappeared").

@MainActor
private func makeRig(_ text: String) -> (NSTextView, LineIndex, FoldingController) {
    let tv = NSTextView()
    tv.string = text
    let li = LineIndex(text: text)
    let fc = FoldingController(textView: tv, lineIndex: li)
    tv.layoutManager?.delegate = fc
    return (tv, li, fc)
}

@MainActor
private func fragmentRect(_ tv: NSTextView, _ li: LineIndex, line: Int) -> NSRect {
    let lm = tv.layoutManager!
    let glyph = lm.glyphIndexForCharacter(at: li.offsetRange(ofLine: line).lowerBound)
    return lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
}

@MainActor
@Test func foldPullsFollowingLinesUpward() {
    // debug/test.json shape, reduced: fold "b" (lines 2..5), closer `],` is
    // line 6 and must sit directly below the header after the fold.
    let text = "{\n  \"b\": [\n    1,\n    2,\n    3\n  ],\n  \"x\": 1\n}\n"
    let (tv, li, fc) = makeRig(text)
    tv.layoutManager!.ensureLayout(for: tv.textContainer!) // pre-fold layout at natural positions
    fc.toggleFold(atLine: 2) // region (2,5): hides lines 3-5
    tv.layoutManager!.ensureLayout(for: tv.textContainer!)

    let header = fragmentRect(tv, li, line: 2)
    let closer = fragmentRect(tv, li, line: 6)
    #expect(abs(closer.minY - header.maxY) < 0.5,
            "closer fragment must reflow to directly below the header, got header.maxY=\(header.maxY) closer.minY=\(closer.minY)")
}

@MainActor
@Test func foldAllLeavesClosingBraceDirectlyBelowHeader() {
    // Whole-document fold: `}` on the last content line must land right under
    // line 1, not stay at its pre-fold y (where it reads as "disappeared").
    let text = "{\n  \"a\": \"1\",\n  \"c\": {\n    \"x\": \"a\"\n  }\n}\n"
    let (tv, li, fc) = makeRig(text)
    tv.layoutManager!.ensureLayout(for: tv.textContainer!)
    fc.foldAll() // outer region (1,5) hides 2-5; line 6 is `}`
    tv.layoutManager!.ensureLayout(for: tv.textContainer!)

    let header = fragmentRect(tv, li, line: 1)
    let closer = fragmentRect(tv, li, line: 6)
    #expect(abs(closer.minY - header.maxY) < 0.5,
            "`}` must reflow to directly below line 1, got header.maxY=\(header.maxY) closer.minY=\(closer.minY)")
}

@MainActor
@Test func unfoldRestoresFollowingLinePositions() {
    let text = "{\n  \"b\": [\n    1,\n    2,\n    3\n  ],\n  \"x\": 1\n}\n"
    let (tv, li, fc) = makeRig(text)
    tv.layoutManager!.ensureLayout(for: tv.textContainer!)
    let before = fragmentRect(tv, li, line: 6)
    fc.toggleFold(atLine: 2)
    tv.layoutManager!.ensureLayout(for: tv.textContainer!)
    fc.toggleFold(atLine: 2) // unfold
    tv.layoutManager!.ensureLayout(for: tv.textContainer!)
    let after = fragmentRect(tv, li, line: 6)
    #expect(abs(after.minY - before.minY) < 0.5,
            "unfold must restore the closer to its natural position")
}
