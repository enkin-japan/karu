import Foundation
import Testing
@testable import KaruCore

// Pure-function coverage for the cursor-word occurrence highlighter (T12.9):
// `wordRange` boundary behaviour and `occurrences` whole-word matching + cap.
// The controller (debounce / viewport scan / temporary attributes) is an AppKit
// shell over these.

// MARK: - wordRange: caret inside / at the end of a word

@Test func wordRangeFindsWordWhenCaretInside() {
    let text = "let value = 1"
    // Caret in the middle of "value".
    #expect(WordOccurrenceHighlighter.wordRange(in: text, at: 6) == NSRange(location: 4, length: 5))
}

@Test func wordRangeFindsWordWhenCaretAtWordStart() {
    let text = "let value = 1"
    // Caret just before the 'v' of "value".
    #expect(WordOccurrenceHighlighter.wordRange(in: text, at: 4) == NSRange(location: 4, length: 5))
}

@Test func wordRangeFindsWordWhenCaretAtWordEnd() {
    let text = "let value = 1"
    // Caret immediately past the last char of "value" (index 9) still counts.
    #expect(WordOccurrenceHighlighter.wordRange(in: text, at: 9) == NSRange(location: 4, length: 5))
}

// MARK: - wordRange: nil cases

@Test func wordRangeNilWhenCaretInWhitespace() {
    // Caret flanked by spaces on both sides (index 3 of "ab   cd") touches no
    // word character, so there is nothing to highlight.
    let text = "ab   cd"          // a0 b1 sp2 sp3 sp4 c5 d6
    #expect(WordOccurrenceHighlighter.wordRange(in: text, at: 3) == nil)
}

@Test func wordRangeNilForSingleCharacterWord() {
    // "x" is a single-unit word; words shorter than 2 units return nil.
    #expect(WordOccurrenceHighlighter.wordRange(in: "a x b", at: 2) == nil)
    #expect(WordOccurrenceHighlighter.wordRange(in: "a x b", at: 3) == nil)
}

@Test func wordRangeNilForEmptyTextOrOutOfBounds() {
    #expect(WordOccurrenceHighlighter.wordRange(in: "", at: 0) == nil)
    #expect(WordOccurrenceHighlighter.wordRange(in: "hello", at: 99) == nil)
}

@Test func wordRangeHandlesUnderscoreAndDigits() {
    let text = "foo_bar1 baz"
    #expect(WordOccurrenceHighlighter.wordRange(in: text, at: 2) == NSRange(location: 0, length: 8))
}

// MARK: - occurrences: whole-word matching

@Test func occurrencesMatchesWholeWordsOnly() {
    let text = "value valuable value revalue value"
    let full = NSRange(location: 0, length: (text as NSString).length)
    let hits = WordOccurrenceHighlighter.occurrences(of: "value", in: text, range: full, cap: 500)
    // Three standalone "value" tokens; "valuable" and "revalue" are not whole words.
    #expect(hits.count == 3)
    let ns = text as NSString
    for hit in hits {
        #expect(ns.substring(with: hit) == "value")
    }
    #expect(hits[0].location == 0)
}

@Test func occurrencesRespectsSearchRange() {
    let text = "value value value"
    // Restrict to the first 8 UTF-16 units: only the first "value" fits wholly.
    let hits = WordOccurrenceHighlighter.occurrences(of: "value", in: text,
                                                     range: NSRange(location: 0, length: 8), cap: 500)
    #expect(hits.count == 1)
    #expect(hits[0] == NSRange(location: 0, length: 5))
}

@Test func occurrencesReturnsEmptyWhenOverCap() {
    // 10 occurrences of "ab", cap 5 → degenerate-file guard returns empty.
    let text = Array(repeating: "ab", count: 10).joined(separator: " ")
    let full = NSRange(location: 0, length: (text as NSString).length)
    let hits = WordOccurrenceHighlighter.occurrences(of: "ab", in: text, range: full, cap: 5)
    #expect(hits.isEmpty)
}

@Test func occurrencesEmptyForTooShortWord() {
    let text = "a a a a"
    let full = NSRange(location: 0, length: (text as NSString).length)
    #expect(WordOccurrenceHighlighter.occurrences(of: "a", in: text, range: full, cap: 500).isEmpty)
}

// MARK: - Whole-character word boundaries (VH6)

/// The caret word and its whole-word hits over the whole of `text`.
private func caretWord(_ text: String, at caret: Int, dollar: Bool = false) -> (word: NSRange, hits: [NSRange])? {
    guard let word = WordOccurrenceHighlighter.wordRange(in: text, at: caret, dollarIsWordCharacter: dollar) else {
        return nil
    }
    let ns = text as NSString
    let hits = WordOccurrenceHighlighter.occurrences(of: ns.substring(with: word), in: text,
                                                     range: NSRange(location: 0, length: ns.length),
                                                     cap: 500, dollarIsWordCharacter: dollar)
    return (word, hits)
}

