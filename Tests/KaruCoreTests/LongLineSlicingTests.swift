import AppKit
import Foundation
import Testing
@testable import KaruCore

// M17 long-line slicing (plan §6 item 2): the scanner's safe-point stop, the
// band bounds that stop snapping to whole lines inside a long line, and the
// engine painting only a slice of a multi-megabyte line while agreeing with a
// full single pass over it.

// MARK: - Helpers

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

/// Merges adjacent runs of the same kind and language (T17.8a: the
/// language index of `segments(…languages:)`, 0 for the host).
private func merged(_ segments: [(NSRange, LexicalSegment, Int)]) -> [(NSRange, LexicalSegment, Int)] {
    var out: [(NSRange, LexicalSegment, Int)] = []
    for (range, kind, language) in segments {
        if let last = out.last, last.1 == kind, last.2 == language, NSMaxRange(last.0) == range.location {
            out[out.count - 1].0.length += range.length
        } else {
            out.append((range, kind, language))
        }
    }
    return out
}

private func sameSegments(_ a: [(NSRange, LexicalSegment, Int)], _ b: [(NSRange, LexicalSegment, Int)]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 && $0.2 == $1.2 }
}

/// An independent statement of the safe-point conditions (`LexicalScanner`
/// "Safe points"), from the profile alone.
private struct SafePointOracle {
    let lookback: Set<unichar>

    init(_ profile: LexicalProfile) {
        var units = Set<unichar>()
        func add(_ text: String, bothCases: Bool) {
            for u in text.utf16 {
                units.insert(u)
                if bothCases {
                    units.formUnion(String(text).lowercased().utf16)
                    units.formUnion(String(text).uppercased().utf16)
                }
            }
        }
        for form in profile.strings {
            form.prefixes.forEach { add($0, bothCases: form.prefixCaseInsensitive) }
            switch form.delimiter {
            case .hashed(let lead, let hash, _, _): add(lead, bothCases: false); add(String(hash), bothCases: false)
            case .cppRaw: add("R", bothCases: false)
            case .fixed, .repeatedQuote: break
            }
        }
        for atom in profile.atoms { atom.prefixes.forEach { add($0, bothCases: false) } }
        lookback = units
    }

    static func isIdentifier(_ u: unichar) -> Bool {
        u == 95 || (48...57).contains(u) || (65...90).contains(u) || (97...122).contains(u) || u >= 128
    }

    func isFriendly(_ ns: NSString, _ q: Int, to: Int, state: LexicalScanState) -> Bool {
        guard q > 0, q < to else { return true }
        let previous = ns.character(at: q - 1), current = ns.character(at: q)
        if (0xD800...0xDBFF).contains(previous) { return false }
        if Self.isIdentifier(previous) && Self.isIdentifier(current) { return false }
        if previous == 13 && current == 10 { return false }
        let code: Bool
        switch state.frames.last {
        case nil, .interpolation?, .heredoc(_, _, false)?, .jsxExpression?: code = true
        default: code = false
        }
        return !(code && lookback.contains(previous))
    }
}

/// For each target: the stop `p` lies in `[target, to]`, is friendly, both
/// stopping modes agree, the emitted segments cover `[from, p)`, and scanning
/// `from..<p` (stopping) then `p..<to` (plain) equals one pass over
/// `from..<to`. Returns the number of failing targets (stops at the first).
@discardableResult
private func checkStops(_ scanner: LexicalScanner, _ ns: NSString, from: Int = 0, initial: LexicalScanState = LexicalScanState(),
                        targets: [Int], label: String,
                        sourceLocation: SourceLocation = #_sourceLocation) -> Int {
    let to = ns.length
    let oracle = SafePointOracle(scanner.profile)
    var oneState = initial
    var one: [(NSRange, LexicalSegment, Int)] = []
    scanner.segments(ns, from: from, to: to, state: &oneState, languages: { one.append(($0, $1, $2)) })
    one = merged(one)

    for target in targets {
        var state = initial
        var pieces: [(NSRange, LexicalSegment, Int)] = []
        let p = scanner.segments(ns, from: from, to: to, stoppingAtSafePointFrom: target, state: &state,
                                 languages: { pieces.append(($0, $1, $2)) })
        var advanced = initial
        let pAdvanced = scanner.advance(ns, from: from, to: to, stoppingAtSafePointFrom: target, state: &advanced)
        let clamped = min(max(target, from), to)
        let covered = pieces.isEmpty ? p == from
            : pieces.first!.0.location == from && NSMaxRange(pieces.last!.0) == p
        let friendly = oracle.isFriendly(ns, p, to: to, state: state)
        var rest = state
        scanner.segments(ns, from: p, to: to, state: &rest, languages: { pieces.append(($0, $1, $2)) })
        let joined = merged(pieces)
        let ok = p == pAdvanced && state == advanced && clamped <= p && p <= to && covered && friendly
            && rest == oneState && sameSegments(joined, one)
        if !ok {
            let around = ns.substring(with: NSRange(location: max(0, p - 12), length: min(to, p + 12) - max(0, p - 12)))
            Issue.record("""
                \(label): target \(target) → stop \(p) (advance: \(pAdvanced), same state: \(state == advanced)), \
                in range: \(clamped <= p && p <= to), covered: \(covered), friendly: \(friendly), \
                end state equal: \(rest == oneState), segments equal: \(sameSegments(joined, one)); \
                around: \(around.debugDescription)
                """, sourceLocation: sourceLocation)
            return 1
        }
    }
    return 0
}

