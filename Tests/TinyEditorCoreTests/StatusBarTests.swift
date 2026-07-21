import Foundation
import Testing
@testable import TinyEditorCore

// MARK: - StatusBarMetrics.column

@Test func columnIsOneAtLineStart() {
    // Caret sitting exactly on the line's start offset is column 1.
    #expect(StatusBarMetrics.column(caretOffset: 0, lineStartOffset: 0) == 1)
    #expect(StatusBarMetrics.column(caretOffset: 42, lineStartOffset: 42) == 1)
}

@Test func columnCountsOffsetFromLineStart() {
    // Fifth code unit on a line beginning at offset 10 → column 6.
    #expect(StatusBarMetrics.column(caretOffset: 15, lineStartOffset: 10) == 6)
}

@Test func columnClampsToOneForInconsistentInput() {
    // A caret before the line start (should never happen) never underflows.
    #expect(StatusBarMetrics.column(caretOffset: 3, lineStartOffset: 10) == 1)
}

// MARK: - StatusBarMetrics captions

@Test func caretDescriptionFormatsLineAndColumn() {
    #expect(StatusBarMetrics.caretDescription(line: 1, column: 1) == "Ln 1, Col 1")
    #expect(StatusBarMetrics.caretDescription(line: 12, column: 7) == "Ln 12, Col 7")
}

@Test func characterCountDescriptionSingularAndPlural() {
    #expect(StatusBarMetrics.characterCountDescription(0) == "0 chars")
    #expect(StatusBarMetrics.characterCountDescription(1) == "1 char")
    #expect(StatusBarMetrics.characterCountDescription(2048) == "2048 chars")
}

// MARK: - column via a real LineIndex (integration of the pieces)

@Test func columnFromLineIndexMatchesCaretPlacement() {
    // "abc\nde|f" → caret after 'e' on line 2 (line start offset 4) is column 3.
    let text = "abc\ndef"
    let index = LineIndex(text: text)
    let caret = 6 // between 'e' and 'f'
    let line = index.lineNumber(forOffset: caret)
    let lineStart = index.offsetRange(ofLine: line).lowerBound
    #expect(line == 2)
    #expect(StatusBarMetrics.column(caretOffset: caret, lineStartOffset: lineStart) == 3)
}

// MARK: - SupportedLanguage

@Test func supportedLanguageTitleForEmptyIsPlainText() {
    #expect(SupportedLanguage.title(forIdentifier: "") == "Plain Text")
}

@Test func supportedLanguageTitleLooksUpKnownIdentifiers() {
    #expect(SupportedLanguage.title(forIdentifier: "json") == "JSON")
    #expect(SupportedLanguage.title(forIdentifier: "cpp") == "C++")
    #expect(SupportedLanguage.title(forIdentifier: "csharp") == "C#")
}

@Test func supportedLanguageTitleIsCaseInsensitive() {
    #expect(SupportedLanguage.title(forIdentifier: "JSON") == "JSON")
    #expect(SupportedLanguage.title(forIdentifier: "Python") == "Python")
}

@Test func supportedLanguageTitleFallsBackForUnknown() {
    #expect(SupportedLanguage.title(forIdentifier: "brainfuck") == "Plain Text")
}

@Test func supportedLanguageListCoversFifteenLanguagesPlusPlain() {
    // Plain Text + the 15 supported languages (ARCHITECTURE.md §4).
    #expect(SupportedLanguage.all.count == 16)
    #expect(SupportedLanguage.all.first?.identifier == "")
    // Every non-plain identifier resolves to a real definition.
    for lang in SupportedLanguage.all where !lang.identifier.isEmpty {
        #expect(LanguageRegistry.definition(forIdentifier: lang.identifier) != nil,
                "no definition for \(lang.identifier)")
    }
}
