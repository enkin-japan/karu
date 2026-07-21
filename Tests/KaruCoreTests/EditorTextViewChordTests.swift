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