/// Every delimiter kind and feature in one profile: Rust-like raw strings
/// (`r#"…"#`, `b`/`rb` prefixes), C++ raw strings, a Swift-like hashed string
/// whose hashes apply to escapes with escape-led interpolation (`\(`,
/// `\#(`), C#-like repeated-quote raw strings, a template with `${…}` and
/// `{…}` (escaped `{{`) and case-insensitive `f` prefix, a single-line string
/// with doubled closers, nesting and non-nesting block comments, line
/// comments, and a char atom with a `b` prefix.
private let syntheticProfile = LexicalProfile(
    lineComments: ["//"],
    blockComments: [.init(open: "/*", close: "*/", nests: true), .init(open: "(*", close: "*)")],
    strings: [
        .init(prefixes: ["b", "rb"], delimiter: .hashed(lead: "r", hash: "#", quote: "\"", hashesApplyToEscapes: false),
              multiline: true, escape: nil),
        .init(delimiter: .cppRaw, multiline: true, escape: nil),
        .init(delimiter: .hashed(lead: "", hash: "#", quote: "\"", hashesApplyToEscapes: true), multiline: false,
              interpolations: [.init(open: "\\(", close: ")")]),
        .init(delimiter: .repeatedQuote(quote: "'", minimum: 3), multiline: true, escape: nil),
        .init(prefixes: ["f"], prefixCaseInsensitive: true, delimiter: .fixed(open: "`", close: "`"), multiline: true,
              interpolations: [.init(open: "${", close: "}"), .init(open: "{", close: "}", escapedOpen: "{{")]),
        .init(delimiter: .fixed(open: "%", close: "%"), multiline: false, escape: nil, doubledCloseEscapes: true),
    ],
    atoms: [
        .init(pattern: #"'(?:[^'\\\r\n]|\\(?:u\{[0-9A-Fa-f]{1,6}\}|[^\r\n]))'"#, firstCharacters: "'",
              kind: .string, prefixes: ["b"]),
    ]
)

private let cFragments = ["\"", "L\"", "u8\"", "'", "'x'", "L'x'", "u8'a'", "'\\''", "1'000", "\\", "\\\"", "//",
                          "/*", "*/", "*", "/", "\n", "\r\n", " ", "abc", "x1", "42", "😀", "(", ")", "#include",
                          "<a.h>", "u", "L", "U", "8",
                          // T17.7: long escape forms.
                          "\\x4F", "\\xABCDEF0123", "\\U0001F600", "\\u20AC", "\\377", "%zu", "%s"]
private let markupFragments = ["<!--", "-->", "--", "<", ">", "\"", "'", "a=", "<div", "\n", "\r\n", " ", "abc",
                               "&amp;", "😀", "!", "["]

private let fragments: [String: [String]] = [
    "javascript": ["\"", "'", "`", "${", "}", "{", "\\", "\\\"", "\\`", "//", "/*", "*/", "*", "/", "\n", "\r\n",
                   " ", "abc", "x1", "42", "1.5", "😀", "(", ")", "+", "=", ";", "r", "é",
                   "/re/g", "/[/]/", "\\/", "[", "]", "return ", "\t", "/'/",
                   // T17.7: long escape forms, complete and cut short.
                   "\\x41", "\\x4", "\\u0041", "\\u00", "\\u{1F600}", "\\u{", "\\012", "\\0", "u", "F"],
    "c": cFragments,
    "cpp": cFragments + ["R\"(", ")\"", "R\"d(", ")d\"", "u8R\"x(", ")x\"", "R"],
    "csharp": ["\"", "\"\"", "\"\"\"", "\"\"\"\"", "$\"", "$$\"\"\"", "$\"\"\"", "@\"", "$@\"", "@$\"", "{", "{{", "}",
               "}}", "'", "'x'", "'\\''", "\\", "\\\"", "//", "/*", "*/", "\n", "\r\n", " ", "abc", "42", "😀",
               "(", ")", "$", "@"],
    "java": ["\"", "\"\"\"", "'", "'x'", "'\\''", "\\", "\\\"", "//", "/*", "*/", "\n", "\r\n", " ", "abc", "42",
             "😀", "(", ")", "@A"],
    "go": ["\"", "`", "'", "'x'", "'\\''", "\\", "\\\"", "//", "/*", "*/", "\n", "\r\n", " ", "abc", "42", "😀"],
    "css": ["\"", "'", "\\", "\\\"", "/*", "*/", "*", "/", "\n", "\r\n", " ", "a", "{", "}", ":", ";", "#fff",
            "😀", "1px"],
    "sql": ["'", "''", "\"", "\"\"", "`", "--", "-", "/*", "*/", "*", "/", "$$", "\n", "\r\n", " ", "SELECT", "x1",
            "42", "😀", "\\"],
    "swift": ["\"", "\"\"\"", "#\"", "\"#", "##\"", "\"##", "#\"\"\"", "\"\"\"#", "\\(", "\\#(", "\\##(", ")", "(",
              "\\", "\\\"", "#", "/*", "*/", "//", "\n", "\r\n", " ", "abc", "42", "😀",
              "\\u{1F600}", "\\#u{41}", "\\u{", "\\#n"],
    "toml": ["\"", "\"\"\"", "'", "'''", "#", "\\", "\\\"", "=", "[", "]", "\n", "\r\n", " ", "key", "42", "😀"],
    "html": markupFragments,
    "xml": markupFragments + ["<![CDATA[", "]]>", "]]", "<?xml", "CDATA"],
    "rust": ["\"", "r\"", "r#\"", "\"#", "br##\"", "\"##", "b\"", "c\"", "'", "'a", "'x'", "b'x'", "'\\u{1F600}'",
             "'\\''", "/*", "*/", "//", "\\", "#", "r", "b", "\n", "\r\n", " ", "abc", "42", "😀", "(", ")", "!",
             "\\x7f", "\\x7", "\\u{10FFFF}", "\\u{_1}"],
    "json": ["\"", "\\", "\\\"", "{", "}", ":", ",", "[", "]", "1.5", "-2", "true", "null", " ", "\n", "\r\n",
             "😀", "abc", "\"k\":", "\"v\""],
    "bash": ["<<", "<<-", "<<<", "EOF", "\tEOF", "'EOF'", "\"EOF\"", "\\EOF", "\n", "\r\n", "\r", " ", "\t", "#",
             "$#", "${", "$(", ")", "}", "`", "\"", "'", "$'", "\\", "\\\"", "a", "x1", "😀", ";", "|", "&", "(",
             "\nEOF\n", "\n\tEOF\r\n", "<<EOF\n", "<<-EOF\n",
             // T17.7: variables inside double quotes (`"$x"`, `"$1"`, `"$@"`).
             "$x", "$abc_1", "$1", "$@", "$$", "$-", "$"],
    "yaml": ["|", ">", "|-", ">+", "|2", "-", "- ", ":", ": ", "?", "#", " #", "\"", "'", "''", "\\", "\\\"", "\n",
             "\r\n", "\r", " ", "  ", "    ", "\t", "key", "a", "😀", "[", ",", "{", "---",
             ": |\n  ", "\n- |\n", "\n  ", "\n    "],
    "markdown": ["```", "````", "~~~", "~~~~", "`", "~", "   ", " ", "    ", "\n", "\r\n", "\r", "<!--", "-->", "--",
                 "<", "a", "js", "😀", "#", "*", "\t", "\n```\n", "\n~~~~\n", "\n   ```js\n"],
    // T17.8a: `<script>` / `<style>` start tags (types, quotes, `>` in a
    // value), end tags in any case, and JS / CSS inside the bodies.
    "htmlEmbedded": markupFragments + ["<script>", "<script ", "<SCRIPT\n", "</script>", "</Script ", "</script",
                                       "<style>", "</style>", "</STYLE\n", "type=", "\"module\"", "'text/x'",
                                       "=", ">", "`", "${", "}", "/*", "*/", "//", "/re/", "\\", "'", "a=1;"],
    // T17.8a: fences of known languages around code with their constructs.
    "markdownEmbedded": ["```", "````", "~~~", "\n```js\n", "\n```python\n", "\n~~~ts {x}\n", "\n```json\n",
                         "\n```bash\n", "\n```markdown\n", "\n```\n", "\n~~~\n", "\r\n", "\n", " ", "`", "${",
                         "}", "/*", "*/", "//", "#", "\"", "'", "\"\"\"", "'''", "<<EOF\n", "\nEOF\n", "<!--",
                         "-->", "abc", "😀", "\\", "f'", "{"],
    // T17.8b: JSX elements (tags, names, attributes, strings, expressions,
    // fragments, comments in tags) and, for TSX, generic arrows and type
    // arguments.
    "jsx": ["<", "</", ">", "/>", "<>", "</>", "{", "}", "x = ", "return ", "(", ")", "=>", "a", "Foo.Bar", "svg:r",
            "data-x", "=", "\"", "'", "\"a>b{\"", "`", "${", "//", "/*", "*/", "\n", "\r\n", " ", "😀", "<div ",
            "{...p}", "a < b", "/re/", "?", ":", "&&"],
    "tsx": ["<", "</", ">", "/>", "<>", "{", "}", "x = ", "(", ")", "=>", "T", "Foo", "div", "<T,>", "<T ",
            "extends ", "const ", ",", "=", "<string>", "\"", "'", "`", "${", "//", "/*", "*/", "\n", "\r\n", " ",
            "\t", "😀", "a<b>c", ": "],
    "synthetic": ["\"", "r\"", "r#\"", "\"#", "rb##\"", "\"##", "R\"d(", ")d\"", "R\"(", ")\"", "#\"", "\\(", "\\#(",
                  ")", "(", "\\", "#", "'''", "''''", "'", "'x'", "b'x'", "`", "f`", "F`", "${", "{", "{{", "}",
                  "%", "%%", "//", "/*", "*/", "(*", "*)", "\n", "\r\n", "\r", " ", "abc", "x1", "😀", "R", "b",
                  "r", "f"],
]

