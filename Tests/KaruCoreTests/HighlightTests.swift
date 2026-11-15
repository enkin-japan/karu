import AppKit
import Foundation
import Testing
@testable import KaruCore

// MARK: - Helpers

private func isolatedDefaults() -> UserDefaults {
    let name = "HighlightTests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

/// Tokenizes `line` and returns `(text, kind)` pairs for readable assertions.
private func spans(_ def: LanguageDefinition, _ line: String) -> [(text: String, kind: TokenKind)] {
    let ns = line as NSString
    return def.tokenize(line: line).map { (ns.substring(with: $0.range), $0.kind) }
}

/// Kind assigned to the first token whose text equals `text`, or nil.
private func kind(of text: String, in pairs: [(text: String, kind: TokenKind)]) -> TokenKind? {
    pairs.first { $0.text == text }?.kind
}

/// Tokenizes the whole of `source` exactly as `highlightVisibleRange` paints
/// a band (`HighlightEngine.bandTokens`: Python's carried state, a profiled
/// language's scanner state, or plain per-line rules) and returns the
/// `(text, kind)` spans of each line, clipped to the line's content (without
/// its terminator).
private func documentSpans(_ def: LanguageDefinition, _ source: String) -> [[(text: String, kind: TokenKind)]] {
    let ns = source as NSString
    var store = CheckpointStore()
    let tokens = HighlightEngine.bandTokens(in: ns, range: NSRange(location: 0, length: ns.length),
                                            language: def, checkpoints: &store)
    var lines: [[(text: String, kind: TokenKind)]] = []
    var loc = 0
    while loc < ns.length {
        var lineEnd = 0, contentsEnd = 0
        ns.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: loc, length: 0))
        let content = NSRange(location: loc, length: contentsEnd - loc)
        lines.append(tokens.compactMap { token in
            let clipped = NSIntersectionRange(token.range, content)
            return clipped.length > 0 ? (ns.substring(with: clipped), token.kind) : nil
        })
        loc = lineEnd
    }
    return lines
}

// MARK: - JSON tokenizer classification

