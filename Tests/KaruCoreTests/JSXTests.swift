import AppKit
import Foundation
import Testing
@testable import KaruCore

// M17 T17.8b — JSX / TSX in the generic scanner (plan §7): elements opened in
// expression positions of JavaScript and TypeScript JSX (never in `.ts`),
// tags, attributes, children text and `{…}` expressions; the split guarantee
// and safe points through JSX frames; checkpoint resume; a long minified JSX
// line painted in slices; the declaration walker over JSX; registration of
// `.jsx` / `.tsx` and the `typescriptreact` identifier.

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

private func definition(_ language: String) throws -> LanguageDefinition {
    try #require(LanguageRegistry.definition(forIdentifier: language))
}

private func scanner(_ language: String) throws -> LexicalScanner {
    try #require(try definition(language).lexicalScanner)
}

/// A segment with its language (0: the host).
private struct Seg: Equatable, CustomStringConvertible {
    let range: NSRange
    let kind: LexicalSegment
    let language: Int
    var description: String { "\(range.location)+\(range.length) \(kind) @\(language)" }
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

private func scanSegments(_ scanner: LexicalScanner, _ ns: NSString, from: Int, to: Int,
                      state: inout LexicalScanState, into out: inout [Seg]) {
    scanner.segments(ns, from: from, to: to, state: &state, languages: { range, kind, language in
        out.append(Seg(range: range, kind: kind, language: language))
    })
}

/// One pass of a language's scanner over a text.
private struct Scan {
    let ns: NSString
    let segments: [Seg]
    let end: LexicalScanState
    private let kinds: [LexicalSegment?]

    init(_ language: String, _ text: String) throws {
        try self.init(scanner(language), text as NSString)
    }

    init(_ scanner: LexicalScanner, _ ns: NSString) {
        self.ns = ns
        var state = LexicalScanState()
        var out: [Seg] = []
        scanSegments(scanner, ns, from: 0, to: ns.length, state: &state, into: &out)
        segments = out
        end = state
        var units = [LexicalSegment?](repeating: nil, count: ns.length)
        for s in out { for i in s.range.location..<NSMaxRange(s.range) { units[i] = s.kind } }
        kinds = units
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

    /// The segment kinds covering `piece`.
    func at(_ piece: String, occurrence: Int = 1) -> Set<LexicalSegment> {
        let r = range(of: piece, occurrence: occurrence)
        guard r.location != NSNotFound else { return [] }
        return Set(kinds[r.location..<NSMaxRange(r)].compactMap { $0 })
    }

    var hasJSX: Bool { segments.contains { $0.kind == .atom(.tagPunctuation) } }
}

/// Token kind per unit (`LanguageDefinition.tokens` plus the identifier
/// pass without roles or table).
private struct Tokens {
    let ns: NSString
    let kinds: [TokenKind?]

