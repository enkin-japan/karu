import Foundation
import Testing
@testable import KaruCore

// Tests for the byte-scanning JSONFormatter (RELIABILITY-PLAN F7: R04, N02,
// N03): differential tests against `LegacyJSONFormatter`, the limits, and the
// grapheme-cluster rules the old `[Character]` tokenizer had.

// MARK: - Deterministic generator

/// SplitMix64: seeded, so every run sees the same corpus.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private struct DocumentGenerator {
    var rng: SeededGenerator
    /// Kept small: the oracle recurses per container.
    let maxDepth = 6

    init(seed: UInt64) { rng = SeededGenerator(seed: seed) }

    mutating func pick<T>(_ options: [T]) -> T { options[Int.random(in: 0..<options.count, using: &rng)] }
    mutating func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &rng) < p }
    mutating func count(_ upTo: Int) -> Int { Int.random(in: 0...upTo, using: &rng) }

    mutating func whitespace(multiline: Bool) -> String {
        if multiline {
            return pick(["", "", " ", "  ", "\t", "\n", "\r\n", "\r", " \n  ", "\n\t\t", "\r\n    "])
        }
        return pick(["", "", " ", "  ", "\t", " \t "])
    }

    mutating func string(multiline: Bool) -> String {
        var pieces: [String] = ["abc", "x", " ", "Key_1", "a b c",
                                "\\n", "\\\"", "\\\\", "\\/", "\\t", "\\u00e9", "\\uD83D\\uDE00", "\\b",
                                "é", "中文", "😀", "👨‍👩‍👧", "🇯🇵", "e\u{301}", "\u{600}x", "a\u{200D}",
                                "\"\u{301}", "\\\u{301}", "ก\u{E31}", "\u{1100}\u{1161}", "\u{FEFF}"]
        if multiline { pieces += ["\n", "\r\n", "\r", "\t"] }
        var s = "\""
        for _ in 0..<count(4) { s += pick(pieces) }
        return s + "\""
    }

    mutating func number() -> String {
        pick(["0", "-0", "1", "42", "-17", "1e5", "1E+5", "1.5E-3", "01", "-12.5e+10", "3.14159",
              "12345678901234567890.000000001", "1.5e+308", "1\u{301}", "3\u{301}4", "0.0"])
    }

    mutating func value(depth: Int, multiline: Bool) -> String {
        if depth < maxDepth && chance(depth == 0 ? 0.9 : 0.4) {
            let isObject = chance(0.5)
            let n = count(4)
            if n == 0 { return isObject ? "{" + whitespace(multiline: multiline) + "}" : "[" + whitespace(multiline: multiline) + "]" }
            var parts: [String] = []
            for _ in 0..<n {
                let v = value(depth: depth + 1, multiline: multiline)
                if isObject {
                    let k = string(multiline: multiline)
                    parts.append(k + whitespace(multiline: multiline) + ":" + whitespace(multiline: multiline) + v)
                } else {
                    parts.append(v)
                }
            }
            let sep = { (g: inout DocumentGenerator) in g.whitespace(multiline: multiline) + "," + g.whitespace(multiline: multiline) }
            var body = parts[0]
            for p in parts.dropFirst() { body += sep(&self) + p }
            let ws1 = whitespace(multiline: multiline), ws2 = whitespace(multiline: multiline)
            return (isObject ? "{" : "[") + ws1 + body + ws2 + (isObject ? "}" : "]")
        }
        switch count(4) {
        case 0, 1: return string(multiline: multiline)
        case 2: return number()
        default: return pick(["true", "false", "null"])
        }
    }

    mutating func document() -> String {
        whitespace(multiline: true) + value(depth: 0, multiline: true) + whitespace(multiline: true)
    }

    mutating func jsonlDocument() -> String {
        var s = ""
        for i in 0..<(1 + count(5)) {
            if i > 0 { s += pick(["\n", "\r\n", "\r"]) }
            if chance(0.2) {
                s += pick(["", " ", "\t", "\u{A0}", "\u{3000}", " \u{2003}\t"])
            } else {
                s += whitespace(multiline: false) + value(depth: 1, multiline: false) + whitespace(multiline: false)
            }
        }
        if chance(0.3) { s += pick(["\n", "\r\n", "\n\n"]) }
        return s
    }

    /// One to three random edits: scalar deletions/insertions, truncation,
    /// or a byte-level edit decoded leniently.
    mutating func mutate(_ text: String) -> String {
        var scalars = Array(text.unicodeScalars)
        let inserts: [String] = ["{", "}", "[", "]", ":", ",", "\"", "\\", "\n", "\r", "\r\n", " ", "\t",
                                 "x", "t", "n", "f", "-", "0", "9", ".", "e", "+", "\u{301}", "\u{600}",
                                 "\u{200D}", "\u{FEFF}", "\u{A0}", "中", "😀", "\u{903}"]
        for _ in 0..<(1 + count(2)) {
            switch count(5) {
            case 0, 1:
                if !scalars.isEmpty { scalars.remove(at: Int.random(in: 0..<scalars.count, using: &rng)) }
            case 2, 3:
                let at = Int.random(in: 0...scalars.count, using: &rng)
                scalars.insert(contentsOf: pick(inserts).unicodeScalars, at: at)
            case 4:
                if !scalars.isEmpty { scalars.removeLast(Int.random(in: 1...scalars.count, using: &rng)) }
            default:
                var s = String(String.UnicodeScalarView(scalars))
                var bytes = Array(s.utf8)
                if !bytes.isEmpty {
                    bytes.remove(at: Int.random(in: 0..<bytes.count, using: &rng))
                    s = String(decoding: bytes, as: UTF8.self)
                }
                scalars = Array(s.unicodeScalars)
            }
        }
        return String(String.UnicodeScalarView(scalars))
    }
}