private func randomText(_ pieces: [String], count: Int, rng: inout SplitMix) -> String {
    var out = ""
    for _ in 0..<count { out += pieces.randomElement(using: &rng)! }
    return out
}

private func scanner(_ language: String) throws -> LexicalScanner {
    if language == "synthetic" { return LexicalScanner(profile: syntheticProfile) }
    return try #require(LanguageRegistry.definition(forIdentifier: language)?.lexicalScanner)
}

// MARK: - Scanner: safe-point stops

@Suite("LongLineSlicingScanner")
struct LongLineSlicingScannerTests {
    static let languages: [(language: String, fragments: String)] = [
        ("javascript", "javascript"), ("typescript", "javascript"), ("rust", "rust"), ("json", "json"),
        ("synthetic", "synthetic"), ("c", "c"), ("cpp", "cpp"), ("csharp", "csharp"), ("java", "java"),
        ("go", "go"), ("css", "css"), ("sql", "sql"), ("swift", "swift"), ("toml", "toml"), ("html", "html"),
        ("xml", "xml"), ("bash", "bash"), ("yaml", "yaml"), ("markdown", "markdown"),
        ("html", "htmlEmbedded"), ("markdown", "markdownEmbedded"),
        ("javascript", "jsx"), ("typescriptreact", "tsx"), ("typescriptreact", "jsx"),
    ]

    @Test(arguments: languages)
    func randomTextsAndTargetsSplitInvariantly(_ sample: (language: String, fragments: String)) throws {
        let scanner = try scanner(sample.language)
        var rng = SplitMix(state: 0x51_1CE_5EED)
        for trial in 0..<10 {
            let ns = randomText(fragments[sample.fragments]!, count: 700, rng: &rng) as NSString
            var targets = (0..<60).map { _ in Int.random(in: -3...(ns.length + 3), using: &rng) }
            targets += [0, ns.length]
            if checkStops(scanner, ns, targets: targets, label: "\(sample.language) trial \(trial)") > 0 { break }

            // From a later line start, with the single pass's state there.
            let lineBreak = ns.range(of: "\n", options: [], range: NSRange(location: ns.length / 3, length: ns.length - ns.length / 3))
            guard lineBreak.location != NSNotFound else { continue }
            let from = NSMaxRange(lineBreak)
            var state = LexicalScanState()
            scanner.advance(ns, from: 0, to: from, state: &state)
            let later = (0..<20).map { _ in Int.random(in: from...ns.length, using: &rng) }
            if checkStops(scanner, ns, from: from, initial: state, targets: later,
                          label: "\(sample.language) trial \(trial) from \(from)") > 0 { break }
        }
    }