    init(_ language: String, _ text: String) throws {
        let def = try definition(language)
        ns = text as NSString
        var state = LexicalScanState()
        let whole = NSRange(location: 0, length: ns.length)
        let result = def.embeddedTokens(in: ns, range: whole, stop: nil, state: &state)
        var tokens = result.tokens
        let identifiers = HighlightEngine.identifierTokens(in: ns, range: whole, tokens: &tokens, roles: [], table: nil,
                                                           language: def, embedded: result.languages)
        var units = [TokenKind?](repeating: nil, count: ns.length)
        for t in tokens + identifiers { for i in t.range.location..<NSMaxRange(t.range) { units[i] = t.kind } }
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

private func endState(_ language: String, _ text: String) throws -> LexicalScanState {
    var s = LexicalScanState()
    try scanner(language).advance(text as NSString, from: 0, to: (text as NSString).length, state: &s)
    return s
}

private let tagPunct = LexicalSegment.atom(.tagPunctuation)
private let tagName = LexicalSegment.atom(.tagName)
private let component = LexicalSegment.atom(.type)
private let attribute = LexicalSegment.atom(.attributeName)
private let plain = LexicalSegment.atom(.plain)
private let brace = LexicalSegment.interpolationDelimiter

/// Synthetic JSX covering the scanner's cases (used by the split suites too).
private let syntheticJSX = """
    const a = <Foo.Bar x="1 > 2 {no}" y='it"s' {...rest} z={`t${u}v`} />;
    const b = <>
      text 'a' "b" // c /* d */ if (x) < 3 and > 4 } here
      {/* only a comment */}
      <svg:rect width={w < 2 ? <i>small</i> : null} data-x />
      {list.map((n) => <li key={n}>{n}</li>)}
    </>;
    const c = <div
      // a line comment in a tag
      /* a block comment */ id="z"
    >😀 x</div>;
    if (a < b && c > d) { x = y < z > w; f(a<b>c); }
    const r = /<a>/g;
    function g() { return <p>{/x</.test(s) ? "</p>" : '{'}</p>; }

    """

/// TSX additions: type arguments in tags, generic arrows, casts as code.
private let syntheticTSX = syntheticJSX + """
    const id = <T,>(x: T) => x;
    const ex = <T extends object>(x: T): T => x;
    const df = <T = string>(x: T) => x;
    const cs = <const T,>(x: T) => x;
    const el = <Badge<string> label="x">kid</Badge>;
    const nested = <Map<Array<string>, () => void> />;
    let m: Array<string> = f<T>(x);

    """

/// `levels` nested elements in one tree (no expressions), then a sibling.
private func deepJSX(levels: Int) -> String {
    var s = "const deep = (\n"
    for i in 0..<levels { s += String(repeating: " ", count: i % 8) + "<div className=\"l\(i)\">\n" }
    s += "text { x } here\n"
    for i in (0..<levels).reversed() { s += String(repeating: " ", count: i % 8) + "</div>\n" }
    return s + ");\nconst after = 1;\n"
}

// MARK: - Scanner

@Suite("JSXScanner")
struct JSXScannerTests {
    @Test func componentJSXFixture() throws {
        let text = try fixture("embedded/component.jsx")
        let scan = try Scan("javascript", text)
        #expect(scan.end.isEmpty)
        #expect(scan.at("<div>not JSX</div> */") == [.comment])
        #expect(scan.at("<", occurrence: 3) == [tagPunct])          // <section
        #expect(scan.at("section") == [tagName])
        #expect(scan.at("className") == [attribute])
        #expect(scan.at("\"todo\"") == [.string])
        #expect(scan.at("data-ratio") == [attribute])
        #expect(scan.at("{ratio") == [brace, .code])
        #expect(scan.at("\"Todo items: a < b is text in an attribute string\"") == [.string])
        #expect(scan.at("{/* JSX comment inside braces */}") == [brace, .comment])
        #expect(scan.at("Plain JSX text with an apostrophe's and \"quotes\" is not a string.") == [plain])
        #expect(scan.at(" of ") == [plain])
        #expect(scan.at("%)") == [plain])
        #expect(scan.at("Footer", occurrence: 1) == [component])
        #expect(scan.at("/>", occurrence: 1) == [tagPunct])
        #expect(scan.at("</", occurrence: 1) == [.comment])
        #expect(scan.at("</", occurrence: 2) == [tagPunct])
        #expect(scan.at("n / 2") == [.code])                          // division in an expression
        #expect(scan.at("empty") == [plain])

        let tokens = try Tokens("javascript", text)
        #expect(tokens.of("section") == [.tagName])
        #expect(tokens.of("Footer", occurrence: 1) == [.type])
        #expect(tokens.of("className") == [.attributeName])
        #expect(tokens.of("{ratio") == [.interpolationDelimiter, .symbolVariable])
        #expect(tokens.of("toFixed") == [.symbolFunction])
        #expect(tokens.of("'Todos'") == [.string])
        #expect(tokens.of("Plain JSX text") == [.plain])
        #expect(tokens.of(" — ", occurrence: 1) == [.comment])
        #expect(tokens.of(" — ", occurrence: 2) == [.plain])
        #expect(tokens.of("undefined") == [.keyword])
    }

    @Test func componentTSXFixture() throws {
        let text = try fixture("embedded/component.tsx")
        let scan = try Scan("typescriptreact", text)
        #expect(scan.end.isEmpty)
        // The generic arrow stays code.
        #expect(scan.at("<T extends string,>({ label") == [.code])
        #expect(scan.at("span", occurrence: 1) == [tagName])
        #expect(scan.at("Badge<", occurrence: 1) == [component, plain])
        #expect(scan.at("string> ", occurrence: 2) == [component, plain])
        #expect(scan.at("text child with 'quotes' and a < b comparison written as text") == [plain])
        #expect(scan.at("{/* comment in TSX */}") == [brace, .comment])
        #expect(scan.at("count > 0 && ") == [.code])
        #expect(scan.at("sup") == [tagName])
        #expect(scan.at("aria-label") == [attribute])

        let tokens = try Tokens("typescriptreact", text)
        #expect(tokens.of("extends", occurrence: 2) == [.keyword])
        #expect(tokens.of("<Badge<string>") == [.tagPunctuation, .type, .plain])
        #expect(tokens.of("</Badge>") == [.tagPunctuation, .type])
        #expect(tokens.of("as unknown") == [.controlKeyword, nil, .type])

        // As `.ts`, the same text has no JSX at all.
        #expect(try !Scan("typescript", text).hasJSX)
    }

    @Test func comparisonsAndGenericsAreCode() throws {
        for language in ["javascript", "typescriptreact", "typescript"] {
            for text in ["a < b", "a<b>c", "x = y < z > w", "if (i <n) {}", "for (;i<len;) {}", "f<T>(x)",
                         "let a: Array<string> = []", "new Map<string, number>()", "x = 1 <y", "a <= b", "a << b",
                         "return a < b", "<!-- old comment"] {
                let scan = try Scan(language, text)
                #expect(!scan.hasJSX, "\(language): \(text)")
                #expect(scan.end.isEmpty, "\(language): \(text)")
            }
        }
    }

    @Test func expressionPositionsOpenElements() throws {
        for language in ["javascript", "typescriptreact"] {
            for text in ["x = <a/>", "return <a/>", "f(<a/>)", "() => <a/>", "c ? <a/> : <b/>", "[<a/>, <b/>]",
                         "{ k: <a/> }", "x && <a/>", "x || <a/>", "x ?? <a/>", "yield <a/>", "`${<a/>}`",
                         "<a/>", "x = <>t</>"] {
                let scan = try Scan(language, text)
                #expect(scan.hasJSX, "\(language): \(text)")
                #expect(scan.end.isEmpty, "\(language): \(text) → \(scan.end.frames)")
            }
        }
    }

    @Test func typeScriptHasNoJSXAndTSXKeepsTypeParameterLists() throws {
        // `.ts`: a cast and a generic arrow.
        for text in ["const v = <T>x;", "const f = <T>(x: T) => x;", "x = <div>a</div>"] {
            #expect(try !Scan("typescript", text).hasJSX, "\(text)")
        }
        // TSX: type parameter lists stay code.
        for text in ["const f = <T,>(x: T) => x;", "const f = <T extends X>(x: T) => x;",
                     "const f = <T extends unknown,>() => 1;", "const f = <T = string>() => 1;",
                     "const f = <const T,>(x: T) => x;", "const f = <T\t,U>(x: T) => x;"] {
            let scan = try Scan("typescriptreact", text)
            #expect(!scan.hasJSX, "\(text)")
            #expect(scan.end.isEmpty, "\(text)")
        }
        // …but `<T>` alone, an attribute named like a keyword, or `extendsX` is an element.
        for text in ["x = <T>y</T>", "x = <div extendsX=\"1\"/>", "x = <constant/>", "x = <div className=\"c\"/>"] {
            let scan = try Scan("typescriptreact", text)
            #expect(scan.hasJSX, "\(text)")
            #expect(scan.end.isEmpty, "\(text)")
        }
        // The TSX walker sees the generic arrow's type parameter.
        let scan = DeclarationScan.scan(text: "const id = <T,>(x: T) => x;", languageIdentifier: "typescriptreact")
        #expect(scan.declarations.map(\.name) == ["id", "T", "x"])
    }

    @Test func syntheticConstructs() throws {
        let scan = try Scan("javascript", syntheticJSX)
        #expect(scan.end.isEmpty)
        #expect(scan.at("Foo.Bar") == [component])
        #expect(scan.at("\"1 > 2 {no}\"") == [.string])
        #expect(scan.at("'it\"s'") == [.string])
        #expect(scan.at("{...rest}") == [brace, .code])
        #expect(scan.at("`t") == [.string])
        #expect(scan.at("${") == [.interpolationDelimiter])
        #expect(scan.at(" />;") == [plain, tagPunct, .code])
        #expect(scan.at("<>") == [tagPunct])
        #expect(scan.at("</>") == [tagPunct])
        #expect(scan.at("text 'a' \"b\" // c /* d */ if (x) < 3 and > 4 } here") == [plain])
        #expect(scan.at("{/* only a comment */}") == [brace, .comment])
        #expect(scan.at("svg") == [tagName])
        #expect(scan.at(":rect") == [plain, tagName])
        #expect(scan.at("w < 2 ? ") == [.code])
        #expect(scan.at("small") == [plain])
        #expect(scan.at("data-x") == [attribute])
        #expect(scan.at("(n) => ") == [.code])
        #expect(scan.at("<li") == [tagPunct, tagName])
        #expect(scan.at("// a line comment in a tag") == [.comment])
        #expect(scan.at("/* a block comment */") == [.comment])
        #expect(scan.at("id") == [attribute])
        #expect(scan.at("😀 x") == [plain])
        #expect(scan.at("a < b && c > d") == [.code])
        #expect(scan.at("a<b>c") == [.code])
        #expect(scan.at("/<a>/g") == [.atom(.regex)])
        #expect(scan.at("/x</") == [.atom(.regex)])
        #expect(scan.at("\"</p>\"") == [.string])
        #expect(scan.at("'{'") == [.string])

        let tsx = try Scan("typescriptreact", syntheticTSX)
        #expect(tsx.end.isEmpty)
        #expect(tsx.at("<T,>(x: T) => x;") == [.code])
        #expect(tsx.at("<T extends object>(x: T): T => x;") == [.code])
        #expect(tsx.at("<T = string>(x: T) => x;") == [.code])
        #expect(tsx.at("<const T,>(x: T) => x;") == [.code])
        #expect(tsx.at("Badge<string>") == [component, plain])
        #expect(tsx.at("kid") == [plain])
        #expect(tsx.at("Map<Array<string>, () => void>") == [component, plain])
        #expect(tsx.at("Array<string> = f<T>(x);") == [.code])
        let tokens = try Tokens("typescriptreact", syntheticTSX)
        #expect(tokens.of("Array<string>, ") == [.type, .plain])
        #expect(tokens.of("void", occurrence: 1) == [.type])
    }

    @Test func statesInsideElements() throws {
        #expect(try endState("javascript", "x = <a").frames == [.jsxTag(depth: 0, phase: 1, closing: false, angles: 0)])
        #expect(try endState("javascript", "x = <").frames == [])
        #expect(try endState("javascript", "x = <a b=\"c").frames
                == [.jsxTag(depth: 0, phase: 2, closing: false, angles: 0)])
        #expect(try endState("javascript", "x = <a b='c").frames
                == [.jsxTag(depth: 0, phase: 3, closing: false, angles: 0)])
        #expect(try endState("javascript", "x = <a><b>t").frames == [.jsxText(depth: 2)])
        #expect(try endState("javascript", "x = <a><b>t</").frames
                == [.jsxTag(depth: 2, phase: 0, closing: true, angles: 0)])
        #expect(try endState("javascript", "x = <a><b>t</b>").frames == [.jsxText(depth: 1)])
        #expect(try endState("javascript", "x = <a>{y").frames == [.jsxText(depth: 1), .jsxExpression(braces: 0)])
        #expect(try endState("javascript", "x = <a>{ {k").frames == [.jsxText(depth: 1), .jsxExpression(braces: 1)])
        #expect(try endState("javascript", "x = <a b={<c>").frames
                == [.jsxTag(depth: 0, phase: 1, closing: false, angles: 0), .jsxExpression(braces: 0),
                    .jsxText(depth: 1)])
        #expect(try endState("typescriptreact", "x = <A<B<C").frames
                == [.jsxTag(depth: 0, phase: 4, closing: false, angles: 2)])
        // In JavaScript a `<` after the tag name is a stray unit.
        #expect(try endState("javascript", "x = <A<B").frames == [.jsxTag(depth: 0, phase: 1, closing: false, angles: 0)])
    }

    @Test func unterminatedElementRunsToTheEnd() throws {
        let text = "x = <div className=\"a\">\n  text {y} more\n  <p>open\n// not a comment\nconst z = 'q'"
        let scan = try Scan("javascript", text)
        #expect(scan.end.frames == [.jsxText(depth: 2)])
        #expect(scan.at("// not a comment\nconst z = 'q'") == [plain])
    }

    @Test func deepTreesUseOneFrame() throws {
        let text = deepJSX(levels: 300)
        let scan = try Scan("javascript", text)
        #expect(scan.end.isEmpty)
        #expect(scan.at("const after") == [.code])
        // In the middle of the tree the stack holds one frame.
        let ns = text as NSString
        var state = LexicalScanState()
        try scanner("javascript").advance(ns, from: 0, to: ns.range(of: "text { x }").location, state: &state)
        #expect(state.frames == [.jsxText(depth: 300)])
        // Nested expressions push frames up to the cap, without failing.
        var nested = "x = "
        for _ in 0..<80 { nested += "<a>{" }
        nested += "y"
        for _ in 0..<80 { nested += "}</a>" }
        let capped = try Scan("javascript", nested)
        #expect(capped.at("y") == [.code] || capped.at("y") == [plain])
        #expect(try endState("javascript", nested).frames.count <= LexicalScanState.maximumDepth)
    }

    @Test func crlfMatchesLF() throws {
        for (language, text) in [("javascript", try fixture("embedded/component.jsx")),
                                 ("typescriptreact", try fixture("embedded/component.tsx")),
                                 ("javascript", syntheticJSX), ("typescriptreact", syntheticTSX)] {
            let lf = try Scan(language, text)
            let crlfText = text.replacingOccurrences(of: "\n", with: "\r\n")
            let crlf = try Scan(language, crlfText)
            #expect(crlf.end == lf.end)
            // Unit by unit, with each CRLF mapped to its LF.
            let ns = crlfText as NSString
            var map: [Int] = []
            var i = 0
            while i < ns.length {
                map.append(i)
                i += ns.character(at: i) == 13 && i + 1 < ns.length && ns.character(at: i + 1) == 10 ? 2 : 1
            }
            func kinds(_ scan: Scan) -> [LexicalSegment?] {
                var out = [LexicalSegment?](repeating: nil, count: scan.ns.length)
                for s in scan.segments { for k in s.range.location..<NSMaxRange(s.range) { out[k] = s.kind } }
                return out
            }
            let a = kinds(lf), b = kinds(crlf)
            #expect(map.count == a.count)
            #expect(map.enumerated().allSatisfy { a[$0.offset] == b[$0.element] }, "\(language)")
        }
    }

    @Test func nonBMPCharacters() throws {
        let text = "x = <𝒜b 𝒞d=\"😀\" e={😀}>😀 {f}<𝔉/>😀</𝒜b>; y = 'ok'"
        let scan = try Scan("javascript", text)
        #expect(scan.end.isEmpty)
        #expect(scan.at("𝒜b", occurrence: 1) == [component])
        #expect(scan.at("𝒞d") == [attribute])
        #expect(scan.at("\"😀\"") == [.string])
        #expect(scan.at("😀 ") == [plain])
        #expect(scan.at("𝔉") == [component])
        #expect(scan.at("'ok'") == [.string])
        // Segment boundaries never split a surrogate pair.
        for s in scan.segments where s.range.location > 0 {
            #expect(!(0xDC00...0xDFFF).contains(scan.ns.character(at: s.range.location)))
        }
    }

    @Test func htmlScriptsAndMarkdownFences() throws {
        let html = try Scan("html", "<script>const a = <b className=\"c\">t</b>;</script><p>x</p>")
        #expect(html.hasJSX)
        #expect(html.end.isEmpty)
        let md = """
            ```jsx
            const a = <b>t</b>;
            ```
            ```tsx
            const f = <T,>(x: T) => <i>{x}</i>;
            ```
            ```ts
            const g = <T>(x: T) => x;
            ```

            """
        let scan = try Scan("markdown", md)
        #expect(scan.end.isEmpty)
        #expect(scan.at("b") == [tagName])
        #expect(scan.at("<T,>(x: T) => ") == [.code])
        #expect(scan.at("i>", occurrence: 1) == [tagName, tagPunct])
        #expect(scan.at("<T>(x: T) => x;") == [.code])
        let tsx = MarkdownLanguage.fenceLanguages.firstIndex { $0.identifier == "typescriptreact" }! + 1
        #expect(scan.segments.contains { $0.language == tsx })
    }
}

