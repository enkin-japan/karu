import Foundation
import Testing
@testable import KaruCore

// M17 T17.2 — the generic lexical scanner on synthetic profiles: every
// delimiter kind and profile feature, line terminators, the frame cap, and
// the two modes agreeing.

// MARK: - Helpers

/// Segments of `text[from..<to]` as `(text, segment)` pairs, after checking
/// that they cover the range gap-free, ascending, and are maximal runs; also
/// checks that `advance` reaches the same end state.
private func scan(_ scanner: LexicalScanner, _ text: String,
                  from: Int? = nil, to: Int? = nil,
                  state: inout LexicalScanState,
                  sourceLocation: SourceLocation = #_sourceLocation) -> [(String, LexicalSegment)] {
    let ns = text as NSString
    let start = from ?? 0
    let end = to ?? ns.length
    var advanced = state
    scanner.advance(ns, from: start, to: end, state: &advanced)
    var out: [(NSRange, LexicalSegment)] = []
    scanner.segments(ns, from: start, to: end, state: &state) { out.append(($0, $1)) }
    #expect(advanced == state, "advance and segments disagree on the end state", sourceLocation: sourceLocation)
    var cursor = start
    for (index, (range, kind)) in out.enumerated() {
        #expect(range.location == cursor && range.length > 0, "gap or empty segment at \(range)",
                sourceLocation: sourceLocation)
        if index > 0 { #expect(out[index - 1].1 != kind, "segments not maximal at \(range)", sourceLocation: sourceLocation) }
        cursor = NSMaxRange(range)
    }
    #expect(cursor == end || (out.isEmpty && start == end), "segments end at \(cursor), expected \(end)",
            sourceLocation: sourceLocation)
    return out.map { (ns.substring(with: $0.0), $0.1) }
}

private func scan(_ scanner: LexicalScanner, _ text: String,
                  sourceLocation: SourceLocation = #_sourceLocation) -> (segments: [(String, LexicalSegment)],
                                                                       state: LexicalScanState) {
    var state = LexicalScanState()
    let segments = scan(scanner, text, state: &state, sourceLocation: sourceLocation)
    return (segments, state)
}

private func expectSegments(_ actual: [(String, LexicalSegment)], _ expected: [(String, LexicalSegment)],
                            sourceLocation: SourceLocation = #_sourceLocation) {
    let a = actual.map { "\($0.1)|\($0.0)" }
    let e = expected.map { "\($0.1)|\($0.0)" }
    #expect(a == e, sourceLocation: sourceLocation)
}

private typealias Form = LexicalProfile.StringForm

private let jsLike = LexicalScanner(profile: JavaScriptLanguage.lexicalProfile)
private let rust = LexicalScanner(profile: RustLanguage.lexicalProfile)

// MARK: - Comments

@Suite("LexicalScanner")
struct LexicalScannerTests {
    @Test func nestedBlockCommentsCountDepth() {
        let nesting = LexicalScanner(profile: .init(blockComments: [.init(open: "/*", close: "*/", nests: true)]))
        let text = "a /* x /* y */ z */ b"
        expectSegments(scan(nesting, text).segments,
                       [("a ", .code), ("/* x /* y */ z */", .comment), (" b", .code)])

        // Non-nesting: the first closer ends the comment.
        let flat = LexicalScanner(profile: .init(blockComments: [.init(open: "/*", close: "*/")]))
        expectSegments(scan(flat, text).segments,
                       [("a ", .code), ("/* x /* y */", .comment), (" z */ b", .code)])

        // Depth is carried across lines and calls.
        var state = LexicalScanState()
        _ = scan(nesting, "/* /* /*\n", state: &state)
        #expect(state.frames == [.blockComment(form: 0, depth: 3)])
        _ = scan(nesting, "*/ */\n", state: &state)
        #expect(state.frames == [.blockComment(form: 0, depth: 1)])
        expectSegments(scan(nesting, "x */ y", state: &state), [("x */", .comment), (" y", .code)])
        #expect(state.isEmpty)

        // `/*/` opens without closing.
        expectSegments(scan(flat, "/*/ c */ d").segments, [("/*/ c */", .comment), (" d", .code)])
    }