    /// Every target position in texts built around the constructs a split
    /// must not cut.
    static let adversarial: [(language: String, text: String)] = [
        ("rust", "let a = br\"x\\y\"; let b = b'x'; let c = r##\"a\"#b\"##; /* o /* i */ o */ let d = '\\u{1F600}';\r\n"
            + "let e = x😀y + abc_def; let f = \"q\\\"r\" + c\"z\" + 'a + '\\''; // tail 😀\r\nr#\"open\n\"#"),
        ("javascript", "a = `t${b + `c${d}e`}f` + \"x\\\"y\" + 'z' /* c * / */ + q😀w + abc_def;\r\n"
            + "`multi\r\n${ {k: \"}\"} }\r\nline` // done\n/* open\r\n*/ x"),
        ("typescript", "let t = `a${`b${`c`}`}d`; /* x */ \"\\\\\" + `\\${no}` + 'it\\'s'"),
        ("json", "{\"key\\\"x\": [1.5, -2e3, \"v😀\", true, null], \"k2\" : \"a\\\\\"}\r\n[\"\\u00e9\", {}]"),
        // An escaped surrogate pair is one escaped character.
        ("json", "[\"a\\😀\\\"b\", \"\\😀\", 1]"),
        ("javascript", "x = /a\\/b[/\"]c/gi; y = a / b / c; return /'/.test(s) || f(x) / 2 /* c */ / 3;\r\n"
            + "z = [/`/, x ? /\"/ : /$/]; i++ / 2 / x; } /x/\n/re/u.exec(t) // end"),
        ("cpp", "auto a = u8R\"x(raw )\" x)x\" + L'\\'' + u8\"s\\\"\" + 1'000'000 + U'a'; /* c\r\n*/ R\"(z)\"\n"
            + "#include <map> // tail 😀"),
        ("csharp", "var s = $\"a{b + $\"{c}\"}d{{e\" + @\"x\"\"y\" + $@\"{p}\\q\r\nr\" + $$\"\"\"{{v}}{w}\"\"\" + '\"';\n"
            + "\"\"\"\"raw \"\"\" more\"\"\"\" + \"\"; // 😀"),
        ("swift", "let a = #\"x\\(no)\\#(yes)\"# + \"q\\(f(\"in\"))r\" + ##\"\"\"\r\nm\\##(z)\"\"\"## /* a /* b */ c */ x😀"),
        ("sql", "SELECT 'it''s\r\nmulti' AS \"a\"\"b\", `c` -- note 'x\n/* block\n*/ FROM t"),
        ("xml", "<a b=\"c\"><![CDATA[ x ]] <!-- ]]> <!-- c\r\n --> <d/>😀 &amp;"),
        ("toml", "a = \"\"\"x\\\r\ny\"\"\" # c\nb = '''z'''\n\"k\" = 'v' # \"q\""),
        // Line blocks: targets inside `<<-EOF`, on terminator / closer lines,
        // in fence marker runs and block-scalar indentation, between CR and LF.
        ("bash", "cat <<-EOF | grep \"x\" # c\r\n\t\tbody $x\r\n\tEOF\r\necho $# ${#x} a#b <<< 'w'\n"
            + "cat <<'Q' \"$(echo \")\")\"\nq 😀\nQ x\nQ\r\ncat <<\\E\nE"),
        ("yaml", "a: |-\r\n  body # x\r\n\r\n  more\r\nb: 'it''s'\n- |\n  item\n- k: >+ # c\n    deep\n  o: \"q\\\"\r\n"
            + "  r\" # c\nd: don't \"x\"\n  | x\n?  |2\n   z"),
        ("markdown", "````js\r\nbody <!-- x\r\n```\r\n  ````  \r\ntext `c` <!-- a\r\n--> b\n~~~\n~~~~\n``` a`b\n"
            + "    ```\n   ~~~\n😀\n   ~~~ \r\nend"),
        // T17.7: long escapes (complete, cut short, next to quotes and
        // surrogate pairs) and Bash variables inside double quotes.
        ("javascript", "s = \"\\x41\\x4g\\u0041\\u00\\u{1F600}\\u{\\012\\0\\q\\😀\" + `a\\u{41}${b}\\x` + '\\\\'"),
        ("cpp", "s = \"\\xABCDEF0123 \\U0001F600\\U0001 \\u20AC\\377\\8\" + L'\\x41' + u8\"\\\"\";"),
        ("rust", "let s = \"\\x7f\\x7\\u{10FFFF}\\u{_1}\\u{\" + r\"\\x41\" + b'\\x7f';"),
        ("swift", "let s = \"\\u{1F600}\\u{\" + #\"\\u{41}\\#u{41}\\#n\"# + \"\\(x)\\t\""),
        ("bash", "echo \"$x$1$@$$${y}$(z)$\" '$q' \"\\$a $abc_1\""),
        ("yaml", "a: 'it''s ''x'''\nb: \"\\x41\\u00e9\\U0001F600\\q\""),
        // T17.8a: targets inside start and end tags (a multi-line start tag
        // with `>` in a quoted value), in bodies, at a closing tag inside a
        // JS string, and around fence openers, info strings and closers.
        ("html", "<p a=\"<b>\">x</p><SCRIPT\r\n type='module' data-x=\"a > b\">let s = \"</scRipt >\"; t`${u}`"
            + "</script>\r\n<style type=text/css>.a{b:\"}\"}/* </style */</style><script type=\"text/x\">a<b</script/>"
            + "<!-- <script> --><script>😀`x\r\n</script"),
        ("markdown", "```python {x}\r\ns = '''\r\n```\r\nt = \"😀\"\n~~~ts\n`a${b}\n~~~\n```json\n{\"k\": 1}\n````"
            + "\n```markdown\n```py\nx\n```\n```\n```js\nlet a = 1 /* open"),
        // T17.8b: targets inside JSX openers, names, strings, expressions,
        // fragments and comments in tags; TSX type parameters and arguments.
        ("javascript", "x = <a b=\"c>{\" c='d\r\ne'{...p} f={`g${h}`}/>;<>t<b/>{/*c*/}</>\r\n"
            + "y = <A.B\r\n // l\r\n /* m */ c>😀<i>{a < b ? <j/> : 'k'}</i></A.B> < z; r = /<a>/;"),
        ("typescriptreact", "f = <T,>(x: T) => <X<Y<Z>, () => void> a=\"1\">t</X>; g = <T extends U>() => 1;"
            + "\r\nh = <const T,>() => <T>t</T>; i = <T = V>() => j<K>(l); k = <svg:rect/>"),
        ("synthetic", "x = R\"d(a)\"b)d\" + R\"(z)\" + rb##\"q\"#r\"## + #\"a\\(b)c\\#(d)e\"# + \"p\\(f(1))q\"\r\n"
            + "''' a '' b '''' c ''' + ''''x'''' + b'x' + '\\u{1F600}' + F`a${b}c{d}{{e` + %a%%b%\r"
            + "/* a /* b */ c */ (* d /* e *) f😀g // end\nabc_def"),
    ]

