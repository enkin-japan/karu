import Foundation
import Testing
@testable import KaruCore

// T15.6 — the scratchpad's three-state to-do lists, as pure logic.
//
// Everything the feature does to text lives in `TodoEngine`: the state machine,
// the batch rules, where a ticked line goes, where an un-ticked one comes back
// to, how the caret follows a line that moved, and how ⏎ continues a list. The
// text view is a wrapper around these functions, so the rules are pinned here
// rather than through a panel (which is unreliable headless — see
// ScratchpadTests for that reasoning).

// MARK: - Line state recognition

@Test func todoStateRecognisesBothBoxesAndPlainProse() {
    #expect(TodoEngine.state(ofLine: "- [ ] milk") == .unchecked)
    #expect(TodoEngine.state(ofLine: "- [x] milk") == .checked)
    // The box letter is case-insensitive: some Markdown tools write "X".
    #expect(TodoEngine.state(ofLine: "- [X] milk") == .checked)
    #expect(TodoEngine.state(ofLine: "milk") == .plain)
    #expect(TodoEngine.state(ofLine: "- milk") == .plain)
    #expect(TodoEngine.state(ofLine: "") == .plain)
}

@Test func todoStateAllowsLeadingIndentAndRequiresASeparator() {
    #expect(TodoEngine.state(ofLine: "    - [ ] nested") == .unchecked)
    #expect(TodoEngine.state(ofLine: "\t- [x] nested") == .checked)
    // An empty item at the very end of a line has no trailing space yet.
    #expect(TodoEngine.state(ofLine: "- [ ]") == .unchecked)
    // ... but glued to text it is prose, not a marker.
    #expect(TodoEngine.state(ofLine: "- [x]done") == .plain)
    // Not at the start of the content: prose.
    #expect(TodoEngine.state(ofLine: "see - [ ] below") == .plain)
}

@Test func todoBoxRangeIsTheThreeCheckBoxCharacters() {
    #expect(TodoEngine.boxRange(inLine: "- [ ] milk") == NSRange(location: 2, length: 3))
    #expect(TodoEngine.boxRange(inLine: "  - [x] milk") == NSRange(location: 4, length: 3))
    #expect(TodoEngine.boxRange(inLine: "milk") == nil)
}

// MARK: - Three-state cycle: single line

@Test func cycleTakesOneLineThroughAllThreeStates() {
    let plain = "milk"
    let unchecked = TodoEngine.cycleTodo(text: plain, selection: NSRange(location: 0, length: 0))
    #expect(unchecked.text == "- [ ] milk")

    let checked = TodoEngine.cycleTodo(text: unchecked.text, selection: unchecked.selection)
    #expect(checked.text == "- [x] milk")

    let back = TodoEngine.cycleTodo(text: checked.text, selection: checked.selection)
    #expect(back.text == "milk")
}

@Test func cycleOnAnEmptyPadStartsAList() {
    let result = TodoEngine.cycleTodo(text: "", selection: NSRange(location: 0, length: 0))
    #expect(result.text == "- [ ] ")
    // The caret ends up where the first character of the item will go.
    #expect(result.selection == NSRange(location: 6, length: 0))
}

@Test func cyclePreservesIndentation() {
    let marked = TodoEngine.cycleTodo(text: "    nested", selection: NSRange(location: 0, length: 0))
    #expect(marked.text == "    - [ ] nested")
    let ticked = TodoEngine.cycleTodo(text: marked.text, selection: NSRange(location: 0, length: 0))
    #expect(ticked.text == "    - [x] nested")
    let stripped = TodoEngine.cycleTodo(text: ticked.text, selection: NSRange(location: 0, length: 0))
    #expect(stripped.text == "    nested")
}

// MARK: - Three-state cycle: batches

@Test func cycleMarksEveryLineWhenAnyOfThemIsStillPlain() {
    // One plain line in the batch means "mark them all" — including the checked
    // one, which comes back unchecked, in place.
    let text = "- [ ] a\nb\n- [x] c\n"
    let result = TodoEngine.cycleTodo(text: text, selection: NSRange(location: 0, length: 17))
    #expect(result.text == "- [ ] a\n- [ ] b\n- [ ] c\n")
}

