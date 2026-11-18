import Foundation

/// Error thrown by ``JSONFormatter`` when the input text is not well-formed JSON.
public struct JSONFormatError: Error, Equatable {
    /// 1-based line number (in the original input) where the problem was detected.
    public let line: Int
    /// Human readable description of the problem.
    public let message: String

    public init(line: Int, message: String) {
        self.line = line
        self.message = message
    }
}

/// A dependency-free JSON / JSONL pretty printer.
///
/// This intentionally avoids `JSONSerialization` because that API does not
/// preserve key order and loses precision on large numeric literals. String
/// and number lexemes are copied through byte for byte.
///
/// Implementation (RELIABILITY-PLAN F7: bugs R04, N02, N03): one forward scan
/// over the input's UTF-8 bytes, no token array, no recursion. Open containers
/// live on an explicit stack bounded by ``FormatLimits/maxDepth``. Formatting
/// runs the same scan twice: the first pass validates and counts the output
/// bytes (throwing ``FormatLimitError`` before anything large is allocated),
/// the second writes straight into the result `String`'s storage. Peak memory
/// is therefore the input's UTF-8 (plus one native copy if the caller's string
/// is a bridged non-UTF-8 `NSString`) and the result.
///
/// The grammar is exactly that of the earlier `[Character]`-based tokenizer,
/// including its grapheme-cluster semantics: an ASCII character only counts as
/// structural when it is a cluster on its own (so `"` followed by a combining
/// mark does not close a string, `\r\n` is one line break, and a digit followed
/// by a combining mark still reads as a digit). Those cases are detected with a
/// cheap check on the neighbouring byte; only non-ASCII neighbours take the
/// slow path.
public enum JSONFormatter {

    /// Pretty-prints a single JSON document, re-indenting it with `indentWidth`
    /// spaces per nesting level (a negative width counts as 0).
    ///
    /// - Throws: ``JSONFormatError`` for malformed input, ``FormatLimitError``
    ///   when nesting exceeds `limits.maxDepth` or the result would exceed
    ///   `limits.maxOutputBytes(forInputBytes:)`.
    public static func prettyPrint(
        _ text: String,
        indentWidth: Int = 2,
        limits: FormatLimits = .standard
    ) throws -> String {
        var text = text
        let width = max(0, indentWidth)
        return try text.withUTF8 { input in
            let limit = limits.maxOutputBytes(forInputBytes: input.count)
            var counter = CountingOutput(indentWidth: width, limit: limit)
            try parseDocument(input, lo: 0, hi: input.count, firstLine: 1, pretty: true,
                              maxDepth: limits.maxDepth, into: &counter)
            return try makeString(byteCount: counter.count) { storage in
                var writer = WritingOutput(storage, indentWidth: width)
                try parseDocument(input, lo: 0, hi: input.count, firstLine: 1, pretty: true,
                                  maxDepth: limits.maxDepth, into: &writer)
                return writer.count
            }
        }
    }

    /// Formats a JSONL document: every non-empty line is parsed as an
    /// independent JSON value and rewritten as a single compact line. Blank
    /// lines are dropped, line order is preserved, and thrown errors report
    /// the original document line number.
    ///
    /// The depth limit applies to each line, the output limit to the whole
    /// result.
    public static func formatJSONL(_ text: String, limits: FormatLimits = .standard) throws -> String {
        var text = text
        return try text.withUTF8 { input in
            let limit = limits.maxOutputBytes(forInputBytes: input.count)
            var counter = CountingOutput(indentWidth: 0, limit: limit)
            try formatJSONLLines(input, maxDepth: limits.maxDepth, into: &counter)
            return try makeString(byteCount: counter.count) { storage in
                var writer = WritingOutput(storage, indentWidth: 0)
                try formatJSONLLines(input, maxDepth: limits.maxDepth, into: &writer)
                return writer.count
            }
        }
    }