// MARK: - Comparison

private enum Outcome: Equatable {
    case output(String)
    case syntax(JSONFormatError)
    case other(String)
}

private func outcome(_ body: () throws -> String) -> Outcome {
    do {
        return .output(try body())
    } catch let error as JSONFormatError {
        return .syntax(error)
    } catch {
        return .other("\(error)")
    }
}

/// Errors the old renderer raised; any other message came from its tokenizer.
private let structuralMessages: Set<String> = [
    "unexpected end of input, expected a value",
    "unexpected token, expected a value",
    "unclosed object, missing '}'",
    "unclosed array, missing ']'",
    "expected string key in object",
    "expected ':' after object key",
    "expected ',' or '}' in object",
    "expected ',' or ']' in array",
    "unexpected token after top-level JSON value",
]

/// New vs old: identical when the old one succeeds; identical when the old
/// one reports a structural error (then the input has no tokenizer error, so
/// both passes see the same tokens); otherwise the old tokenizer error came
/// from tokenizing everything first, and the single pass may stop earlier at
/// a structural error, never at a later line.
private func agrees(new: Outcome, old: Outcome) -> Bool {
    switch (new, old) {
    case (.output(let a), .output(let b)):
        return a == b
    case (.syntax(let a), .syntax(let b)):
        if a == b { return true }
        if structuralMessages.contains(b.message) { return false }
        return structuralMessages.contains(a.message) && a.line <= b.line
    default:
        return false
    }
}

private func describe(_ text: String) -> String {
    text.unicodeScalars.map { $0.isASCII && $0.value >= 0x20 && $0.value < 0x7F ? String($0) : "\\u{\(String($0.value, radix: 16))}" }.joined()
}

// MARK: - Differential tests

@Suite("JSONFormatter rewrite — differential against the legacy implementation")
struct JSONFormatterDifferentialTests {

    @Test("2 000 generated valid documents: identical output for widths 0/1/2/4/8 and JSONL")
    func validDocuments() {
        var generator = DocumentGenerator(seed: 0x4B41_5255_4A53_4F4E)
        var accepted = 0
        var mismatches = 0
        for _ in 0..<2_000 {
            let doc = generator.document()
            let old2 = outcome { try LegacyJSONFormatter.prettyPrint(doc, indentWidth: 2) }
            if case .output = old2 { accepted += 1 }
            for width in [0, 1, 2, 4, 8] {
                let new = outcome { try JSONFormatter.prettyPrint(doc, indentWidth: width) }
                let old = width == 2 ? old2 : outcome { try LegacyJSONFormatter.prettyPrint(doc, indentWidth: width) }
                if !agrees(new: new, old: old) {
                    mismatches += 1
                    Issue.record("width \(width) differs for \(describe(doc)): new \(new) old \(old)")
                }
            }
            let newL = outcome { try JSONFormatter.formatJSONL(doc) }
            let oldL = outcome { try LegacyJSONFormatter.formatJSONL(doc) }
            if !agrees(new: newL, old: oldL) {
                mismatches += 1
                Issue.record("JSONL differs for \(describe(doc)): new \(newL) old \(oldL)")
            }
            let succeeded: Bool
            if case .output = outcome({ try JSONFormatter.prettyPrint(doc) }) { succeeded = true } else { succeeded = false }
            #expect(JSONFormatter.isValid(doc) == succeeded, "isValid disagrees for \(describe(doc))")
            if mismatches > 20 { break }
        }
        // The generator must produce mostly valid JSON or this test proves little.
        #expect(accepted >= 1_900, "only \(accepted) generated documents were valid")
    }

