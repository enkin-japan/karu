import Foundation

/// Streaming lexical state for Python strings and replacement fields. State is
/// transient per viewport pass apart from the sparse checkpoints the document
/// analysis keeps (`CheckpointStore`); no per-line token cache or parser
/// dependency. `State` is a small value (`Sendable`, `Equatable`) so it can be
/// stored in a checkpoint and compared in tests.
///
/// Token kinds (M17 T17.7, as VS Code's MagicPython grammar colours them in
/// the Modern themes): a string prefix is `.keyword`; a lowercase-`r` raw
/// string (`r`, `rb`, `br`) is a regular expression (`.regex`, with its
/// escapes, quantifiers, groups and classes split out, `regexUnit`); an `R`
/// or `rf` raw string is a plain `.string`; in other strings the escape
/// sequences Python defines are `.escape` (`\q` stays string text; bytes have
/// no `\u`, `\U`, `\N`), and in plain non-bytes strings `%s` / `{0}` format
/// placeholders are `.interpolationDelimiter`. In an f-string, `{` / `}`, the
/// `!r` conversion and the `:` format spec are `.interpolationDelimiter`,
/// `{{` / `}}` `.escape`; identifiers inside a field get no kind of their own
/// (the rules still colour keywords and built-ins there).
public enum PythonTokenizer {
    public struct Frame: Sendable, Equatable {
        var quote: unichar = 0 // zero means replacement expression
        var width = 0
        var formatted = false
        var brackets: [unichar] = []
        var formatSpec = false
        /// Raw string: a backslash only keeps the next character literal.
        var raw = false
        /// Raw string read as a regular expression (lowercase `r`, not `rf`).
        var regex = false
        /// Bytes literal: no `\u`, `\U`, `\N{…}` escapes, no placeholders.
        var bytes = false
    }
    public struct State: Sendable, Equatable {
        var frames: [Frame] = []
        public init() {}
    }

    private static let codeMarkers = CharacterSet(charactersIn: "\"'#")
    private static let singleMarkers = CharacterSet(charactersIn: "'\\\r\n")
    private static let doubleMarkers = CharacterSet(charactersIn: "\"\\\r\n")
    private static let fSingleMarkers = CharacterSet(charactersIn: "'\\{}\r\n")
    private static let fDoubleMarkers = CharacterSet(charactersIn: "\"\\{}\r\n")

    static func state(in text: NSString, before end: Int, language: LanguageDefinition,
                      from start: Int = 0, initial: State = State()) -> State {
        var state = initial
        // Straight on the NSString: bridging a mutable string (the text
        // storage's) to `String` would copy the whole document.
        _ = scan(text, subject: nil, language: language, state: &state, emit: false, limit: end, start: start)
        return state
    }

    static func scan(_ line: String, language: LanguageDefinition, state: inout State,
                     emit: Bool = true, limit: Int? = nil, start: Int = 0) -> [(range: NSRange, kind: TokenKind)] {
        scan(line as NSString, subject: line, language: language, state: &state, emit: emit, limit: limit, start: start)
    }

