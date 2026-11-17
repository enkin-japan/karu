import AppKit
import Foundation
import Testing
@testable import KaruCore

// M17 T17.7 — syntax categories by position and the Dark / Light Modern
// palette (plan §6): palette values for every kind, escapes per language
// family, control keywords, the constants rule, declaration-position roles,
// the bold heading emphasis, and the rule-loop / seek-point machinery the
// pass relies on.

private func t177Defaults() -> UserDefaults {
    let name = "SyntaxCategoryTests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

/// `(text, kind)` of every token of `text` (rule tokens and profile
/// segments; no identifier pass).
private func tokens(_ language: String, _ text: String) -> [(text: String, kind: TokenKind)] {
    let def = LanguageRegistry.definition(forIdentifier: language)!
    let ns = text as NSString
    let list: [(range: NSRange, kind: TokenKind)]
    if language == "python" || def.lexicalScanner == nil {
        list = text.components(separatedBy: "\n").reduce(into: (offset: 0, out: [(range: NSRange, kind: TokenKind)]())) { acc, line in
            for t in def.tokenize(line: line) {
                acc.out.append((NSRange(location: acc.offset + t.range.location, length: t.range.length), t.kind))
            }
            acc.offset += (line as NSString).length + 1
        }.out
    } else {
        var state = LexicalScanState()
        list = def.tokens(in: ns, range: NSRange(location: 0, length: ns.length), state: &state)
    }
    return list.map { (ns.substring(with: $0.range), $0.kind) }
}

private func kinds(_ language: String, _ text: String, of piece: String) -> [TokenKind] {
    tokens(language, text).filter { $0.text == piece }.map(\.kind)
}

// MARK: - Palette

@Suite("SyntaxPalette")
@MainActor
struct SyntaxPaletteTests {
    /// Plan §6 and VS Code 1.146.0 `dark_modern.json` / `light_modern.json`
    /// (through `dark_plus` → `dark_vs`, `light_plus` → `light_vs`).
    static let expected: [TokenKind: (dark: UInt32, light: UInt32)?] = [
        .keyword: (0x569CD6, 0x0000FF),
        .controlKeyword: (0xC586C0, 0xAF00DB),
        .builtin: (0xDCDCAA, 0x795E26),
        .string: (0xCE9178, 0xA31515),
        .number: (0xB5CEA8, 0x098658),
        .comment: (0x6A9955, 0x008000),
        .type: (0x4EC9B0, 0x267F99),
        .property: (0x9CDCFE, 0x001080),
        .jsonKey: (0x9CDCFE, 0x0451A5),
        .cssProperty: (0x9CDCFE, 0xE50000),
        .punctuation: (0xD4D4D4, 0x000000),
        .symbolFunction: (0xDCDCAA, 0x795E26),
        .symbolVariable: (0x9CDCFE, 0x001080),
        .parameter: (0x9CDCFE, 0x001080),
        .constant: (0x4FC1FF, 0x0070C1),
        .escape: (0xD7BA7D, 0xEE0000),
        .regex: (0xD16969, 0x811F3F),
        .interpolationDelimiter: (0x569CD6, 0x0000FF),
        .tagName: (0x569CD6, 0x800000),
        .tagPunctuation: (0x808080, 0x800000),
        .attributeName: (0x9CDCFE, 0xE50000),
        .heading: (0x569CD6, 0x800000),
        .markupValue: (0xCE9178, 0x0000FF),
        .plain: nil,
    ]

    @Test func everyKindHasThePlanColourInBothAppearances() {
        #expect(Set(Self.expected.keys) == Set(TokenKind.allCases))
        for kind in TokenKind.allCases {
            let actual = HighlightTheme.hex(for: kind)
            let want = Self.expected[kind] ?? nil
            #expect(actual?.dark == want?.dark && actual?.light == want?.light, "\(kind)")
        }
    }

    /// The dynamic colours resolve to those values under each appearance.
    @Test func dynamicColoursResolvePerAppearance() {
        let theme = HighlightTheme()
        func hex(_ color: NSColor, _ name: NSAppearance.Name) -> UInt32 {
            var resolved: NSColor?
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) }
            let c = resolved!
            func byte(_ v: CGFloat) -> UInt32 { UInt32(max(0, min(255, (v * 255).rounded()))) }
            return byte(c.redComponent) << 16 | byte(c.greenComponent) << 8 | byte(c.blueComponent)
        }
        for kind in TokenKind.allCases {
            guard let pair = HighlightTheme.hex(for: kind) else {
                #expect(theme.color(for: kind) == nil)
                continue
            }
            let color = theme.color(for: kind)!
            #expect(hex(color, .darkAqua) == pair.dark, "\(kind) dark")
            #expect(hex(color, .aqua) == pair.light, "\(kind) light")
        }
    }

    /// T17.15d: JSON keys and CSS property names take Light Modern's
    /// `support.type.property-name(.json)` colours; Dark Modern keeps the
    /// variable blue for them, and the other `.property` producers
    /// (Markdown list markers, TOML keys, YAML quoted keys) keep theirs.
    @Test func jsonKeysAndCSSPropertiesHaveTheirLightModernColours() {
        // Light: JSON key #0451A5, CSS property #E50000; dark unchanged.
        #expect(HighlightTheme.hex(for: .jsonKey)?.light == 0x0451A5)
        #expect(HighlightTheme.hex(for: .cssProperty)?.light == 0xE50000)
        for kind in [TokenKind.jsonKey, .cssProperty, .property] {
            #expect(HighlightTheme.hex(for: kind)?.dark == 0x9CDCFE, "\(kind)")
        }
        #expect(HighlightTheme.hex(for: .property)?.light == 0x001080)

        // Which kind each language gives these names.
        #expect(kinds("json", #"{"name": "x"}"#, of: #""name""#) == [.jsonKey])
        #expect(kinds("json", #"{"name": "x"}"#, of: #""x""#) == [.string])
        #expect(kinds("jsonl", #"{"k": 1}"#, of: #""k""#) == [.jsonKey])
        #expect(kinds("css", "a { color: red; }", of: "color") == [.cssProperty])
        #expect(kinds("markdown", "- item", of: "- ") == [.property])
        #expect(kinds("markdown", "1. next", of: "1. ") == [.property])
        #expect(kinds("toml", "name = \"Karu\"", of: "name") == [.property])
        #expect(kinds("toml", "\"quoted\" = 1", of: "\"quoted\"") == [.property])
        #expect(kinds("yaml", "\"quoted key\": 1", of: "\"quoted key\"") == [.property])

        // The colours those tokens resolve to, per appearance.
        let theme = HighlightTheme()
        func hex(_ kind: TokenKind, _ name: NSAppearance.Name) -> UInt32? {
            guard let color = theme.color(for: kind) else { return nil }
            var resolved: NSColor?
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) }
            guard let c = resolved else { return nil }
            func byte(_ v: CGFloat) -> UInt32 { UInt32(max(0, min(255, (v * 255).rounded()))) }
            return byte(c.redComponent) << 16 | byte(c.greenComponent) << 8 | byte(c.blueComponent)
        }
        #expect(hex(.jsonKey, .aqua) == 0x0451A5)
        #expect(hex(.cssProperty, .aqua) == 0xE50000)
        #expect(hex(.property, .aqua) == 0x001080)
        for kind in [TokenKind.jsonKey, .cssProperty, .property] {
            #expect(hex(kind, .darkAqua) == 0x9CDCFE, "\(kind) dark")
        }
        // Dark Modern: still the variable colour object family (same pair as before).
        #expect(theme.color(for: .property) === theme.color(for: .symbolVariable))
    }

    @Test func onlyHeadingsAreBold() {
        #expect(TokenKind.allCases.filter(HighlightTheme.isBold) == [.heading])
        #expect(HighlightTheme.emphasisStrokeWidth < 0)
    }
}