    @Test("2 000 generated JSONL documents: identical output")
    func validJSONLDocuments() {
        var generator = DocumentGenerator(seed: 0x4A53_4F4E_4C21)
        var accepted = 0
        var mismatches = 0
        for _ in 0..<2_000 {
            let doc = generator.jsonlDocument()
            let new = outcome { try JSONFormatter.formatJSONL(doc) }
            let old = outcome { try LegacyJSONFormatter.formatJSONL(doc) }
            if case .output = old { accepted += 1 }
            if !agrees(new: new, old: old) {
                mismatches += 1
                Issue.record("JSONL differs for \(describe(doc)): new \(new) old \(old)")
                if mismatches > 20 { break }
            }
        }
        #expect(accepted >= 1_900, "only \(accepted) generated JSONL documents were valid")
    }

    @Test("3 000 mutated documents: same accept/reject, same output, error line never later")
    func mutatedDocuments() {
        var generator = DocumentGenerator(seed: 0x4D55_5441_5445)
        var rejected = 0
        var sameError = 0
        var mismatches = 0
        for i in 0..<3_000 {
            let base = i % 3 == 0 ? generator.jsonlDocument() : generator.document()
            let doc = generator.mutate(base)
            for width in [2, 4] {
                let new = outcome { try JSONFormatter.prettyPrint(doc, indentWidth: width) }
                let old = outcome { try LegacyJSONFormatter.prettyPrint(doc, indentWidth: width) }
                if width == 2, case .syntax = old { rejected += 1 }
                if width == 2, case .syntax = old, new == old { sameError += 1 }
                if !agrees(new: new, old: old) {
                    mismatches += 1
                    Issue.record("width \(width) differs for \(describe(doc)): new \(new) old \(old)")
                }
                let succeeded: Bool
                if case .output = new { succeeded = true } else { succeeded = false }
                if width == 2 {
                    #expect(JSONFormatter.isValid(doc) == succeeded, "isValid disagrees for \(describe(doc))")
                }
            }
            let newL = outcome { try JSONFormatter.formatJSONL(doc) }
            let oldL = outcome { try LegacyJSONFormatter.formatJSONL(doc) }
            if !agrees(new: newL, old: oldL) {
                mismatches += 1
                Issue.record("JSONL differs for \(describe(doc)): new \(newL) old \(oldL)")
            }
            if mismatches > 20 { break }
        }
        #expect(rejected >= 1_500, "only \(rejected) mutated documents were invalid")
        // Most errors are reported identically; the rest only earlier.
        #expect(sameError * 2 >= rejected)
    }

