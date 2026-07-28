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

// MARK: - Fold ⌘K prefix chord state machine (T12.12)

private let escape = "\u{1B}"

@MainActor
@Test func chordCommandKArmsPrefix() {
    #expect(EditorTextView.chordStep(
        prefixActive: false, modifiers: [.command], charactersIgnoringModifiers: "k") == .enterPrefix)
}

@MainActor
@Test func chordCommandKUppercaseAlsoArms() {
    // charactersIgnoringModifiers is lowercased before comparison.
    #expect(EditorTextView.chordStep(
        prefixActive: false, modifiers: [.command], charactersIgnoringModifiers: "K") == .enterPrefix)
}

@MainActor
@Test func chordCommandShiftKDoesNotArm() {
    // ⌘⇧K is Delete Line — must not be swallowed as a fold prefix.
    #expect(EditorTextView.chordStep(
        prefixActive: false, modifiers: [.command, .shift], charactersIgnoringModifiers: "K") == .cancelAndHandle)
}

@MainActor
@Test func chordCommandOptionKDoesNotArm() {
    #expect(EditorTextView.chordStep(
        prefixActive: false, modifiers: [.command, .option], charactersIgnoringModifiers: "k") == .cancelAndHandle)
}

@MainActor
@Test func chordPlainKeyWithoutPrefixIsHandled() {
    #expect(EditorTextView.chordStep(
        prefixActive: false, modifiers: [], charactersIgnoringModifiers: "a") == .cancelAndHandle)
}

@MainActor
@Test func chordPrefixCommandZeroFoldsAll() {
    #expect(EditorTextView.chordStep(
        prefixActive: true, modifiers: [.command], charactersIgnoringModifiers: "0") == .foldAll)
}

@MainActor
@Test func chordPrefixCommandJUnfoldsAll() {
    #expect(EditorTextView.chordStep(
        prefixActive: true, modifiers: [.command], charactersIgnoringModifiers: "j") == .unfoldAll)
}

@MainActor
@Test func chordPrefixEscapeCancelsAndSwallows() {
    #expect(EditorTextView.chordStep(
        prefixActive: true, modifiers: [], charactersIgnoringModifiers: escape) == .cancelAndSwallow)
}

@MainActor
@Test func chordPrefixOtherKeyCancelsAndHandles() {
    // Any non-chord key while armed exits the prefix and is handled normally.
    #expect(EditorTextView.chordStep(
        prefixActive: true, modifiers: [.command], charactersIgnoringModifiers: "x") == .cancelAndHandle)
    #expect(EditorTextView.chordStep(
        prefixActive: true, modifiers: [], charactersIgnoringModifiers: "0") == .cancelAndHandle)
}

@MainActor
@Test func chordPrefixCommandZeroIgnoresExtraneousDeviceFlags() {
    #expect(EditorTextView.chordStep(
        prefixActive: true, modifiers: [.command, .capsLock], charactersIgnoringModifiers: "0") == .foldAll)
}

@MainActor
@Test func chordPrefixCommandShiftZeroIsNotFoldAll() {
    // Requires a clean ⌘ (no Shift) — ⌘⇧0 falls through to normal handling.
    #expect(EditorTextView.chordStep(
        prefixActive: true, modifiers: [.command, .shift], charactersIgnoringModifiers: "0") == .cancelAndHandle)
}

// MARK: - ⌘⏎ insert-line-below chord

@Test func insertLineBelowChordMatchesCommandReturn() {
    #expect(EditorTextView.isInsertLineBelowChord(
        modifiers: [.command], charactersIgnoringModifiers: "\r"))
}

@Test func insertLineBelowChordMatchesKeypadEnter() {
    #expect(EditorTextView.isInsertLineBelowChord(
        modifiers: [.command], charactersIgnoringModifiers: "\u{3}"))
}

@Test func insertLineBelowChordRejectsExtraModifiers() {
    #expect(!EditorTextView.isInsertLineBelowChord(
        modifiers: [.command, .shift], charactersIgnoringModifiers: "\r"))
    #expect(!EditorTextView.isInsertLineBelowChord(
        modifiers: [.command, .option], charactersIgnoringModifiers: "\r"))
    #expect(!EditorTextView.isInsertLineBelowChord(
        modifiers: [], charactersIgnoringModifiers: "\r"))
}

@Test func insertLineBelowChordRejectsOtherKeys() {
    #expect(!EditorTextView.isInsertLineBelowChord(
        modifiers: [.command], charactersIgnoringModifiers: "a"))
}

// MARK: - ⌘K chord vs menu key equivalents (T13.8 regression)
//
// ⌘0 doubles as View ▸ Actual Size's menu equivalent, and menus match during
// the key-equivalent pass — before keyDown. The chord must therefore consume
// its ⌘-bearing steps in `performKeyEquivalent`, or the armed prefix's ⌘0 is
// eaten by the menu and the chord never completes (user bug, 2026-07-28).

@MainActor
private func makeKeyEvent(_ chars: String, modifiers: NSEvent.ModifierFlags) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                     timestamp: 0, windowNumber: 0, context: nil,
                     characters: chars, charactersIgnoringModifiers: chars,
                     isARepeat: false, keyCode: 0)!
}

@MainActor
private func makeFocusedEditor() -> (NSWindow, EditorTextView) {
    let tv = EditorTextView()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView?.addSubview(tv)
    window.makeFirstResponder(tv)
    return (window, tv)
}

@MainActor
@Test func performKeyEquivalentConsumesFoldChordBeforeMenu() {
    let (window, tv) = makeFocusedEditor()
    defer { window.orderOut(nil) }
    // ⌘K arms the prefix and is consumed; the armed ⌘0 is consumed too (it must
    // never reach the menu's Actual Size binding).
    #expect(tv.performKeyEquivalent(with: makeKeyEvent("k", modifiers: .command)) == true)
    #expect(tv.performKeyEquivalent(with: makeKeyEvent("0", modifiers: .command)) == true)
}

@MainActor
@Test func performKeyEquivalentWithoutPrefixLetsCommandZeroThrough() {
    let (window, tv) = makeFocusedEditor()
    defer { window.orderOut(nil) }
    // No prefix armed: ⌘0 falls through so View ▸ Actual Size keeps working.
    #expect(tv.performKeyEquivalent(with: makeKeyEvent("0", modifiers: .command)) == false)
    // Ordinary shortcuts pass through untouched as well.
    #expect(tv.performKeyEquivalent(with: makeKeyEvent("s", modifiers: .command)) == false)
}

@MainActor
@Test func performKeyEquivalentIgnoresChordWhenEditorNotFocused() {
    let (window, tv) = makeFocusedEditor()
    defer { window.orderOut(nil) }
    window.makeFirstResponder(nil)
    // A ⌘K typed while another control has focus must not arm the prefix.
    #expect(tv.performKeyEquivalent(with: makeKeyEvent("k", modifiers: .command)) == false)
}
