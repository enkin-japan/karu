import Foundation
import Testing
@testable import TinyEditorCore

// MARK: - Helpers

/// Unwraps a success result or fails the test.
private func expectSuccess<T>(_ result: Result<T, SearchError>,
                              sourceLocation: SourceLocation = #_sourceLocation) -> T? {
    switch result {
    case .success(let value):
        return value
    case .failure(let error):
        Issue.record("expected success but got error: \(error.description)", sourceLocation: sourceLocation)
        return nil
    }
}

// MARK: - Plain-text search

@Test func plainTextCaseInsensitiveMatchesAllCasings() {
    let text = "Foo foo FOO fOo"
    let result = SearchEngine.matches(in: text, pattern: "foo",
                                      options: SearchOptions(regex: false, caseSensitive: false))
    let ranges = expectSuccess(result)
    #expect(ranges?.count == 4)
    #expect(ranges?.first == NSRange(location: 0, length: 3))
}

@Test func plainTextCaseSensitiveMatchesOnlyExactCasing() {
    let text = "Foo foo FOO fOo"
    let result = SearchEngine.matches(in: text, pattern: "foo",
                                      options: SearchOptions(regex: false, caseSensitive: true))
    let ranges = expectSuccess(result)
    #expect(ranges?.count == 1)
    #expect(ranges?.first == NSRange(location: 4, length: 3))
}

@Test func plainTextTreatsMetacharactersLiterally() {
    // In plain-text mode "a.c" should only match the literal "a.c", not "abc".
    let text = "abc a.c axc"
    let result = SearchEngine.matches(in: text, pattern: "a.c",
                                      options: SearchOptions(regex: false, caseSensitive: true))
    let ranges = expectSuccess(result)
    #expect(ranges?.count == 1)
    #expect(ranges?.first == NSRange(location: 4, length: 3))
}

// MARK: - Regex search

@Test func regexDigitRunsAreMatched() {
    let text = "a1 22 333 bb 4"
    let result = SearchEngine.matches(in: text, pattern: "\\d+",
                                      options: SearchOptions(regex: true, caseSensitive: true))
    let ranges = expectSuccess(result)
    #expect(ranges?.count == 4)
    #expect(ranges == [
        NSRange(location: 1, length: 1),
        NSRange(location: 3, length: 2),
        NSRange(location: 6, length: 3),
        NSRange(location: 13, length: 1),
    ])
}

@Test func regexAnchorsMatchEachLine() {
    // ^\w+ with anchorsMatchLines should match the first word on every line.
    let text = "alpha beta\ngamma delta\nepsilon"
    let result = SearchEngine.matches(in: text, pattern: "^\\w+",
                                      options: SearchOptions(regex: true, caseSensitive: true))
    let ranges = expectSuccess(result)
    let ns = text as NSString
    #expect(ranges?.count == 3)
    #expect(ranges?.map { ns.substring(with: $0) } == ["alpha", "gamma", "epsilon"])
}

@Test func regexEndAnchorMatchesLineEnds() {
    let text = "one\ntwo\nthree"
    let result = SearchEngine.matches(in: text, pattern: "\\w+$",
                                      options: SearchOptions(regex: true, caseSensitive: true))
    let ranges = expectSuccess(result)
    let ns = text as NSString
    #expect(ranges?.map { ns.substring(with: $0) } == ["one", "two", "three"])
}

// MARK: - Empty & invalid patterns

@Test func emptyPatternReturnsNoMatches() {
    let result = SearchEngine.matches(in: "anything here", pattern: "",
                                      options: SearchOptions(regex: true, caseSensitive: false))
    #expect(expectSuccess(result)?.isEmpty == true)
}

@Test func invalidRegexReturnsError() {
    let result = SearchEngine.matches(in: "text", pattern: "a(b",
                                      options: SearchOptions(regex: true, caseSensitive: true))
    switch result {
    case .success:
        Issue.record("expected an error for an unbalanced group")
    case .failure(let error):
        #expect(!error.description.isEmpty)
    }
}

@Test func invalidRegexPropagatesThroughReplaceAll() {
    let result = SearchEngine.replaceAll(in: "text", pattern: "*bad",
                                         options: SearchOptions(regex: true, caseSensitive: true),
                                         template: "x")
    #expect(result.isFailure)
}

// MARK: - Replace all

@Test func replaceAllWithCaptureGroupTemplate() {
    // Swap "key: value" into "value=key" using capture groups.
    let text = "name: alice\nrole: admin"
    let result = SearchEngine.replaceAll(in: text, pattern: "(\\w+): (\\w+)",
                                         options: SearchOptions(regex: true, caseSensitive: true),
                                         template: "$2=$1")
    #expect(expectSuccess(result) == "alice=name\nadmin=role")
}

@Test func replaceAllPlainTextTreatsDollarLiterally() {
    // Plain-text template: "$1" must be inserted verbatim, not as a group ref.
    let text = "price A price B"
    let result = SearchEngine.replaceAll(in: text, pattern: "price",
                                         options: SearchOptions(regex: false, caseSensitive: true),
                                         template: "$1")
    #expect(expectSuccess(result) == "$1 A $1 B")
}

@Test func replaceAllPlainTextCaseInsensitive() {
    let text = "Cat cat CAT"
    let result = SearchEngine.replaceAll(in: text, pattern: "cat",
                                         options: SearchOptions(regex: false, caseSensitive: false),
                                         template: "dog")
    #expect(expectSuccess(result) == "dog dog dog")
}

@Test func replaceAllEmptyPatternLeavesTextUnchanged() {
    let text = "unchanged"
    let result = SearchEngine.replaceAll(in: text, pattern: "",
                                         options: SearchOptions(regex: true, caseSensitive: false),
                                         template: "x")
    #expect(expectSuccess(result) == "unchanged")
}

// MARK: - Single replacement

@Test func replacementTextResolvesCaptureGroups() {
    let text = "name: alice\nrole: admin"
    // Resolve only the first match's replacement.
    let matches = expectSuccess(SearchEngine.matches(in: text, pattern: "(\\w+): (\\w+)",
                                                     options: SearchOptions(regex: true, caseSensitive: true)))
    let firstRange = try! #require(matches?.first)
    let result = SearchEngine.replacementText(for: firstRange, in: text,
                                              pattern: "(\\w+): (\\w+)",
                                              options: SearchOptions(regex: true, caseSensitive: true),
                                              template: "$2=$1")
    #expect(expectSuccess(result) == "alice=name")
}

@Test func replacementTextPlainDollarLiteral() {
    let text = "aa bb aa"
    let matches = expectSuccess(SearchEngine.matches(in: text, pattern: "aa",
                                                     options: SearchOptions(regex: false, caseSensitive: true)))
    let firstRange = try! #require(matches?.first)
    let result = SearchEngine.replacementText(for: firstRange, in: text,
                                              pattern: "aa",
                                              options: SearchOptions(regex: false, caseSensitive: true),
                                              template: "$0")
    #expect(expectSuccess(result) == "$0")
}

// MARK: - Result helper

private extension Result {
    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}