    /// Whether `text` is one JSON document `prettyPrint` accepts, checked
    /// with the same grammar and depth limit but without producing (or
    /// sizing) any output.
    public static func isValid(_ text: String, limits: FormatLimits = .standard) -> Bool {
        var text = text
        return text.withUTF8 { input in
            var sink = DiscardingOutput()
            do {
                try parseDocument(input, lo: 0, hi: input.count, firstLine: 1, pretty: false,
                                  maxDepth: limits.maxDepth, into: &sink)
                return true
            } catch {
                return false
            }
        }
    }

    // MARK: - Result string

    private static func makeString(
        byteCount: Int,
        _ fill: (UnsafeMutableBufferPointer<UInt8>) throws -> Int
    ) rethrows -> String {
        guard byteCount > 0 else { return "" }
        return try String(unsafeUninitializedCapacity: byteCount) { storage in
            let written = try fill(storage)
            precondition(written == byteCount, "JSONFormatter: size pass and write pass disagree")
            return written
        }
    }

    // MARK: - JSONL

    private static func formatJSONLLines<Output: JSONOutput>(
        _ input: UnsafeBufferPointer<UInt8>,
        maxDepth: Int,
        into out: inout Output
    ) throws {
        let n = input.count
        var lineStart = 0
        var lineNumber = 0
        var wroteLine = false
        // Lines end at "\n", "\r\n" or a lone "\r" (each always a grapheme
        // cluster of its own, so this matches splitting on Characters).
        while true {
            var lineEnd = lineStart
            while lineEnd < n, input[lineEnd] != ASCII.lf, input[lineEnd] != ASCII.cr {
                lineEnd += 1
            }
            lineNumber += 1
            if !isBlank(input, lineStart, lineEnd) {
                if wroteLine { try out.append(ASCII.lf) }
                try parseDocument(input, lo: lineStart, hi: lineEnd, firstLine: lineNumber, pretty: false,
                                  maxDepth: maxDepth, into: &out)
                wroteLine = true
            }
            guard lineEnd < n else { return }
            let crlf = input[lineEnd] == ASCII.cr && lineEnd + 1 < n && input[lineEnd + 1] == ASCII.lf
            lineStart = lineEnd + (crlf ? 2 : 1)
        }
    }

    /// Mirrors `line.trimmingCharacters(in: .whitespaces).isEmpty`.
    private static func isBlank(_ input: UnsafeBufferPointer<UInt8>, _ lo: Int, _ hi: Int) -> Bool {
        var i = lo
        while i < hi {
            let b = input[i]
            if b < 0x80 {
                guard b == ASCII.space || b == ASCII.tab else { return false }
                i += 1
            } else {
                let scalar = decodeScalar(input, at: i)
                guard CharacterSet.whitespaces.contains(scalar) else { return false }
                i += utf8Length(lead: b)
            }
        }
        return true
    }

    // MARK: - Parser (explicit stack, no recursion)

    private struct Frame {
        let isObject: Bool
        let openLine: Int
    }

    private enum ParseState {
        case value
        case key
        case afterValue
    }