@Test func cycleTicksAndSinksTheWholeBatchKeepingItsOrder() {
    let text = "- [ ] a\n- [ ] b\nnotes\n"
    // Select the first two lines only.
    let result = TodoEngine.cycleTodo(text: text, selection: NSRange(location: 0, length: 15))
    #expect(result.text == "notes\n- [x] a\n- [x] b\n")
}

@Test func cycleClearsAWholeBatchOfCheckedLinesInPlace() {
    let text = "- [x] a\n- [x] b\n"
    let result = TodoEngine.cycleTodo(text: text, selection: NSRange(location: 0, length: 15))
    #expect(result.text == "a\nb\n")
}

@Test func cycleIncludesAPartlySelectedLine() {
    // The selection touches the middle of both lines; both are still marked.
    let text = "alpha\nbeta\n"
    let result = TodoEngine.cycleTodo(text: text, selection: NSRange(location: 3, length: 4))
    #expect(result.text == "- [ ] alpha\n- [ ] beta\n")
}

@Test func cycleIgnoresALineTheSelectionOnlyEndsAt() {
    // Dragging down to the next line's left edge selects the lines above it,
    // not one more (the classic off-by-one line operation).
    let text = "alpha\nbeta\n"
    let result = TodoEngine.cycleTodo(text: text, selection: NSRange(location: 0, length: 6))
    #expect(result.text == "- [ ] alpha\nbeta\n")
}

@Test func cycleLeavesBlankLinesInsideASelectionAlone() {
    let text = "a\n\nb\n"
    let result = TodoEngine.cycleTodo(text: text, selection: NSRange(location: 0, length: 5))
    #expect(result.text == "- [ ] a\n\n- [ ] b\n")
}

// MARK: - Moving a ticked line

@Test func checkingSinksTheLineToTheBottomOfTheDocument() {
    let text = "- [ ] a\n- [ ] b\n- [ ] c\n"
    // Tick the middle one.
    let result = TodoEngine.cycleTodo(text: text, selection: NSRange(location: 8, length: 0))
    #expect(result.text == "- [ ] a\n- [ ] c\n- [x] b\n")
}

@Test func movingALineNeitherAddsNorSwallowsALine() {
    // A document *without* a trailing newline must not gain one, and one *with*
    // a trailing newline must keep exactly one.
    let noNewline = "- [ ] a\n- [ ] b"
    let sunk = TodoEngine.cycleTodo(text: noNewline, selection: NSRange(location: 0, length: 0))
    #expect(sunk.text == "- [ ] b\n- [x] a")

    let trailing = "- [ ] a\n- [ ] b\n"
    let sunk2 = TodoEngine.cycleTodo(text: trailing, selection: NSRange(location: 0, length: 0))
    #expect(sunk2.text == "- [ ] b\n- [x] a\n")

    // Trailing blank lines stay at the bottom rather than being jumped over.
    let blanks = "- [ ] a\nnotes\n\n"
    let sunk3 = TodoEngine.cycleTodo(text: blanks, selection: NSRange(location: 0, length: 0))
    #expect(sunk3.text == "notes\n- [x] a\n\n")
}

@Test func checkingTheLastLineLeavesItWhereItIs() {
    let text = "notes\n- [ ] a"
    let result = TodoEngine.cycleTodo(text: text, selection: NSRange(location: 6, length: 0))
    #expect(result.text == "notes\n- [x] a")
}

// MARK: - Caret following

@Test func theCaretRidesAlongWithTheLineItSitsOn() {
    let text = "- [ ] alpha\n- [ ] beta\n"
    // Caret two characters into the word: "- [ ] al|pha".
    let result = TodoEngine.cycleTodo(text: text, selection: NSRange(location: 8, length: 0))
    #expect(result.text == "- [ ] beta\n- [x] alpha\n")
    // Same offset within the line, now 11 characters further down the document.
    #expect(result.selection == NSRange(location: 19, length: 0))
}

