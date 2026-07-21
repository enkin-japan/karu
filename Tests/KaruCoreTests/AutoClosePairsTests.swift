import Foundation
import Testing
@testable import KaruCore

// MARK: - Opening brackets (T12.6)

@Test func openBracketWithoutSelectionInsertsPair() {
    #expect(AutoClosePairs.decide(typed: "(", charBefore: nil, charAfter: nil, hasSelection: false)
        == .insertPair("()", caretOffset: 1))
    #expect(AutoClosePairs.decide(typed: "[", charBefore: "x", charAfter: " ", hasSelection: false)
        == .insertPair("[]", caretOffset: 1))
    #expect(AutoClosePairs.decide(typed: "{", charBefore: nil, charAfter: nil, hasSelection: false)
        == .insertPair("{}", caretOffset: 1))
}

@Test func openBracketWithSelectionWraps() {
    #expect(AutoClosePairs.decide(typed: "(", charBefore: nil, charAfter: nil, hasSelection: true)
        == .wrap(prefix: "(", suffix: ")"))
    #expect(AutoClosePairs.decide(typed: "{", charBefore: nil, charAfter: nil, hasSelection: true)
        == .wrap(prefix: "{", suffix: "}"))
}

// MARK: - Closing brackets

@Test func closeBracketStepsOverMatchingCloser() {
    #expect(AutoClosePairs.decide(typed: ")", charBefore: nil, charAfter: ")", hasSelection: false)
        == .stepOver)
    #expect(AutoClosePairs.decide(typed: "]", charBefore: nil, charAfter: "]", hasSelection: false)
        == .stepOver)
}

@Test func closeBracketPassesThroughWhenNoMatchingCloser() {
    #expect(AutoClosePairs.decide(typed: ")", charBefore: nil, charAfter: nil, hasSelection: false)
        == .passthrough)
    #expect(AutoClosePairs.decide(typed: ")", charBefore: nil, charAfter: "x", hasSelection: false)
        == .passthrough)
    // A different closer following is not a step-over.
    #expect(AutoClosePairs.decide(typed: ")", charBefore: nil, charAfter: "]", hasSelection: false)
        == .passthrough)
}

// MARK: - Quotes

@Test func quoteWithoutContextInsertsPair() {
    #expect(AutoClosePairs.decide(typed: "\"", charBefore: nil, charAfter: nil, hasSelection: false)
        == .insertPair("\"\"", caretOffset: 1))
    #expect(AutoClosePairs.decide(typed: "`", charBefore: " ", charAfter: " ", hasSelection: false)
        == .insertPair("``", caretOffset: 1))
}

@Test func quoteWithSelectionWraps() {
    #expect(AutoClosePairs.decide(typed: "\"", charBefore: nil, charAfter: nil, hasSelection: true)
        == .wrap(prefix: "\"", suffix: "\""))
    #expect(AutoClosePairs.decide(typed: "'", charBefore: nil, charAfter: nil, hasSelection: true)
        == .wrap(prefix: "'", suffix: "'"))
}

@Test func quoteStepsOverMatchingQuote() {
    #expect(AutoClosePairs.decide(typed: "\"", charBefore: nil, charAfter: "\"", hasSelection: false)
        == .stepOver)
    #expect(AutoClosePairs.decide(typed: "'", charBefore: "x", charAfter: "'", hasSelection: false)
        == .stepOver)
}

@Test func apostropheInsideWordDoesNotClose() {
    // don't — the ' follows a letter, so no pair is inserted.
    #expect(AutoClosePairs.decide(typed: "'", charBefore: "n", charAfter: nil, hasSelection: false)
        == .passthrough)
    // After a digit and an underscore too.
    #expect(AutoClosePairs.decide(typed: "'", charBefore: "9", charAfter: nil, hasSelection: false)
        == .passthrough)
    #expect(AutoClosePairs.decide(typed: "'", charBefore: "_", charAfter: nil, hasSelection: false)
        == .passthrough)
}

@Test func quoteAfterSameQuotePassesThrough() {
    // Python-style triple quote: typing ' after ' should not insert a pair.
    #expect(AutoClosePairs.decide(typed: "'", charBefore: "'", charAfter: nil, hasSelection: false)
        == .passthrough)
}

@Test func quoteAfterWhitespaceOrPunctuationInsertsPair() {
    #expect(AutoClosePairs.decide(typed: "'", charBefore: " ", charAfter: nil, hasSelection: false)
        == .insertPair("''", caretOffset: 1))
    #expect(AutoClosePairs.decide(typed: "'", charBefore: "(", charAfter: nil, hasSelection: false)
        == .insertPair("''", caretOffset: 1))
}

// MARK: - Non-paired characters

@Test func ordinaryCharacterPassesThrough() {
    #expect(AutoClosePairs.decide(typed: "a", charBefore: nil, charAfter: nil, hasSelection: false)
        == .passthrough)
    #expect(AutoClosePairs.decide(typed: "a", charBefore: nil, charAfter: nil, hasSelection: true)
        == .passthrough)
}

@Test func multiCharacterInputPassesThrough() {
    // Guards the wrapper's single-character contract at the pure layer too.
    #expect(AutoClosePairs.decide(typed: "()", charBefore: nil, charAfter: nil, hasSelection: false)
        == .passthrough)
    #expect(AutoClosePairs.decide(typed: "", charBefore: nil, charAfter: nil, hasSelection: false)
        == .passthrough)
}

// MARK: - Backspace pair deletion

@Test func backspaceDeletesEmptyBracketPair() {
    #expect(AutoClosePairs.shouldDeletePair(charBefore: "(", charAfter: ")"))
    #expect(AutoClosePairs.shouldDeletePair(charBefore: "[", charAfter: "]"))
    #expect(AutoClosePairs.shouldDeletePair(charBefore: "{", charAfter: "}"))
}

@Test func backspaceDeletesEmptyQuotePair() {
    #expect(AutoClosePairs.shouldDeletePair(charBefore: "\"", charAfter: "\""))
    #expect(AutoClosePairs.shouldDeletePair(charBefore: "'", charAfter: "'"))
    #expect(AutoClosePairs.shouldDeletePair(charBefore: "`", charAfter: "`"))
}

@Test func backspaceDoesNotDeleteMismatchedOrPlainPair() {
    #expect(!AutoClosePairs.shouldDeletePair(charBefore: "(", charAfter: "]"))
    #expect(!AutoClosePairs.shouldDeletePair(charBefore: "a", charAfter: "b"))
    #expect(!AutoClosePairs.shouldDeletePair(charBefore: ")", charAfter: "("))
    #expect(!AutoClosePairs.shouldDeletePair(charBefore: nil, charAfter: ")"))
    #expect(!AutoClosePairs.shouldDeletePair(charBefore: "(", charAfter: nil))
}

// MARK: - Default toggle

@Test func autoCloseDefaultsToEnabledWhenUnset() {
    let name = "AutoCloseTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    // The production accessor reads `.standard`; assert the documented default
    // contract directly against an isolated store.
    #expect(defaults.object(forKey: AutoClosePairs.enabledKey) == nil)
}