    /// Parses (and, through `out`, re-lays out) the single JSON value in
    /// `input[lo..<hi]`. The control flow and every error mirror the earlier
    /// recursive-descent renderer; the only difference is that structure is
    /// checked while scanning, so for inputs with several errors an earlier
    /// one may be reported.
    private static func parseDocument<Output: JSONOutput>(
        _ input: UnsafeBufferPointer<UInt8>,
        lo: Int,
        hi: Int,
        firstLine: Int,
        pretty: Bool,
        maxDepth: Int,
        into out: inout Output
    ) throws {
        var lexer = Lexer(input: input, pos: lo, end: hi, line: firstLine)
        var stack: [Frame] = []
        var pending: Token?
        var state = ParseState.value

        while true {
            switch state {
            case .value:
                let token: Token
                if let held = pending { token = held; pending = nil } else { token = try lexer.next() }
                switch token.kind {
                case .eof:
                    throw JSONFormatError(line: lexer.lastTokenLine ?? firstLine,
                                          message: "unexpected end of input, expected a value")
                case .leftBrace, .leftBracket:
                    let isObject = token.kind == .leftBrace
                    if stack.count >= maxDepth {
                        throw FormatLimitError.nestingTooDeep(line: token.line, limit: maxDepth)
                    }
                    let next = try lexer.next()
                    if next.kind == (isObject ? .rightBrace : .rightBracket) {
                        try out.append(isObject ? ASCII.leftBrace : ASCII.leftBracket,
                                       isObject ? ASCII.rightBrace : ASCII.rightBracket)
                        state = .afterValue
                        continue
                    }
                    if next.kind == .eof {
                        throw JSONFormatError(line: token.line, message: unclosedMessage(isObject: isObject))
                    }
                    stack.append(Frame(isObject: isObject, openLine: token.line))
                    try out.append(isObject ? ASCII.leftBrace : ASCII.leftBracket)
                    pending = next
                    if isObject {
                        state = .key
                    } else {
                        if pretty { try out.newline(indentLevel: stack.count) }
                        state = .value
                    }
                case .string, .number, .literal:
                    try out.append(input, token.start, token.end)
                    state = .afterValue
                default:
                    throw JSONFormatError(line: token.line, message: "unexpected token, expected a value")
                }

            case .key:
                let openLine = stack[stack.count - 1].openLine
                let key: Token
                if let held = pending { key = held; pending = nil } else { key = try lexer.next() }
                guard key.kind == .string else {
                    throw JSONFormatError(line: key.kind == .eof ? openLine : key.line,
                                          message: "expected string key in object")
                }
                if pretty { try out.newline(indentLevel: stack.count) }
                try out.append(input, key.start, key.end)
                let colon = try lexer.next()
                guard colon.kind == .colon else {
                    throw JSONFormatError(line: colon.kind == .eof ? openLine : colon.line,
                                          message: "expected ':' after object key")
                }
                if pretty {
                    try out.append(ASCII.colon, ASCII.space)
                } else {
                    try out.append(ASCII.colon)
                }
                state = .value

            case .afterValue:
                let token = try lexer.next()
                guard let top = stack.last else {
                    if token.kind != .eof {
                        throw JSONFormatError(line: token.line, message: "unexpected token after top-level JSON value")
                    }
                    return
                }
                switch token.kind {
                case .eof:
                    throw JSONFormatError(line: top.openLine, message: unclosedMessage(isObject: top.isObject))
                case .comma:
                    try out.append(ASCII.comma)
                    if top.isObject {
                        state = .key
                    } else {
                        if pretty { try out.newline(indentLevel: stack.count) }
                        state = .value
                    }
                case .rightBrace where top.isObject, .rightBracket where !top.isObject:
                    stack.removeLast()
                    if pretty { try out.newline(indentLevel: stack.count) }
                    try out.append(top.isObject ? ASCII.rightBrace : ASCII.rightBracket)
                    state = .afterValue
                default:
                    throw JSONFormatError(
                        line: token.line,
                        message: top.isObject ? "expected ',' or '}' in object" : "expected ',' or ']' in array")
                }
            }
        }
    }

    private static func unclosedMessage(isObject: Bool) -> String {
        isObject ? "unclosed object, missing '}'" : "unclosed array, missing ']'"
    }

    // MARK: - Tokens

    private enum TokenKind {
        case leftBrace
        case rightBrace
        case leftBracket
        case rightBracket
        case colon
        case comma
        case string
        case number
        case literal
        case eof
    }

    /// A token is a byte range of the input; nothing is copied.
    private struct Token {
        let kind: TokenKind
        let start: Int
        let end: Int
        let line: Int
    }

    // MARK: - Lexer

    private static let keywords: [[UInt8]] = [Array("true".utf8), Array("false".utf8), Array("null".utf8)]

