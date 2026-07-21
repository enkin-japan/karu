import Testing
@testable import KaruCore

// Each rule gets at least one positive and one negative case, plus the 8 KB
// truncation boundary. The sniffer is pure logic (no AppKit), so no @MainActor.

// MARK: - Shebang

@Test func sniffsPythonShebang() {
    #expect(LanguageSniffer.sniff("#!/usr/bin/env python3\nprint('hi')") == "python")
}

@Test func sniffsBashShebang() {
    #expect(LanguageSniffer.sniff("#!/bin/bash\necho hi") == "bash")
    #expect(LanguageSniffer.sniff("#!/bin/sh\necho hi") == "bash")
}

@Test func sniffsNodeShebang() {
    #expect(LanguageSniffer.sniff("#!/usr/bin/env node\nconsole.log(1)") == "javascript")
}

@Test func unknownShebangIsNotClaimed() {
    // A ruby shebang matches no interpreter rule and the body no other rule.
    #expect(LanguageSniffer.sniff("#!/usr/bin/env ruby\nputs 1") == nil)
}

// MARK: - XML / HTML

@Test func sniffsXMLDeclaration() {
    #expect(LanguageSniffer.sniff("<?xml version=\"1.0\"?>\n<root/>") == "xml")
    #expect(LanguageSniffer.sniff("<!DOCTYPE plist PUBLIC \"-//Apple//\">\n<plist/>") == "xml")
}

@Test func sniffsHTML() {
    #expect(LanguageSniffer.sniff("<!DOCTYPE html>\n<html></html>") == "html")
    #expect(LanguageSniffer.sniff("<html>\n<body></body>\n</html>") == "html")
}

@Test func plainAngleBracketsAreNotMarkup() {
    #expect(LanguageSniffer.sniff("a < b and c > d\nfoo") == nil)
}

// MARK: - JSON / JSONL

@Test func sniffsJSONObject() {
    let json = "{\n  \"a\": 1,\n  \"b\": [1, 2, 3]\n}"
    #expect(LanguageSniffer.sniff(json) == "json")
}

@Test func sniffsJSONL() {
    let jsonl = "{\"a\": 1}\n{\"b\": 2}\n{\"c\": 3}"
    #expect(LanguageSniffer.sniff(jsonl) == "jsonl")
}

@Test func brokenBraceIsNotJSON() {
    #expect(LanguageSniffer.sniff("{ this is not json at all") == nil)
}

// MARK: - Markdown

@Test func sniffsMarkdownHeadings() {
    #expect(LanguageSniffer.sniff("# Title\n## Section\nbody text") == "markdown")
}

@Test func sniffsMarkdownFences() {
    #expect(LanguageSniffer.sniff("intro\n```\ncode\n```\nmore") == "markdown")
}

@Test func singleHeadingIsNotEnoughForMarkdown() {
    #expect(LanguageSniffer.sniff("# Only one heading\njust prose here") == nil)
}

// MARK: - Python

@Test func sniffsPythonKeywords() {
    #expect(LanguageSniffer.sniff("import os\ndef main():\n    pass") == "python")
}

@Test func plainAssignmentsAreNotPython() {
    #expect(LanguageSniffer.sniff("x = 1\ny = 2\nz = x + y") == nil)
}

// MARK: - JavaScript / TypeScript

@Test func sniffsJavaScript() {
    #expect(LanguageSniffer.sniff("const a = 1\nfunction greet() {}") == "javascript")
}

@Test func plainWordsAreNotJavaScript() {
    #expect(LanguageSniffer.sniff("hello world\nsome plain notes\nnothing here") == nil)
}

// MARK: - C

@Test func sniffsCInclude() {
    #expect(LanguageSniffer.sniff("#include <stdio.h>\nint main(void) { return 0; }") == "c")
}

@Test func plainCodeWithoutIncludeIsNotC() {
    #expect(LanguageSniffer.sniff("int x = 1;\nreturn x;") == nil)
}

// MARK: - SQL

@Test func sniffsSQL() {
    #expect(LanguageSniffer.sniff("SELECT * FROM users\nWHERE id = 1") == "sql")
    #expect(LanguageSniffer.sniff("create table t (id int)") == "sql")
}

@Test func keywordNotAtLineStartIsNotSQL() {
    #expect(LanguageSniffer.sniff("please select an option\nthen continue") == nil)
}

// MARK: - Empty / unknown

@Test func emptyTextYieldsNil() {
    #expect(LanguageSniffer.sniff("") == nil)
    #expect(LanguageSniffer.sniff("   \n  \n") == nil)
}

// MARK: - 8 KB truncation boundary

@Test func doesNotSniffBeyond8KB() {
    // ~10 KB of neutral filler pushes the Python markers past the 8 KB window,
    // so they are never seen and detection yields nil.
    let filler = String(repeating: "a\n", count: 5000)
    let hidden = filler + "def one():\n    pass\ndef two():\n    pass\n"
    #expect(LanguageSniffer.sniff(hidden) == nil)
}

@Test func sniffsWithin8KB() {
    // Same markers, now at the front (within the window), are detected even
    // with trailing filler beyond 8 KB.
    let filler = String(repeating: "a\n", count: 5000)
    let visible = "def one():\n    pass\ndef two():\n    pass\n" + filler
    #expect(LanguageSniffer.sniff(visible) == "python")
}

@Test func esModuleImportsClassifyAsJavaScriptNotPython() {
    let js = """
    import React from 'react'
    import { useState } from 'react'
    """
    #expect(LanguageSniffer.sniff(js) == "javascript")
}

@Test func pythonImportsStillClassifyAsPython() {
    let py = """
    import os
    from pathlib import Path
    """
    #expect(LanguageSniffer.sniff(py) == "python")
}
