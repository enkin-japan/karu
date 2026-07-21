import Foundation
import Testing
@testable import KaruCore

// MARK: - Helpers

/// Applies a raw NSString replacement, returning the new text plus the
/// `editedRange` (new coords) and length delta an `NSTextStorage` would report.
private func applyEdit(_ text: String,
                       range: NSRange,
                       replacement: String) -> (text: String, editedRange: NSRange, delta: Int) {
    let mutable = NSMutableString(string: text)
    mutable.replaceCharacters(in: range, with: replacement)
    let replLen = (replacement as NSString).length
    let delta = replLen - range.length
    let editedRange = NSRange(location: range.location, length: replLen)
    return (mutable as String, editedRange, delta)
}

/// Asserts that incrementally updating `index` matches a full rebuild.
private func expectMatchesRebuild(_ index: LineIndex, _ text: String) {
    let fresh = LineIndex(text: text)
    #expect(index.starts == fresh.starts)
    #expect(index.lineCount == fresh.lineCount)
    #expect(index.length == fresh.length)
}

// MARK: - LineIndex: full build

@Test func lineIndexEmptyText() {
    let index = LineIndex(text: "")
    #expect(index.starts == [0])
    #expect(index.lineCount == 1)
    #expect(index.lineNumber(forOffset: 0) == 1)
    #expect(index.offsetRange(ofLine: 1) == 0..<0)
}

@Test func lineIndexNoTrailingNewline() {
    let index = LineIndex(text: "abc\ndef")
    #expect(index.starts == [0, 4])
    #expect(index.lineCount == 2)
    #expect(index.offsetRange(ofLine: 1) == 0..<4)
    #expect(index.offsetRange(ofLine: 2) == 4..<7)
}

@Test func lineIndexTrailingNewlineMakesEmptyLastLine() {
    let index = LineIndex(text: "abc\n")
    #expect(index.starts == [0, 4])
    #expect(index.lineCount == 2)
    #expect(index.offsetRange(ofLine: 2) == 4..<4) // empty final line
}

@Test func lineIndexConsecutiveBlankLines() {
    // "a\n\n\nb" -> lines: "a", "", "", "b"
    let index = LineIndex(text: "a\n\n\nb")
    #expect(index.starts == [0, 2, 3, 4])
    #expect(index.lineCount == 4)
    #expect(index.offsetRange(ofLine: 2) == 2..<3)
    #expect(index.offsetRange(ofLine: 3) == 3..<4)
}

// MARK: - LineIndex: lineNumber boundaries

@Test func lineIndexLineNumberBoundaries() {
    let text = "ab\ncd\nef"
    let index = LineIndex(text: text)
    // starts = [0, 3, 6]
    #expect(index.lineNumber(forOffset: 0) == 1)   // start of line 1
    #expect(index.lineNumber(forOffset: 2) == 1)   // end of line 1 content
    #expect(index.lineNumber(forOffset: 3) == 2)   // start of line 2
    #expect(index.lineNumber(forOffset: 5) == 2)   // just before newline
    #expect(index.lineNumber(forOffset: 6) == 3)   // start of line 3
    #expect(index.lineNumber(forOffset: 8) == 3)   // end of document
    // Out of range clamps.
    #expect(index.lineNumber(forOffset: -5) == 1)
    #expect(index.lineNumber(forOffset: 999) == 3)
}

@Test func lineIndexOutOfRangeLineNumber() {
    let index = LineIndex(text: "a\nb")
    #expect(index.offsetRange(ofLine: 0) == 0..<0)
    #expect(index.offsetRange(ofLine: 3) == 0..<0)
}

// MARK: - LineIndex: incremental updates

@Test func lineIndexInsertMultilineInMiddle() {
    let original = "line1\nline2\nline3"
    let index = LineIndex(text: original)
    // Insert two extra lines after "line2\n" (offset 12).
    let edit = applyEdit(original, range: NSRange(location: 12, length: 0), replacement: "X\nY\n")
    index.update(text: edit.text, editedRange: edit.editedRange, changeInLength: edit.delta)
    expectMatchesRebuild(index, edit.text)
}

@Test func lineIndexInsertMultilineAtLineStart() {
    let original = "aaa\nbbb\nccc"
    let index = LineIndex(text: original)
    // Insert at the very start of line 2 (offset 4).
    let edit = applyEdit(original, range: NSRange(location: 4, length: 0), replacement: "one\ntwo\n")
    index.update(text: edit.text, editedRange: edit.editedRange, changeInLength: edit.delta)
    expectMatchesRebuild(index, edit.text)
}

@Test func lineIndexDeleteAcrossLines() {
    let original = "a\nb\nc\nd\ne"
    let index = LineIndex(text: original)
    // Delete "b\nc\n" (range 2..<6).
    let edit = applyEdit(original, range: NSRange(location: 2, length: 4), replacement: "")
    index.update(text: edit.text, editedRange: edit.editedRange, changeInLength: edit.delta)
    expectMatchesRebuild(index, edit.text)
}

@Test func lineIndexDeleteSingleNewline() {
    let original = "a\nb\nc\nd"
    let index = LineIndex(text: original)
    // Delete the newline at offset 3, joining lines 2 and 3.
    let edit = applyEdit(original, range: NSRange(location: 3, length: 1), replacement: "")
    index.update(text: edit.text, editedRange: edit.editedRange, changeInLength: edit.delta)
    expectMatchesRebuild(index, edit.text)
}