    @Test(arguments: adversarial)
    func everyTargetInAdversarialTexts(_ sample: (language: String, text: String)) throws {
        let scanner = try scanner(sample.language)
        let ns = sample.text as NSString
        checkStops(scanner, ns, targets: Array(0...ns.length), label: sample.language)
        // And from every line start, in the single pass's state.
        var loc = 0
        while loc < ns.length {
            let next = NSMaxRange(ns.lineRange(for: NSRange(location: loc, length: 0)))
            if next >= ns.length { break }
            var state = LexicalScanState()
            scanner.advance(ns, from: 0, to: next, state: &state)
            checkStops(scanner, ns, from: next, initial: state, targets: Array(next...ns.length),
                       label: "\(sample.language) from \(next)")
            loc = next
        }
    }

    @Test func stopsAtTheFirstFriendlyPointAndNeverInsideConstructs() throws {
        let rust = try scanner("rust")
        let ns = "ab br\"x\" cd" as NSString
        var state = LexicalScanState()
        // Inside the identifier `ab` → not after it either (`b` is a string
        // prefix unit), so after the space; before the prefix `br` → stays.
        #expect(rust.advance(ns, from: 0, to: ns.length, stoppingAtSafePointFrom: 1, state: &state) == 3)
        state = LexicalScanState()
        #expect(rust.advance(ns, from: 0, to: ns.length, stoppingAtSafePointFrom: 3, state: &state) == 3)
        // Inside `br"` the opener is consumed first; content is friendly.
        state = LexicalScanState()
        #expect(rust.advance(ns, from: 0, to: ns.length, stoppingAtSafePointFrom: 4, state: &state) == 6)
        #expect(state.frames.count == 1)
        // An escape takes a whole surrogate pair: the string still closes.
        let json = try scanner("json")
        let escaped = "\"\\😀\" x" as NSString
        var segments: [(NSRange, LexicalSegment)] = []
        state = LexicalScanState()
        json.segments(escaped, from: 0, to: escaped.length, state: &state) { segments.append(($0, $1)) }
        #expect(state.isEmpty)
        // T17.7: the escape (with the whole pair) is its own segment.
        #expect(segments.map(\.0) == [NSRange(location: 0, length: 1), NSRange(location: 1, length: 3),
                                       NSRange(location: 4, length: 1), NSRange(location: 5, length: 2)])
        #expect(segments.map(\.1) == [.string, .escape, .string, .code])
        // A target at or past `to` stops at `to`.
        state = LexicalScanState()
        #expect(rust.advance(ns, from: 0, to: ns.length, stoppingAtSafePointFrom: 99, state: &state) == ns.length)
        #expect(state.isEmpty)
    }
}

// MARK: - Band bounds

@Suite("LongLineSlicingBounds")
struct LongLineSlicingBoundsTests {
    /// The definition `bandBounds` implements, through `lineRange`.
    private func reference(_ raw: NSRange, _ ns: NSString, _ threshold: Int) -> HighlightEngine.BandBounds {
        guard ns.length > 0 else { return .init(start: 0, startMidLine: false, end: 0, endMidLine: false) }
        func isHigh(_ u: unichar) -> Bool { (0xD800...0xDBFF).contains(u) }
        let s = min(max(raw.location, 0), ns.length - 1)
        let lineStart = ns.lineRange(for: NSRange(location: s, length: 0)).location
        var start = lineStart, startMid = false
        if s - lineStart > threshold {
            start = s; startMid = true
            if start > 0, isHigh(ns.character(at: start - 1)) { start -= 1 }
        }
        let rawEnd = min(max(raw.location + raw.length, 0), ns.length)
        let lineEnd = NSMaxRange(ns.lineRange(for: NSRange(location: min(rawEnd, ns.length - 1), length: 0)))
        var end = lineEnd, endMid = false
        if lineEnd - rawEnd > threshold {
            end = rawEnd; endMid = true
            if end > 0, end < ns.length, isHigh(ns.character(at: end - 1)) { end += 1 }
        }
        return .init(start: start, startMidLine: startMid, end: max(start, end), endMidLine: endMid)
    }

    @Test func shortLinesAreExactlyWholeLines() {
        var rng = SplitMix(state: 0xB0_0D5)
        let pieces = ["abc", " ", "\n", "\r\n", "\r", "😀", "x", "\n\n", "\u{2028}", "\u{2029}", "\u{85}"]
        for _ in 0..<60 {
            let ns = randomText(pieces, count: Int.random(in: 0...80, using: &rng), rng: &rng) as NSString
            for _ in 0..<40 {
                let location = Int.random(in: -2...(ns.length + 2), using: &rng)
                let raw = NSRange(location: location, length: Int.random(in: 0...20, using: &rng))
                let bounds = HighlightEngine.bandBounds(raw: raw, in: ns, threshold: LanguageDefinition.longLineThreshold)
                #expect(bounds.range == HighlightEngine.wholeLineRange(clamping: raw, in: ns), "\(raw) in \((ns as String).debugDescription)")
                #expect(!bounds.startMidLine && !bounds.endMidLine)
            }
        }
    }

