import Foundation

// Token layer of the hand-written parsers (M17 T17.11a).
//
// Built from KaruCore's generic `LexicalScanner` segments over the analysis
// profiles (Python `PythonLanguage.analysisProfile`; JavaScript / TypeScript /
// TSX `JavaScriptLanguage.lexicalProfile(forIdentifier:)`), the same way
// `DeclTokenizer` does it: code segments are split into identifiers /
// numbers / punctuation; strings, escapes and regex atoms become literal
// tokens; interpolation delimiters become open / close tokens; JSX atoms
// become JSX tokens. Differences from `DeclTokenizer`: full operator codes
// (Pratt parsing), the whole string range per literal token, an
// interpolation stack (template / f-string / JSX expression, so `}` is
// classified and a single-line f-string left open at its line end gets a
// synthetic closer), per-frame Python bracket depth, and a `clean` flag per
// token (the scanner state before it is empty) for the incremental update.

/// Namespace of the parser machinery (tokens, lexer, parser core, parsers).
enum SyntaxParsing {
    typealias NK = SyntaxKind
    typealias Node = SyntaxNode
    typealias NodeFlags = SyntaxFlags

    enum TK: UInt8, Sendable {
        case eof = 0, newline, ident, privateName, number, string, regex
        case lparen, rparen, lbracket, rbracket, lbrace, rbrace
        case comma, colon, semicolon, dot, questionDot, ellipsis, arrow, thinArrow, at, question
        case op
        case interpOpen, interpClose, jsxExprOpen, jsxExprClose
        case jsxLt, jsxLtSlash, jsxGt, jsxSlashGt, jsxName, jsxAttr, jsxText
    }

    enum Op: UInt8, Sendable {
        case none = 0
        case assign
        case addAssign, subAssign, mulAssign, divAssign, modAssign, powAssign, floorDivAssign, matMulAssign
        case shlAssign, shrAssign, ushrAssign, andAssign, orAssign, xorAssign, landAssign, lorAssign, nullishAssign
        case walrus
        case eq, ne, eqStrict, neStrict, lt, gt, le, ge
        case plus, minus, star, slash, percent, starStar, slashSlash, amp, pipe, caret, tilde, bang
        case ampAmp, pipePipe, qq, shl, shr, ushr, inc, dec
        // Word operators (Python `and` / `or` / `not` / `in` / `is`, JS `in` / `instanceof` …)
        case and, or, not, `in`, notIn, `is`, isNot, instanceof, matMul
        case typeofOp, voidOp, deleteOp, awaitOp, keyofOp
        case asOp, satisfiesOp

        var isAssignment: Bool { rawValue >= Op.assign.rawValue && rawValue <= Op.nullishAssign.rawValue }
    }

    enum KW: UInt8, Sendable {
        case none = 0
        // Python (and shared)
        case def, `class`, lambda, `for`, `in`, `if`, elif, `else`, `while`, with, `as`, `try`, except
        case finally, `import`, from, global, nonlocal, `return`, yield, async, await, pass, `break`
        case `continue`, raise, del, assert, not, and, or, `is`, match, `case`, type
        case pyNone, pyTrue, pyFalse
        // JavaScript / TypeScript
        case function, const, `let`, `var`, new, `typeof`, instanceof, of, extends, implements
        case interface, `enum`, namespace, module, declare, abstract, export, `default`
        case `static`, get, set, `public`, `private`, protected, readonly, override, accessor
        case this, `super`, `catch`, `switch`, `do`, `throw`, void, delete, `true`, `false`, null
        case undefined, satisfies, keyof, infer, debugger, using, unique, asserts
    }

    struct Token: Sendable {
        static let lineStart: UInt8 = 1      // first token on its physical line
        static let logicalStart: UInt8 = 2   // Python: first token of a logical line
        static let inInterp: UInt8 = 4       // inside an interpolation / JSX expression
        static let synthetic: UInt8 = 8      // zero-width, inserted by recovery
        static let continuation: UInt8 = 16  // string text right after an interpolation closer
        /// The scanner state before this token is empty (top-level code): not
        /// in an interpolation, JSX, or the middle of a string.
        static let clean: UInt8 = 32