// MARK: - Registration and completion positions

@Suite("JSXRegistration")
struct JSXRegistrationTests {
    @Test func extensionsAndIdentifiers() throws {
        #expect(LanguageRegistry.identifier(forExtension: "jsx") == "javascript")
        #expect(LanguageRegistry.identifier(forExtension: "TSX") == "typescriptreact")
        #expect(LanguageRegistry.identifier(forExtension: "ts") == "typescript")
        #expect(LanguageRegistry.definition(forExtension: "jsx")?.identifier == "javascript")
        #expect(LanguageRegistry.definition(forExtension: "tsx")?.identifier == "typescriptreact")
        #expect(LanguageRegistry.canonicalIdentifier("TypeScriptReact") == "typescriptreact")
        let tsx = try definition("typescriptreact")
        #expect(tsx.lexicalProfile?.jsx?.typeScript == true)
        #expect(try definition("javascript").lexicalProfile?.jsx?.typeScript == false)
        #expect(try definition("typescript").lexicalProfile?.jsx == nil)
        #expect(tsx.keywords == (try definition("typescript")).keywords)
        #expect(tsx.builtins == (try definition("typescript")).builtins)
    }

    @Test func menusSettingsAndEditorFeatures() {
        #expect(SupportedLanguage.all.contains { $0 == ("TypeScript JSX", "typescriptreact") })
        #expect(SupportedLanguage.title(forIdentifier: "typescriptreact") == "TypeScript JSX")
        #expect(LanguageMenuSettings.hideableIdentifiers.contains("typescriptreact"))
        #expect(LanguageMenuLayout.unfiltered.languages.contains { $0.identifier == "typescriptreact" })
        #expect(CommentToggle.tokens(for: "typescriptreact")?.line == "//")
        #expect(IdentifierText.allowsDollar("typescriptreact"))
        #expect(CompletionContext.selfNames("typescriptreact") == ["this"])
        #expect(DeclarationScan.usesWalker("typescriptreact"))
        #expect(!WordIndex.declarationPatterns(for: "typescriptreact").isEmpty)
        // Not runnable (Node does not strip JSX).
        #expect(RunnableLanguage(identifier: "typescriptreact") == nil)
    }