    @Test func longLinesStayMidLineAndMatchTheDefinition() {
        var rng = SplitMix(state: 0x10_4C)
        let pieces = ["abcdefgh", " ", "\n", "\r\n", "\r", "😀", "x", "\u{2028}"]
        for threshold in [0, 1, 3, 7, 20] {
            for _ in 0..<60 {
                let ns = randomText(pieces, count: Int.random(in: 1...40, using: &rng), rng: &rng) as NSString
                for _ in 0..<30 {
                    let location = Int.random(in: -2...(ns.length + 2), using: &rng)
                    let raw = NSRange(location: location, length: Int.random(in: 0...12, using: &rng))
                    let bounds = HighlightEngine.bandBounds(raw: raw, in: ns, threshold: threshold)
                    #expect(bounds == reference(raw, ns, threshold),
                            "threshold \(threshold), raw \(raw), text \((ns as String).debugDescription)")
                }
            }
        }
    }

    @Test func documentBoundaries() {
        let threshold = 4
        let empty = HighlightEngine.bandBounds(raw: NSRange(location: 3, length: 9), in: "" as NSString, threshold: threshold)
        #expect(empty == .init(start: 0, startMidLine: false, end: 0, endMidLine: false))
        let long = "0123456789abcdefghij" as NSString            // one 20-unit line, no terminator
        // Start of document: the line start is 0 → whole-line start.
        var b = HighlightEngine.bandBounds(raw: NSRange(location: -5, length: 7), in: long, threshold: threshold)
        #expect(b == .init(start: 0, startMidLine: false, end: 2, endMidLine: true))
        // End of document: the line end is the document end.
        b = HighlightEngine.bandBounds(raw: NSRange(location: 14, length: 50), in: long, threshold: threshold)
        #expect(b == .init(start: 14, startMidLine: true, end: 20, endMidLine: false))
        // Middle: both edges mid-line.
        b = HighlightEngine.bandBounds(raw: NSRange(location: 8, length: 3), in: long, threshold: threshold)
        #expect(b == .init(start: 8, startMidLine: true, end: 11, endMidLine: true))
        // A surrogate pair is never cut.
        let emoji = "aaaaaaaa😀aaaaaaaa😀aaaaaaaa" as NSString
        b = HighlightEngine.bandBounds(raw: NSRange(location: 9, length: 10), in: emoji, threshold: threshold)
        #expect(b == .init(start: 8, startMidLine: true, end: 20, endMidLine: true))
        // Near both ends of a long line inside a document.
        let doc = "ab\n0123456789abcdefghij\ncd" as NSString
        b = HighlightEngine.bandBounds(raw: NSRange(location: 5, length: 16), in: doc, threshold: threshold)
        #expect(b == .init(start: 3, startMidLine: false, end: 24, endMidLine: false))
    }
}

// MARK: - Engine (real text view)

@MainActor
private func pump(_ seconds: TimeInterval) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

/// An engine and its document analysis on a windowed, wrapping text view,
/// wired like an editor window (analysis first on the hub). The analysis gets
/// a private scheduler, so the multi-megabyte declaration rescans after an
/// edit never queue ahead of other suites' jobs on the shared one.
@MainActor
private final class SlicePainter {
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
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        textView.layoutManager?.allowsNonContiguousLayout = true
        // No idle-time layout of the megabytes off screen: it would compete
        // for the main thread with other suites' timing-sensitive tests.
        textView.layoutManager?.backgroundLayoutEnabled = false
        scrollView.documentView = textView
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        textView.string = text
        let name = "LongLineSlicingTests-\(UUID().uuidString)"
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
        // A large document scans in slices (T17.15d-A); compare with names.
        engine.analysis.finishPendingDeclarationScanForTesting()
    }

    var ns: NSString { textView.textStorage!.mutableString }

    /// Scrolls `offset` into view and repaints. Layout and painting are
    /// separate main-actor turns, so neither holds the main thread long.
    func paint(at offset: Int) async {
        textView.scrollRangeToVisible(NSRange(location: offset, length: 0))
        await Task.yield()
        engine.appearanceDidChange()
        await Task.yield()
    }

    func replace(_ range: NSRange, with string: String) {
        guard textView.shouldChangeText(in: range, replacementString: string) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: string)
        textView.didChangeText()
    }

    func colours(in range: NSRange) -> [ObjectIdentifier?] {
        let lm = textView.layoutManager!
        var out: [ObjectIdentifier?] = []
        out.reserveCapacity(range.length)
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

    func runsOutsideBand() -> Int {
        let length = ns.length
        guard let band = engine.paintedRange else { return runs(in: NSRange(location: 0, length: length)) }
        return runs(in: NSRange(location: 0, length: band.location))
            + runs(in: NSRange(location: NSMaxRange(band), length: length - NSMaxRange(band)))
    }
}

/// The colours one full single pass of `tokens` over the whole text gives,
/// per unit of a requested range — with the identifier pass the engine adds
/// (T17.7: JS colours every identifier; no declarations here, so no roles
/// and no table).
private struct FullPass: @unchecked Sendable {
    let tokens: [(range: NSRange, kind: TokenKind)]

    init(_ def: LanguageDefinition, _ ns: NSString) {
        var state = LexicalScanState()
        let whole = NSRange(location: 0, length: ns.length)
        var ruleTokens = def.tokens(in: ns, range: whole, state: &state)
        let identifiers = HighlightEngine.identifierTokens(in: ns, range: whole, tokens: &ruleTokens, roles: [],
                                                           table: nil, policy: def.identifierPolicy)
        tokens = (ruleTokens + identifiers).sorted { $0.range.location < $1.range.location }
    }

    /// Computed off the main actor, so the heavy reference pass does not hold
    /// up the other suites' main-actor work.
    static func detached(_ language: String, _ text: String) async -> FullPass {
        await Task.detached {
            FullPass(LanguageRegistry.definition(forIdentifier: language)!, text as NSString)
        }.value
    }

    func colours(in range: NSRange) -> [ObjectIdentifier?] {
        let theme = HighlightTheme()
        var out = [ObjectIdentifier?](repeating: nil, count: range.length)
        var low = 0, high = tokens.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(tokens[mid].range) <= range.location { low = mid + 1 } else { high = mid }
        }
        var index = low
        while index < tokens.count, tokens[index].range.location < NSMaxRange(range) {
            let piece = NSIntersectionRange(tokens[index].range, range)
            if piece.length > 0, let colour = theme.color(for: tokens[index].kind) {
                for i in piece.location..<NSMaxRange(piece) { out[i - range.location] = ObjectIdentifier(colour) }
            }
            index += 1
        }
        return out
    }
}

/// Minified JSON on one line. Escaped quotes only in the first half: they
/// re-pair the quotes after an inserted `"`, so without them a quote typed
/// in the middle flips every string up to the line end.
private func minifiedJSON(units: Int) -> String {
    var json = "["
    var i = 0
    while json.utf16.count < units {
        if i > 0 { json += "," }
        let name = json.utf16.count < units / 2 ? #"item-\#(i) \"q\""# : "item-\(i) q"
        json += #"{"id":\#(i),"name":"\#(name)","tags":["a","b"],"price":\#(i % 97).5,"ok":true,"note":null,"e":-1.25e-3}"#
        i += 1
    }
    return json + "]"
}