        var kind: TK
        /// Keyword (`ident`) or operator (`op`) code.
        var sub: UInt8
        var flags: UInt8
        /// Column of a line-start token (tabs to multiples of 8).
        var indent: UInt16
        var start: Int32
        var end: Int32

        @inline(__always) var kw: KW { kind == .ident ? KW(rawValue: sub) ?? .none : .none }
        @inline(__always) var op: Op { kind == .op ? Op(rawValue: sub) ?? .none : .none }
        @inline(__always) var isLineStart: Bool { flags & Token.lineStart != 0 }
        @inline(__always) var isLogicalStart: Bool { flags & Token.logicalStart != 0 }
        @inline(__always) func isOp(_ o: Op) -> Bool { kind == .op && sub == o.rawValue }
        @inline(__always) func isKW(_ k: KW) -> Bool { kind == .ident && sub == k.rawValue }
    }

    /// Keyword lookup without allocating a String: 2…12 lowercase ASCII
    /// letters packed 5 bits per letter (as in `DeclKeywords`).
    struct KeywordTable: Sendable {
        private let table: [UInt64: KW]
        init(_ words: [(String, KW)]) {
            var t: [UInt64: KW] = [:]
            for (w, k) in words {
                var pack: UInt64 = 0
                for u in w.utf16 { pack = pack << 5 | UInt64(u - 96) }
                t[pack << 4 | UInt64(w.utf16.count)] = k
            }
            table = t
        }
        @inline(__always) func lookup(pack: UInt64, length: Int) -> KW { table[pack << 4 | UInt64(length)] ?? .none }

        static let python = KeywordTable([
            ("def", .def), ("class", .class), ("lambda", .lambda), ("for", .for), ("in", .in), ("if", .if),
            ("elif", .elif), ("else", .else), ("while", .while), ("with", .with), ("as", .as), ("try", .try),
            ("except", .except), ("finally", .finally), ("import", .import), ("from", .from),
            ("global", .global), ("nonlocal", .nonlocal), ("return", .return), ("yield", .yield),
            ("async", .async), ("await", .await), ("pass", .pass), ("break", .break),
            ("continue", .continue), ("raise", .raise), ("del", .del), ("assert", .assert), ("not", .not),
            ("and", .and), ("or", .or), ("is", .is), ("match", .match), ("case", .case), ("type", .type),
        ])

        /// JavaScript and TypeScript (the TypeScript-only contextual words
        /// are keywords in JavaScript too; the parser ignores them there).
        static let script = KeywordTable([
            ("function", .function), ("class", .class), ("const", .const), ("let", .let), ("var", .var),
            ("if", .if), ("else", .else), ("for", .for), ("while", .while), ("do", .do), ("switch", .switch),
            ("case", .case), ("default", .default), ("break", .break), ("continue", .continue),
            ("return", .return), ("throw", .throw), ("try", .try), ("catch", .catch), ("finally", .finally),
            ("new", .new), ("delete", .delete), ("typeof", .typeof), ("instanceof", .instanceof),
            ("in", .in), ("of", .of), ("void", .void), ("this", .this), ("super", .super),
            ("true", .true), ("false", .false), ("null", .null), ("undefined", .undefined),
            ("import", .import), ("export", .export), ("from", .from), ("as", .as), ("async", .async),
            ("await", .await), ("yield", .yield), ("extends", .extends), ("implements", .implements),
            ("static", .static), ("get", .get), ("set", .set), ("with", .with), ("debugger", .debugger),
            ("interface", .interface), ("type", .type), ("enum", .enum), ("namespace", .namespace),
            ("module", .module), ("declare", .declare), ("abstract", .abstract), ("public", .public),
            ("private", .private), ("protected", .protected), ("readonly", .readonly),
            ("override", .override), ("accessor", .accessor), ("satisfies", .satisfies),
            ("keyof", .keyof), ("infer", .infer), ("is", .is), ("using", .using), ("unique", .unique),
            ("asserts", .asserts), ("global", .global),
        ])
    }

