import Foundation

// Recursive-descent / precedence-climbing parser for Python 3.13 syntax
// (M17 T17.11a), error tolerant:
// - blocks are delimited by indentation alone (a block holds the following
//   logical lines indented deeper than its header), so an unexpected indent
//   or an inconsistent dedent never loses statements;
// - a missing `:` after a header is inserted when the header line ends;
// - unclosed brackets are closed at the tokenizer's recovery NEWLINE (a line
//   start indented less than the open logical line, or a statement keyword
//   no deeper) or at the end of input;
// - a statement with trailing junk is synchronised at its NEWLINE;
// - `x.` with no name yields a member node flagged `missingName`.
// `match` statements get pattern nodes (PEP 634); f-string fields are
// parsed as expressions, with `formatSpec` nodes holding a format spec's
// nested fields.

extension SyntaxParsing {
    struct PythonParser {
        var c: Core

        init(core: Core) {
            c = core
            c.python = true
        }

        // MARK: Module

        /// Skips blank logical lines, then parses one top-level statement
        /// (the unit of slicing and of the incremental update). Does nothing
        /// at the end of input.
        mutating func topLevelStep() {
            while c.kind == .newline { c.advance() }
            guard c.kind != .eof else { return }
            c.compactTokens()
            c.beginTopLevel()
            statement()
            c.endTopLevel()
        }

        // MARK: Helpers

        @inline(__always) func isName(_ t: Token) -> Bool {
            t.kind == .ident && (t.sub == 0 || t.sub == KW.match.rawValue || t.sub == KW.case.rawValue
                                 || t.sub == KW.type.rawValue)
        }

        @inline(__always) var atLineEnd: Bool {
            mutating get {
                let k = c.kind
                return k == .newline || k == .eof
            }
        }

        /// End for a node whose closer is missing: the end of input when the
        /// input ended, else the last consumed token.
        var closeEnd: Int32 {
            mutating get {
                if c.kind == .eof { return c.cur.start }
                if c.kind == .newline, c.peek(1).kind == .eof { return c.peek(1).start }
                return c.lastEnd
            }
        }

        mutating func skipToLineEnd() {
            guard !atLineEnd else { return }
            let m = c.mark
            let s = c.cur.start
            while !atLineEnd { c.advance() }
            c.diag += 1
            c.emit(.error, m, s, c.lastEnd)
        }

        func indentOf(_ t: Token) -> Int { t.isLogicalStart || t.isLineStart ? Int(t.indent) : c.lineIndent(t.start) }

        // MARK: Statements

        mutating func statement() {
            guard c.enter() else { return }
            defer { c.leave() }
            let t = c.cur
            switch t.kind {
            case .newline:
                c.advance()
                return
            case .at:
                decorated()
                return
            case .ident:
                let indent = indentOf(t)
                switch t.kw {
                case .def: funcDef(mark: c.mark, start: t.start, indent: indent, flags: 0)
                case .class: classDef(mark: c.mark, start: t.start, indent: indent)
                case .if: ifStmt(indent)
                case .while: whileStmt(indent)
                case .for: forStmt(mark: c.mark, start: t.start, indent: indent, flags: 0)
                case .try: tryStmt(indent)
                case .with: withStmt(mark: c.mark, start: t.start, indent: indent, flags: 0)
                case .async:
                    let n = c.peek(1)
                    let m = c.mark
                    if n.isKW(.def) { c.advance(); funcDef(mark: m, start: t.start, indent: indent, flags: NodeFlags.async) }
                    else if n.isKW(.for) { c.advance(); forStmt(mark: m, start: t.start, indent: indent, flags: NodeFlags.async) }
                    else if n.isKW(.with) { c.advance(); withStmt(mark: m, start: t.start, indent: indent, flags: NodeFlags.async) }
                    else { simpleStatements() }
                case .elif, .else, .except, .finally:
                    orphanClause(indent)
                case .match where isMatchStatement():
                    matchStmt(indent)
                default:
                    simpleStatements()
                }
            default:
                simpleStatements()
            }
        }

        mutating func simpleStatements() {
            while true {
                smallStatement()
                if c.kind == .semicolon {
                    c.advance()
                    if atLineEnd { break }
                    continue
                }
                break
            }
            skipToLineEnd()
            if c.kind == .newline { c.advance() }
        }

        mutating func smallStatement() {
            let t = c.cur
            let m = c.mark
            switch t.kw {
            case .pass: c.advance(); c.emit(.passStmt, m, t.start, t.end)
            case .break: c.advance(); c.emit(.breakStmt, m, t.start, t.end)
            case .continue: c.advance(); c.emit(.continueStmt, m, t.start, t.end)
            case .return:
                c.advance()
                if !atLineEnd && c.kind != .semicolon { starExpressions() }
                c.emit(.returnStmt, m, t.start, c.lastEnd)
            case .raise:
                c.advance()
                if !atLineEnd && c.kind != .semicolon {
                    test()
                    if c.cur.isKW(.from) { c.advance(); test() }
                }
                c.emit(.raiseStmt, m, t.start, c.lastEnd)
            case .global, .nonlocal:
                c.advance()
                repeat {
                    if c.kind == .comma { c.advance() }
                    if isName(c.cur) { c.leaf(.name) } else { c.missing(); break }
                } while c.kind == .comma
                c.emit(t.kw == .global ? .globalStmt : .nonlocalStmt, m, t.start, c.lastEnd)
            case .del:
                c.advance()
                targetList()
                c.emit(.delStmt, m, t.start, c.lastEnd)
            case .assert:
                c.advance()
                test()
                if c.kind == .comma { c.advance(); test() }
                c.emit(.assertStmt, m, t.start, c.lastEnd)
            case .import:
                c.advance()
                repeat {
                    if c.kind == .comma { c.advance() }
                    let am = c.mark
                    let s = c.cur.start
                    if !dottedName() { c.missing(); break }
                    if c.cur.isKW(.as) { c.advance(); if isName(c.cur) { c.leaf(.name) } else { c.missing() } }
                    c.emit(.alias, am, s, c.lastEnd)
                } while c.kind == .comma
                c.emit(.importStmt, m, t.start, c.lastEnd)
            case .from:
                c.advance()
                var level: UInt16 = 0
                while c.kind == .dot || c.kind == .ellipsis {
                    level += c.kind == .dot ? 1 : 3
                    c.advance()
                }
                if !dottedName(), level == 0 { c.missing() }
                if c.cur.isKW(.import) {
                    c.advance()
                    var paren = false
                    if c.kind == .lparen { paren = true; c.advance() }
                    if c.cur.isOp(.star) {
                        c.leaf(.name)
                    } else {
                        var any = false
                        while isName(c.cur) {
                            any = true
                            let am = c.mark
                            let s = c.cur.start
                            c.leaf(.name)
                            if c.cur.isKW(.as) { c.advance(); if isName(c.cur) { c.leaf(.name) } else { c.missing() } }
                            c.emit(.alias, am, s, c.lastEnd)
                            if c.kind == .comma { c.advance() } else { break }
                        }
                        if !any { c.missing() }
                    }
                    if paren { if c.kind == .rparen { c.advance() } else { c.diag += 1 } }
                } else {
                    c.missing()
                }
                c.emit(.importFrom, m, t.start, c.lastEnd, aux: level)
            case .type where isName(c.peek(1)) && (c.peek(2).isOp(.assign) || c.peek(2).kind == .lbracket):
                c.advance()
                c.leaf(.name)
                if c.kind == .lbracket { typeParams() }
                if c.cur.isOp(.assign) { c.advance(); test() } else { c.missing() }
                c.emit(.typeAliasStmt, m, t.start, c.lastEnd)
            default:
                expressionStatement()
            }
        }