// MARK: - Escapes

/// The kind covering each unit of `piece` (its first occurrence) in `text`.
private func unitKinds(_ language: String, _ text: String, _ piece: String) -> [TokenKind?] {
    let def = LanguageRegistry.definition(forIdentifier: language)!
    let ns = text as NSString
    var list: [(range: NSRange, kind: TokenKind)] = []
    if language == "python" {
        var state = PythonTokenizer.State()
        list = PythonTokenizer.scan(text, language: def, state: &state)
    } else {
        var state = LexicalScanState()
        list = def.tokens(in: ns, range: NSRange(location: 0, length: ns.length), state: &state)
    }
    let r = ns.range(of: piece)
    precondition(r.location != NSNotFound, "\(piece) not in \(text)")
    return (r.location..<NSMaxRange(r)).map { i in list.first { NSLocationInRange(i, $0.range) }?.kind }
}

/// `piece` is entirely an escape.
private func isEscape(_ language: String, _ text: String, _ piece: String) -> Bool {
    unitKinds(language, text, piece).allSatisfy { $0 == .escape }
}

/// No unit of `piece` is an escape.
private func hasNoEscape(_ language: String, _ text: String, _ piece: String) -> Bool {
    unitKinds(language, text, piece).allSatisfy { $0 != .escape }
}

@Suite("SyntaxEscapes")
struct SyntaxEscapeTests {
    @Test func javascriptFamilyLongForms() {
        let text = #"s = "a \x41 \u0041 \u{1F600} \012 \q \x4g";"#
        for escape in [#"\x41"#, #"\u0041"#, #"\u{1F600}"#, #"\012"#, #"\q"#] {
            #expect(isEscape("javascript", text, escape), "\(escape)")
            #expect(isEscape("typescript", text, escape), "\(escape)")
        }
        // An incomplete form falls back to the one-unit escape.
        #expect(unitKinds("javascript", text, #"\x4g"#) == [.escape, .escape, .string, .string])
        #expect(unitKinds("typescript", #"s = `\u{ x`;"#, #"\u{ "#) == [.escape, .escape, .string, .string])
        // Template literal escapes.
        #expect(isEscape("javascript", #"t = `a \n ${b}`"#, #"\n"#))
    }

    @Test func cFamilyLongForms() {
        for language in ["c", "cpp"] {
            let text = #"char *s = "\xABCDEF12 \U0001F600 \u20AC \377 \q";"#
            for escape in [#"\xABCDEF12"#, #"\U0001F600"#, #"\u20AC"#, #"\377"#, #"\q"#] {
                #expect(isEscape(language, text, escape), "\(language) \(escape)")
            }
        }
        // C++ raw strings have no escapes.
        #expect(hasNoEscape("cpp", #"auto r = R"(a\nb)";"#, #"R"(a\nb)""#))
    }

    @Test func javaGoAndCSharp() {
        #expect(isEscape("java", #"String s = "x \u0041 \101";"#, #"\u0041"#))
        #expect(isEscape("java", #"String s = "x \u0041 \101";"#, #"\101"#))
        for escape in [#"\x41"#, #"\u0041"#, #"\U0001F600"#, #"\101"#] {
            #expect(isEscape("go", #"s := "\x41 \u0041 \U0001F600 \101""#, escape), "\(escape)")
        }
        // Go raw strings have none.
        #expect(hasNoEscape("go", #"s := `a\n`"#, #"`a\n`"#))
        #expect(isEscape("csharp", #"var s = "\x41 \u0041";"#, #"\x41"#))
        #expect(isEscape("csharp", #"var s = "\x41 \u0041";"#, #"\u0041"#))
        // A verbatim string's `""` is an escape, as VS Code colours it (decision L).
        #expect(isEscape("csharp", #"var p = @"C:\dir\""q"";"#, "\"\""))
    }

    @Test func rustAndSwift() {
        for escape in [#"\x7f"#, #"\u{1F600}"#, #"\n"#] {
            #expect(isEscape("rust", #"let s = "\x7f \u{1F600} \n";"#, escape), "\(escape)")
        }
        // Raw strings have none.
        #expect(hasNoEscape("rust", ##"let r = r#"a\n\x41"#;"##, ##"r#"a\n\x41"#"##))
        #expect(hasNoEscape("rust", #"let r = br"a\n";"#, #"br"a\n""#))
        #expect(isEscape("swift", #"let s = "\u{1F600} \t""#, #"\u{1F600}"#))
        // In `#"…"#` only `\#` escapes.
        #expect(hasNoEscape("swift", ##"let s = #"\n \#n"#"##, #"\n "#))
        #expect(isEscape("swift", ##"let s = #"\n \#n"#"##, ##"\#n"##))
    }

    @Test func pythonNonRawRawAndBytes() {
        let text = #"s = "\n \x41 \N{DASH} \u00e9 \101 \q""#
        for escape in [#"\n"#, #"\x41"#, #"\N{DASH}"#, #"\u00e9"#, #"\101"#] {
            #expect(isEscape("python", text, escape), "\(escape)")
        }
        #expect(hasNoEscape("python", text, #"\q"#))                       // not a Python escape
        // Bytes have no `\u`.
        #expect(hasNoEscape("python", #"b = b"\u0041 \x41""#, #"\u0041"#))
        #expect(isEscape("python", #"b = b"\u0041 \x41""#, #"\x41"#))
        // `R"…"` and `rf"…"` are plain raw strings: no escapes.
        #expect(hasNoEscape("python", #"r = R"\n\x41""#, #"R"\n\x41""#))
        #expect(hasNoEscape("python", #"r = rf"\n{x}""#, #"\n"#))
        // A lowercase-`r` string is a regular expression: the prefix a
        // keyword, class escapes regex, other escapes escapes.
        let regex = #"p = r"\d \. \t""#
        #expect(unitKinds("python", regex, "r\"") == [.keyword, .regex])
        #expect(unitKinds("python", regex, #"\d"#) == [.regex, .regex])
        #expect(isEscape("python", regex, #"\."#))
        #expect(isEscape("python", regex, #"\t"#))
        // f-string: `{{` is an escape, `{` / `}` delimiters.
        #expect(isEscape("python", #"s = f"{{x}} {y}""#, "{{"))
        #expect(unitKinds("python", #"s = f"{{x}} {y}""#, "{y}") == [.interpolationDelimiter, nil, .interpolationDelimiter])
    }

