import Foundation

// M17 T17.11d — reading code tokens of the live text for the statically
// typed brace languages (Swift, Go, Rust, Java, C#, C, C++). These
// languages have no parser (`SyntaxDialect` excludes them): inference reads
// the declaration snapshot (`DeclarationScan`: declarations, kinds, scopes)
// plus the generic lexical scanner's code tokens (`DeclTokenizer`, the same
// tokens `BraceDeclarationWalker` reads) around the declarations it needs.

/// Code tokens of short live-text ranges, read on demand.
///
/// A read starts at a line start. When the text on that line before the
/// anchor (a position known to be code: a declaration name, a scope start,
/// the access operator) holds nothing that could close a string or comment
/// opened on an earlier line (`"`, `'`, `` ` ``, `*/`), the line start is in
/// code and the scan starts from the initial lexical state; otherwise the
/// state is resumed from the analysis's context checkpoints (`resume`), as
/// the candidate engine's window scan does.
final class BraceTokenReader {
    let text: NSString
    let language: BraceLanguage
    let scanner: LexicalScanner
    /// The scanner state at a line start (accurate, from checkpoints).
    private let resume: (Int) -> (position: Int, state: LexicalScanState)
    /// Tokens read (statistics).
    private(set) var tokensRead = 0
    private(set) var resumed = 0

    init(text: NSString, language: BraceLanguage, scanner: LexicalScanner,
         resume: @escaping (Int) -> (position: Int, state: LexicalScanState)) {
        self.text = text
        self.language = language
        self.scanner = scanner
        self.resume = resume
    }

    func lineStart(of offset: Int) -> Int {
        var k = min(max(0, offset), text.length)
        while k > 0 {
            let u = text.character(at: k - 1)
            if u == 10 || u == 13 { break }
            k -= 1
        }
        return k
    }

    func lineEnd(of offset: Int) -> Int {
        var k = min(max(0, offset), text.length)
        let n = text.length
        while k < n {
            let u = text.character(at: k)
            if u == 10 || u == 13 { break }
            k += 1
        }
        return k
    }

    /// Whether `[from, to)` could end a string or comment begun earlier.
    private func isRisky(from: Int, to: Int) -> Bool {
        var i = from
        var previous: unichar = 0
        while i < to {
            let u = text.character(at: i)
            if u == 34 || u == 39 || u == 96 { return true }          // " ' `
            if u == 47, previous == 42 { return true }                 // */
            previous = u
            i += 1
        }
        return false
    }

    /// The code tokens of `[lineStart(anchor), to)`; `anchor` must be a code
    /// position. Tokens past `to` are not read.
    func tokens(anchor: Int, to: Int) -> [DeclToken] {
        let start = lineStart(of: anchor)
        return tokens(lineStart: start, anchor: anchor, to: to)
    }

    /// As `tokens(anchor:to:)`, from an explicit line start at or before the anchor.
    func tokens(lineStart start: Int, anchor: Int, to: Int) -> [DeclToken] {
        let end = min(max(to, anchor), text.length)
        guard end > start else { return [] }
        var state = LexicalScanState()
        var from = start
        if isRisky(from: start, to: min(anchor, end)) {
            let resumed = resume(start)
            resumedCount()
            if resumed.position <= start {
                state = resumed.state
                if resumed.position < start { scanner.advance(text, from: resumed.position, to: start, state: &state) }
            }
            from = start
        }
        var segments: [(NSRange, LexicalSegment)] = []
        scanner.segments(text, from: from, to: end, state: &state) { range, segment in
            segments.append((range, segment))
        }
        var tokenizer = DeclTokenizer(brace: language)
        var buffer = DeclTokenBuffer()
        tokenizer.tokenize(text, from: from, to: end, segments: segments, into: &buffer)
        var out: [DeclToken] = []
        out.reserveCapacity(buffer.count)
        while let t = buffer.peek() {
            buffer.consume()
            if t.end <= end { out.append(t) }
        }
        tokensRead += out.count
        return out
    }

