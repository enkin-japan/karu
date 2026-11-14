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

    @Test func constDeclarationLookback() {
        let ns = "const a = 1; let b = 2; const [c, ...d] = e; const {f, g: h} = i; for (const j of k) {} var l"
            as NSString
        #expect(HighlightEngine.isConstDeclaration(at: ns.range(of: "a =").location, in: ns))
        #expect(!HighlightEngine.isConstDeclaration(at: ns.range(of: "b =").location, in: ns))
        #expect(HighlightEngine.isConstDeclaration(at: ns.range(of: "c,").location, in: ns))
        #expect(HighlightEngine.isConstDeclaration(at: ns.range(of: "d]").location, in: ns))
        #expect(HighlightEngine.isConstDeclaration(at: ns.range(of: "h}").location, in: ns))
        #expect(HighlightEngine.isConstDeclaration(at: ns.range(of: "j of").location, in: ns))
        #expect(!HighlightEngine.isConstDeclaration(at: ns.range(of: "l", options: .backwards).location, in: ns))
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
    }

    private let theme = HighlightTheme()

    /// A parameter named like a file-level function takes the parameter
    /// colour at its declaration, while the table still colours the other
    /// occurrences as the function (C: the table's functions are used).
    @Test func parameterNamedLikeAFunctionGetsTheParameterColourAtItsDeclaration() {
        let p = Painter("int total(int a) { return a; }\nint f(int total) { return total; }\n", language: "c")
        #expect(p.colour(of: "total", occurrence: 1) === theme.color(for: .symbolFunction))   // declaration
        #expect(p.colour(of: "total", occurrence: 2) === theme.color(for: .parameter))        // parameter
        #expect(theme.color(for: .parameter) !== theme.color(for: .symbolFunction))
        #expect(p.colour(of: "total", occurrence: 3) === theme.color(for: .symbolFunction))   // table
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