    @Test func markupAndDataFormats() {
        #expect(isEscape("css", #"a { content: "\201C"; }"#, #"\201C"#))
        #expect(isEscape("json", #"{"k": "x \u00e9"}"#, #"\u00e9"#))
        #expect(isEscape("toml", #"k = "x \u00e9""#, #"\u00e9"#))
        // YAML: a doubled `''` in single quotes is an escape (VS Code).
        #expect(isEscape("yaml", "a: 'it''s'", "''"))
        #expect(isEscape("yaml", #"a: "q\"r""#, #"\""#))
        // Bash: `$'…'` escapes, `'…'` none; `$x` in double quotes a variable.
        #expect(isEscape("bash", #"a=$'t\t' b='x\ty'"#, #"\t"#))
        #expect(hasNoEscape("bash", #"a=$'t\t' b='x\ty'"#, #"'x\ty'"#))
        let quoted = #"echo "a $x ${y} $1" '$z'"#
        #expect(unitKinds("bash", quoted, "$x") == [.symbolVariable, .symbolVariable])
        #expect(unitKinds("bash", quoted, "$1") == [.symbolVariable, .symbolVariable])
        #expect(unitKinds("bash", quoted, "'$z'").allSatisfy { $0 == .string })
    }
}

// MARK: - Control keywords

@Suite("SyntaxControlKeywords")
struct SyntaxControlKeywordTests {
    /// Per language: words that must be control keywords and words that
    /// must stay (non-control) keywords, as VS Code's grammars scope them.
    static let samples: [(language: String, text: String, control: [String], other: [String])] = [
        ("javascript", "import a from 'b'; export default function f() { if (x) return; for (const y of z) {} }",
         ["import", "from", "export", "default", "if", "return", "for"], ["function", "const", "of"]),
        ("typescript", "export type T = A as B; while (x) { try { throw e } catch { break } }",
         ["export", "as", "while", "try", "throw", "catch", "break"], ["type"]),
        ("python", "from a import b\nfor x in y:\n    if x: continue\n    else: raise E\nwith o as p: pass\n",
         ["from", "import", "for", "in", "if", "continue", "else", "raise", "with", "as", "pass"], []),
        ("python", "def f(self, cls): return lambda: None\n", ["return"], ["def", "lambda", "None"]),
        ("c", "int f(void) { switch (x) { case 1: goto out; default: break; } while (y) continue; return 0; }",
         ["switch", "case", "goto", "default", "break", "while", "continue", "return"], ["int", "void"]),
        ("cpp", "void f() { try { throw new X(); } catch (...) { delete p; } using T = int; }",
         ["try", "throw", "new", "catch", "delete", "using"], ["void", "int"]),
        ("csharp", "using System; foreach (var x in xs) { yield return x; }",
         ["using", "foreach", "in", "yield", "return"], ["var"]),
        ("java", "for (int i = 0;;) { if (x) return new Y(); }", ["for", "if", "return", "new"], []),
        ("go", "import \"fmt\"\nfunc f() { defer g(); go h(); for range xs { return } }\n",
         ["import", "defer", "go", "for", "range", "return"], ["func"]),
        ("rust", "fn f() { for x in xs { match x { _ => return } } loop { break } }",
         ["for", "match", "return", "loop", "break"], ["fn", "in"]),
        ("swift", "import Foundation\nfunc f() { guard x else { return }; for y in z { switch y { default: break } } }\n",
         ["import", "guard", "else", "return", "for", "in", "switch", "default", "break"], ["func"]),
        ("bash", "if [ x ]; then for a in b; do echo; done; fi\ncase x in *) ;; esac\n",
         ["if", "then", "for", "in", "do", "done", "fi", "case", "esac"], []),
    ]

    @Test(arguments: samples.indices)
    func controlKeywordsPerLanguage(_ index: Int) {
        let sample = Self.samples[index]
        let t = tokens(sample.language, sample.text)
        for word in sample.control {
            #expect(t.contains { $0.text == word && $0.kind == .controlKeyword }, "\(sample.language): \(word)")
        }
        for word in sample.other {
            #expect(t.contains { $0.text == word && $0.kind == .keyword }, "\(sample.language): \(word) not keyword")
            #expect(!t.contains { $0.text == word && $0.kind == .controlKeyword }, "\(sample.language): \(word)")
        }
    }

    /// Python's soft keywords are control keywords only at a statement start.
    @Test func pythonSoftKeywords() {
        // One line at a time, as the engine scans Python.
        #expect(!unitKinds("python", "match = re.match(p, s)", "match =").contains(.controlKeyword))
        #expect(!unitKinds("python", "match = re.match(p, s)", "match(").contains(.controlKeyword))
        #expect(unitKinds("python", "match cmd:", "match").allSatisfy { $0 == .controlKeyword })
        #expect(unitKinds("python", "    case [x]: pass", "case").allSatisfy { $0 == .controlKeyword })
    }
}

// MARK: - Constants

@Suite("SyntaxConstants")
struct SyntaxConstantTests {
    @Test func upperSnakeIsAConstantInJavaScriptAndTypeScript() {
        for language in ["javascript", "typescript"] {
            let t = tokens(language, "x = MAX_SIZE + A1 + HTTPServer + T + _ + __ + R2D2_ + $X_Y + a.MAX")
            func kind(_ word: String) -> TokenKind? { t.first { $0.text == word }?.kind }
            #expect(kind("MAX_SIZE") == .constant, "\(language)")
            #expect(kind("A1") == .constant)
            #expect(kind("R2D2_") == .constant)
            // Mixed case, single letters and letterless names are not.
            #expect(kind("HTTPServer") != .constant)
            #expect(kind("T") != .constant)
            #expect(kind("__") != .constant)
            #expect(kind("$X_Y") != .constant)
        }
    }

    /// VS Code does not colour all-caps names in these grammars.
    @Test func noUpperSnakeConstantsElsewhere() {
        for (language, text) in [("python", "x = MAX_SIZE\n"), ("c", "x = MAX_SIZE;"), ("java", "x = MAX_SIZE;"),
                                 ("csharp", "x = MAX_SIZE;"), ("go", "x := MAX_SIZE"), ("swift", "let x = MAX_SIZE"),
                                 ("cpp", "x = MAX_SIZE;"), ("rust", "let x = MAX_SIZE;")] {
            #expect(!tokens(language, text).contains { $0.kind == .constant }, "\(language)")
        }
    }