        mutating func expressionStatement() {
            let m = c.mark
            let s = c.cur.start
            if c.cur.isKW(.yield) { yieldExpr() } else { starExpressions() }
            if c.cur.isOp(.assign) {
                while c.cur.isOp(.assign) {
                    c.advance()
                    if c.cur.isKW(.yield) { yieldExpr() } else { starExpressions() }
                }
                c.emit(.assign, m, s, c.lastEnd)
            } else if c.kind == .colon {
                c.advance()
                test()
                if c.cur.isOp(.assign) {
                    c.advance()
                    if c.cur.isKW(.yield) { yieldExpr() } else { starExpressions() }
                }
                c.emit(.annAssign, m, s, c.lastEnd)
            } else if c.kind == .op, c.cur.op.isAssignment || c.cur.isOp(.matMulAssign) {
                let op = c.cur.sub
                c.advance()
                if c.cur.isKW(.yield) { yieldExpr() } else { starExpressions() }
                c.emit(.augAssign, m, s, c.lastEnd, aux: UInt16(op))
            } else {
                c.emit(.exprStmt, m, s, c.lastEnd)
            }
        }

        /// `a.b.c` as one dottedName node of names.
        mutating func dottedName() -> Bool {
            guard isName(c.cur) else { return false }
            let m = c.mark
            let s = c.cur.start
            c.leaf(.name)
            while c.kind == .dot {
                c.advance()
                if isName(c.cur) { c.leaf(.name) } else { c.missing(); break }
            }
            c.emit(.dottedName, m, s, c.lastEnd)
            return true
        }

        // MARK: Compound statements

        /// `:` then the block (missing `:` inserted at the line end).
        mutating func colonAndBlock(_ indent: Int) {
            if c.kind == .colon {
                c.advance()
            } else {
                c.missing(at: c.lastEnd)
                skipToLineEnd()
            }
            block(indent)
        }

        mutating func block(_ headerIndent: Int) {
            let m = c.mark
            let s = c.lastEnd
            if c.kind == .newline {
                c.advance()
                var any = false
                while c.kind != .eof, Int(c.cur.indent) > headerIndent || c.kind == .newline {
                    statement()
                    any = true
                }
                if !any { c.diag += 1 }
                c.emit(.block, m, s, c.lastEnd, flags: any ? 0 : NodeFlags.recovered)
            } else if c.kind == .eof {
                c.diag += 1
                c.emit(.block, m, s, c.lastEnd, flags: NodeFlags.recovered)
            } else {
                simpleStatements()
                c.emit(.block, m, s, c.lastEnd)
            }
        }

        mutating func decorated() {
            let m = c.mark
            let s = c.cur.start
            let indent = indentOf(c.cur)
            while c.kind == .at {
                let dm = c.mark
                let ds = c.cur.start
                c.advance()
                namedExpr()
                c.emit(.decorator, dm, ds, c.lastEnd)
                skipToLineEnd()
                if c.kind == .newline { c.advance() }
            }
            let t = c.cur
            if t.isKW(.def) {
                funcDef(mark: m, start: s, indent: indent, flags: 0)
            } else if t.isKW(.class) {
                classDef(mark: m, start: s, indent: indent)
            } else if t.isKW(.async), c.peek(1).isKW(.def) {
                c.advance()
                funcDef(mark: m, start: s, indent: indent, flags: NodeFlags.async)
            } else {
                c.diag += 1
                c.emit(.error, m, s, c.lastEnd)
            }
        }

        mutating func funcDef(mark m: Int, start s: Int32, indent: Int, flags: UInt8) {
            c.advance() // def
            if isName(c.cur) { c.leaf(.name) } else { c.missing() }
            if c.kind == .lbracket { typeParams() }
            if c.kind == .lparen { parameters(lambda: false) } else { c.missing() }
            if c.kind == .thinArrow { c.advance(); test() }
            colonAndBlock(indent)
            c.emit(.funcDef, m, s, c.lastEnd, flags: flags)
        }

