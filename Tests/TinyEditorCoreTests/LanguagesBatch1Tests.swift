import Foundation
import Testing
@testable import TinyEditorCore

// MARK: - Helpers

/// Tokenizes `line` and returns `(text, kind)` pairs for readable assertions.
private func spans(_ def: LanguageDefinition, _ line: String) -> [(text: String, kind: TokenKind)] {
    let ns = line as NSString
    return def.tokenize(line: line).map { (ns.substring(with: $0.range), $0.kind) }
}

/// Kind assigned to the first token whose text equals `text`, or nil.
private func kind(of text: String, in pairs: [(text: String, kind: TokenKind)]) -> TokenKind? {
    pairs.first { $0.text == text }?.kind
}

// MARK: - JSONL (isomorphic to JSON)

@Test func jsonlIsStructurallyIdenticalToJSON() {
    let def = JSONLLanguage.make()
    #expect(def.identifier == "jsonl")

    let pairs = spans(def, #"{"k": 1, "v": true, "s": "x"}"#)
    #expect(kind(of: #""k""#, in: pairs) == .property)   // key
    #expect(kind(of: "1", in: pairs) == .number)
    #expect(kind(of: "true", in: pairs) == .keyword)
    #expect(kind(of: #""x""#, in: pairs) == .string)     // value string
    #expect(kind(of: "{", in: pairs) == .punctuation)
}

@Test func jsonlRulesMatchJSONRules() {
    // Same rule set → same classification for the same line.
    let json = JSONLanguage.make()
    let jsonl = JSONLLanguage.make()
    let line = #"[-0.5, false, null, "a\"b"]"#
    #expect(spans(json, line).map(\.kind) == spans(jsonl, line).map(\.kind))
}

// MARK: - Markdown

@Test func markdownHeadingIsWholeLineKeyword() {
    let md = MarkdownLanguage.make()
    let pairs = spans(md, "## Heading here")
    #expect(kind(of: "## Heading here", in: pairs) == .keyword)
}

@Test func markdownInlineCodeAndEmphasis() {
    let md = MarkdownLanguage.make()
    let pairs = spans(md, "text `code` and **bold** here")
    #expect(kind(of: "`code`", in: pairs) == .string)
    #expect(kind(of: "**bold**", in: pairs) == .keyword)
}

@Test func markdownLinkSplitsTextAndURL() {
    let md = MarkdownLanguage.make()
    let pairs = spans(md, "see [txt](http://x) end")
    #expect(kind(of: "[txt]", in: pairs) == .property)
    #expect(kind(of: "(http://x)", in: pairs) == .string)
}

@Test func markdownListMarkerAndBlockquote() {
    let md = MarkdownLanguage.make()
    #expect(kind(of: "- ", in: spans(md, "- item")) == .punctuation)
    #expect(kind(of: "1. ", in: spans(md, "1. item")) == .punctuation)
    #expect(kind(of: "> quoted", in: spans(md, "> quoted")) == .comment)
    #expect(kind(of: "```swift", in: spans(md, "```swift")) == .comment)
}

// MARK: - Python

@Test func pythonKeywordsSelfAndNumbers() {
    let py = PythonLanguage.make()
    let pairs = spans(py, "def foo(self, x=1_000): return 0xFF")
    #expect(kind(of: "def", in: pairs) == .keyword)
    #expect(kind(of: "return", in: pairs) == .keyword)
    #expect(kind(of: "self", in: pairs) == .property)
    #expect(kind(of: "1_000", in: pairs) == .number)   // underscore separator
    #expect(kind(of: "0xFF", in: pairs) == .number)    // hex
}

@Test func pythonTripleQuotedStringWholeLine() {
    let py = PythonLanguage.make()
    let pairs = spans(py, "'''a docstring line'''")
    #expect(kind(of: "'''a docstring line'''", in: pairs) == .string)
    // Opening-only line colours to end of line.
    let open = spans(py, #"x = """opening"#)
    #expect(kind(of: #""""opening"#, in: open) == .string)
}

@Test func pythonFStringCommentAndDecorator() {
    let py = PythonLanguage.make()
    let pairs = spans(py, #"s = f"hi {name}"  # note"#)
    #expect(kind(of: #"f"hi {name}""#, in: pairs) == .string)
    #expect(kind(of: "# note", in: pairs) == .comment)

    let deco = spans(py, "@app.route")
    #expect(kind(of: "@app.route", in: deco) == .type)
}

@Test func pythonImaginaryNumber() {
    let py = PythonLanguage.make()
    #expect(kind(of: "3.14j", in: spans(py, "z = 3.14j")) == .number)
}

// MARK: - JavaScript

@Test func javascriptKeywordsAndNumbers() {
    let js = JavaScriptLanguage.make()
    let pairs = spans(js, "const n = 0xFF; let big = 10n;")
    #expect(kind(of: "const", in: pairs) == .keyword)
    #expect(kind(of: "let", in: pairs) == .keyword)
    #expect(kind(of: "0xFF", in: pairs) == .number)
    #expect(kind(of: "10n", in: pairs) == .number)   // BigInt suffix
}

@Test func javascriptTemplateStringAndBlockComment() {
    let js = JavaScriptLanguage.make()
    let pairs = spans(js, "const x = `tmpl ${y}`; /* c */ z = 1;")
    #expect(kind(of: "`tmpl ${y}`", in: pairs) == .string)
    #expect(kind(of: "/* c */", in: pairs) == .comment)
}

@Test func javascriptLineComment() {
    let js = JavaScriptLanguage.make()
    let pairs = spans(js, "// this is a comment with a fake 0xFF")
    #expect(kind(of: "// this is a comment with a fake 0xFF", in: pairs) == .comment)
}

// MARK: - TypeScript

@Test func typescriptExtraKeywordsAndPrimitiveTypes() {
    let ts = TypeScriptLanguage.make()
    let pairs = spans(ts, "interface Foo { name: string; count: number }")
    #expect(kind(of: "interface", in: pairs) == .keyword)
    #expect(kind(of: "string", in: pairs) == .type)   // primitive type
    #expect(kind(of: "number", in: pairs) == .type)
}

@Test func typescriptStillHandlesJSConstructs() {
    let ts = TypeScriptLanguage.make()
    let pairs = spans(ts, "const enum E {} // note")
    #expect(kind(of: "const", in: pairs) == .keyword)   // inherited from JS
    #expect(kind(of: "enum", in: pairs) == .keyword)    // TS-only
    #expect(kind(of: "// note", in: pairs) == .comment)
}

@Test func typescriptModifierKeywords() {
    let ts = TypeScriptLanguage.make()
    let pairs = spans(ts, "private readonly x: boolean")
    #expect(kind(of: "private", in: pairs) == .keyword)
    #expect(kind(of: "readonly", in: pairs) == .keyword)
    #expect(kind(of: "boolean", in: pairs) == .type)
}

// MARK: - HTML

@Test func htmlTagAttributesAndValues() {
    let html = HTMLLanguage.make()
    let pairs = spans(html, #"<div class="a" id='b'></div>"#)
    #expect(kind(of: "<div", in: pairs) == .keyword)
    #expect(kind(of: "</div", in: pairs) == .keyword)
    #expect(kind(of: "class", in: pairs) == .property)
    #expect(kind(of: "id", in: pairs) == .property)
    #expect(kind(of: #""a""#, in: pairs) == .string)
    #expect(kind(of: "'b'", in: pairs) == .string)
}

@Test func htmlEntityAndComment() {
    let html = HTMLLanguage.make()
    #expect(kind(of: "&amp;", in: spans(html, "x &amp; y")) == .number)
    #expect(kind(of: "&#169;", in: spans(html, "&#169;")) == .number)
    #expect(kind(of: "<!-- hi -->", in: spans(html, "<!-- hi -->")) == .comment)
}

@Test func htmlCustomElementTagName() {
    let html = HTMLLanguage.make()
    #expect(kind(of: "<my-element", in: spans(html, "<my-element>")) == .keyword)
}

// MARK: - CSS

@Test func cssPropertyColorAndUnit() {
    let css = CSSLanguage.make()
    let pairs = spans(css, "color: #fff; margin: 10px;")
    #expect(kind(of: "color", in: pairs) == .property)
    #expect(kind(of: "#fff", in: pairs) == .number)
    #expect(kind(of: "margin", in: pairs) == .property)
    #expect(kind(of: "10px", in: pairs) == .number)
}

@Test func cssAtRuleImportantAndComment() {
    let css = CSSLanguage.make()
    let pairs = spans(css, "@media screen { /* c */ } .x { color: red !important; }")
    #expect(kind(of: "@media", in: pairs) == .keyword)
    #expect(kind(of: "/* c */", in: pairs) == .comment)
    #expect(kind(of: "!important", in: pairs) == .keyword)
}

@Test func cssStringValue() {
    let css = CSSLanguage.make()
    let pairs = spans(css, #"content: "hello";"#)
    #expect(kind(of: "content", in: pairs) == .property)
    #expect(kind(of: #""hello""#, in: pairs) == .string)
}

// MARK: - Registry: every registered extension resolves to the right identifier

@Test func registryResolvesAllBatch1Extensions() {
    let expected: [String: String] = [
        "json": "json",
        "jsonl": "jsonl", "ndjson": "jsonl",
        "md": "markdown", "markdown": "markdown",
        "py": "python", "pyw": "python",
        "js": "javascript", "mjs": "javascript", "cjs": "javascript",
        "ts": "typescript",
        "html": "html", "htm": "html",
        "css": "css",
    ]
    for (ext, id) in expected {
        #expect(LanguageRegistry.definition(forExtension: ext)?.identifier == id)
        // Case-insensitive resolution.
        #expect(LanguageRegistry.definition(forExtension: ext.uppercased())?.identifier == id)
        // The definition claims the extension it was resolved by.
        #expect(LanguageRegistry.definition(forExtension: ext)?.fileExtensions.contains(ext) == true)
    }
}

@Test func supportedExtensionsCoverBatch1() {
    let supported = Set(LanguageRegistry.supportedExtensions)
    for ext in ["json", "jsonl", "ndjson", "md", "markdown", "py", "pyw",
                "js", "mjs", "cjs", "ts", "html", "htm", "css"] {
        #expect(supported.contains(ext))
    }
}

// MARK: - Identifier ↔ IndentSettings key-style consistency

@Test func identifiersUseIndentSettingsKeyStyle() {
    // Identifiers are lowercase and (for the markup / data languages) line up
    // with `IndentSettings.languageDefaults` keys, so indent width can be
    // looked up straight from the resolved identifier.
    let settings = IndentSettings(defaults: UserDefaults(suiteName: "Batch1-\(UUID().uuidString)")!)

    for (ext, expectedWidth) in [("markdown", 2), ("html", 2), ("css", 2),
                                 ("json", 2), ("jsonl", 2)] {
        let id = LanguageRegistry.definition(forExtension: ext)!.identifier
        #expect(id == id.lowercased())
        #expect(IndentSettings.languageDefaults[id] != nil)
        #expect(settings.width(for: id) == expectedWidth)
    }

    // Languages without a built-in default fall back to the global width.
    for ext in ["py", "js", "ts"] {
        let id = LanguageRegistry.definition(forExtension: ext)!.identifier
        #expect(id == id.lowercased())
        #expect(settings.width(for: id) == IndentSettings.defaultWidth)
    }
}