@Test func theCaretStaysWithItsCharacterWhenAMarkerIsInserted() {
    // Caret at the start of the word: after marking it is still at the start of
    // the word, i.e. past the six-character marker.
    let result = TodoEngine.cycleTodo(text: "milk", selection: NSRange(location: 0, length: 0))
    #expect(result.selection == NSRange(location: 6, length: 0))

    // ... and mid-word it keeps its distance from the word start.
    let mid = TodoEngine.cycleTodo(text: "milk", selection: NSRange(location: 2, length: 0))
    #expect(mid.selection == NSRange(location: 8, length: 0))
}

@Test func aCaretInsideAStrippedMarkerLandsAtTheLineStart() {
    let result = TodoEngine.cycleTodo(text: "- [x] milk", selection: NSRange(location: 3, length: 0))
    #expect(result.text == "milk")
    #expect(result.selection == NSRange(location: 0, length: 0))
}

@Test func aSelectionSurvivesTheBatchItTriggered() {
    let text = "- [ ] a\n- [ ] b\nnotes\n"
    let result = TodoEngine.cycleTodo(text: text, selection: NSRange(location: 6, length: 9))
    #expect(result.text == "notes\n- [x] a\n- [x] b\n")
    // "a\n- [ ] b" → the same two offsets on the same two (moved) lines.
    let ns = result.text as NSString
    #expect(ns.substring(with: result.selection) == "a\n- [x] b")
}

// MARK: - Click-to-tick (flipChecked)

@Test func flippingAnUncheckedBoxTicksItAndSinksTheLine() {
    let text = "- [ ] a\n- [ ] b\n"
    let result = TodoEngine.flipChecked(text: text, lineAt: 2,
                                        selection: NSRange(location: 0, length: 0))
    #expect(result?.text == "- [ ] b\n- [x] a\n")
}

@Test func flippingACheckedBoxReturnsItBelowTheLastOpenItem() {
    let text = "- [ ] a\n- [ ] b\n- [x] c\n- [x] d\n"
    // Un-tick "d": it goes back right after "- [ ] b", above the other done one.
    let result = TodoEngine.flipChecked(text: text, lineAt: 26,
                                        selection: NSRange(location: 0, length: 0))
    #expect(result?.text == "- [ ] a\n- [ ] b\n- [ ] d\n- [x] c\n")
}

@Test func flippingACheckedBoxWithNoOpenItemsGoesAboveTheDoneOnes() {
    let text = "notes\n- [x] c\n- [x] d\n"
    let result = TodoEngine.flipChecked(text: text, lineAt: 16,
                                        selection: NSRange(location: 0, length: 0))
    #expect(result?.text == "notes\n- [ ] d\n- [x] c\n")
}

@Test func flippingTheOnlyItemMovesNothing() {
    let text = "notes\n- [x] c\nmore\n"
    let result = TodoEngine.flipChecked(text: text, lineAt: 8,
                                        selection: NSRange(location: 0, length: 0))
    #expect(result?.text == "notes\n- [ ] c\nmore\n")
}

@Test func flippingAPlainLineDoesNothingAtAll() {
    #expect(TodoEngine.flipChecked(text: "notes\n", lineAt: 1,
                                   selection: NSRange(location: 0, length: 0)) == nil)
}

@Test func theCaretFollowsAFlippedLineToo() {
    let text = "- [ ] a\n- [ ] b\n"
    // Caret sits on "a" (offset 6) while its box is clicked.
    let result = TodoEngine.flipChecked(text: text, lineAt: 2,
                                        selection: NSRange(location: 6, length: 0))
    #expect(result?.text == "- [ ] b\n- [x] a\n")
    #expect(result?.selection == NSRange(location: 14, length: 0))
}

// MARK: - List continuation (⏎)

@Test func returnContinuesATodoListAlwaysUnchecked() {
    #expect(TodoEngine.continuation(line: "- [ ] milk", caretOffsetInLine: 10)
            == .insert("- [ ] "))
    // Even from a ticked item: a fresh entry starts undone.
    #expect(TodoEngine.continuation(line: "- [x] milk", caretOffsetInLine: 10)
            == .insert("- [ ] "))
    #expect(TodoEngine.continuation(line: "    - [ ] milk", caretOffsetInLine: 14)
            == .insert("    - [ ] "))
}

