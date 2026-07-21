import Foundation
import Testing
@testable import KaruCore

// Exercises the Batch-3 languages (YAML, TOML, Go, Rust, Swift): tokenizer
// colouring, in-document symbol extraction, comment toggling, and registry /
// SupportedLanguage wiring.

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

/// Applies a `CommentToggle` result to `text` (mirrors `CommentToggleTests`).
private func commentApplied(_ text: String, selection: NSRange, language: String) -> String? {
    guard let r = CommentToggle.toggle(text: text, selection: selection,
                                       languageIdentifier: language) else { return nil }
    let ns = NSMutableString(string: text)
    ns.replaceCharacters(in: r.range, with: r.replacement)
    return ns as String
}

// MARK: - YAML

@Test func yamlKeyValueColouring() {
    let yaml = YAMLLanguage.make()
    let pairs = spans(yaml, "name: Karu")
    #expect(kind(of: "name", in: pairs) == .property)
}

@Test func yamlQuotedKeyAndStringValue() {
    let yaml = YAMLLanguage.make()
    let pairs = spans(yaml, #"title: "Hello World""#)
    #expect(kind(of: "title", in: pairs) == .property)
    #expect(kind(of: #""Hello World""#, in: pairs) == .string)
}

@Test func yamlCommentAndNumber() {
    let yaml = YAMLLanguage.make()
    let pairs = spans(yaml, "port: 8080 # the port")
    #expect(kind(of: "port", in: pairs) == .property)
    #expect(kind(of: "8080", in: pairs) == .number)
    #expect(kind(of: "# the port", in: pairs) == .comment)
}

@Test func yamlBooleanAndNull() {
    let yaml = YAMLLanguage.make()
    #expect(kind(of: "true", in: spans(yaml, "enabled: true")) == .keyword)
    #expect(kind(of: "null", in: spans(yaml, "value: null")) == .keyword)
}

@Test func yamlDocumentMarker() {
    let yaml = YAMLLanguage.make()
    let pairs = spans(yaml, "---")
    #expect(kind(of: "---", in: pairs) == .punctuation)
}

// MARK: - TOML

@Test func tomlTableHeaders() {
    let toml = TOMLLanguage.make()
    #expect(kind(of: "[server]", in: spans(toml, "[server]")) == .type)
    #expect(kind(of: "[[products]]", in: spans(toml, "[[products]]")) == .type)
}

@Test func tomlKeyValueString() {
    let toml = TOMLLanguage.make()
    let pairs = spans(toml, #"name = "Karu""#)
    #expect(kind(of: "name", in: pairs) == .property)
    #expect(kind(of: #""Karu""#, in: pairs) == .string)
}

@Test func tomlCommentAndUnderscoreNumber() {
    let toml = TOMLLanguage.make()
    let pairs = spans(toml, "count = 1_000 # note")
    #expect(kind(of: "count", in: pairs) == .property)
    #expect(kind(of: "1_000", in: pairs) == .number)
    #expect(kind(of: "# note", in: pairs) == .comment)
}

@Test func tomlBooleanAndDate() {
    let toml = TOMLLanguage.make()
    #expect(kind(of: "true", in: spans(toml, "enabled = true")) == .keyword)
    #expect(kind(of: "2026-07-21", in: spans(toml, "created = 2026-07-21")) == .number)
}

// MARK: - Go

@Test func goKeywordsAndTypes() {
    let go = GoLanguage.make()
    let pairs = spans(go, "func main() { var x int = 0 }")
    #expect(kind(of: "func", in: pairs) == .keyword)
    #expect(kind(of: "var", in: pairs) == .keyword)
    #expect(kind(of: "int", in: pairs) == .type)
    #expect(kind(of: "0", in: pairs) == .number)
}

@Test func goStringsRawAndRune() {
    let go = GoLanguage.make()
    let pairs = spans(go, "s := \"hi\"; r := `raw`; c := 'x'")
    #expect(kind(of: #""hi""#, in: pairs) == .string)
    #expect(kind(of: "`raw`", in: pairs) == .string)
    #expect(kind(of: "'x'", in: pairs) == .string)
}

@Test func goBuiltinsAndComment() {
    let go = GoLanguage.make()
    let pairs = spans(go, "n := len(s) // length")
    #expect(kind(of: "len", in: pairs) == .builtin)
    #expect(kind(of: "// length", in: pairs) == .comment)
}

@Test func goSymbolExtraction() {
    let source = """
    func Greet() {}
    func (u User) Name() string { return u.name }
    type User struct {}
    """
    let table = WordIndex.symbolTable(text: source, languageIdentifier: "go")
    #expect(table.functions.contains("Greet"))
    #expect(table.functions.contains("Name"))
    #expect(table.types.contains("User"))
}

// MARK: - Rust

@Test func rustKeywordsAndNumber() {
    let rust = RustLanguage.make()
    let pairs = spans(rust, "fn main() { let mut x = 0; }")
    #expect(kind(of: "fn", in: pairs) == .keyword)
    #expect(kind(of: "let", in: pairs) == .keyword)
    #expect(kind(of: "mut", in: pairs) == .keyword)
    #expect(kind(of: "0", in: pairs) == .number)
}

@Test func rustMacroAndString() {
    let rust = RustLanguage.make()
    let pairs = spans(rust, #"println!("hi")"#)
    #expect(kind(of: "println!", in: pairs) == .builtin)
    #expect(kind(of: #""hi""#, in: pairs) == .string)
}

@Test func rustTypesAndLifetime() {
    let rust = RustLanguage.make()
    let types = spans(rust, "let x: Option<i32> = None;")
    #expect(kind(of: "Option", in: types) == .type)
    #expect(kind(of: "i32", in: types) == .type)
    #expect(kind(of: "None", in: types) == .type)

    let lifetime = spans(rust, "fn f<'a>(x: &'a str) {}")
    #expect(kind(of: "'a", in: lifetime) == .property)
    #expect(kind(of: "str", in: lifetime) == .type)
}

@Test func rustCommentAndSymbolExtraction() {
    let rust = RustLanguage.make()
    #expect(kind(of: "// note", in: spans(rust, "let s = 1; // note")) == .comment)

    let source = """
    fn compute() -> i32 { 0 }
    struct Point { x: i32 }
    enum Color { Red }
    trait Draw {}
    """
    let table = WordIndex.symbolTable(text: source, languageIdentifier: "rust")
    #expect(table.functions.contains("compute"))
    #expect(table.types.contains("Point"))
    #expect(table.types.contains("Color"))
    #expect(table.types.contains("Draw"))
}

// MARK: - Swift

@Test func swiftKeywordsAndString() {
    let swift = SwiftLanguage.make()
    let pairs = spans(swift, #"func greet() { let name = "x" }"#)
    #expect(kind(of: "func", in: pairs) == .keyword)
    #expect(kind(of: "let", in: pairs) == .keyword)
    #expect(kind(of: #""x""#, in: pairs) == .string)
}

@Test func swiftTypesAndBuiltin() {
    let swift = SwiftLanguage.make()
    let types = spans(swift, "let x: Int = 0")
    #expect(kind(of: "Int", in: types) == .type)

    let pairs = spans(swift, #"print("hi")"#)
    #expect(kind(of: "print", in: pairs) == .builtin)
    #expect(kind(of: #""hi""#, in: pairs) == .string)
}

@Test func swiftAttributeAndComment() {
    let swift = SwiftLanguage.make()
    let pairs = spans(swift, "@objc class Foo {} // note")
    #expect(kind(of: "@objc", in: pairs) == .type)
    #expect(kind(of: "class", in: pairs) == .keyword)
    #expect(kind(of: "// note", in: pairs) == .comment)
}

@Test func swiftSymbolExtraction() {
    let source = """
    func compute() {}
    class Widget {}
    struct Point {}
    enum Color {}
    protocol Drawable {}
    let answer = 42
    """
    let table = WordIndex.symbolTable(text: source, languageIdentifier: "swift")
    #expect(table.functions.contains("compute"))
    #expect(table.types.contains("Widget"))
    #expect(table.types.contains("Point"))
    #expect(table.types.contains("Color"))
    #expect(table.types.contains("Drawable"))
    #expect(table.variables.contains("answer"))
}

// MARK: - Comment toggle

@Test func tomlCommentToggleAddsHash() {
    let result = commentApplied("key = 1\n", selection: NSRange(location: 0, length: 0), language: "toml")
    #expect(result == "# key = 1\n")
}

@Test func goCommentToggleAddsSlashes() {
    let result = commentApplied("x := 1\n", selection: NSRange(location: 0, length: 0), language: "go")
    #expect(result == "// x := 1\n")
}

@Test func rustCommentToggleAddsSlashes() {
    let result = commentApplied("let x = 1;\n", selection: NSRange(location: 0, length: 0), language: "rust")
    #expect(result == "// let x = 1;\n")
}

// MARK: - Registry / SupportedLanguage wiring

@Test func registryResolvesAllBatch3Extensions() {
    let expected: [String: String] = [
        "yaml": "yaml", "yml": "yaml",
        "toml": "toml",
        "go": "go",
        "rs": "rust",
        "swift": "swift",
    ]
    for (ext, id) in expected {
        #expect(LanguageRegistry.definition(forExtension: ext)?.identifier == id)
        #expect(LanguageRegistry.definition(forExtension: ext.uppercased())?.identifier == id)
        #expect(LanguageRegistry.definition(forExtension: ext)?.fileExtensions.contains(ext) == true)
    }
    // Menu identifiers resolve to a real definition.
    for id in ["yaml", "toml", "go", "rust", "swift"] {
        #expect(LanguageRegistry.definition(forIdentifier: id)?.identifier == id)
    }
}

@Test func supportedLanguageListCoversBatch3() {
    let ids = Set(SupportedLanguage.all.map(\.identifier))
    for id in ["yaml", "toml", "go", "rust", "swift"] {
        #expect(ids.contains(id))
    }
}
