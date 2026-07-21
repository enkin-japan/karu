import AppKit
import Testing
@testable import KaruCore

// MARK: - Format Document chord predicate (T12.1)

@MainActor
@Test func formatChordMatchesOptionShiftF() {
    #expect(EditorTextView.isFormatDocumentChord(
        modifiers: [.option, .shift],
        charactersIgnoringModifiers: "F") == true)
}

@MainActor
@Test func formatChordRejectsWhenCommandPresent() {
    #expect(EditorTextView.isFormatDocumentChord(
        modifiers: [.option, .shift, .command],
        charactersIgnoringModifiers: "F") == false)
}

@MainActor
@Test func formatChordRejectsWithoutShift() {
    #expect(EditorTextView.isFormatDocumentChord(
        modifiers: [.option],
        charactersIgnoringModifiers: "f") == false)
}

@MainActor
@Test func formatChordRejectsWrongKey() {
    #expect(EditorTextView.isFormatDocumentChord(
        modifiers: [.option, .shift],
        charactersIgnoringModifiers: "G") == false)
}

@MainActor
@Test func formatChordMatchesUppercaseF() {
    // charactersIgnoringModifiers keeps the Shift effect, yielding "F".
    #expect(EditorTextView.isFormatDocumentChord(
        modifiers: [.option, .shift],
        charactersIgnoringModifiers: "F") == true)
}

@MainActor
@Test func formatChordRejectsWhenControlPresent() {
    #expect(EditorTextView.isFormatDocumentChord(
        modifiers: [.option, .shift, .control],
        charactersIgnoringModifiers: "f") == false)
}

@MainActor
@Test func formatChordIgnoresExtraneousDeviceFlags() {
    // Caps Lock / numeric-pad bits set alongside the real chord must not break
    // matching (they are masked out by deviceIndependentFlagsMask).
    #expect(EditorTextView.isFormatDocumentChord(
        modifiers: [.option, .shift, .capsLock],
        charactersIgnoringModifiers: "F") == true)
}

// MARK: - Line-operation chord predicate (T12.4)

private let upArrow = String(UnicodeScalar(NSUpArrowFunctionKey)!)
private let downArrow = String(UnicodeScalar(NSDownArrowFunctionKey)!)

@MainActor
@Test func lineChordOptionUpIsMoveUp() {
    #expect(EditorTextView.lineOperationChord(
        modifiers: [.option], charactersIgnoringModifiers: upArrow)
        == #selector(EditorWindowController.moveLinesUp(_:)))
}

@MainActor
@Test func lineChordOptionDownIsMoveDown() {
    #expect(EditorTextView.lineOperationChord(
        modifiers: [.option], charactersIgnoringModifiers: downArrow)
        == #selector(EditorWindowController.moveLinesDown(_:)))
}

@MainActor
@Test func lineChordOptionShiftUpIsCopyUp() {
    #expect(EditorTextView.lineOperationChord(
        modifiers: [.option, .shift], charactersIgnoringModifiers: upArrow)
        == #selector(EditorWindowController.copyLinesUp(_:)))
}

@MainActor
@Test func lineChordOptionShiftDownIsCopyDown() {
    #expect(EditorTextView.lineOperationChord(
        modifiers: [.option, .shift], charactersIgnoringModifiers: downArrow)
        == #selector(EditorWindowController.copyLinesDown(_:)))
}

@MainActor
@Test func lineChordRejectsWhenCommandPresent() {
    #expect(EditorTextView.lineOperationChord(
        modifiers: [.option, .command], charactersIgnoringModifiers: upArrow) == nil)
}

@MainActor
@Test func lineChordRejectsWhenControlPresent() {
    #expect(EditorTextView.lineOperationChord(
        modifiers: [.option, .control], charactersIgnoringModifiers: downArrow) == nil)
}

@MainActor
@Test func lineChordRejectsWithoutOption() {
    #expect(EditorTextView.lineOperationChord(
        modifiers: [.shift], charactersIgnoringModifiers: upArrow) == nil)
}

@MainActor
@Test func lineChordRejectsNonArrowKey() {
    #expect(EditorTextView.lineOperationChord(
        modifiers: [.option], charactersIgnoringModifiers: "x") == nil)
}

@MainActor
@Test func lineChordIgnoresExtraneousDeviceFlags() {
    #expect(EditorTextView.lineOperationChord(
        modifiers: [.option, .capsLock], charactersIgnoringModifiers: upArrow)
        == #selector(EditorWindowController.moveLinesUp(_:)))
}
