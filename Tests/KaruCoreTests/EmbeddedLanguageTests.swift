import AppKit
import Foundation
import Testing
@testable import KaruCore

// M17 T17.8a — embedded languages in the generic scanner (plan §7): HTML
// `<script>` / `<style>` bodies and Markdown fenced code blocks scanned and
// coloured as their child language; the split guarantee and safe points for
// the composite state; checkpoint resume inside bodies; a long minified line
// with inline script and style painted in slices.

// MARK: - Helpers

private let highlightFixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // KaruCoreTests
    .deletingLastPathComponent()   // Tests
    .appendingPathComponent("Fixtures/M17/highlight", isDirectory: true)

private func fixture(_ name: String) throws -> String {
    try String(contentsOf: highlightFixtures.appendingPathComponent(name), encoding: .utf8)
}

/// Deterministic generator (SplitMix64) so failures reproduce.
private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A segment with its language (0: the host).
private struct Seg: Equatable, CustomStringConvertible {
    let range: NSRange
    let kind: LexicalSegment
    let language: Int
    var description: String { "\(range.location)+\(range.length) \(kind) @\(language)" }
}

/// A segment kind in a language, for set comparisons.
private struct Pair: Hashable {
    let kind: LexicalSegment
    let language: Int
}

/// Merges adjacent runs of the same kind and language.
private func merged(_ segments: [Seg]) -> [Seg] {
    var out: [Seg] = []
    for s in segments {
        if let last = out.last, last.kind == s.kind, last.language == s.language,
           NSMaxRange(last.range) == s.range.location {
            out[out.count - 1] = Seg(range: NSRange(location: last.range.location,
                                                    length: last.range.length + s.range.length),
                                     kind: s.kind, language: s.language)
        } else {
            out.append(s)
        }
    }
    return out
}

private func definition(_ language: String) throws -> LanguageDefinition {
    try #require(LanguageRegistry.definition(forIdentifier: language))
}

/// Index of a Markdown fence language (`MarkdownLanguage.fenceLanguages`).
private func md(_ identifier: String) -> Int {
    (MarkdownLanguage.fenceLanguages.firstIndex { $0.identifier == identifier } ?? -1) + 1
}

private let js = 1, css = 2   // HTML embeds

/// One pass of a language's scanner over a text, with segment languages.
private struct Scan {
    let ns: NSString
    let segments: [Seg]
    let end: LexicalScanState
    private let pairs: [Pair]

    init(_ language: String, _ text: String) throws {
        let scanner = try #require(try definition(language).lexicalScanner)
        self.init(scanner, text as NSString)
    }

    init(_ scanner: LexicalScanner, _ ns: NSString) {
        self.ns = ns
        var state = LexicalScanState()
        var out: [Seg] = []
        scanner.segments(ns, from: 0, to: ns.length, state: &state, languages: { range, kind, language in
            out.append(Seg(range: range, kind: kind, language: language))
        })
        segments = out
        end = state
        var units = [Pair](repeating: Pair(kind: .code, language: -1), count: ns.length)
        for s in out { for i in s.range.location..<NSMaxRange(s.range) { units[i] = Pair(kind: s.kind, language: s.language) } }
        pairs = units
    }

    func range(of piece: String, occurrence: Int = 1) -> NSRange {
        var from = 0
        var hit = NSRange(location: NSNotFound, length: 0)
        for _ in 0..<occurrence {
            hit = ns.range(of: piece, options: .literal, range: NSRange(location: from, length: ns.length - from))
            guard hit.location != NSNotFound else { return hit }
            from = hit.location + 1
        }
        return hit
    }

    /// The (kind, language) pairs covering `piece`.
    func at(_ piece: String, occurrence: Int = 1) -> Set<Pair> {
        let r = range(of: piece, occurrence: occurrence)
        guard r.location != NSNotFound else { return [] }
        return Set(pairs[r.location..<NSMaxRange(r)])
    }

    func languages(of piece: String, occurrence: Int = 1) -> Set<Int> {
        Set(at(piece, occurrence: occurrence).map(\.language))
    }
}

/// Token kind per unit of the whole text (`LanguageDefinition.tokens`).
private struct Tokens {
    let ns: NSString
    let kinds: [TokenKind?]

    init(_ language: String, _ text: String) throws {
        let def = try definition(language)
        ns = text as NSString
        var state = LexicalScanState()
        let tokens = def.tokens(in: ns, range: NSRange(location: 0, length: ns.length), state: &state)
        var units = [TokenKind?](repeating: nil, count: ns.length)
        for t in tokens { for i in t.range.location..<NSMaxRange(t.range) { units[i] = t.kind } }
        kinds = units
    }

    func of(_ piece: String, occurrence: Int = 1) -> Set<TokenKind?> {
        var from = 0
        var hit = NSRange(location: NSNotFound, length: 0)
        for _ in 0..<occurrence {
            hit = ns.range(of: piece, options: .literal, range: NSRange(location: from, length: ns.length - from))
            guard hit.location != NSNotFound else { return [] }
            from = hit.location + 1
        }
        return Set(kinds[hit.location..<NSMaxRange(hit)])
    }
}

private func state(_ language: String, _ text: String) throws -> LexicalScanState {
    var s = LexicalScanState()
    try #require(try definition(language).lexicalScanner).advance(text as NSString, from: 0, to: (text as NSString).length,
                                                                 state: &s)
    return s
}

// MARK: - HTML