    /// Lazily tokenizes `text[from..<end]` chunk by chunk (chunks end at the
    /// scanner's safe points, which never split an identifier; a multi-unit
    /// operator or number straddling a chunk end is read on from the text and
    /// skipped by the next chunk, as in `DeclTokenizer`). The token sequence is
    /// independent of the chunk size.
    struct Lexer {
        let dialect: SyntaxDialect
        let python: Bool
        let scanner: LexicalScanner
        let keywords: KeywordTable
        /// The text being read; rebound before each resumed step (it must hold
        /// the same characters).
        var text: NSString
        let end: Int
        private(set) var pos: Int
        var state = LexicalScanState()
        private(set) var done = false
        static let defaultChunkSize = 16_384
        /// Units scanned per `fill` (smaller for incremental reparses).
        var chunkSize = Lexer.defaultChunkSize

        // Tokenizer state.
        private var consumedUpTo = 0
        private var prevLiteral = false
        private var sawLineBreak = true
        private var hasTokens = false
        private var depth = 0
        private var atLogicalStart = true
        private var logicalIndent = 0
        private var pendingNewline = false
        private enum FrameKind: UInt8 { case template, fstringSingle, fstringMulti, jsx }
        private struct Frame {
            var kind: FrameKind
            var savedInTag: Bool
            var savedDepth: Int
            var savedMultiline: Bool
            /// The enclosing (Python) string's quote unit.
            var savedQuote: unichar
        }
        private var frames: [Frame] = []
        private var inTag = false
        private var lastStringMultiline = false
        private var lastStringQuote: unichar = 0
        private var lastInterpCloseEnd = -1
        private var segs: [(NSRange, LexicalSegment)] = []
        private var buffer: [unichar] = []
        private var bufStart = 0
        private var bufEnd = 0

        private static let pythonScanner = LexicalScanner(profile: SyntaxDialect.python.lexicalProfile)
        private static let javascriptScanner = LexicalScanner(profile: SyntaxDialect.javascript.lexicalProfile)
        private static let typescriptScanner = LexicalScanner(profile: SyntaxDialect.typescript.lexicalProfile)
        private static let typescriptReactScanner = LexicalScanner(profile: SyntaxDialect.typescriptReact.lexicalProfile)

        /// The (shared, immutable) scanner of `dialect`.
        static func scanner(for dialect: SyntaxDialect) -> LexicalScanner {
            switch dialect {
            case .python: return pythonScanner
            case .javascript: return javascriptScanner
            case .typescript: return typescriptScanner
            case .typescriptReact: return typescriptReactScanner
            }
        }

        init(text: NSString, dialect: SyntaxDialect, from: Int = 0) {
            self.dialect = dialect
            self.python = dialect == .python
            self.text = text
            self.end = text.length
            self.pos = from
            self.scanner = Lexer.scanner(for: dialect)
            self.keywords = dialect == .python ? .python : .script
        }

        /// Tokenizes everything (tests).
        static func tokenizeAll(_ text: NSString, dialect: SyntaxDialect, chunkSize: Int = Lexer.defaultChunkSize) -> [Token] {
            var lx = Lexer(text: text, dialect: dialect)
            lx.chunkSize = chunkSize
            var out: [Token] = []
            out.reserveCapacity(text.length / 4)
            while lx.fill(&out) {}
            return out
        }

        /// Appends the next chunk's tokens; returns false once EOF is appended.
        @discardableResult
        mutating func fill(_ out: inout [Token]) -> Bool {
            if done { return false }
            if pos >= end {
                finish(&out)
                return false
            }
            segs.removeAll(keepingCapacity: true)
            let target = min(end, pos + chunkSize)
            let stop = scanner.segments(text, from: pos, to: end, stoppingAtSafePointFrom: target, state: &state) { r, s in
                segs.append((r, s))
            }
            let readEnd = min(end, stop + 16)
            if buffer.count < readEnd - pos { buffer = [unichar](repeating: 0, count: max(readEnd - pos, chunkSize + 64)) }
            let range = NSRange(location: pos, length: readEnd - pos)
            let source = text
            buffer.withUnsafeMutableBufferPointer { p in
                source.getCharacters(p.baseAddress!, range: range)
            }
            bufStart = pos
            bufEnd = readEnd
            tokenize(segs, &out)
            pos = stop
            return true
        }

        @inline(__always) private func at(_ i: Int) -> unichar {
            i >= bufStart && i < bufEnd ? buffer[i - bufStart] : (i < end ? text.character(at: i) : 0)
        }