    @Test func lineCommentsEndAtEveryTerminator() {
        for terminator in ["\n", "\r", "\r\n"] {
            let r = scan(jsLike, "a // c '\"`\(terminator)b")
            expectSegments(r.segments, [("a ", .code), ("// c '\"`", .comment), ("\(terminator)b", .code)])
            #expect(r.state.isEmpty)
        }
        // A range ending inside a line comment carries it.
        var state = LexicalScanState()
        _ = scan(jsLike, "x // open", state: &state)
        #expect(state.frames == [.lineComment])
    }

    // MARK: - Interpolation

    @Test func interpolationsNestStringsThatInterpolate() {
        let r = scan(jsLike, "`a ${ `b ${x} c` } d` e")
        expectSegments(r.segments, [
            ("`a ", .string), ("${", .interpolationDelimiter), (" ", .code),
            ("`b ", .string), ("${", .interpolationDelimiter), ("x", .code), ("}", .interpolationDelimiter),
            (" c`", .string), (" ", .code), ("}", .interpolationDelimiter), (" d`", .string), (" e", .code),
        ])
        #expect(r.state.isEmpty)
    }

    @Test func bracesInsideInterpolationDoNotCloseIt() {
        let r = scan(jsLike, "`${ {a: {b: 1}}.a + f(g[0]) } tail`;")
        expectSegments(r.segments, [
            ("`", .string), ("${", .interpolationDelimiter), (" {a: {b: 1}}.a + f(g[0]) ", .code),
            ("}", .interpolationDelimiter), (" tail`", .string), (";", .code),
        ])
        // A multi-line template keeps the interpolation (and its depth) open.
        var state = LexicalScanState()
        _ = scan(jsLike, "`x ${ {\n", state: &state)
        #expect(state.frames == [.string(form: 2, count: 0, delimiter: nil),
                                 .interpolation(form: 2, interpolation: 0, depth: 1)])
        expectSegments(scan(jsLike, "} }`;", state: &state),
                       [("} ", .code), ("}", .interpolationDelimiter), ("`", .string), (";", .code)])
        #expect(state.isEmpty)
    }

    @Test func escapedInterpolationOpenerIsContent() {
        let fString = LexicalScanner(profile: .init(strings: [
            Form(prefixes: ["f"], prefixRequired: true, delimiter: .fixed(open: "\"", close: "\""),
                 multiline: false, interpolations: [.init(open: "{", close: "}", escapedOpen: "{{")]),
            Form(delimiter: .fixed(open: "\"", close: "\""), multiline: false),
        ]))
        expectSegments(scan(fString, "f\"{{x}} {y}\" \"{z}\"").segments, [
            ("f\"{{x}} ", .string), ("{", .interpolationDelimiter), ("y", .code), ("}", .interpolationDelimiter),
            ("\"", .string), (" ", .code), ("\"{z}\"", .string),
        ])
    }

    @Test func lineEndInsideInterpolationClosesTheSingleLineString() {
        let profile = LexicalProfile(strings: [
            Form(delimiter: .fixed(open: "\"", close: "\""), multiline: false,
                 interpolations: [.init(open: "{", close: "}")]),
            Form(delimiter: .fixed(open: "`", close: "`"), multiline: true,
                 interpolations: [.init(open: "{", close: "}")]),
        ])
        let scanner = LexicalScanner(profile: profile)
        var state = LexicalScanState()
        _ = scan(scanner, "\"a {b \"c {d\n", state: &state)
        #expect(state.isEmpty)
        // …but a multi-line string below keeps its interpolation open.
        _ = scan(scanner, "`a {b \"c {d\n", state: &state)
        #expect(state.frames == [.string(form: 1, count: 0, delimiter: nil),
                                 .interpolation(form: 1, interpolation: 0, depth: 0)])
    }

    // MARK: - Escapes and single-line strings

    @Test func escapesIncludingEscapedQuoteAtLineEnd() {
        // T17.7: an escape sequence is its own `.escape` segment.
        expectSegments(scan(jsLike, #"x = "a\"b" + 'c\'d';"#).segments, [
            ("x = ", .code), (#""a"#, .string), (#"\""#, .escape), (#"b""#, .string), (" + ", .code),
            ("'c", .string), (#"\'"#, .escape), ("d'", .string), (";", .code),
        ])
        // An escaped quote right before the line end: the string is
        // unterminated and ends with its line.
        let open = scan(jsLike, "s = \"abc\\\"\nlet y")
        expectSegments(open.segments, [("s = ", .code), ("\"abc", .string), ("\\\"", .escape), ("\nlet y", .code)])
        #expect(open.state.isEmpty)
        // Escape + newline continues the string (LF, CR and CRLF; the
        // terminator belongs to the escape).
        for terminator in ["\n", "\r", "\r\n"] {
            let continued = scan(jsLike, "s = \"abc\\\(terminator)def\" x")
            expectSegments(continued.segments,
                           [("s = ", .code), ("\"abc", .string), ("\\\(terminator)", .escape), ("def\"", .string),
                            (" x", .code)])
        }
    }

    @Test func unterminatedSingleLineStringEndsAtEndOfLine() {
        for terminator in ["\n", "\r", "\r\n"] {
            let r = scan(jsLike, "'abc\(terminator)let x = \"q")
            expectSegments(r.segments, [("'abc", .string), ("\(terminator)let x = ", .code), ("\"q", .string)])
            // The final line has no terminator, so the string is still open.
            #expect(r.state.frames == [.string(form: 0, count: 0, delimiter: nil)])
        }
    }

    @Test func doubledClosersAreEscapes() {
        let sql = LexicalScanner(profile: .init(strings: [
            Form(delimiter: .fixed(open: "'", close: "'"), multiline: true, escape: nil, doubledCloseEscapes: true),
        ]))
        expectSegments(scan(sql, "x 'it''s' y ''''").segments,
                       [("x ", .code), ("'it''s'", .string), (" y ", .code), ("''''", .string)])
    }

    // MARK: - Delimiter kinds

    @Test func repeatedQuoteClosesOnlyWithTheSameRunLength() {
        let raw = LexicalScanner(profile: .init(strings: [
            Form(delimiter: .repeatedQuote(quote: "\"", minimum: 3), multiline: true, escape: nil),
            Form(delimiter: .fixed(open: "\"", close: "\""), multiline: false),
        ]))
        expectSegments(scan(raw, "\"\"\"\"a \"\"\" b\"\"\"\"x").segments,
                       [("\"\"\"\"a \"\"\" b\"\"\"\"", .string), ("x", .code)])
        expectSegments(scan(raw, "\"\"\"a\"\"\"\"b\"\"\" y").segments,
                       [("\"\"\"a\"\"\"\"b\"\"\"", .string), (" y", .code)])
        // Two quotes are below the minimum: the next form (an empty string).
        expectSegments(scan(raw, "\"\" z").segments, [("\"\"", .string), (" z", .code)])
        var state = LexicalScanState()
        _ = scan(raw, "s = \"\"\"\"\n", state: &state)
        #expect(state.frames == [.string(form: 0, count: 4, delimiter: nil)])
        _ = scan(raw, "\"\"\"\n", state: &state)
        #expect(state.frames.count == 1)
        _ = scan(raw, "\"\"\"\";\n", state: &state)
        #expect(state.isEmpty)
    }

    @Test func hashedDelimitersWithHashedEscapesAndInterpolation() {
        let swiftLike = LexicalScanner(profile: .init(strings: [
            Form(delimiter: .hashed(lead: "", hash: "#", quote: "\"", hashesApplyToEscapes: true),
                 multiline: false, interpolations: [.init(open: "\\(", close: ")")]),
        ]))
        // T17.7: `\#"` (escape + hashes + escaped unit) is an escape segment.
        expectSegments(scan(swiftLike, ##"x #"a \(x) \#(y + f(1)) \#"q"# z"##).segments, [
            ("x ", .code), (##"#"a \(x) "##, .string), (##"\#("##, .interpolationDelimiter), ("y + f(1)", .code),
            (")", .interpolationDelimiter), (" ", .string), (##"\#""##, .escape), (##"q"#"##, .string), (" z", .code),
        ])
        // n = 0: the ordinary escape and interpolation.
        expectSegments(scan(swiftLike, #""a \"b\" \(c)""#).segments, [
            (#""a "#, .string), (#"\""#, .escape), ("b", .string), (#"\""#, .escape), (" ", .string),
            (#"\("#, .interpolationDelimiter), ("c", .code), (")", .interpolationDelimiter), (#"""#, .string),
        ])

        // Rust raw strings: any number of hashes, no escapes.
        expectSegments(scan(rust, ##"let s = r#"a "b" "# x"##).segments,
                       [("let s = ", .code), (##"r#"a "b" "#"##, .string), (" x", .code)])
        expectSegments(scan(rust, ###"r##"a "# b"## c"###).segments,
                       [(###"r##"a "# b"##"###, .string), (" c", .code)])
        expectSegments(scan(rust, #"r"a\" b"#).segments, [(#"r"a\""#, .string), (" b", .code)])
        expectSegments(scan(rust, ##"br#"x"# b"y" c"z""##).segments,
                       [(##"br#"x"#"##, .string), (" ", .code), (#"b"y""#, .string), (" ", .code), (#"c"z""#, .string)])
        // A raw string spans lines; the hash count is part of the state.
        var state = LexicalScanState()
        _ = scan(rust, "r##\"\n", state: &state)
        #expect(state.frames == [.string(form: 0, count: 2, delimiter: nil)])
    }

    @Test func cppRawStringsUseTheirDelimiter() {
        let cpp = LexicalScanner(profile: .init(strings: [
            Form(prefixes: ["u8", "u", "U", "L"], delimiter: .cppRaw, multiline: true, escape: nil),
            Form(prefixes: ["u8", "u", "U", "L"], delimiter: .fixed(open: "\"", close: "\""), multiline: false),
        ]))
        expectSegments(scan(cpp, #"a R"xy(q )" b)x" c)xy" d"#).segments,
                       [("a ", .code), (#"R"xy(q )" b)x" c)xy""#, .string), (" d", .code)])
        expectSegments(scan(cpp, #"u8R"(x\)" y"#).segments, [(#"u8R"(x\)""#, .string), (" y", .code)])
        // A space is not allowed in the delimiter: an ordinary string.
        expectSegments(scan(cpp, #"R"a b(x)" z"#).segments, [("R", .code), (#""a b(x)""#, .string), (" z", .code)])
        var state = LexicalScanState()
        _ = scan(cpp, "R\"END(\n", state: &state)
        #expect(state.frames == [.string(form: 0, count: 0, delimiter: "END")])
        expectSegments(scan(cpp, ")\" )END\";", state: &state), [(")\" )END\"", .string), (";", .code)])
    }

    @Test func prefixesAndLeadsNeedAWordBoundary() {
        // `xr"…"` is the identifier `xr` and an ordinary (escaping) string.
        expectSegments(scan(rust, #"xr"\"" y"#).segments,
                       [("xr", .code), (#"""#, .string), (#"\""#, .escape), (#"""#, .string), (" y", .code)])
        // `r"\"` is raw: the backslash does not escape.
        expectSegments(scan(rust, #"r"\" + 1"#).segments, [(#"r"\""#, .string), (" + 1", .code)])
        expectSegments(scan(rust, #"xb"q" b"q""#).segments,
                       [("xb", .code), (#""q""#, .string), (" ", .code), (#"b"q""#, .string)])
        // Case-insensitive prefixes, longest first.
        let py = LexicalScanner(profile: .init(strings: [
            Form(prefixes: ["rb", "br", "r", "b"], prefixCaseInsensitive: true,
                 delimiter: .fixed(open: "'", close: "'"), multiline: false, escape: nil),
        ]))
        expectSegments(scan(py, "Rb'x' xRb'y'").segments,
                       [("Rb'x'", .string), (" xRb", .code), ("'y'", .string)])
    }

    // MARK: - Atoms

    @Test func atomsNeverOpenStrings() {
        // T17.7: Rust lifetimes are `.type` atoms (`entity.name.type.lifetime`).
        expectSegments(scan(rust, #"let q = '"'; f::<'a>(b'"', '\'', x) "s""#).segments, [
            ("let q = ", .code), (#"'"'"#, .atom(.string)), ("; f::<", .code), ("'a", .atom(.type)),
            (">(", .code), (#"b'"'"#, .atom(.string)), (", ", .code), (#"'\''"#, .atom(.string)),
            (", x) ", .code), (#""s""#, .string),
        ])
        #expect(scan(rust, "fn f<'a>(x: &'a str) {}").state.isEmpty)
    }

    // MARK: - Ranges, terminators, cap

    @Test func blockCommentsCrossCRLFLines() {
        let r = scan(jsLike, "a /* x\r\n y\r * z\n */ b")
        expectSegments(r.segments, [("a ", .code), ("/* x\r\n y\r * z\n */", .comment), (" b", .code)])
    }

    @Test func arbitrarySubrangesAreScannedInPlace() {
        // Mid-line ranges: the state at `from` is supplied by the caller.
        let text = "aa `t ${x} u` bb"
        var state = LexicalScanState()
        _ = scan(jsLike, text, from: 0, to: 6, state: &state)
        #expect(state.frames == [.string(form: 2, count: 0, delimiter: nil)])
        expectSegments(scan(jsLike, text, from: 6, to: 9, state: &state),
                       [("${", .interpolationDelimiter), ("x", .code)])
        expectSegments(scan(jsLike, text, from: 9, to: 16, state: &state),
                       [("}", .interpolationDelimiter), (" u`", .string), (" bb", .code)])
        #expect(state.isEmpty)
        // Out-of-range bounds are clamped.
        var clamped = LexicalScanState()
        jsLike.advance(text as NSString, from: -5, to: 1_000, state: &clamped)
        #expect(clamped.isEmpty)
    }

    @Test func frameStackIsCappedAt64() {
        let deep = String(repeating: "`${", count: 50) + "x" + String(repeating: "}`", count: 50)
        var state = LexicalScanState()
        _ = scan(jsLike, String(repeating: "`${", count: 50), state: &state)
        #expect(state.frames.count == LexicalScanState.maximumDepth)
        // Nothing traps and the whole text is still segmented.
        let r = scan(jsLike, deep)
        #expect(r.segments.map(\.0).joined() == deep)
        #expect(r.state.frames.count <= LexicalScanState.maximumDepth)
        // A nesting block comment counts depth inside a single frame.
        let nesting = LexicalScanner(profile: .init(blockComments: [.init(open: "/*", close: "*/", nests: true)]))
        var comment = LexicalScanState()
        _ = scan(nesting, String(repeating: "/*", count: 100), state: &comment)
        #expect(comment.frames == [.blockComment(form: 0, depth: 100)])
    }

    @Test func emptyAndMarkerFreeInputs() {
        #expect(scan(jsLike, "").segments.isEmpty)
        expectSegments(scan(jsLike, "plain code 1 + 2").segments, [("plain code 1 + 2", .code)])
        let none = LexicalScanner(profile: .init())
        expectSegments(scan(none, "a \"b\" /* c */").segments, [("a \"b\" /* c */", .code)])
    }
}