@Suite("EmbeddedHTML")
struct EmbeddedHTMLTests {
    @Test func classicScriptIsJavaScript() throws {
        let text = "<p>a</p>\n<script>\nconst s = 'x'; // note\nlet r = /a<b/g; x=1\n</script>\n<p>b=c</p>\n"
        let scan = try Scan("html", text)
        #expect(scan.at("<script>") == [Pair(kind: .code, language: 0)])
        #expect(scan.at("const s = ") == [Pair(kind: .code, language: js)])
        #expect(scan.at("'x'") == [Pair(kind: .string, language: js)])
        #expect(scan.at("// note") == [Pair(kind: .comment, language: js)])
        #expect(scan.at("/a<b/g") == [Pair(kind: .atom(.regex), language: js)])
        #expect(scan.at("</script>") == [Pair(kind: .code, language: 0)])
        #expect(scan.at("<p>b=c</p>") == [Pair(kind: .code, language: 0)])
        #expect(scan.end.isEmpty)

        // The child's rules colour the body; the host's never run there.
        let tokens = try Tokens("html", text)
        #expect(tokens.of("const") == [.keyword])
        #expect(tokens.of("'x'") == [.string])
        #expect(tokens.of("x=1").contains(.attributeName) == false)
        #expect(tokens.of("script", occurrence: 1) == [.tagName])
        #expect(tokens.of("script", occurrence: 2) == [.tagName])
        #expect(tokens.of("b=c").contains(.attributeName))            // host rules after the body
    }

    static let javaScriptTypes = [
        "type=\"module\"", "type='text/javascript'", "TYPE=Module", "type=\"\"", "type = \" application/javascript \"",
        "type=text/babel", "id=\"x\" type=\"text/ecmascript\" defer", "src=\"a.js\"",
    ]

    @Test(arguments: javaScriptTypes)
    func javaScriptTypesAreJavaScript(_ attributes: String) throws {
        let scan = try Scan("html", "<script \(attributes)>let a = `t`;</script>")
        #expect(scan.languages(of: "let a = `t`;") == [js])
        #expect(scan.at("`t`") == [Pair(kind: .string, language: js)])
        #expect(scan.end.isEmpty)
    }

    static let otherTypes = [
        "text/template", "application/json", "importmap", "application/ld+json", "text/x-handlebars-template",
        "speculationrules",
    ]

    @Test(arguments: otherTypes)
    func otherTypesArePlainText(_ type: String) throws {
        let body = "<b>{{ x }}</b> \"q\" // not a comment"
        let scan = try Scan("html", "<script type=\"\(type)\">\(body)</script><i>after</i>")
        #expect(scan.at(body) == [Pair(kind: .block(.plain), language: 0)])
        #expect(scan.at("</script>") == [Pair(kind: .code, language: 0)])
        #expect(scan.at("<i>after</i>") == [Pair(kind: .code, language: 0)])
        let tokens = try Tokens("html", "<script type=\"\(type)\">\(body)</script>")
        #expect(tokens.of(body) == [.plain])
    }

    @Test func styleIsCSS() throws {
        for open in ["<style>", "<style type=\"text/css\" media=\"screen\">", "<STYLE>", "<style type=\"text/less\">"] {
            let scan = try Scan("html", "\(open)a { color: \"red\"; } /* c */</style>x")
            #expect(scan.languages(of: "a { color: ") == [css], "\(open)")
            #expect(scan.at("\"red\"") == [Pair(kind: .string, language: css)], "\(open)")
            #expect(scan.at("/* c */") == [Pair(kind: .comment, language: css)], "\(open)")
            #expect(scan.languages(of: "</style>x") == [0], "\(open)")
        }
        let tokens = try Tokens("html", "<style>@media (x) { a { color: #fff; } }</style>")
        #expect(tokens.of("@media") == [.controlKeyword])
        #expect(tokens.of("#fff") == [.string])
    }

    @Test func startTagSpanningLinesWithQuotedGreaterThan() throws {
        let text = "<script\n  data-x=\"a > b\" data-y='c>d'\n  type=\"module\"\n>const a = 1;</script>"
        let scan = try Scan("html", text)
        #expect(scan.languages(of: "data-x=\"a > b\" data-y='c>d'") == [0])
        #expect(scan.languages(of: "type=\"module\"\n>") == [0])
        #expect(scan.at("const a = 1;") == [Pair(kind: .code, language: js)])
        #expect(scan.end.isEmpty)
        // The tag's attributes keep the HTML rules.
        let tokens = try Tokens("html", text)
        #expect(tokens.of("data-x") == [.attributeName])
        #expect(tokens.of("const") == [.keyword])

        // Inside the tag the state remembers where it is: after `=`, in a value.
        #expect(try state("html", "<script\n data-x=\"a >").frames == [.rawTextTag(element: 0, phase: 2, start: 0)])
        #expect(try state("html", "<script data-x='a >").frames == [.rawTextTag(element: 0, phase: 3, start: 0)])
        #expect(try state("html", "<script data-x =").frames == [.rawTextTag(element: 0, phase: 1, start: 0)])
        #expect(try state("html", "<script data-x=abc").frames == [.rawTextTag(element: 0, phase: 4, start: 0)])

        // An unquoted value ends at `>`, which ends the tag.
        let unquoted = try Scan("html", "<script type=module>b>x</script>")
        #expect(unquoted.at("b>x") == [Pair(kind: .code, language: js)])
        // A `type` on a continuation line, uppercase, unquoted.
        let late = try Scan("html", "<script\r\n\tid=a\r\n\tTYPE=TEXT/TEMPLATE\r\n>let x</script>")
        #expect(late.at("let x") == [Pair(kind: .block(.plain), language: 0)])
    }

    @Test func endTagInsideJavaScriptConstructsStillEndsTheElement() throws {
        // In a string, a comment, a template literal: browser semantics.
        for body in ["var s = \"</script>\"; t = 1", "/* </script> */ t = 1", "`a ${ </script> }` t = 1",
                     "// </script> t = 1"] {
            let first = (body as NSString).range(of: "</script>").location
            let prefix = (body as NSString).substring(to: first)
            let rest = (body as NSString).substring(from: first + 9)
            let scan = try Scan("html", "<script>\(body)</script><p>")
            #expect(scan.languages(of: prefix) == [js], "\(body)")
            #expect(scan.at("</script>") == [Pair(kind: .code, language: 0)], "\(body)")
            #expect(scan.languages(of: rest) == [0], "\(body)")
            #expect(scan.end.isEmpty, "\(body)")
        }
    }

