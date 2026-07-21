import Foundation
import Testing
@testable import KaruCore

// MARK: - Space-indented documents

@Test func detectsFourSpacePython() {
    let source = """
    def outer():
        x = 1
        if x:
            y = 2
            if y:
                z = 3
        return x
    """
    let detection = IndentDetector.detect(text: source)
    #expect(detection == IndentDetector.Detection(unit: 4, usesTabs: false))
}

@Test func detectsTwoSpaceHTML() {
    let source = """
    <html>
      <body>
        <div>
          <span>hi</span>
        </div>
      </body>
    </html>
    """
    let detection = IndentDetector.detect(text: source)
    #expect(detection == IndentDetector.Detection(unit: 2, usesTabs: false))
}

@Test func detectsEightSpaceDocument() {
    let source = """
    top
            level1
                    level2
                            level3
    back
            level1again
    """
    let detection = IndentDetector.detect(text: source)
    #expect(detection == IndentDetector.Detection(unit: 8, usesTabs: false))
}

// MARK: - Tab-indented documents

@Test func detectsTabDocument() {
    let source = "func main() {\n\tprint(1)\n\tif true {\n\t\tprint(2)\n\t}\n}\n"
    let detection = IndentDetector.detect(text: source)
    #expect(detection == IndentDetector.Detection(unit: 1, usesTabs: true))
}

// MARK: - Mixed but four-dominant

@Test func detectsFourWhenFourDominatesMixture() {
    // Increment diffs: 4, 4, 4, 2 -> 4 wins the vote.
    let source = """
    a
        b
            c
                d
    e
      f
    """
    let detection = IndentDetector.detect(text: source)
    #expect(detection == IndentDetector.Detection(unit: 4, usesTabs: false))
}

// MARK: - Inconclusive documents fall back to nil

@Test func returnsNilForNoIndentation() {
    let source = "line one\nline two\nline three\nline four\n"
    #expect(IndentDetector.detect(text: source) == nil)
}

@Test func returnsNilForTooFewSamples() {
    // Only two increment samples (< 3), so detection abstains.
    let source = "a\n  b\n    c\n"
    #expect(IndentDetector.detect(text: source) == nil)
}

@Test func returnsNilForEmptyText() {
    #expect(IndentDetector.detect(text: "") == nil)
}

// MARK: - Markdown 4-space nested list (the reported regression)

@Test func detectsFourForMarkdownNestedList() {
    let source = """
    - top
        - nested
            - deeper
                - deepest
    - another top
        - nested again
    """
    let detection = IndentDetector.detect(text: source)
    #expect(detection == IndentDetector.Detection(unit: 4, usesTabs: false))
}

// MARK: - Blank lines don't break the increment chain

@Test func blankLinesAreIgnored() {
    let source = """
    a

        b

            c

                d
    """
    let detection = IndentDetector.detect(text: source)
    #expect(detection == IndentDetector.Detection(unit: 4, usesTabs: false))
}

// MARK: - maxLines bound

@Test func respectsMaxLinesWindow() {
    // First 3 lines have no increments; the 4-space structure only starts
    // afterwards. With maxLines = 3 nothing is sampled -> nil.
    let source = """
    x
    y
    z
    a
        b
            c
                d
    """
    #expect(IndentDetector.detect(text: source, maxLines: 3) == nil)
    #expect(IndentDetector.detect(text: source) == IndentDetector.Detection(unit: 4, usesTabs: false))
}