    /// `subject`: the same text as a `String` for the rules; needed only when
    /// `emit` is true.
    // swiftlint:disable:next function_body_length cyclomatic_complexity function_parameter_count
    private static func scan(_ ns: NSString, subject line: String?, language: LanguageDefinition,
                             state: inout State, emit: Bool, limit: Int?,
                             start: Int) -> [(range: NSRange, kind: TokenKind)] {
        let length = min(limit ?? ns.length, ns.length)
        var result: [(range: NSRange, kind: TokenKind)] = []
        var i = min(start, length)
        func unit(_ offset: Int) -> unichar { offset < length ? ns.character(at: offset) : 0 }
        func add(_ start: Int, _ end: Int, _ kind: TokenKind) {
            guard emit, end > start else { return }
            if let last = result.last, last.kind == kind, NSMaxRange(last.range) == start {
                result[result.count - 1].range.length += end - start
            } else { result.append((NSRange(location: start, length: end - start), kind)) }
        }
        func identifier(_ u: unichar) -> Bool {
            u == 95 || (48...57).contains(u) || (65...90).contains(u) || (97...122).contains(u)
                || u >= 128
        }
        while i < length {
            if !emit, state.frames.isEmpty {
                let next = ns.rangeOfCharacter(from: codeMarkers, options: [], range: NSRange(location: i, length: length - i))
                guard next.location != NSNotFound else { break }
                i = next.location
                if unit(i) != 35 {
                    var start = i
                    while start > 0, i - start < 2, [UInt16(114),82,98,66,102,70,117,85].contains(unit(start - 1)) { start -= 1 }
                    if start == 0 || !identifier(unit(start - 1)) { i = start }
                }
            }
            let c = unit(i)
            if let top = state.frames.last, top.quote != 0 {
                let content: TokenKind = top.regex ? .regex : .string
                if top.width == 1, c == 10 || c == 13 {
                    state.frames.removeLast(); i += 1; continue
                }
                if !emit {
                    let markers = top.quote == 39
                        ? (top.formatted ? fSingleMarkers : singleMarkers)
                        : (top.formatted ? fDoubleMarkers : doubleMarkers)
                    let next = ns.rangeOfCharacter(from: markers, options: [], range: NSRange(location: i, length: length - i))
                    guard next.location != NSNotFound else { break }
                    if next.location > i { i = next.location; continue }
                }
                if c == top.quote, (0..<top.width).allSatisfy({ unit(i + $0) == top.quote }) {
                    add(i, i + top.width, content); i += top.width; state.frames.removeLast(); continue
                }
                if c == 92, i + 1 < length, unit(i + 1) != 123, unit(i + 1) != 125 {
                    let count = unit(i + 1) == 13 && unit(i + 2) == 10 ? 3 : 2
                    if !emit || top.raw && !top.regex {
                        add(i, i + count, content); i += count; continue
                    }
                    let (end, kind) = top.regex
                        ? regexEscape(at: i, count: count, unit: unit)
                        : escape(at: i, count: count, bytes: top.bytes, formatted: top.formatted,
                                 length: length, unit: unit)
                    add(i, end, kind); i = end; continue
                }
                if top.formatted, c == 123 {
                    if unit(i + 1) == 123 { add(i, i + 2, .escape); i += 2; continue }
                    add(i, i + 1, .interpolationDelimiter); i += 1
                    if state.frames.count < 64 { state.frames.append(Frame()) }
                    continue
                }
                if top.formatted, c == 125, unit(i + 1) == 125 {
                    add(i, i + 2, .escape); i += 2; continue
                }
                if emit, top.regex {
                    let (end, kind) = regexUnit(at: i, length: length, unit: unit)
                    add(i, end, kind); i = end; continue
                }
                if emit, !top.raw, !top.formatted, !top.bytes, c == 37 || c == 123,
                   let end = placeholderEnd(at: i, length: length, unit: unit) {
                    add(i, end, .interpolationDelimiter); i = end; continue
                }
                add(i, i + 1, content); i += 1; continue
            }
            let inExpression = state.frames.last?.quote == 0
            if inExpression, state.frames.last!.formatSpec {
                if c == 125 { add(i, i + 1, .interpolationDelimiter); state.frames.removeLast() }
                else if c == 123, state.frames.count < 64 {
                    add(i, i + 1, .interpolationDelimiter); state.frames.append(Frame())
                } else { add(i, i + 1, .interpolationDelimiter) }
                i += 1; continue
            }
            if c == 35 {
                let end = min(NSMaxRange(ns.lineRange(for: NSRange(location: i, length: 0))), length)
                add(i, end, .comment); i = end; continue
            }
            // Recognize plain, raw, bytes and f-string prefixes only at a word boundary.
            var quoteAt = i
            if i == 0 || !identifier(unit(i - 1)) {
                while quoteAt < min(i + 2, length), [UInt16(114),82,98,66,102,70,117,85].contains(unit(quoteAt)) { quoteAt += 1 }
            }
            if unit(quoteAt) != 34 && unit(quoteAt) != 39 { quoteAt = i }
            if unit(quoteAt) == 34 || unit(quoteAt) == 39 {
                let quote = unit(quoteAt)
                let width = unit(quoteAt + 1) == quote && unit(quoteAt + 2) == quote ? 3 : 1
                let rawPrefix = ns.substring(with: NSRange(location: i, length: quoteAt - i))
                let prefix = rawPrefix.lowercased()
                let formatted = prefix.contains("f")
                let raw = prefix.contains("r")
                let regex = raw && !formatted && rawPrefix.contains("r")
                add(i, quoteAt, .keyword)
                add(quoteAt, quoteAt + width, regex ? .regex : .string)
                if state.frames.count < 64 {
                    state.frames.append(Frame(quote: quote, width: width, formatted: formatted,
                                              raw: raw, regex: regex, bytes: prefix.contains("b")))
                }
                i = quoteAt + width; continue
            }
            if inExpression {
                let last = state.frames.count - 1
                if c == 125, state.frames[last].brackets.isEmpty {
                    add(i, i + 1, .interpolationDelimiter); state.frames.removeLast(); i += 1; continue
                }
                if c == 58, state.frames[last].brackets.isEmpty, unit(i + 1) != 61 {
                    add(i, i + 1, .interpolationDelimiter); state.frames[last].formatSpec = true; i += 1; continue
                }
                if c == 33, state.frames[last].brackets.isEmpty, [UInt16(115),114,97].contains(unit(i + 1)) {
                    add(i, i + 2, .interpolationDelimiter); i += 2; continue
                }
                if [UInt16(40),91,123].contains(c) { state.frames[last].brackets.append(c) }
                if let open = state.frames[last].brackets.last,
                   (open == 40 && c == 41) || (open == 91 && c == 93) || (open == 123 && c == 125) {
                    state.frames[last].brackets.removeLast()
                }
            }
            if emit, let line,
               let token = language.codeRuleSet.match(in: line, range: NSRange(location: i, length: length - i)) {
                add(i, NSMaxRange(token.range), token.kind); i = NSMaxRange(token.range); continue
            }
            if identifier(c) {
                repeat { i += 1 } while i < length && identifier(unit(i))
            } else {
                if inExpression, c != 32 && c != 9 && c != 10 && c != 13 { add(i, i + 1, .punctuation) }
                i += 1
            }
        }
        // An unfinished ordinary quote cannot swallow all subsequent lines.
        if let top = state.frames.last, top.quote != 0, top.width == 1,
           !(length >= 2 && unit(length - 2) == 92 && unit(length - 1) == 10),
           !(length >= 3 && unit(length - 3) == 92 && unit(length - 2) == 13 && unit(length - 1) == 10) {
            state.frames.removeLast()
        }
        return result
    }