    @Test func endTagCaseAndDelimiters() throws {
        for close in ["</SCRIPT >", "</Script/>", "</script\n>", "</script\t>", "</sCrIpT>"] {
            let scan = try Scan("html", "<script>a()\(close)b")
            #expect(scan.languages(of: "a()") == [js], "\(close)")
            #expect(scan.languages(of: close) == [0], "\(close)")
            #expect(scan.languages(of: "b") == [0], "\(close)")
            #expect(scan.end.isEmpty, "\(close)")
        }
        // Not an end tag: another name, no delimiter, a style end in a script.
        for lookalike in ["</scripts>", "</scrip>", "</style>", "</ script>"] {
            let scan = try Scan("html", "<script>a()\(lookalike)b")
            #expect(scan.languages(of: "\(lookalike)b") == [js], "\(lookalike)")
            #expect(scan.end.frames == [.rawText(element: 0, language: UInt8(js))], "\(lookalike)")
        }
    }

    @Test func commentsAndLookalikesDoNotOpen() throws {
        let scan = try Scan("html", "<!-- <script>x = \"y\"</script> -->\n<scripts>a</scripts><script-x>b</script-x>"
                                  + "<scriptx>c<stylesheet>d")
        #expect(scan.segments.allSatisfy { $0.language == 0 })
        #expect(scan.at("<!-- <script>x = \"y\"</script> -->") == [Pair(kind: .comment, language: 0)])
        #expect(scan.end.isEmpty)
    }

    @Test func unterminatedBodiesRunToTheEnd() throws {
        let script = try Scan("html", "<p>\n<script>\nlet a = \"x")
        #expect(script.end.frames == [.rawText(element: 0, language: UInt8(js))])
        #expect(script.end.embedded == .init(language: js, state: try state("javascript", "\nlet a = \"x")))
        #expect(script.end.embedded?.state.frames.count == 1)
        #expect(script.languages(of: "let a = \"x") == [js])

        let style = try Scan("html", "<style>a { color: red")
        #expect(style.end.frames == [.rawText(element: 1, language: UInt8(css))])
        #expect(style.end.embedded == nil)   // the child has nothing open

        let template = try Scan("html", "<script type=\"text/x\">a\nb")
        #expect(template.end.frames == [.rawText(element: 0, language: 0)])
        #expect(template.at("a\nb") == [Pair(kind: .block(.plain), language: 0)])

        let tag = try Scan("html", "<p></p><script type=\"mod")
        #expect(tag.end.frames == [.rawTextTag(element: 0, phase: 2, start: 7)])
    }

    @Test func emptyBodies() throws {
        let scan = try Scan("html", "<script></script><style></style><SCRIPT type=module></SCRIPT>x")
        #expect(scan.segments.allSatisfy { $0.language == 0 })
        #expect(scan.segments.map(\.kind) == [.code])
        #expect(scan.end.isEmpty)
    }

    @Test func pageFixture() throws {
        let scan = try Scan("html", try fixture("embedded/page.html"))
        #expect(scan.at("/* CSS sub-language: a block comment */") == [Pair(kind: .comment, language: css)])
        #expect(scan.at("\"</div> is text inside a CSS string\"") == [Pair(kind: .string, language: css)])
        #expect(scan.at("<!-- An HTML comment between blocks: <script>not a script</script> -->")
                == [Pair(kind: .comment, language: 0)])
        #expect(scan.at("// Classic inline script: JavaScript sub-language.") == [Pair(kind: .comment, language: js)])
        #expect(scan.at("/<\\/?p>/") == [Pair(kind: .atom(.regex), language: js)])
        // A `</script>` inside a JS comment ends the element (browser semantics).
        #expect(scan.languages(of: "\" inside a string would end the") == [0])
        #expect(scan.languages(of: "import { render }") == [js])
        #expect(scan.at("    <li class=\"row\">") == [Pair(kind: .block(.plain), language: 0)])
        #expect(scan.at("{ \"theme\": \"dark\"") == [Pair(kind: .block(.plain), language: 0)])
        #expect(scan.languages(of: "<p>Text after the scripts") == [0])
        #expect(scan.end.isEmpty)
    }
}

// MARK: - Markdown

@Suite("EmbeddedMarkdown")
struct EmbeddedMarkdownTests {
    @Test func fencesFixture() throws {
        let text = try fixture("embedded/fences.md")
        let scan = try Scan("markdown", text)
        let plain = Pair(kind: .block(.plain), language: 0)
        // Opener and closer lines stay the host's plain block.
        #expect(scan.at("```python\n") == [plain])
        #expect(scan.at("~~~ts\n") == [plain])
        #expect(scan.at("```\n\nJavaScript") .contains(plain))
        // Bodies: the child's segments.
        #expect(scan.languages(of: "def total(prices") == [md("python")])
        #expect(scan.at("\"\"\"Docstring inside a fence.\"\"\"") == [Pair(kind: .string, language: md("python"))])
        #expect(scan.at("# comment") == [Pair(kind: .comment, language: md("python"))])
        #expect(scan.languages(of: "const label") == [md("javascript")])
        #expect(scan.at("/* block comment */") == [Pair(kind: .comment, language: md("javascript"))])
        #expect(scan.languages(of: "interface Point") == [md("typescript")])
        #expect(scan.languages(of: "cat <<EOF") == [md("bash")])
        #expect(scan.at("heredoc inside a fence: $HOME") == [Pair(kind: .block(.string), language: md("bash"))])
        #expect(scan.at("\"fence\"") == [Pair(kind: .string, language: md("json"))])
        // A four-backtick `markdown` fence: its three-backtick lines are the
        // child's own plain fence (one level only), the host closes at ````.
        #expect(scan.at("Here is how to write a fence:") == [Pair(kind: .code, language: md("markdown"))])
        #expect(scan.at("print(\"this is still inside") == [Pair(kind: .block(.plain), language: md("markdown"))])
        #expect(scan.at("````\n\nAn unknown") .contains(plain))
        // Unknown language and an info-less tilde fence: plain, as before.
        #expect(scan.at("++++++++[>++++[") == [plain])
        #expect(scan.at("still inside the tilde fence") == [plain])
        #expect(scan.at("Text between fences with ") == [Pair(kind: .code, language: 0)])
        // Unterminated: the body runs to the end.
        #expect(scan.languages(of: "def never_closed():") == [md("python")])
        #expect(scan.end.frames == [.fence(marker: 96, length: 3, inBody: true, language: UInt8(md("python")))])

        let tokens = try Tokens("markdown", text)
        #expect(tokens.of("def") == [.keyword])
        #expect(tokens.of("return", occurrence: 1) == [.controlKeyword])
        #expect(tokens.of("\"fence\"") == [.property])                    // JSON key
        #expect(tokens.of("true") == [.keyword])
        #expect(tokens.of("`avg ") == [.string])
        #expect(tokens.of("${") == [.interpolationDelimiter])
        #expect(tokens.of("++++++++[>++++[") == [.plain])
        #expect(tokens.of("```python\n") == [.plain])
    }