    @Test("hand-picked grapheme, whitespace and line-break edge cases match the legacy implementation exactly")
    func edgeCases() {
        let cases: [String] = [
            "", " ", "\n\n\n", "\r\n\r\n", "\t", "\u{FEFF}{}", "\u{FEFF}",
            "[\"a\"\u{301}\"]",            // quote + combining mark does not close the string
            "[\"a\u{600}\"]",              // prepend glues onto the closing quote: unterminated
            "[\"a\u{600}\"\"]",
            "[\"\\\u{301}\"]",             // backslash + combining mark is not an escape
            "[\"\\\u{600}\"]",             // escape consumes the prepend+quote cluster
            "[\"\\\r\n\",\n1,]",           // escaped CRLF: not a line break inside strings
            "[\"a\r\nb\rc\nd\",\n x]",     // only a lone LF counts inside strings
            "[\"\\\n\",\n x]",
            "[1\u{301}]", "[9\u{301}]", "[1\u{301}2.5\u{301}e3]", "[-\u{301}1]", "[1.\u{301}]",
            "[1e\u{301}5]", "[1.5\r\n]", "[1\r\n,\r2]",
            "[t\u{301}rue]", "[tru\u{301}e]", "[true\u{301}]", "[null\u{200D}]", "[truex]", "[truefalse]",
            "{\u{301}}", "[ \u{301}1]", "[\t\u{301}1]", "[\n\u{301}1]", "[\u{600}1]", "[1,\u{903}2]",
            "[01, -0, 1e5, 1E-5, -0.0e+0]", "-", "-a", "1.", "1.e5", "1e", "1e+", "1.5x", "[.5]",
            "{\"a\":1,\"a\":2}", "{\"a\" 1}", "{1:2}", "{\"a\":}", "[,]", "[1,]", "]", "}", "[}", "{]", "1 2",
            "[[[[]]]]", "{\"a\":{\"b\":{}}}", "[\n\n", "{\n\"a\"\n", "{\"a\":1,\n", "[\"unterminated\n",
            "[\"😀👨‍👩‍👧🇯🇵\\uD83D\\uDE00\"]", "\"\u{0}\"", "[\"\u{7F}\"]", "[\u{7F}]",
            "x", "\"a\"\u{301}", "{} \u{301}", "[]\r\n\r\nx", "nul", "fals", "tr",
        ]
        for doc in cases {
            for width in [0, 2, 3] {
                let new = outcome { try JSONFormatter.prettyPrint(doc, indentWidth: width) }
                let old = outcome { try LegacyJSONFormatter.prettyPrint(doc, indentWidth: width) }
                #expect(new == old, "width \(width) for \(describe(doc)): new \(new) old \(old)")
            }
            let newL = outcome { try JSONFormatter.formatJSONL(doc) }
            let oldL = outcome { try LegacyJSONFormatter.formatJSONL(doc) }
            #expect(newL == oldL, "JSONL for \(describe(doc)): new \(newL) old \(oldL)")
        }
    }

    @Test("JSONL blank-line detection matches trimming .whitespaces, including Unicode spaces")
    func jsonlBlankLines() {
        let blanks = ["", " ", "\t", "\u{A0}", "\u{1680}", "\u{2000}\u{200A}", "\u{202F}", "\u{205F}", "\u{3000}",
                      "\u{200B}", "\u{FEFF}", "\u{85}", "\u{301}", " \u{301}", "\u{2028}", "\u{B}", "\u{C}"]
        for blank in blanks {
            let doc = "[1]\n\(blank)\r\n{}\r\(blank)"
            let new = outcome { try JSONFormatter.formatJSONL(doc) }
            let old = outcome { try LegacyJSONFormatter.formatJSONL(doc) }
            #expect(new == old, "\(describe(blank)): new \(new) old \(old)")
        }
    }

    @Test("a bridged NSString input gives the same result as a native string")
    func bridgedInput() throws {
        let native = "{\"名前\":[1,\"😀\",{\"e\u{301}\":null}]}"
        let bridged = NSString(string: native) as String
        #expect(try JSONFormatter.prettyPrint(bridged) == LegacyJSONFormatter.prettyPrint(native))
        #expect(try JSONFormatter.formatJSONL(bridged) == LegacyJSONFormatter.formatJSONL(native))
        #expect(JSONFormatter.isValid(bridged))
    }
}

// MARK: - Grapheme fast path

@Suite("JSONFormatter rewrite — grapheme fast path")
struct JSONFormatterGraphemeTests {

    @Test("the never-joins prefilter is exact: none of those scalars clusters with ASCII on either side")
    func prefilterIsSound() {
        let asciiSamples: [Unicode.Scalar] = ["\"", "\\", " ", "{", "0", "9", "t", "e", "-", ".", "a", ",", "\t"]
        var checked = 0
        for value in UInt32(0x80)...0xD7A3 where JSONFormatter.neverJoinsASCII(value) {
            guard let scalar = Unicode.Scalar(value) else { continue }
            for ascii in asciiSamples {
                var after = ""
                after.unicodeScalars.append(ascii)
                after.unicodeScalars.append(scalar)
                var before = ""
                before.unicodeScalars.append(scalar)
                before.unicodeScalars.append(ascii)
                if after.count != 2 || before.count != 2 {
                    Issue.record("U+\(String(value, radix: 16)) clusters with \(ascii)")
                    return
                }
            }
            checked += 1
        }
        #expect(checked > 30_000)
    }

