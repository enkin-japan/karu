import Foundation

// Recursive-descent / Pratt parser for JavaScript, TypeScript and TSX
// (M17 T17.11a; JSX through the scanner's JSX tokens), error tolerant:
// - statements end at `;`, `}`, the end of input or a line break (ASI); a
//   statement with trailing junk is synchronised at the next `;` / line
//   start / `}`;
// - an unclosed `(` `[` `{` (call, array, object, parameters, type
//   arguments …) is closed when a different closer, a line-initial statement
//   keyword that cannot continue the construct, or the end of input arrives;
// - a block left open is closed at a line-initial `export` / `import`, or at
//   a declaration keyword indented no deeper than the line that opened the
//   block (only when the block's content was indented deeper);
// - a function signature whose next line is indented deeper gets a missing
//   `{` inserted;
// - `x.` followed by `}` / `)` / a line-initial reserved word yields a member
//   node flagged `missingName`;
// - arrow functions and generic call arguments are recognised by bounded
//   lookahead / speculation with backtracking (`Core.snapshot`).
// JavaScript mode (`ts == false`) turns every TypeScript-only construct off
// (annotations, generics, `as` / `satisfies` / `!`, TS declarations), so
// valid JavaScript parses as JavaScript. The left side of a destructuring
// assignment becomes pattern nodes like a declaration's.

extension SyntaxParsing {
    struct ScriptParser {
        var c: Core
        /// TypeScript syntax is on (off: JavaScript).
        let ts: Bool
        /// The scanner reports JSX (so no `<T>expr` type assertions).
        let jsx: Bool
        /// Inside a conditional type's `extends` clause.
        var noConditional = false

        init(core: Core, dialect: SyntaxDialect) {
            c = core
            ts = dialect.hasTypes
            jsx = dialect.hasJSX
        }

        // MARK: Module

        /// Parses one top-level statement (the unit of slicing and of the
        /// incremental update). Does nothing at the end of input.
        mutating func topLevelStep() {
            guard c.kind != .eof else { return }
            c.compactTokens()
            c.beginTopLevel()
            let before = c.i
            if c.kind == .rbrace || c.kind == .rparen || c.kind == .rbracket {
                skipJunk()
            } else {
                statement()
            }
            if c.i == before, c.kind != .eof { c.skipOne() }
            c.endTopLevel()
        }

        // MARK: Token predicates

        @inline(__always) static func isReserved(_ k: KW) -> Bool {
            switch k {
            case .break, .case, .catch, .class, .const, .continue, .debugger, .default, .delete, .do, .else,
                 .enum, .export, .extends, .false, .finally, .for, .function, .if, .import, .in, .instanceof,
                 .new, .null, .return, .super, .switch, .this, .throw, .true, .try, .typeof, .var, .void,
                 .while, .with, .let, .yield, .await:
                return true
            default:
                return false
            }
        }

        /// An identifier usable as a binding / reference (contextual keywords too).
        @inline(__always) func isIdent(_ t: Token) -> Bool {
            t.kind == .ident && (t.sub == 0 || !ScriptParser.isReserved(t.kw))
        }

        /// Any identifier name (property names after `.`, object keys).
        @inline(__always) func isIdentName(_ t: Token) -> Bool { t.kind == .ident }

        func canStartExpression(_ t: Token) -> Bool {
            switch t.kind {
            case .ident:
                if !ScriptParser.isReserved(t.kw) { return true }
                switch t.kw {
                case .this, .super, .null, .true, .false, .new, .typeof, .void, .delete, .await, .yield,
                     .function, .class, .import:
                    return true
                default:
                    return false
                }
            case .number, .string, .regex, .lparen, .lbracket, .lbrace, .jsxLt, .privateName, .interpOpen, .at:
                return true
            case .op:
                switch t.op {
                case .bang, .tilde, .plus, .minus, .inc, .dec, .lt: return true
                default: return false
                }
            default:
                return false
            }
        }

        /// A line-initial word that starts a statement and cannot continue an
        /// open expression list (ends unclosed brackets).
        mutating func isStatementBoundary() -> Bool {
            let t = c.cur
            guard t.isLineStart, t.kind == .ident else { return false }
            switch t.kw {
            case .const, .var, .return, .if, .for, .while, .do, .switch, .try, .throw, .break, .continue, .export:
                return true
            case .interface, .enum, .declare:
                return ts
            case .let:
                return isIdent(c.peek(1)) || c.peek(1).kind == .lbrace || c.peek(1).kind == .lbracket
            case .import:
                let n = c.peek(1)
                return n.kind != .lparen && n.kind != .dot
            case .type:
                return ts && isIdent(c.peek(1)) && !c.peek(1).isLineStart
            default:
                return false
            }
        }

        /// End for a node whose closer is missing.
        var closeEnd: Int32 {
            mutating get { c.kind == .eof ? c.cur.start : c.lastEnd }
        }

        @inline(__always) var sameLine: Bool {
            mutating get { !c.cur.isLineStart }
        }

        // MARK: Statements

        /// `;`, or ASI (line break, `}`, end of input); otherwise skip junk.
        mutating func semicolon() {
            if c.kind == .semicolon { c.advance(); return }
            if c.kind == .rbrace || c.kind == .eof || c.cur.isLineStart { return }
            skipJunk()
            if c.kind == .semicolon { c.advance() }
        }

        /// Consumes tokens up to the next `;` / line start / `}` (at least one).
        mutating func skipJunk() {
            let m = c.mark
            let s = c.cur.start
            c.advance()
            while c.kind != .eof, c.kind != .semicolon, c.kind != .rbrace, !c.cur.isLineStart { c.advance() }
            c.diag += 1
            c.emit(.error, m, s, c.lastEnd)
        }

        mutating func statementList(openIndent: Int, namespace: Bool = false) {
            var contentIndent: Int? = nil
            while c.kind != .eof, c.kind != .rbrace {
                if c.cur.isLineStart {
                    if contentIndent == nil { contentIndent = Int(c.cur.indent) }
                    if let ci = contentIndent,
                       shouldCloseBlock(openIndent: openIndent, contentIndent: ci, namespace: namespace) { break }
                }
                let before = c.i
                if c.kind == .rparen || c.kind == .rbracket { skipJunk(); continue }
                statement()
                if c.i == before { c.skipOne() }
            }
        }

        mutating func shouldCloseBlock(openIndent: Int, contentIndent: Int, namespace: Bool = false) -> Bool {
            let t = c.cur
            guard t.kind == .ident else { return false }
            if !namespace {
                if t.kw == .export { return true }
                if t.kw == .import, c.peek(1).kind != .lparen, c.peek(1).kind != .dot { return true }
            }
            if namespace, t.kw == .export || t.kw == .import { return Int(t.indent) <= openIndent && contentIndent > openIndent }
            guard contentIndent > openIndent, Int(t.indent) <= openIndent else { return false }
            switch t.kw {
            case .function, .class, .const, .let, .var: return true
            case .interface, .enum, .declare: return ts
            case .async: return c.peek(1).isKW(.function)
            case .type: return ts && isIdent(c.peek(1))
            default: return false
            }
        }

        mutating func statement() {
            guard c.enter() else { return }
            defer { c.leave() }
            let t = c.cur
            let m = c.mark
            switch t.kind {
            case .lbrace:
                block()
                return
            case .semicolon:
                c.advance()
                c.emit(.emptyStmt, m, t.start, t.end)
                return
            case .at:
                decorators()
                if c.cur.isKW(.class) || (ts && c.cur.isKW(.abstract) && c.peek(1).isKW(.class)) {
                    if c.cur.isKW(.abstract) { c.advance() }
                    classLike(m, t.start, expression: false)
                } else if c.cur.isKW(.export) {
                    exportDecl(m, t.start)
                } else {
                    c.diag += 1
                    c.emit(.error, m, t.start, c.lastEnd)
                }
                return
            case .ident:
                break
            default:
                if !canStartExpression(t) {
                    skipJunk()
                    if c.kind == .semicolon { c.advance() }
                    return
                }
                expressionStatement()
                return
            }
            let n = c.peek(1)
            switch t.kw {
            case .var, .const:
                if ts, t.kw == .const, n.isKW(.enum) { c.advance(); enumDecl(m, t.start); return }
                varDecl(m, t.start, noIn: false)
                semicolon()
            case .let where isIdent(n) || n.kind == .lbrace || n.kind == .lbracket:
                varDecl(m, t.start, noIn: false)
                semicolon()
            case .using where isIdent(n) && !n.isLineStart:
                varDecl(m, t.start, noIn: false)
                semicolon()
            case .function:
                functionDecl(m, t.start, flags: 0)
            case .async where n.isKW(.function) && !n.isLineStart:
                c.advance()
                functionDecl(m, t.start, flags: NodeFlags.async)
            case .class:
                classLike(m, t.start, expression: false)
            case .abstract where ts && n.isKW(.class):
                c.advance()
                classLike(m, t.start, expression: false)
            case .interface where ts && isIdent(n) && !n.isLineStart:
                interfaceDecl(m, t.start)
            case .type where ts && isIdent(n) && !n.isLineStart:
                typeAliasDecl(m, t.start)
            case .enum where ts && isIdent(n):
                enumDecl(m, t.start)
            case .declare where ts && !n.isLineStart && (n.kind == .ident):
                c.advance()
                let before = c.nodes.count
                statement()
                if c.nodes.count > before { c.nodes[c.nodes.count - 1].flags |= NodeFlags.modifier }
            case .namespace where ts && (isIdent(n) || n.kind == .string) && !n.isLineStart,
                 .module where ts && (isIdent(n) || n.kind == .string) && !n.isLineStart:
                namespaceDecl(m, t.start)
            case .global where ts && n.kind == .lbrace:
                namespaceDecl(m, t.start)
            case .import where n.kind != .lparen && n.kind != .dot:
                importDecl(m, t.start)
            case .export:
                exportDecl(m, t.start)
            case .if: ifStmt()
            case .for: forStmt()
            case .while:
                c.advance()
                parenCondition()
                statement()
                c.emit(.whileStmt, m, t.start, c.lastEnd)
            case .do:
                c.advance()
                statement()
                if c.cur.isKW(.while) { c.advance(); parenCondition() } else { c.missing() }
                if c.kind == .semicolon { c.advance() }
                c.emit(.doWhile, m, t.start, c.lastEnd)
            case .switch: switchStmt()
            case .try: tryStmt()
            case .return:
                c.advance()
                if c.kind != .semicolon, c.kind != .rbrace, c.kind != .eof, sameLine { expression(noIn: false) }
                semicolon()
                c.emit(.returnStmt, m, t.start, c.lastEnd)
            case .throw:
                c.advance()
                if c.kind != .semicolon, c.kind != .rbrace, c.kind != .eof { expression(noIn: false) } else { c.missing() }
                semicolon()
                c.emit(.throwStmt, m, t.start, c.lastEnd)
            case .break, .continue:
                c.advance()
                if isIdent(c.cur), sameLine { c.leaf(.name) }
                semicolon()
                c.emit(t.kw == .break ? .breakStmt : .continueStmt, m, t.start, c.lastEnd)
            case .debugger:
                c.advance()
                semicolon()
                c.emit(.debuggerStmt, m, t.start, c.lastEnd)
            case .with:
                c.advance()
                parenCondition()
                statement()
                c.emit(.whileStmt, m, t.start, c.lastEnd, aux: 1)
            case .else, .case, .default, .catch, .finally, .extends, .implements:
                skipJunk()
            default:
                if isIdent(t), n.kind == .colon {
                    c.leaf(.name)
                    c.advance()
                    statement()
                    c.emit(.labeled, m, t.start, c.lastEnd)
                    return
                }
                if !canStartExpression(t) {
                    skipJunk()
                    return
                }
                expressionStatement()
            }
        }