    static let aliases: [(word: String, identifier: String)] = [
        ("python", "python"), ("py", "python"), ("python3", "python"), ("js", "javascript"),
        ("javascript", "javascript"), ("jsx", "javascript"), ("mjs", "javascript"), ("cjs", "javascript"),
        ("ts", "typescript"), ("typescript", "typescript"), ("tsx", "typescriptreact"), ("bash", "bash"), ("sh", "bash"),
        ("shell", "bash"), ("zsh", "bash"), ("json", "json"), ("jsonc", "json"), ("jsonl", "jsonl"),
        ("yaml", "yaml"), ("yml", "yaml"), ("toml", "toml"), ("html", "html"), ("htm", "html"), ("xml", "xml"),
        ("plist", "xml"), ("svg", "xml"), ("css", "css"), ("c", "c"), ("h", "c"), ("cpp", "cpp"), ("c++", "cpp"),
        ("cc", "cpp"), ("cxx", "cpp"), ("hpp", "cpp"), ("csharp", "csharp"), ("cs", "csharp"), ("c#", "csharp"),
        ("java", "java"), ("go", "go"), ("golang", "go"), ("rust", "rust"), ("rs", "rust"), ("swift", "swift"),
        ("sql", "sql"), ("markdown", "markdown"), ("md", "markdown"),
        // Case, attributes after the word, a tilde fence, indentation.
        ("Python {.class}", "python"), ("JS title=\"a\"", "javascript"), ("ts,linenums", "typescript"),
        ("yaml:config", "yaml"),
    ]

    @Test(arguments: aliases)
    func infoStringAliases(_ alias: (word: String, identifier: String)) throws {
        for opener in ["```", "~~~", "   ````", "``` "] {
            let closer = opener.trimmingCharacters(in: .whitespaces)
            let scan = try Scan("markdown", "\(opener)\(alias.word)\nbody\n\(closer)\nafter\n")
            #expect(scan.languages(of: "body") == [md(alias.identifier)], "\(opener)\(alias.word)")
            #expect(scan.languages(of: "after") == [0])
            #expect(scan.end.isEmpty)
        }
        // Every child definition exists.
        let def = try definition("markdown")
        #expect(def.embeddedDefinition(md(alias.identifier))?.identifier == alias.identifier)
    }

    @Test func unknownLanguagesAndPlainFencesStayOneBlock() throws {
        for info in ["", "brainfuck", "text", " js`x", " {python}"] {
            let scan = try Scan("markdown", "```\(info)\nbody\n```\n")
            if info == " js`x" {
                #expect(scan.at("body") == [Pair(kind: .code, language: 0)])   // no fence at all
            } else {
                #expect(scan.at("body") == [Pair(kind: .block(.plain), language: 0)], "\(info)")
                #expect(scan.segments.count == 1, "\(info): \(scan.segments)")
            }
        }
    }

    @Test func theHostClosesWhateverTheChildState() throws {
        // A closer inside a child triple-quoted string, block comment and
        // heredoc; a longer closer; a shorter run and backticks inside.
        let cases: [(text: String, after: String)] = [
            ("```python\ns = '''\n```\nafter\n", "after"),
            ("```js\n/* open\n````\nafter\n", "after"),
            ("```bash\ncat <<EOF\n```\nafter\n", "after"),
            ("````js\nlet a = `\n```\n`\n````\nafter\n", "after"),
            ("~~~python\nx = 1\n```\n~~~~\nafter\n", "after"),
        ]
        for c in cases {
            let scan = try Scan("markdown", c.text)
            #expect(scan.at(c.after) == [Pair(kind: .code, language: 0)], "\(c.text.debugDescription)")
            #expect(scan.end.isEmpty, "\(c.text.debugDescription)")
        }
        // The tilde fence's ``` line belongs to the child.
        let tilde = try Scan("markdown", "~~~python\nx = 1\n```\n~~~~\n")
        #expect(tilde.languages(of: "```") == [md("python")])
    }

    @Test func childRulesNotHostRules() throws {
        let tokens = try Tokens("markdown", "```python\n# not a heading **x**\n- y\n```\n# heading\n")
        #expect(tokens.of("# not a heading **x**") == [.comment])
        #expect(tokens.of("- y").contains(.property) == false)          // no list marker in a body
        #expect(tokens.of("# heading") == [.heading])
    }
}

// MARK: - Text variants

@Suite("EmbeddedText")
struct EmbeddedTextTests {
    /// The LF document's units mapped into its CRLF variant.
    private func crlfIndex(_ lf: NSString) -> [Int] {
        var out: [Int] = []
        var shift = 0
        for i in 0..<lf.length {
            out.append(i + shift)
            if lf.character(at: i) == 10 { shift += 1 }
        }
        return out
    }

    static let samples: [(file: String, language: String)] = [
        ("embedded/page.html", "html"), ("embedded/fences.md", "markdown"),
    ]