    private static func isHex(_ u: unichar) -> Bool {
        (48...57).contains(u) || (65...70).contains(u) || (97...102).contains(u)
    }

    /// An escape at `i` (a backslash; `count` units with a CRLF continuation)
    /// in a non-raw string: its end and kind — `.escape` for the sequences
    /// Python defines, `.string` for any other `\c`. Never extends over a
    /// quote, a line break or (in an f-string) a brace, so the emitting pass
    /// and the state-only pass agree on the state.
    private static func escape(at i: Int, count: Int, bytes: Bool, formatted: Bool, length: Int,
                               unit: (Int) -> unichar) -> (Int, TokenKind) {
        let n = unit(i + 1)
        func hexEnd(_ digits: Int) -> Int? {
            for k in 0..<digits where i + 2 + k >= length || !isHex(unit(i + 2 + k)) { return nil }
            return i + 2 + digits
        }
        switch n {
        case 10, 13, 92, 39, 34, 97, 98, 102, 110, 114, 116, 118:   // newline \ ' " a b f n r t v
            return (i + count, .escape)
        case 48...55:                                               // octal
            var e = i + 2
            while e < length, e - i < 4, (48...55).contains(unit(e)) { e += 1 }
            return (e, .escape)
        case 120:                                                   // x
            if let e = hexEnd(2) { return (e, .escape) }
        case 117 where !bytes:                                      // u
            if let e = hexEnd(4) { return (e, .escape) }
        case 85 where !bytes:                                       // U
            if let e = hexEnd(8) { return (e, .escape) }
        case 78 where !bytes && !formatted:                         // N{…}
            if unit(i + 2) == 123 {
                var e = i + 3
                while e < length, e - i < 96, ![UInt16(125), 10, 13, 34, 39].contains(unit(e)) { e += 1 }
                if e < length, unit(e) == 125, e > i + 3 { return (e + 1, .escape) }
            }
        default:
            break
        }
        return (i + count, .string)
    }