        mutating func expressionStatement() {
            let m = c.mark
            let s = c.cur.start
            expression(noIn: false)
            semicolon()
            c.emit(.exprStmt, m, s, c.lastEnd)
        }

        mutating func block(namespace: Bool = false) {
            let m = c.mark
            let s = c.cur.start
            let openIndent = c.lineIndent(s)
            c.advance()
            statementList(openIndent: openIndent, namespace: namespace)
            if c.kind == .rbrace {
                c.advance()
                c.emit(.block, m, s, c.lastEnd)
            } else {
                c.diag += 1
                c.emit(.block, m, s, closeEnd, flags: NodeFlags.missingClose)
            }
        }

        mutating func parenCondition() {
            if c.kind == .lparen { c.advance() } else { c.missing() }
            expression(noIn: false)
            if c.kind == .rparen { c.advance() } else { c.diag += 1 }
        }

        mutating func ifStmt() {
            let m = c.mark
            let s = c.cur.start
            c.advance()
            parenCondition()
            statement()
            if c.cur.isKW(.else) {
                c.advance()
                statement()
            }
            c.emit(.ifStmt, m, s, c.lastEnd)
        }

        mutating func forStmt() {
            let m = c.mark
            let s = c.cur.start
            c.advance()
            if c.cur.isKW(.await) { c.advance() }
            if c.kind == .lparen { c.advance() } else { c.missing() }
            var kind: NK = .forStmt
            if c.kind == .semicolon {
                // empty init
            } else if c.cur.isKW(.var) || c.cur.isKW(.const)
                        || (c.cur.isKW(.let) && (isIdent(c.peek(1)) || c.peek(1).kind == .lbrace || c.peek(1).kind == .lbracket))
                        || (c.cur.isKW(.using) && isIdent(c.peek(1))) {
                varDecl(c.mark, c.cur.start, noIn: true)
            } else {
                let em = c.mark
                expression(noIn: true)
                if c.cur.isKW(.of) || c.cur.isKW(.in), c.nodes.count == em + Int(c.nodes[c.nodes.count - 1].size) + 1 {
                    toPattern(c.nodes.count - 1)
                }
            }
            if c.cur.isKW(.of) || c.cur.isKW(.in) {
                kind = c.cur.isKW(.of) ? .forOf : .forIn
                c.advance()
                assignment(noIn: false)
            } else {
                if c.kind == .semicolon { c.advance() } else { c.missing() }
                if c.kind != .semicolon { expression(noIn: false) }
                if c.kind == .semicolon { c.advance() } else { c.missing() }
                if c.kind != .rparen { expression(noIn: false) }
            }
            if c.kind == .rparen { c.advance() } else { c.diag += 1 }
            statement()
            c.emit(kind, m, s, c.lastEnd)
        }

        mutating func switchStmt() {
            let m = c.mark
            let s = c.cur.start
            c.advance()
            parenCondition()
            let openIndent = c.lineIndent(c.cur.start)
            if c.kind == .lbrace { c.advance() } else { c.missing() }
            while c.kind != .eof, c.kind != .rbrace {
                if c.cur.isKW(.case) || c.cur.isKW(.default) {
                    let cm = c.mark
                    let cs = c.cur.start
                    let isCase = c.cur.isKW(.case)
                    c.advance()
                    if isCase { expression(noIn: false) }
                    if c.kind == .colon { c.advance() } else { c.missing() }
                    while c.kind != .eof, c.kind != .rbrace, !c.cur.isKW(.case), !c.cur.isKW(.default) {
                        if c.cur.isLineStart, shouldCloseBlock(openIndent: openIndent, contentIndent: openIndent + 1) { break }
                        let before = c.i
                        statement()
                        if c.i == before { c.skipOne() }
                    }
                    c.emit(.switchCase, cm, cs, c.lastEnd)
                } else if c.cur.isLineStart, shouldCloseBlock(openIndent: openIndent, contentIndent: openIndent + 1) {
                    break
                } else {
                    skipJunk()
                }
            }
            if c.kind == .rbrace { c.advance() } else { c.diag += 1 }
            c.emit(.switchStmt, m, s, c.lastEnd)
        }

        mutating func tryStmt() {
            let m = c.mark
            let s = c.cur.start
            c.advance()
            if c.kind == .lbrace { block() } else { c.missing() }
            if c.cur.isKW(.catch) {
                let cm = c.mark
                let cs = c.cur.start
                c.advance()
                if c.kind == .lparen {
                    c.advance()
                    bindingTarget()
                    if ts, c.kind == .colon { c.advance(); type() }
                    if c.kind == .rparen { c.advance() } else { c.diag += 1 }
                }
                if c.kind == .lbrace { block() } else { c.missing() }
                c.emit(.catchClause, cm, cs, c.lastEnd)
            }
            if c.cur.isKW(.finally) {
                c.advance()
                if c.kind == .lbrace { block() } else { c.missing() }
            }
            c.emit(.tryStmt, m, s, c.lastEnd)
        }

        // MARK: Declarations

        mutating func varDecl(_ m: Int, _ s: Int32, noIn: Bool) {
            let kw = c.cur.kw
            let aux: UInt16 = kw == .var ? 0 : kw == .let ? 1 : kw == .const ? 2 : 3
            c.advance()
            repeat {
                if c.kind == .comma { c.advance() }
                let dm = c.mark
                let ds = c.cur.start
                var daux: UInt16 = 0
                if isIdent(c.cur) || c.kind == .lbrace || c.kind == .lbracket {
                    bindingTarget()
                } else {
                    c.missing()
                    // `let 5x = …`: skip to `=` / `,` / `;` / the line end.
                    if !(c.cur.isOp(.assign) || c.kind == .comma || c.kind == .semicolon || c.kind == .eof
                         || c.kind == .rbrace || c.cur.isLineStart || c.cur.isKW(.of) || c.cur.isKW(.in)) {
                        let em = c.mark
                        let es = c.cur.start
                        while !(c.cur.isOp(.assign) || c.kind == .comma || c.kind == .semicolon || c.kind == .eof
                                || c.kind == .rbrace || c.cur.isLineStart) { c.advance() }
                        c.emit(.error, em, es, c.lastEnd)
                    }
                }
                if ts, c.cur.isOp(.bang) { c.advance() }
                if ts, c.kind == .colon { c.advance(); type(); daux |= 1 }
                if c.cur.isOp(.assign) { c.advance(); assignment(noIn: noIn); daux |= 2 }
                c.emit(.declarator, dm, ds, c.lastEnd, aux: daux)
            } while c.kind == .comma
            c.emit(.varDecl, m, s, c.lastEnd, aux: aux)
        }

        /// Binding identifier or destructuring pattern.
        mutating func bindingTarget() {
            guard c.enter() else { return }
            defer { c.leave() }
            switch c.kind {
            case .lbrace: objectPattern()
            case .lbracket: arrayPattern()
            default:
                if isIdent(c.cur) { c.leaf(.name) } else { c.missing() }
            }
        }

        mutating func bindingElement() {
            let m = c.mark
            let s = c.cur.start
            bindingTarget()
            if c.cur.isOp(.assign) {
                c.advance()
                assignment(noIn: false)
                c.emit(.assignPattern, m, s, c.lastEnd)
            }
        }

        mutating func objectPattern() {
            let m = c.mark
            let s = c.cur.start
            c.advance()
            while c.kind != .rbrace, c.kind != .eof {
                let pm = c.mark
                let ps = c.cur.start
                if c.kind == .ellipsis {
                    c.advance()
                    bindingTarget()
                    c.emit(.restElement, pm, ps, c.lastEnd)
                } else if c.kind == .lbracket || c.kind == .string || c.kind == .number || isIdentName(c.cur) {
                    let shorthand = isIdent(c.cur) && c.peek(1).kind != .colon
                    if shorthand {
                        c.leaf(.name)
                        if c.cur.isOp(.assign) { c.advance(); assignment(noIn: false) }
                        c.emit(.patternProp, pm, ps, c.lastEnd, aux: 1)
                    } else {
                        propertyKey()
                        if c.kind == .colon { c.advance(); bindingElement() } else { c.missing() }
                        c.emit(.patternProp, pm, ps, c.lastEnd, aux: 2)
                    }
                } else if c.kind == .rparen || c.kind == .semicolon || c.cur.isOp(.assign) {
                    break
                } else {
                    c.skipOne()
                    continue
                }
                if c.kind == .comma { c.advance() } else if c.kind != .rbrace { break }
            }
            let closed = c.kind == .rbrace
            if closed { c.advance() } else { c.diag += 1 }
            c.emit(.objectPattern, m, s, closed ? c.lastEnd : closeEnd, flags: closed ? 0 : NodeFlags.missingClose)
        }

        mutating func arrayPattern() {
            let m = c.mark
            let s = c.cur.start
            c.advance()
            while c.kind != .rbracket, c.kind != .eof {
                if c.kind == .comma {
                    c.emit(.elision, c.mark, c.cur.start, c.cur.start)
                    c.advance()
                    continue
                }
                let pm = c.mark
                let ps = c.cur.start
                if c.kind == .ellipsis {
                    c.advance()
                    bindingTarget()
                    c.emit(.restElement, pm, ps, c.lastEnd)
                } else if isIdent(c.cur) || c.kind == .lbrace || c.kind == .lbracket {
                    bindingElement()
                } else {
                    break
                }
                if c.kind == .comma { c.advance() } else if c.kind != .rbracket { break }
            }
            let closed = c.kind == .rbracket
            if closed { c.advance() } else { c.diag += 1 }
            c.emit(.arrayPattern, m, s, closed ? c.lastEnd : closeEnd, flags: closed ? 0 : NodeFlags.missingClose)
        }

        mutating func functionDecl(_ m: Int, _ s: Int32, flags: UInt8) {
            var flags = flags
            c.advance() // function
            if c.cur.isOp(.star) { c.advance(); flags |= NodeFlags.generator }
            if isIdent(c.cur) { c.leaf(.name) }
            signatureAndBody(start: s)
            c.emit(.funcDecl, m, s, c.lastEnd, flags: flags)
        }