    /// Pulls tokens on demand from `input[pos..<end]`. Positions it stops at
    /// are always grapheme-cluster boundaries, which is what lets it reproduce
    /// the `Character`-based rules with byte comparisons.
    private struct Lexer {
        let input: UnsafeBufferPointer<UInt8>
        var pos: Int
        let end: Int
        var line: Int
        /// Line of the most recent token (the old `tokens.last?.line`).
        var lastTokenLine: Int?

        init(input: UnsafeBufferPointer<UInt8>, pos: Int, end: Int, line: Int) {
            self.input = input
            self.pos = pos
            self.end = end
            self.line = line
        }

        mutating func next() throws -> Token {
            while pos < end {
                let b = input[pos]
                if b == ASCII.cr {
                    // "\r" and "\r\n" are each one Character and one line break.
                    line += 1
                    pos += (pos + 1 < end && input[pos + 1] == ASCII.lf) ? 2 : 1
                    continue
                }
                if b >= 0x80 || joinsNext(pos) {
                    return try complexCluster()
                }
                switch b {
                case ASCII.space, ASCII.tab:
                    pos += 1
                case ASCII.lf:
                    line += 1
                    pos += 1
                case ASCII.leftBrace: return single(.leftBrace)
                case ASCII.rightBrace: return single(.rightBrace)
                case ASCII.leftBracket: return single(.leftBracket)
                case ASCII.rightBracket: return single(.rightBracket)
                case ASCII.colon: return single(.colon)
                case ASCII.comma: return single(.comma)
                case ASCII.quote:
                    return try string()
                case UInt8(ascii: "t"), UInt8(ascii: "f"), UInt8(ascii: "n"):
                    guard let length = keywordLength() else {
                        throw unexpectedCharacter(Character(Unicode.Scalar(b)))
                    }
                    return token(.literal, length: length)
                case ASCII.minus, ASCII.zero...ASCII.nine:
                    return try number()
                default:
                    throw unexpectedCharacter(Character(Unicode.Scalar(b)))
                }
            }
            return Token(kind: .eof, start: pos, end: pos, line: line)
        }

        private mutating func single(_ kind: TokenKind) -> Token {
            token(kind, length: 1)
        }

        private mutating func token(_ kind: TokenKind, length: Int) -> Token {
            let result = Token(kind: kind, start: pos, end: pos + length, line: line)
            lastTokenLine = line
            pos += length
            return result
        }

        private func unexpectedCharacter(_ c: Character) -> JSONFormatError {
            JSONFormatError(line: line, message: "unexpected character '\(c)'")
        }

        /// A cluster that is not a lone ASCII scalar. The old tokenizer only
        /// accepted such a Character through its `"0"..."9"` case (a digit
        /// followed by combining marks); everything else is unexpected.
        private mutating func complexCluster() throws -> Token {
            let (c, _) = JSONFormatter.character(input, at: pos, end: end)
            if ("0"..."9").contains(c) {
                return try number()
            }
            throw unexpectedCharacter(c)
        }

        // MARK: Grapheme helpers

        /// Whether the ASCII scalar at `i` forms one cluster with the scalar
        /// after it (only possible when that one is non-ASCII: a combining
        /// mark, ZWJ or spacing mark). `\r\n` is handled by the callers.
        @inline(__always)
        func joinsNext(_ i: Int) -> Bool {
            let j = i + 1
            guard j < end, input[j] >= 0x80 else { return false }
            return JSONFormatter.pairJoins(Unicode.Scalar(input[i]), JSONFormatter.decodeScalar(input, at: j))
        }

        /// Whether the ASCII scalar at `i` forms one cluster with the scalar
        /// before it (only possible when that one is a non-ASCII prepend).
        @inline(__always)
        func joinsPrevious(_ i: Int) -> Bool {
            guard input[i - 1] >= 0x80 else { return false }
            var s = i - 1
            while input[s] & 0xC0 == 0x80 { s -= 1 }
            return JSONFormatter.pairJoins(JSONFormatter.decodeScalar(input, at: s), Unicode.Scalar(input[i]))
        }

