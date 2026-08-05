import Foundation
import Testing
@testable import KaruCore

// T15.6 — the scratchpad's to-do lists, as pure logic.
//
// The feature is two orthogonal switches: ⇧⌘L (`toggleTodo`) says whether a line
// is a to-do and never moves anything, ⇧⌘U (`toggleChecked`) says whether it is
// done and moves it accordingly. Everything they do to text lives in
// `TodoEngine`: the batch rules, where a ticked line goes, where an un-ticked
// one comes back to, how the caret follows a line that moved, and how ⏎
// continues a list. The text view is a wrapper around these functions, so the
// rules are pinned here rather than through a panel (which is unreliable
// headless — see ScratchpadTests for that reasoning).

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

// MARK: - "Is this a to-do?" (⇧⌘L): single line

@Test func todoToggleTurnsAPlainLineIntoAnItemAndBackAgain() {
    let plain = "milk"
    let marked = TodoEngine.toggleTodo(text: plain, selection: NSRange(location: 0, length: 0))
    #expect(marked.text == "- [ ] milk")

    // Pressing it again undoes exactly what it did — the switch is symmetric.
    let back = TodoEngine.toggleTodo(text: marked.text, selection: marked.selection)
    #expect(back.text == "milk")
}

@Test func todoToggleOnAnEmptyPadStartsAList() {
    let result = TodoEngine.toggleTodo(text: "", selection: NSRange(location: 0, length: 0))
    #expect(result.text == "- [ ] ")
    // The caret ends up where the first character of the item will go.
    #expect(result.selection == NSRange(location: 6, length: 0))
}

@Test func todoToggleOnABlankLineInsideADocumentStartsAList() {
    // Same "start a list here" case, but with text around it: the blank line is
    // the only covered line, so the blank-line filter must not empty the batch.
    let text = "notes\n\nmore\n"
    let result = TodoEngine.toggleTodo(text: text, selection: NSRange(location: 6, length: 0))
    #expect(result.text == "notes\n- [ ] \nmore\n")
}

@Test func todoTogglePreservesIndentation() {
    let marked = TodoEngine.toggleTodo(text: "    nested", selection: NSRange(location: 0, length: 0))
    #expect(marked.text == "    - [ ] nested")
    let stripped = TodoEngine.toggleTodo(text: marked.text, selection: NSRange(location: 0, length: 0))
    #expect(stripped.text == "    nested")
}

@Test func todoToggleClearsACheckedLineInOneStep() {
    // "This is not a to-do at all" — the done flag goes with the box, which is
    // what the user explicitly asked for by pressing ⇧⌘L on a finished item.
    let result = TodoEngine.toggleTodo(text: "- [x] milk", selection: NSRange(location: 8, length: 0))
    #expect(result.text == "milk")
}

// MARK: - "Is this a to-do?" (⇧⌘L): batches

@Test func todoToggleMarksOnlyThePlainLinesAndLeavesMarkedOnesUntouched() {
    // One plain line in the batch means "mark what is not marked yet". The
    // checked line keeps its box *and* its tick: extending a list over a
    // finished item must never un-finish it.
    let text = "- [ ] a\nb\n- [x] c\n"
    let result = TodoEngine.toggleTodo(text: text, selection: NSRange(location: 0, length: 17))
    #expect(result.text == "- [ ] a\n- [ ] b\n- [x] c\n")
}

@Test func todoToggleClearsAWholeBatchOfMarkedLinesInPlace() {
    // Every target carries a box — ticked or not — so the switch flips the other
    // way and all of them lose it, checked ones included.
    let text = "- [x] a\n- [ ] b\n"
    let result = TodoEngine.toggleTodo(text: text, selection: NSRange(location: 0, length: 15))
    #expect(result.text == "a\nb\n")
}

