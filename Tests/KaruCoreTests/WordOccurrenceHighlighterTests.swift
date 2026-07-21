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
