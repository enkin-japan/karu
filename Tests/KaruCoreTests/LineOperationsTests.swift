import Foundation
import Testing
@testable import KaruCore

private func applied(
    _ text: String,
    _ op: (String, NSRange) -> (replacement: String, range: NSRange, newSelection: NSRange)?,
    selection: NSRange
) -> (string: String, selection: NSRange)? {
    guard let r = op(text, selection) else { return nil }
    let ns = NSMutableString(string: text)
    ns.replaceCharacters(in: r.range, with: r.replacement)
    return (ns as String, r.newSelection)
}

// MARK: - Move lines

@Test func moveLineUpSwapsWithPrevious() {
    let result = applied("a\nb\nc\n", LineOperations.moveLinesUp,
                         selection: NSRange(location: 2, length: 0)) // on "b"
    #expect(result?.string == "b\na\nc\n")
}

@Test func moveLineUpAtTopIsNoOp() {
    #expect(LineOperations.moveLinesUp(text: "a\nb\n",
                                       selection: NSRange(location: 0, length: 0)) == nil)
}

@Test func moveLineDownSwapsWithNext() {
    let result = applied("a\nb\nc\n", LineOperations.moveLinesDown,
                         selection: NSRange(location: 0, length: 0)) // on "a"
    #expect(result?.string == "b\na\nc\n")
}

@Test func moveLineDownAtBottomIsNoOp() {
    // Caret on the final "c" (no trailing newline): nothing below to swap with.
    #expect(LineOperations.moveLinesDown(text: "a\nb\nc",
                                         selection: NSRange(location: 4, length: 0)) == nil)
}

@Test func moveLineUpPreservesMissingFinalNewline() {
    // Last line has no terminator; after moving it up the newline structure must
    // stay valid (the line that becomes last loses its terminator).
    let result = applied("a\nb\nc", LineOperations.moveLinesUp,
                         selection: NSRange(location: 4, length: 0)) // on "c"
    #expect(result?.string == "a\nc\nb")
}

@Test func moveLinesUpKeepsSelectionOnMovedBlock() {
    // Select lines "b" and "c"; move up → block sits on the first two lines.
    let result = applied("a\nb\nc\nd\n", LineOperations.moveLinesUp,
                         selection: NSRange(location: 2, length: 3)) // spans b + c
    #expect(result?.string == "b\nc\na\nd\n")
    #expect(result?.selection == NSRange(location: 0, length: 4)) // "b\nc\n"
}

// MARK: - Copy lines

@Test func copyLineDownDuplicatesBelow() {
    let result = applied("a\nb\n", LineOperations.copyLinesDown,
                         selection: NSRange(location: 0, length: 0)) // "a"
    #expect(result?.string == "a\na\nb\n")
    #expect(result?.selection == NSRange(location: 2, length: 2)) // the copy
}

@Test func copyLineUpDuplicatesAbove() {
    let result = applied("a\nb\n", LineOperations.copyLinesUp,
                         selection: NSRange(location: 2, length: 0)) // "b"
    #expect(result?.string == "a\nb\nb\n")
    #expect(result?.selection == NSRange(location: 2, length: 2)) // the new copy
}

@Test func copyLineDownOnLastLineWithoutNewline() {
    let result = applied("a\nb", LineOperations.copyLinesDown,
                         selection: NSRange(location: 2, length: 0)) // "b", no newline
    #expect(result?.string == "a\nb\nb")
}

@Test func copyLineUpOnLastLineWithoutNewline() {
    let result = applied("a\nb", LineOperations.copyLinesUp,
                         selection: NSRange(location: 2, length: 0)) // "b", no newline
    #expect(result?.string == "a\nb\nb")
}

// MARK: - Delete lines

@Test func deleteLineRemovesMiddleLine() {
    let result = applied("a\nb\nc\n", LineOperations.deleteLines,
                         selection: NSRange(location: 2, length: 0)) // "b"
    #expect(result?.string == "a\nc\n")
}

@Test func deleteLastLineDropsPrecedingNewline() {
    let result = applied("a\nb\nc", LineOperations.deleteLines,
                         selection: NSRange(location: 4, length: 0)) // "c", no newline
    #expect(result?.string == "a\nb")
}

@Test func deleteLineCaretLandsAtOriginalColumn() {
    // Caret at column 1 on "bb"; after deleting it, the shifted-up "cc" gets the
    // caret at column 1.
    let result = applied("aa\nbb\ncc\n", LineOperations.deleteLines,
                         selection: NSRange(location: 4, length: 0)) // column 1 of "bb"
    #expect(result?.string == "aa\ncc\n")
    #expect(result?.selection == NSRange(location: 4, length: 0)) // column 1 of "cc"
}

@Test func deleteLineClampsColumnToShorterLine() {
    // Caret at column 2 of "bbb"; the line below ("c") is shorter, so the caret
    // clamps to that line's end.
    let result = applied("bbb\nc\n", LineOperations.deleteLines,
                         selection: NSRange(location: 2, length: 0)) // column 2 of "bbb"
    #expect(result?.string == "c\n")
    #expect(result?.selection == NSRange(location: 1, length: 0)) // end of "c"
}

@Test func deleteLinesSpanningSelection() {
    let result = applied("a\nb\nc\nd\n", LineOperations.deleteLines,
                         selection: NSRange(location: 0, length: 3)) // a + b
    #expect(result?.string == "c\nd\n")
}