@Test func jsonClassifiesKeysValuesNumbersLiteralsPunctuation() {
    let json = JSONLanguage.make()
    let pairs = spans(json, #"{"name": "x", "n": 1.5e2, "ok": true}"#)

    // Key strings (followed by a colon) are keys (T17.15d: `.jsonKey`); value strings are strings.
    #expect(kind(of: #""name""#, in: pairs) == .jsonKey)
    #expect(kind(of: #""n""#, in: pairs) == .jsonKey)
    #expect(kind(of: #""ok""#, in: pairs) == .jsonKey)
    #expect(kind(of: #""x""#, in: pairs) == .string)

    // Number, literal, punctuation.
    #expect(kind(of: "1.5e2", in: pairs) == .number)
    #expect(kind(of: "true", in: pairs) == .keyword)
    #expect(kind(of: "{", in: pairs) == .punctuation)
    #expect(kind(of: ":", in: pairs) == .punctuation)
    #expect(kind(of: ",", in: pairs) == .punctuation)
    #expect(kind(of: "}", in: pairs) == .punctuation)
}

@Test func jsonClassifiesNegativeAndFractionalNumbers() {
    let json = JSONLanguage.make()
    let pairs = spans(json, #"[-0.5, 42, 1E-3, false, null]"#)
    #expect(kind(of: "-0.5", in: pairs) == .number)
    #expect(kind(of: "42", in: pairs) == .number)
    #expect(kind(of: "1E-3", in: pairs) == .number)
    #expect(kind(of: "false", in: pairs) == .keyword)
    #expect(kind(of: "null", in: pairs) == .keyword)
    #expect(kind(of: "[", in: pairs) == .punctuation)
    #expect(kind(of: "]", in: pairs) == .punctuation)
}

@Test func jsonEscapedQuotesStayInsideStringToken() {
    let json = JSONLanguage.make()
    // A value string containing an escaped quote must be one token.
    let pairs = spans(json, #"{"k": "a\"b"}"#)
    #expect(kind(of: #""k""#, in: pairs) == .jsonKey)
    // T17.7: the escape is its own token inside the string (VS Code's
    // `constant.character.escape`); the string still ends after `b"`.
    #expect(kind(of: #""a"#, in: pairs) == .string)
    #expect(kind(of: #"\""#, in: pairs) == .escape)
    #expect(kind(of: #"b""#, in: pairs) == .string)
}

@Test func tokenizerLeavesWhitespaceUntokenized() {
    let json = JSONLanguage.make()
    let tokens = json.tokenize(line: "  {")
    // Leading spaces produce no token; only the brace is classified.
    #expect(tokens.count == 1)
    #expect(tokens.first?.kind == .punctuation)
    #expect(tokens.first?.range == NSRange(location: 2, length: 1))
}

// MARK: - Built-in identifier colouring (T10.2)

@Test func pythonBuiltinFunctionsAreColouredAsBuiltin() {
    let py = PythonLanguage.make()
    let pairs = spans(py, "print(len(items))")
    #expect(kind(of: "print", in: pairs) == .builtin)
    #expect(kind(of: "len", in: pairs) == .builtin)
    // A user identifier that is not a built-in stays untokenized (plain).
    #expect(kind(of: "items", in: pairs) == nil)
}

@Test func pythonBuiltinDoesNotOverrideKeywordOrSelf() {
    let py = PythonLanguage.make()
    // `open` is a built-in, `for`/`in` keywords, `self` a keyword — each keeps
    // its own classification (built-in rule runs after keyword and self/cls).
    // T17.7: `for` / `in` / `return` are control keywords, `self` is
    // `variable.language` (the keyword colour), `type` a built-in type.
    let pairs = spans(py, "for self in open(path): return type(self)")
    #expect(kind(of: "for", in: pairs) == .controlKeyword)
    #expect(kind(of: "in", in: pairs) == .controlKeyword)
    #expect(kind(of: "return", in: pairs) == .controlKeyword)
    #expect(kind(of: "self", in: pairs) == .keyword)
    #expect(kind(of: "open", in: pairs) == .builtin)
    #expect(kind(of: "type", in: pairs) == .type)
}

@Test func builtinsInsideStringsAndCommentsAreNotColoured() {
    let py = PythonLanguage.make()
    let pairs = spans(py, #"x = "print len open"  # print open len"#)
    // The quoted text and the comment are single tokens; no built-in token is
    // emitted for the built-in words that live inside them.
    #expect(kind(of: #""print len open""#, in: pairs) == .string)
    #expect(kind(of: "# print open len", in: pairs) == .comment)
    #expect(pairs.contains { $0.kind == .builtin } == false)
}

@Test func javascriptBuiltinGlobalsAreColoured() {
    let js = JavaScriptLanguage.make()
    let pairs = spans(js, "console.log(Math.max(a, b));")
    // T17.7 (VS Code): an object before `.` is a variable, a member call a
    // function.
    #expect(kind(of: "console", in: pairs) == .symbolVariable)
    #expect(kind(of: "Math", in: pairs) == .symbolVariable)
    #expect(kind(of: "log", in: pairs) == .symbolFunction)
    #expect(kind(of: "max", in: pairs) == .symbolFunction)
}

@Test func typescriptInheritsJavaScriptBuiltins() {
    let ts = TypeScriptLanguage.make()
    let pairs = spans(ts, "const p: Promise<number> = fetch(url);")
    // T17.7: a built-in class is a type; a call is a function.
    #expect(kind(of: "Promise", in: pairs) == .type)
    #expect(kind(of: "fetch", in: pairs) == .symbolFunction)
    #expect(kind(of: "number", in: pairs) == .type)   // primitive type still wins
    #expect(kind(of: "const", in: pairs) == .keyword)
}

@Test func cBuiltinLibraryFunctionsAreColoured() {
    let c = CLanguage.make()
    let pairs = spans(c, #"printf("%d", strlen(s));"#)
    #expect(kind(of: "printf", in: pairs) == .builtin)
    #expect(kind(of: "strlen", in: pairs) == .builtin)
}

@Test func cppInheritsCBuiltinsAndAddsStdLib() {
    let cpp = CppLanguage.make()
    let pairs = spans(cpp, "std::cout << printf();")
    // T17.7 (VS Code): `std::` is a scope qualifier (type colour); `cout` is
    // a variable like every other C++ name (identifier pass, no rule token);
    // a call is a function.
    #expect(kind(of: "std", in: pairs) == .type)
    #expect(kind(of: "cout", in: pairs) == nil)
    #expect(kind(of: "printf", in: pairs) == .symbolFunction)
    #expect(kind(of: "::", in: pairs) == .punctuation)
}

@Test func csharpJavaAndBashBuiltinsAreColoured() {
    // T17.7 (VS Code): objects before `.` are variables, calls functions;
    // shell commands in command position are functions (with the leading
    // blank), their arguments strings.
    let cs = CSharpLanguage.make()
    #expect(kind(of: "Console", in: spans(cs, "Console.WriteLine(x);")) == .symbolVariable)
    #expect(kind(of: "WriteLine", in: spans(cs, "Console.WriteLine(x);")) == .symbolFunction)

    let java = JavaLanguage.make()
    #expect(kind(of: "System", in: spans(java, "System.out.println(x);")) == .symbolVariable)

    let bash = BashLanguage.make()
    let pairs = spans(bash, "echo hi | grep x")
    #expect(kind(of: "echo", in: pairs) == .symbolFunction)
    #expect(kind(of: " grep", in: pairs) == .symbolFunction)
    #expect(kind(of: "hi", in: pairs) == .string)
}

// MARK: - Theme: Dark/Light Modern palette + dynamic appearance

@Test func themeBuiltinSharesFunctionColour() {
    let theme = HighlightTheme()
    #expect(theme.color(for: .builtin) === theme.color(for: .symbolFunction))
    #expect(theme.color(for: .property) === theme.color(for: .symbolVariable))
    #expect(theme.color(for: .plain) == nil)
    // The syntax kinds all resolve to a colour.
    for k in [TokenKind.keyword, .string, .number, .comment, .type, .builtin] {
        #expect(theme.color(for: k) != nil)
    }
}

@Test func themeColoursFlipBetweenLightAndDarkAppearance() {
    let theme = HighlightTheme()
    let dark = NSAppearance(named: .darkAqua)!
    let light = NSAppearance(named: .aqua)!

    func resolve(_ kind: TokenKind, _ appearance: NSAppearance) -> NSColor? {
        var out: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            out = theme.color(for: kind)?.usingColorSpace(.sRGB)
        }
        return out
    }

    // Keyword blue differs: Dark Modern #569CD6 vs Light Modern #0000FF.
    let darkKeyword = resolve(.keyword, dark)
    let lightKeyword = resolve(.keyword, light)
    #expect(darkKeyword != nil && lightKeyword != nil)
    #expect(darkKeyword != lightKeyword)

    // The Dark Modern keyword resolves close to #569CD6.
    #expect(abs((darkKeyword?.redComponent ?? 0) - 0x56 / 255.0) < 0.02)
    #expect(abs((darkKeyword?.greenComponent ?? 0) - 0x9C / 255.0) < 0.02)
    #expect(abs((darkKeyword?.blueComponent ?? 0) - 0xD6 / 255.0) < 0.02)
}

// MARK: - Registry lookup

@Test func registryResolvesJSONCaseInsensitively() {
    #expect(LanguageRegistry.definition(forExtension: "json")?.identifier == "json")
    #expect(LanguageRegistry.definition(forExtension: "JSON")?.identifier == "json")
}

@Test func registryReturnsNilForUnknownExtension() {
    #expect(LanguageRegistry.definition(forExtension: "txt") == nil)
    #expect(LanguageRegistry.definition(forExtension: "") == nil)
}

// MARK: - Lazy loading

@Test func supportedExtensionsDoesNotBuildDefinitions() {
    // Listing supported extensions must not invoke any language factory.
    let before = JSONLanguage.buildCount
    #expect(LanguageRegistry.supportedExtensions.contains("json"))
    #expect(JSONLanguage.buildCount == before)
}

@Test func unknownExtensionNeverBuildsJSON() {
    // Resolving an unregistered extension must not build JSON.
    let before = JSONLanguage.buildCount
    _ = LanguageRegistry.definition(forExtension: "nope")
    #expect(JSONLanguage.buildCount == before)
}

@Test func factoryClosureIsNotInvokedUntilCalled() {
    // Demonstrates the lazy pattern directly: holding the factory does nothing.
    var built = false
    let factory: () -> LanguageDefinition = {
        built = true
        return JSONLanguage.make()
    }
    #expect(built == false)
    _ = factory()
    #expect(built == true)
}

// MARK: - Module gating / released state

@MainActor
@Test func disablingModuleReleasesLanguageState() {
    // Route module notifications through a private center so this test does not
    // perturb suites observing `NotificationCenter.default`.
    let center = NotificationCenter()
    let defaults = isolatedDefaults()
    let settings = ModuleSettings(defaults: defaults, center: center)

    let scrollView = NSScrollView()
    let textView = EditorTextView()
    scrollView.documentView = textView

    let engine = HighlightEngine(textView: textView,
                                 scrollView: scrollView,
                                 moduleSettings: settings,
                                 moduleCenter: center)
    engine.setLanguage(fileExtension: "json")

    // Enabled + language resolved → runtime state held.
    #expect(engine.isModuleEnabled)
    #expect(engine.isRuntimeStateReleased == false)

    // Disabling the module must release language state.
    settings.setEnabled(false, for: .highlight)
    #expect(engine.isModuleEnabled == false)
    #expect(engine.isRuntimeStateReleased)

    // Re-enabling rebuilds it from the remembered extension.
    settings.setEnabled(true, for: .highlight)
    #expect(engine.isModuleEnabled)
    #expect(engine.isRuntimeStateReleased == false)
}

@MainActor
@Test func engineStartsDisabledWhenModuleOff() {
    let center = NotificationCenter()
    let defaults = isolatedDefaults()
    let settings = ModuleSettings(defaults: defaults, center: center)
    settings.setEnabled(false, for: .highlight)

    let scrollView = NSScrollView()
    let textView = EditorTextView()
    scrollView.documentView = textView

    let engine = HighlightEngine(textView: textView,
                                 scrollView: scrollView,
                                 moduleSettings: settings,
                                 moduleCenter: center)
    engine.setLanguage(fileExtension: "json")

    // Module off from the start: no runtime state despite a known language.
    #expect(engine.isModuleEnabled == false)
    #expect(engine.isRuntimeStateReleased)
}

// MARK: - Anchored-search boundary regressions (T10.2 review)

/// `\b` in a rule must respect the character *before* the match position: the
/// tokenizer advances through unmatched identifiers one character at a time, and
/// without transparent bounds the search-range start acted as a fake word
/// boundary — colouring the `in` inside `main`, the `print` inside `sprint`,
/// and the `1` inside `x1`.
@Test func keywordDoesNotMatchInsideIdentifier() {
    let def = LanguageRegistry.definition(forIdentifier: "python")!
    for line in ["def main(argv):", "def maintain(x):"] {
        let ns = line as NSString
        for token in def.tokenize(line: line) where token.kind == .keyword {
            #expect(ns.substring(with: token.range) == "def",
                    "unexpected keyword token in \(line)")
        }
    }
}

@Test func builtinDoesNotMatchInsideIdentifier() {
    let def = LanguageRegistry.definition(forIdentifier: "python")!
    let tokens = def.tokenize(line: "sprints = 3")
    #expect(!tokens.contains { $0.kind == .builtin })
}

@Test func numberDoesNotMatchInsideIdentifier() {
    let def = LanguageRegistry.definition(forIdentifier: "python")!
    let tokens = def.tokenize(line: "x1 = y")
    #expect(!tokens.contains { $0.kind == .number })
}

// MARK: - Markdown additions (T14.5)

@Test func markdownStrikethroughIsDimmed() {
    let kinds = MarkdownLanguage.make().tokenize(line: "a ~~gone~~ b").map(\.kind)
    #expect(kinds.contains(.comment))
}

@Test func markdownBoldItalicMatchesWholeSpan() {
    let def = MarkdownLanguage.make()
    let line = "***both*** rest"
    let ns = line as NSString
    let spans = def.tokenize(line: line).map { ns.substring(with: $0.range) }
    #expect(spans.contains("***both***"))
}

// MARK: - Cross-line multi-line strings (T14.7)

/// User bug: the *body* lines of a Python `"""` block were re-tokenized as
/// code, so numbers / classes / functions inside a docstring got their code
/// colours. The body must read as one string span, and the state must be
/// released again after the closing delimiter.
@Test func pythonDocstringBodyIsOneStringSpan() {
    let py = PythonLanguage.make()
    let lines = documentSpans(py, "def f():\n    \"\"\"doc\n    x = 1 + 2\n    \"\"\"\n    y = 3\n")

    // Body line: a single string token covering the whole line, no number.
    #expect(lines[2].count == 1)
    #expect(lines[2].first?.kind == .string)
    #expect(lines[2].first?.text == "    x = 1 + 2")
    #expect(lines[2].contains { $0.kind == .number } == false)

    // After the closing line, normal colouring is back.
    #expect(kind(of: "3", in: lines[4]) == .number)
    #expect(kind(of: "def", in: lines[0]) == .keyword)
}

@Test func pythonDocstringCloseLineColoursOnlyUpToDelimiter() {
    let py = PythonLanguage.make()
    let lines = documentSpans(py, "s = \"\"\"a\nb\"\"\" + repr(2)\n")

    // The carried-in string ends at the closing delimiter …
    #expect(lines[1].first?.kind == .string)
    #expect(lines[1].first?.text == "b\"\"\"")
    // … and the code after it on the same line is tokenized normally.
    #expect(kind(of: "repr", in: lines[1]) == .builtin)
    #expect(kind(of: "2", in: lines[1]) == .number)
}

@Test func pythonMultilineStringClosesOnlyWithItsOwnDelimiter() {
    let py = PythonLanguage.make()

    // A `"""` inside a `'''` block is plain body text, not a close.
    let single = documentSpans(py, "x = '''\n\"\"\" not a close 7\n'''\ny = 4\n")
    #expect(single[1].count == 1)
    #expect(single[1].first?.kind == .string)
    #expect(single[1].contains { $0.kind == .number } == false)
    #expect(kind(of: "4", in: single[3]) == .number)

    // … and symmetrically for `'''` inside a `"""` block.
    let double = documentSpans(py, "x = \"\"\"\n''' not a close 7\n\"\"\"\ny = 4\n")
    #expect(double[1].count == 1)
    #expect(double[1].first?.kind == .string)
    #expect(kind(of: "4", in: double[3]) == .number)
}

@Test func pythonSingleLineTripleQuoteLeavesFollowingLinesAlone() {
    let py = PythonLanguage.make()
    let lines = documentSpans(py, "a = \"\"\"x\"\"\"\nb = 5\n")
    #expect(kind(of: "\"\"\"x\"\"\"", in: lines[0]) == .string)
    // The state closed on the same line, so line 2 is ordinary code.
    #expect(kind(of: "5", in: lines[1]) == .number)
    #expect(lines[1].contains { $0.kind == .string } == false)
}

@Test func lexicalStateResolvesAtAnyOffset() {
    // Python (PythonTokenizer state, resumed from checkpoints).
    let py = PythonLanguage.make()
    let source = "a = \"\"\"\nbody 1\n\"\"\"\nz = 1\nb = '''\ntail\n"
    let ns = source as NSString
    func pythonOpen(atLineStartingWith prefix: String) -> Bool {
        var store = CheckpointStore()
        return !HighlightEngine.pythonLexicalState(at: ns.range(of: prefix).location, in: ns, language: py,
                                                   checkpoints: &store).frames.isEmpty
    }
    #expect(pythonOpen(atLineStartingWith: "a = ") == false)
    #expect(pythonOpen(atLineStartingWith: "body 1"))        // inside the block
    #expect(pythonOpen(atLineStartingWith: "z = 1") == false) // closed again
    #expect(pythonOpen(atLineStartingWith: "tail"))           // inside the unterminated block

    // A profiled language (generic scanner state).
    let js = JavaScriptLanguage.make()
    let jsSource = "a = `\nbody ${x\n} y`\n/* c\nd */\nz = 1\n"
    let jsNS = jsSource as NSString
    func jsState(atLineStartingWith prefix: String) -> LexicalScanState {
        var store = CheckpointStore()
        return HighlightEngine.lexicalScanState(at: jsNS.range(of: prefix).location, in: jsNS, language: js,
                                                checkpoints: &store)
    }
    #expect(jsState(atLineStartingWith: "a = ").isEmpty)
    #expect(jsState(atLineStartingWith: "body").frames == [.string(form: 2, count: 0, delimiter: nil)])
    #expect(jsState(atLineStartingWith: "} y").frames.count == 2)   // template + interpolation
    #expect(jsState(atLineStartingWith: "d */").frames == [.blockComment(form: 0, depth: 1)])
    #expect(jsState(atLineStartingWith: "z = 1").isEmpty)
}

@Test func unprofiledLanguagesKeepPerLineTokens() {
    // Every registered language but Python (own tokenizer) is profiled since
    // M17 T17.3, so the per-line path is exercised with a synthetic
    // unprofiled definition (string and comment rules of its own).
    let def = LanguageDefinition(identifier: "unprofiled-test", fileExtensions: [], rules: [
        LanguageRule(pattern: #"/\*.*?(?:\*/|$)"#, kind: .comment),
        LanguageRule(pattern: #""(?:[^"\\]|\\.)*""#, kind: .string),
        LanguageRule(pattern: #"\b(?:let|b)\b"#, kind: .keyword),
    ])
    #expect(def.lexicalProfile == nil && def.lexicalScanner == nil)
    // No state is carried: each line tokenizes exactly as on its own.
    let source = "let s = \"\"\"x\n/* a\nb */ \"\"\";\n"
    let lines = documentSpans(def, source)
    #expect(lines[1].contains { $0.kind == .comment })
    for (index, line) in source.components(separatedBy: "\n").dropLast().enumerated() {
        let ns = line as NSString
        let expected = def.tokenize(line: line).map { (ns.substring(with: $0.range), $0.kind) }
        #expect(lines[index].map(\.text) == expected.map(\.0))
        #expect(lines[index].map(\.kind) == expected.map(\.1))
    }
}

/// JS (profiled): a block comment's body lines are comment, a template's body
/// lines are string, and the code inside `${…}` is tokenized as code.
@Test func javascriptCrossLineCommentAndTemplate() {
    let js = JavaScriptLanguage.make()
    let lines = documentSpans(js, "/* head\n if (x) return 42;\n*/ let a = 1;\nconst t = `x\n ${count + 2} if\nend`; return 3\n")
    #expect(lines[1].count == 1)
    #expect(lines[1].first?.kind == .comment)
    #expect(lines[1].first?.text == " if (x) return 42;")
    #expect(kind(of: "let", in: lines[2]) == .keyword)
    #expect(kind(of: "1", in: lines[2]) == .number)
    #expect(lines[4].first?.text == " ")
    #expect(lines[4].first?.kind == .string)
    #expect(kind(of: "${", in: lines[4]) == .interpolationDelimiter)   // T17.7
    #expect(kind(of: "2", in: lines[4]) == .number)
    #expect(kind(of: " if", in: lines[4]) == .string)      // template text, not a keyword
    #expect(kind(of: "end`", in: lines[5]) == .string)
    #expect(kind(of: "return", in: lines[5]) == .controlKeyword)   // T17.7
    #expect(kind(of: "3", in: lines[5]) == .number)
}

/// End-to-end through the engine: painting a docstring must leave the body's
/// identifiers with the string colour, i.e. the in-document symbol pass (which
/// colours class / function names) must not reach inside the synthesized span.
@MainActor
@Test func enginePaintsDocstringBodyAsStringIncludingSymbols() {
    let center = NotificationCenter()
    let settings = ModuleSettings(defaults: isolatedDefaults(), center: center)

    let frame = NSRect(x: 0, y: 0, width: 600, height: 400)
    let scrollView = NSScrollView(frame: frame)
    let textView = EditorTextView(frame: frame)
    scrollView.documentView = textView
    let source = "class Widget:\n    \"\"\"Widget makes 42.\n    \"\"\"\n    n = 42\n"
    textView.string = source

    let engine = HighlightEngine(textView: textView,
                                 scrollView: scrollView,
                                 moduleSettings: settings,
                                 moduleCenter: center)
    engine.setLanguage(identifier: "python")
    textView.layoutManager?.ensureLayout(for: textView.textContainer!)
    engine.appearanceDidChange()   // invalidate + repaint synchronously

    let ns = source as NSString
    let lm = textView.layoutManager!
    func colour(at index: Int) -> NSColor? {
        lm.temporaryAttribute(.foregroundColor, atCharacterIndex: index,
                              effectiveRange: nil) as? NSColor
    }
    let theme = HighlightTheme()
    // `Widget` inside the docstring: string colour, not the symbol/type colour.
    #expect(colour(at: ns.range(of: "Widget makes").location) === theme.color(for: .string))
    // The number inside the docstring is string-coloured too …
    #expect(colour(at: ns.range(of: "42.").location) === theme.color(for: .string))
    // … while the one on the code line below keeps the number colour.
    #expect(colour(at: ns.range(of: "n = 42").location + 4) === theme.color(for: .number))
}

@Test func markdownListMarkersAreVisiblyColoured() {
    let def = MarkdownLanguage.make()
    // `.property` resolves to the variable blue; `.punctuation` resolved to the
    // plain text colour and looked un-highlighted (user feedback).
    for line in ["- item", "* item", "+ item", "1. item", "  - sub"] {
        #expect(def.tokenize(line: line).contains { $0.kind == .property }, "marker not coloured in: \(line)")
    }
}