    @Test func snifferRecognisesTSX() {
        let tsx = """
            import { useState } from 'react';
            import type { Props } from './props';

            export function Counter({ start }: Props): JSX.Element {
              const [n, setN] = useState<number>(start);
              return (
                <button onClick={() => setN(n + 1)}>{n}</button>
              );
            }
            """
        #expect(LanguageSniffer.sniff(tsx) == "typescriptreact")
        let jsx = """
            import { useState } from 'react';
            import Button from './button';

            export function Counter({ start }) {
              const [n, setN] = useState(start);
              return <Button onClick={() => setN(n + 1)} />;
            }
            """
        #expect(LanguageSniffer.sniff(jsx) == "javascript")
        let ts = """
            import { a } from './a';
            import { b } from './b';
            const x: number = 1;
            function f<T>(v: T): T { return v; }
            """
        #expect(LanguageSniffer.sniff(ts) == "typescript")
    }

    @Test func completionPositionsInJSX() throws {
        let scanner = try #require(CandidateEngine.contextScanner(for: "typescriptreact", definition: nil))
        func position(_ text: String) -> CompletionContext.Position {
            var state = LexicalScanState()
            scanner.advance(text as NSString, from: 0, to: (text as NSString).length, state: &state)
            return CompletionContext.position(of: state)
        }
        #expect(position("x = <div>some te") == .string)
        #expect(position("x = <div>a</div><p>b") == .string)
        #expect(position("x = <di") == .code)
        #expect(position("x = <div class") == .code)
        #expect(position("x = <div className=\"a") == .string)
        #expect(position("x = <div>{ite") == .code)
        #expect(position("x = <div onClick={() => se") == .code)
        #expect(position("x = <div>{/* no") == .comment)
        #expect(position("x = <div></div>; y") == .code)
        // TypeScript (no JSX) and JavaScript (JSX) context scanners.
        let ts = try #require(CandidateEngine.contextScanner(for: "typescript", definition: nil))
        #expect(ts.profile.jsx == nil)
        let js = try #require(CandidateEngine.contextScanner(for: "javascript", definition: nil))
        #expect(js.profile.jsx != nil)
    }
}