    @Test("pairJoins recognises combining marks, ZWJ, spacing marks and prepends")
    func pairJoins() {
        #expect(JSONFormatter.pairJoins("\"", "\u{301}"))
        #expect(JSONFormatter.pairJoins("a", "\u{200D}"))
        #expect(JSONFormatter.pairJoins("a", "\u{903}"))
        #expect(JSONFormatter.pairJoins("\u{600}", "\""))
        #expect(!JSONFormatter.pairJoins("\u{600}", "\t"))
        #expect(!JSONFormatter.pairJoins("\t", "\u{301}"))
        #expect(!JSONFormatter.pairJoins("\"", "中"))
        #expect(!JSONFormatter.pairJoins("\"", "\u{FEFF}"))
    }
}

// MARK: - Limits and scale

@Suite("JSONFormatter rewrite — limits")
struct JSONFormatterLimitTests {

    private func limitError(_ body: () throws -> String) -> FormatLimitError? {
        do {
            _ = try body()
            return nil
        } catch let error as FormatLimitError {
            return error
        } catch {
            Issue.record("unexpected error \(error)")
            return nil
        }
    }

    @Test("arrays: exactly 512 levels format, 513 throw nestingTooDeep at the 513th bracket's line")
    func arrayDepth() throws {
        let ok = String(repeating: "[", count: 512) + String(repeating: "]", count: 512)
        let pretty = try JSONFormatter.prettyPrint(ok, indentWidth: 0)
        #expect(pretty.hasPrefix(String(repeating: "[\n", count: 511) + "[]"))
        #expect(JSONFormatter.isValid(ok))

        let deep = String(repeating: "[\n", count: 513) + String(repeating: "]", count: 513)
        #expect(limitError { try JSONFormatter.prettyPrint(deep) } == .nestingTooDeep(line: 513, limit: 512))
        #expect(!JSONFormatter.isValid(deep))
    }

    @Test("objects and mixed nesting hit the same limit")
    func objectAndMixedDepth() throws {
        func objects(_ n: Int) -> String {
            String(repeating: "{\"k\":\n", count: n - 1) + "{}" + String(repeating: "}", count: n - 1)
        }
        _ = try JSONFormatter.prettyPrint(objects(512))
        #expect(limitError { try JSONFormatter.prettyPrint(objects(513)) } == .nestingTooDeep(line: 513, limit: 512))

        func mixed(_ n: Int) -> String {
            var open = "", close = ""
            for level in 0..<n {
                if level % 2 == 0 { open += "[1,\n"; close = "]" + close } else { open += "{\"a\":\n"; close = "}" + close }
            }
            return open + "null" + close
        }
        _ = try JSONFormatter.prettyPrint(mixed(512))
        #expect(limitError { try JSONFormatter.prettyPrint(mixed(513)) } == .nestingTooDeep(line: 513, limit: 512))
    }

    @Test("custom depth limits are respected, including the exact boundary")
    func customDepth() throws {
        let limits = FormatLimits(maxDepth: 3, outputFactor: 8, outputSlackBytes: 1 << 20)
        #expect(try JSONFormatter.prettyPrint("[[[1]]]", limits: limits) == LegacyJSONFormatter.prettyPrint("[[[1]]]"))
        #expect(limitError { try JSONFormatter.prettyPrint("[[[[]]]]", limits: limits) } == .nestingTooDeep(line: 1, limit: 3))
        #expect(!JSONFormatter.isValid("{\"a\":[{\"b\":[]}]}", limits: limits))
        #expect(JSONFormatter.isValid("{\"a\":[{\"b\":1}]}", limits: limits))
    }

    @Test("JSONL: depth is per line and reported with the document line")
    func jsonlDepth() throws {
        let ok = String(repeating: "[", count: 512) + String(repeating: "]", count: 512)
        let deep = String(repeating: "[", count: 513) + String(repeating: "]", count: 513)
        _ = try JSONFormatter.formatJSONL(ok + "\n" + ok)
        #expect(limitError { try JSONFormatter.formatJSONL("{}\n\n" + ok + "\r\n" + deep) } == .nestingTooDeep(line: 4, limit: 512))
    }

    @Test("output limit: exact boundary passes, one byte less throws outputTooLarge")
    func outputBoundary() throws {
        // "[1]" (3 bytes) pretty-prints to "[\n  1\n]" (7 bytes).
        let exact = FormatLimits(maxDepth: 512, outputFactor: 1, outputSlackBytes: 4)
        #expect(try JSONFormatter.prettyPrint("[1]", limits: exact) == "[\n  1\n]")
        let short = FormatLimits(maxDepth: 512, outputFactor: 1, outputSlackBytes: 3)
        #expect(limitError { try JSONFormatter.prettyPrint("[1]", limits: short) } == .outputTooLarge(limitBytes: 6))
        // isValid does not size output.
        #expect(JSONFormatter.isValid("[1]", limits: short))
    }

