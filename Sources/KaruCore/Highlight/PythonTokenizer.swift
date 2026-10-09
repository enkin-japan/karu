import Foundation

/// Streaming lexical state for Python strings and replacement fields. State is
/// transient per viewport pass; no per-line token cache or parser dependency.
enum PythonTokenizer {
    struct Frame {
        var quote: unichar = 0 // zero means replacement expression
        var width = 0
        var formatted = false
        var brackets: [unichar] = []
        var formatSpec = false
    }
    struct State { var frames: [Frame] = [] }

    private static let codeMarkers = CharacterSet(charactersIn: "\"'#")
    private static let singleMarkers = CharacterSet(charactersIn: "'\\\r\n")
    private static let doubleMarkers = CharacterSet(charactersIn: "\"\\\r\n")
    private static let fSingleMarkers = CharacterSet(charactersIn: "'\\{}\r\n")
    private static let fDoubleMarkers = CharacterSet(charactersIn: "\"\\{}\r\n")

    static func state(in text: NSString, before end: Int, language: LanguageDefinition,
                      from start: Int = 0, initial: State = State()) -> State {
        var state = initial
        _ = scan(text as String, language: language, state: &state, emit: false, limit: end, start: start)
        return state
    }

    static func scan(_ line: String, language: LanguageDefinition, state: inout State,
                     emit: Bool = true, limit: Int? = nil, start: Int = 0) -> [(range: NSRange, kind: TokenKind)] {
        let ns = line as NSString
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
                    add(i, i + top.width, .string); i += top.width; state.frames.removeLast(); continue
                }
                if c == 92, i + 1 < length, unit(i + 1) != 123, unit(i + 1) != 125 {
                    let count = unit(i + 1) == 13 && unit(i + 2) == 10 ? 3 : 2
                    add(i, i + count, .string); i += count; continue
                }
                if top.formatted, c == 123 {
                    if unit(i + 1) == 123 { add(i, i + 2, .string); i += 2; continue }
                    add(i, i + 1, .punctuation); i += 1
                    if state.frames.count < 64 { state.frames.append(Frame()) }
                    continue
                }
                if top.formatted, c == 125, unit(i + 1) == 125 {
                    add(i, i + 2, .string); i += 2; continue
                }
                add(i, i + 1, .string); i += 1; continue
            }
            let inExpression = state.frames.last?.quote == 0
            if inExpression, state.frames.last!.formatSpec {
                if c == 125 { add(i, i + 1, .punctuation); state.frames.removeLast() }
                else if c == 123, state.frames.count < 64 {
                    add(i, i + 1, .punctuation); state.frames.append(Frame())
                } else { add(i, i + 1, .string) }
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
                let prefix = ns.substring(with: NSRange(location: i, length: quoteAt - i)).lowercased()
                add(i, quoteAt + width, .string)
                if state.frames.count < 64 {
                    state.frames.append(Frame(quote: quote, width: width, formatted: prefix.contains("f")))
                }
                i = quoteAt + width; continue
            }
            if inExpression {
                let last = state.frames.count - 1
                if c == 125, state.frames[last].brackets.isEmpty {
                    add(i, i + 1, .punctuation); state.frames.removeLast(); i += 1; continue
                }
                if c == 58, state.frames[last].brackets.isEmpty, unit(i + 1) != 61 {
                    add(i, i + 1, .punctuation); state.frames[last].formatSpec = true; i += 1; continue
                }
                if c == 33, state.frames[last].brackets.isEmpty, [UInt16(115),114,97].contains(unit(i + 1)) {
                    add(i, i + 2, .punctuation); i += 2; continue
                }
                if [UInt16(40),91,123].contains(c) { state.frames[last].brackets.append(c) }
                if let open = state.frames[last].brackets.last,
                   (open == 40 && c == 41) || (open == 91 && c == 93) || (open == 123 && c == 125) {
                    state.frames[last].brackets.removeLast()
                }
            }
            if emit {
                let range = NSRange(location: i, length: length - i)
                if let token = language.rules.lazy.compactMap({ rule -> (NSRange, TokenKind)? in
                    guard rule.kind != .string && rule.kind != .comment,
                          let match = rule.regex.firstMatch(in: line, options: [.anchored, .withTransparentBounds, .withoutAnchoringBounds], range: range), match.range.length > 0 else { return nil }
                    return (match.range, rule.kind)
                }).first {
                    add(i, NSMaxRange(token.0), token.1); i = NSMaxRange(token.0); continue
                }
            }
            if identifier(c) {
                let start = i
                repeat { i += 1 } while i < length && identifier(unit(i))
                if inExpression { add(start, i, .symbolVariable) }
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
}