        /// Type parameters, parameters, return type and body of a function.
        mutating func signatureAndBody(start: Int32, bodyRequired: Bool = false) {
            if ts, c.cur.isOp(.lt) { typeParams() }
            if c.kind == .lparen { params() } else { c.missing() }
            if ts, c.kind == .colon { c.advance(); returnType() }
            if c.kind == .lbrace {
                block()
            } else if c.kind == .semicolon {
                c.advance()
            } else if c.kind != .eof, c.cur.isLineStart, Int(c.cur.indent) > c.lineIndent(start),
                      c.kind != .rbrace, canStartStatement(c.cur) {
                // Missing `{`: the deeper-indented lines are the body, up to `}`.
                let m = c.mark
                let s = c.lastEnd
                c.diag += 1
                statementList(openIndent: c.lineIndent(start))
                if c.kind == .rbrace { c.advance() }
                c.emit(.block, m, s, c.lastEnd, flags: NodeFlags.recovered)
            } else if bodyRequired {
                c.missing()
            }
        }

        func canStartStatement(_ t: Token) -> Bool {
            if canStartExpression(t) { return true }
            if t.kind == .ident {
                switch t.kw {
                case .const, .let, .var, .if, .for, .while, .do, .return, .throw, .try, .switch, .break, .continue:
                    return true
                default: return false
                }
            }
            return t.kind == .semicolon
        }

        mutating func decorators() {
            while c.kind == .at {
                let m = c.mark
                let s = c.cur.start
                c.advance()
                leftHandSide(allowCall: true)
                c.emit(.decorator, m, s, c.lastEnd)
            }
        }

        mutating func classLike(_ m: Int, _ s: Int32, expression: Bool) {
            c.advance() // class
            if isIdent(c.cur), !(ts && c.cur.isKW(.implements)) { c.leaf(.name) }
            if ts, c.cur.isOp(.lt) { typeParams() }
            while c.cur.isKW(.extends) || (ts && c.cur.isKW(.implements)) {
                let hm = c.mark
                let hs = c.cur.start
                let ext = c.cur.isKW(.extends)
                c.advance()
                repeat {
                    if c.kind == .comma { c.advance() }
                    if ext {
                        leftHandSide(allowCall: true)
                        if ts, c.cur.isOp(.lt) { typeArgs() }
                    } else {
                        type()
                    }
                } while c.kind == .comma
                c.emit(.heritage, hm, hs, c.lastEnd, aux: ext ? 0 : 1)
            }
            classBody()
            c.emit(expression ? .classExpr : .classDecl, m, s, c.lastEnd)
        }

        mutating func classBody() {
            let m = c.mark
            let s = c.cur.start
            guard c.kind == .lbrace else {
                c.missing()
                c.emit(.classBody, m, s, s, flags: NodeFlags.recovered)
                return
            }
            let openIndent = c.lineIndent(s)
            c.advance()
            var contentIndent: Int? = nil
            while c.kind != .eof, c.kind != .rbrace {
                if c.cur.isLineStart {
                    if contentIndent == nil { contentIndent = Int(c.cur.indent) }
                    if let ci = contentIndent, shouldCloseClass(openIndent: openIndent, contentIndent: ci) { break }
                }
                let before = c.i
                classMember()
                if c.i == before { c.skipOne() }
            }
            if c.kind == .rbrace {
                c.advance()
                c.emit(.classBody, m, s, c.lastEnd)
            } else {
                c.diag += 1
                c.emit(.classBody, m, s, closeEnd, flags: NodeFlags.missingClose)
            }
        }

        mutating func shouldCloseClass(openIndent: Int, contentIndent: Int) -> Bool {
            let t = c.cur
            guard t.kind == .ident else { return false }
            if t.kw == .export { return true }
            if t.kw == .import, c.peek(1).kind != .lparen { return true }
            guard contentIndent > openIndent, Int(t.indent) <= openIndent else { return false }
            switch t.kw {
            case .function, .class, .interface, .enum, .const, .let, .var:
                return isIdent(c.peek(1)) || c.peek(1).kind == .lbrace || c.peek(1).kind == .lbracket
            default:
                return false
            }
        }

        @inline(__always) func isModifier(_ k: KW) -> Bool {
            switch k {
            case .static, .accessor, .async, .get, .set:
                return true
            case .public, .private, .protected, .readonly, .abstract, .override, .declare:
                return ts
            default:
                return false
            }
        }

        /// The token after a modifier keeps it a modifier (a member name follows
        /// on the same line).
        mutating func modifierApplies() -> Bool {
            let n = c.peek(1)
            if n.isLineStart && (c.cur.isKW(.async) || c.cur.isKW(.get) || c.cur.isKW(.set)) { return false }
            switch n.kind {
            case .ident, .string, .number, .lbracket, .privateName: return true
            case .op: return n.op == .star
            case .lbrace: return c.cur.isKW(.static)
            default: return false
            }
        }

        mutating func classMember() {
            let m = c.mark
            let s = c.cur.start
            if c.kind == .semicolon { c.advance(); return }
            if c.kind == .at { decorators() }
            var flags: UInt8 = 0
            var aux: UInt16 = 0
            while c.kind == .ident, isModifier(c.cur.kw), modifierApplies() {
                switch c.cur.kw {
                case .static:
                    if c.peek(1).kind == .lbrace {
                        c.advance()
                        block()
                        c.emit(.staticBlock, m, s, c.lastEnd)
                        return
                    }
                    flags |= NodeFlags.isStatic
                case .async: flags |= NodeFlags.async
                case .get: aux = 1
                case .set: aux = 2
                default: break
                }
                c.advance()
            }
            if c.cur.isOp(.star) { flags |= NodeFlags.generator; c.advance() }
            // Index signature `[key: T]: U`.
            if ts, c.kind == .lbracket, isIdent(c.peek(1)), c.peek(2).kind == .colon {
                indexSignature(m, s)
                semicolonMember()
                return
            }
            guard c.kind == .ident || c.kind == .string || c.kind == .number || c.kind == .lbracket
                    || c.kind == .privateName else {
                if c.kind == .rbrace { return }
                c.skipOne()
                return
            }
            if c.kind == .ident, c.tokenIs(c.cur, "constructor"), c.peek(1).kind == .lparen { aux = 3 }
            propertyKey()
            if ts, c.kind == .question || c.cur.isOp(.bang) {
                if c.kind == .question { flags |= NodeFlags.optional }
                c.advance()
            }
            if c.kind == .lparen || (ts && c.cur.isOp(.lt)) {
                signatureAndBody(start: s)
                c.emit(.method, m, s, c.lastEnd, flags: flags, aux: aux)
                if c.kind == .semicolon { c.advance() }
                return
            }
            var paux: UInt16 = 0
            if ts, c.kind == .colon { c.advance(); type(); paux |= 1 }
            if c.cur.isOp(.assign) { c.advance(); assignment(noIn: false); paux |= 2 }
            semicolonMember()
            c.emit(.property, m, s, c.lastEnd, flags: flags, aux: paux)
        }

        mutating func semicolonMember() {
            if c.kind == .semicolon || c.kind == .comma { c.advance(); return }
            if c.kind == .rbrace || c.kind == .eof || c.cur.isLineStart { return }
            skipJunk()
            if c.kind == .semicolon { c.advance() }
        }

        mutating func indexSignature(_ m: Int, _ s: Int32) {
            c.advance() // [
            let pm = c.mark
            let ps = c.cur.start
            let qm = c.mark
            c.leaf(.name)
            c.advance() // :
            type()
            c.emit(.param, qm, ps, c.lastEnd, aux: 4)
            c.emit(.params, pm, ps, c.lastEnd)
            if c.kind == .rbracket { c.advance() } else { c.diag += 1 }
            if c.kind == .colon { c.advance(); type() }
            c.emit(.indexSig, m, s, c.lastEnd)
        }

        /// Property name: identifier / keyword, string, number, `[computed]`, `#private`.
        mutating func propertyKey() {
            switch c.kind {
            case .ident: c.leaf(.name)
            case .string: c.leaf(.string)
            case .number: c.leaf(.number)
            case .privateName: c.leaf(.privateName)
            case .lbracket:
                let m = c.mark
                let s = c.cur.start
                c.advance()
                assignment(noIn: false)
                if c.kind == .rbracket { c.advance() } else { c.diag += 1 }
                c.emit(.computedKey, m, s, c.lastEnd)
            default:
                c.missing()
            }
        }

        mutating func interfaceDecl(_ m: Int, _ s: Int32) {
            c.advance()
            c.leaf(.name)
            if c.cur.isOp(.lt) { typeParams() }
            if c.cur.isKW(.extends) {
                let hm = c.mark
                let hs = c.cur.start
                c.advance()
                repeat {
                    if c.kind == .comma { c.advance() }
                    type()
                } while c.kind == .comma
                c.emit(.heritage, hm, hs, c.lastEnd)
            }
            if c.kind == .lbrace { objectType() } else { c.missing() }
            c.emit(.interfaceDecl, m, s, c.lastEnd)
        }

        mutating func typeAliasDecl(_ m: Int, _ s: Int32) {
            c.advance()
            c.leaf(.name)
            if c.cur.isOp(.lt) { typeParams() }
            if c.cur.isOp(.assign) { c.advance(); type() } else { c.missing() }
            semicolon()
            c.emit(.typeAlias, m, s, c.lastEnd)
        }

        mutating func enumDecl(_ m: Int, _ s: Int32) {
            c.advance() // enum
            if isIdent(c.cur) { c.leaf(.name) } else { c.missing() }
            guard c.kind == .lbrace else {
                c.missing()
                c.emit(.enumDecl, m, s, c.lastEnd)
                return
            }
            c.advance()
            while c.kind != .rbrace, c.kind != .eof {
                if isStatementBoundary() { break }
                let em = c.mark
                let es = c.cur.start
                if c.kind == .ident || c.kind == .string || c.kind == .number || c.kind == .lbracket {
                    propertyKey()
                    if c.cur.isOp(.assign) { c.advance(); assignment(noIn: false) }
                    c.emit(.enumMember, em, es, c.lastEnd)
                } else {
                    c.skipOne()
                    continue
                }
                if c.kind == .comma { c.advance() } else if c.kind != .rbrace, !c.cur.isLineStart { c.skipOne() }
            }
            if c.kind == .rbrace { c.advance() } else { c.diag += 1 }
            c.emit(.enumDecl, m, s, c.lastEnd)
        }

        mutating func namespaceDecl(_ m: Int, _ s: Int32) {
            c.advance()
            if c.kind == .string { c.leaf(.string) } else if isIdentName(c.cur) {
                let qm = c.mark
                let qs = c.cur.start
                c.leaf(.name)
                while c.kind == .dot {
                    c.advance()
                    if isIdentName(c.cur) { c.leaf(.name) } else { c.missing(); break }
                }
                c.emit(.qualifiedName, qm, qs, c.lastEnd)
            }
            if c.kind == .lbrace { block(namespace: true) } else { semicolon() }
            c.emit(.namespaceDecl, m, s, c.lastEnd)
        }

        mutating func moduleSource() {
            if c.kind == .string { c.leaf(.string) } else { c.missing() }
        }