        private mutating func finish(_ out: inout [Token]) {
            if python {
                while let f = frames.last, f.kind == .fstringSingle || f.kind == .fstringMulti {
                    frames.removeLast()
                    out.append(Token(kind: .interpClose, sub: 0, flags: Token.synthetic, indent: 0,
                                     start: Int32(end), end: Int32(end)))
                }
                if pendingNewline || !atLogicalStart {
                    out.append(Token(kind: .newline, sub: 0, flags: 0, indent: 0, start: Int32(end), end: Int32(end)))
                }
            }
            out.append(Token(kind: .eof, sub: 0, flags: Token.lineStart, indent: 0, start: Int32(end), end: Int32(end)))
            done = true
        }

        // MARK: Segments

        private mutating func tokenize(_ segments: [(NSRange, LexicalSegment)], _ out: inout [Token]) {
            for (range, seg) in segments {
                let a = range.location, b = NSMaxRange(range)
                switch seg {
                case .code:
                    prevLiteral = false
                    code(from: a, to: b, &out)
                case .string, .escape, .block:
                    if prevLiteral, var last = out.popLast() {
                        last.end = Int32(b)
                        out.append(last)
                    } else {
                        var t = Token(kind: .string, sub: 0, flags: 0, indent: 0, start: Int32(a), end: Int32(b))
                        if a == lastInterpCloseEnd {
                            t.flags |= Token.continuation
                        } else if python {
                            lastStringMultiline = isTripleQuoted(a)
                            lastStringQuote = quoteUnit(a)
                        }
                        push(t, &out)
                    }
                    prevLiteral = true
                case .comment:
                    prevLiteral = false
                    if !python {
                        var i = a
                        while i < b {
                            let u = at(i)
                            if u == 10 || u == 13 || u == 0x2028 || u == 0x2029 { sawLineBreak = true; break }
                            i += 1
                        }
                    } else if let f = frames.last, f.kind == .fstringSingle {
                        fieldComment(f, from: a, to: b, &out)
                    }
                case .interpolationDelimiter:
                    prevLiteral = false
                    var i = a
                    while i < b {
                        let u = at(i)
                        if u == 123 { // {
                            let isTemplate = i > a && at(i - 1) == 36
                            let kind: FrameKind
                            if python { kind = lastStringMultiline ? .fstringMulti : .fstringSingle }
                            else { kind = isTemplate ? .template : .jsx }
                            let tokStart = isTemplate ? i - 1 : i
                            push(Token(kind: kind == .jsx ? .jsxExprOpen : .interpOpen, sub: 0, flags: 0, indent: 0,
                                       start: Int32(tokStart), end: Int32(i + 1)), &out)
                            frames.append(Frame(kind: kind, savedInTag: inTag, savedDepth: depth,
                                                savedMultiline: lastStringMultiline, savedQuote: lastStringQuote))
                            inTag = false
                            depth = 0
                        } else if u == 125 { // }
                            let f = frames.popLast()
                            let jsx = f?.kind == .jsx
                            push(Token(kind: jsx ? .jsxExprClose : .interpClose, sub: 0, flags: 0, indent: 0,
                                       start: Int32(i), end: Int32(i + 1)), &out)
                            if let f {
                                inTag = f.savedInTag
                                depth = f.savedDepth
                                lastStringMultiline = f.savedMultiline
                                lastStringQuote = f.savedQuote
                            }
                            if !jsx { lastInterpCloseEnd = i + 1 }
                        }
                        i += 1
                    }
                case .atom(let kind):
                    switch kind {
                    case .regex:
                        if prevLiteral, var last = out.popLast() {
                            last.end = Int32(b); out.append(last)
                        } else {
                            push(Token(kind: .regex, sub: 0, flags: 0, indent: 0, start: Int32(a), end: Int32(b)), &out)
                        }
                        prevLiteral = true
                    case .tagPunctuation:
                        prevLiteral = false
                        var i = a
                        while i < b {
                            let u = at(i)
                            if u == 60 { // <
                                if i + 1 < b, at(i + 1) == 47 {
                                    push(Token(kind: .jsxLtSlash, sub: 0, flags: 0, indent: 0, start: Int32(i), end: Int32(i + 2)), &out)
                                    i += 2
                                } else {
                                    push(Token(kind: .jsxLt, sub: 0, flags: 0, indent: 0, start: Int32(i), end: Int32(i + 1)), &out)
                                    i += 1
                                }
                                inTag = true
                            } else if u == 47, i + 1 < b, at(i + 1) == 62 { // />
                                push(Token(kind: .jsxSlashGt, sub: 0, flags: 0, indent: 0, start: Int32(i), end: Int32(i + 2)), &out)
                                inTag = false
                                i += 2
                            } else if u == 62 {
                                push(Token(kind: .jsxGt, sub: 0, flags: 0, indent: 0, start: Int32(i), end: Int32(i + 1)), &out)
                                inTag = false
                                i += 1
                            } else {
                                i += 1
                            }
                        }
                    case .tagName, .type:
                        prevLiteral = false
                        if let last = out.last, last.kind == .jsxName, Int(last.end) >= a - 1 {
                            // `ns:name`, `Foo.Bar` pieces: one name.
                            out[out.count - 1].end = Int32(b)
                        } else {
                            push(Token(kind: .jsxName, sub: 0, flags: 0, indent: 0, start: Int32(a), end: Int32(b)), &out)
                        }
                    case .attributeName:
                        prevLiteral = false
                        push(Token(kind: .jsxAttr, sub: 0, flags: 0, indent: 0, start: Int32(a), end: Int32(b)), &out)
                    default:
                        prevLiteral = false
                        if !inTag {
                            var i = a
                            var nonBlank = false
                            while i < b {
                                let u = at(i)
                                if !(u == 32 || u == 9 || u == 10 || u == 13) { nonBlank = true; break }
                                i += 1
                            }
                            if nonBlank {
                                if let last = out.last, last.kind == .jsxText, Int(last.end) == a {
                                    out[out.count - 1].end = Int32(b)
                                } else {
                                    push(Token(kind: .jsxText, sub: 0, flags: 0, indent: 0, start: Int32(a), end: Int32(b)), &out)
                                }
                            }
                        }
                    }
                }
            }
        }