        mutating func typeParams() {
            let m = c.mark
            let s = c.cur.start
            c.advance()
            while !atLineEnd, c.kind != .rbracket {
                if c.cur.isOp(.star) || c.cur.isOp(.starStar) { c.advance() }
                let pm = c.mark
                let ps = c.cur.start
                if isName(c.cur) { c.leaf(.name) } else { c.skipOne(); continue }
                if c.kind == .colon { c.advance(); test() }
                if c.cur.isOp(.assign) { c.advance(); test() }
                c.emit(.typeParam, pm, ps, c.lastEnd)
                if c.kind == .comma { c.advance() } else { break }
            }
            let closed = c.kind == .rbracket
            if closed { c.advance() } else { c.diag += 1 }
            c.emit(.typeParams, m, s, closed ? c.lastEnd : closeEnd, flags: closed ? 0 : NodeFlags.missingClose)
        }

        mutating func classDef(mark m: Int, start s: Int32, indent: Int) {
            c.advance() // class
            if isName(c.cur) { c.leaf(.name) } else { c.missing() }
            if c.kind == .lbracket { typeParams() }
            if c.kind == .lparen { callArgs() }
            colonAndBlock(indent)
            c.emit(.classDef, m, s, c.lastEnd)
        }

        mutating func ifStmt(_ indent: Int) {
            let m = c.mark
            let s = c.cur.start
            c.advance()
            namedExpr()
            colonAndBlock(indent)
            while c.cur.isKW(.elif), Int(c.cur.indent) == indent, c.cur.isLogicalStart {
                let em = c.mark
                let es = c.cur.start
                c.advance()
                namedExpr()
                colonAndBlock(indent)
                c.emit(.elifClause, em, es, c.lastEnd)
            }
            elseClause(indent)
            c.emit(.ifStmt, m, s, c.lastEnd)
        }

        mutating func elseClause(_ indent: Int) {
            if c.cur.isKW(.else), Int(c.cur.indent) == indent, c.cur.isLogicalStart {
                let em = c.mark
                let es = c.cur.start
                c.advance()
                colonAndBlock(indent)
                c.emit(.elseClause, em, es, c.lastEnd)
            }
        }

        mutating func whileStmt(_ indent: Int) {
            let m = c.mark
            let s = c.cur.start
            c.advance()
            namedExpr()
            colonAndBlock(indent)
            elseClause(indent)
            c.emit(.whileStmt, m, s, c.lastEnd)
        }

        mutating func forStmt(mark m: Int, start s: Int32, indent: Int, flags: UInt8) {
            c.advance() // for
            targetList()
            if c.cur.isKW(.in) { c.advance(); starExpressions() } else { c.missing() }
            colonAndBlock(indent)
            elseClause(indent)
            c.emit(.forStmt, m, s, c.lastEnd, flags: flags)
        }

        mutating func tryStmt(_ indent: Int) {
            let m = c.mark
            let s = c.cur.start
            c.advance()
            colonAndBlock(indent)
            while c.cur.isKW(.except), Int(c.cur.indent) == indent, c.cur.isLogicalStart {
                let em = c.mark
                let es = c.cur.start
                c.advance()
                if c.cur.isOp(.star) { c.advance() }
                if c.kind != .colon, !atLineEnd {
                    test()
                    if c.kind == .comma { c.advance(); test() }
                    if c.cur.isKW(.as) { c.advance(); if isName(c.cur) { c.leaf(.name) } else { c.missing() } }
                }
                colonAndBlock(indent)
                c.emit(.exceptClause, em, es, c.lastEnd)
            }
            elseClause(indent)
            if c.cur.isKW(.finally), Int(c.cur.indent) == indent, c.cur.isLogicalStart {
                let em = c.mark
                let es = c.cur.start
                c.advance()
                colonAndBlock(indent)
                c.emit(.finallyClause, em, es, c.lastEnd)
            }
            c.emit(.tryStmt, m, s, c.lastEnd)
        }

        mutating func withStmt(mark m: Int, start s: Int32, indent: Int, flags: UInt8) {
            c.advance() // with
            var done = false
            if c.kind == .lparen {
                // `with (a as b, c as d):` — speculative.
                let snap = c.snapshot
                c.advance()
                withItems()
                if c.kind == .rparen {
                    c.advance()
                    if c.kind == .colon, c.diag == snap.diag { done = true }
                }
                if !done { c.restore(snap) }
            }
            if !done { withItems() }
            colonAndBlock(indent)
            c.emit(.withStmt, m, s, c.lastEnd, flags: flags)
        }

        mutating func withItems() {
            repeat {
                if c.kind == .comma { c.advance() }
                if c.kind == .rparen || c.kind == .colon || atLineEnd { break }
                let im = c.mark
                let s = c.cur.start
                test()
                if c.cur.isKW(.as) { c.advance(); targetAtom() }
                c.emit(.withItem, im, s, c.lastEnd)
            } while c.kind == .comma
        }

        mutating func isMatchStatement() -> Bool {
            // `match <subject>:` at a statement start (soft keyword): the next
            // token can start an expression and the logical line ends with `:`.
            let n = c.peek(1)
            switch n.kind {
            case .newline, .eof, .colon, .comma, .rparen, .rbracket, .rbrace, .dot, .semicolon: return false
            case .op where n.op.isAssignment || n.op != .minus && n.op != .tilde && n.op != .star: return false
            default: break
            }
            var k = 1
            var depth = 0
            var last = n
            while true {
                let t = c.peek(k)
                if t.kind == .newline || t.kind == .eof { break }
                if t.kind == .lparen || t.kind == .lbracket || t.kind == .lbrace { depth += 1 }
                if t.kind == .rparen || t.kind == .rbracket || t.kind == .rbrace { depth -= 1 }
                last = t
                k += 1
                if k > 512 { return false }
            }
            return last.kind == .colon && depth == 0
        }

        mutating func matchStmt(_ indent: Int) {
            let m = c.mark
            let s = c.cur.start
            c.advance()
            starExpressions()
            if c.kind == .colon { c.advance() } else { c.missing() }
            skipToLineEnd()
            let bm = c.mark
            let bs = c.lastEnd
            if c.kind == .newline {
                c.advance()
                while c.kind != .eof, Int(c.cur.indent) > indent {
                    if c.cur.isKW(.case) {
                        let cm = c.mark
                        let cs = c.cur.start
                        let ci = Int(c.cur.indent)
                        c.advance()
                        casePatterns()
                        if c.cur.isKW(.if) { c.advance(); namedExpr() }
                        colonAndBlock(ci)
                        c.emit(.caseClause, cm, cs, c.lastEnd)
                    } else {
                        statement()
                    }
                }
            }
            c.emit(.block, bm, bs, c.lastEnd)
            c.emit(.matchStmt, m, s, c.lastEnd)
        }