        /// `import …` (aux: `SyntaxAux.typeOnly` for `import type`).
        mutating func importDecl(_ m: Int, _ s: Int32) {
            c.advance() // import
            var declAux: UInt16 = 0
            if ts, c.cur.isKW(.type), c.peek(1).kind == .lbrace || c.peek(1).isOp(.star)
                || (isIdent(c.peek(1)) && !c.peek(1).isKW(.from)) || (c.peek(1).isKW(.from) && c.peek(2).isKW(.from)) {
                c.advance()
                declAux = SyntaxAux.typeOnly
            }
            if c.kind == .string {
                c.leaf(.string)
                semicolon()
                c.emit(.importDecl, m, s, c.lastEnd, aux: declAux)
                return
            }
            if isIdent(c.cur), !(c.cur.isKW(.from) && c.peek(1).kind == .string) {
                let sm = c.mark
                let ss = c.cur.start
                c.leaf(.name)
                if ts, c.cur.isOp(.assign) {
                    // `import x = require("m")` / `= A.B`
                    c.advance()
                    assignment(noIn: false)
                    c.emit(.importSpec, sm, ss, c.lastEnd, aux: 3 | declAux)
                    semicolon()
                    c.emit(.importDecl, m, s, c.lastEnd, aux: declAux)
                    return
                }
                c.emit(.importSpec, sm, ss, c.lastEnd, aux: 1 | declAux)
                if c.kind == .comma { c.advance() }
            }
            if c.cur.isOp(.star) {
                let sm = c.mark
                let ss = c.cur.start
                c.advance()
                if c.cur.isKW(.as) { c.advance() } else { c.diag += 1 }
                if isIdent(c.cur) { c.leaf(.name) } else { c.missing() }
                c.emit(.importSpec, sm, ss, c.lastEnd, aux: 2 | declAux)
            } else if c.kind == .lbrace {
                namedSpecifiers(.importSpec, aux: declAux)
            }
            if c.cur.isKW(.from) {
                c.advance()
                moduleSource()
            } else {
                c.missing()
            }
            importAttributes()
            semicolon()
            c.emit(.importDecl, m, s, c.lastEnd, aux: declAux)
        }

        /// `with { type: "json" }` / `assert { … }` after a module source.
        mutating func importAttributes() {
            guard c.cur.isKW(.with) || (c.kind == .ident && c.tokenIs(c.cur, "assert")),
                  c.peek(1).kind == .lbrace, !c.cur.isLineStart else { return }
            c.advance()
            objectLiteral()
        }

        /// `{ a, b as c, type T }`; a specifier's aux is `aux`, plus
        /// `SyntaxAux.typeOnly` for a `type` modifier.
        mutating func namedSpecifiers(_ kind: NK, aux: UInt16 = 0) {
            c.advance() // {
            while c.kind != .rbrace, c.kind != .eof {
                if c.cur.isLineStart, isStatementBoundary() { break }
                let sm = c.mark
                let ss = c.cur.start
                var specAux = aux
                if ts, c.cur.isKW(.type), c.peek(1).kind == .ident || c.peek(1).kind == .string,
                   !(c.peek(1).isKW(.as) && !(c.peek(2).kind == .ident || c.peek(2).kind == .string)) {
                    // `type X`, `type as`, `type as as y` (not `type as y`: `type` is the name).
                    c.advance()
                    specAux |= SyntaxAux.typeOnly
                }
                if c.kind == .ident || c.kind == .string {
                    c.leaf(c.kind == .string ? .string : .name)
                    if c.cur.isKW(.as) {
                        c.advance()
                        if c.kind == .ident || c.kind == .string { c.leaf(.name) } else { c.missing() }
                    }
                    c.emit(kind, sm, ss, c.lastEnd, aux: specAux)
                } else if c.kind == .semicolon || c.kind == .rparen {
                    break
                } else {
                    c.skipOne()
                    continue
                }
                if c.kind == .comma { c.advance() } else if c.kind != .rbrace { break }
            }
            if c.kind == .rbrace { c.advance() } else { c.diag += 1 }
        }

        /// `export …` (aux 0 a declaration, 1 `default`, 2 a list / re-export
        /// / assignment; plus `SyntaxAux.typeOnly` for `export type { … }` /
        /// `export type * …`).
        mutating func exportDecl(_ m: Int, _ s: Int32) {
            c.advance() // export
            let t = c.cur
            if t.isKW(.default) {
                c.advance()
                let n = c.peek(1)
                let dm = c.mark
                let ds = c.cur.start
                if c.cur.isKW(.function) {
                    functionDecl(dm, ds, flags: 0)
                } else if c.cur.isKW(.async), n.isKW(.function), !n.isLineStart {
                    c.advance()
                    functionDecl(dm, ds, flags: NodeFlags.async)
                } else if c.cur.isKW(.class) {
                    classLike(dm, ds, expression: false)
                } else if ts, c.cur.isKW(.abstract), n.isKW(.class) {
                    c.advance()
                    classLike(dm, ds, expression: false)
                } else if ts, c.cur.isKW(.interface), isIdent(n) {
                    interfaceDecl(dm, ds)
                } else if c.kind == .at {
                    statement()
                } else {
                    assignment(noIn: false)
                    semicolon()
                }
                c.emit(.exportDecl, m, s, c.lastEnd, aux: 1)
                return
            }
            var typeOnly: UInt16 = 0
            if ts, t.isKW(.type), c.peek(1).kind == .lbrace || c.peek(1).isOp(.star) {
                c.advance()
                typeOnly = SyntaxAux.typeOnly
            }
            if c.cur.isOp(.star) {
                c.advance()
                if c.cur.isKW(.as) {
                    c.advance()
                    if c.kind == .ident || c.kind == .string { c.leaf(.name) } else { c.missing() }
                }
                if c.cur.isKW(.from) { c.advance(); moduleSource() } else { c.missing() }
                importAttributes()
                semicolon()
                c.emit(.exportDecl, m, s, c.lastEnd, aux: 2 | typeOnly)
                return
            }
            if c.kind == .lbrace {
                namedSpecifiers(.exportSpec, aux: typeOnly)
                if c.cur.isKW(.from) { c.advance(); moduleSource(); importAttributes() }
                semicolon()
                c.emit(.exportDecl, m, s, c.lastEnd, aux: 2 | typeOnly)
                return
            }
            if ts, t.isOp(.assign) {
                c.advance()
                assignment(noIn: false)
                semicolon()
                c.emit(.exportDecl, m, s, c.lastEnd, aux: 2)
                return
            }
            if ts, t.isKW(.as), c.peek(1).isKW(.namespace) {
                c.advance(); c.advance()
                if isIdent(c.cur) { c.leaf(.name) }
                semicolon()
                c.emit(.exportDecl, m, s, c.lastEnd, aux: 2)
                return
            }
            if t.kind == .eof || (t.isLineStart && t.kind != .ident) {
                c.missing()
            } else {
                statement()
            }
            c.emit(.exportDecl, m, s, c.lastEnd, aux: 0)
        }

        // MARK: Parameters

        mutating func params() {
            let m = c.mark
            let s = c.cur.start
            c.advance() // (
            while c.kind != .rparen, c.kind != .eof {
                if c.cur.isLineStart, isStatementBoundary() { break }
                if c.kind == .rbrace || c.kind == .rbracket || c.kind == .semicolon || c.kind == .arrow { break }
                let pm = c.mark
                let ps = c.cur.start
                var aux: UInt16 = 0
                var flags: UInt8 = 0
                if c.kind == .at { decorators() }
                while ts, c.kind == .ident, [KW.public, .private, .protected, .readonly, .override].contains(c.cur.kw),
                      isIdent(c.peek(1)) || c.peek(1).kind == .lbrace || c.peek(1).kind == .lbracket {
                    aux |= 2
                    c.advance()
                }
                if c.kind == .ellipsis { aux |= 1; c.advance() }
                if ts, c.cur.isKW(.this) {
                    c.leaf(.keywordLit)
                } else if isIdent(c.cur) || c.kind == .lbrace || c.kind == .lbracket {
                    bindingTarget()
                } else {
                    c.skipOne()
                    continue
                }
                if ts, c.kind == .question { flags |= NodeFlags.optional; c.advance() }
                if ts, c.kind == .colon { c.advance(); type(); aux |= 4 }
                if c.cur.isOp(.assign) { c.advance(); assignment(noIn: false); aux |= 8 }
                c.emit(.param, pm, ps, c.lastEnd, flags: flags, aux: aux)
                if c.kind == .comma { c.advance() } else if c.kind != .rparen {
                    if canStartExpression(c.cur), !c.cur.isLineStart, isIdent(c.cur) || c.kind == .lbrace || c.kind == .lbracket {
                        c.diag += 1
                    } else { break }
                }
            }
            let closed = c.kind == .rparen
            if closed { c.advance() } else { c.diag += 1 }
            c.emit(.params, m, s, closed ? c.lastEnd : closeEnd, flags: closed ? 0 : NodeFlags.missingClose)
        }

        // MARK: Expressions

        mutating func expression(noIn: Bool) {
            let m = c.mark
            let s = c.cur.start
            assignment(noIn: noIn)
            if c.kind == .comma {
                while c.kind == .comma {
                    c.advance()
                    assignment(noIn: noIn)
                }
                c.emit(.sequence, m, s, c.lastEnd)
            }
        }

        /// Token offset of the `)` matching the `(` at offset `k` from the cursor.
        mutating func matchingParen(_ k: Int) -> Int? {
            var depth = 0
            var j = k
            while j - k < 4096 {
                let t = c.peek(j)
                switch t.kind {
                case .lparen, .lbracket, .lbrace, .interpOpen, .jsxExprOpen: depth += 1
                case .rparen, .rbracket, .rbrace, .interpClose, .jsxExprClose:
                    depth -= 1
                    if depth == 0 { return t.kind == .rparen ? j : nil }
                    if depth < 0 { return nil }
                case .eof: return nil
                case .semicolon where depth <= 1: return nil
                default: break
                }
                j += 1
            }
            return nil
        }

        /// `x =>`, `(…) =>`, `(…): T =>`, `async …`, `<T>(…) =>`.
        mutating func tryArrow(noIn: Bool) -> Bool {
            let t = c.cur
            var k = 0
            var isAsync = false
            if t.isKW(.async), !c.peek(1).isLineStart {
                let n = c.peek(1)
                if isIdent(n), c.peek(2).kind == .arrow { isAsync = true; k = 1 }
                else if n.kind == .lparen || n.isOp(.lt) { isAsync = true; k = 1 }
            }
            let first = c.peek(k)
            if isIdent(first), c.peek(k + 1).kind == .arrow, !c.peek(k + 1).isLineStart {
                return arrow(simple: true, async: isAsync, noIn: noIn, speculative: false)
            }
            if first.kind == .lparen {
                guard let close = matchingParen(k) else { return false }
                let after = c.peek(close + 1)
                if after.kind == .arrow, !after.isLineStart {
                    return arrow(simple: false, async: isAsync, noIn: noIn, speculative: false)
                }
                if ts, after.kind == .colon {
                    return arrow(simple: false, async: isAsync, noIn: noIn, speculative: true)
                }
                return false
            }
            if ts, first.isOp(.lt) {
                return arrow(simple: false, async: isAsync, noIn: noIn, speculative: true)
            }
            return false
        }