    @Test(arguments: samples)
    func crlfVariantsMatchLF(_ sample: (file: String, language: String)) throws {
        let lf = try fixture(sample.file)
        let crlf = lf.replacingOccurrences(of: "\n", with: "\r\n")
        let a = try Scan(sample.language, lf), b = try Scan(sample.language, crlf)
        let ta = try Tokens(sample.language, lf), tb = try Tokens(sample.language, crlf)
        let map = crlfIndex(a.ns)
        func unitPairs(_ scan: Scan) -> [Pair] {
            var units = [Pair](repeating: Pair(kind: .code, language: -1), count: scan.ns.length)
            for s in scan.segments { for i in s.range.location..<NSMaxRange(s.range) { units[i] = Pair(kind: s.kind, language: s.language) } }
            return units
        }
        let pa = unitPairs(a), pb = unitPairs(b)
        var differences = 0
        for i in 0..<a.ns.length where a.ns.character(at: i) != 10 {
            if pa[i] != pb[map[i]] || ta.kinds[i] != tb.kinds[map[i]] { differences += 1 }
        }
        #expect(differences == 0)
        #expect(a.end == b.end)
        #expect(a.segments.contains { $0.language != 0 })
    }

    @Test func nonBMPCharactersInBodies() throws {
        let html = try Scan("html", "<script>const s = \"😀𝒳\"; // 🎉 note\nlet 𝒳 = '🎉';</script><style>a::before{content:\"😀\"}</style>")
        let md = try Scan("markdown", "```js\nlet t = '😀'; // 𝒳\n```\n```python\ns = \"🎉\"  # 😀\n")
        for scan in [html, md] {
            for s in scan.segments {
                let b = s.range.location
                if b > 0, b < scan.ns.length {
                    let high = (0xD800...0xDBFF).contains(scan.ns.character(at: b - 1))
                    #expect(!high, "boundary inside a surrogate pair at \(b)")
                }
            }
        }
        #expect(html.at("\"😀𝒳\"") == [Pair(kind: .string, language: js)])
        #expect(html.at("// 🎉 note") == [Pair(kind: .comment, language: js)])
        #expect(html.at("'🎉'") == [Pair(kind: .string, language: js)])
        #expect(html.at("\"😀\"") == [Pair(kind: .string, language: css)])
        #expect(md.at("'😀'") == [Pair(kind: .string, language: 1 + MarkdownLanguage.fenceLanguages.firstIndex { $0.identifier == "javascript" }!)])
        #expect(md.at("# 😀") == [Pair(kind: .comment, language: 1)])
        #expect(md.end.frames == [.fence(marker: 96, length: 3, inBody: true, language: 1)])
    }
}

// MARK: - Split guarantee, safe points, checkpoints

/// Synthetic documents covering start tags over lines, types, end tags in
/// strings, unterminated bodies, nested-looking fences and closers inside
/// child constructs.
private let syntheticHTML = """
    <!doctype html>
    <html><head>
    <style media="screen">
      .a::before { content: "</div>"; } /* c */ @media (x) { .b { margin: 1px } }
    </style>
    <script
       data-a="x > y" data-b='>'
       type = "module" async>
      import { a } from './a.js';
      const s = "</p>", t = `x${a + `y${1}`}z`;
      const re = /<\\/?p>/g; // c
    </script>
    <script type="text/x-template"><b>{{ x }}</b></script>
    <!-- <script>not</script> -->
    <SCRIPT TYPE=text/javascript>let u = "</SCRIPT >"; v</SCRIPT >
    <script src="x.js"></script><p title='a=b'>t &amp; 😀</p>
    <script>/* unterminated `

    """

private let syntheticMarkdown = """
    # Title
    ```python title="x"
    s = '''
    ```
    '''
    f"{x!r:>10}" # c
    ~~~~js
    `a${b}
    ```
    c`
    ~~~~
    ``` C++
    auto r = R"d(x)d";
    ```
    ```json
    {"k": [1, "v😀"]}
    ```
    ```yaml
    a: |
      b
    c: 'd'
    ```
    ````md
    ```js
    x
    ```
    ````
    ```bash
    cat <<EOF
    $HOME
    EOF
    ```
    ```nope
    x
    ```
    ```swift
    let s = #"a"#

    """

@Suite("EmbeddedSplit")
struct EmbeddedSplitTests {
    static let documents: [(label: String, language: String)] = [
        ("page.html", "html"), ("fences.md", "markdown"), ("synthetic.html", "html"),
        ("synthetic.md", "markdown"), ("page.html crlf", "html"), ("fences.md crlf", "markdown"),
        ("synthetic.html crlf", "html"), ("synthetic.md crlf", "markdown"),
    ]

    private func text(_ label: String) throws -> String {
        let base: String
        switch label.split(separator: " ").first! {
        case "page.html": base = try fixture("embedded/page.html")
        case "fences.md": base = try fixture("embedded/fences.md")
        case "synthetic.html": base = syntheticHTML
        default: base = syntheticMarkdown
        }
        // Twice, so the second copy starts in the state the first left.
        let doubled = base + "\n" + base
        return label.hasSuffix("crlf") ? doubled.replacingOccurrences(of: "\n", with: "\r\n") : doubled
    }

    private func segments(_ scanner: LexicalScanner, _ ns: NSString, from: Int, to: Int,
                          state: inout LexicalScanState, into out: inout [Seg]) {
        scanner.segments(ns, from: from, to: to, state: &state, languages: { range, kind, language in
            out.append(Seg(range: range, kind: kind, language: language))
        })
    }