        // MARK: Patterns (PEP 634)

        @inline(__always) func canStartPattern(_ t: Token) -> Bool {
            switch t.kind {
            case .ident:
                switch t.kw {
                case .none, .match, .case, .type, .pyNone, .pyTrue, .pyFalse: return true
                default: return false
                }
            case .number, .string, .interpOpen, .lparen, .lbracket, .lbrace: return true
            case .op: return t.op == .minus || t.op == .star
            default: return false
            }
        }

        /// A `case` clause's patterns: an open sequence (`case a, *b:`) or one pattern.
        mutating func casePatterns() {
            let m = c.mark
            let s = c.cur.start
            maybeStarPattern()
            if c.kind == .comma {
                while c.kind == .comma {
                    c.advance()
                    if !canStartPattern(c.cur) { break }
                    maybeStarPattern()
                }
                c.emit(.patternSequence, m, s, c.lastEnd)
            }
        }

        mutating func maybeStarPattern() {
            if c.cur.isOp(.star) || c.cur.isOp(.starStar) { starPattern() } else { pattern() }
        }

        /// `*rest` (aux 1) / `**rest` (aux 2).
        mutating func starPattern() {
            let m = c.mark
            let s = c.cur.start
            let aux: UInt16 = c.cur.isOp(.star) ? 1 : 2
            c.advance()
            if isName(c.cur) { c.leaf(.name) } else { c.missing() }
            c.emit(.patternStar, m, s, c.lastEnd, aux: aux)
        }

        /// `or_pattern ('as' NAME)?`.
        mutating func pattern() {
            guard c.enter() else { return }
            defer { c.leave() }
            let m = c.mark
            let s = c.cur.start
            closedPattern()
            if c.cur.isOp(.pipe) {
                while c.cur.isOp(.pipe) {
                    c.advance()
                    closedPattern()
                }
                c.emit(.patternOr, m, s, c.lastEnd)
            }
            if c.cur.isKW(.as) {
                c.advance()
                if isName(c.cur) { c.leaf(.name) } else { c.missing() }
                c.emit(.patternAs, m, s, c.lastEnd)
            }
        }

        mutating func closedPattern() {
            let t = c.cur
            let m = c.mark
            switch t.kind {
            case .ident where isName(t):
                // Capture (`_` is the wildcard, aux 1), dotted value, or class pattern.
                c.leaf(.name)
                var dotted = false
                while c.kind == .dot {
                    dotted = true
                    let gap = UInt16(clamping: max(0, Int(c.cur.start - c.nodes[c.nodes.count - 1].end)))
                    let dotEnd = c.cur.end
                    c.advance()
                    if isName(c.cur) {
                        c.leaf(.name)
                        c.emit(.member, m, t.start, c.lastEnd, aux: gap)
                    } else {
                        c.diag += 1
                        c.emit(.member, m, t.start, dotEnd, flags: NodeFlags.missingName, aux: gap)
                        break
                    }
                }
                if c.kind == .lparen {
                    classPatternArguments(m, t.start)
                } else if dotted {
                    c.emit(.patternValue, m, t.start, c.lastEnd)
                } else {
                    let wildcard = t.end - t.start == 1 && c.text.character(at: Int(t.start)) == 95
                    c.emit(.patternCapture, m, t.start, c.lastEnd, aux: wildcard ? 1 : 0)
                }
            case .ident where t.kw == .pyNone || t.kw == .pyTrue || t.kw == .pyFalse:
                c.leaf(.keywordLit, aux: UInt16(t.sub))
                c.emit(.patternValue, m, t.start, c.lastEnd)
            case .number:
                // Numbers and complex literals (`1 + 2j`).
                binary(9)
                c.emit(.patternValue, m, t.start, c.lastEnd)
            case .op where t.op == .minus:
                // Signed numbers (`-1`, `-1 - 2j`).
                binary(9)
                c.emit(.patternValue, m, t.start, c.lastEnd)
            case .string, .interpOpen:
                stringAtom()
                c.emit(.patternValue, m, t.start, c.lastEnd)
            case .op where t.op == .star || t.op == .starStar:
                starPattern()
            case .lparen:
                // `()` / `(p, …)` sequence (aux 2), or a group `(p)`.
                c.advance()
                if c.kind == .rparen {
                    c.advance()
                    c.emit(.patternSequence, m, t.start, c.lastEnd, aux: 2)
                    return
                }
                maybeStarPattern()
                if c.kind == .comma {
                    patternTail(closer: .rparen)
                    closeBracket(m, t.start, .patternSequence, .rparen, aux: 2)
                } else if c.kind == .rparen {
                    c.advance()
                } else {
                    while !atLineEnd, c.kind != .rparen, c.kind != .rbracket, c.kind != .rbrace, c.kind != .colon {
                        c.skipOne()
                    }
                    if c.kind == .rparen { c.advance() } else { c.missing() }
                }
            case .lbracket:
                c.advance()
                if c.kind != .rbracket, !atLineEnd {
                    maybeStarPattern()
                    patternTail(closer: .rbracket)
                }
                closeBracket(m, t.start, .patternSequence, .rbracket, aux: 1)
            case .lbrace:
                mappingPattern()
            default:
                c.missing()
            }
        }

        /// `, pattern …` up to `closer` (not consumed), with recovery.
        mutating func patternTail(closer: TK) {
            while !atLineEnd, c.kind != closer {
                if c.kind == .comma {
                    c.advance()
                    if c.kind == closer || atLineEnd { break }
                    let before = c.i
                    maybeStarPattern()
                    if c.i == before, !atLineEnd, c.kind != closer { c.skipOne() }
                } else if canStartPattern(c.cur) {
                    c.diag += 1 // missing comma
                    let before = c.i
                    maybeStarPattern()
                    if c.i == before { c.skipOne() }
                } else if c.kind == .rparen || c.kind == .rbracket || c.kind == .rbrace || c.kind == .colon {
                    break
                } else {
                    c.skipOne()
                }
            }
        }