@Test func todoToggleNeverMovesALine() {
    // The old three-state cycle sank this batch to the bottom. The ⇧⌘L switch
    // does not move anything, ever — in either direction.
    let unmark = TodoEngine.toggleTodo(text: "- [ ] a\n- [ ] b\nnotes\n",
                                       selection: NSRange(location: 0, length: 15))
    #expect(unmark.text == "a\nb\nnotes\n")

    let mark = TodoEngine.toggleTodo(text: "a\nb\nnotes\n",
                                     selection: NSRange(location: 0, length: 3))
    #expect(mark.text == "- [ ] a\n- [ ] b\nnotes\n")

    // A checked line stays exactly where it is while its neighbour is marked.
    let mixed = TodoEngine.toggleTodo(text: "- [x] done\nchore\nnotes\n",
                                      selection: NSRange(location: 0, length: 16))
    #expect(mixed.text == "- [x] done\n- [ ] chore\nnotes\n")
}

@Test func todoToggleIncludesAPartlySelectedLine() {
    // The selection touches the middle of both lines; both are still marked.
    let text = "alpha\nbeta\n"
    let result = TodoEngine.toggleTodo(text: text, selection: NSRange(location: 3, length: 4))
    #expect(result.text == "- [ ] alpha\n- [ ] beta\n")
}

@Test func todoToggleIgnoresALineTheSelectionOnlyEndsAt() {
    // Dragging down to the next line's left edge selects the lines above it,
    // not one more (the classic off-by-one line operation).
    let text = "alpha\nbeta\n"
    let result = TodoEngine.toggleTodo(text: text, selection: NSRange(location: 0, length: 6))
    #expect(result.text == "- [ ] alpha\nbeta\n")
}

@Test func todoToggleLeavesBlankLinesInsideASelectionAlone() {
    let text = "a\n\nb\n"
    let result = TodoEngine.toggleTodo(text: text, selection: NSRange(location: 0, length: 5))
    #expect(result.text == "- [ ] a\n\n- [ ] b\n")
}

// MARK: - "Is it done?" (⇧⌘U): ticking

@Test func checkingSinksTheLineToTheBottomOfTheDocument() {
    let text = "- [ ] a\n- [ ] b\n- [ ] c\n"
    // Tick the middle one.
    let result = TodoEngine.toggleChecked(text: text, selection: NSRange(location: 8, length: 0))
    #expect(result.text == "- [ ] a\n- [ ] c\n- [x] b\n")
}

@Test func checkingAMixedBatchTicksAllOfItAndSinksItAsOneBlock() {
    // Any unchecked target means "finish them all"; the already-checked one
    // travels along, keeping the block's relative order.
    let text = "- [x] a\n- [ ] b\nnotes\n"
    let result = TodoEngine.toggleChecked(text: text, selection: NSRange(location: 0, length: 15))
    #expect(result.text == "notes\n- [x] a\n- [x] b\n")
}

@Test func checkingLeavesPlainLinesInTheSelectionWhereTheyAre() {
    // The prose line is neither marked nor moved — it is simply not involved.
    let text = "- [ ] a\nnotes\n"
    let result = TodoEngine.toggleChecked(text: text, selection: NSRange(location: 0, length: 13))
    #expect(result.text == "notes\n- [x] a\n")
}

@Test func checkingAPlainOnlySelectionDoesNothingAtAll() {
    let text = "notes\nmore\n"
    let selection = NSRange(location: 0, length: 10)
    let result = TodoEngine.toggleChecked(text: text, selection: selection)
    #expect(result.text == text)
    #expect(result.selection == selection)
}