    @Test(arguments: documents)
    func piecesAtLineStartsAndSafePointsEqualOnePass(_ doc: (label: String, language: String)) throws {
        let scanner = try #require(try definition(doc.language).lexicalScanner)
        let ns = try text(doc.label) as NSString
        let one = Scan(scanner, ns)
        let reference = merged(one.segments)
        #expect(reference.contains { $0.language != 0 })

        // Every line start at once.
        var lineState = LexicalScanState()
        var lines: [Seg] = []
        var loc = 0
        while loc < ns.length {
            let end = NSMaxRange(ns.lineRange(for: NSRange(location: loc, length: 0)))
            segments(scanner, ns, from: loc, to: end, state: &lineState, into: &lines)
            loc = end
        }
        #expect(lineState == one.end)
        #expect(merged(lines) == reference)

        // Chains of random safe points: each stop agrees with `advance`,
        // a plain pass to it gives the same state and segments, and the
        // pieces join to the single pass.
        var rng = SplitMix(state: 0x17_8A_5EED)
        for trial in 0..<120 {
            let k = Int.random(in: 1...6, using: &rng)
            let targets = (0..<k).map { _ in Int.random(in: 0...ns.length, using: &rng) }.sorted()
            var state = LexicalScanState()
            var pieces: [Seg] = []
            var from = 0
            var failed = false
            for target in targets where target >= from {
                var advanced = state
                var plain = state
                var stopped: [Seg] = []
                let q = scanner.segments(ns, from: from, to: ns.length, stoppingAtSafePointFrom: target, state: &state,
                                         languages: { stopped.append(Seg(range: $0, kind: $1, language: $2)) })
                let qa = scanner.advance(ns, from: from, to: ns.length, stoppingAtSafePointFrom: target, state: &advanced)
                var plainPieces: [Seg] = []
                segments(scanner, ns, from: from, to: q, state: &plain, into: &plainPieces)
                let ok = q >= target && q == qa && advanced == state && plain == state
                    && merged(plainPieces) == merged(stopped)
                #expect(ok, "\(doc.label) trial \(trial): target \(target) → \(q) (advance \(qa))")
                if !ok { failed = true; break }
                pieces += stopped
                from = q
            }
            if failed { break }
            segments(scanner, ns, from: from, to: ns.length, state: &state, into: &pieces)
            let same = merged(pieces) == reference && state == one.end
            #expect(same, "\(doc.label) trial \(trial): pieces differ for targets \(targets)")
            if !same { break }
        }
    }

    /// `text` repeated until it is longer than `minimum` units.
    private func repeated(_ text: String, longerThan minimum: Int) -> String {
        let unit = text.hasSuffix("\n") ? text : text + "\n"
        return String(repeating: unit, count: minimum / (unit as NSString).length + 1)
    }

    private func unitKinds(_ tokens: [(range: NSRange, kind: TokenKind)], in range: NSRange) -> [TokenKind?] {
        var out = [TokenKind?](repeating: nil, count: range.length)
        for t in tokens {
            let piece = NSIntersectionRange(t.range, range)
            guard piece.length > 0 else { continue }
            for i in piece.location..<NSMaxRange(piece) { out[i - range.location] = t.kind }
        }
        return out
    }

    static let longDocuments: [(file: String, language: String)] = [
        ("embedded/page.html", "html"), ("embedded/fences.md", "markdown"),
    ]

    /// Bands starting inside embedded bodies, from a cold checkpoint store and
    /// from one warmed by the earlier jumps, equal a fresh single pass.
    @Test(arguments: longDocuments)
    func checkpointResumeInsideBodiesEqualsAFreshPass(_ sample: (file: String, language: String)) throws {
        let def = try definition(sample.language)
        let spacing = CheckpointStore.spacing
        let ns = repeated(try fixture(sample.file), longerThan: 4 * spacing + spacing / 2) as NSString
        var fullState = LexicalScanState()
        let full = def.tokens(in: ns, range: NSRange(location: 0, length: ns.length), state: &fullState)
        let fullKinds = unitKinds(full, in: NSRange(location: 0, length: ns.length))
        let bodies = Scan(def.lexicalScanner!, ns).segments.filter { $0.language != 0 }
        #expect(bodies.count > 100)

        var warm = CheckpointStore()
        var rng = SplitMix(state: 0xC4EC_9017)
        for trial in 0..<40 {
            let body = bodies.randomElement(using: &rng)!
            let offset = body.range.location + Int.random(in: 0..<body.range.length, using: &rng)
            let start = ns.lineRange(for: NSRange(location: offset, length: 0)).location
            let endLine = ns.lineRange(for: NSRange(location: min(ns.length - 1, start + Int.random(in: 1...3_000, using: &rng)),
                                                    length: 0))
            let band = NSRange(location: start, length: NSMaxRange(endLine) - start)
            var cold = CheckpointStore()
            let a = HighlightEngine.bandTokens(in: ns, range: band, language: def, checkpoints: &cold)
            let b = HighlightEngine.bandTokens(in: ns, range: band, language: def, checkpoints: &warm)
            let expected = Array(fullKinds[band.location..<NSMaxRange(band)])
            let ok = unitKinds(a, in: band) == expected && unitKinds(b, in: band) == expected
            #expect(ok, "trial \(trial): band \(band)")
            if !ok { break }
        }
        #expect(warm.entries.count >= 3)
        // Checkpoints taken inside bodies hold the body frame.
        #expect(warm.entries.contains { entry in
            if case .generic(let s) = entry.state, let top = s.frames.last {
                switch top {
                case .rawText, .fence: return true
                default: return false
                }
            }
            return false
        } || sample.language == "markdown")
    }

    /// The identifier pass: a child's policy inside its spans (JS colours
    /// every identifier as a variable), the host's outside.
    @Test func identifierPassFollowsTheSpanLanguage() throws {
        let def = try definition("html")
        let ns = "<p>alpha beta</p><script>let gamma = delta;</script><p>epsilon</p>" as NSString
        var state = LexicalScanState()
        let result = def.embeddedTokens(in: ns, range: NSRange(location: 0, length: ns.length), stop: nil, state: &state)
        #expect(result.languages.map(\.language) == [js])
        var tokens = result.tokens
        let identifiers = HighlightEngine.identifierTokens(in: ns, range: NSRange(location: 0, length: ns.length),
                                                           tokens: &tokens, roles: [], table: nil, language: def,
                                                           embedded: result.languages)
        let names = Set(identifiers.map { ns.substring(with: $0.range) })
        #expect(names == ["gamma", "delta"])
        #expect(identifiers.allSatisfy { $0.kind == .symbolVariable })
        // A host symbol table never colours names in a child span.
        let table = WordIndex.SymbolTable(functions: ["gamma", "alpha"], types: [], variables: [])
        var again = result.tokens
        let withTable = HighlightEngine.identifierTokens(in: ns, range: NSRange(location: 0, length: ns.length),
                                                         tokens: &again, roles: [], table: table, language: def,
                                                         embedded: result.languages)
        #expect(withTable.contains { ns.substring(with: $0.range) == "alpha" && $0.kind == .symbolFunction })
        #expect(withTable.contains { ns.substring(with: $0.range) == "gamma" && $0.kind == .symbolVariable })
    }
}

