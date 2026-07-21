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

// MARK: - C

@Test func cPreprocessorLine() {
    let c = CLanguage.make()
    let pairs = spans(c, "#include <stdio.h>")
    #expect(kind(of: "#include", in: pairs) == .type)
}

@Test func cKeywordsStringAndCharLiteral() {
    let c = CLanguage.make()
    let pairs = spans(c, #"int main() { char c = 'x'; char *s = "hi"; return 0; }"#)
    #expect(kind(of: "int", in: pairs) == .keyword)
    #expect(kind(of: "char", in: pairs) == .keyword)
    #expect(kind(of: "return", in: pairs) == .keyword)
    #expect(kind(of: "'x'", in: pairs) == .string)
    #expect(kind(of: #""hi""#, in: pairs) == .string)
}

@Test func cNumbersHexAndSuffix() {
    let c = CLanguage.make()
    let pairs = spans(c, "unsigned long x = 0xFFu; float f = 1.5f;")
    #expect(kind(of: "0xFFu", in: pairs) == .number)
    #expect(kind(of: "1.5f", in: pairs) == .number)
}

// MARK: - C++

@Test func cppScopeResolutionAndTemplate() {
    let cpp = CppLanguage.make()
    let pairs = spans(cpp, "template<typename T> class Foo { std::string s; };")
    #expect(kind(of: "template", in: pairs) == .keyword)
    #expect(kind(of: "typename", in: pairs) == .keyword)
    #expect(kind(of: "class", in: pairs) == .keyword)
    #expect(kind(of: "::", in: pairs) == .punctuation)
}

@Test func cppRawStringAndCastKeywords() {
    let cpp = CppLanguage.make()
    let pairs = spans(cpp, #"auto s = R"(raw text)"; auto p = static_cast<int*>(nullptr);"#)
    #expect(kind(of: #"R"(raw text)""#, in: pairs) == .string)
    #expect(kind(of: "static_cast", in: pairs) == .keyword)
    #expect(kind(of: "nullptr", in: pairs) == .keyword)
}

@Test func cppInheritsCKeywordsAndNumbers() {
    let cpp = CppLanguage.make()
    let pairs = spans(cpp, "const int x = 0x10; // note")
    #expect(kind(of: "const", in: pairs) == .keyword)   // inherited from C
    #expect(kind(of: "0x10", in: pairs) == .number)
    #expect(kind(of: "// note", in: pairs) == .comment)
}

// MARK: - C#

@Test func csharpVerbatimAndInterpolatedStrings() {
    let cs = CSharpLanguage.make()
    let verbatim = spans(cs, #"string path = @"C:\temp\a.txt";"#)
    #expect(kind(of: #"@"C:\temp\a.txt""#, in: verbatim) == .string)

    let interpolated = spans(cs, #"string s = $"hi {name}";"#)
    #expect(kind(of: #"$"hi {name}""#, in: interpolated) == .string)
}

@Test func csharpKeywordsAndAttribute() {
    let cs = CSharpLanguage.make()
    let pairs = spans(cs, "[Obsolete] public class Foo : Bar {}")
    #expect(kind(of: "[Obsolete]", in: pairs) == .type)
    #expect(kind(of: "public", in: pairs) == .keyword)
    #expect(kind(of: "class", in: pairs) == .keyword)
}

@Test func csharpNumbers() {
    let cs = CSharpLanguage.make()
    let pairs = spans(cs, "decimal d = 1.5m; int n = 0xFF;")
    #expect(kind(of: "1.5m", in: pairs) == .number)
    #expect(kind(of: "0xFF", in: pairs) == .number)
}

// MARK: - Java

@Test func javaAnnotationAndKeywords() {
    let java = JavaLanguage.make()
    let pairs = spans(java, "@Override public void run() throws Exception {}")
    #expect(kind(of: "@Override", in: pairs) == .type)
    #expect(kind(of: "public", in: pairs) == .keyword)
    #expect(kind(of: "void", in: pairs) == .keyword)
    #expect(kind(of: "throws", in: pairs) == .keyword)
}

@Test func javaStringAndComment() {
    let java = JavaLanguage.make()
    let pairs = spans(java, #"String s = "hi"; // note"#)
    #expect(kind(of: #""hi""#, in: pairs) == .string)
    #expect(kind(of: "// note", in: pairs) == .comment)
}

@Test func javaNumberWithSuffixAndUnderscore() {
    let java = JavaLanguage.make()
    let pairs = spans(java, "long big = 1_000_000L; double d = 3.14d;")
    #expect(kind(of: "1_000_000L", in: pairs) == .number)
    #expect(kind(of: "3.14d", in: pairs) == .number)
}

// MARK: - Bash

@Test func bashShebangLine() {
    let bash = BashLanguage.make()
    let pairs = spans(bash, "#!/bin/bash")
    #expect(kind(of: "#!/bin/bash", in: pairs) == .type)
}

@Test func bashVariableExpansion() {
    let bash = BashLanguage.make()
    let pairs = spans(bash, "NAME=$USER; echo ${HOME}")
    #expect(kind(of: "$USER", in: pairs) == .property)
    #expect(kind(of: "${HOME}", in: pairs) == .property)
}

@Test func bashKeywordsAndComment() {
    let bash = BashLanguage.make()
    let pairs = spans(bash, "if [ -f x ]; then echo hi; fi # done")
    #expect(kind(of: "if", in: pairs) == .keyword)
    #expect(kind(of: "then", in: pairs) == .keyword)
    #expect(kind(of: "fi", in: pairs) == .keyword)
    #expect(kind(of: "# done", in: pairs) == .comment)
}

// MARK: - SQL

@Test func sqlCaseInsensitiveKeywords() {
    let sql = SQLLanguage.make()
    let pairs = spans(sql, "select * from Users where id = 1; -- note")
    #expect(kind(of: "select", in: pairs) == .keyword)
    #expect(kind(of: "from", in: pairs) == .keyword)
    #expect(kind(of: "where", in: pairs) == .keyword)
    #expect(kind(of: "-- note", in: pairs) == .comment)

    let upper = spans(sql, "SELECT * FROM Users WHERE id = 1")
    #expect(kind(of: "SELECT", in: upper) == .keyword)
    #expect(kind(of: "FROM", in: upper) == .keyword)
}

@Test func sqlStringAndEscapedQuote() {
    let sql = SQLLanguage.make()
    let pairs = spans(sql, "INSERT INTO t (name) VALUES ('O''Brien');")
    #expect(kind(of: "INSERT", in: pairs) == .keyword)
    #expect(kind(of: "'O''Brien'", in: pairs) == .string)
}

@Test func sqlNumberLiteral() {
    let sql = SQLLanguage.make()
    let pairs = spans(sql, "SELECT price FROM t WHERE price > 10.5")
    #expect(kind(of: "10.5", in: pairs) == .number)
}

// MARK: - XML / plist

@Test func xmlPlistKeyValuePair() {
    let xml = XMLPlistLanguage.make()
    let pairs = spans(xml, "<key>Name</key>")
    #expect(kind(of: "<key", in: pairs) == .keyword)
    #expect(kind(of: "</key", in: pairs) == .keyword)
}

@Test func xmlAttributesAndDeclaration() {
    let xml = XMLPlistLanguage.make()
    let pairs = spans(xml, #"<?xml version="1.0" encoding="UTF-8"?>"#)
    #expect(kind(of: #"<?xml version="1.0" encoding="UTF-8"?>"#, in: pairs) == .type)

    let tag = spans(xml, #"<string key="value">text</string>"#)
    #expect(kind(of: "key", in: tag) == .property)
    #expect(kind(of: #""value""#, in: tag) == .string)
}

@Test func xmlDoctypeAndComment() {
    let xml = XMLPlistLanguage.make()
    let doctype = spans(xml, "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\">")
    #expect(kind(of: "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\">", in: doctype) == .type)

    let comment = spans(xml, "<!-- hi -->")
    #expect(kind(of: "<!-- hi -->", in: comment) == .comment)
}

// MARK: - Registry: every registered Batch-2 extension resolves to the right identifier

@Test func registryResolvesAllBatch2Extensions() {
    let expected: [String: String] = [
        "c": "c", "h": "c",
        "cpp": "cpp", "cc": "cpp", "cxx": "cpp", "hpp": "cpp", "hh": "cpp",
        "cs": "csharp",
        "java": "java",
        "sh": "bash", "bash": "bash", "zsh": "bash",
        "sql": "sql",
        "xml": "xml", "plist": "xml", "svg": "xml", "xib": "xml", "storyboard": "xml",
    ]
    for (ext, id) in expected {
        #expect(LanguageRegistry.definition(forExtension: ext)?.identifier == id)
        // Case-insensitive resolution.
        #expect(LanguageRegistry.definition(forExtension: ext.uppercased())?.identifier == id)
        // The definition claims the extension it was resolved by.
        #expect(LanguageRegistry.definition(forExtension: ext)?.fileExtensions.contains(ext) == true)
    }
}

@Test func supportedExtensionsCoverBatch2() {
    let supported = Set(LanguageRegistry.supportedExtensions)
    for ext in ["c", "h", "cpp", "cc", "cxx", "hpp", "hh", "cs", "java",
                "sh", "bash", "zsh", "sql", "xml", "plist", "svg", "xib", "storyboard"] {
        #expect(supported.contains(ext))
    }
}