@Test func movingALineNeitherAddsNorSwallowsALine() {
    // A document *without* a trailing newline must not gain one, and one *with*
    // a trailing newline must keep exactly one.
    let noNewline = "- [ ] a\n- [ ] b"
    let sunk = TodoEngine.toggleChecked(text: noNewline, selection: NSRange(location: 0, length: 0))
    #expect(sunk.text == "- [ ] b\n- [x] a")

    let trailing = "- [ ] a\n- [ ] b\n"
    let sunk2 = TodoEngine.toggleChecked(text: trailing, selection: NSRange(location: 0, length: 0))
    #expect(sunk2.text == "- [ ] b\n- [x] a\n")

    // Trailing blank lines stay at the bottom rather than being jumped over.
    let blanks = "- [ ] a\nnotes\n\n"
    let sunk3 = TodoEngine.toggleChecked(text: blanks, selection: NSRange(location: 0, length: 0))
    #expect(sunk3.text == "notes\n- [x] a\n\n")
}

@Test func checkingTheLastLineLeavesItWhereItIs() {
    let text = "notes\n- [ ] a"
    let result = TodoEngine.toggleChecked(text: text, selection: NSRange(location: 6, length: 0))
    #expect(result.text == "notes\n- [x] a")
}

// MARK: - "Is it done?" (⇧⌘U): un-ticking

@Test func unCheckingABatchReturnsItBelowTheLastOpenItem() {
    let text = "- [ ] a\n- [x] b\n- [x] c\nnotes\n"
    // Un-tick "b" and "c" together: both go back right after "- [ ] a".
    let result = TodoEngine.toggleChecked(text: text, selection: NSRange(location: 8, length: 15))
    #expect(result.text == "- [ ] a\n- [ ] b\n- [ ] c\nnotes\n")
}

@Test func unCheckingABatchWithNoOpenItemsGoesAboveTheDoneOnes() {
    let text = "notes\n- [x] c\n- [x] d\n- [x] e\n"
    // Un-tick "d" and "e": they land in front of the still-done "c".
    let result = TodoEngine.toggleChecked(text: text, selection: NSRange(location: 14, length: 15))
    #expect(result.text == "notes\n- [ ] d\n- [ ] e\n- [x] c\n")
}

@Test func unCheckingABatchWithNothingToReturnToStaysPut() {
    let text = "notes\n- [x] a\n- [x] b\nmore\n"
    let result = TodoEngine.toggleChecked(text: text, selection: NSRange(location: 6, length: 15))
    #expect(result.text == "notes\n- [ ] a\n- [ ] b\nmore\n")
}

// MARK: - Caret following

@Test func theCaretRidesAlongWithTheLineItSitsOn() {
    let text = "- [ ] alpha\n- [ ] beta\n"
    // Caret two characters into the word: "- [ ] al|pha".
    let result = TodoEngine.toggleChecked(text: text, selection: NSRange(location: 8, length: 0))
    #expect(result.text == "- [ ] beta\n- [x] alpha\n")
    // Same offset within the line, now 11 characters further down the document.
    #expect(result.selection == NSRange(location: 19, length: 0))
}

@Test func theCaretStaysWithItsCharacterWhenAMarkerIsInserted() {
    // Caret at the start of the word: after marking it is still at the start of
    // the word, i.e. past the six-character marker.
    let result = TodoEngine.toggleTodo(text: "milk", selection: NSRange(location: 0, length: 0))
    #expect(result.selection == NSRange(location: 6, length: 0))

    // ... and mid-word it keeps its distance from the word start.
    let mid = TodoEngine.toggleTodo(text: "milk", selection: NSRange(location: 2, length: 0))
    #expect(mid.selection == NSRange(location: 8, length: 0))
}

@Test func aCaretInsideAStrippedMarkerLandsAtTheLineStart() {
    let result = TodoEngine.toggleTodo(text: "- [x] milk", selection: NSRange(location: 3, length: 0))
    #expect(result.text == "milk")
    #expect(result.selection == NSRange(location: 0, length: 0))
}

@Test func aSelectionSurvivesTheBatchItTriggered() {
    let text = "- [ ] a\n- [ ] b\nnotes\n"
    let result = TodoEngine.toggleChecked(text: text, selection: NSRange(location: 6, length: 9))
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
    let new = TodoEngine.toggleChecked(text: old, selection: NSRange(location: 0, length: 0)).text
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