        /// `{ key: pattern, **rest }`.
        mutating func mappingPattern() {
            let m = c.mark
            let s = c.cur.start
            c.advance()
            while !atLineEnd, c.kind != .rbrace {
                let pm = c.mark
                let ps = c.cur.start
                if c.cur.isOp(.starStar) {
                    starPattern()
                } else if canStartPattern(c.cur), !c.cur.isOp(.star) {
                    let before = c.i
                    binary(9) // literal or dotted name key
                    if c.i == before { c.skipOne(); continue }
                    if c.kind == .colon { c.advance(); pattern() } else { c.missing() }
                    c.emit(.patternPair, pm, ps, c.lastEnd)
                } else if c.kind == .rparen || c.kind == .rbracket || c.kind == .colon {
                    break
                } else {
                    c.skipOne()
                    continue
                }
                if c.kind == .comma { c.advance() } else if c.kind != .rbrace {
                    if atLineEnd || c.kind == .rparen || c.kind == .rbracket || c.kind == .colon { break }
                    if !canStartPattern(c.cur) { c.skipOne() } else { c.diag += 1 }
                }
            }
            closeBracket(m, s, .patternMapping, .rbrace)
        }

        /// `Cls(p, …, kw=p, …)` after the class reference.
        mutating func classPatternArguments(_ m: Int, _ s: Int32) {
            c.advance() // (
            while !atLineEnd, c.kind != .rparen {
                let t = c.cur
                if isName(t), c.peek(1).isOp(.assign) {
                    let km = c.mark
                    c.leaf(.name)
                    c.advance()
                    pattern()
                    c.emit(.patternKeyword, km, t.start, c.lastEnd)
                } else if canStartPattern(t) {
                    let before = c.i
                    maybeStarPattern()
                    if c.i == before { c.skipOne(); continue }
                } else if t.kind == .rbracket || t.kind == .rbrace || t.kind == .colon {
                    break
                } else {
                    c.skipOne()
                    continue
                }
                if c.kind == .comma { c.advance() } else if c.kind != .rparen {
                    if atLineEnd || c.kind == .rbracket || c.kind == .rbrace || c.kind == .colon { break }
                    if !canStartPattern(c.cur) { c.skipOne() } else { c.diag += 1 }
                }
            }
            closeBracket(m, s, .patternClass, .rparen)
        }

        mutating func orphanClause(_ indent: Int) {
            let m = c.mark
            let s = c.cur.start
            let k = c.cur.kw
            c.advance()
            if k == .elif || k == .except, c.kind != .colon, !atLineEnd { test() }
            colonAndBlock(indent)
            c.diag += 1
            c.emit(.error, m, s, c.lastEnd)
        }

        // MARK: Parameters

        mutating func parameters(lambda: Bool) {
            let m = c.mark
            let s = c.cur.start
            if !lambda { c.advance() } // (
            let closer: TK = lambda ? .colon : .rparen
            while !atLineEnd, c.kind != closer {
                let pm = c.mark
                let ps = c.cur.start
                var aux: UInt16 = 0
                if c.cur.isOp(.star) { aux = 1; c.advance() }
                else if c.cur.isOp(.starStar) { aux = 2; c.advance() }
                else if c.cur.isOp(.slash) { c.advance(); c.emit(.param, pm, ps, c.lastEnd, aux: 4) }
                if c.nodes.count > pm { // `/` emitted
                    if c.kind == .comma { c.advance(); continue } else { break }
                }
                if isName(c.cur) {
                    c.leaf(.name)
                    if !lambda, c.kind == .colon { c.advance(); if c.cur.isOp(.star) { c.advance() }; test() }
                    if c.cur.isOp(.assign) { c.advance(); test() }
                    c.emit(.param, pm, ps, c.lastEnd, aux: aux)
                } else if aux == 1 {
                    c.emit(.param, pm, ps, c.lastEnd, aux: 3) // bare `*`
                } else {
                    if c.kind == .rparen || c.kind == .rbracket || c.kind == .rbrace || c.kind == .colon { break }
                    c.skipOne()
                    continue
                }
                if c.kind == .comma { c.advance() } else if c.kind != closer && !atLineEnd {
                    if c.kind == .rparen || c.kind == .colon || c.kind == .thinArrow { break }
                    c.skipOne()
                }
            }
            var flags: UInt8 = 0
            var end = c.lastEnd
            if !lambda {
                if c.kind == .rparen { c.advance(); end = c.lastEnd } else { c.diag += 1; flags = NodeFlags.missingClose; end = closeEnd }
            }
            c.emit(.params, m, s, end, flags: flags)
        }

        // MARK: Expressions

        @inline(__always) func canStartExpression(_ t: Token) -> Bool {
            switch t.kind {
            case .ident:
                switch t.kw {
                case .none, .match, .case, .type, .lambda, .not, .await, .pyNone, .pyTrue, .pyFalse, .yield: return true
                default: return false
                }
            case .number, .string, .lparen, .lbracket, .lbrace, .ellipsis, .interpOpen: return true
            case .op: return t.op == .minus || t.op == .plus || t.op == .tilde || t.op == .star || t.op == .starStar
            default: return false
            }
        }

        /// `a, *b, c` (tuple without parentheses when there is a comma).
        mutating func starExpressions() {
            let m = c.mark
            let s = c.cur.start
            starNamedExpr()
            if c.kind == .comma {
                while c.kind == .comma {
                    c.advance()
                    if !canStartExpression(c.cur) { break }
                    starNamedExpr()
                }
                c.emit(.tuple, m, s, c.lastEnd)
            }
        }

        mutating func starNamedExpr() {
            if c.cur.isOp(.star) {
                let m = c.mark
                let s = c.cur.start
                c.advance()
                binary(5)
                c.emit(.starred, m, s, c.lastEnd, aux: 1)
            } else {
                namedExpr()
            }
        }