@Test func dollarIsAWordCharacterOnlyWithTheFlag() {
    let text = "$value value"
    let inDollar = caretWord(text, at: 2, dollar: true)
    #expect(inDollar?.word == NSRange(location: 0, length: 6))
    #expect(inDollar?.hits == [NSRange(location: 0, length: 6)])
    // The bare word does not match inside `$value` (not word-bounded).
    let bare = caretWord(text, at: 9, dollar: true)
    #expect(bare?.word == NSRange(location: 7, length: 5))
    #expect(bare?.hits == [NSRange(location: 7, length: 5)])
    // Flag off: `$` is punctuation, as before.
    let off = caretWord(text, at: 2)
    #expect(off?.word == NSRange(location: 1, length: 5))
    #expect(off?.hits == [NSRange(location: 1, length: 5), NSRange(location: 7, length: 5)])
}

@Test func combiningMarkBelongsToTheWord() {
    let text = "cafe\u{301} cafe"
    let decomposed = caretWord(text, at: 2)
    #expect(decomposed?.word == NSRange(location: 0, length: 5))
    #expect(decomposed?.hits == [NSRange(location: 0, length: 5)])
    // `cafe` does not match inside `cafe` + U+0301.
    let plain = caretWord(text, at: 8)
    #expect(plain?.word == NSRange(location: 6, length: 4))
    #expect(plain?.hits == [NSRange(location: 6, length: 4)])
    // A caret right after the mark still touches the word.
    #expect(caretWord(text, at: 5)?.word == NSRange(location: 0, length: 5))
}

@Test func nonBMPLetterIsPartOfTheWord() {
    let text = "\u{10400}name name"
    let prefixed = caretWord(text, at: 3)
    #expect(prefixed?.word == NSRange(location: 0, length: 6))
    #expect(prefixed?.hits == [NSRange(location: 0, length: 6)])
    let bare = caretWord(text, at: 9)
    #expect(bare?.word == NSRange(location: 7, length: 4))
    #expect(bare?.hits == [NSRange(location: 7, length: 4)])
}

@Test func surrogatePairIsNeverSplit() {
    let text = "𠮷野家 𠮷野家"
    for caret in [1, 3] {
        let result = caretWord(text, at: caret)
        #expect(result?.word == NSRange(location: 0, length: 4))
        #expect(result?.hits == [NSRange(location: 0, length: 4), NSRange(location: 5, length: 4)])
    }
}

@Test func minimumLengthCountsCharactersNotUnitsOrMarks() {
    // A lone non-BMP letter (2 units) and a lone decomposed é are 1 character.
    #expect(WordOccurrenceHighlighter.wordRange(in: "a 𠮷 b", at: 3) == nil)
    #expect(WordOccurrenceHighlighter.wordRange(in: "a e\u{301} b", at: 3) == nil)
    #expect(WordOccurrenceHighlighter.wordRange(in: "x x", at: 1) == nil)
    // A mark after whitespace has no word base and is no word.
    #expect(WordOccurrenceHighlighter.wordRange(in: "a \u{301}\u{301} b", at: 3) == nil)
}

@Test func unchangedWordShapes() {
    #expect(caretWord("naïve naïve", at: 2)?.word == NSRange(location: 0, length: 5))
    #expect(caretWord("naïve naïve", at: 2)?.hits.count == 2)
    #expect(caretWord("日本語 日本語", at: 1)?.word == NSRange(location: 0, length: 3))
    #expect(caretWord("日本語 日本語", at: 1)?.hits.count == 2)
    #expect(caretWord("@name name", at: 3)?.word == NSRange(location: 1, length: 4))
    #expect(caretWord("@name name", at: 3)?.hits.count == 2)
    #expect(caretWord("#id id", at: 2)?.word == NSRange(location: 1, length: 2))
    #expect(caretWord("#id id", at: 2)?.hits.count == 2)
    #expect(caretWord("my-var var", at: 4)?.word == NSRange(location: 3, length: 3))
    #expect(caretWord("my-var var", at: 4)?.hits.count == 2)
    #expect(caretWord("my-var my", at: 1)?.word == NSRange(location: 0, length: 2))
    #expect(caretWord("my-var my", at: 1)?.hits.count == 2)
}

@Test func nsStringVariantsMatchTheStringOnes() {
    let text = "let value = value + 1"
    let ns = NSMutableString(string: text)
    #expect(WordOccurrenceHighlighter.wordRange(in: ns, at: 6) == WordOccurrenceHighlighter.wordRange(in: text, at: 6))
    let full = NSRange(location: 0, length: ns.length)
    #expect(WordOccurrenceHighlighter.occurrences(of: "value", in: ns, range: full, cap: 500)
        == WordOccurrenceHighlighter.occurrences(of: "value", in: text, range: full, cap: 500))
}
