import AppKit
import Foundation
import Testing
@testable import TinyEditorCore

// MARK: - Helper

/// Scans `text` with a freshly-built LineIndex, mirroring production use.
private func scan(_ text: String) -> [FoldRegion] {
    FoldScanner.regions(text: text, lineIndex: LineIndex(text: text))
}

// MARK: - Empty / trivial

@Test func foldEmptyDocument() {
    #expect(scan("") == [])
}

@Test func foldNoFoldableContent() {
    #expect(scan("let a = 1\nlet b = 2\nlet c = 3") == [])
}

// MARK: - C-style braces

@Test func foldSameLineBracesProduceNoRegion() {
    // `{}` opened and closed on one line: nothing to hide.
    #expect(scan("struct Empty {}\n") == [])
}

@Test func foldSingleBraceBlock() {
    // Line 1: header `{`, line 2: body, line 3: closing `}`.
    // Interior-only fold keeps both delimiter lines visible: hide line 2.
    let text = """
    func f() {
        body()
    }
    """
    #expect(scan(text) == [FoldRegion(startLine: 1, endLine: 2)])
}

@Test func foldAdjacentBracesNoInterior() {
    // `{` on line 1, `}` on line 2: no interior line, so no region.
    let text = "func f() {\n}"
    #expect(scan(text) == [])
}

@Test func foldNestedBraces() {
    let text = """
    class A {
        func f() {
            if x {
                y()
            }
        }
    }
    """
    // Lines (1-based):
    // 1 class A {
    // 2     func f() {
    // 3         if x {
    // 4             y()
    // 5         }
    // 6     }
    // 7 }
    // Innermost `if` (3..5) -> hide 4;  func (2..6) -> hide 3..5;  class (1..7) -> hide 2..6.
    let expected = [
        FoldRegion(startLine: 1, endLine: 6),
        FoldRegion(startLine: 2, endLine: 5),
        FoldRegion(startLine: 3, endLine: 4),
    ]
    #expect(scan(text) == expected)
}

@Test func foldBracketArrayAcrossLines() {
    let text = """
    let items = [
        1,
        2,
    ]
    """
    // `[` line 1, `]` line 4 -> hide interior lines 2..3.
    #expect(scan(text) == [FoldRegion(startLine: 1, endLine: 3)])
}

// MARK: - Python-style indentation

@Test func foldPythonDefBlock() {
    let text = """
    def f():
        a = 1
        b = 2
    x = 3
    """
    // Header line 1 ends with ':'; body lines 2..3 are deeper; line 4 falls back.
    #expect(scan(text) == [FoldRegion(startLine: 1, endLine: 3)])
}

@Test func foldPythonNestedDef() {
    let text = """
    class C:
        def m(self):
            return 1
        def n(self):
            return 2
    """
    // 1 class C:
    // 2     def m(self):
    // 3         return 1
    // 4     def n(self):
    // 5         return 2
    // class (1) -> body 2..5;  def m (2) -> 3;  def n (4) -> 5.
    let expected = [
        FoldRegion(startLine: 1, endLine: 5),
        FoldRegion(startLine: 2, endLine: 3),
        FoldRegion(startLine: 4, endLine: 5),
    ]
    #expect(scan(text) == expected)
}

@Test func foldPythonBlankLinesInsideBlockDoNotBreak() {
    let text = """
    def f():
        a = 1

        b = 2
    y = 0
    """
    // The blank line 3 must not terminate the block; it extends to line 4.
    #expect(scan(text) == [FoldRegion(startLine: 1, endLine: 4)])
}

@Test func foldPythonBlockToEndOfFileNoDedent() {
    let text = """
    def f():
        a = 1
        b = 2
    """
    // No dedent before EOF: block runs to the last content line (3).
    #expect(scan(text) == [FoldRegion(startLine: 1, endLine: 3)])
}

@Test func foldPythonColonWithNoDeeperBodyProducesNothing() {
    let text = """
    def f():
    pass
    """
    // Line 2 is not more-indented than the header, so no region.
    #expect(scan(text) == [])
}

@Test func foldPythonTrailingBlankLinesIgnored() {
    let text = "def f():\n    a = 1\n\n\n"
    // Trailing blanks don't extend the block past the last content line (2).
    #expect(scan(text) == [FoldRegion(startLine: 1, endLine: 2)])
}

// MARK: - Mixed document

@Test func foldMixedBraceAndIndent() {
    // A brace block and an indented colon block in one document.
    let text = """
    obj = {
        "a": 1,
    }
    def f():
        return obj
    """
    // 1 obj = {
    // 2     "a": 1,
    // 3 }
    // 4 def f():
    // 5     return obj
    // Brace (1..3) -> hide 2;  def (4) -> body line 5.
    // Line 2 ends with ',' (the ':' is mid-line), so the indentation rule does
    // not treat it as a colon-led header.
    let expected = [
        FoldRegion(startLine: 1, endLine: 2),
        FoldRegion(startLine: 4, endLine: 5),
    ]
    #expect(scan(text) == expected)
}

// MARK: - FoldRegion value semantics

@Test func foldRegionEquatable() {
    #expect(FoldRegion(startLine: 1, endLine: 3) == FoldRegion(startLine: 1, endLine: 3))
    #expect(FoldRegion(startLine: 1, endLine: 3) != FoldRegion(startLine: 1, endLine: 4))
}

// MARK: - FoldingController: folded-header queries (T7.3)

/// Builds a `FoldingController` over a text view holding `text`, mirroring
/// production wiring closely enough to exercise the fold-state queries.
@MainActor
private func makeController(_ text: String) -> FoldingController {
    let textView = NSTextView()
    textView.string = text
    return FoldingController(textView: textView, lineIndex: LineIndex(text: text))
}

@MainActor
@Test func foldedHeadersEmptyBeforeFolding() {
    let c = makeController("def f():\n    a = 1\n    b = 2\nx = 3\n")
    #expect(c.foldedHeaderLines() == [])
    #expect(c.hiddenLineCount(forHeader: 1) == 0)
}

@MainActor
@Test func foldingHeaderReportsHiddenCount() {
    // def block: header line 1, hidden body lines 2..3.
    let c = makeController("def f():\n    a = 1\n    b = 2\nx = 3\n")
    c.toggleFold(atLine: 1)
    #expect(c.foldedHeaderLines() == [1])
    #expect(c.hiddenLineCount(forHeader: 1) == 2)
    // A non-folded line reports nothing.
    #expect(c.hiddenLineCount(forHeader: 2) == 0)
}

@MainActor
@Test func unfoldingClearsHeaderState() {
    let c = makeController("def f():\n    a = 1\n    b = 2\nx = 3\n")
    c.toggleFold(atLine: 1)
    c.toggleFold(atLine: 1)
    #expect(c.foldedHeaderLines() == [])
    #expect(c.hiddenLineCount(forHeader: 1) == 0)
}

@MainActor
@Test func nestedFoldsReportSortedHeadersAndCounts() {
    // class A { func f() { if x { y() } } } — regions (1,6), (2,5), (3,4).
    let text = """
    class A {
        func f() {
            if x {
                y()
            }
        }
    }
    """
    let c = makeController(text)
    c.toggleFold(atLine: 2) // hides 3..5 -> 3 lines
    c.toggleFold(atLine: 1) // hides 2..6 -> 5 lines
    #expect(c.foldedHeaderLines() == [1, 2])
    #expect(c.hiddenLineCount(forHeader: 1) == 5)
    #expect(c.hiddenLineCount(forHeader: 2) == 3)
}
