import Foundation
import Testing
@testable import KaruCore

// M17 T17.2 — the Python migration experiment, kept as a record of why Python
// stays on `PythonTokenizer` (plan §4: migrate only if every existing Python
// test passes without Python-specific logic in the generic scanner).
//
// The profile below expresses Python's string structure (prefixes r/b/u/f and
// their combinations, case-insensitive; single-line quotes with backslash
// continuation; triple quotes; f-string `{…}` fields with `{{` escapes). With
// it as Python's production path, the full suite failed 11 expectations in 4
// tests — all of them PythonTokenizer behaviours *inside replacement fields*
// that a generic profile has no notion of:
//   - identifiers in a field are `.symbolVariable` (OptimizationTests
//     pythonFStringsDistinguishExpressionsFromLiterals ×5,
//     pythonNestedQuotesAndMultilineFStrings ×3,
//     pythonScrollCheckpointInvalidatesAfterEditingPrefix ×1;
//     LanguagesBatch1Tests pythonFStringCommentAndDecorator ×1);
//   - a format spec after `:` is string text and `!r` / `!s` / `!a` are
//     punctuation (same lines; the generic scanner sees code).
// The cross-line structure itself agrees (checked below), so the gap is the
// in-field classification only. (The 12th failure was this suite's own
// edit-sensitivity check, which relies on PythonTokenizer keeping an
// unbalanced field open.)

private func experimentalPythonProfile() -> LexicalProfile {
    typealias Form = LexicalProfile.StringForm
    let field = LexicalProfile.InterpolationForm(open: "{", close: "}", escapedOpen: "{{")
    let formatted = ["f", "fr", "rf"]
    let other = ["r", "u", "b", "br", "rb"]
    var forms: [Form] = []
    for quote in ["\"\"\"", "'''"] {
        forms.append(Form(prefixes: formatted, prefixRequired: true, prefixCaseInsensitive: true,
                          delimiter: .fixed(open: quote, close: quote), multiline: true, interpolations: [field]))
        forms.append(Form(prefixes: other, prefixCaseInsensitive: true,
                          delimiter: .fixed(open: quote, close: quote), multiline: true))
    }
    for quote in ["\"", "'"] {
        forms.append(Form(prefixes: formatted, prefixRequired: true, prefixCaseInsensitive: true,
                          delimiter: .fixed(open: quote, close: quote), multiline: false, interpolations: [field]))
        forms.append(Form(prefixes: other, prefixCaseInsensitive: true,
                          delimiter: .fixed(open: quote, close: quote), multiline: false))
    }
    return LexicalProfile(lineComments: ["#"], strings: forms)
}

@Suite("PythonProfileExperiment")
struct PythonProfileExperimentTests {
    let python = PythonLanguage.make()
    let generic: LanguageDefinition = {
        let py = PythonLanguage.make()
        return LanguageDefinition(identifier: "python-generic-experiment", fileExtensions: [],
                                  rules: py.rules, keywords: py.keywords, builtins: py.builtins,
                                  lexicalProfile: experimentalPythonProfile())
    }()

    /// At every line start of the Python fixture (and of a sample mixing
    /// docstrings, f-strings and fake triple quotes in comments), the generic
    /// scanner is inside a multi-line construct exactly when PythonTokenizer is.
    @Test func crossLineStructureAgreesWithPythonTokenizer() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/M17/highlight/python.py")
        let sample = """
        def f(a, b=1):
            '''Doc with "quotes" and {braces}
            spanning lines'''
            name = f"value {a!r:>10} and {b + 1} {{literal}}"
            other = f'''multi
        {a}
          line {b['k']:{a}}'''
            # comment with \"\"\" fake triple
            s = "plain \\" escaped" + 'it\\'s'
            r = rb'raw\\d+' + u"x" + Rb'\\'' + F"{a}"
            return name
        x = \"\"\"
            triple
            \"\"\"

        """
        let scanner = try #require(generic.lexicalScanner)
        for text in [try String(contentsOf: url, encoding: .utf8), sample] {
            let ns = text as NSString
            var genericState = LexicalScanState()
            var pythonState = PythonTokenizer.State()
            var loc = 0
            while loc < ns.length {
                let line = ns.lineRange(for: NSRange(location: loc, length: 0))
                scanner.advance(ns, from: line.location, to: NSMaxRange(line), state: &genericState)
                _ = PythonTokenizer.scan(ns.substring(with: line), language: python, state: &pythonState)
                #expect(genericState.isEmpty == pythonState.frames.isEmpty,
                        "line ending at \(NSMaxRange(line)): generic \(genericState.frames), python \(pythonState.frames.count) frames")
                loc = NSMaxRange(line)
            }
        }
    }

    /// The documented gap: inside a replacement field PythonTokenizer
    /// classifies identifiers, conversions and format specs; the generic
    /// scanner only knows the field is code.
    @Test func replacementFieldClassificationIsTheGap() {
        let line = #"s = f"{{literal}} {name} {value!r:>{width}.{precision}f}" # c"#
        let ns = line as NSString
        func kind(_ word: String, _ tokens: [(range: NSRange, kind: TokenKind)], options: NSString.CompareOptions = []) -> TokenKind? {
            let r = ns.range(of: word, options: options)
            return tokens.first { NSLocationInRange(r.location, $0.range) }?.kind
        }
        let tokenizer = python.tokenize(line: line)
        let profiled = generic.tokenize(line: line)
        for word in ["name", "value", "width", "precision"] {
            #expect(kind(word, tokenizer) == .symbolVariable)
            #expect(kind(word, profiled) == nil)
        }
        #expect(kind("!r", tokenizer) == .punctuation)
        #expect(kind(">", tokenizer) == .string)          // format spec
        #expect(kind(">", profiled) == nil)
        // Outside the fields both agree.
        for (word, expected) in [("{{literal}} ", TokenKind.string), ("# c", .comment)] {
            #expect(kind(word, tokenizer) == expected)
            #expect(kind(word, profiled) == expected)
        }
    }
}