        mutating func namedExpr() {
            if isName(c.cur), c.peek(1).isOp(.walrus) {
                let m = c.mark
                let s = c.cur.start
                c.leaf(.name)
                c.advance()
                test()
                c.emit(.walrus, m, s, c.lastEnd)
            } else {
                test()
            }
        }

        /// Targets of `for` / `del` / comprehension `for` (no `in` operator).
        mutating func targetList() {
            let m = c.mark
            let s = c.cur.start
            targetAtom()
            if c.kind == .comma {
                while c.kind == .comma {
                    c.advance()
                    if !canStartExpression(c.cur) { break }
                    targetAtom()
                }
                c.emit(.tuple, m, s, c.lastEnd)
            }
        }

        mutating func targetAtom() {
            if c.cur.isOp(.star) {
                let m = c.mark
                let s = c.cur.start
                c.advance()
                binary(5)
                c.emit(.starred, m, s, c.lastEnd, aux: 1)
            } else {
                binary(5)
            }
        }

        mutating func test() {
            guard c.enter() else { return }
            defer { c.leave() }
            if c.cur.isKW(.lambda) { lambdef(); return }
            let m = c.mark
            let s = c.cur.start
            binary(1)
            if c.cur.isKW(.if), !c.cur.isLogicalStart {
                c.advance()
                binary(1)
                if c.cur.isKW(.else) { c.advance(); test() } else { c.missing() }
                c.emit(.ternary, m, s, c.lastEnd)
            }
        }

        mutating func lambdef() {
            let m = c.mark
            let s = c.cur.start
            c.advance()
            parameters(lambda: true)
            if c.kind == .colon { c.advance() } else { c.missing() }
            test()
            c.emit(.lambda, m, s, c.lastEnd)
        }

        mutating func yieldExpr() {
            let m = c.mark
            let s = c.cur.start
            c.advance()
            var aux: UInt16 = 0
            if c.cur.isKW(.from) { c.advance(); aux = 1; test() }
            else if canStartExpression(c.cur) { starExpressions() }
            c.emit(.yield, m, s, c.lastEnd, aux: aux)
        }

        /// Binary operator precedence (0 = not a binary operator here).
        @inline(__always) mutating func infix() -> (prec: Int, op: Op, width: Int) {
            let t = c.cur
            switch t.kind {
            case .ident:
                switch t.kw {
                case .or: return (1, .or, 1)
                case .and: return (2, .and, 1)
                case .in: return (4, .in, 1)
                case .is: return c.peek(1).isKW(.not) ? (4, .isNot, 2) : (4, .is, 1)
                case .not: return c.peek(1).isKW(.in) ? (4, .notIn, 2) : (0, .none, 0)
                default: return (0, .none, 0)
                }
            case .op:
                switch t.op {
                case .lt, .gt, .eq, .ge, .le, .ne: return (4, t.op, 1)
                case .pipe: return (5, .pipe, 1)
                case .caret: return (6, .caret, 1)
                case .amp: return (7, .amp, 1)
                case .shl, .shr: return (8, t.op, 1)
                case .plus, .minus: return (9, t.op, 1)
                case .star, .slash, .slashSlash, .percent: return (10, t.op, 1)
                case .starStar: return (12, .starStar, 1)
                default: return (0, .none, 0)
                }
            case .at: return (10, .matMul, 1)
            default: return (0, .none, 0)
            }
        }

        mutating func binary(_ minPrec: Int) {
            guard c.enter() else { return }
            defer { c.leave() }
            let m = c.mark
            let s = c.cur.start
            let t = c.cur
            if t.isKW(.not) {
                c.advance()
                binary(3)
                c.emit(.unary, m, s, c.lastEnd, aux: UInt16(Op.not.rawValue))
            } else if t.kind == .op, t.op == .minus || t.op == .plus || t.op == .tilde {
                c.advance()
                binary(11)
                c.emit(.unary, m, s, c.lastEnd, aux: UInt16(t.op.rawValue))
            } else if t.isKW(.await) {
                c.advance()
                primary()
                c.emit(.await, m, s, c.lastEnd)
            } else {
                primary()
            }
            while true {
                let (prec, op, width) = infix()
                if prec == 0 || prec < minPrec { break }
                for _ in 0..<width { c.advance() }
                if op == .starStar { binary(11) } else { binary(prec + 1) }
                c.emit(.binary, m, s, c.lastEnd, aux: UInt16(op.rawValue))
            }
        }

        mutating func primary() {
            guard c.enter() else { return }
            defer { c.leave() }
            let m = c.mark
            let s = c.cur.start
            atom()
            while true {
                switch c.kind {
                case .dot:
                    let gap = UInt16(clamping: max(0, Int(c.cur.start - c.nodes[c.nodes.count - 1].end)))
                    let dotEnd = c.cur.end
                    c.advance()
                    if isName(c.cur) {
                        c.leaf(.name)
                        c.emit(.member, m, s, c.lastEnd, aux: gap)
                    } else {
                        c.diag += 1
                        c.emit(.member, m, s, dotEnd, flags: NodeFlags.missingName, aux: gap)
                    }
                case .lparen:
                    let closed = callArgs()
                    c.emit(.call, m, s, closed ? c.lastEnd : closeEnd, flags: closed ? 0 : NodeFlags.missingClose)
                case .lbracket:
                    let closed = subscriptTrailerList()
                    c.emit(.subscript, m, s, closed ? c.lastEnd : closeEnd, flags: closed ? 0 : NodeFlags.missingClose)
                default:
                    return
                }
            }
        }