        /// A `#` inside a single-line f-string's field is no comment (a
        /// format spec such as `{x:#x}`), but the analysis scanner reads the
        /// rest of the line as one. Close the field at its `}` and keep the
        /// remainder as string text (later fields on that line stay text).
        private mutating func fieldComment(_ f: Frame, from a: Int, to b: Int, _ out: inout [Token]) {
            var i = a
            var braces = 0
            while i < b {
                let u = at(i)
                if u == 123 { braces += 1 } else if u == 125 {
                    if braces == 0 { break }
                    braces -= 1
                }
                i += 1
            }
            guard i < b else { return }
            frames.removeLast()
            push(Token(kind: .interpClose, sub: 0, flags: 0, indent: 0, start: Int32(i), end: Int32(i + 1)), &out)
            inTag = f.savedInTag
            depth = f.savedDepth
            lastStringMultiline = f.savedMultiline
            lastInterpCloseEnd = i + 1
            lastStringQuote = f.savedQuote
            guard i + 1 < b else { return }
            // The string's own closing quote; what follows it on the line is code.
            var p = i + 1
            var close = -1
            while p < b {
                let u = at(p)
                if u == 92 { p += 2; continue }
                if u == f.savedQuote { close = p; break }
                p += 1
            }
            let stringEnd = close < 0 ? b : close + 1
            push(Token(kind: .string, sub: 0, flags: Token.continuation, indent: 0,
                       start: Int32(i + 1), end: Int32(stringEnd)), &out)
            prevLiteral = true
            if stringEnd < b {
                // Rescan the rest of the line from a code state (the scanner
                // is back in code after the string's quote).
                prevLiteral = false
                var state = LexicalScanState()
                var rest: [(NSRange, LexicalSegment)] = []
                scanner.segments(text, from: stringEnd, to: b, state: &state) { r, seg in rest.append((r, seg)) }
                tokenize(rest, &out)
            }
        }

        /// The quote unit of the string literal starting at `a` (after its prefix).
        private func quoteUnit(_ a: Int) -> unichar {
            var i = a
            var n = 0
            while n < 2 {
                let u = at(i)
                if (u >= 65 && u <= 90) || (u >= 97 && u <= 122) { i += 1; n += 1 } else { break }
            }
            return at(i)
        }

