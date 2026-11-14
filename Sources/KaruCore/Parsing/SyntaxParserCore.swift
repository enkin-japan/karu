import Foundation

extension SyntaxParsing {
    /// Shared parser machinery: token cursor (lazily filled from the
    /// `Lexer`), node emission, speculation (backtracking), recovery counters,
    /// and the two progress guards.
    ///
    /// **Step cap (forward progress).** Every token read through `cur`,
    /// `kind` or `peek` is a step. Within one top-level statement the parser
    /// may take at most `stepSlack + stepsPerToken × (tokens consumed in the
    /// statement)` steps; past that bound it is *exhausted*: a synthetic end
    /// of input is inserted at the cursor, so every construct closes and the
    /// statement returns; the top-level loop then drops the synthetic token
    /// and skips to the next clean line start (an `error` node) and goes on
    /// with a fresh budget. Should the parser still read more than
    /// `hardStepSlack` further tokens (a loop that does not stop at the end
    /// of input — a bug), the token buffer is truncated to a lone end of
    /// input and the parse ends there. So a parse of `n` tokens reads at most
    /// `n × stepsPerToken + statements × (stepSlack + hardStepSlack)` tokens,
    /// and the budget depends only on the statement's own text (incremental
    /// and full parses stay identical). Valid code stays far below the bound
    /// (the corpus tests record the largest ratio); `capHits` counts
    /// exhaustions.
    ///
    /// **Nesting guard.** Recursive constructs (statements, expressions,
    /// types, patterns, JSX) count their depth; past `maxDepth` the token at
    /// the cursor becomes an `error` node instead of a deeper level, so
    /// pathological nesting cannot overflow the stack.
    struct Core {
        /// Steps allowed per consumed token, and per statement on top.
        static let stepsPerToken = 512
        static let stepSlack = 65_536
        /// Steps allowed after an exhaustion before the hard stop.
        static let hardStepSlack = 1 << 20
        /// Nesting levels before the guard turns tokens into errors.
        static let maxDepth = 160

        var toks: [Token]
        var i = 0
        var lexer: Lexer?
        var nodes: [Node] = []
        var text: NSString
        /// Incremented by every recovery; speculation fails when it changes.
        var diag = 0
        /// Last consumed token's end (for node ends).
        var lastEnd: Int32 = 0
        /// Clean top-level statement starts (see `SyntaxTree.syncStarts`).
        var syncStarts: [Int32] = []
        var python = false

        // Progress guards.
        private(set) var steps = 0
        private var stepLimit = Core.stepSlack
        /// Index of the synthetic end of input inserted by an exhaustion.
        private(set) var exhaustedAt: Int?
        private var hardStopped = false
        var depth = 0
        /// Exhaustions so far (diagnostics; 0 on any sane input).
        private(set) var capHits = 0
        /// Largest steps / consumed-tokens ratio of a statement (diagnostics).
        private(set) var maxStepRatio = 0.0
        private var statementTokens = 0
        /// The current top-level statement's first token start and first node.
        private var statementStart: Int32 = 0
        private var statementMark = 0

        init(text: NSString, lexer: Lexer, reserveNodes: Bool = true) {
            self.text = text
            self.lexer = lexer
            self.toks = []
            self.toks.reserveCapacity(4096)
            if reserveNodes { nodes.reserveCapacity(Core.nodeEstimate(text.length)) }
            fillTo(8)
        }

        /// ~0.17–0.19 nodes per UTF-16 unit on the samples: reserve 0.2 so
        /// the array rarely grows (growth = realloc copies = transient footprint).
        static func nodeEstimate(_ units: Int) -> Int { units / 5 + 256 }

        /// Rebinds the text before a resumed step (same characters).
        mutating func rebind(_ text: NSString) {
            self.text = text
            lexer?.text = text
        }

        /// Called before each top-level statement: records a sync start and
        /// resets the step budget.
        mutating func beginTopLevel() {
            let t = toks[i]
            if t.kind != .eof, t.flags & Token.clean != 0, !python || t.isLogicalStart,
               syncStarts.last != t.start {
                syncStarts.append(t.start)
            }
            statementStart = t.start
            statementMark = nodes.count
            steps = 0
            statementTokens = 0
            stepLimit = Core.stepSlack
            depth = 0
        }

        /// Called after each top-level statement: records the step ratio and
        /// recovers from an exhaustion (skips to the next clean line start).
        mutating func endTopLevel() {
            if statementTokens > 0 {
                maxStepRatio = max(maxStepRatio, Double(steps) / Double(statementTokens))
            }
            guard let at = exhaustedAt else { return }
            exhaustedAt = nil
            if hardStopped { return }
            toks.remove(at: at)
            if i > at { i = at }
            // Skip past the token where the budget ran out, up to the next
            // clean (logical) line start.
            let m = mark
            let s = toks[i].start
            var skipped = false
            while toks[i].kind != .eof {
                if i > at, isRestartPoint(toks[i]) { break }
                rawAdvance()
                skipped = true
            }
            if skipped {
                diag += 1
                emit(.error, m, s, lastEnd)
            }
        }

        @inline(__always) private func isRestartPoint(_ t: Token) -> Bool {
            t.flags & Token.clean != 0 && t.isLineStart && (!python || t.isLogicalStart)
        }

        @inline(__always) private mutating func tick() {
            steps &+= 1
            if steps > stepLimit { exhaust() }
        }

        @inline(never) private mutating func exhaust() {
            if exhaustedAt == nil {
                capHits += 1
                let t = toks[i]
                toks.insert(Token(kind: .eof, sub: 0, flags: Token.synthetic | Token.lineStart, indent: 0,
                                  start: t.start, end: t.start), at: i)
                exhaustedAt = i
                stepLimit = steps &+ Core.hardStepSlack
            } else {
                // Still reading: stop for good.
                hardStopped = true
                let p = toks[i].start
                toks = [Token(kind: .eof, sub: 0, flags: Token.synthetic | Token.lineStart, indent: 0,
                              start: p, end: p)]
                i = 0
                lexer = nil
                stepLimit = Int.max
            }
        }