        /// Parses an arrow function. Speculative: the head (type parameters,
        /// parameters, return type, `=>`) must parse without recovery, else
        /// everything is rolled back and false is returned; the body is never
        /// part of the speculation.
        @discardableResult
        mutating func arrow(simple: Bool, async: Bool, noIn: Bool, speculative: Bool) -> Bool {
            let snap = c.snapshot
            let m = c.mark
            let s = c.cur.start
            if async { c.advance() }
            if simple {
                let pm = c.mark
                let ps = c.cur.start
                let qm = c.mark
                c.leaf(.name)
                c.emit(.param, qm, ps, c.lastEnd)
                c.emit(.params, pm, ps, c.lastEnd)
            } else {
                if ts, c.cur.isOp(.lt) { typeParams() }
                if c.kind == .lparen, !(speculative && c.diag != snap.diag) {
                    params()
                    if ts, c.kind == .colon, !(speculative && c.diag != snap.diag) { c.advance(); returnType() }
                } else {
                    c.diag += 1
                }
            }
            let headOK = c.kind == .arrow && !c.cur.isLineStart
            if speculative, !headOK || c.diag != snap.diag {
                c.restore(snap)
                return false
            }
            if headOK { c.advance() } else { c.diag += 1 }
            if c.kind == .lbrace {
                block()
            } else {
                assignment(noIn: noIn)
            }
            c.emit(.arrow, m, s, c.lastEnd, flags: async ? NodeFlags.async : 0)
            return true
        }

        mutating func assignment(noIn: Bool) {
            guard c.enter() else { return }
            defer { c.leave() }
            if c.kind == .ident || c.kind == .lparen || c.cur.isOp(.lt) {
                if c.cur.isKW(.yield), canStartExpression(c.peek(1)) || c.peek(1).isOp(.star), !c.peek(1).isLineStart {
                    let m = c.mark
                    let s = c.cur.start
                    c.advance()
                    if c.cur.isOp(.star) { c.advance() }
                    assignment(noIn: noIn)
                    c.emit(.yield, m, s, c.lastEnd)
                    return
                }
                if tryArrow(noIn: noIn) { return }
            }
            let m = c.mark
            let s = c.cur.start
            conditional(noIn: noIn)
            if c.kind == .op {
                var op = c.cur.op
                var width = 1
                // `>>=` / `>>>=` arrive as `>` `>=` / `>` `>` `>=`.
                if op == .gt, c.peek(1).start == c.cur.end {
                    if c.peek(1).isOp(.ge) { op = .shrAssign; width = 2 }
                    else if c.peek(1).isOp(.gt), c.peek(2).isOp(.ge), c.peek(2).start == c.peek(1).end { op = .ushrAssign; width = 3 }
                }
                if op.isAssignment {
                    if op == .assign, c.nodes.count == m + Int(c.nodes[c.nodes.count - 1].size) + 1 {
                        toPattern(c.nodes.count - 1)
                    }
                    for _ in 0..<width { c.advance() }
                    assignment(noIn: noIn)
                    c.emit(.assignExpr, m, s, c.lastEnd, aux: UInt16(op.rawValue))
                }
            }
        }

        // MARK: Destructuring assignment

        /// Reinterprets the array / object literal at node `i` — the left side
        /// of `=` or of a `for … of / in` — as the pattern a declaration would
        /// have produced, in place (kinds only; the structure is the same).
        mutating func toPattern(_ i: Int) {
            switch c.nodes[i].kind {
            case .array:
                c.nodes[i].kind = .arrayPattern
                forEachChild(i) { p, e in p.toPatternElement(e) }
            case .object:
                c.nodes[i].kind = .objectPattern
                forEachChild(i) { p, e in
                    switch p.c.nodes[e].kind {
                    case .prop:
                        // aux 0 `key: target` → keyed; 1 `a`, 2 `a = d` → shorthand.
                        let keyed = p.c.nodes[e].aux == 0
                        p.c.nodes[e].kind = .patternProp
                        p.c.nodes[e].aux = keyed ? 2 : 1
                        if keyed, p.c.nodes[e].size > 0 { p.toPatternElement(e - 1) }
                    case .spread:
                        p.c.nodes[e].kind = .restElement
                        if p.c.nodes[e].size > 0 { p.toPattern(e - 1) }
                    default:
                        break
                    }
                }
            default:
                break
            }
        }

        /// An element of a destructuring target: `...rest`, `x = default`, a
        /// nested literal, or a plain target (left as is).
        mutating func toPatternElement(_ e: Int) {
            switch c.nodes[e].kind {
            case .spread:
                c.nodes[e].kind = .restElement
                if c.nodes[e].size > 0 { toPattern(e - 1) }
            case .assignExpr where c.nodes[e].aux == UInt16(Op.assign.rawValue):
                c.nodes[e].kind = .assignPattern
                c.nodes[e].aux = 0
                if let first = firstChild(e) { toPattern(first) }
            case .array, .object:
                toPattern(e)
            default:
                break
            }
        }

        /// Calls `body` with each child of node `i` (reverse document order).
        mutating func forEachChild(_ i: Int, _ body: (inout ScriptParser, Int) -> Void) {
            let lo = i - Int(c.nodes[i].size)
            var k = i - 1
            while k >= lo {
                body(&self, k)
                k -= Int(c.nodes[k].size) + 1
            }
        }

        func firstChild(_ i: Int) -> Int? {
            let lo = i - Int(c.nodes[i].size)
            var k = i - 1
            var first: Int?
            while k >= lo {
                first = k
                k -= Int(c.nodes[k].size) + 1
            }
            return first
        }

        mutating func conditional(noIn: Bool) {
            let m = c.mark
            let s = c.cur.start
            binary(1, noIn: noIn)
            if c.kind == .question {
                c.advance()
                assignment(noIn: false)
                if c.kind == .colon { c.advance(); assignment(noIn: noIn) } else { c.missing() }
                c.emit(.ternary, m, s, c.lastEnd)
            }
        }

        /// Infix operator at the cursor: precedence, operator, tokens.
        mutating func infix(noIn: Bool) -> (Int, Op, Int) {
            let t = c.cur
            switch t.kind {
            case .op:
                switch t.op {
                case .qq: return (1, .qq, 1)
                case .pipePipe: return (2, .pipePipe, 1)
                case .ampAmp: return (3, .ampAmp, 1)
                case .pipe: return (4, .pipe, 1)
                case .caret: return (5, .caret, 1)
                case .amp: return (6, .amp, 1)
                case .eq, .ne, .eqStrict, .neStrict: return (7, t.op, 1)
                case .lt, .le, .ge: return (8, t.op, 1)
                case .gt:
                    let n = c.peek(1)
                    if n.start == t.end, n.isOp(.gt) {
                        let n2 = c.peek(2)
                        if n2.start == n.end, n2.isOp(.gt) { return (9, .ushr, 3) }
                        if n2.start == n.end, n2.isOp(.ge) { return (0, .none, 0) } // >>>= assignment
                        return (9, .shr, 2)
                    }
                    if n.start == t.end, n.isOp(.ge) { return (0, .none, 0) } // >>= assignment
                    return (8, .gt, 1)
                case .shl: return (9, .shl, 1)
                case .plus, .minus: return (10, t.op, 1)
                case .star, .slash, .percent: return (11, t.op, 1)
                case .starStar: return (12, .starStar, 1)
                default: return (0, .none, 0)
                }
            case .ident:
                switch t.kw {
                case .instanceof: return (8, .instanceof, 1)
                case .in: return noIn ? (0, .none, 0) : (8, .in, 1)
                case .as where ts && sameLine: return (8, .asOp, 1)
                case .satisfies where ts && sameLine: return (8, .satisfiesOp, 1)
                default: return (0, .none, 0)
                }
            default:
                return (0, .none, 0)
            }
        }

        mutating func binary(_ minPrec: Int, noIn: Bool) {
            let m = c.mark
            let s = c.cur.start
            unary()
            while true {
                let (prec, op, width) = infix(noIn: noIn)
                if prec == 0 || prec < minPrec { break }
                for _ in 0..<width { c.advance() }
                if op == .asOp || op == .satisfiesOp {
                    if op == .asOp, c.cur.isKW(.const) { c.leaf(.keywordLit) } else { type() }
                    c.emit(op == .asOp ? .asExpr : .satisfiesExpr, m, s, c.lastEnd)
                    continue
                }
                binary(op == .starStar ? prec : prec + 1, noIn: noIn)
                c.emit(.binary, m, s, c.lastEnd, aux: UInt16(op.rawValue))
            }
        }

        mutating func unary() {
            guard c.enter() else { return }
            defer { c.leave() }
            let t = c.cur
            let m = c.mark
            switch t.kind {
            case .op:
                switch t.op {
                case .bang, .tilde, .plus, .minus:
                    c.advance()
                    unary()
                    c.emit(.unary, m, t.start, c.lastEnd, aux: UInt16(t.op.rawValue))
                    return
                case .inc, .dec:
                    c.advance()
                    unary()
                    c.emit(.update, m, t.start, c.lastEnd, aux: UInt16(t.op.rawValue))
                    return
                case .lt where ts && !jsx:
                    // `<T>expr` type assertion (generic arrows were tried before).
                    c.advance()
                    type()
                    if c.cur.isOp(.gt) { c.advance() } else { c.diag += 1 }
                    unary()
                    c.emit(.typeAssertion, m, t.start, c.lastEnd)
                    return
                default:
                    break
                }
            case .ident:
                switch t.kw {
                case .typeof, .void, .delete:
                    c.advance()
                    unary()
                    let op: Op = t.kw == .typeof ? .typeofOp : t.kw == .void ? .voidOp : .deleteOp
                    c.emit(.unary, m, t.start, c.lastEnd, aux: UInt16(op.rawValue))
                    return
                case .await where canStartExpression(c.peek(1)) && !c.peek(1).isLineStart:
                    c.advance()
                    unary()
                    c.emit(.await, m, t.start, c.lastEnd)
                    return
                default:
                    break
                }
            default:
                break
            }
            leftHandSide(allowCall: true)
            if c.kind == .op, c.cur.op == .inc || c.cur.op == .dec, sameLine {
                let op = c.cur.op
                c.advance()
                c.emit(.update, m, t.start, c.lastEnd, aux: UInt16(op.rawValue) | 0x100)
            }
        }

        @inline(__always) func isTemplateStart(_ t: Token) -> Bool {
            t.kind == .string && t.flags & Token.continuation == 0 && c.text.character(at: Int(t.start)) == 96
        }

        /// A reserved word that, on a new line after `x.`, starts the next
        /// statement rather than naming a property.
        mutating func endsMemberAccess(_ t: Token) -> Bool {
            guard t.isLineStart, t.kind == .ident else { return false }
            return ScriptParser.isReserved(t.kw) || (ts && (t.kw == .interface || (t.kw == .type && isIdent(c.peek(1)))))
        }