// MARK: - Split and resume

@Suite("JSXSplit")
struct JSXSplitTests {
    static let documents: [(label: String, language: String)] = [
        ("component.jsx", "javascript"), ("component.tsx", "typescriptreact"), ("synthetic.jsx", "javascript"),
        ("synthetic.tsx", "typescriptreact"), ("deep.jsx", "javascript"), ("component.jsx crlf", "javascript"),
        ("component.tsx crlf", "typescriptreact"), ("synthetic.tsx crlf", "typescriptreact"),
    ]

    private func text(_ label: String) throws -> String {
        let base: String
        switch label.split(separator: " ").first! {
        case "component.jsx": base = try fixture("embedded/component.jsx")
        case "component.tsx": base = try fixture("embedded/component.tsx")
        case "synthetic.jsx": base = syntheticJSX
        case "synthetic.tsx": base = syntheticTSX
        default: base = deepJSX(levels: 220)
        }
        // Twice, so the second copy starts in the state the first left.
        let doubled = base + "\n" + base
        return label.hasSuffix("crlf") ? doubled.replacingOccurrences(of: "\n", with: "\r\n") : doubled
    }

    /// Positions strictly inside a JSX token a word / blank split could
    /// cut (see `LexicalScanner` "Split guarantee"): names and type-argument
    /// identifiers (atoms of the single pass), two-unit tokens, and the text
    /// a TSX opener's type-parameter check reads.
    private func interiors(_ ns: NSString, _ one: [Seg]) -> Set<Int> {
        var out = Set<Int>()
        for s in one {
            switch s.kind {
            case .atom(.plain): continue
            case .atom, .escape: break
            default: continue
            }
            for k in 1..<max(1, s.range.length) { out.insert(s.range.location + k) }
        }
        let patterns = [#"</|<>|/>|//|/\*|\*/|\$\{"#,
                        #"<(?:const[ \t]+[A-Za-z_$]|[A-Za-z_$][\w$]*[ \t]*(?:extends[^\w$]|[,=])?)"#]
        for pattern in patterns {
            let re = try! NSRegularExpression(pattern: pattern)
            for match in re.matches(in: ns as String, range: NSRange(location: 0, length: ns.length)) {
                for k in 1..<max(1, match.range.length) { out.insert(match.range.location + k) }
            }
        }
        return out
    }

    @Test(arguments: documents)
    func piecesAtLineStartsSplitsAndSafePointsEqualOnePass(_ doc: (label: String, language: String)) throws {
        let scanner = try scanner(doc.language)
        let ns = try text(doc.label) as NSString
        let one = Scan(scanner, ns)
        let reference = merged(one.segments)
        #expect(reference.contains { $0.kind == tagPunct })

        // Every line start at once.
        var lineState = LexicalScanState()
        var lines: [Seg] = []
        var loc = 0
        while loc < ns.length {
            let end = NSMaxRange(ns.lineRange(for: NSRange(location: loc, length: 0)))
            scanSegments(scanner, ns, from: loc, to: end, state: &lineState, into: &lines)
            loc = end
        }
        #expect(lineState == one.end)
        #expect(merged(lines) == reference)

        // Random split points between tokens: after a blank, between two
        // non-word units, inside words outside names.
        let inside = interiors(ns, reference)
        func isWord(_ u: unichar) -> Bool {
            u == 95 || u == 36 || (48...57).contains(u) || (65...90).contains(u) || (97...122).contains(u)
        }
        let candidates = (1..<ns.length).filter { p in
            guard !inside.contains(p) else { return false }
            let prev = ns.character(at: p - 1), cur = ns.character(at: p)
            if (0xD800...0xDBFF).contains(prev) || (prev == 13 && cur == 10) { return false }
            if prev == 10 || prev == 32 || prev == 9 { return true }
            return isWord(prev) && isWord(cur)
        }
        #expect(candidates.count > ns.length / 4, "too few split points: \(candidates.count)")
        var rng = SplitMix(state: 0x17_8B_5EED)
        for trial in 0..<120 {
            let k = Int.random(in: 1...6, using: &rng)
            let points = Set((0..<k).map { _ in candidates.randomElement(using: &rng)! }).sorted()
            var state = LexicalScanState()
            var advanced = LexicalScanState()
            var pieces: [Seg] = []
            var from = 0
            for to in points + [ns.length] {
                scanSegments(scanner, ns, from: from, to: to, state: &state, into: &pieces)
                scanner.advance(ns, from: from, to: to, state: &advanced)
                from = to
            }
            let same = merged(pieces) == reference && state == one.end && advanced == one.end
            #expect(same, "\(doc.label) trial \(trial): splits \(points)")
            if !same { break }
        }

        // Chains of random safe points.
        for trial in 0..<120 {
            let k = Int.random(in: 1...6, using: &rng)
            let targets = (0..<k).map { _ in Int.random(in: 0...ns.length, using: &rng) }.sorted()
            var state = LexicalScanState()
            var pieces: [Seg] = []
            var from = 0
            var failed = false
            for target in targets where target >= from {
                var advanced = state
                var plainState = state
                var stopped: [Seg] = []
                let q = scanner.segments(ns, from: from, to: ns.length, stoppingAtSafePointFrom: target, state: &state,
                                         languages: { stopped.append(Seg(range: $0, kind: $1, language: $2)) })
                let qa = scanner.advance(ns, from: from, to: ns.length, stoppingAtSafePointFrom: target, state: &advanced)
                var plainPieces: [Seg] = []
                scanSegments(scanner, ns, from: from, to: q, state: &plainState, into: &plainPieces)
                let ok = q >= target && q == qa && advanced == state && plainState == state
                    && merged(plainPieces) == merged(stopped)
                #expect(ok, "\(doc.label) trial \(trial): target \(target) → \(q) (advance \(qa))")
                if !ok { failed = true; break }
                pieces += stopped
                from = q
            }
            if failed { break }
            scanSegments(scanner, ns, from: from, to: ns.length, state: &state, into: &pieces)
            let same = merged(pieces) == reference && state == one.end
            #expect(same, "\(doc.label) trial \(trial): pieces differ for targets \(targets)")
            if !same { break }
        }
    }

    /// Every target in short texts around the JSX tokens.
    @Test func everyTargetInAdversarialTexts() throws {
        let samples: [(String, String)] = [
            ("javascript", "x = <a b=\"c>{\" c='d\r\ne'{...p} f={`g${h}`}/>;<>t<b/>{/*c*/}</>\r\n"
                + "y = <A.B\r\n // l\r\n /* m */ c>😀<i>{a < b ? <j/> : 'k'}</i></A.B> < z; r = /<a>/;"),
            ("typescriptreact", "f = <T,>(x: T) => <X<Y<Z>, () => void> a=\"1\">t</X>; g = <T extends U>() => 1;"
                + "\r\nh = <const T,>() => <T>t</T>; i = <T = V>() => j<K>(l);"),
        ]
        for (language, text) in samples {
            let scanner = try scanner(language)
            let ns = text as NSString
            let one = Scan(scanner, ns)
            for target in 0...ns.length {
                var state = LexicalScanState()
                var pieces: [Seg] = []
                let q = scanner.segments(ns, from: 0, to: ns.length, stoppingAtSafePointFrom: target, state: &state,
                                         languages: { pieces.append(Seg(range: $0, kind: $1, language: $2)) })
                var advanced = LexicalScanState()
                let qa = scanner.advance(ns, from: 0, to: ns.length, stoppingAtSafePointFrom: target, state: &advanced)
                scanSegments(scanner, ns, from: q, to: ns.length, state: &state, into: &pieces)
                let ok = q >= target && q == qa && merged(pieces) == merged(one.segments) && state == one.end
                #expect(ok, "\(language): target \(target) → \(q)")
                if !ok { break }
            }
        }
    }

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
        ("embedded/component.jsx", "javascript"), ("embedded/component.tsx", "typescriptreact"),
    ]