    /// Every declaration of `text` with its `const` flag, read through the
    /// ranged iterator over the whole text.
    private func constFlags(_ language: String, _ text: String) -> [(name: String, constant: Bool)] {
        let scan = DeclarationScan.scan(text: text, languageIdentifier: language)
        var out: [(name: String, constant: Bool)] = []
        scan.forEachDeclaration(from: 0, to: Int.max) { _, name, _, constant in out.append((name, constant)) }
        return out
    }

    private func flag(_ flags: [(name: String, constant: Bool)], _ name: String) -> Bool? {
        flags.first { $0.name == name }?.constant
    }

    /// The JS / TS walker flags every binding of a `const` declaration
    /// (LEDGER VH4): all declarators, destructuring, `for (const …)`,
    /// `export const`, `declare const`; never `let` / `var` / `using`, nor a
    /// `const f = () =>` function or a `const enum`.
    @Test func javascriptConstDeclarationsAreFlaggedByTheWalker() {
        for language in ["javascript", "typescript"] {
            let text = """
            const a = 1, b = 2;
            const c = 1,
                d = 2;
            const /* note */ value = 1;
            const {x, y: w} = o, z = 3;
            const [p, ...rest] = xs;
            for (const j of xs) {}
            export const exported = 1;
            let l = 1, m = 2;
            var v = 1;
            using u = r;
            const f = () => 1;
            """
            let flags = constFlags(language, text)
            for name in ["a", "b", "c", "d", "value", "x", "w", "z", "p", "rest", "j", "exported"] {
                #expect(flag(flags, name) == true, "\(language): \(name)")
            }
            for name in ["l", "m", "v", "u", "f"] {
                #expect(flag(flags, name) == false, "\(language): \(name)")
            }
            // `y` is a key, not a binding.
            #expect(flag(flags, "y") == nil)
        }
        let ts = constFlags("typescript", """
            const a: number = 1, b: string = "x";
            declare const g: number;
            const enum E { K }
            let h: number = 1;
            """)
        #expect(flag(ts, "a") == true)
        #expect(flag(ts, "b") == true)
        #expect(flag(ts, "g") == true)
        #expect(flag(ts, "E") == false)
        #expect(flag(ts, "h") == false)
    }