        /// `( args )`; returns false when the closer was missing.
        @discardableResult
        mutating func callArgs() -> Bool {
            let m = c.mark
            let s = c.cur.start
            c.advance()
            while !atLineEnd, c.kind != .rparen {
                let t = c.cur
                let am = c.mark
                if t.isOp(.star) || t.isOp(.starStar) {
                    c.advance()
                    test()
                    c.emit(.starred, am, t.start, c.lastEnd, aux: t.isOp(.star) ? 1 : 2)
                } else if isName(t), c.peek(1).isOp(.assign) {
                    c.leaf(.name)
                    c.advance()
                    test()
                    c.emit(.keywordArg, am, t.start, c.lastEnd)
                } else if canStartExpression(t) {
                    let before = c.i
                    namedExpr()
                    if c.i == before { c.skipOne(); continue }
                    if c.cur.isKW(.for) || (c.cur.isKW(.async) && c.peek(1).isKW(.for)) {
                        compFors()
                        c.emit(.genExp, am, t.start, c.lastEnd)
                    }
                } else if t.kind == .rbracket || t.kind == .rbrace {
                    break
                } else {
                    c.skipOne()
                    continue
                }
                if c.kind == .comma { c.advance() }
                else if c.kind != .rparen, canStartExpression(c.cur) { c.diag += 1 }
                else if c.kind != .rparen, !atLineEnd, c.kind != .rbracket, c.kind != .rbrace { c.skipOne() }
                else if c.kind == .rbracket || c.kind == .rbrace { break }
            }
            let closed = c.kind == .rparen
            if closed { c.advance() } else { c.diag += 1 }
            c.emit(.args, m, s, closed ? c.lastEnd : closeEnd, flags: closed ? 0 : NodeFlags.missingClose)
            return closed
        }

        @discardableResult
        mutating func subscriptTrailerList() -> Bool {
            c.advance()
            let m = c.mark
            let s = c.cur.start
            var count = 0
            while !atLineEnd, c.kind != .rbracket {
                if c.kind == .rparen || c.kind == .rbrace { break }
                let before = c.i
                sliceItem()
                count += 1
                if c.i == before { c.skipOne(); continue }
                if c.kind == .comma { c.advance() } else if c.kind != .rbracket {
                    if canStartExpression(c.cur) { c.diag += 1 } else if !atLineEnd, c.kind != .rparen, c.kind != .rbrace { c.skipOne() }
                    else { break }
                }
            }
            if count > 1 { c.emit(.tuple, m, s, c.lastEnd) }
            if count == 0 { c.missing() }
            let closed = c.kind == .rbracket
            if closed { c.advance() } else { c.diag += 1 }
            return closed
        }

        mutating func sliceItem() {
            let m = c.mark
            let s = c.cur.start
            var parts: UInt16 = 0
            if c.kind != .colon { starNamedExpr(); parts |= 1 }
            if c.kind == .colon {
                c.advance()
                if canStartExpression(c.cur) { test(); parts |= 2 }
                if c.kind == .colon {
                    c.advance()
                    if canStartExpression(c.cur) { test(); parts |= 4 }
                }
                c.emit(.slice, m, s, c.lastEnd, aux: parts)
            }
        }

        mutating func compFors() {
            while c.cur.isKW(.for) || (c.cur.isKW(.async) && c.peek(1).isKW(.for)) {
                let m = c.mark
                let s = c.cur.start
                var flags: UInt8 = 0
                if c.cur.isKW(.async) { c.advance(); flags = NodeFlags.async }
                c.advance()
                targetList()
                if c.cur.isKW(.in) { c.advance(); binary(1) } else { c.missing() }
                while c.cur.isKW(.if) {
                    let im = c.mark
                    let iS = c.cur.start
                    c.advance()
                    if c.cur.isKW(.lambda) { lambdef() } else { binary(1) }
                    c.emit(.compIf, im, iS, c.lastEnd)
                }
                c.emit(.compFor, m, s, c.lastEnd, flags: flags)
            }
        }

        mutating func atom() {
            let t = c.cur
            switch t.kind {
            case .ident:
                switch t.kw {
                case .none, .match, .case, .type: c.leaf(.name)
                case .pyNone, .pyTrue, .pyFalse: c.leaf(.keywordLit, aux: UInt16(t.sub))
                case .lambda: lambdef()
                case .yield: yieldExpr()
                case .await:
                    let m = c.mark
                    c.advance()
                    primary()
                    c.emit(.await, m, t.start, c.lastEnd)
                default: c.missing()
                }
            case .number: c.leaf(.number)
            case .string, .interpOpen: stringAtom()
            case .ellipsis: c.leaf(.ellipsisLit)
            case .lparen: parenAtom()
            case .lbracket: listAtom()
            case .lbrace: braceAtom()
            default: c.missing()
            }
        }

        mutating func stringAtom() {
            let m = c.mark
            let s = c.cur.start
            var flags: UInt8 = 0
            while true {
                if c.kind == .string {
                    c.advance()
                } else if c.kind == .interpOpen {
                    c.advance()
                    if c.kind != .interpClose {
                        if c.cur.isKW(.yield) { yieldExpr() } else { starExpressions() }
                        fieldTail()
                    }
                    if c.kind == .interpClose {
                        if c.cur.flags & Token.synthetic != 0 { flags = NodeFlags.missingClose; c.diag += 1 }
                        c.advance()
                    } else {
                        // Junk inside the field: skip to its closer.
                        var depth = 0
                        while c.kind != .eof, !(c.kind == .interpClose && depth == 0) {
                            if c.kind == .interpOpen { depth += 1 }
                            if c.kind == .interpClose { depth -= 1 }
                            c.skipOne()
                        }
                        if c.kind == .interpClose { c.advance() }
                    }
                } else {
                    break
                }
            }
            c.emit(.string, m, s, c.lastEnd, flags: flags)
        }