    /// Bands starting mid-element, from a cold checkpoint store and from one
    /// warmed by the earlier jumps, equal a fresh single pass.
    @Test(arguments: longDocuments)
    func checkpointResumeInsideElementsEqualsAFreshPass(_ sample: (file: String, language: String)) throws {
        let def = try definition(sample.language)
        let spacing = CheckpointStore.spacing
        let ns = repeated(try fixture(sample.file), longerThan: 4 * spacing + spacing / 2) as NSString
        var fullState = LexicalScanState()
        let full = def.tokens(in: ns, range: NSRange(location: 0, length: ns.length), state: &fullState)
        let fullKinds = unitKinds(full, in: NSRange(location: 0, length: ns.length))
        let texts = Scan(def.lexicalScanner!, ns).segments.filter { $0.kind == plain }
        #expect(texts.count > 100)

        var warm = CheckpointStore()
        var rng = SplitMix(state: 0xC4EC_8B17)
        for trial in 0..<40 {
            let piece = texts.randomElement(using: &rng)!
            let offset = piece.range.location + Int.random(in: 0..<piece.range.length, using: &rng)
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
        // Checkpoints taken mid-element hold a JSX frame.
        #expect(warm.entries.contains { entry in
            if case .generic(let s) = entry.state, let top = s.frames.last {
                switch top {
                case .jsxText, .jsxTag, .jsxExpression: return true
                default: return false
                }
            }
            return false
        })
    }
}