        private func isTripleQuoted(_ a: Int) -> Bool {
            var i = a
            var n = 0
            while n < 2 {
                let u = at(i)
                if (u >= 65 && u <= 90) || (u >= 97 && u <= 122) { i += 1; n += 1 } else { break }
            }
            let q = at(i)
            return (q == 34 || q == 39) && at(i + 1) == q && at(i + 2) == q
        }

        // MARK: Code

        @inline(__always) private static func isIdentStart(_ u: unichar, dollar: Bool) -> Bool {
            (u >= 97 && u <= 122) || (u >= 65 && u <= 90) || u == 95 || (dollar && u == 36)
                || (u >= 0x80 && !isExtraSpace(u))
        }
        @inline(__always) private static func isIdentPart(_ u: unichar, dollar: Bool) -> Bool {
            isIdentStart(u, dollar: dollar) || (u >= 48 && u <= 57)
        }
        @inline(__always) private static func isExtraSpace(_ u: unichar) -> Bool {
            u == 0xA0 || u == 0xFEFF || u == 0x2028 || u == 0x2029 || u == 0x3000
        }

        private mutating func code(from: Int, to: Int, _ out: inout [Token]) {
            var i = max(from, consumedUpTo)
            let dollar = !python
            let length = end
            while i < to {
                let c = at(i)
                if c == 32 || c == 9 || c == 12 || c == 11 || (c >= 0x80 && Self.isExtraSpace(c)) {
                    if !python, c == 0x2028 || c == 0x2029 { lineBreak(at: i, &out) }
                    i += 1
                    continue
                }
                if c == 10 || c == 13 {
                    lineBreak(at: i, &out)
                    i += (c == 13 && i + 1 < length && at(i + 1) == 10) ? 2 : 1
                    continue
                }
                if python, c == 92, i + 1 < length {
                    let n = at(i + 1)
                    if n == 10 || n == 13 {
                        i += (n == 13 && i + 2 < length && at(i + 2) == 10) ? 3 : 2
                        continue
                    }
                }
                let start = i
                var isPrivate = false
                if !python, c == 35, i + 1 < length, Self.isIdentStart(at(i + 1), dollar: true) {
                    isPrivate = true
                    i += 1
                }
                if isPrivate || Self.isIdentStart(c, dollar: dollar) {
                    var pack: UInt64 = 0
                    var lower = !isPrivate
                    var j = i
                    while j < length {
                        let u = at(j)
                        guard Self.isIdentPart(u, dollar: dollar) else { break }
                        if lower {
                            if u >= 97 && u <= 122, j - start < 12 { pack = pack << 5 | UInt64(u - 96) } else { lower = false }
                        }
                        j += 1
                    }
                    var t = Token(kind: isPrivate ? .privateName : .ident, sub: 0, flags: 0, indent: 0,
                                  start: Int32(start), end: Int32(j))
                    if lower, j - start >= 2 {
                        t.sub = keywords.lookup(pack: pack, length: j - start).rawValue
                    } else if python, j - start == 4 || j - start == 5, c == 78 || c == 84 || c == 70 {
                        t.sub = pythonConstant(start, j - start).rawValue
                    }
                    push(t, &out)
                    i = j
                    if j > to { consumedUpTo = j }
                    continue
                }
                if (c >= 48 && c <= 57) || (c == 46 && i + 1 < length && (48...57).contains(at(i + 1))) {
                    var j = i + 1
                    let hex = c == 48 && (at(i + 1) == 120 || at(i + 1) == 88)
                    while j < length {
                        let u = at(j)
                        if Self.isIdentPart(u, dollar: false) || u == 46 {
                            if !hex, (u == 101 || u == 69), j + 1 < length, at(j + 1) == 43 || at(j + 1) == 45,
                               j + 2 < length, (48...57).contains(at(j + 2)) {
                                j += 2
                            }
                            j += 1
                        } else { break }
                    }
                    push(Token(kind: .number, sub: 0, flags: 0, indent: 0, start: Int32(start), end: Int32(j)), &out)
                    i = j
                    if j > to { consumedUpTo = j }
                    continue
                }
                @inline(__always) func nx(_ k: Int) -> unichar { i + k < length ? at(i + k) : 0 }
                var kind: TK = .op
                var op: Op = .none
                var width = 1
                switch c {
                case 40: kind = .lparen
                case 41: kind = .rparen
                case 91: kind = .lbracket
                case 93: kind = .rbracket
                case 123: kind = .lbrace
                case 125: kind = .rbrace
                case 44: kind = .comma
                case 59: kind = .semicolon
                case 126: op = .tilde
                case 64:
                    if python, nx(1) == 61 { op = .matMulAssign; width = 2 } else { kind = .at }
                case 58:
                    if python, nx(1) == 61 { op = .walrus; width = 2 } else { kind = .colon }
                case 61:
                    if nx(1) == 61 { if !python && nx(2) == 61 { op = .eqStrict; width = 3 } else { op = .eq; width = 2 } }
                    else if nx(1) == 62, !python { kind = .arrow; width = 2 }
                    else { op = .assign }
                case 46:
                    if nx(1) == 46, nx(2) == 46 { kind = .ellipsis; width = 3 } else { kind = .dot }
                case 42:
                    if nx(1) == 42 {
                        if nx(2) == 61 { op = .powAssign; width = 3 } else { op = .starStar; width = 2 }
                    } else if nx(1) == 61 { op = .mulAssign; width = 2 } else { op = .star }
                case 63:
                    if !python, nx(1) == 46, !(48...57).contains(nx(2)) { kind = .questionDot; width = 2 }
                    else if !python, nx(1) == 63 { if nx(2) == 61 { op = .nullishAssign; width = 3 } else { op = .qq; width = 2 } }
                    else { kind = .question }
                case 60:
                    if nx(1) == 61 { op = .le; width = 2 }
                    else if nx(1) == 60 { if nx(2) == 61 { op = .shlAssign; width = 3 } else { op = .shl; width = 2 } }
                    else if python, nx(1) == 62 { op = .ne; width = 2 }
                    else { op = .lt }
                case 62:
                    if nx(1) == 61 { op = .ge; width = 2 }
                    else if python, nx(1) == 62 { if nx(2) == 61 { op = .shrAssign; width = 3 } else { op = .shr; width = 2 } }
                    else { op = .gt }
                case 33:
                    if nx(1) == 61 { if !python && nx(2) == 61 { op = .neStrict; width = 3 } else { op = .ne; width = 2 } }
                    else { op = .bang }
                case 45:
                    if python, nx(1) == 62 { kind = .thinArrow; width = 2 }
                    else if nx(1) == 61 { op = .subAssign; width = 2 }
                    else if nx(1) == 45, !python { op = .dec; width = 2 }
                    else { op = .minus }
                case 43:
                    if nx(1) == 61 { op = .addAssign; width = 2 } else if nx(1) == 43, !python { op = .inc; width = 2 } else { op = .plus }
                case 47:
                    if nx(1) == 61 { op = .divAssign; width = 2 }
                    else if python, nx(1) == 47 { if nx(2) == 61 { op = .floorDivAssign; width = 3 } else { op = .slashSlash; width = 2 } }
                    else { op = .slash }
                case 37: if nx(1) == 61 { op = .modAssign; width = 2 } else { op = .percent }
                case 94: if nx(1) == 61 { op = .xorAssign; width = 2 } else { op = .caret }
                case 38:
                    if nx(1) == 38, !python { if nx(2) == 61 { op = .landAssign; width = 3 } else { op = .ampAmp; width = 2 } }
                    else if nx(1) == 61 { op = .andAssign; width = 2 } else { op = .amp }
                case 124:
                    if nx(1) == 124, !python { if nx(2) == 61 { op = .lorAssign; width = 3 } else { op = .pipePipe; width = 2 } }
                    else if nx(1) == 61 { op = .orAssign; width = 2 } else { op = .pipe }
                default:
                    op = .none
                }
                push(Token(kind: kind, sub: op.rawValue, flags: 0, indent: 0, start: Int32(start), end: Int32(start + width)), &out)
                i = start + width
                if i > to { consumedUpTo = i }
            }
        }