    /// Go: `const` names (single-line and grouped) are flagged, `var` names
    /// are not; no other brace language flags anything.
    @Test func goConstDeclarationsAreFlaggedByTheWalker() {
        let go = constFlags("go", """
            package main

            const a = 1
            const b, c = 1, 2
            const (
            	A = iota
            	B
            	C
            	D int = 4
            )
            var x = 1
            var (
            	y = 2
            	z int
            )
            func f() {
            	const k = 1
            	var n = 2
            }
            """)
        for name in ["a", "b", "c", "A", "B", "C", "D", "k"] { #expect(flag(go, name) == true, "\(name)") }
        for name in ["x", "y", "z", "n", "f"] { #expect(flag(go, name) == false, "\(name)") }
        for (language, text) in [("rust", "const A: i32 = 1;\nstatic B: i32 = 2;\nfn f() { let c = 1; }\n"),
                                 ("c", "const int a = 1;\nint f(void) { const int b = 2; return b; }\n"),
                                 ("cpp", "const int a = 1;\nconstexpr int b = 2;\n"),
                                 ("csharp", "class K { const int A = 1; }\n"),
                                 ("java", "class K { static final int A = 1; }\n"),
                                 ("swift", "let a = 1\nvar b = 2\n")] {
            let scan = DeclarationScan.scan(text: text, languageIdentifier: language)
            #expect(scan.constantBits.isEmpty, "\(language)")
        }
    }

    /// A scan without any `const` declaration stores no flag bytes.
    @Test func noConstDeclarationsNoFlagBytes() {
        let python = DeclarationScan.scan(text: "def f(a):\n    b = a\n    return b\n", languageIdentifier: "python")
        #expect(!python.declarations.isEmpty)
        #expect(python.constantBits.isEmpty)
        let js = DeclarationScan.scan(text: "let a = 1, b = 2;\nvar c = 3;\nfunction f(d) { let e = d; }\n",
                                      languageIdentifier: "javascript")
        #expect(js.declarations.count >= 5)
        #expect(js.constantBits.isEmpty)
        // One flagged declaration: bytes only up to its ordinal.
        let one = DeclarationScan.scan(text: "let a = 1;\nconst b = 2;\nlet c = 3, d = 4;\n",
                                       languageIdentifier: "javascript")
        #expect(one.constantBits == [0b10])
        // The regex reference path flags nothing.
        let legacy = DeclarationScan.regexScan("const a = 1;\n" as NSString, languageIdentifier: "javascript")
        #expect(legacy.constantBits.isEmpty)
    }

    /// The ranged iterator derives each declaration's ordinal from the seek
    /// point it starts at (seek `k` precedes ordinal `(k + 1) * seekStride`):
    /// alternating `const` / `let` lines across several seek boundaries,
    /// every range start agrees with the full decode.
    @Test func constFlagsThroughSeekPoints() {
        var text = ""
        for i in 0..<150 { text += (i % 2 == 0 ? "const" : "let") + " n\(i) = \(i);\n" }
        let scan = DeclarationScan.scan(text: text, languageIdentifier: "javascript")
        let all = scan.declarations
        #expect(all.count == 150)
        #expect(scan.declarationSeeks.count == 4)   // before ordinals 64 and 128
        // Ordinal n is `n<n>`, constant when n is even.
        for (ordinal, declaration) in all.enumerated() { #expect(declaration.name == "n\(ordinal)") }
        let ns = text as NSString
        func lineStart(_ i: Int) -> Int { ns.range(of: "n\(i) =").location }
        for first in [0, 1, 62, 63, 64, 65, 66, 126, 127, 128, 129, 130, 149] {
            for to in [lineStart(first) + 1, lineStart(min(149, first + 3)) + 1, ns.length] {
                var got: [(String, Bool)] = []
                scan.forEachDeclaration(from: lineStart(first), to: to) { _, name, _, constant in
                    got.append((name, constant))
                }
                #expect(!got.isEmpty)
                for (offset, entry) in got.enumerated() {
                    let ordinal = first + offset
                    #expect(entry.0 == "n\(ordinal)" && entry.1 == (ordinal % 2 == 0), "from \(first): \(entry)")
                }
            }
        }
        // The three-argument iterator is unchanged.
        var names: [String] = []
        scan.forEachDeclaration(from: lineStart(64), to: lineStart(66)) { _, name, _ in names.append(name) }
        #expect(names == ["n64", "n65"])
    }
}

// MARK: - Position roles (engine)

@Suite("SyntaxPositionRoles", .serialized)
@MainActor
struct SyntaxPositionRoleTests {
    @MainActor
    final class Painter {
        let center = NotificationCenter()
        let scrollView: NSScrollView
        let textView: EditorTextView
        let hub = TextStorageObserverHub()
        let engine: HighlightEngine

        init(_ text: String, language: String) {
            let frame = NSRect(x: 0, y: 0, width: 700, height: 500)
            scrollView = NSScrollView(frame: frame)
            textView = EditorTextView(frame: frame)
            textView.isVerticallyResizable = true
            textView.textContainer?.containerSize = NSSize(width: 700, height: CGFloat.greatestFiniteMagnitude)
            scrollView.documentView = textView
            textView.string = text
            engine = HighlightEngine(textView: textView, scrollView: scrollView,
                                     moduleSettings: ModuleSettings(defaults: t177Defaults(), center: center),
                                     moduleCenter: center)
            hub.add(engine)
            textView.textStorage?.delegate = hub
            engine.setLanguage(identifier: language)
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
            engine.appearanceDidChange()
        }

        var ns: NSString { textView.textStorage!.mutableString }

        func colour(at index: Int) -> NSColor? {
            textView.layoutManager!.temporaryAttribute(.foregroundColor, atCharacterIndex: index,
                                                       effectiveRange: nil) as? NSColor
        }

        /// The colour of the `occurrence`-th (1-based) `word`.
        func colour(of word: String, occurrence: Int = 1) -> NSColor? {
            var from = 0
            var hit = NSRange(location: NSNotFound, length: 0)
            for _ in 0..<occurrence {
                hit = ns.range(of: word, options: .literal, range: NSRange(location: from, length: ns.length - from))
                guard hit.location != NSNotFound else { return nil }
                from = NSMaxRange(hit)
            }
            return colour(at: hit.location)
        }

        /// The colour of the `occurrence`-th (1-based) `word` inside the
        /// first occurrence of `context`.
        func colour(of word: String, in context: String, occurrence: Int = 1) -> NSColor? {
            let outer = ns.range(of: context, options: .literal)
            guard outer.location != NSNotFound else { return nil }
            var from = outer.location
            var hit = NSRange(location: NSNotFound, length: 0)
            for _ in 0..<occurrence {
                hit = ns.range(of: word, options: .literal,
                               range: NSRange(location: from, length: NSMaxRange(outer) - from))
                guard hit.location != NSNotFound else { return nil }
                from = NSMaxRange(hit)
            }
            return colour(at: hit.location)
        }
    }

    private let theme = HighlightTheme()

    /// A parameter named like a file-level function takes the parameter
    /// colour at its declaration, and its references in that function the
    /// colour of any other parameter reference — the function's name does
    /// not reach them (C: the table's functions are used; LEDGER VH5).
    @Test func parameterNamedLikeAFunctionGetsTheParameterColourAtItsDeclaration() {
        let p = Painter("int total(int a) { return a; }\nint f(int total) { return total; }\n", language: "c")
        #expect(p.colour(of: "total", occurrence: 1) === theme.color(for: .symbolFunction))   // declaration
        #expect(p.colour(of: "total", occurrence: 2) === theme.color(for: .parameter))        // parameter
        #expect(theme.color(for: .parameter) !== theme.color(for: .symbolFunction))
        let plainReference = p.colour(of: "a;")                                               // `return a;`
        #expect(p.colour(of: "total", occurrence: 3) === plainReference)                      // shadowed
        #expect(p.colour(of: "total", occurrence: 3) !== theme.color(for: .symbolFunction))
    }

    // MARK: Function names yield to local bindings (LEDGER VH5)

    /// C: a parameter or local named like a function has the plain
    /// reference colour in its function; elsewhere the bare function name
    /// (a function pointer, a callback, `&total`) and every call keep the
    /// function colour.
    @Test func cFunctionNamesYieldToLocalBindings() {
        let p = Painter("""
            int total(int a) { return a; }
            int f(int total) { return total + total(1); }
            int g(void) { int total = 4; return total; }
            int (*handler)(int) = total;
            void k(void) { register_cb(total); fp = &total; }

            """, language: "c")
        let function = theme.color(for: .symbolFunction)
        let plain = p.colour(of: "a", in: "return a;")
        #expect(plain !== function)
        #expect(p.colour(of: "total", in: "return total +") === plain)                  // parameter
        #expect(p.colour(of: "total", in: "total(1)") === function)                     // call
        #expect(p.colour(of: "total", in: "int total = 4; return total;", occurrence: 2) === plain)   // local
        #expect(p.colour(of: "total", in: "= total;") === function)                     // function pointer
        #expect(p.colour(of: "total", in: "register_cb(total)") === function)           // callback
        #expect(p.colour(of: "total", in: "&total") === function)
    }

    /// C++: the same, and a member named like a free function in its own
    /// type's methods.
    @Test func cppFunctionNamesYieldToLocalBindings() {
        let p = Painter("""
            int total(int a) { return a; }
            int size() { return 0; }
            struct Box { int size; int get() const { return size; } };
            int f(int total) { return total + total(1); }
            int g() { int total = 4; return total; }
            void k() { auto fp = &total; run(total); auto sp = size; }

            """, language: "cpp")
        let function = theme.color(for: .symbolFunction)
        let plain = p.colour(of: "a", in: "return a;")
        #expect(plain !== function)
        #expect(p.colour(of: "total", in: "return total +") === plain)
        #expect(p.colour(of: "total", in: "total(1)") === function)
        #expect(p.colour(of: "total", in: "int total = 4; return total;", occurrence: 2) === plain)
        #expect(p.colour(of: "size", in: "return size; }") === plain)                   // member
        #expect(p.colour(of: "total", in: "&total") === function)
        #expect(p.colour(of: "total", in: "run(total)") === function)
        #expect(p.colour(of: "size", in: "sp = size") === function)
    }

    /// Java: a method is no value — a bare name is never a function (a
    /// field, a parameter, a local named like a method), a method
    /// reference (`this::size`, `Cases::size`) and a call always are.
    @Test func javaBareMethodNamesAreNotFunctions() {
        let p = Painter("""
            class Cases {
                private int size;
                int size() { return size; }
                void grow() { size = size + 1; int other = 1; other++; }
                int shadow(int count) { int total = count; return total; }
                int count() { return 1; }
                int total() { return 2; }
                void use() { run(this::size); run(Cases::size); int n = size(); }
                void run(java.util.function.IntSupplier s) { }
            }

            """, language: "java")
        let function = theme.color(for: .symbolFunction)
        let plain = p.colour(of: "other", in: "other++")
        #expect(plain !== function)
        #expect(p.colour(of: "size", in: "return size;") === plain)                     // field
        #expect(p.colour(of: "size", in: "size = size", occurrence: 1) === plain)
        #expect(p.colour(of: "size", in: "size = size", occurrence: 2) === plain)
        #expect(p.colour(of: "count", in: "= count;") === plain)                        // parameter
        #expect(p.colour(of: "total", in: "return total; }") === plain)                 // local
        #expect(p.colour(of: "size", in: "this::size") === function)                    // method references
        #expect(p.colour(of: "size", in: "Cases::size") === function)
        #expect(p.colour(of: "size", in: "size()") === function)                        // call
    }

    /// C#: a method group (`list.ForEach(Print)`, `Func<…> f = Total`)
    /// keeps the function colour where no binding hides it.
    @Test func csharpFunctionNamesYieldToLocalBindings() {
        let p = Painter("""
            class Cases {
                int Total(int a) { return a; }
                int Shadow(int Total) { return Total + 1; }
                int Local() { var Total = 2; return Total; }
                void Use(System.Collections.Generic.List<int> list) { list.ForEach(Print); System.Func<int, int> f = Total; }
                void Print(int s) { }
                int Calls(int Total) { return this.Total(Total); }
            }

            """, language: "csharp")
        let function = theme.color(for: .symbolFunction)
        let plain = p.colour(of: "a", in: "return a;")
        #expect(plain !== function)
        #expect(p.colour(of: "Total", in: "return Total + 1") === plain)                // parameter
        #expect(p.colour(of: "Total", in: "return Total; }") === plain)                 // local
        #expect(p.colour(of: "Print", in: "ForEach(Print)") === function)               // method group
        #expect(p.colour(of: "Total", in: "f = Total") === function)
        #expect(p.colour(of: "Total", in: "this.Total(Total)", occurrence: 1) === function)   // call
        #expect(p.colour(of: "Total", in: "this.Total(Total)", occurrence: 2) === plain)
    }

    /// Swift: parameters, locals, closure parameters and properties hide a
    /// function's name; calls (also through a property of function type),
    /// `#selector(name)`, trailing-closure calls and unshadowed function
    /// values keep the function colour.
    @Test func swiftFunctionNamesYieldToLocalBindings() {
        let p = Painter("""
            struct Box {
                var callback: () -> Void = {}
                func run() { callback(); let other = 1; _ = other; let c = callback; _ = c }
            }
            func callback() {}
            func code(_ x: Int) -> Int { x }
            func format(code: Int) -> Int { return code + 1 }
            func local() -> Int { let code = 2; return code }
            func pass() { apply(code); each { } }
            func closure() { _ = [1].map { code in code + 1 } }
            func calls(code: Int) -> Int { return code(code) }
            @objc func tap() {}
            func wire() { button.action = #selector(tap) }
            func each(_ body: () -> Void) {}

            """, language: "swift")
        let function = theme.color(for: .symbolFunction)
        let plain = p.colour(of: "other", in: "_ = other")
        #expect(plain !== function)
        #expect(p.colour(of: "callback", in: "callback();") === function)               // call through the property
        #expect(p.colour(of: "callback", in: "c = callback") === plain)                 // the property
        #expect(p.colour(of: "code", in: "return code + 1") === plain)                  // parameter
        #expect(p.colour(of: "code", in: "return code }") === plain)                    // local
        #expect(p.colour(of: "code", in: "code in code + 1", occurrence: 2) === plain)  // closure parameter
        #expect(p.colour(of: "code", in: "apply(code)") === function)                   // function value
        #expect(p.colour(of: "each", in: "each { }") === function)                      // trailing closure
        #expect(p.colour(of: "tap", in: "#selector(tap)") === function)
        #expect(p.colour(of: "code", in: "code(code)", occurrence: 1) === function)     // call
        #expect(p.colour(of: "code", in: "code(code)", occurrence: 2) === plain)
    }

    /// Go: a parameter or local (`:=`) hides the function; `f := handler`
    /// and `register(handler)` elsewhere keep the function colour.
    @Test func goFunctionNamesYieldToLocalBindings() {
        let p = Painter("""
            package cases

            func handler(w int) {}
            func shadow(handler int) int { other := 1; return handler + other }
            func local() int { handler := 2; return handler }
            func value() func(int) { f := handler; register(handler); return f }
            func register(fn func(int)) {}
            func calls() { handler(1) }

            """, language: "go")
        let function = theme.color(for: .symbolFunction)
        let plain = p.colour(of: "other", in: "+ other")
        #expect(plain !== function)
        #expect(p.colour(of: "handler", in: "return handler +") === plain)              // parameter
        #expect(p.colour(of: "handler", in: "return handler }") === plain)              // local
        #expect(p.colour(of: "handler", in: "f := handler") === function)
        #expect(p.colour(of: "handler", in: "register(handler)") === function)
        #expect(p.colour(of: "handler", in: "handler(1)") === function)                 // call
    }

    /// Before the rescan, the shadowing check reads the published snapshot
    /// through the edit journal; an unmappable journal falls back to the
    /// function colour without failing.
    @Test func shadowingFollowsEditsBeforeTheRescan() {
        let p = Painter("int total(int a) { return a; }\nint f(int total) { return total; }\n"
                        + "int g(void) { return total; }\n", language: "c")
        let function = theme.color(for: .symbolFunction)
        #expect(p.colour(of: "total", in: "{ return total; }\nint g") !== function)
        p.textView.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 0), with: "/* x */\n")
        #expect(p.engine.analysis.declarations == nil)
        #expect(p.engine.analysis.publishedDeclarations?.journal.isEmpty == false)
        p.engine.appearanceDidChange()
        #expect(p.colour(of: "total", in: "{ return total; }\nint g") !== function)    // shadowed, mapped
        #expect(p.colour(of: "total", in: "int g(void) { return total;") === function)  // not shadowed
        // Past the journal's capacity: no mapping, the function colour stays.
        for _ in 0...EditJournal.capacity {
            p.textView.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 0), with: " ")
        }
        #expect(p.engine.analysis.publishedDeclarations?.journal.isUnmappable == true)
        p.engine.appearanceDidChange()
        #expect(p.colour(of: "total", in: "{ return total; }\nint g") === function)
        #expect(p.colour(of: "total", in: "int g(void) { return total;") === function)
    }

    /// Python colours declarations only (VS Code): `def` names, class names
    /// and parameters — also a parameter that shadows a function or a
    /// built-in — and no references.
    @Test func pythonDeclarationsOnly() {
        let p = Painter("def total():\n    pass\n\nclass Box:\n    def put(self, total, type):\n        return total\n",
                        language: "python")
        #expect(p.colour(of: "total", occurrence: 1) === theme.color(for: .symbolFunction))
        #expect(p.colour(of: "Box") === theme.color(for: .type))
        #expect(p.colour(of: "self") === theme.color(for: .parameter))       // over the keyword rule
        #expect(p.colour(of: "total", occurrence: 2) === theme.color(for: .parameter))
        #expect(p.colour(of: "type", occurrence: 1) === theme.color(for: .parameter))   // over the built-in rule
        #expect(p.colour(of: "total", occurrence: 3) == nil)                  // a reference
    }

    /// JS / TS: `const` bindings are constants at their declaration,
    /// `let` bindings variables; references are variables.
    @Test func javascriptConstBindings() {
        let p = Painter("const limit = 3; let count = 1;\nconst [a, b] = xs;\nconsole.log(limit, count);\n",
                        language: "javascript")
        #expect(p.colour(of: "limit") === theme.color(for: .constant))
        #expect(p.colour(of: "count") === theme.color(for: .symbolVariable))
        #expect(p.colour(of: "a,") === theme.color(for: .constant))
        #expect(p.colour(of: "b]") === theme.color(for: .constant))
        #expect(p.colour(of: "limit", occurrence: 2) === theme.color(for: .symbolVariable))
    }

    /// Every binding of a JS / TS `const` declaration takes the constant
    /// colour at its declaration, whatever lies between it and `const`
    /// (LEDGER VH4); `let` / `var` bindings and references do not change.
    @Test(arguments: ["javascript", "typescript"])
    func javascriptConstDeclaratorsAreConstants(_ language: String) {
        let typed = language == "typescript" ? "const ta: number = 1, tb: string = \"x\";\n" : ""
        let p = Painter("""
            const a = 1, b = 2;
            const c = 1,
                d = 2;
            \(typed)const {x, y: w} = o, z = 3;
            const [p, ...rest] = xs;
            const /* note */ value = 1;
            for (const j of xs) {}
            export const exported = 1;
            let l = 1, m = 2;
            var v = 1;
            use(b, z);

            """, language: language)
        let constant = theme.color(for: .constant)
        let variable = theme.color(for: .symbolVariable)
        #expect(constant !== variable)
        for word in ["a =", "b =", "c =", "d =", "x,", "w}", "z =", "p,", "rest]", "value", "j of", "exported"] {
            #expect(p.colour(of: word) === constant, "\(language): \(word)")
        }
        if !typed.isEmpty {
            #expect(p.colour(of: "ta:") === constant)
            #expect(p.colour(of: "tb:") === constant)
        }
        for word in ["l =", "m =", "v ="] {
            #expect(p.colour(of: word) === variable, "\(language): \(word)")
        }
        // References keep today's colour (variable).
        #expect(p.colour(of: "b,", occurrence: 1) === variable)
        #expect(p.colour(of: "z)") === variable)
    }

    /// Go: `const` names are constants at their declaration, single-line
    /// and grouped (typed entries too); `var` names stay variables.
    @Test func goConstDeclarationsAreConstants() {
        let p = Painter("""
            package main

            const a = 1
            const b, c = 1, 2
            const (
            	A = iota
            	B
            	C
            	D int = 4
            )
            var x = 1
            var (
            	y = 2
            )

            """, language: "go")
        let constant = theme.color(for: .constant)
        let variable = theme.color(for: .symbolVariable)
        for word in ["a =", "b,", "c =", "A =", "\tB\n", "\tC\n", "D int"] {
            let at = p.ns.range(of: word).location + (word.hasPrefix("\t") ? 1 : 0)
            #expect(p.colour(at: at) === constant, "\(word.debugDescription)")
        }
        #expect(p.colour(of: "x =") === variable)
        #expect(p.colour(of: "y =") === variable)
    }

    /// The flag follows the declaration across seek points: alternating
    /// `const` / `let` lines around ordinals 64 and 128.
    @Test func constColourAcrossSeekPoints() {
        var text = ""
        for i in 0..<150 { text += (i % 2 == 0 ? "const" : "let") + " n\(i) = \(i);\n" }
        let p = Painter(text, language: "javascript")
        let constant = theme.color(for: .constant)
        let variable = theme.color(for: .symbolVariable)
        for i in [0, 1, 62, 63, 64, 65, 66, 127, 128, 129, 130, 149] {
            let at = p.ns.range(of: " n\(i) =").location + 1
            p.textView.scrollRangeToVisible(NSRange(location: at, length: 0))
            p.engine.appearanceDidChange()
            #expect(p.colour(at: at) === (i % 2 == 0 ? constant : variable), "n\(i)")
        }
    }

    /// Roles are mapped through the edit journal before the rescan lands,
    /// and dropped where the text no longer reads the declared name.
    @Test func rolesFollowEditsBeforeTheRescan() {
        let p = Painter("int total(int a) { return a; }\nint f(int total) { return total; }\n", language: "c")
        #expect(p.colour(of: "total", occurrence: 2) === theme.color(for: .parameter))
        // Insert above, then repaint at once (the debounced rescan has not run).
        p.textView.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 0), with: "/* x */\n")
        #expect(p.engine.analysis.declarations == nil)
        #expect(p.engine.analysis.publishedDeclarations?.journal.isEmpty == false)
        p.engine.appearanceDidChange()
        #expect(p.colour(of: "total", occurrence: 2) === theme.color(for: .parameter))
        // Rename the parameter: its old role no longer applies there.
        let paramAt = p.ns.range(of: "total", options: [], range: NSRange(location: p.ns.range(of: "f(").location,
                                                                             length: 20)).location
        p.textView.textStorage?.replaceCharacters(in: NSRange(location: paramAt, length: 5), with: "tally")
        p.engine.appearanceDidChange()
        #expect(p.colour(at: paramAt) == nil)
    }

    /// A band repainted between an edit and its rescan (a scroll, or the
    /// view growing) has no colour for the names the edit declared; the
    /// rescan's snapshot repaints it (LEDGER VH1, 2026-11-17).
    @Test func bandPaintedBeforeTheRescanIsRepaintedByIt() async {
        let p = Painter("def f(count):\n    pass\n", language: "python")
        #expect(p.colour(at: 6) === theme.color(for: .parameter))
        p.textView.textStorage?.replaceCharacters(in: NSRange(location: 6, length: 5), with: "tally")
        p.engine.appearanceDidChange()
        #expect(p.colour(at: 6) == nil)
        #expect(p.engine.paintedRange != nil)
        let deadline = Date().addingTimeInterval(10)
        while p.engine.analysis.declarations == nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(p.engine.analysis.declarations != nil)
        #expect(p.colour(at: 6) === theme.color(for: .parameter))
    }
}