// MARK: - Long line

/// One line of minified JSX: nested elements, attribute strings with `>`
/// and `{`, expressions with nested elements, templates and regexes.
private func minifiedJSX(units: Int) -> String {
    var js = "const App=()=>(<div className=\"app\">"
    var i = 0
    while js.utf16.count < units {
        js += "<section id=\"s\(i)\" data-x='a>b{c' onClick={()=>f(\(i)<2?/<x>/g:`t${i}`)}>"
        js += "text \(i) 'q' // not a comment <b>bold</b>{list.map((n)=><Item key={n} v={n/2}/>)}{/* c */}"
        js += "<Foo.Bar {...p}>x</Foo.Bar><>😀</></section>"
        i += 1
    }
    return js + "</div>);const after=1;"
}

/// Token kind per unit of the whole text, with the identifier pass.
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

@Suite("JSXLongLine")
struct JSXLongLineTests {
    @Test(arguments: ["javascript", "typescriptreact"])
    func midLineSlicesOfMinifiedJSXMatchAFullPass(_ language: String) throws {
        let def = try definition(language)
        let ns = minifiedJSX(units: 200 * 1024) as NSString
        #expect(ns.length >= 200 * 1024 && ns.range(of: "\n").location == NSNotFound)
        let full = fullPassKinds(def, ns)
        #expect(full.contains(.tagName) && full.contains(.attributeName) && full.contains(.regex))
        var rng = SplitMix(state: 0x10_96_8B)
        var store = CheckpointStore()
        let threshold = LanguageDefinition.longLineThreshold
        for trial in 0..<100 {
            let start = Int.random(in: (threshold + 1)...(ns.length - threshold - 5_001), using: &rng)
            let end = start + Int.random(in: 1...5_000, using: &rng)
            let bounds = HighlightEngine.BandBounds(start: start, startMidLine: true, end: end, endMidLine: true)
            if trial % 3 == 0 { store = CheckpointStore() }
            let band = HighlightEngine.bandTokens(in: ns, bounds: bounds, language: def, checkpoints: &store)
            // Bounded: the painted slice is the requested one up to a few tokens.
            #expect(band.painted.location >= start && band.painted.location - start <= 600, "trial \(trial)")
            #expect(NSMaxRange(band.painted) >= end && NSMaxRange(band.painted) - end <= 600, "trial \(trial)")
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
        #expect(store.entries.allSatisfy { $0.offset > 0 })
    }
}

// MARK: - Declarations

@Suite("JSXDeclarations")
struct JSXDeclarationTests {
    private func names(_ scan: DeclarationScan) -> Set<String> { Set(scan.declarations.map(\.name)) }

