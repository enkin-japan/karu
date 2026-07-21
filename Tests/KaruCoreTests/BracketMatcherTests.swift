import Foundation
import Testing
@testable import KaruCore

// MARK: - Basic matching (T12.7)

@Test func matchesSimplePairFromCaretAfterOpener() {
    // "(abc)", caret at 1 (just after the opener).
    let match = BracketMatcher.findMatch(text: "(abc)", caret: 1)
    #expect(match?.open == NSRange(location: 0, length: 1))
    #expect(match?.close == NSRange(location: 4, length: 1))
}

@Test func matchesSimplePairFromCaretBeforeCloser() {
    // "(abc)", caret at 5 (just after the closer) → the char before is ')'.
    let match = BracketMatcher.findMatch(text: "(abc)", caret: 5)
    #expect(match?.open == NSRange(location: 0, length: 1))
    #expect(match?.close == NSRange(location: 4, length: 1))
}

@Test func matchesCaretAtDocumentStartUsesCharAfter() {
    // caret at 0: no char before, so the opener at index 0 is used.
    let match = BracketMatcher.findMatch(text: "(x)", caret: 0)
    #expect(match?.open == NSRange(location: 0, length: 1))
    #expect(match?.close == NSRange(location: 2, length: 1))
}

// MARK: - Nesting

@Test func matchesNestedBrackets() {
    // "([{}])"
    //  0 = (  1 = [  2 = {  3 = }  4 = ]  5 = )
    let text = "([{}])"
    // Caret after outer '(' → matches outer ')'.
    #expect(BracketMatcher.findMatch(text: text, caret: 1)?.close == NSRange(location: 5, length: 1))
    // Caret after '[' (index 2) → matches ']' at 4.
    #expect(BracketMatcher.findMatch(text: text, caret: 2)?.open == NSRange(location: 1, length: 1))
    #expect(BracketMatcher.findMatch(text: text, caret: 2)?.close == NSRange(location: 4, length: 1))
    // Caret after '{' (index 3) → matches '}' at 3.
    #expect(BracketMatcher.findMatch(text: text, caret: 3)?.open == NSRange(location: 2, length: 1))
    #expect(BracketMatcher.findMatch(text: text, caret: 3)?.close == NSRange(location: 3, length: 1))
}

@Test func nestedSameBracketPicksBalancedMatch() {
    // "((x))" caret after the inner '(' (index 2) matches the inner ')' at 3.
    let match = BracketMatcher.findMatch(text: "((x))", caret: 2)
    #expect(match?.open == NSRange(location: 1, length: 1))
    #expect(match?.close == NSRange(location: 3, length: 1))
}

// MARK: - Before/after adjacency priority

@Test func beforeCaretTakesPriorityOverAfter() {
    // ")(" with caret at 1: char before is ')', char after is '('. Both are
    // brackets; the char before wins (VS Code). ')' at 1... wait, indices:
    // index 0 = ')', index 1 = '('. Caret at 1 → before is ')' at 0 (unbalanced
    // backward → nil), so it falls through to the char after '(' at 1.
    let text = ")("
    let match = BracketMatcher.findMatch(text: text, caret: 1)
    // The ')' before has no opener, so we fall back to '(' after — which has no
    // closer either → nil overall.
    #expect(match == nil)
}

@Test func beforePriorityWithTwoValidBrackets() {
    // "()()" caret at 2: before is ')' (index 1) → matches '(' at 0.
    // After is '(' (index 2) → would match ')' at 3. Before must win.
    let match = BracketMatcher.findMatch(text: "()()", caret: 2)
    #expect(match?.open == NSRange(location: 0, length: 1))
    #expect(match?.close == NSRange(location: 1, length: 1))
}

// MARK: - No match

@Test func returnsNilWhenCaretNotAdjacentToBracket() {
    #expect(BracketMatcher.findMatch(text: "abc", caret: 1) == nil)
    #expect(BracketMatcher.findMatch(text: "", caret: 0) == nil)
}

@Test func returnsNilForUnbalancedBracket() {
    #expect(BracketMatcher.findMatch(text: "(abc", caret: 1) == nil)
    #expect(BracketMatcher.findMatch(text: "abc)", caret: 4) == nil)
}

@Test func mismatchedBracketTypesDoNotMatch() {
    // "(]" — the '(' has no ')'.
    #expect(BracketMatcher.findMatch(text: "(]", caret: 1) == nil)
}

// MARK: - Scan-limit clamp

@Test func matchBeyondScanLimitReturnsNil() {
    // '(' then > scanLimit filler then ')': the forward scan gives up.
    let filler = String(repeating: "x", count: BracketMatcher.scanLimit + 10)
    let text = "(" + filler + ")"
    #expect(BracketMatcher.findMatch(text: text, caret: 1) == nil)
}

@Test func matchJustInsideScanLimitSucceeds() {
    // Opener at 0, closer within the scan window.
    let filler = String(repeating: "x", count: BracketMatcher.scanLimit - 2)
    let text = "(" + filler + ")"
    let match = BracketMatcher.findMatch(text: text, caret: 1)
    #expect(match?.open == NSRange(location: 0, length: 1))
    #expect(match?.close == NSRange(location: (text as NSString).length - 1, length: 1))
}

// MARK: - UTF-16 correctness with astral characters

@Test func astralCharactersDoNotSkewIndices() {
    // An emoji (surrogate pair, 2 UTF-16 units) before the bracket pair: the
    // returned ranges must be UTF-16 offsets so they map straight onto layout.
    let text = "😀(x)"
    let ns = text as NSString
    // '(' is at UTF-16 index 2 (emoji occupies 0..<2).
    let openIndex = 2
    let match = BracketMatcher.findMatch(text: text, caret: openIndex + 1)
    #expect(match?.open == NSRange(location: openIndex, length: 1))
    #expect(match?.close == NSRange(location: ns.length - 1, length: 1))
}