        /// After a replacement field's expression: `=`, `!conversion` and
        /// `:format spec`; the spec's nested `{expr}` fields are parsed into a
        /// `formatSpec` node (the rest of the spec is plain text to Python).
        mutating func fieldTail() {
            if c.cur.isOp(.assign) { c.advance() }
            if c.cur.isOp(.bang), c.peek(1).kind == .ident { c.advance(); c.advance() }
            guard c.kind == .colon else { return }
            let m = c.mark
            let s = c.cur.start
            c.advance()
            while c.kind != .eof, c.kind != .interpClose {
                if c.kind == .lbrace {
                    c.advance()
                    if c.kind != .rbrace, c.kind != .interpClose, !atLineEnd {
                        starExpressions()
                        fieldTail()
                    }
                    var depth = 0
                    while c.kind != .eof, c.kind != .interpClose, !(c.kind == .rbrace && depth == 0) {
                        if c.kind == .lbrace { depth += 1 }
                        if c.kind == .rbrace { depth -= 1 }
                        c.skipOne()
                    }
                    if c.kind == .rbrace { c.advance() }
                } else if c.kind == .interpOpen || c.kind == .string {
                    stringAtom()
                } else {
                    c.advance()
                }
            }
            c.emit(.formatSpec, m, s, c.lastEnd)
        }

        mutating func parenAtom() {
            let m = c.mark
            let s = c.cur.start
            c.advance()
            if c.kind == .rparen {
                c.advance()
                c.emit(.tuple, m, s, c.lastEnd)
                return
            }
            if c.cur.isKW(.yield) {
                yieldExpr()
                closeParen(m, s, .paren)
                return
            }
            starNamedExpr()
            if c.cur.isKW(.for) || (c.cur.isKW(.async) && c.peek(1).isKW(.for)) {
                compFors()
                closeParen(m, s, .genExp)
                return
            }
            if c.kind == .comma {
                while c.kind == .comma {
                    c.advance()
                    if !canStartExpression(c.cur) { break }
                    starNamedExpr()
                }
                closeParen(m, s, .tuple)
                return
            }
            closeParen(m, s, .paren)
        }

        mutating func closeParen(_ m: Int, _ s: Int32, _ kind: NK) {
            if c.kind != .rparen, !atLineEnd, c.kind != .rbracket, c.kind != .rbrace {
                // Junk before the closer.
                while !atLineEnd, c.kind != .rparen, c.kind != .rbracket, c.kind != .rbrace { c.skipOne() }
            }
            if c.kind == .rparen {
                c.advance()
                c.emit(kind, m, s, c.lastEnd)
            } else {
                c.diag += 1
                c.emit(kind, m, s, closeEnd, flags: NodeFlags.missingClose)
            }
        }

        mutating func listAtom() {
            let m = c.mark
            let s = c.cur.start
            c.advance()
            var kind: NK = .list
            if c.kind != .rbracket, !atLineEnd {
                starNamedExpr()
                if c.cur.isKW(.for) || (c.cur.isKW(.async) && c.peek(1).isKW(.for)) {
                    compFors()
                    kind = .listComp
                } else {
                    elementTail(closer: .rbracket) { p in p.starNamedExpr() }
                }
            }
            closeBracket(m, s, kind, .rbracket)
        }

        /// `, elem, elem …` up to the closer, with recovery.
        mutating func elementTail(closer: TK, _ element: (inout PythonParser) -> Void) {
            while !atLineEnd, c.kind != closer {
                if c.kind == .comma {
                    c.advance()
                    if c.kind == closer || atLineEnd { break }
                    let before = c.i
                    element(&self)
                    if c.i == before, !atLineEnd, c.kind != closer { c.skipOne() }
                } else if canStartExpression(c.cur) {
                    c.diag += 1 // missing comma
                    let before = c.i
                    element(&self)
                    if c.i == before { c.skipOne() }
                } else if c.kind == .rparen || c.kind == .rbracket || c.kind == .rbrace {
                    break
                } else {
                    c.skipOne()
                }
            }
        }

        mutating func closeBracket(_ m: Int, _ s: Int32, _ kind: NK, _ closer: TK, aux: UInt16 = 0) {
            if c.kind == closer {
                c.advance()
                c.emit(kind, m, s, c.lastEnd, aux: aux)
            } else {
                c.diag += 1
                c.emit(kind, m, s, closeEnd, flags: NodeFlags.missingClose, aux: aux)
            }
        }

        mutating func braceAtom() {
            let m = c.mark
            let s = c.cur.start
            c.advance()
            if c.kind == .rbrace || atLineEnd {
                closeBracket(m, s, .dict, .rbrace)
                return
            }
            if c.cur.isOp(.starStar) {
                dictTail(m, s)
                return
            }
            let em = c.mark
            let es = c.cur.start
            starNamedExpr()
            if c.kind == .colon {
                c.advance()
                test()
                c.emit(.pair, em, es, c.lastEnd)
                if c.cur.isKW(.for) || (c.cur.isKW(.async) && c.peek(1).isKW(.for)) {
                    compFors()
                    closeBracket(m, s, .dictComp, .rbrace)
                    return
                }
                if c.kind == .comma { c.advance() }
                dictTail(m, s)
                return
            }
            if c.cur.isKW(.for) || (c.cur.isKW(.async) && c.peek(1).isKW(.for)) {
                compFors()
                closeBracket(m, s, .setComp, .rbrace)
                return
            }
            elementTail(closer: .rbrace) { p in p.starNamedExpr() }
            closeBracket(m, s, .set, .rbrace)
        }

        mutating func dictTail(_ m: Int, _ s: Int32) {
            while !atLineEnd, c.kind != .rbrace {
                let em = c.mark
                let es = c.cur.start
                if c.cur.isOp(.starStar) {
                    c.advance()
                    binary(5)
                    c.emit(.starred, em, es, c.lastEnd, aux: 2)
                } else if canStartExpression(c.cur) {
                    let before = c.i
                    test()
                    if c.i == before { c.skipOne(); continue }
                    if c.kind == .colon { c.advance(); test() } else { c.missing() }
                    c.emit(.pair, em, es, c.lastEnd)
                } else if c.kind == .rparen || c.kind == .rbracket {
                    break
                } else {
                    c.skipOne()
                    continue
                }
                if c.kind == .comma { c.advance() } else if c.kind != .rbrace, !canStartExpression(c.cur), !c.cur.isOp(.starStar) {
                    if atLineEnd || c.kind == .rparen || c.kind == .rbracket { break }
                    c.skipOne()
                } else if c.kind != .rbrace { c.diag += 1 }
            }
            closeBracket(m, s, .dict, .rbrace)
        }
    }
}