    @Test("output limit applies to the whole JSONL result, separators included")
    func jsonlOutputLimit() throws {
        let input = "[1 ]\n[2 ]\n[3 ]"  // 14 bytes in, "[1]\n[2]\n[3]" 11 bytes out
        let exact = FormatLimits(maxDepth: 512, outputFactor: 0, outputSlackBytes: 11)
        #expect(try JSONFormatter.formatJSONL(input, limits: exact) == "[1]\n[2]\n[3]")
        let short = FormatLimits(maxDepth: 512, outputFactor: 0, outputSlackBytes: 10)
        #expect(limitError { try JSONFormatter.formatJSONL(input, limits: short) } == .outputTooLarge(limitBytes: 10))
    }

    @Test("standard limits: 400 levels deep with many small scalars inside throws outputTooLarge")
    func standardOutputLimit() {
        let input = String(repeating: "[", count: 400) + Array(repeating: "1", count: 2_000).joined(separator: ",")
            + String(repeating: "]", count: 400)
        let limit = FormatLimits.standard.maxOutputBytes(forInputBytes: input.utf8.count)
        #expect(limitError { try JSONFormatter.prettyPrint(input) } == .outputTooLarge(limitBytes: limit))
        #expect(JSONFormatter.isValid(input))
        // Compact JSONL output fits easily.
        #expect(throws: Never.self) { _ = try JSONFormatter.formatJSONL(input) }
    }

    @Test("huge indent widths fail with outputTooLarge instead of overflowing")
    func hugeIndentWidth() {
        #expect(limitError { try JSONFormatter.prettyPrint("[[1]]", indentWidth: .max) } != nil)
        #expect(limitError { try JSONFormatter.prettyPrint("[[1]]", indentWidth: 1 << 40) } != nil)
    }
}

@Suite("JSONFormatter rewrite — scale and content")
struct JSONFormatterScaleTests {

    @Test("a 1 MB string value is copied through unchanged")
    func longString() throws {
        let body = String(repeating: "abcdé中😀\\n", count: 1_000_000 / 18)
        let input = "{\"s\":\"\(body)\"}"
        #expect(try JSONFormatter.prettyPrint(input) == "{\n  \"s\": \"\(body)\"\n}")
        #expect(try JSONFormatter.formatJSONL(input) == input)
    }

    @Test("dense tokens: 100 000 small values match the legacy implementation")
    func denseTokens() throws {
        let items = (0..<100_000).map { i in i % 3 == 0 ? "\(i)" : i % 3 == 1 ? "\"s\(i)\"" : "true" }
        let input = "[" + items.joined(separator: ",") + "]"
        #expect(try JSONFormatter.prettyPrint(input, indentWidth: 4) == LegacyJSONFormatter.prettyPrint(input, indentWidth: 4))
        #expect(try JSONFormatter.formatJSONL(input) == input)
    }

    @Test("multi-byte, surrogate-pair and escaped text round-trips byte for byte")
    func multiByte() throws {
        let input = "{\"キー\":\"値 😀🇯🇵👩🏽‍💻 \\ud83d\\ude00 \\\" \\\\ \\/ \\b\\f\\n\\r\\t \\u00e9 e\u{301} 한국어\"}"
        #expect(try JSONFormatter.prettyPrint(input) == LegacyJSONFormatter.prettyPrint(input))
        #expect(try JSONFormatter.prettyPrint(input).utf8.elementsEqual(LegacyJSONFormatter.prettyPrint(input).utf8))
    }

    @Test("empty and whitespace-only input behave as before")
    func emptyInput() {
        for doc in ["", "   ", "\n\n", "\t\r\n"] {
            #expect(outcome { try JSONFormatter.prettyPrint(doc) }
                == .syntax(JSONFormatError(line: 1, message: "unexpected end of input, expected a value")))
            #expect(outcome { try JSONFormatter.formatJSONL(doc) } == .output(""))
            #expect(!JSONFormatter.isValid(doc))
        }
    }

    @Test("negative indent width is treated as zero")
    func negativeIndent() throws {
        #expect(try JSONFormatter.prettyPrint("[1]", indentWidth: -3) == "[\n1\n]")
    }
}