        /// Streaming: drop consumed tokens at a top-level statement boundary
        /// (no snapshot spans one), so the token buffer stays small.
        @inline(__always) mutating func compactTokens() {
            if lexer != nil, i > 8192, exhaustedAt == nil {
                toks.removeSubrange(0..<i)
                i = 0
            }
        }

        /// Out of line: the refill path must not be inlined into every
        /// `advance` / `peek` call site (code size).
        @inline(never) mutating func fillTo(_ k: Int) {
            while k >= toks.count, lexer != nil, !(lexer!.done) {
                lexer!.fill(&toks)
            }
        }

        @inline(__always) var cur: Token {
            mutating get {
                tick()
                return toks[i]
            }
        }

        @inline(__always) var kind: TK {
            mutating get {
                tick()
                return toks[i].kind
            }
        }

        @inline(__always) mutating func peek(_ k: Int) -> Token {
            tick()
            let j = i + k
            if j >= toks.count { fillTo(j) }
            return j < toks.count ? toks[j] : toks[toks.count - 1]
        }

        @inline(__always) mutating func advance() {
            if toks[i].kind != .eof {
                rawAdvance()
                statementTokens += 1
                stepLimit &+= Core.stepsPerToken
            }
        }

        @inline(__always) private mutating func rawAdvance() {
            if toks[i].kind != .newline { lastEnd = toks[i].end }
            i += 1
            if i + 4 >= toks.count { fillTo(i + 4) }
        }

        @inline(__always) var mark: Int { nodes.count }

        @discardableResult
        mutating func emit(_ kind: NK, _ mark: Int, _ start: Int32, _ end: Int32, flags: UInt8 = 0, aux: UInt16 = 0) -> Int {
            // A parent covers its children: its first descendant (a missing
            // piece placed before its first token) and every child's end (a
            // missing closer may extend a child to the end of input).
            var start = start
            if nodes.count > mark, nodes[mark].start < start { start = nodes[mark].start }
            var end = max(start, end)
            var c = nodes.count - 1
            while c >= mark {
                if nodes[c].end > end { end = nodes[c].end }
                c -= Int(nodes[c].size) + 1
            }
            nodes.append(Node(kind: kind, flags: flags, aux: aux, start: start, end: end,
                              size: Int32(nodes.count - mark)))
            return nodes.count - 1
        }

        @discardableResult
        mutating func leaf(_ kind: NK, aux: UInt16 = 0) -> Int {
            let t = toks[i]
            nodes.append(Node(kind: kind, flags: 0, aux: aux, start: t.start, end: t.end, size: 0))
            advance()
            return nodes.count - 1
        }

        /// Zero-width placeholder for an expected piece: by default right
        /// after what was consumed in the current top-level statement (never
        /// before a node it emitted; never before the statement, so the
        /// position depends on the statement's own text only).
        mutating func missing(at pos: Int32? = nil) {
            diag += 1
            var p = pos ?? max(lastEnd, statementStart)
            if pos == nil, nodes.count > statementMark, nodes[nodes.count - 1].end > p { p = nodes[nodes.count - 1].end }
            nodes.append(Node(kind: .missing, flags: 0, aux: 0, start: p, end: p, size: 0))
        }

        /// Consumes the current token into an error node.
        mutating func skipOne() {
            diag += 1
            let t = toks[i]
            nodes.append(Node(kind: .error, flags: 0, aux: 0, start: t.start, end: t.end, size: 0))
            advance()
        }

        // MARK: Nesting guard

        /// Enters one nesting level; false (and the cursor token turned into
        /// an error node, or a missing node at the end) past `maxDepth`.
        @inline(__always) mutating func enter() -> Bool {
            depth += 1
            if depth > Core.maxDepth {
                depth -= 1
                tooDeep()
                return false
            }
            return true
        }

        @inline(__always) mutating func leave() { depth -= 1 }

        @inline(never) private mutating func tooDeep() {
            if toks[i].kind == .eof { missing() } else { skipOne() }
        }

        // MARK: Speculation

        struct Snapshot { var i: Int; var nodes: Int; var diag: Int; var lastEnd: Int32 }
        @inline(__always) var snapshot: Snapshot { Snapshot(i: i, nodes: nodes.count, diag: diag, lastEnd: lastEnd) }
        mutating func restore(_ s: Snapshot) {
            i = min(s.i, toks.count - 1)
            if s.nodes < nodes.count { nodes.removeSubrange(s.nodes...) }
            diag = s.diag
            lastEnd = s.lastEnd
        }

        // MARK: Text

        /// Column of the line containing `offset` (reads text back to the line start).
        func lineIndent(_ offset: Int32) -> Int {
            var p = Int(offset)
            let floor = max(0, p - 4096)
            while p > floor {
                let u = text.character(at: p - 1)
                if u == 10 || u == 13 { break }
                p -= 1
            }
            var col = 0
            while p < text.length {
                let u = text.character(at: p)
                if u == 32 { col += 1 } else if u == 9 { col = (col / 8 + 1) * 8 } else { break }
                p += 1
            }
            return col
        }

        func tokenIs(_ t: Token, _ s: StaticString) -> Bool {
            let n = Int(t.end - t.start)
            guard n == s.utf8CodeUnitCount else { return false }
            let p = s.utf8Start
            for k in 0..<n where text.character(at: Int(t.start) + k) != unichar(p[k]) { return false }
            return true
        }
    }
}
