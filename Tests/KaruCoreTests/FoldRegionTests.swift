import AppKit
import Foundation
import Testing
@testable import KaruCore

// MARK: - Helper

/// Scans `text` with a freshly-built LineIndex, mirroring production use.
private func scan(_ text: String) -> [FoldRegion] {
    FoldScanner.regions(text: text, lineIndex: LineIndex(text: text))
}

/// Same, but under the markdown rule set (T13.4).
private func scanMarkdown(_ text: String) -> [FoldRegion] {
    FoldScanner.regions(text: text, lineIndex: LineIndex(text: text), language: "markdown")
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

// MARK: - Indent regions stop before closing lines (T13.2)

@Test func foldIndentRegionStopsBeforeClosingBracketLine() {
    // The `]` on line 4 is more deeply indented than the `def` header, but it
    // closes the bracket block — the bracket rule keeps it visible, so the
    // indent rule must not swallow it either.
    let text = "def f():\n    return [\n        1,\n    ]\n"
    // Indent region (1,3), bracket region (2,3).
    let expected = [
        FoldRegion(startLine: 1, endLine: 3),
        FoldRegion(startLine: 2, endLine: 3),
    ]
    #expect(scan(text) == expected)
}

@Test func foldIndentRegionShrinksOverMultipleClosingLines() {
    // A run of closing lines at the tail is shrunk away entirely.
    let text = "def f():\n    x = g(\n        [\n            1,\n        ],\n    )\n"
    // 1 def f():
    // 2     x = g(
    // 3         [
    // 4             1,
    // 5         ],
    // 6     )
    // Lines 5 and 6 are pure closers -> the indent region ends at line 4.
    #expect(scan(text).contains(FoldRegion(startLine: 1, endLine: 4)))
    #expect(!scan(text).contains(FoldRegion(startLine: 1, endLine: 6)))
}

@Test func foldIndentRegionDegeneratesToNothing() {
    // The only "body" line is a closer, so the region collapses and is dropped.
    #expect(scan("key:\n    }\n") == [])
}

@Test func foldClosingLineDetectionBoundaries() {
    // `]` / `],` / `});` count as pure closing lines...
    #expect(scan("key:\n    a\n    ]\n") == [FoldRegion(startLine: 1, endLine: 2)])
    #expect(scan("key:\n    a\n    ],\n") == [FoldRegion(startLine: 1, endLine: 2)])
    #expect(scan("key:\n    a\n    });\n") == [FoldRegion(startLine: 1, endLine: 2)])
    // ...but anything else on the line does not.
    #expect(scan("key:\n    a\n    ], # comment\n") == [FoldRegion(startLine: 1, endLine: 3)])
    #expect(scan("key:\n    a\n    a]\n") == [FoldRegion(startLine: 1, endLine: 3)])
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

// MARK: - Markdown rules (T13.4)

@Test func markdownHeadingSectionsNest() {
    // 1 # A     -> section runs to the line before the next level-1 heading (4)
    // 2 text
    // 3 ## B    -> deeper heading also stops at "# C" (4)
    // 4 text
    // 5 # C     -> no following heading: to the document's last content line
    // 6 text
    let expected = [
        FoldRegion(startLine: 1, endLine: 4),
        FoldRegion(startLine: 3, endLine: 4),
        FoldRegion(startLine: 5, endLine: 6),
    ]
    #expect(scanMarkdown("# A\ntext\n## B\ntext\n# C\ntext\n") == expected)
}

@Test func markdownHeadingWithNoBodyProducesNoRegion() {
    // Two headings back to back: the first has nothing to hide.
    #expect(scanMarkdown("# A\n# B\nbody\n") == [FoldRegion(startLine: 2, endLine: 3)])
}

@Test func markdownDeeperHeadingDoesNotCloseShallowerOne() {
    // "### C" is deeper than "## B", so B's section swallows it and both run to
    // the end of the document.
    let expected = [
        FoldRegion(startLine: 1, endLine: 4),
        FoldRegion(startLine: 3, endLine: 4),
    ]
    #expect(scanMarkdown("## B\ntext\n### C\ntext\n") == expected)
}

@Test func markdownNonHeadingHashLinesIgnored() {
    // No space after the hashes / more than six of them / four-space indent.
    #expect(scanMarkdown("#NoSpace\ntext\n") == [])
    #expect(scanMarkdown("####### seven\ntext\n") == [])
    #expect(scanMarkdown("    # indented code\ntext\n") == [])
    // Up to three leading spaces still counts (CommonMark).
    #expect(scanMarkdown("  # A\ntext\n") == [FoldRegion(startLine: 1, endLine: 2)])
}

@Test func markdownFencedBlockKeepsClosingFenceVisible() {
    // 1 # T
    // 2 ```swift   <- opener (info string allowed)
    // 3 code
    // 4 code
    // 5 ```        <- closer stays visible
    let regions = scanMarkdown("# T\n```swift\ncode\ncode\n```\n")
    #expect(regions.contains(FoldRegion(startLine: 2, endLine: 4)))
    #expect(!regions.contains(FoldRegion(startLine: 2, endLine: 5)))
}

@Test func markdownTildeFenceWorksTheSameWay() {
    #expect(scanMarkdown("~~~\ncode\ncode\n~~~\n").contains(FoldRegion(startLine: 1, endLine: 3)))
}

@Test func markdownHeadingInsideFenceIsNotASection() {
    // The `# not a heading` line lives inside the code block: only the fence
    // region exists, and the real heading's section covers the whole fence.
    let expected = [
        FoldRegion(startLine: 1, endLine: 5),
        FoldRegion(startLine: 2, endLine: 4),
    ]
    #expect(scanMarkdown("# T\n```sh\n# not a heading\necho hi\n```\n") == expected)
}

@Test func markdownOtherFenceCharInsideFenceIsContent() {
    // 1 ```
    // 2 ~~~     <- ordinary content, does not open a fence
    // 3 ~~~
    // 4 ```     <- the only closer
    // A single region (1,3); nothing starts on line 2.
    #expect(scanMarkdown("```\n~~~\n~~~\n```\n") == [FoldRegion(startLine: 1, endLine: 3)])
}

@Test func markdownFenceNeedsAtLeastAsManyClosingChars() {
    // A three-backtick line cannot close a four-backtick fence.
    // 1 ````
    // 2 ```
    // 3 text
    // 4 ````
    #expect(scanMarkdown("````\n```\ntext\n````\n") == [FoldRegion(startLine: 1, endLine: 3)])
}

@Test func markdownUnclosedFenceRunsToEndOfDocument() {
    // No closing fence: fold everything below the opener (trailing blank line
    // aside).
    #expect(scanMarkdown("```swift\ncode\nmore\n") == [FoldRegion(startLine: 1, endLine: 3)])
}

@Test func markdownIgnoresBracketAndColonRules() {
    // Links and a prose colon: the generic rules would fire, markdown must not.
    #expect(scanMarkdown("key:\n    [a](b)\n    [c](d)\n") == [])
    // ...while the same text under the default rules still folds.
    #expect(!scan("key:\n    [a](b)\n    [c](d)\n").isEmpty)
}

@Test func markdownSectionStopsBeforeSeparatingBlankLines() {
    // Blank lines between sections belong to neither.
    #expect(scanMarkdown("# A\ntext\n\n\n# B\nbody\n")
            == [FoldRegion(startLine: 1, endLine: 2), FoldRegion(startLine: 5, endLine: 6)])
}

@Test func markdownPlainProseHasNoRegions() {
    #expect(scanMarkdown("just some prose\nand more of it\n") == [])
    #expect(scanMarkdown("") == [])
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
