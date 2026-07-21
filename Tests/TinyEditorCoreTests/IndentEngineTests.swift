import Foundation
import Testing
@testable import TinyEditorCore

// MARK: - Single-line Tab insertion

@Test func tabInsertsTwoSpacesAtCaret() {
    let edit = IndentEngine.tab(
        text: "foo",
        selection: NSRange(location: 0, length: 0),
        width: 2,
        usesSpaces: true
    )
    #expect(edit.range == NSRange(location: 0, length: 0))
    #expect(edit.replacement == "  ")
    #expect(edit.selection == NSRange(location: 2, length: 0))
}

@Test func tabInsertsFourSpacesAtCaret() {
    let edit = IndentEngine.tab(
        text: "foo",
        selection: NSRange(location: 3, length: 0),
        width: 4,
        usesSpaces: true
    )
    #expect(edit.range == NSRange(location: 3, length: 0))
    #expect(edit.replacement == "    ")
    #expect(edit.selection == NSRange(location: 7, length: 0))
}

@Test func tabInsertsTabWhenSpacesDisabled() {
    let edit = IndentEngine.tab(
        text: "foo",
        selection: NSRange(location: 0, length: 0),
        width: 4,
        usesSpaces: false
    )
    #expect(edit.replacement == "\t")
}

// MARK: - Multi-line selection indent / outdent

@Test func tabIndentsEverySelectedLine() {
    let text = "a\nb\nc\n"
    let edit = IndentEngine.tab(
        text: text,
        selection: NSRange(location: 0, length: (text as NSString).length),
        width: 2,
        usesSpaces: true
    )
    #expect(edit.range == NSRange(location: 0, length: 6))
    #expect(edit.replacement == "  a\n  b\n  c\n")
    // Whole block stays selected.
    #expect(edit.selection == NSRange(location: 0, length: (edit.replacement as NSString).length))
}

@Test func tabSkipsBlankLinesInSelection() {
    let text = "a\n\nb"
    let edit = IndentEngine.tab(
        text: text,
        selection: NSRange(location: 0, length: (text as NSString).length),
        width: 2,
        usesSpaces: true
    )
    #expect(edit.replacement == "  a\n\n  b")
}

@Test func shiftTabOutdentsEverySelectedLine() {
    let text = "    a\n    b\n"
    let edit = IndentEngine.shiftTab(
        text: text,
        selection: NSRange(location: 0, length: (text as NSString).length),
        width: 4,
        usesSpaces: true
    )
    #expect(edit.replacement == "a\nb\n")
}

@Test func shiftTabRemovesLeadingTab() {
    let edit = IndentEngine.shiftTab(
        text: "\tvalue",
        selection: NSRange(location: 0, length: 0),
        width: 4,
        usesSpaces: false
    )
    #expect(edit.replacement == "value")
}

// MARK: - Shift-Tab with insufficient leading whitespace

@Test func shiftTabRemovesOnlyAvailableSpaces() {
    // Line has 2 leading spaces but width is 4: remove only the 2 present.
    let edit = IndentEngine.shiftTab(
        text: "  a",
        selection: NSRange(location: 0, length: 0),
        width: 4,
        usesSpaces: true
    )
    #expect(edit.replacement == "a")
}

@Test func shiftTabPerLineRemovesAtMostWidth() {
    // First line has 6 spaces (remove 4), second has 1 (remove 1).
    let text = "      x\n y\n"
    let edit = IndentEngine.shiftTab(
        text: text,
        selection: NSRange(location: 0, length: (text as NSString).length),
        width: 4,
        usesSpaces: true
    )
    #expect(edit.replacement == "  x\ny\n")
}

// MARK: - Newline auto-indent

@Test func newlineInheritsLeadingWhitespace() {
    let text = "    foo"
    let edit = IndentEngine.newline(
        text: text,
        selection: NSRange(location: (text as NSString).length, length: 0),
        width: 4,
        usesSpaces: true
    )
    #expect(edit.replacement == "\n    ")
    #expect(edit.selection == NSRange(location: 12, length: 0))
}

@Test func newlineAddsLevelAfterOpenBrace() {
    let text = "  foo {"
    let edit = IndentEngine.newline(
        text: text,
        selection: NSRange(location: (text as NSString).length, length: 0),
        width: 2,
        usesSpaces: true
    )
    // Inherit 2 + one extra level of 2.
    #expect(edit.replacement == "\n    ")
}

@Test func newlineAddsLevelAfterColon() {
    let text = "def f():"
    let edit = IndentEngine.newline(
        text: text,
        selection: NSRange(location: (text as NSString).length, length: 0),
        width: 4,
        usesSpaces: true
    )
    #expect(edit.replacement == "\n    ")
}

@Test func newlineIgnoresTrailingWhitespaceWhenDetectingOpener() {
    let text = "if (x) {   "
    let edit = IndentEngine.newline(
        text: text,
        selection: NSRange(location: (text as NSString).length, length: 0),
        width: 2,
        usesSpaces: true
    )
    #expect(edit.replacement == "\n  ")
}

@Test func newlineWithoutOpenerKeepsIndentOnly() {
    let text = "        value"
    let edit = IndentEngine.newline(
        text: text,
        selection: NSRange(location: (text as NSString).length, length: 0),
        width: 4,
        usesSpaces: true
    )
    #expect(edit.replacement == "\n        ")
}

// MARK: - IndentSettings

private func makeIsolatedDefaults() -> UserDefaults {
    UserDefaults(suiteName: "IndentSettingsTests-\(UUID().uuidString)")!
}

@Test func indentSettingsDefaults() {
    let settings = IndentSettings(defaults: makeIsolatedDefaults())
    #expect(settings.usesSpaces == true)
    #expect(settings.width(for: "swift") == 4)   // fallback
    #expect(settings.width(for: "python") == 4)  // fallback
    #expect(settings.width(for: "html") == 2)    // language default
    #expect(settings.width(for: "HTML") == 2)    // case-insensitive
    #expect(settings.width(for: "json") == 2)
}

@Test func indentSettingsUserDefaultsOverride() {
    let defaults = makeIsolatedDefaults()
    defaults.set(8, forKey: IndentSettings.widthKey(for: "html"))
    defaults.set(3, forKey: IndentSettings.widthKey(for: "swift"))
    defaults.set(false, forKey: IndentSettings.usesSpacesKey)

    let settings = IndentSettings(defaults: defaults)
    #expect(settings.width(for: "html") == 8)    // override beats language default
    #expect(settings.width(for: "swift") == 3)   // override beats fallback
    #expect(settings.width(for: "css") == 2)     // untouched language default
    #expect(settings.usesSpaces == false)
}