// MARK: - Heading emphasis

@Suite("SyntaxHeadingEmphasis", .serialized)
@MainActor
struct SyntaxHeadingEmphasisTests {
    /// The heading's fill-and-stroke emphasis is drawing-only: glyph
    /// positions, line fragments and caret rects are identical with and
    /// without it, and it does change the drawn pixels, in both appearances.
    @Test(arguments: [NSAppearance.Name.darkAqua, .aqua])
    func headingEmphasisKeepsLayoutAndIsDrawn(_ appearance: NSAppearance.Name) throws {
        let frame = NSRect(x: 0, y: 0, width: 420, height: 120)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        defer { window.close() }
        let scrollView = NSScrollView(frame: frame)
        let textView = EditorTextView(frame: frame)
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.isVerticallyResizable = true
        scrollView.documentView = textView
        window.contentView = scrollView
        let text = "# Heading Title\nbody text\n"
        textView.string = text
        let center = NotificationCenter()
        let engine = HighlightEngine(textView: textView, scrollView: scrollView,
                                     moduleSettings: ModuleSettings(defaults: t177Defaults(), center: center),
                                     moduleCenter: center)
        let lm = try #require(textView.layoutManager)
        let container = try #require(textView.textContainer)

        func metrics() -> [NSRect] {
            lm.ensureLayout(for: container)
            var out: [NSRect] = []
            for glyph in 0..<lm.numberOfGlyphs {
                let p = lm.location(forGlyphAt: glyph)
                out.append(NSRect(origin: p, size: .zero))
                out.append(lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil))
                out.append(lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container))
            }
            return out
        }
        func pixels() -> [UInt8] {
            textView.display()
            let rep = textView.bitmapImageRepForCachingDisplay(in: textView.bounds)!
            textView.cacheDisplay(in: textView.bounds, to: rep)
            return Array(UnsafeBufferPointer(start: rep.bitmapData, count: rep.bytesPerRow * rep.pixelsHigh))
        }

        let plainMetrics = metrics()
        engine.setLanguage(identifier: "markdown")
        engine.appearanceDidChange()
        let headingRange = NSRange(location: 0, length: 15)
        var effective = NSRange()
        let stroke = lm.temporaryAttribute(.strokeWidth, atCharacterIndex: 2, effectiveRange: &effective) as? CGFloat
        #expect(stroke == HighlightTheme.emphasisStrokeWidth)
        #expect(NSIntersectionRange(effective, headingRange) == headingRange)
        #expect(lm.temporaryAttribute(.strokeWidth, atCharacterIndex: 18, effectiveRange: nil) == nil)   // body
        let boldMetrics = metrics()
        let boldPixels = pixels()

        // Same colours without the stroke.
        lm.removeTemporaryAttribute(.strokeWidth, forCharacterRange: headingRange)
        lm.removeTemporaryAttribute(.strokeColor, forCharacterRange: headingRange)
        let colourOnlyMetrics = metrics()
        let colourOnlyPixels = pixels()

        #expect(boldMetrics == plainMetrics)
        #expect(colourOnlyMetrics == plainMetrics)
        #expect(boldPixels.count == colourOnlyPixels.count)
        let differing = zip(boldPixels, colourOnlyPixels).filter { $0 != $1 }.count
        #expect(differing > 50, "the emphasis stroke did not change the drawing (\(differing) bytes)")

        // Switching the module off removes the emphasis with the colour.
        engine.setLanguage(identifier: "markdown")
        engine.appearanceDidChange()
        #expect(lm.temporaryAttribute(.strokeWidth, atCharacterIndex: 2, effectiveRange: nil) != nil)
        engine.setLanguage(identifier: nil)
        #expect(lm.temporaryAttribute(.strokeWidth, atCharacterIndex: 2, effectiveRange: nil) == nil)
        #expect(lm.temporaryAttribute(.foregroundColor, atCharacterIndex: 2, effectiveRange: nil) == nil)
    }
}