    /// Words of tags, attributes and children text that must never be bindings.
    static let markupWords = ["section", "className", "data", "ratio", "aria", "label", "h2", "ul", "li", "key",
                              "input", "type", "checked", "onChange", "p", "Plain", "JSX", "text", "apostrophe",
                              "quotes", "string", "of", "chars", "span", "em", "footer", "empty", "sup", "Badge",
                              "style", "child", "comparison", "written", "b", "a"]

    @Test func componentJSX() throws {
        let text = try fixture("embedded/component.jsx")
        let scan = DeclarationScan.scan(text: text, languageIdentifier: "javascript")
        #expect(names(scan) == ["useState", "TodoList", "initial", "title", "items", "setItems", "done", "t", "ratio",
                                "item", "n", "Footer", "count", "render"])
        // `item` and `n` belong to their arrows only.
        let ns = text as NSString
        let inMap = ns.range(of: "item.done ? 'done'").location
        #expect(scan.visibleBindings(at: inMap).contains { $0.name == "item" })
        #expect(!scan.visibleBindings(at: ns.range(of: "<p>").location).contains { $0.name == "item" })
        let inRender = ns.range(of: "{n / 2}").location + 1
        #expect(scan.visibleBindings(at: inRender).contains { $0.name == "n" && $0.kind == .parameter })
        #expect(scan.scopeChain(at: inRender).first?.kind == .lambda)
        #expect(!scan.visibleBindings(at: ns.range(of: "</section>").location).contains { $0.name == "n" })
    }

    @Test func componentTSX() throws {
        let text = try fixture("embedded/component.tsx")
        let scan = DeclarationScan.scan(text: text, languageIdentifier: "typescriptreact")
        let declared = names(scan)
        #expect(declared == ["ReactNode", "Tone", "BadgeProps", "Badge", "T", "label", "tone", "count", "children",
                             "width", "ratio", "BadgeList", "labels", "casted", "l", "i"])
        for word in Self.markupWords where !["label", "Badge", "ratio"].contains(word) {
            #expect(!declared.contains(word), "\(word)")
        }
        // `l` and `i` only inside the `.map` arrow.
        let ns = text as NSString
        let arrow = ns.range(of: "(l, i) =>")
        let inside = ns.range(of: "casted[i]").location
        let visible = scan.visibleBindings(at: inside)
        #expect(visible.contains { $0.name == "l" && $0.kind == .parameter })
        #expect(visible.contains { $0.name == "i" && $0.kind == .parameter })
        #expect(scan.scopeChain(at: inside).first?.kind == .lambda)
        for outside in [arrow.location - 2, ns.range(of: "</ul>").location, ns.range(of: "const casted").location] {
            let names = Set(scan.visibleBindings(at: outside).map(\.name))
            #expect(!names.contains("l") && !names.contains("i"), "at \(outside)")
        }
        // The lambda scope ends inside the `{…}` expression.
        let lambda = try #require(scan.scopes.first { $0.kind == .lambda && $0.start >= arrow.location })
        #expect(lambda.end <= ns.range(of: "))}").location + 2)
    }

    /// The T17.4a gap: tag names, attributes and text words in `{…}`
    /// children produced stray bindings.
    @Test func noBindingsFromMarkup() throws {
        let text = """
            function A({ rows }) {
              const total = 1;
              return (
                <table summary="let x = 1">
                  {rows.map((row, k) => <tr key={k} onClick={(e) => use(e, row)}>{row.cells.map((c) => <td>{c}</td>)}</tr>)}
                  <tfoot>const fake = 2; function ghost() {} {total}</tfoot>
                  <Child render={(v) => <b>{v}</b>} {...{ spread: 1 }} />
                </table>
              );
            }
            const B = () => <i>let y = 3</i>;
            """
        for language in ["javascript", "typescriptreact"] {
            let scan = DeclarationScan.scan(text: text, languageIdentifier: language)
            #expect(names(scan) == ["A", "rows", "total", "row", "k", "e", "c", "v", "B"], "\(language)")
            let ns = text as NSString
            let cell = ns.range(of: "{c}").location + 1
            #expect(scan.visibleBindings(at: cell).contains { $0.name == "c" })
            #expect(scan.visibleBindings(at: cell).contains { $0.name == "row" })
            let foot = ns.range(of: "{total}").location + 1
            let visible = Set(scan.visibleBindings(at: foot).map(\.name))
            #expect(visible.contains("total") && !visible.contains("row") && !visible.contains("c"), "\(language)")
            #expect(!scan.completionSymbols.contains("fake") && !scan.completionSymbols.contains("ghost"))
        }
    }
}