    private func resumedCount() { resumed += 1 }

    // MARK: - Token helpers

    func string(_ t: DeclToken) -> String {
        text.substring(with: NSRange(location: t.start, length: t.end - t.start))
    }

    func string(from: Int, to: Int) -> String {
        guard to > from else { return "" }
        return text.substring(with: NSRange(location: from, length: to - from))
    }

    /// `t` spells `word` (no allocation).
    func spells(_ t: DeclToken, _ word: String) -> Bool {
        let units = word.utf16
        guard t.end - t.start == units.count else { return false }
        var i = t.start
        for u in units {
            if text.character(at: i) != u { return false }
            i += 1
        }
        return true
    }

    /// The source of `[from, to)` with runs of white space (line breaks
    /// included) collapsed to one space.
    func compact(from: Int, to: Int) -> String {
        guard to > from else { return "" }
        var out = ""
        var space = false
        var i = from
        while i < to {
            let u = text.character(at: i)
            if u == 32 || u == 9 || u == 10 || u == 13 {
                space = true
            } else {
                if space, !out.isEmpty { out.append(" ") }
                space = false
                if let scalar = Unicode.Scalar(u) {
                    out.unicodeScalars.append(scalar)
                } else {
                    // A surrogate pair: copy it whole.
                    let pair = text.rangeOfComposedCharacterSequence(at: i)
                    out += text.substring(with: pair)
                    i = NSMaxRange(pair)
                    continue
                }
            }
            i += 1
        }
        return out
    }
}

/// Bracket helpers over a token array.
enum BraceTokens {
    static func isOpener(_ k: DeclTokenKind) -> Bool {
        k == .lparen || k == .lbracket || k == .lbrace || k == .interpOpen
    }

    static func isCloser(_ k: DeclTokenKind) -> Bool {
        k == .rparen || k == .rbracket || k == .rbrace || k == .interpClose
    }

    /// The index of the closer matching the opener at `i` (nil: unclosed).
    static func matching(_ tokens: [DeclToken], _ i: Int, limit: Int = .max) -> Int? {
        var depth = 0
        var k = i
        let end = min(tokens.count, limit)
        while k < end {
            let kind = tokens[k].kind
            if isOpener(kind) { depth += 1 } else if isCloser(kind) {
                depth -= 1
                if depth == 0 { return k }
                if depth < 0 { return nil }
            }
            k += 1
        }
        return nil
    }

    /// The index of the opener matching the closer at `i`.
    static func matchingBackward(_ tokens: [DeclToken], _ i: Int) -> Int? {
        var depth = 0
        var k = i
        while k >= 0 {
            let kind = tokens[k].kind
            if isCloser(kind) { depth += 1 } else if isOpener(kind) {
                depth -= 1
                if depth == 0 { return k }
                if depth < 0 { return nil }
            }
            k -= 1
        }
        return nil
    }

    /// The `>` matching the `<` at `i` (`>>` is two tokens; angle brackets
    /// nested inside, other
    /// brackets balanced); nil when it does not close before `;`, `{`, `=`
    /// or an unbalanced closer.
    static func matchingAngle(_ tokens: [DeclToken], _ i: Int, end: Int) -> Int? {
        var angle = 0
        var depth = 0
        var k = i
        while k < end {
            let t = tokens[k]
            switch t.kind {
            case .less: if depth == 0 { angle += 1 }
            case .greater:
                if depth == 0 {
                    angle -= 1
                    if angle == 0 { return k }
                }
            case .lparen, .lbracket: depth += 1
            case .rparen, .rbracket:
                depth -= 1
                if depth < 0 { return nil }
            case .semicolon, .lbrace, .rbrace, .assign: return nil
            default: break
            }
            k += 1
        }
        return nil
    }

    /// Index of the first token whose start is `>= offset`.
    static func index(atOrAfter offset: Int, in tokens: [DeclToken]) -> Int {
        var lo = 0
        var hi = tokens.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if tokens[mid].start < offset { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}