        private func pythonConstant(_ start: Int, _ len: Int) -> KW {
            let a = at(start), b = at(start + 1), c = at(start + 2), d = at(start + 3)
            if len == 4 {
                if a == 78, b == 111, c == 110, d == 101 { return .pyNone }
                if a == 84, b == 114, c == 117, d == 101 { return .pyTrue }
            } else if a == 70, b == 97, c == 108, d == 115, at(start + 4) == 101 { return .pyFalse }
            return .none
        }

        private mutating func lineBreak(at offset: Int, _ out: inout [Token]) {
            sawLineBreak = true
            guard python else { return }
            // A single-line f-string's interpolation ends with its line (the
            // scanner closes the string there): synthesize its closer.
            while let f = frames.last, f.kind == .fstringSingle {
                frames.removeLast()
                depth = f.savedDepth
                lastStringMultiline = f.savedMultiline
                lastStringQuote = f.savedQuote
                out.append(Token(kind: .interpClose, sub: 0, flags: Token.synthetic, indent: 0,
                                 start: Int32(offset), end: Int32(offset)))
            }
            if depth == 0, frames.isEmpty, !atLogicalStart { pendingNewline = true }
        }

        /// Column of the token at `start` (reading back over its line, bounded).
        private func indentation(of start: Int) -> Int {
            var p = start
            let floor = max(0, start - 4096)
            while p > floor {
                let u = at(p - 1)
                if u == 10 || u == 13 { break }
                p -= 1
            }
            var column = 0
            while p < start {
                let u = at(p)
                if u == 9 { column = (column / 8 + 1) * 8 } else if u == 12 { column = 0 } else { column += 1 }
                p += 1
            }
            return column
        }