        /// Whether the cluster at boundary `i` is exactly the ASCII `scalar`.
        func clusterIs(_ i: Int, _ scalar: UInt8) -> Bool {
            guard i < end else { return false }
            let b = input[i]
            if b < 0x80 && b != ASCII.cr && !joinsNext(i) { return b == scalar }
            if b == ASCII.cr { return false }
            return JSONFormatter.character(input, at: i, end: end).0 == Character(Unicode.Scalar(scalar))
        }

        /// Byte length of the cluster at boundary `i` if the old `isDigit`
        /// (`c >= "0" && c <= "9"`) accepts it, else 0.
        func digitLength(_ i: Int) -> Int {
            guard i < end else { return 0 }
            let b = input[i]
            if b < 0x80 && !joinsNext(i) {
                // A lone ASCII scalar, or "\r\n", which is not a digit.
                return b >= ASCII.zero && b <= ASCII.nine ? 1 : 0
            }
            let (c, length) = JSONFormatter.character(input, at: i, end: end)
            return c >= "0" && c <= "9" ? length : 0
        }

        // MARK: Lexemes

        private func keywordLength() -> Int? {
            for word in JSONFormatter.keywords where pos + word.count <= end {
                var matches = true
                for k in 0..<word.count where input[pos + k] != word[k] || (k > 0 && joinsNext(pos + k)) {
                    matches = false
                    break
                }
                if matches { return word.count }
            }
            return nil
        }

        private mutating func number() throws -> Token {
            var j = pos
            if clusterIs(j, ASCII.minus) {
                j += 1
            }
            var digit = digitLength(j)
            guard digit > 0 else {
                throw JSONFormatError(line: line, message: "invalid number literal")
            }
            while digit > 0 {
                j += digit
                digit = digitLength(j)
            }

            if clusterIs(j, ASCII.dot) {
                var k = j + 1
                digit = digitLength(k)
                guard digit > 0 else {
                    throw JSONFormatError(line: line, message: "invalid number literal: expected digit after '.'")
                }
                while digit > 0 {
                    k += digit
                    digit = digitLength(k)
                }
                j = k
            }

            if clusterIs(j, UInt8(ascii: "e")) || clusterIs(j, UInt8(ascii: "E")) {
                var k = j + 1
                if clusterIs(k, ASCII.plus) || clusterIs(k, ASCII.minus) {
                    k += 1
                }
                digit = digitLength(k)
                guard digit > 0 else {
                    throw JSONFormatError(line: line, message: "invalid number literal: expected digit in exponent")
                }
                while digit > 0 {
                    k += digit
                    digit = digitLength(k)
                }
                j = k
            }

            return token(.number, length: j - pos)
        }

        /// Scans the string literal whose opening quote is at `pos`. A `"` or
        /// `\` only acts as such when it is a cluster on its own; a lone "\n"
        /// (escaped or not) advances the line, "\r" and "\r\n" do not.
        private mutating func string() throws -> Token {
            let start = pos
            let startLine = line
            var linesConsumed = 0
            var i = start + 1

            while i < end {
                let b = input[i]
                switch b {
                case ASCII.quote:
                    i += 1
                    if !joinsPrevious(i - 1) && !joinsNext(i - 1) {
                        let result = Token(kind: .string, start: start, end: i, line: startLine)
                        lastTokenLine = startLine
                        pos = i
                        line = startLine + linesConsumed
                        return result
                    }
                case ASCII.backslash:
                    i += 1
                    if !joinsPrevious(i - 1) && !joinsNext(i - 1), i < end {
                        // The escape consumes the next Character. Skipping one
                        // scalar is equivalent: the rest of that cluster can
                        // only be marks, or an ASCII scalar glued to a prepend,
                        // which `joinsPrevious` then refuses as structural.
                        if input[i] == ASCII.lf { linesConsumed += 1 }
                        i += JSONFormatter.utf8Length(lead: input[i])
                    }
                case ASCII.lf:
                    if input[i - 1] != ASCII.cr { linesConsumed += 1 }
                    i += 1
                default:
                    i += 1
                }
            }

            throw JSONFormatError(line: startLine, message: "unterminated string literal")
        }
    }

