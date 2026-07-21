import Foundation
import Testing
@testable import KaruCore

/// Applies a `CommentToggle` result to `text` the way `EditorWindowController`
/// would, so tests can assert on the resulting document string.
private func applied(
    _ text: String,
    selection: NSRange,
    language: String
) -> (string: String, selection: NSRange)? {
    guard let r = CommentToggle.toggle(text: text, selection: selection,
                                       languageIdentifier: language) else { return nil }
    let ns = NSMutableString(string: text)
    ns.replaceCharacters(in: r.range, with: r.replacement)
    return (ns as String, r.newSelection)
}

// MARK: - Line comments

@Test func commentAddsHashAtIndentForPython() {
    let text = "foo\nbar\n"
    let result = applied(text, selection: NSRange(location: 0, length: 0), language: "python")
    #expect(result?.string == "# foo\nbar\n")
}

@Test func commentTogglesOffWhenAllLinesCommented() {
    let text = "# foo\n# bar\n"
    let sel = NSRange(location: 0, length: (text as NSString).length)
    let result = applied(text, selection: sel, language: "python")
    #expect(result?.string == "foo\nbar\n")
}

@Test func commentUncommentToleratesMissingSpace() {
    let text = "#foo\n"
    let result = applied(text, selection: NSRange(location: 0, length: 0), language: "python")
    #expect(result?.string == "foo\n")
}

@Test func commentUsesCommonMinimumIndentColumn() {
    // Two lines at different indents: the comment goes at the shallower column
    // (2 spaces) on both, VS Code style.
    let text = "  a\n    b\n"
    let sel = NSRange(location: 0, length: (text as NSString).length)
    let result = applied(text, selection: sel, language: "python")
    #expect(result?.string == "  # a\n  #   b\n")
}

@Test func commentSkipsBlankLines() {
    // The blank middle line is neither commented nor counted.
    let text = "a\n\nb\n"
    let sel = NSRange(location: 0, length: (text as NSString).length)
    let result = applied(text, selection: sel, language: "python")
    #expect(result?.string == "# a\n\n# b\n")
}

@Test func commentMixedSelectionCommentsAll() {
    // One line already commented, one not → the whole selection becomes commented
    // (not all are commented, so the operation adds).
    let text = "# a\nb\n"
    let sel = NSRange(location: 0, length: (text as NSString).length)
    let result = applied(text, selection: sel, language: "python")
    #expect(result?.string == "# # a\n# b\n")
}

@Test func commentUsesDoubleSlashForSwiftFamily() {
    let text = "let x = 1\n"
    let result = applied(text, selection: NSRange(location: 0, length: 0), language: "javascript")
    #expect(result?.string == "// let x = 1\n")
}

@Test func commentUsesDashesForSQL() {
    let text = "SELECT 1\n"
    let result = applied(text, selection: NSRange(location: 0, length: 0), language: "sql")
    #expect(result?.string == "-- SELECT 1\n")
}

// MARK: - Block comments

@Test func blockCommentWrapsCurrentLineForCSS() {
    let text = "a { color: red; }\n"
    let result = applied(text, selection: NSRange(location: 0, length: 0), language: "css")
    #expect(result?.string == "/* a { color: red; } */\n")
}

@Test func blockCommentUnwrapsWhenAlreadyWrapped() {
    let text = "/* a { color: red; } */\n"
    let result = applied(text, selection: NSRange(location: 0, length: 0), language: "css")
    #expect(result?.string == "a { color: red; }\n")
}

@Test func blockCommentWrapsSelectionForHTML() {
    let text = "<p>hi</p>"
    let sel = NSRange(location: 0, length: (text as NSString).length)
    let result = applied(text, selection: sel, language: "html")
    #expect(result?.string == "<!-- <p>hi</p> -->")
}

// MARK: - No comment syntax

@Test func toggleReturnsNilForJSON() {
    #expect(CommentToggle.toggle(text: "{}", selection: NSRange(location: 0, length: 0),
                                 languageIdentifier: "json") == nil)
}

@Test func toggleReturnsNilForPlainText() {
    #expect(CommentToggle.toggle(text: "hi", selection: NSRange(location: 0, length: 0),
                                 languageIdentifier: "") == nil)
}