/// One line of JS with templates, nested `${…}`, block comments (one holding
/// a backtick), strings with escapes and numbers — and no declarations, so
/// the in-document symbol pass adds no colour.
private func minifiedJS(units: Int) -> String {
    var js = ""
    var i = 0
    while js.utf16.count < units {
        js += #"a\#(i % 7) = `t ${b + \#(i)} and ${`n ${c[\#(i % 5)]} /* not */`} end`; "#
        js += #"/* block ` comment \#(i) */ d = "dq \"x\" " + 'sq\'s' + 0x1F + 1.5e3 - .5; "#
        js += #"if (a) { b = [1, 2, 3]; } else { c = { k: "v}" }; } "#
        i += 1
    }
    return js
}

// MARK: - Band tokens (pure)

@Suite("LongLineSlicingBand")
struct LongLineSlicingBandTests {
    /// The pure band path at many random mid-line edges: the slice's tokens
    /// equal the full pass's, clipped — rule tokens crossing an edge (`1.5`,
    /// `-1.25e-3`, `0x1F`, keywords) keep their extent and kind, and a key cut
    /// by the end edge stays a key.
    @Test(arguments: ["json", "javascript"])
    func randomMidLineSlicesMatchAFullPass(_ language: String) throws {
        let def = try #require(LanguageRegistry.definition(forIdentifier: language))
        let text = language == "json" ? minifiedJSON(units: 40_000) : minifiedJS(units: 40_000)
        let ns = text as NSString
        let full = FullPass(def, ns)
        var rng = SplitMix(state: 0x5_11CE)
        var store = CheckpointStore()
        let threshold = LanguageDefinition.longLineThreshold
        for trial in 0..<150 {
            let start = Int.random(in: (threshold + 1)...(ns.length - threshold - 5_001), using: &rng)
            let end = start + Int.random(in: 1...5_000, using: &rng)
            let bounds = HighlightEngine.BandBounds(start: start, startMidLine: true, end: end, endMidLine: true)
            if trial % 3 == 0 { store = CheckpointStore() }
            let band = HighlightEngine.bandTokens(in: ns, bounds: bounds, language: def, checkpoints: &store)
            #expect(band.painted.location >= start && NSMaxRange(band.painted) >= end, "trial \(trial): \(band.painted)")
            #expect(band.tokens.allSatisfy { NSIntersectionRange($0.range, band.painted) == $0.range })
            var mine = [ObjectIdentifier?](repeating: nil, count: band.painted.length)
            // T17.7: plus the identifier pass the engine runs over the band.
            var ruleTokens = band.tokens
            let identifiers = HighlightEngine.identifierTokens(in: ns, range: band.painted, tokens: &ruleTokens,
                                                               roles: [], table: nil, policy: def.identifierPolicy)
            for token in ruleTokens + identifiers {
                guard let colour = HighlightTheme().color(for: token.kind) else { continue }
                for i in token.range.location..<NSMaxRange(token.range) {
                    mine[i - band.painted.location] = ObjectIdentifier(colour)
                }
            }
            let expected = full.colours(in: band.painted)
            let diff = zip(mine, expected).enumerated().first { $0.element.0 != $0.element.1 }?.offset
            #expect(diff == nil, "trial \(trial): bounds \(start)..<\(end), painted \(band.painted), differs at \(band.painted.location + (diff ?? 0))")
            if diff != nil { break }
        }
    }
}

@Suite("LongLineSlicingEngine", .serialized)
@MainActor
struct LongLineSlicingEngineTests {
    init() { _ = NSApplication.shared }

    private static let bandLimit = 65_536