        /// Statement-only Python keywords: at a line start no deeper than the
        /// open logical line, they end an unbalanced bracket run.
        private static func isStatementKeyword(_ k: KW) -> Bool {
            switch k {
            case .def, .class, .return, .import, .from, .with, .try, .while, .elif, .except, .finally, .raise,
                 .pass, .break, .continue, .global, .nonlocal, .del, .assert, .if, .for, .else, .async:
                return true
            default:
                return false
            }
        }

        private mutating func push(_ token: Token, _ out: inout [Token]) {
            var token = token
            let firstOnLine = sawLineBreak || !hasTokens
            if !frames.isEmpty { token.flags |= Token.inInterp }
            else if !inTag {
                switch token.kind {
                case .interpOpen, .interpClose, .jsxExprOpen, .jsxExprClose, .jsxLt, .jsxLtSlash, .jsxGt, .jsxSlashGt,
                     .jsxName, .jsxAttr, .jsxText:
                    break
                case .string where token.flags & Token.continuation != 0:
                    break
                default:
                    token.flags |= Token.clean
                }
            }
            if firstOnLine {
                token.flags |= Token.lineStart
                token.indent = UInt16(min(indentation(of: Int(token.start)), 65_535))
            }
            if python {
                if pendingNewline {
                    out.append(Token(kind: .newline, sub: 0, flags: 0, indent: 0, start: token.start, end: token.start))
                    pendingNewline = false
                    atLogicalStart = true
                }
                if firstOnLine, depth > 0, frames.isEmpty, !atLogicalStart {
                    let closer = token.kind == .rparen || token.kind == .rbracket || token.kind == .rbrace
                    let column = Int(token.indent)
                    if !closer, column < logicalIndent || (column <= logicalIndent && Self.isStatementKeyword(token.kw)) {
                        depth = 0
                        out.append(Token(kind: .newline, sub: 0, flags: Token.synthetic, indent: 0,
                                         start: token.start, end: token.start))
                        atLogicalStart = true
                    }
                }
                if atLogicalStart, frames.isEmpty {
                    if !firstOnLine { token.indent = UInt16(min(indentation(of: Int(token.start)), 65_535)) }
                    token.flags |= Token.logicalStart
                    logicalIndent = Int(token.indent)
                    atLogicalStart = false
                }
                switch token.kind {
                case .lparen, .lbracket, .lbrace: depth += 1
                case .rparen, .rbracket, .rbrace: depth = max(0, depth - 1)
                default: break
                }
            }
            sawLineBreak = false
            hasTokens = true
            out.append(token)
        }
    }
}