    // MARK: - Unicode helpers

    @inline(__always)
    fileprivate static func utf8Length(lead: UInt8) -> Int {
        if lead < 0x80 { return 1 }
        if lead < 0xE0 { return 2 }
        if lead < 0xF0 { return 3 }
        return 4
    }

    /// Decodes the scalar whose lead byte is at `i` (the input is valid UTF-8).
    fileprivate static func decodeScalar(_ input: UnsafeBufferPointer<UInt8>, at i: Int) -> Unicode.Scalar {
        let b0 = UInt32(input[i])
        let value: UInt32
        if b0 < 0x80 {
            value = b0
        } else if b0 < 0xE0 {
            value = (b0 & 0x1F) << 6 | UInt32(input[i + 1] & 0x3F)
        } else if b0 < 0xF0 {
            value = (b0 & 0x0F) << 12 | UInt32(input[i + 1] & 0x3F) << 6 | UInt32(input[i + 2] & 0x3F)
        } else {
            value = (b0 & 0x07) << 18 | UInt32(input[i + 1] & 0x3F) << 12
                | UInt32(input[i + 2] & 0x3F) << 6 | UInt32(input[i + 3] & 0x3F)
        }
        return Unicode.Scalar(value) ?? "\u{FFFD}"
    }

    /// Scalars that never form a cluster with an adjacent ASCII scalar on
    /// either side: everything below the first combining mark (U+0300; the
    /// first prepend is U+0600), CJK ideographs and Hangul syllables. Only a
    /// fast exit; verified exhaustively by `JSONFormatterRewriteTests`.
    @inline(__always)
    static func neverJoinsASCII(_ value: UInt32) -> Bool {
        value < 0x300 || (0x3400...0x9FFF).contains(value) || (0xAC00...0xD7A3).contains(value)
    }

    /// Whether `a` and `b` (one of them ASCII) form a single grapheme
    /// cluster. With an ASCII side only pairwise rules apply (GB3, GB9,
    /// GB9a, GB9b), so the two-scalar string decides it exactly as the old
    /// `Array(text)` did. Rare path: only taken next to non-ASCII scalars.
    static func pairJoins(_ a: Unicode.Scalar, _ b: Unicode.Scalar) -> Bool {
        let other = a.isASCII ? b.value : a.value
        if neverJoinsASCII(other) { return false }
        var pair = ""
        pair.unicodeScalars.append(a)
        pair.unicodeScalars.append(b)
        return pair.count == 1
    }

    /// The grapheme cluster starting at boundary `i` and its UTF-8 length.
    /// Error and other rare paths only.
    fileprivate static func character(
        _ input: UnsafeBufferPointer<UInt8>,
        at i: Int,
        end: Int
    ) -> (Character, Int) {
        var window = min(16, end - i)
        while true {
            while i + window < end && input[i + window] & 0xC0 == 0x80 { window += 1 }
            let slice = UnsafeBufferPointer(rebasing: input[i..<(i + window)])
            let text = String(decoding: slice, as: UTF8.self)
            let c = text.first ?? "\u{FFFD}"
            let length = String(c).utf8.count
            // A break found before the window's end is final: cluster
            // boundaries depend only on what precedes them and the next scalar.
            if length < window || i + window >= end { return (c, length) }
            window = min(window * 2, end - i)
        }
    }
}

// MARK: - ASCII