// MARK: - Machinery

@Suite("SyntaxMachinery")
struct SyntaxMachineryTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The compiled rule set picks exactly what the rules in order would
    /// (first rule that matches at a position), over every highlight
    /// fixture.
    @Test func ruleSetMatchesTheRulesInOrder() throws {
        let dir = Self.root.appendingPathComponent("Tests/Fixtures/M17/highlight")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        var checked = 0
        for file in files.sorted() {
            let ext = (file as NSString).pathExtension
            guard let def = LanguageRegistry.definition(forExtension: ext) else { continue }
            let text = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
            let set = RuleSet(def.rules)
            for line in text.components(separatedBy: "\n") {
                let ns = line as NSString
                var location = 0
                while location < ns.length {
                    let range = NSRange(location: location, length: ns.length - location)
                    let sequential = def.rules.lazy.compactMap { rule -> (NSRange, TokenKind)? in
                        guard let m = rule.regex.firstMatch(in: line, options: [.anchored, .withTransparentBounds,
                                                                                 .withoutAnchoringBounds],
                                                            range: range), m.range.length > 0 else { return nil }
                        return (m.range, rule.kind)
                    }.first
                    let combined = set.match(in: line, range: range)
                    #expect(sequential?.0 == combined?.range && sequential?.1 == combined?.kind,
                            "\(file): \(line.debugDescription) at \(location)")
                    if sequential?.0 != combined?.range || sequential?.1 != combined?.kind { return }
                    location += max(1, sequential?.0.length ?? 1)
                    checked += 1
                }
            }
        }
        #expect(checked > 10_000)
    }

    /// Range iteration through the seek points equals filtering every
    /// declaration (a scan with several seek strides).
    @Test func declarationRangesThroughSeekPoints() throws {
        var source = ""
        for i in 0..<400 { source += "def f\(i)(a\(i), b\(i)):\n    c\(i) = a\(i)\n    return c\(i)\n" }
        let scan = DeclarationScan.scan(text: source, languageIdentifier: "python")
        let all = scan.declarations
        #expect(all.count > 4 * DeclarationScan.seekStride)
        #expect(scan.declarationSeeks.count >= 8)
        let length = (source as NSString).length
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let from = Int.random(in: 0...length, using: &rng)
            let to = from + Int.random(in: 0...3_000, using: &rng)
            var got: [(Int, String)] = []
            scan.forEachDeclaration(from: from, to: to) { location, name, _ in got.append((location, name)) }
            let want = all.filter { $0.location >= from && $0.location < to }.map { ($0.location, $0.name) }
            #expect(got.map(\.0) == want.map(\.0) && got.map(\.1) == want.map(\.1), "\(from)..<\(to)")
        }
    }

    /// No rule starts inside a word with another outcome, so skipping the
    /// rest of an unmatched word changes no token on the fixtures except
    /// digits inside identifiers (CSS `h1`), which VS Code does not colour.
    @Test func unmatchedWordsAreSkippedWhole() {
        let css = CSSLanguage.make()
        #expect(css.tokenize(line: "h1 { margin: 10px }").contains { $0.kind == .number })
        #expect(!css.tokenize(line: "h1 { }").contains { $0.kind == .number })
        let md = MarkdownLanguage.make()
        #expect(md.tokenize(line: "snake_case_word").isEmpty)
        #expect(md.tokenize(line: "an _italic_ word").contains { $0.kind == .controlKeyword })
    }
}