// MARK: - Long line

/// One line of minified HTML with inline scripts (strings holding end-tag
/// look-alikes, templates, regexes, comments), styles and template scripts.
private func minifiedHTML(units: Int) -> String {
    var html = "<!doctype html><html><body>"
    var i = 0
    while html.utf16.count < units {
        html += "<div class=\"c\(i)\" data-x='a>b'>t&amp;\(i)</div>"
        html += "<script>var a\(i)=\"</p>\"+'x',b=`t${a\(i)+`u${\(i)}`}`;/* c */function f\(i)(x){return x<2?/a\\/b/g:x/2}</script>"
        html += "<style>.c\(i)::before{content:\"}\";color:#fff}/* s */@media (x){.d{margin:1px}}</style>"
        html += "<script type=\"text/template\"><b>{{x}}</b></script>"
        i += 1
    }
    return html + "</body></html>"
}

/// Token kind per unit of the whole text, with the identifier pass the
/// engine adds (no roles, no table).
private func fullPassKinds(_ def: LanguageDefinition, _ ns: NSString) -> [TokenKind?] {
    var state = LexicalScanState()
    let whole = NSRange(location: 0, length: ns.length)
    let result = def.embeddedTokens(in: ns, range: whole, stop: nil, state: &state)
    var tokens = result.tokens
    let identifiers = HighlightEngine.identifierTokens(in: ns, range: whole, tokens: &tokens, roles: [], table: nil,
                                                       language: def, embedded: result.languages)
    var out = [TokenKind?](repeating: nil, count: ns.length)
    for t in tokens + identifiers { for i in t.range.location..<NSMaxRange(t.range) { out[i] = t.kind } }
    return out
}

@Suite("EmbeddedLongLine")
struct EmbeddedLongLineTests {
    @Test func midLineSlicesOfMinifiedHTMLMatchAFullPass() throws {
        let def = try definition("html")
        let ns = minifiedHTML(units: 200 * 1024) as NSString
        #expect(ns.length >= 200 * 1024 && ns.range(of: "\n").location == NSNotFound)
        let full = fullPassKinds(def, ns)
        var rng = SplitMix(state: 0x10_96_11E)
        var store = CheckpointStore()
        let threshold = LanguageDefinition.longLineThreshold
        for trial in 0..<120 {
            let start = Int.random(in: (threshold + 1)...(ns.length - threshold - 5_001), using: &rng)
            let end = start + Int.random(in: 1...5_000, using: &rng)
            let bounds = HighlightEngine.BandBounds(start: start, startMidLine: true, end: end, endMidLine: true)
            if trial % 3 == 0 { store = CheckpointStore() }
            let band = HighlightEngine.bandTokens(in: ns, bounds: bounds, language: def, checkpoints: &store)
            // Bounded: the painted slice is the requested one up to a few tokens.
            #expect(band.painted.location >= start && band.painted.location - start <= 600, "trial \(trial)")
            #expect(NSMaxRange(band.painted) >= end && NSMaxRange(band.painted) - end <= 600, "trial \(trial)")
            #expect(band.tokens.allSatisfy { NSIntersectionRange($0.range, band.painted) == $0.range })
            #expect(band.embedded.allSatisfy { NSIntersectionRange($0.range, band.painted) == $0.range })
            var tokens = band.tokens
            let identifiers = HighlightEngine.identifierTokens(in: ns, range: band.painted, tokens: &tokens, roles: [],
                                                               table: nil, language: def, embedded: band.embedded)
            var mine = [TokenKind?](repeating: nil, count: band.painted.length)
            for t in tokens + identifiers {
                for i in t.range.location..<NSMaxRange(t.range) { mine[i - band.painted.location] = t.kind }
            }
            let expected = Array(full[band.painted.location..<NSMaxRange(band.painted)])
            let diff = zip(mine, expected).enumerated().first { $0.element.0 != $0.element.1 }?.offset
            #expect(diff == nil, "trial \(trial): bounds \(start)..<\(end), painted \(band.painted), differs at \(band.painted.location + (diff ?? 0))")
            if diff != nil { break }
            // A warm store resumes near the band: at most one spacing to scan.
            if trial % 3 != 0 {
                let nearest = store.nearest(atOrBefore: start)?.offset ?? 0
                #expect(start - nearest <= CheckpointStore.spacing + LanguageDefinition.ruleContext + 1_024,
                        "trial \(trial): resumed from \(nearest) for \(start)")
            }
        }
        // Checkpoints inside the line hold body states too.
        #expect(store.entries.allSatisfy { $0.offset > 0 })
    }

    /// A minified JSON line inside a `json` fence: slices cut inside the
    /// child's strings still find its keys (the child's key follower and the
    /// look-ahead past the cut), and match a full pass.
    @Test func midLineSlicesOfAJSONFenceMatchAFullPass() throws {
        let def = try definition("markdown")
        var json = "["
        var i = 0
        while json.utf16.count < 120_000 {
            if i > 0 { json += "," }
            json += #"{"id":\#(i),"name":"item \"\#(i)\" 😀","tags":["a","b"],"ok":true,"n":null}"#
            i += 1
        }
        let ns = ("# Data\n\n```json\n" + json + "]\n```\n\nafter\n") as NSString
        let full = fullPassKinds(def, ns)
        #expect(full.contains(.property) && full.contains(.string))
        var rng = SplitMix(state: 0x150_F3)
        var store = CheckpointStore()
        let threshold = LanguageDefinition.longLineThreshold
        for trial in 0..<80 {
            let start = Int.random(in: (threshold + 20)...(ns.length - threshold - 5_001), using: &rng)
            let end = start + Int.random(in: 1...5_000, using: &rng)
            let bounds = HighlightEngine.BandBounds(start: start, startMidLine: true, end: end, endMidLine: true)
            if trial % 4 == 0 { store = CheckpointStore() }
            let band = HighlightEngine.bandTokens(in: ns, bounds: bounds, language: def, checkpoints: &store)
            #expect(band.embedded.allSatisfy { $0.language == md("json") })
            var tokens = band.tokens
            let identifiers = HighlightEngine.identifierTokens(in: ns, range: band.painted, tokens: &tokens, roles: [],
                                                               table: nil, language: def, embedded: band.embedded)
            var mine = [TokenKind?](repeating: nil, count: band.painted.length)
            for t in tokens + identifiers {
                for i in t.range.location..<NSMaxRange(t.range) { mine[i - band.painted.location] = t.kind }
            }
            let expected = Array(full[band.painted.location..<NSMaxRange(band.painted)])
            let diff = zip(mine, expected).enumerated().first { $0.element.0 != $0.element.1 }?.offset
            #expect(diff == nil, "trial \(trial): painted \(band.painted), differs at \(band.painted.location + (diff ?? 0))")
            if diff != nil { break }
        }
    }
}