private enum ASCII {
    static let tab = UInt8(ascii: "\t")
    static let lf = UInt8(ascii: "\n")
    static let cr = UInt8(ascii: "\r")
    static let space = UInt8(ascii: " ")
    static let quote = UInt8(ascii: "\"")
    static let plus = UInt8(ascii: "+")
    static let comma = UInt8(ascii: ",")
    static let minus = UInt8(ascii: "-")
    static let dot = UInt8(ascii: ".")
    static let zero = UInt8(ascii: "0")
    static let nine = UInt8(ascii: "9")
    static let colon = UInt8(ascii: ":")
    static let leftBracket = UInt8(ascii: "[")
    static let backslash = UInt8(ascii: "\\")
    static let rightBracket = UInt8(ascii: "]")
    static let leftBrace = UInt8(ascii: "{")
    static let rightBrace = UInt8(ascii: "}")
}

// MARK: - Output sinks

/// Where the parser sends the re-laid-out document. One implementation per
/// pass; generic specialisation keeps the calls inline.
private protocol JSONOutput {
    mutating func append(_ input: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) throws
    mutating func append(_ byte: UInt8) throws
    mutating func append(_ first: UInt8, _ second: UInt8) throws
    /// "\n" followed by `indentLevel` × indent width spaces.
    mutating func newline(indentLevel: Int) throws
}

/// Validation only: produces nothing.
private struct DiscardingOutput: JSONOutput {
    func append(_ input: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) {}
    func append(_ byte: UInt8) {}
    func append(_ first: UInt8, _ second: UInt8) {}
    func newline(indentLevel: Int) {}
}

/// Size pass: counts the result bytes and stops at the limit.
private struct CountingOutput: JSONOutput {
    let indentWidth: Int
    let limit: Int
    private(set) var count = 0

    init(indentWidth: Int, limit: Int) {
        self.indentWidth = indentWidth
        self.limit = limit
    }

    @inline(__always)
    private mutating func add(_ n: Int) throws {
        let (total, overflow) = count.addingReportingOverflow(n)
        guard !overflow, total <= limit else { throw FormatLimitError.outputTooLarge(limitBytes: limit) }
        count = total
    }

    mutating func append(_ input: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) throws {
        try add(end - start)
    }

    mutating func append(_ byte: UInt8) throws {
        try add(1)
    }

    mutating func append(_ first: UInt8, _ second: UInt8) throws {
        try add(2)
    }

    mutating func newline(indentLevel: Int) throws {
        let (spaces, overflow) = indentLevel.multipliedReportingOverflow(by: indentWidth)
        guard !overflow, spaces < Int.max else { throw FormatLimitError.outputTooLarge(limitBytes: limit) }
        try add(1 + spaces)
    }
}

/// Write pass: fills the result string's storage, sized by the counting pass.
private struct WritingOutput: JSONOutput {
    let storage: UnsafeMutableBufferPointer<UInt8>
    let indentWidth: Int
    private(set) var count = 0

    init(_ storage: UnsafeMutableBufferPointer<UInt8>, indentWidth: Int) {
        self.storage = storage
        self.indentWidth = indentWidth
    }

    @inline(__always)
    private mutating func reserve(_ n: Int) -> UnsafeMutablePointer<UInt8> {
        precondition(n <= storage.count - count, "JSONFormatter: write pass exceeded the counted size")
        let destination = storage.baseAddress! + count
        count += n
        return destination
    }

    mutating func append(_ input: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) {
        let n = end - start
        guard n > 0 else { return }
        reserve(n).initialize(from: input.baseAddress! + start, count: n)
    }

    mutating func append(_ byte: UInt8) {
        reserve(1).pointee = byte
    }

    mutating func append(_ first: UInt8, _ second: UInt8) {
        let destination = reserve(2)
        destination[0] = first
        destination[1] = second
    }

    mutating func newline(indentLevel: Int) {
        let spaces = indentLevel * indentWidth
        let destination = reserve(1 + spaces)
        destination.pointee = UInt8(ascii: "\n")
        (destination + 1).initialize(repeating: UInt8(ascii: " "), count: spaces)
    }
}