        mutating func leftHandSide(allowCall: Bool) {
            guard c.enter() else { return }
            defer { c.leave() }
            let m = c.mark
            let s = c.cur.start
            if c.cur.isKW(.new) {
                newExpression()
            } else {
                primary()
            }
            while true {
                let t = c.cur
                switch t.kind {
                case .dot, .questionDot:
                    let optional = t.kind == .questionDot
                    if optional, !allowCall, c.peek(1).kind == .lparen { return }
                    let gap = UInt16(clamping: max(0, Int(t.start - c.nodes[c.nodes.count - 1].end)))
                    let dotEnd = t.end
                    c.advance()
                    var flags: UInt8 = optional ? NodeFlags.optional : 0
                    if optional, c.kind == .lparen {
                        callArgs()
                        c.emit(.call, m, s, c.lastEnd, flags: flags)
                        continue
                    }
                    if optional, c.kind == .lbracket {
                        indexAccess()
                        c.emit(.subscript, m, s, c.lastEnd, flags: flags)
                        continue
                    }
                    if isIdentName(c.cur) || c.kind == .privateName, !endsMemberAccess(c.cur) {
                        c.leaf(c.kind == .privateName ? .privateName : .name)
                        c.emit(.member, m, s, c.lastEnd, flags: flags, aux: gap)
                    } else {
                        c.diag += 1
                        flags |= NodeFlags.missingName
                        c.emit(.member, m, s, dotEnd, flags: flags, aux: gap)
                    }
                case .lbracket:
                    indexAccess()
                    c.emit(.subscript, m, s, c.lastEnd)
                case .lparen:
                    if !allowCall { return }
                    let closed = callArgs()
                    c.emit(.call, m, s, closed ? c.lastEnd : closeEnd, flags: closed ? 0 : NodeFlags.missingClose)
                case .string where isTemplateStart(t):
                    template()
                    c.emit(.taggedTemplate, m, s, c.lastEnd)
                case .op:
                    if ts, t.op == .bang, sameLine {
                        // Non-null assertion `x!` (as in TypeScript: any `!` on the same line).
                        c.advance()
                        c.emit(.nonNull, m, s, c.lastEnd)
                    } else if ts, t.op == .lt {
                        // Generic call `f<T>(…)` / tagged template `` f<T>`…` ``.
                        let snap = c.snapshot
                        typeArgs()
                        if c.diag == snap.diag, c.kind == .lparen || isTemplateStart(c.cur) {
                            if c.kind == .lparen {
                                if !allowCall { c.restore(snap); return }
                                let closed = callArgs()
                                c.emit(.call, m, s, closed ? c.lastEnd : closeEnd, flags: closed ? 0 : NodeFlags.missingClose)
                            } else {
                                template()
                                c.emit(.taggedTemplate, m, s, c.lastEnd)
                            }
                        } else {
                            c.restore(snap)
                            return
                        }
                    } else {
                        return
                    }
                default:
                    return
                }
            }
        }

        mutating func newExpression() {
            let m = c.mark
            let s = c.cur.start
            c.advance() // new
            if c.kind == .dot {
                c.advance()
                if isIdentName(c.cur) { c.leaf(.name) } else { c.missing() }
                c.emit(.metaProperty, m, s, c.lastEnd)
                return
            }
            leftHandSide(allowCall: false)
            if ts, c.cur.isOp(.lt) {
                let snap = c.snapshot
                typeArgs()
                if c.diag != snap.diag { c.restore(snap) }
            }
            if c.kind == .lparen {
                let closed = callArgs()
                c.emit(.new, m, s, closed ? c.lastEnd : closeEnd, flags: closed ? 0 : NodeFlags.missingClose)
            } else {
                c.emit(.new, m, s, c.lastEnd)
            }
        }

        /// `( args )`; false when the closer was missing.
        @discardableResult
        mutating func callArgs() -> Bool {
            let m = c.mark
            let s = c.cur.start
            c.advance()
            listElements(closer: .rparen) { p in
                if p.c.kind == .ellipsis {
                    let sm = p.c.mark
                    let ss = p.c.cur.start
                    p.c.advance()
                    p.assignment(noIn: false)
                    p.c.emit(.spread, sm, ss, p.c.lastEnd)
                } else {
                    p.assignment(noIn: false)
                }
            }
            let closed = c.kind == .rparen
            if closed { c.advance() } else { c.diag += 1 }
            c.emit(.args, m, s, closed ? c.lastEnd : closeEnd, flags: closed ? 0 : NodeFlags.missingClose)
            return closed
        }

        /// Comma-separated elements up to `closer`, with recovery (not consumed).
        mutating func listElements(closer: TK, _ element: (inout ScriptParser) -> Void) {
            while c.kind != closer, c.kind != .eof {
                if c.cur.isLineStart, isStatementBoundary() { break }
                switch c.kind {
                case .rparen, .rbracket, .rbrace, .semicolon, .interpClose, .jsxExprClose: return
                case .comma:
                    c.advance()
                    continue
                default:
                    break
                }
                if !canStartExpression(c.cur) && c.kind != .ellipsis {
                    c.skipOne()
                    continue
                }
                let before = c.i
                element(&self)
                if c.i == before { c.skipOne(); continue }
                if c.kind == .comma { c.advance() }
                else if c.kind != closer, canStartExpression(c.cur), !(c.cur.isLineStart && isStatementBoundary()) {
                    c.diag += 1 // missing comma
                }
            }
        }

        mutating func indexAccess() {
            c.advance() // [
            if c.kind == .rbracket { c.missing() } else { expression(noIn: false) }
            if c.kind == .rbracket { c.advance() } else { c.diag += 1 }
        }

        mutating func primary() {
            let t = c.cur
            let m = c.mark
            switch t.kind {
            case .ident:
                switch t.kw {
                case .this, .super, .null, .true, .false, .undefined: c.leaf(.keywordLit, aux: UInt16(t.sub))
                case .function:
                    var flags: UInt8 = 0
                    c.advance()
                    if c.cur.isOp(.star) { c.advance(); flags |= NodeFlags.generator }
                    if isIdent(c.cur) { c.leaf(.name) }
                    signatureAndBody(start: t.start, bodyRequired: true)
                    c.emit(.funcExpr, m, t.start, c.lastEnd, flags: flags)
                case .async where c.peek(1).isKW(.function) && !c.peek(1).isLineStart:
                    c.advance()
                    c.advance()
                    var flags: UInt8 = NodeFlags.async
                    if c.cur.isOp(.star) { c.advance(); flags |= NodeFlags.generator }
                    if isIdent(c.cur) { c.leaf(.name) }
                    signatureAndBody(start: t.start, bodyRequired: true)
                    c.emit(.funcExpr, m, t.start, c.lastEnd, flags: flags)
                case .class:
                    classLike(m, t.start, expression: true)
                case .import:
                    c.advance()
                    if c.kind == .dot {
                        c.advance()
                        if isIdentName(c.cur) { c.leaf(.name) } else { c.missing() }
                        c.emit(.metaProperty, m, t.start, c.lastEnd)
                    } else if c.kind == .lparen {
                        callArgs()
                        c.emit(.importCall, m, t.start, c.lastEnd)
                    } else {
                        c.missing()
                    }
                case .await, .yield, .let:
                    c.leaf(.name)
                default:
                    if isIdent(t) { c.leaf(.name) } else { c.missing() }
                }
            case .number: c.leaf(.number)
            case .regex: c.leaf(.regex)
            case .string: template()
            case .privateName: c.leaf(.privateName)
            case .lparen:
                c.advance()
                expression(noIn: false)
                if c.kind == .rparen {
                    c.advance()
                    c.emit(.paren, m, t.start, c.lastEnd)
                } else {
                    c.diag += 1
                    c.emit(.paren, m, t.start, closeEnd, flags: NodeFlags.missingClose)
                }
            case .lbracket: arrayLiteral()
            case .lbrace: objectLiteral()
            case .jsxLt: jsxElement()
            case .at:
                // A decorated class expression.
                decorators()
                if c.cur.isKW(.class) { classLike(m, t.start, expression: true) } else { c.missing() }
            default:
                c.missing()
            }
        }

        /// A string / template literal (with `${…}` parts).
        mutating func template() {
            let m = c.mark
            let s = c.cur.start
            c.advance()
            var interpolated = false
            while c.kind == .interpOpen {
                interpolated = true
                c.advance()
                if c.kind != .interpClose { expression(noIn: false) }
                if c.kind != .interpClose {
                    var depth = 0
                    while c.kind != .eof, !(c.kind == .interpClose && depth == 0) {
                        if c.kind == .interpOpen { depth += 1 }
                        if c.kind == .interpClose { depth -= 1 }
                        c.skipOne()
                    }
                }
                if c.kind == .interpClose { c.advance() } else { c.diag += 1 }
                if c.kind == .string, c.cur.flags & Token.continuation != 0 { c.advance() }
            }
            c.emit(interpolated ? .template : .string, m, s, c.lastEnd)
        }

        mutating func arrayLiteral() {
            let m = c.mark
            let s = c.cur.start
            c.advance()
            while c.kind != .rbracket, c.kind != .eof {
                if c.cur.isLineStart, isStatementBoundary() { break }
                if c.kind == .rparen || c.kind == .rbrace || c.kind == .semicolon || c.kind == .interpClose
                    || c.kind == .jsxExprClose { break }
                if c.kind == .comma {
                    c.emit(.elision, c.mark, c.cur.start, c.cur.start)
                    c.advance()
                    continue
                }
                let em = c.mark
                let es = c.cur.start
                if c.kind == .ellipsis {
                    c.advance()
                    assignment(noIn: false)
                    c.emit(.spread, em, es, c.lastEnd)
                } else if canStartExpression(c.cur) {
                    let before = c.i
                    assignment(noIn: false)
                    if c.i == before { c.skipOne(); continue }
                } else {
                    c.skipOne()
                    continue
                }
                if c.kind == .comma { c.advance() } else if c.kind != .rbracket, canStartExpression(c.cur),
                                                             !(c.cur.isLineStart && isStatementBoundary()) {
                    c.diag += 1
                }
            }
            let closed = c.kind == .rbracket
            if closed { c.advance() } else { c.diag += 1 }
            c.emit(.array, m, s, closed ? c.lastEnd : closeEnd, flags: closed ? 0 : NodeFlags.missingClose)
        }

        /// A keyword at a line start that is not followed by what makes it a
        /// property name (`return: 1`, `if() {}`) ends an unclosed object.
        mutating func objectBoundary() -> Bool {
            guard c.cur.isLineStart, isStatementBoundary() else { return false }
            let n = c.peek(1)
            switch n.kind {
            case .colon, .lparen, .comma, .rbrace, .question: return false
            default: return true
            }
        }