    /// The painted band is bounded and equals the full pass inside it.
    @discardableResult
    private func expectBandMatches(_ painter: SlicePainter, _ full: FullPass, _ label: String,
                                   sourceLocation: SourceLocation = #_sourceLocation) -> [ObjectIdentifier?] {
        guard let band = painter.engine.paintedRange, band.length > 0 else {
            Issue.record("\(label): nothing painted", sourceLocation: sourceLocation)
            return []
        }
        #expect(band.length <= Self.bandLimit, "\(label): band \(band)", sourceLocation: sourceLocation)
        #expect((painter.engine.colouredRange?.length ?? 0) <= Self.bandLimit,
                "\(label): coloured \(String(describing: painter.engine.colouredRange))", sourceLocation: sourceLocation)
        #expect(painter.runsOutsideBand() == 0, "\(label): colour outside the band", sourceLocation: sourceLocation)
        let mine = painter.colours(in: band)
        let expected = full.colours(in: band)
        let diff = zip(mine, expected).enumerated().first { $0.element.0 != $0.element.1 }?.offset
        #expect(diff == nil, "\(label): colours differ at \(band.location + (diff ?? 0)) in band \(band)",
                sourceLocation: sourceLocation)
        return mine
    }

    private func colour(_ kind: TokenKind) -> ObjectIdentifier? {
        HighlightTheme().color(for: kind).map { ObjectIdentifier($0) }
    }

    @Test func minifiedJSONIsPaintedInSlicesThatMatchAFullPass() async throws {
        let text = minifiedJSON(units: 2 * 1024 * 1024)
        let painter = SlicePainter(text: text, language: "json")
        let ns = painter.ns
        let def = JSONLanguage.make()
        var full = await FullPass.detached("json", text)

        let top = expectBandMatches(painter, full, "after setLanguage")
        #expect(top.contains(colour(.jsonKey)) && top.contains(colour(.string)) && top.contains(colour(.number)))
        for (label, offset) in [("quarter", ns.length / 4), ("middle", ns.length / 2), ("end", ns.length - 1)] {
            await painter.paint(at: offset)
            let band = try #require(painter.engine.paintedRange)
            #expect(NSLocationInRange(offset, band), "\(label): \(offset) not in \(band)")
            let colours = expectBandMatches(painter, full, label)
            #expect(colours.contains(colour(.jsonKey)), "\(label): no key coloured as a JSON key")
        }
        // Checkpoints inside the line (the only line start is 0).
        let checkpoints = painter.engine.analysis.checkpoints.entries
        #expect(checkpoints.count >= 10 && checkpoints.allSatisfy { $0.offset > 0 })

        // An edit in the middle (a quote flips every string after it), then a
        // repaint further on equals a fresh full pass over the edited text.
        let editAt = ns.length / 2 + 7
        let probe = NSRange(location: ns.length * 3 / 4, length: 2_000)
        await painter.paint(at: probe.location)
        let before = painter.colours(in: probe)
        let stale = painter.engine.analysis.checkpoints
        #expect(stale.entries.contains { $0.offset > editAt && $0.offset < probe.location })
        painter.replace(NSRange(location: editAt, length: 0), with: "\"")
        // T17.15d-A: in-line checkpoints more than `editMargin` before the
        // edit stay; those after it wait as pending entries (their states
        // flipped with the quote, so the walk below re-scans past them).
        let survivors = painter.engine.analysis.checkpoints
        #expect(!survivors.entries.isEmpty)
        #expect(survivors.entries.allSatisfy { $0.offset < editAt - CheckpointStore.editMargin })
        #expect(survivors.pending.allSatisfy { $0.offset > editAt + CheckpointStore.editMargin })
        await pump(0.3)
        full = await FullPass.detached("json", painter.textView.string)
        await painter.paint(at: probe.location + 1)
        let band = try #require(painter.engine.paintedRange)
        expectBandMatches(painter, full, "after edit")
        let after = painter.colours(in: NSRange(location: probe.location + 1, length: probe.length))
        #expect(after != before, "the edit did not change the colours downstream")
        // Resuming from the un-invalidated checkpoints would paint it wrong.
        // From `probe` (not the painted band's start, which varies with the
        // background catch-up's timing): a stale checkpoint after the edit
        // lies before it (asserted above), so the stale walk starts in the
        // flipped state.
        var staleStore = stale
        let bounds = HighlightEngine.BandBounds(start: probe.location, startMidLine: true,
                                                end: max(NSMaxRange(band), NSMaxRange(probe)), endMidLine: true)
        let fromStale = HighlightEngine.bandTokens(in: painter.ns, bounds: bounds, language: def,
                                                   checkpoints: &staleStore)
        var freshStore = CheckpointStore()
        let fromFresh = HighlightEngine.bandTokens(in: painter.ns, bounds: bounds, language: def,
                                                   checkpoints: &freshStore)
        #expect(fromStale.tokens.map(\.range) != fromFresh.tokens.map(\.range)
                || fromStale.tokens.map(\.kind) != fromFresh.tokens.map(\.kind),
                "stale checkpoints happen to give the right answer")
    }

    @Test func minifiedJavaScriptIsPaintedInSlicesThatMatchAFullPass() async throws {
        // Short lines first, so a line-start checkpoint survives the edit
        // while the long line's in-line checkpoints are dropped.
        let prefix = String(repeating: "x = 1; // short line\n", count: 4_000)
        let text = prefix + minifiedJS(units: 1024 * 1024)
        let painter = SlicePainter(text: text, language: "javascript")
        let ns = painter.ns
        let lineStart = (prefix as NSString).length
        var full = await FullPass.detached("javascript", text)
        #expect(painter.engine.analysis.declarations?.scan.table.isEmpty ?? true)

        expectBandMatches(painter, full, "after setLanguage")
        for (label, offset) in [("middle", lineStart + (ns.length - lineStart) / 2), ("end", ns.length - 1)] {
            await painter.paint(at: offset)
            let band = try #require(painter.engine.paintedRange)
            #expect(NSLocationInRange(offset, band), "\(label): \(offset) not in \(band)")
            let colours = expectBandMatches(painter, full, label)
            #expect(colours.contains(colour(.comment)) && colours.contains(colour(.string))
                    && colours.contains(colour(.interpolationDelimiter)) && colours.contains(colour(.escape)),
                    "\(label): band lacks comment / string / ${ / escape colour")
        }
        let checkpoints = painter.engine.analysis.checkpoints.entries
        #expect(checkpoints.contains { $0.offset < lineStart })
        #expect(checkpoints.filter { $0.offset > lineStart }.count >= 10)

        // A backtick typed in code in the middle of the long line opens a
        // template (the next backticks re-pair, so the change is local).
        let middle = lineStart + (ns.length - lineStart) / 2
        let anchor = ns.range(of: "; if (a)", options: [], range: NSRange(location: middle, length: 2_000))
        #expect(anchor.location != NSNotFound)
        let editAt = anchor.location + 2
        let near = NSRange(location: editAt, length: 400)
        let far = lineStart + (ns.length - lineStart) * 4 / 5
        await painter.paint(at: editAt)
        let before = painter.colours(in: near)
        #expect(painter.engine.analysis.checkpoints.entries.contains { $0.offset > lineStart && $0.offset < editAt })
        painter.replace(NSRange(location: editAt, length: 0), with: "`")
        let kept = painter.engine.analysis.checkpoints.entries
        // T17.15d-A: the long line's in-line checkpoints more than
        // `editMargin` before the edit stay (the exact edited range, not the
        // paragraph `didProcessEditing` reports).
        #expect(!kept.isEmpty && kept.allSatisfy { $0.offset < editAt - CheckpointStore.editMargin })
        #expect(kept.contains { $0.offset > lineStart })
        await pump(0.3)
        full = await FullPass.detached("javascript", painter.textView.string)
        await painter.paint(at: editAt)
        expectBandMatches(painter, full, "after edit (near)")
        let after = painter.colours(in: NSRange(location: editAt + 1, length: near.length))
        #expect(after != before, "the edit did not change the colours after it")
        await painter.paint(at: far)
        expectBandMatches(painter, full, "after edit (far)")

        // Undo restores the original colours.
        let undo = try #require(painter.textView.undoManager)
        undo.undo()
        #expect(painter.textView.string == text)
        await pump(0.3)
        await painter.paint(at: editAt)
        #expect(painter.colours(in: near) == before)
    }

    /// Python (own tokenizer) and an unprofiled language: a long line is
    /// coloured only in the band's slice, by stateless rules.
    @Test func unprofiledLongLinesArePaintedInSlices() async throws {
        for (language, unit) in [("python", "x = 'a' + 12 # c "), ("go", "x := \"a\" + 12 /* c */ ")] {
            let line = String(repeating: unit, count: 600_000 / unit.utf16.count)
            let painter = SlicePainter(text: "a = 1\n" + line + "\nb = 2\n", language: language)
            for offset in [0, painter.ns.length / 2, painter.ns.length - 1] {
                await painter.paint(at: offset)
                let band = try #require(painter.engine.paintedRange)
                #expect(band.length <= Self.bandLimit && NSLocationInRange(offset, band), "\(language): band \(band)")
                #expect(painter.runs(in: band) > 0, "\(language): nothing painted at \(offset)")
                #expect(painter.runsOutsideBand() == 0)
            }
        }
    }
}