@Test func lineIndexReplaceSpanningLines() {
    let original = "one\ntwo\nthree\nfour"
    let index = LineIndex(text: original)
    // Replace "two\nthree" (range 4..<13) with "TWO\n\nX".
    let edit = applyEdit(original, range: NSRange(location: 4, length: 9), replacement: "TWO\n\nX")
    index.update(text: edit.text, editedRange: edit.editedRange, changeInLength: edit.delta)
    expectMatchesRebuild(index, edit.text)
}

@Test func lineIndexInsertAtEndAndStart() {
    let original = "x\ny"
    let index = LineIndex(text: original)

    // Append a trailing newline (at end of document).
    var edit = applyEdit(original, range: NSRange(location: 3, length: 0), replacement: "\nz")
    index.update(text: edit.text, editedRange: edit.editedRange, changeInLength: edit.delta)
    expectMatchesRebuild(index, edit.text)

    // Now prepend at offset 0.
    let current = edit.text
    edit = applyEdit(current, range: NSRange(location: 0, length: 0), replacement: "start\n")
    index.update(text: edit.text, editedRange: edit.editedRange, changeInLength: edit.delta)
    expectMatchesRebuild(index, edit.text)
}

@Test func lineIndexDeleteEverything() {
    let original = "a\nb\nc\n"
    let index = LineIndex(text: original)
    let edit = applyEdit(original, range: NSRange(location: 0, length: (original as NSString).length), replacement: "")
    index.update(text: edit.text, editedRange: edit.editedRange, changeInLength: edit.delta)
    expectMatchesRebuild(index, edit.text)
    #expect(index.starts == [0])
}

// MARK: - LineIndex: randomised incremental vs rebuild

@Test func lineIndexRandomEditsMatchRebuild() {
    var rng = SystemRandomNumberGenerator()
    let alphabet = Array("ab\n \tXY\n")

    for _ in 0..<12 {
        var text = "the\nquick\nbrown\nfox\n"
        let index = LineIndex(text: text)

        for _ in 0..<60 {
            let ns = text as NSString
            let len = ns.length
            let loc = len == 0 ? 0 : Int.random(in: 0...len, using: &rng)
            let maxDel = len - loc
            let delLen = maxDel == 0 ? 0 : Int.random(in: 0...maxDel, using: &rng)

            // Random replacement of 0-4 characters.
            let replCount = Int.random(in: 0...4, using: &rng)
            var repl = ""
            for _ in 0..<replCount {
                repl.append(alphabet[Int.random(in: 0..<alphabet.count, using: &rng)])
            }

            let edit = applyEdit(text, range: NSRange(location: loc, length: delLen), replacement: repl)
            index.update(text: edit.text, editedRange: edit.editedRange, changeInLength: edit.delta)
            text = edit.text

            let fresh = LineIndex(text: text)
            #expect(index.starts == fresh.starts)
        }
    }
}

// MARK: - IndentRainbow.blocks

private func levels(_ blocks: [IndentRainbow.Block]) -> [Int] { blocks.map(\.level) }
private func ranges(_ blocks: [IndentRainbow.Block]) -> [Range<Int>] { blocks.map(\.columnRange) }

@Test func indentRainbowNoIndent() {
    #expect(IndentRainbow.blocks(forLine: "hello", indentWidth: 4).isEmpty)
    #expect(IndentRainbow.blocks(forLine: "", indentWidth: 4).isEmpty)
}

@Test func indentRainbowPureSpacesWidth2() {
    // 4 spaces at width 2 -> two levels of 2.
    let blocks = IndentRainbow.blocks(forLine: "    x", indentWidth: 2)
    #expect(levels(blocks) == [0, 1])
    #expect(ranges(blocks) == [0..<2, 2..<4])
}

@Test func indentRainbowPureSpacesWidth4() {
    // 8 spaces at width 4 -> two levels of 4.
    let blocks = IndentRainbow.blocks(forLine: "        y", indentWidth: 4)
    #expect(levels(blocks) == [0, 1])
    #expect(ranges(blocks) == [0..<4, 4..<8])
}

@Test func indentRainbowTabAndSpaceMixed() {
    // tab, then 2 spaces, then content at width 4.
    // tab = level 0 (one column); remaining 2 spaces = partial level 1.
    let blocks = IndentRainbow.blocks(forLine: "\t  z", indentWidth: 4)
    #expect(levels(blocks) == [0, 1])
    #expect(ranges(blocks) == [0..<1, 1..<3])
}

@Test func indentRainbowTabsCountOneLevelEach() {
    let blocks = IndentRainbow.blocks(forLine: "\t\tz", indentWidth: 4)
    #expect(levels(blocks) == [0, 1])
    #expect(ranges(blocks) == [0..<1, 1..<2])
}

@Test func indentRainbowRemainderSpaces() {
    // 6 spaces at width 4 -> one full level (4) + remainder (2).
    let blocks = IndentRainbow.blocks(forLine: "      z", indentWidth: 4)
    #expect(levels(blocks) == [0, 1])
    #expect(ranges(blocks) == [0..<4, 4..<6])
}

@Test func indentRainbowSubUnitRemainderOnly() {
    // 3 spaces at width 4 -> a single partial block.
    let blocks = IndentRainbow.blocks(forLine: "   z", indentWidth: 4)
    #expect(levels(blocks) == [0])
    #expect(ranges(blocks) == [0..<3])
}

@Test func indentRainbowSpacesThenTab() {
    // 2 spaces (partial) then a tab, width 4.
    let blocks = IndentRainbow.blocks(forLine: "  \tz", indentWidth: 4)
    #expect(levels(blocks) == [0, 1])
    #expect(ranges(blocks) == [0..<2, 2..<3])
}