    /// An escape at `i` inside a regex string: `\d`-style class escapes are
    /// `.regex`, any other escape (`\.`, `\t`, `\x41`) `.escape`.
    private static func regexEscape(at i: Int, count: Int, unit: (Int) -> unichar) -> (Int, TokenKind) {
        let n = unit(i + 1)
        if [UInt16(100), 68, 119, 87, 115, 83, 98, 66, 65, 90].contains(n) { return (i + 2, .regex) }   // dDwWsSbBAZ
        if n == 120, isHex(unit(i + 2)), isHex(unit(i + 3)) { return (i + 4, .escape) }
        return (i + count, .escape)
    }

    /// One regex token at `i` (not a backslash or quote): quantifiers
    /// (`*`, `+`, `?`, `{m,n}`) `.escape`, group and class brackets
    /// `.string`, a named group's `?P<name>` `.keyword`, the rest `.regex`.
    private static func regexUnit(at i: Int, length: Int, unit: (Int) -> unichar) -> (Int, TokenKind) {
        let c = unit(i)
        switch c {
        case 42, 43:                                                // * +
            return (i + 1, .escape)
        case 123:                                                   // {m,n}
            var e = i + 1
            var digits = 0
            while e < length, (48...57).contains(unit(e)) || unit(e) == 44 {
                if unit(e) != 44 { digits += 1 }
                e += 1
            }
            if digits > 0, e < length, unit(e) == 125 { return (e + 1, .escape) }
        case 40:                                                    // ( and group syntax
            guard unit(i + 1) == 63 else { return (i + 1, .string) }
            if unit(i + 2) == 80, unit(i + 3) == 60 {               // (?P<name>: `(` only
                return (i + 1, .string)
            }
            var e = i + 2
            if unit(e) == 60 { e += 1 }                             // (?<= (?<!
            if [UInt16(58), 61, 33].contains(unit(e)) { return (e + 1, .string) }   // : = !
            return (i + 1, .string)
        case 63:                                                    // ? (or ?P<name>)
            if unit(i + 1) == 80, unit(i + 2) == 60 {
                var e = i + 3
                while e < length, e - i < 64, ![UInt16(62), 10, 13, 34, 39].contains(unit(e)) { e += 1 }
                if e < length, unit(e) == 62 { return (e + 1, .keyword) }
            }
            return (i + 1, .escape)
        case 41, 91, 93:                                            // ) [ ]
            return (i + 1, .string)
        default:
            break
        }
        return (i + 1, .regex)
    }

    /// End of a `%`-format or `{}`-format placeholder at `i` in a plain
    /// string (`%s`, `%-5.2f`, `%(name)s`, `{0}`, `{name!r:>10}`), or nil.
    private static func placeholderEnd(at i: Int, length: Int, unit: (Int) -> unichar) -> Int? {
        let c = unit(i)
        if c == 37 {                                                // %
            var e = i + 1
            if e < length, unit(e) == 40 {                          // %(name)
                while e < length, e - i < 64, ![UInt16(41), 10, 13, 34, 39].contains(unit(e)) { e += 1 }
                guard e < length, unit(e) == 41 else { return nil }
                e += 1
            }
            while e < length, [UInt16(45), 43, 32, 35, 48].contains(unit(e)) { e += 1 }   // flags
            while e < length, (48...57).contains(unit(e)) || unit(e) == 42 { e += 1 }   // width
            if e < length, unit(e) == 46 {                          // .precision
                e += 1
                while e < length, (48...57).contains(unit(e)) || unit(e) == 42 { e += 1 }
            }
            guard e < length else { return nil }
            let conversion = unit(e)
            let conversions: [UInt16] = Array("diouxXeEfFgGcrsa%".utf16)
            return conversions.contains(conversion) ? e + 1 : nil
        }
        // {…}: an identifier, digits, `.` / `[…]` access, `!r`, `:spec`.
        var e = i + 1
        while e < length, e - i < 64 {
            let u = unit(e)
            if u == 125 { return e > i ? e + 1 : nil }
            if u == 123 || u == 10 || u == 13 || u == 34 || u == 39 || u == 32 { return nil }
            e += 1
        }
        return nil
    }
}