        mutating func objectLiteral() {
            let m = c.mark
            let s = c.cur.start
            c.advance()
            while c.kind != .rbrace, c.kind != .eof {
                if objectBoundary() { break }
                if c.kind == .rparen || c.kind == .rbracket || c.kind == .semicolon || c.kind == .interpClose
                    || c.kind == .jsxExprClose { break }
                if c.kind == .comma { c.advance(); continue }
                let pm = c.mark
                let ps = c.cur.start
                if c.kind == .ellipsis {
                    c.advance()
                    assignment(noIn: false)
                    c.emit(.spread, pm, ps, c.lastEnd)
                } else if c.kind == .ident || c.kind == .string || c.kind == .number || c.kind == .lbracket
                            || c.kind == .privateName || c.cur.isOp(.star) {
                    var flags: UInt8 = 0
                    var aux: UInt16 = 0
                    // Modifiers: async / get / set / `*` before a key.
                    while true {
                        let k = c.cur
                        let n = c.peek(1)
                        let keyNext = n.kind == .ident || n.kind == .string || n.kind == .number || n.kind == .lbracket
                            || n.kind == .privateName || n.isOp(.star)
                        if k.isKW(.async) || k.isKW(.get) || k.isKW(.set), keyNext, !n.isLineStart {
                            if k.isKW(.async) { flags |= NodeFlags.async } else { aux = k.isKW(.get) ? 1 : 2 }
                            c.advance()
                        } else if k.isOp(.star) {
                            flags |= NodeFlags.generator
                            c.advance()
                        } else { break }
                    }
                    let shorthandCandidate = c.kind == .ident
                    propertyKey()
                    if c.kind == .lparen || (ts && c.cur.isOp(.lt)) {
                        signatureAndBody(start: ps, bodyRequired: true)
                        c.emit(.method, pm, ps, c.lastEnd, flags: flags, aux: aux)
                    } else if c.kind == .colon {
                        c.advance()
                        assignment(noIn: false)
                        c.emit(.prop, pm, ps, c.lastEnd)
                    } else if shorthandCandidate, c.cur.isOp(.assign) {
                        c.advance()
                        assignment(noIn: false)
                        c.emit(.prop, pm, ps, c.lastEnd, aux: 2)
                    } else {
                        c.emit(.prop, pm, ps, c.lastEnd, aux: 1)
                    }
                } else {
                    c.skipOne()
                    continue
                }
                if c.kind == .comma { c.advance() }
                else if c.kind != .rbrace, !c.cur.isLineStart, !objectBoundary() {
                    if c.kind == .rparen || c.kind == .rbracket || c.kind == .semicolon { break }
                    c.skipOne()
                }
            }
            let closed = c.kind == .rbrace
            if closed { c.advance() } else { c.diag += 1 }
            c.emit(.object, m, s, closed ? c.lastEnd : closeEnd, flags: closed ? 0 : NodeFlags.missingClose)
        }

        // MARK: JSX

        mutating func jsxElement() {
            guard c.enter() else { return }
            defer { c.leave() }
            let m = c.mark
            let s = c.cur.start
            c.advance() // <
            var flags: UInt8 = 0
            if c.kind == .jsxGt {
                c.advance()
                jsxChildren(&flags)
                c.emit(.jsxElement, m, s, flags & NodeFlags.missingClose != 0 ? closeEnd : c.lastEnd, flags: flags, aux: 1)
                return
            }
            if c.kind == .jsxName { c.leaf(.jsxName) } else { c.missing() }
            while true {
                switch c.kind {
                case .jsxAttr:
                    let am = c.mark
                    let aS = c.cur.start
                    c.leaf(.name)
                    if c.kind == .string { template() }
                    else if c.kind == .jsxExprOpen { jsxContainer() }
                    else if c.kind == .jsxLt { jsxElement() }
                    c.emit(.jsxAttr, am, aS, c.lastEnd)
                    continue
                case .jsxExprOpen:
                    let am = c.mark
                    let aS = c.cur.start
                    jsxContainer()
                    c.emit(.jsxSpreadAttr, am, aS, c.lastEnd)
                    continue
                case .jsxName, .string:
                    c.skipOne()
                    continue
                case .jsxSlashGt:
                    c.advance()
                    c.emit(.jsxElement, m, s, c.lastEnd, aux: 2)
                    return
                case .jsxGt:
                    c.advance()
                    jsxChildren(&flags)
                    c.emit(.jsxElement, m, s, flags & NodeFlags.missingClose != 0 ? closeEnd : c.lastEnd, flags: flags)
                    return
                default:
                    c.diag += 1
                    c.emit(.jsxElement, m, s, closeEnd, flags: NodeFlags.missingClose)
                    return
                }
            }
        }

        mutating func jsxChildren(_ flags: inout UInt8) {
            while true {
                switch c.kind {
                case .jsxText: c.leaf(.jsxText)
                case .jsxExprOpen: jsxContainer()
                case .jsxLt: jsxElement()
                case .jsxLtSlash:
                    c.advance()
                    if c.kind == .jsxName { c.advance() }
                    if c.kind == .jsxGt { c.advance() } else { c.diag += 1 }
                    return
                default:
                    c.diag += 1
                    flags |= NodeFlags.missingClose
                    return
                }
            }
        }

        mutating func jsxContainer() {
            let m = c.mark
            let s = c.cur.start
            c.advance() // {
            if c.kind == .ellipsis {
                let sm = c.mark
                let ss = c.cur.start
                c.advance()
                assignment(noIn: false)
                c.emit(.spread, sm, ss, c.lastEnd)
            } else if c.kind != .jsxExprClose {
                expression(noIn: false)
            }
            if c.kind != .jsxExprClose {
                // Junk up to the container's closer.
                var depth = 0
                while c.kind != .eof, !(c.kind == .jsxExprClose && depth == 0) {
                    if c.kind == .jsxExprOpen { depth += 1 }
                    if c.kind == .jsxExprClose { depth -= 1 }
                    c.skipOne()
                }
            }
            if c.kind == .jsxExprClose {
                c.advance()
                c.emit(.jsxExprContainer, m, s, c.lastEnd)
            } else {
                c.diag += 1
                c.emit(.jsxExprContainer, m, s, closeEnd, flags: NodeFlags.missingClose)
            }
        }

        // MARK: Types

        mutating func returnType() {
            let t = c.cur
            let m = c.mark
            if t.isKW(.asserts), isIdent(c.peek(1)) || c.peek(1).isKW(.this), !c.peek(1).isLineStart {
                c.advance()
                if c.cur.isKW(.this) { c.leaf(.keywordLit) } else { c.leaf(.name) }
                if c.cur.isKW(.is) { c.advance(); type() }
                c.emit(.typePredicate, m, t.start, c.lastEnd, aux: 1)
                return
            }
            if isIdent(t) || t.isKW(.this), c.peek(1).isKW(.is), !c.peek(1).isLineStart {
                if t.isKW(.this) { c.leaf(.keywordLit) } else { c.leaf(.name) }
                c.advance()
                type()
                c.emit(.typePredicate, m, t.start, c.lastEnd)
                return
            }
            type()
        }

        /// Whether `(` at the cursor starts a function type `(…) => T`.
        mutating func isFunctionTypeStart() -> Bool {
            let n = c.peek(1)
            if n.kind == .rparen || n.kind == .ellipsis { return true }
            guard let close = matchingParen(0) else {
                // Unclosed: a function type when it looks like a parameter.
                return (isIdent(n) || n.isKW(.this)) && (c.peek(2).kind == .colon || c.peek(2).kind == .question)
            }
            return c.peek(close + 1).kind == .arrow
        }

        mutating func type() {
            guard c.enter() else { return }
            defer { c.leave() }
            let t = c.cur
            let m = c.mark
            if t.isOp(.lt) || (t.kind == .lparen && isFunctionTypeStart()) {
                if t.isOp(.lt) { typeParams() }
                let saved = noConditional
                noConditional = false
                if c.kind == .lparen { params() } else { c.missing() }
                noConditional = saved
                if c.kind == .arrow { c.advance() } else { c.diag += 1 }
                returnType()
                c.emit(.funcType, m, t.start, c.lastEnd)
                return
            }
            if t.isKW(.new) || (t.isKW(.abstract) && c.peek(1).isKW(.new)) {
                if t.isKW(.abstract) { c.advance() }
                c.advance()
                if c.cur.isOp(.lt) { typeParams() }
                if c.kind == .lparen { params() } else { c.missing() }
                if c.kind == .arrow { c.advance() } else { c.diag += 1 }
                returnType()
                c.emit(.ctorType, m, t.start, c.lastEnd)
                return
            }
            unionType()
            if c.cur.isKW(.extends), sameLine, !noConditional {
                c.advance()
                // The check type: any type but a conditional one (function
                // types included), as in TypeScript.
                noConditional = true
                type()
                noConditional = false
                if c.kind == .question {
                    c.advance()
                    type()
                    if c.kind == .colon { c.advance(); type() } else { c.missing() }
                } else {
                    c.missing()
                }
                c.emit(.conditionalType, m, t.start, c.lastEnd)
            }
        }

        mutating func unionType() {
            let m = c.mark
            let s = c.cur.start
            if c.cur.isOp(.pipe) { c.advance() }
            intersectionType()
            if c.cur.isOp(.pipe) {
                while c.cur.isOp(.pipe) {
                    c.advance()
                    intersectionType()
                }
                c.emit(.unionType, m, s, c.lastEnd)
            }
        }

        mutating func intersectionType() {
            let m = c.mark
            let s = c.cur.start
            if c.cur.isOp(.amp) { c.advance() }
            typeOperator()
            if c.cur.isOp(.amp) {
                while c.cur.isOp(.amp) {
                    c.advance()
                    typeOperator()
                }
                c.emit(.intersectionType, m, s, c.lastEnd)
            }
        }

        mutating func typeOperator() {
            guard c.enter() else { return }
            defer { c.leave() }
            let t = c.cur
            let m = c.mark
            if t.isKW(.keyof) || t.isKW(.unique) || t.isKW(.readonly), c.peek(1).kind != .comma,
               c.peek(1).kind != .rparen, !c.peek(1).isOp(.gt), c.peek(1).kind != .semicolon {
                c.advance()
                typeOperator()
                c.emit(.typeOperator, m, t.start, c.lastEnd, aux: UInt16(t.sub))
                return
            }
            if t.isKW(.infer), isIdent(c.peek(1)) {
                c.advance()
                c.leaf(.name)
                if c.cur.isKW(.extends) {
                    // A constraint `infer U extends X` — unless, outside a
                    // conditional's check type, a `?` follows (then the
                    // `extends` starts a conditional type).
                    let snap = c.snapshot
                    let saved = noConditional
                    c.advance()
                    noConditional = true
                    type()
                    noConditional = saved
                    if !saved, c.kind == .question { c.restore(snap) }
                }
                c.emit(.inferType, m, t.start, c.lastEnd)
                return
            }
            postfixType()
        }

        mutating func postfixType() {
            let m = c.mark
            let s = c.cur.start
            primaryType()
            while c.kind == .lbracket, sameLine {
                c.advance()
                if c.kind == .rbracket {
                    c.advance()
                    c.emit(.arrayType, m, s, c.lastEnd)
                } else {
                    let saved = noConditional
                    noConditional = false
                    type()
                    noConditional = saved
                    if c.kind == .rbracket { c.advance() } else { c.diag += 1 }
                    c.emit(.indexedAccess, m, s, c.lastEnd)
                }
            }
        }