/// An engine and its analysis on a windowed, wrapping text view (as the
/// long-line engine suite sets it up).
@MainActor
private final class Painter {
    let center = NotificationCenter()
    let window: NSWindow
    let scrollView: NSScrollView
    let textView: EditorTextView
    let hub = TextStorageObserverHub()
    let analysis: DocumentAnalysis
    let engine: HighlightEngine

    init(text: String, language: String) {
        let frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        scrollView = NSScrollView(frame: frame)
        textView = EditorTextView(frame: frame)
        textView.isRichText = false
        textView.isVerticallyResizable = true
        textView.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.layoutManager?.backgroundLayoutEnabled = false
        scrollView.documentView = textView
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        textView.string = text
        let name = "EmbeddedLanguageTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let settings = ModuleSettings(defaults: defaults, center: center)
        analysis = DocumentAnalysis(textView: textView, moduleSettings: settings, moduleCenter: center,
                                    scheduler: AnalysisScheduler())
        engine = HighlightEngine(textView: textView, scrollView: scrollView, moduleSettings: settings,
                                 moduleCenter: center, analysis: analysis)
        hub.add(analysis)
        hub.add(engine)
        textView.textStorage?.delegate = hub
        engine.setLanguage(identifier: language)
    }

    var ns: NSString { textView.textStorage!.mutableString }

    func paint(at offset: Int) async {
        textView.scrollRangeToVisible(NSRange(location: offset, length: 0))
        await Task.yield()
        engine.appearanceDidChange()
        await Task.yield()
    }

    func colours(in range: NSRange) -> [ObjectIdentifier?] {
        let lm = textView.layoutManager!
        var out: [ObjectIdentifier?] = []
        var index = range.location
        while index < NSMaxRange(range) {
            var effective = NSRange(location: 0, length: 0)
            let colour = lm.temporaryAttribute(.foregroundColor, atCharacterIndex: index,
                                               longestEffectiveRange: &effective, in: range)
            let id = (colour as? NSColor).map { ObjectIdentifier($0) }
            let end = max(index + 1, NSMaxRange(effective))
            out += Array(repeating: id, count: end - index)
            index = end
        }
        return out
    }

    func runs(in range: NSRange) -> Int {
        guard range.length > 0 else { return 0 }
        let lm = textView.layoutManager!
        var runs = 0, index = range.location
        while index < NSMaxRange(range) {
            var effective = NSRange(location: 0, length: 0)
            let value = lm.temporaryAttribute(.foregroundColor, atCharacterIndex: index,
                                              longestEffectiveRange: &effective, in: range)
            if value != nil { runs += 1 }
            index = max(index + 1, NSMaxRange(effective))
        }
        return runs
    }
}

@Suite("EmbeddedLongLineEngine", .serialized)
@MainActor
struct EmbeddedLongLineEngineTests {
    init() { _ = NSApplication.shared }

    @Test func minifiedHTMLIsPaintedInBoundedSlicesThatMatchAFullPass() async throws {
        let text = minifiedHTML(units: 256 * 1024)
        let painter = Painter(text: text, language: "html")
        let ns = painter.ns
        let full = await Task.detached { fullPassKinds(HTMLLanguage.make(), text as NSString) }.value
        let theme = HighlightTheme()
        func expected(_ range: NSRange) -> [ObjectIdentifier?] {
            full[range.location..<NSMaxRange(range)].map { kind in kind.flatMap { theme.color(for: $0) }.map { ObjectIdentifier($0) } }
        }
        for (label, offset) in [("top", 0), ("quarter", ns.length / 4), ("middle", ns.length / 2), ("end", ns.length - 1)] {
            if offset > 0 { await painter.paint(at: offset) }
            let band = try #require(painter.engine.paintedRange, "\(label)")
            #expect(offset == 0 || NSLocationInRange(offset, band), "\(label): \(offset) not in \(band)")
            #expect(band.length <= 65_536, "\(label): band \(band)")
            #expect((painter.engine.colouredRange?.length ?? 0) <= 65_536, "\(label)")
            #expect(painter.runs(in: NSRange(location: 0, length: band.location))
                    + painter.runs(in: NSRange(location: NSMaxRange(band), length: ns.length - NSMaxRange(band))) == 0,
                    "\(label): colour outside the band")
            let mine = painter.colours(in: band)
            let diff = zip(mine, expected(band)).enumerated().first { $0.element.0 != $0.element.1 }?.offset
            #expect(diff == nil, "\(label): differs at \(band.location + (diff ?? 0)) in \(band)")
            // The band shows script and style colours.
            let kinds = Set(full[band.location..<NSMaxRange(band)].compactMap { $0 })
            #expect(kinds.isSuperset(of: [.keyword, .regex, .comment, .tagName, .symbolVariable]), "\(label): \(kinds)")
        }
        // Checkpoints inside the line (its only line start is 0).
        let checkpoints = painter.engine.analysis.checkpoints.entries
        #expect(checkpoints.count >= 2 && checkpoints.allSatisfy { $0.offset > 0 })
    }
}