@Test func returnContinuesBulletsAndNumbers() {
    #expect(TodoEngine.continuation(line: "- item", caretOffsetInLine: 6) == .insert("- "))
    #expect(TodoEngine.continuation(line: "* item", caretOffsetInLine: 6) == .insert("* "))
    #expect(TodoEngine.continuation(line: "1. item", caretOffsetInLine: 7) == .insert("2. "))
    #expect(TodoEngine.continuation(line: "  9. item", caretOffsetInLine: 9) == .insert("  10. "))
    // A number that is not a list marker is just text.
    #expect(TodoEngine.continuation(line: "1.item", caretOffsetInLine: 6) == nil)
    #expect(TodoEngine.continuation(line: "-item", caretOffsetInLine: 5) == nil)
}

@Test func returnOnAnEmptyItemLeavesTheList() {
    // The whole line goes; the caret is left on an empty line.
    #expect(TodoEngine.continuation(line: "- [ ] ", caretOffsetInLine: 6)
            == .exit(NSRange(location: 0, length: 6)))
    #expect(TodoEngine.continuation(line: "  - ", caretOffsetInLine: 4)
            == .exit(NSRange(location: 0, length: 4)))
    #expect(TodoEngine.continuation(line: "3. ", caretOffsetInLine: 3)
            == .exit(NSRange(location: 0, length: 3)))
}

@Test func returnInsideThePrefixIsAnOrdinaryNewline() {
    #expect(TodoEngine.continuation(line: "- [ ] milk", caretOffsetInLine: 0) == nil)
    #expect(TodoEngine.continuation(line: "- [ ] milk", caretOffsetInLine: 3) == nil)
    #expect(TodoEngine.continuation(line: "- [ ] milk", caretOffsetInLine: 5) == nil)
    // Right after the prefix the item is still continued: the text to the right
    // of the caret becomes the new entry (a mid-line split).
    #expect(TodoEngine.continuation(line: "- [ ] milk", caretOffsetInLine: 6)
            == .insert("- [ ] "))
}

@Test func returnSplitsAnItemInTwo() {
    // "- [ ] mi|lk" → the tail moves into a brand-new item.
    #expect(TodoEngine.continuation(line: "- [ ] milk", caretOffsetInLine: 8)
            == .insert("- [ ] "))
    #expect(TodoEngine.continuation(line: "plain text", caretOffsetInLine: 5) == nil)
}

// MARK: - Minimal edit (what the text view actually replaces)

@Test func minimalEditNarrowsARewriteToTheSpanThatChanged() {
    let edit = TodoEngine.minimalEdit(from: "- [ ] milk", to: "- [x] milk")
    #expect(edit?.range == NSRange(location: 3, length: 1))
    #expect(edit?.replacement == "x")
}

@Test func minimalEditReportsNothingForAnUnchangedDocument() {
    #expect(TodoEngine.minimalEdit(from: "same", to: "same") == nil)
}

@Test func minimalEditRoundTripsForAMovedLine() {
    let old = "- [ ] a\n- [ ] b\n- [ ] c\n"
    let new = TodoEngine.cycleTodo(text: old, selection: NSRange(location: 0, length: 0)).text
    let edit = TodoEngine.minimalEdit(from: old, to: new)!
    let rebuilt = (old as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    #expect(rebuilt == new)
}

@Test func minimalEditNeverSplitsASurrogatePair() {
    // An emoji (two UTF-16 units) on both sides of the change: the trimmed
    // range must stay on a character boundary, or the replacement would produce
    // a lone surrogate.
    let old = "🙂 milk 🙂"
    let new = "🙂 milkx 🙂"
    let edit = TodoEngine.minimalEdit(from: old, to: new)!
    let rebuilt = (old as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    #expect(rebuilt == new)
    #expect(edit.range.location >= 2)
}