        mutating func primaryType() {
            let t = c.cur
            let m = c.mark
            // Bracketed types allow conditional types again (in a check type too).
            let saved = noConditional
            if t.kind == .lbrace || t.kind == .lbracket || t.kind == .lparen || t.kind == .string { noConditional = false }
            defer { noConditional = saved }
            switch t.kind {
            case .ident:
                switch t.kw {
                case .typeof:
                    c.advance()
                    if c.cur.isKW(.import) { importType(); c.emit(.typeQuery, m, t.start, c.lastEnd); return }
                    entityName()
                    if c.cur.isOp(.lt), sameLine { typeArgs() }
                    c.emit(.typeQuery, m, t.start, c.lastEnd)
                case .import:
                    importType()
                case .null, .true, .false, .undefined, .void, .this:
                    c.leaf(.keywordLit, aux: UInt16(t.sub))
                    c.emit(.literalType, m, t.start, c.lastEnd)
                default:
                    if ScriptParser.isReserved(t.kw) {
                        c.missing()
                        return
                    }
                    entityName()
                    if c.cur.isOp(.lt), sameLine { typeArgs() }
                    c.emit(.typeRef, m, t.start, c.lastEnd)
                }
            case .string:
                if isTemplateStart(t) {
                    c.advance()
                    while c.kind == .interpOpen {
                        c.advance()
                        type()
                        while c.kind != .eof, c.kind != .interpClose { c.skipOne() }
                        if c.kind == .interpClose { c.advance() }
                        if c.kind == .string, c.cur.flags & Token.continuation != 0 { c.advance() }
                    }
                    c.emit(.templateType, m, t.start, c.lastEnd)
                } else {
                    c.leaf(.string)
                    c.emit(.literalType, m, t.start, c.lastEnd)
                }
            case .number:
                c.leaf(.number)
                c.emit(.literalType, m, t.start, c.lastEnd)
            case .op where t.op == .minus && c.peek(1).kind == .number:
                c.advance()
                c.leaf(.number)
                c.emit(.literalType, m, t.start, c.lastEnd)
            case .lbrace:
                objectType()
            case .lbracket:
                tupleType()
            case .lparen:
                c.advance()
                type()
                if c.kind == .rparen { c.advance() } else { c.diag += 1 }
                c.emit(.parenType, m, t.start, c.lastEnd)
            default:
                c.missing()
            }
        }

        mutating func entityName() {
            let m = c.mark
            let s = c.cur.start
            c.leaf(.name)
            if c.kind == .dot {
                while c.kind == .dot {
                    c.advance()
                    if isIdentName(c.cur) { c.leaf(.name) } else { c.missing(); break }
                }
                c.emit(.qualifiedName, m, s, c.lastEnd)
            }
        }

        mutating func importType() {
            let m = c.mark
            let s = c.cur.start
            c.advance() // import
            if c.kind == .lparen {
                c.advance()
                if c.kind == .string { c.leaf(.string) } else { c.missing() }
                if c.kind == .rparen { c.advance() } else { c.diag += 1 }
            }
            while c.kind == .dot {
                c.advance()
                if isIdentName(c.cur) { c.leaf(.name) } else { c.missing(); break }
            }
            if c.cur.isOp(.lt), sameLine { typeArgs() }
            c.emit(.importType, m, s, c.lastEnd)
        }

        mutating func tupleType() {
            let m = c.mark
            let s = c.cur.start
            c.advance()
            while c.kind != .rbracket, c.kind != .eof {
                if c.cur.isLineStart, isStatementBoundary() { break }
                if c.kind == .rparen || c.kind == .rbrace || c.kind == .semicolon || c.cur.isOp(.assign) { break }
                let em = c.mark
                let es = c.cur.start
                if c.kind == .ellipsis {
                    c.advance()
                    if isIdent(c.cur), c.peek(1).kind == .colon { c.leaf(.name); c.advance() }
                    type()
                    c.emit(.restType, em, es, c.lastEnd)
                } else if isIdent(c.cur), c.peek(1).kind == .colon || (c.peek(1).kind == .question && c.peek(2).kind == .colon) {
                    c.leaf(.name)
                    if c.kind == .question { c.advance() }
                    c.advance()
                    type()
                    c.emit(.namedTupleMember, em, es, c.lastEnd)
                } else {
                    type()
                    if c.kind == .question { c.advance(); c.emit(.optionalType, em, es, c.lastEnd) }
                }
                if c.kind == .comma { c.advance() } else if c.kind != .rbracket { break }
            }
            let closed = c.kind == .rbracket
            if closed { c.advance() } else { c.diag += 1 }
            c.emit(.tupleType, m, s, closed ? c.lastEnd : closeEnd, flags: closed ? 0 : NodeFlags.missingClose)
        }

        /// `{ members }` (interface body / type literal / mapped type).
        mutating func objectType() {
            let m = c.mark
            let s = c.cur.start
            c.advance()
            // Mapped type `{ [K in T]: X }` (with readonly / +/- modifiers).
            var k = 0
            if c.cur.isKW(.readonly) { k = 1 }
            else if c.cur.isOp(.plus) || c.cur.isOp(.minus) { k = c.peek(1).isKW(.readonly) ? 2 : 1 }
            if c.peek(k).kind == .lbracket, isIdent(c.peek(k + 1)), c.peek(k + 2).isKW(.in) {
                for _ in 0..<k { c.advance() }
                c.advance() // [
                let pm = c.mark
                let ps = c.cur.start
                c.leaf(.name)
                c.advance() // in
                type()
                c.emit(.typeParam, pm, ps, c.lastEnd)
                if c.cur.isKW(.as) { c.advance(); type() }
                if c.kind == .rbracket { c.advance() } else { c.diag += 1 }
                if c.cur.isOp(.plus) || c.cur.isOp(.minus) { c.advance() }
                if c.kind == .question { c.advance() }
                if c.kind == .colon { c.advance(); type() }
                if c.kind == .semicolon || c.kind == .comma { c.advance() }
                let closed = c.kind == .rbrace
                if closed { c.advance() } else { c.diag += 1 }
                c.emit(.mappedType, m, s, closed ? c.lastEnd : closeEnd, flags: closed ? 0 : NodeFlags.missingClose)
                return
            }
            while c.kind != .rbrace, c.kind != .eof {
                if c.cur.isLineStart, isStatementBoundary(),
                   !(c.peek(1).kind == .colon || c.peek(1).kind == .question || c.peek(1).kind == .lparen
                     || c.peek(1).isOp(.lt)) { break }
                if c.kind == .rparen || c.kind == .rbracket { break }
                let before = c.i
                typeMember()
                if c.kind == .semicolon || c.kind == .comma { c.advance() }
                if c.i == before { c.skipOne() }
            }
            let closed = c.kind == .rbrace
            if closed { c.advance() } else { c.diag += 1 }
            c.emit(.objectType, m, s, closed ? c.lastEnd : closeEnd, flags: closed ? 0 : NodeFlags.missingClose)
        }

        mutating func typeMember() {
            let m = c.mark
            let s = c.cur.start
            if c.kind == .lparen || c.cur.isOp(.lt) {
                if c.cur.isOp(.lt) { typeParams() }
                if c.kind == .lparen { params() }
                if c.kind == .colon { c.advance(); returnType() }
                c.emit(.callSig, m, s, c.lastEnd)
                return
            }
            if c.cur.isKW(.new), c.peek(1).kind == .lparen || c.peek(1).isOp(.lt) {
                c.advance()
                if c.cur.isOp(.lt) { typeParams() }
                if c.kind == .lparen { params() }
                if c.kind == .colon { c.advance(); returnType() }
                c.emit(.ctorSig, m, s, c.lastEnd)
                return
            }
            var flags: UInt8 = 0
            while c.cur.isKW(.readonly) || c.cur.isKW(.get) || c.cur.isKW(.set),
                  c.peek(1).kind == .ident || c.peek(1).kind == .string || c.peek(1).kind == .lbracket,
                  !c.peek(1).isLineStart {
                c.advance()
            }
            if c.kind == .lbracket, isIdent(c.peek(1)), c.peek(2).kind == .colon {
                indexSignature(m, s)
                return
            }
            guard c.kind == .ident || c.kind == .string || c.kind == .number || c.kind == .lbracket else {
                c.skipOne()
                return
            }
            propertyKey()
            if c.kind == .question { flags |= NodeFlags.optional; c.advance() }
            if c.kind == .lparen || c.cur.isOp(.lt) {
                if c.cur.isOp(.lt) { typeParams() }
                if c.kind == .lparen { params() } else { c.missing() }
                if c.kind == .colon { c.advance(); returnType() }
                c.emit(.methodSig, m, s, c.lastEnd, flags: flags)
                return
            }
            if c.kind == .colon { c.advance(); type() }
            c.emit(.propSig, m, s, c.lastEnd, flags: flags)
        }

        /// Consumes a `>` closing type arguments / parameters (a `>=` token
        /// gives up its first unit: `Array<T>= x`).
        mutating func closeAngle() -> Bool {
            if c.cur.isOp(.gt) { c.advance(); return true }
            if c.cur.isOp(.ge) {
                c.toks[c.i].start += 1
                c.toks[c.i].sub = Op.assign.rawValue
                c.lastEnd = c.toks[c.i].start
                return true
            }
            return false
        }

        mutating func typeArgs() {
            let saved = noConditional
            noConditional = false
            defer { noConditional = saved }
            let m = c.mark
            let s = c.cur.start
            c.advance() // <
            while !c.cur.isOp(.gt), c.kind != .eof {
                if c.cur.isLineStart, isStatementBoundary() { break }
                if c.kind == .rparen || c.kind == .rbrace || c.kind == .rbracket || c.kind == .semicolon
                    || c.cur.isOp(.assign) || c.cur.isOp(.ge) { break }
                type()
                if c.kind == .comma { c.advance() } else { break }
            }
            let closed = closeAngle()
            if !closed { c.diag += 1 }
            c.emit(.typeArgs, m, s, closed ? c.lastEnd : closeEnd, flags: closed ? 0 : NodeFlags.missingClose)
        }

        mutating func typeParams() {
            let m = c.mark
            let s = c.cur.start
            c.advance() // <
            while !c.cur.isOp(.gt), c.kind != .eof {
                if c.cur.isLineStart, isStatementBoundary() { break }
                let pm = c.mark
                let ps = c.cur.start
                while c.cur.isKW(.in) || c.cur.isKW(.const) || (c.kind == .ident && c.tokenIs(c.cur, "out")),
                      isIdent(c.peek(1)) {
                    c.advance()
                }
                if isIdent(c.cur) { c.leaf(.name) } else { break }
                if c.cur.isKW(.extends) {
                    c.advance()
                    let saved = noConditional
                    noConditional = false
                    type()
                    noConditional = saved
                }
                if c.cur.isOp(.assign) { c.advance(); type() }
                c.emit(.typeParam, pm, ps, c.lastEnd)
                if c.kind == .comma { c.advance() } else { break }
            }
            let closed = closeAngle()
            if !closed { c.diag += 1 }
            c.emit(.typeParams, m, s, closed ? c.lastEnd : closeEnd, flags: closed ? 0 : NodeFlags.missingClose)
        }
    }
}
