import Foundation

// M17 T17.11c — JavaScript / TypeScript type evaluation over the script
// parser's tree (plan §8.1, the JS / TS column), modelled on
// `PythonEvaluator`: demand-driven, lazy (`Thunk`s), bounded by the
// request's `InferenceBudget`.
//
// - **Scope of work (plan §8.3).** A request evaluates the receiver of one
//   member access: the flow of the caret's function up to that point and
//   what the receiver depends on (module-level declarations, called
//   functions' return types with a bounded call depth, classes' and
//   interfaces' members). Nothing else is analysed.
// - **Flow.** Statements are walked up to the receiver: `const` / `let` /
//   `var` (annotations, JSDoc `@type`, initialisers, destructuring),
//   assignments, `for…of` / `for…in`, `catch`, hoisted function / class /
//   interface / type / enum declarations; `if` / `switch` / loops / `try`
//   branches join, branches that cannot fall through (`return`, `throw`,
//   `break`, `continue`) are dropped (early return narrows what follows).
//   Conditions narrow names and member chains (`this.x`): `typeof`,
//   `instanceof`, `in`, `=== null` / `undefined`, discriminant properties
//   (`s.kind === 'circle'`), `Array.isArray`, truthiness, `&&` / `||` / `!`.
//   Optional chaining and `x!` drop `null` / `undefined`. `push` / `unshift`
//   / `add` / `set` give an empty array / set / map its element type.
// - **Types.** Annotations, interfaces (merged), type aliases (generic),
//   classes (fields, parameter properties, `this.x =` in methods, methods,
//   accessors, static members, `extends`), enums, literals and object
//   literals (`ObjectShape`), arrays, calls (document functions — declared
//   or the union of their `return`s, `async` wrapping in `Promise` — and lib
//   methods with overload choice and type-parameter solving, contextual
//   parameter types for callbacks), `await`, `new`, generics. JavaScript
//   reads JSDoc `@type` / `@param` / `@returns` / `@typedef` / `@template`.
// - **Precision first (plan §13).** `any` / `unknown`, unresolved names,
//   imports (project modules until T17.13; modules without lib entries) are
//   unknown: no inferred members, the usage-evidence path.

/// A call argument (JS / TS).
struct SArg {
    let node: PyNode?
    /// The frame the argument is evaluated in (callbacks are defined there).
    let frame: SFrame?
    let value: Thunk
    let spread: Bool
}

/// Collects `return` values during a whole-body walk.
final class SReturnSink {
    var values: [(node: PyNode?, frame: SFrame)] = []
}

@MainActor
final class ScriptEvaluator {
    let text: NSString
    let module: PyModuleView
    let tables: ScriptTypeTables
    let returnCache: ByteLRU<String, CachedReturn>
    let dialect: SyntaxDialect
    var budget: InferenceBudget

    static let maxCallDepth = 2
    static let maxUnionSites = 4
    static let literalLimit = 64

    var callDepth = 0
    var inProgress = Set<String>()
    var returnMemo: [String: InferredType] = [:]
    private var moduleMemo: [String: InferredType] = [:]
    private var typeMemo: [String: STypeDecl?] = [:]
    var classes: [String: SDocClass] = [:]
    var functions: [String: SDocFunction] = [:]
    private var nodeFunctions: [PyNode: SDocFunction] = [:]
    private var nodeClasses: [PyNode: SDocClass] = [:]
    var linearizations: [ClassRef: [(ClassRef, [InferredType])]] = [:]
    var linearizing = Set<ClassRef>()
    private var nameHashes: [String: UInt64] = [:]
    private var depStack: [[String: UInt64]] = []
    private var typedefs: [String: JSDocComment]?
    var aliasDepth = 0
    /// Fields whose type is being inferred (`this.n = this.n + 1` reads itself).
    var fieldsInProgress = Set<String>()

    var isAborted: Bool { budget.exhausted }
    var isJavaScript: Bool { dialect == .javascript }

    private(set) var returnCacheHits = 0
    private(set) var returnInferences = 0

    init(text: NSString, module: PyModuleView, tables: ScriptTypeTables, returnCache: ByteLRU<String, CachedReturn>,
         dialect: SyntaxDialect, budget: InferenceBudget) {
        self.text = text
        self.module = module
        self.tables = tables
        self.returnCache = returnCache
        self.dialect = dialect
        self.budget = budget
    }

    func tearDown() {
        for cls in classes.values { cls.tearDown() }
        for cls in nodeClasses.values { cls.tearDown() }
        classes.removeAll()
        nodeClasses.removeAll()
        functions.removeAll()
        nodeFunctions.removeAll()
        moduleMemo.removeAll()
        typeMemo.removeAll()
        returnMemo.removeAll()
        linearizations.removeAll()
    }

    // MARK: - Text

    func string(_ n: PyNode) -> String { text.substring(with: n.range) }

    /// Whether the source between two offsets holds the word `word`.
    func gapHas(_ word: String, from: Int, to: Int) -> Bool {
        guard to > from, to <= text.length else { return false }
        return text.substring(with: NSRange(location: from, length: to - from))
            .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_" || $0 == "$") })
            .contains { $0 == word }
    }

    /// A property key's name (`name`, `'quoted'`, `1`, `#private`); nil for computed keys.
    func keyName(_ key: PyNode) -> String? {
        switch key.kind {
        case .name, .privateName, .number: return string(key)
        case .string: return ScriptTypes.unquoted(string(key))
        default: return nil
        }
    }

    /// `private` / `protected` modifiers before a class member's key, or a `#name`.
    func isPrivateMember(_ member: PyNode, key: PyNode) -> Bool {
        key.kind == .privateName || gapHas("private", from: member.start, to: key.start)
            || gapHas("protected", from: member.start, to: key.start)
    }

    /// `a`, `a.b.c`, `this.x` for a pure name chain; nil otherwise.
    func chainKey(_ n: PyNode) -> String? {
        switch n.kind {
        case .name: return string(n)
        case .keywordLit: return string(n) == "this" ? "this" : nil
        case .member:
            let cs = n.children
            guard cs.count == 2, cs[1].kind == .name || cs[1].kind == .privateName, let base = chainKey(cs[0]) else { return nil }
            return base + "." + string(cs[1])
        case .paren, .nonNull:
            let ps = n.parts
            return ps.count == 1 ? chainKey(ps[0]) : nil
        default: return nil
        }
    }

    /// The JSDoc comment right before `node` (JavaScript only; for a
    /// statement inside `export`, the comment before the `export`).
    func jsdoc(before node: PyNode) -> JSDocComment? {
        guard isJavaScript else { return nil }
        var start = node.start
        if let comment = JSDoc.comment(before: start, in: text) { return JSDocComment(comment) }
        // `export function f` / `export const x`: the comment precedes `export`.
        let lineStart = max(0, start - 64)
        let head = text.substring(with: NSRange(location: lineStart, length: start - lineStart))
        if let r = head.range(of: "export default ", options: .backwards) ?? head.range(of: "export ", options: .backwards),
           head[r.upperBound...].allSatisfy({ $0 == " " }) {
            start = lineStart + (head[..<r.lowerBound] as Substring).utf16.count
            if let comment = JSDoc.comment(before: start, in: text) { return JSDocComment(comment) }
        }
        return nil
    }

    // MARK: - Entry

    /// The type of the object of member access `member` (a `.member` node);
    /// `?.` drops `null` / `undefined`.
    func receiverType(of member: PyNode) -> InferredType {
        guard let object = member.children.first else { return .unknown }
        let frame = frame(at: object)
        lastFrame = frame
        let t = eval(object, frame)
        return member.has(SyntaxFlags.optional) ? t.withoutNone : t
    }

    /// The frame the last receiver was evaluated in (private-member visibility).
    private(set) var lastFrame: SFrame?

    // MARK: - Frames at a position

    struct Walk {
        let chain: [PyNode]
        let set: Set<Int>
        let index: [Int: Int]
        let target: PyNode

        func contains(_ n: PyNode) -> Bool { set.contains(n.i) || n == target }
        func parent(of n: PyNode) -> PyNode? {
            guard let k = index[n.i], k > 0 else { return nil }
            return chain[k - 1]
        }
    }

    /// The flow environment right before `target` is evaluated.
    func frame(at target: PyNode) -> SFrame {
        let chain = target.ancestors
        var f = SFrame()
        f.modulePosition = target.start
        guard chain.count >= 2 else { return f }
        var index: [Int: Int] = [:]
        for (k, n) in chain.enumerated() { index[n.i] = k }
        let walk = Walk(chain: chain, set: Set(chain.map(\.i)), index: index, target: target)
        return descend(chain[1], f, walk)
    }

    private func next(_ s: PyNode, _ w: Walk) -> PyNode? { s.children.first { w.contains($0) } }

    func descend(_ s: PyNode, _ frame: SFrame, _ w: Walk) -> SFrame {
        guard budget.tick() else { return frame }
        var f = frame
        switch s.kind {
        case .exportDecl, .labeled:
            guard let n = next(s, w), n != w.target else { return f }
            return descend(n, f, w)
        case .funcDecl, .funcExpr, .arrow, .method:
            return descendFunction(s, f, w, contextual: nil)
        case .classDecl, .classExpr:
            return descendClass(s, f, w)
        case .block, .namespaceDecl:
            let block = s.kind == .block ? s : s.firstChild(.block)
            guard let block, w.contains(block) || block == s else { return descendExpr(s, f, w) }
            return walkTo(block, &f, w)
        case .ifStmt:
            let cs = s.children
            guard let cond = cs.first else { return f }
            if w.contains(cond) { return descendExpr(cond, f, w) }
            if cs.count >= 2, w.contains(cs[1]) { return descend(cs[1], narrow(f, cond, true), w) }
            if cs.count >= 3, w.contains(cs[2]) { return descend(cs[2], narrow(f, cond, false), w) }
            return f
        case .forStmt:
            let cs = s.children
            guard let body = cs.last else { return f }
            if let first = cs.first, first.kind == .varDecl {
                if w.contains(first) { return descend(first, f, w) }
                exec(first, &f, sink: nil)
            }
            if w.contains(body), cs.count > 1 { return descend(body, f, w) }
            if let n = next(s, w), n != w.target { return descendExpr(n, f, w) }
            return f
        case .forOf, .forIn:
            let cs = s.children
            guard cs.count >= 2 else { return f }
            if w.contains(cs[1]) { return descendExpr(cs[1], f, w) }
            if w.contains(cs[0]) { return f }
            bindForOf(s, &f)
            if cs.count >= 3, w.contains(cs[2]) { return descend(cs[2], f, w) }
            return f
        case .whileStmt:
            let cs = s.children
            guard let cond = cs.first else { return f }
            if w.contains(cond) { return descendExpr(cond, f, w) }
            if cs.count >= 2, w.contains(cs[1]) { return descend(cs[1], s.raw.aux == 1 ? f : narrow(f, cond, true), w) }
            return f
        case .doWhile:
            let cs = s.children
            if let body = cs.first, w.contains(body) { return descend(body, f, w) }
            if cs.count >= 2, w.contains(cs[1]) { return descendExpr(cs[1], f, w) }
            return f
        case .switchStmt:
            let cs = s.children
            guard let disc = cs.first else { return f }
            if w.contains(disc) { return descendExpr(disc, f, w) }
            for c in cs.dropFirst() where c.kind == .switchCase && w.contains(c) {
                var cf = f
                let parts = c.children
                var statements = parts
                if isCaseClause(c), let test = parts.first {
                    if w.contains(test) { return descendExpr(test, f, w) }
                    cf = narrowCase(cf, disc, test)
                    statements = Array(parts.dropFirst())
                }
                hoist(statements, &cf)
                for st in statements {
                    if w.contains(st) { return descend(st, cf, w) }
                    if st.start > w.target.start { break }
                    guard budget.tick() else { return cf }
                    exec(st, &cf, sink: nil)
                }
                return cf
            }
            return f
        case .tryStmt:
            var afterTry = f
            for p in s.children {
                switch p.kind {
                case .block:
                    let isTry = p == s.children.first
                    if w.contains(p) {
                        if isTry { return walkTo(p, &f, w) }
                        var fin = join([f, afterTry])
                        return walkTo(p, &fin, w)
                    }
                    if isTry { walkAll(p, &afterTry, sink: nil) }
                case .catchClause:
                    if w.contains(p) {
                        var e = join([f, afterTry])
                        bindCatch(p, &e)
                        if let b = p.firstChild(.block), w.contains(b) { return walkTo(b, &e, w) }
                        return e
                    }
                default: break
                }
            }
            return f
        case .varDecl:
            for d in s.children where d.kind == .declarator {
                if w.contains(d) {
                    if let initNode = initializer(d), w.contains(initNode) {
                        if initNode.kind == .arrow || initNode.kind == .funcExpr, let typeNode = declaredTypeNode(d) {
                            let sig = signatureParams(typeOf(typeNode, f))
                            return descendFunction(initNode, f, w, contextual: sig)
                        }
                        return descendExpr(initNode, f, w)
                    }
                    return f
                }
                bindDeclarator(d, statement: s, &f)
            }
            return f
        case .interfaceDecl, .typeAlias, .enumDecl, .importDecl:
            return f
        default:
            return descendExpr(s, f, w)
        }
    }

    private func isCaseClause(_ c: PyNode) -> Bool {
        c.end - c.start >= 4 && text.substring(with: NSRange(location: c.start, length: 4)) == "case"
    }

    /// Enters a function on the chain: its body with parameters bound
    /// (`contextual`: parameter types from the call it is an argument of).
    private func descendFunction(_ s: PyNode, _ f: SFrame, _ w: Walk, contextual: [InferredType]?) -> SFrame {
        let fn = registerFunction(s, in: f)
        guard let body = fn.body, w.contains(body) else { return descendExpr(s, f, w) }
        var inner = functionFrame(fn, contextual: contextual)
        if body.kind == .block { return walkTo(body, &inner, w) }
        return descendExpr(body, inner, w)
    }

    private func descendClass(_ s: PyNode, _ f: SFrame, _ w: Walk) -> SFrame {
        guard let body = s.firstChild(.classBody), w.contains(body) else { return descendExpr(s, f, w) }
        let cls = registerClass(s, in: f)
        cls.buildMembers()
        guard let member = next(body, w), member != w.target else { return cls.bodyFrame }
        var inner = cls.bodyFrame
        let instance = InferredType.instance(cls.ref, cls.typeParamNames.map { .typeVar($0, bound: nil) })
        let isStatic = member.has(SyntaxFlags.isStatic)
        inner.this = Thunk(isStatic ? .classObject(cls.ref, []) : instance)
        switch member.kind {
        case .method:
            guard let fn = nodeFunctions[member] else { return inner }
            guard let fbody = fn.body, w.contains(fbody) else { return descendExpr(member, inner, w) }
            var ff = functionFrame(fn, contextual: nil)
            if fbody.kind == .block { return walkTo(fbody, &ff, w) }
            return descendExpr(fbody, ff, w)
        case .property:
            if let fn = nodeFunctions.first(where: { member.contains($0.key) && w.contains($0.key) })?.value {
                return descendFunction(fn.node, inner, w, contextual: nil)
            }
            return descendExpr(member, inner, w)
        case .staticBlock:
            guard let block = member.firstChild(.block) else { return inner }
            inner.this = Thunk(.classObject(cls.ref, []))
            return walkTo(block, &inner, w)
        default:
            return descendExpr(member, inner, w)
        }
    }

    /// Walks `block`'s statements up to the one on the chain, then descends.
    func walkTo(_ block: PyNode, _ f: inout SFrame, _ w: Walk) -> SFrame {
        let statements = block.children
        hoist(statements, &f)
        for st in statements {
            if w.contains(st) {
                if st == w.target { return f }
                return descend(st, f, w)
            }
            if st.start > w.target.start { break }
            guard budget.tick() else { return f }
            exec(st, &f, sink: nil)
        }
        return f
    }

    /// Follows the chain inside an expression: conditional / logical
    /// operands narrow, functions and classes are entered (callbacks get
    /// contextual parameter types).
    private func descendExpr(_ start: PyNode, _ frame: SFrame, _ w: Walk) -> SFrame {
        var f = frame
        // A function or class expression that is itself the start (an
        // initialiser, a returned arrow): enter it.
        if start != w.target {
            switch start.kind {
            case .arrow, .funcExpr:
                if let body = registerFunction(start, in: f).body, w.contains(body) {
                    return descendFunction(start, f, w, contextual: nil)
                }
            case .classExpr:
                return descendClass(start, f, w)
            default:
                break
            }
        }
        var node = start
        while node != w.target {
            guard budget.tick(), let nx = next(node, w) else { return f }
            switch node.kind {
            case .ternary:
                let cs = node.children
                if cs.count == 3 {
                    if nx == cs[1] { f = narrow(f, cs[0], true) } else if nx == cs[2] { f = narrow(f, cs[0], false) }
                }
            case .binary:
                let cs = node.children
                if cs.count == 2, nx == cs[1] {
                    let op = SyntaxParsing.Op(rawValue: UInt8(truncatingIfNeeded: node.raw.aux))
                    if op == .ampAmp { f = narrow(f, cs[0], true) } else if op == .pipePipe { f = narrow(f, cs[0], false) }
                }
            default:
                break
            }
            switch nx.kind {
            case .arrow, .funcExpr:
                if nx == w.target { return f }
                return descendFunction(nx, f, w, contextual: contextualParameters(of: nx, parent: node, f))
            case .method:
                if node.kind == .object { return descendFunction(nx, f, w, contextual: nil) }
                return descend(nx, f, w)
            case .classExpr:
                if nx == w.target { return f }
                return descendClass(nx, f, w)
            default:
                break
            }
            node = nx
        }
        return f
    }

    // MARK: - Statements

    /// Function / class declarations of a block are visible throughout it
    /// (hoisting); interfaces, type aliases and enums bind types.
    func hoist(_ statements: [PyNode], _ f: inout SFrame) {
        for raw in statements {
            var st = raw
            if st.kind == .exportDecl, let inner = st.parts.first, st.raw.aux & ~SyntaxAux.typeOnly <= 1 { st = inner }
            switch st.kind {
            case .funcDecl:
                guard let name = st.firstChild(.name) else { continue }
                let n = string(name)
                if f.env[n] == nil {
                    let fn = registerFunction(st, in: f)
                    f.env[n] = Thunk(functionValue(fn))
                }
            case .classDecl, .interfaceDecl, .enumDecl:
                guard let name = st.firstChild(.name) else { continue }
                let n = string(name)
                if f.types[n] == nil {
                    let cls = registerClass(st, in: f)
                    f.types[n] = .decl(cls)
                    if st.kind != .interfaceDecl { f.env[n] = Thunk(.classObject(cls.ref, [])) }
                }
            case .typeAlias:
                guard let name = st.firstChild(.name) else { continue }
                f.types[string(name)] = .alias(makeAlias(st, f))
            default:
                continue
            }
        }
    }

    func makeAlias(_ st: PyNode, _ f: SFrame) -> SAlias {
        let ps = st.parts
        let name = ps.first.map(string) ?? ""
        var params: [(String, PyNode?)] = []
        if let tps = st.firstChild(.typeParams) {
            for tp in tps.parts where tp.kind == .typeParam {
                let tpp = tp.parts
                guard let n = tpp.first, n.kind == .name else { continue }
                let c = tpp.count >= 2 && gapHas("extends", from: n.end, to: tpp[1].start) ? tpp[1] : nil
                params.append((string(n), c))
            }
        }
        let body = ps.last { $0.kind != .name && $0.kind != .typeParams }
        return SAlias(node: st, name: name, defining: f, typeParams: params, body: body)
    }

    /// Executes a statement not containing the target. Returns false when
    /// control cannot fall through it.
    @discardableResult
    func exec(_ s: PyNode, _ f: inout SFrame, sink: SReturnSink?) -> Bool {
        guard budget.tick() else { return true }
        switch s.kind {
        case .varDecl:
            for d in s.children where d.kind == .declarator { bindDeclarator(d, statement: s, &f) }
        case .exprStmt:
            for e in s.parts { execExpression(e, &f) }
        case .returnStmt:
            sink?.values.append((s.parts.first, f))
            return false
        case .throwStmt, .breakStmt, .continueStmt:
            return false
        case .ifStmt:
            return execIf(s, &f, sink: sink)
        case .forStmt, .forOf, .forIn, .whileStmt, .doWhile:
            var body = f
            let cs = s.children
            if s.kind == .forOf || s.kind == .forIn { bindForOf(s, &body) }
            if s.kind == .forStmt, let first = cs.first, first.kind == .varDecl { exec(first, &body, sink: nil) }
            if s.kind == .whileStmt, s.raw.aux == 0, let cond = cs.first { body = narrow(body, cond, true) }
            let bodyNode = s.kind == .doWhile ? cs.first : cs.last
            if let b = bodyNode, cs.count >= 2 {
                let falls = exec(b, &body, sink: sink)
                f = falls ? join([f, body]) : f
            }
            if s.kind == .whileStmt, let cond = cs.first, isTrueLiteral(cond), !containsBreak(s) { return false }
        case .switchStmt:
            let cs = s.children
            guard let disc = cs.first else { return true }
            var outs: [SFrame] = []
            var hasDefault = false
            for c in cs.dropFirst() where c.kind == .switchCase {
                var cf = f
                var statements = c.children
                if isCaseClause(c), let test = statements.first {
                    cf = narrowCase(cf, disc, test)
                    statements.removeFirst()
                } else {
                    hasDefault = true
                }
                hoist(statements, &cf)
                var falls = true
                for st in statements where !exec(st, &cf, sink: sink) { falls = false; break }
                if falls || statements.contains(where: { $0.kind == .breakStmt }) { outs.append(cf) }
            }
            if !hasDefault { outs.append(f) }
            if outs.isEmpty { return false }
            f = join(outs)
        case .tryStmt:
            return execTry(s, &f, sink: sink)
        case .block:
            return walkAll(s, &f, sink: sink)
        case .funcDecl:
            if let name = s.firstChild(.name) {
                let fn = registerFunction(s, in: f)
                bindName(string(name), Thunk(functionValue(fn)), &f)
            }
        case .classDecl, .enumDecl:
            let cls = registerClass(s, in: f)
            bindName(cls.name, Thunk(.classObject(cls.ref, [])), &f)
            f.types[cls.name] = .decl(cls)
        case .interfaceDecl:
            let cls = registerClass(s, in: f)
            f.types[cls.name] = .decl(cls)
        case .typeAlias:
            let alias = makeAlias(s, f)
            f.types[alias.name] = .alias(alias)
        case .labeled:
            if let inner = s.parts.last { return exec(inner, &f, sink: sink) }
        case .exportDecl:
            if let inner = s.parts.first, s.raw.aux & ~SyntaxAux.typeOnly <= 1 { return exec(inner, &f, sink: sink) }
        case .importDecl:
            for spec in s.parts where spec.kind == .importSpec {
                let names = spec.parts.filter { $0.kind == .name }
                let local = spec.raw.aux & 3 == 3 ? names.first : names.last
                if let local { bindName(string(local), Thunk(.unknown), &f) }
            }
        default:
            break
        }
        return true
    }

    /// Walks every statement of `block`; false when its end is unreachable.
    @discardableResult
    func walkAll(_ block: PyNode, _ f: inout SFrame, sink: SReturnSink?) -> Bool {
        let statements = block.children
        hoist(statements, &f)
        for st in statements {
            guard budget.tick() else { return true }
            if !exec(st, &f, sink: sink) { return false }
        }
        return true
    }

    private func execIf(_ s: PyNode, _ f: inout SFrame, sink: SReturnSink?) -> Bool {
        let cs = s.children
        guard let cond = cs.first else { return true }
        var outs: [SFrame] = []
        if cs.count >= 2 {
            var b = narrow(f, cond, true)
            if exec(cs[1], &b, sink: sink) { outs.append(b) }
        }
        var e = narrow(f, cond, false)
        if cs.count >= 3 {
            if exec(cs[2], &e, sink: sink) { outs.append(e) }
        } else {
            outs.append(e)
        }
        guard !outs.isEmpty else { return false }
        f = join(outs)
        return true
    }

    private func execTry(_ s: PyNode, _ f: inout SFrame, sink: SReturnSink?) -> Bool {
        let cs = s.children
        var outs: [SFrame] = []
        var afterTry = f
        var tryFalls = true
        var finallyBlock: PyNode?
        for (k, p) in cs.enumerated() {
            switch p.kind {
            case .block where k == 0:
                tryFalls = walkAll(p, &afterTry, sink: sink)
            case .catchClause:
                var e = join([f, afterTry])
                bindCatch(p, &e)
                if let b = p.firstChild(.block), walkAll(b, &e, sink: sink) { outs.append(e) }
            case .block:
                finallyBlock = p
            default: break
            }
        }
        if tryFalls { outs.append(afterTry) }
        if let fb = finallyBlock {
            var fin = outs.isEmpty ? join([f, afterTry]) : join(outs)
            let falls = walkAll(fb, &fin, sink: sink)
            f = fin
            return falls && !outs.isEmpty
        }
        guard !outs.isEmpty else { return false }
        f = join(outs)
        return true
    }

    private func isTrueLiteral(_ n: PyNode) -> Bool { n.kind == .keywordLit && string(n) == "true" }

    private func containsBreak(_ loop: PyNode) -> Bool {
        var found = false
        loop.children.last?.walk { n in
            if found { return false }
            switch n.kind {
            case .breakStmt: found = true; return false
            case .forStmt, .forOf, .forIn, .whileStmt, .doWhile, .switchStmt, .funcDecl, .funcExpr, .arrow,
                 .classDecl, .classExpr: return false
            default: return true
            }
        }
        return found
    }

    /// An expression statement: assignments rebind, container methods
    /// give element evidence.
    private func execExpression(_ e: PyNode, _ f: inout SFrame) {
        switch e.kind {
        case .sequence:
            for p in e.parts { execExpression(p, &f) }
        case .assignExpr:
            let ps = e.parts
            guard ps.count == 2 else { return }
            let op = SyntaxParsing.Op(rawValue: UInt8(truncatingIfNeeded: e.raw.aux))
            let target = ps[0], valueNode = ps[1]
            let snapshot = f
            if op == .assign {
                if target.kind == .objectPattern || target.kind == .arrayPattern {
                    bindPattern(target, Thunk(lazy: { [unowned self] in self.eval(valueNode, snapshot) }), &f)
                    return
                }
                guard let key = chainKey(target) else { return }
                let old = f.env[key]
                bindName(key, Thunk(lazy: { [unowned self] in
                    let v = self.eval(valueNode, snapshot)
                    if v == .unknown, let old { return old.get() }
                    return v
                }), &f)
            } else if op == .nullishAssign || op == .lorAssign, let key = chainKey(target) {
                let old = f.env[key]
                bindName(key, Thunk(lazy: { [unowned self] in
                    let current = old?.get() ?? self.evalKey(key, snapshot)
                    return .union([current.withoutNone, self.eval(valueNode, snapshot)])
                }), &f)
            }
        case .call:
            containerEvidence(e, &f)
        case .paren, .await, .unary:
            if let inner = e.parts.first { execExpression(inner, &f) }
        default:
            break
        }
    }

    /// `x.push(v)` / `unshift` / `add` / `set(k, v)` on a local array, set or
    /// map whose element type is unknown gives it one.
    private func containerEvidence(_ e: PyNode, _ f: inout SFrame) {
        let cs = e.parts
        guard cs.count >= 2, cs[0].kind == .member else { return }
        let mcs = cs[0].parts
        guard mcs.count == 2, mcs[1].kind == .name, let key = chainKey(mcs[0]), let old = f.env[key],
              let argsNode = cs.last, argsNode.kind == .args else { return }
        let method = string(mcs[1])
        guard ["push", "unshift", "add", "set"].contains(method) else { return }
        let args = argsNode.parts
        let snapshot = f
        bindName(key, Thunk(lazy: { [unowned self] in
            let current = old.get()
            guard case .instance(let ref, let targs) = current, targs.allSatisfy({ $0 == .unknown }) else { return current }
            @MainActor func arg(_ k: Int) -> InferredType? {
                guard k < args.count else { return nil }
                if args[k].kind == .spread, let inner = args[k].parts.first {
                    return self.iterationElement(self.eval(inner, snapshot))
                }
                return self.eval(args[k], snapshot)
            }
            switch (ref, method) {
            case (ScriptTypes.array, "push"), (ScriptTypes.array, "unshift"):
                let parts = (0..<args.count).compactMap { arg($0)?.widened }
                return parts.isEmpty ? current : .instance(ref, [.union(parts)])
            case (ScriptTypes.set, "add"):
                guard let a = arg(0) else { return current }
                return .instance(ref, [a.widened])
            case (ScriptTypes.map, "set"):
                guard let k = arg(0), let v = arg(1) else { return current }
                return .instance(ref, [k.widened, v.widened])
            default:
                return current
            }
        }), &f)
    }

    // MARK: - Bindings

    func bindName(_ name: String, _ value: Thunk, _ f: inout SFrame) {
        let prefix = name + "."
        if f.env.keys.contains(where: { $0.hasPrefix(prefix) }) {
            for k in f.env.keys where k.hasPrefix(prefix) { f.env[k] = nil }
        }
        f.env[name] = value
    }

    func initializer(_ d: PyNode) -> PyNode? {
        guard d.raw.aux & 2 != 0 else { return nil }
        return d.parts.last
    }

    func declaredTypeNode(_ d: PyNode) -> PyNode? {
        guard d.raw.aux & 1 != 0 else { return nil }
        let ps = d.parts
        return ps.count >= 2 ? ps[1] : nil
    }

    /// Binds a declarator: its annotation (or JSDoc `@type`), else its
    /// initialiser (literals kept for `const`, widened for `let` / `var`).
    func bindDeclarator(_ d: PyNode, statement: PyNode, _ f: inout SFrame) {
        guard let binding = d.parts.first else { return }
        let typeNode = declaredTypeNode(d)
        let initNode = initializer(d)
        let isConst = statement.kind == .varDecl && statement.raw.aux == 2
        let jsdocType = typeNode == nil ? jsdoc(before: statement)?.type : nil
        let snapshot = f
        let name = binding.kind == .name ? string(binding) : nil
        let value = Thunk(lazy: { [unowned self] in
            if let typeNode {
                let t = self.typeOf(typeNode, snapshot)
                if t != .unknown { return t }
            }
            if let jsdocType {
                let t = self.jsdocType(jsdocType, snapshot)
                if t != .unknown { return t }
            }
            guard let initNode else { return .unknown }
            var initFrame = snapshot
            if let name, initNode.kind == .arrow || initNode.kind == .funcExpr || initNode.kind == .classExpr {
                initFrame.qualPrefix = snapshot.qualPrefix
                return self.evalNamedFunction(initNode, name: name, initFrame)
            }
            let v = self.eval(initNode, initFrame)
            return isConst ? v : v.widened
        })
        bindPattern(binding, value, &f)
    }

    /// Binds a destructuring target (or a name) to `value`.
    func bindPattern(_ t: PyNode, _ value: Thunk, _ f: inout SFrame) {
        switch t.kind {
        case .name:
            bindName(string(t), value, &f)
        case .member, .keywordLit:
            if let key = chainKey(t) { bindName(key, value, &f) }
        case .objectPattern:
            for p in t.parts {
                switch p.kind {
                case .patternProp:
                    let ps = p.parts
                    guard let key = ps.first, let name = keyName(key) else { continue }
                    let member = Thunk(lazy: { [unowned self] in self.memberType(value.get(), name) })
                    if p.raw.aux == 1 {
                        // `{ a }` / `{ a = d }`
                        if ps.count >= 2 {
                            let d = ps[1]
                            let snapshot = f
                            bindName(name, Thunk(lazy: { [unowned self] in
                                .union([member.get().withoutNone, self.eval(d, snapshot).widened])
                            }), &f)
                        } else {
                            bindName(name, member, &f)
                        }
                    } else if ps.count >= 2 {
                        bindPattern(ps[1], member, &f)
                    }
                case .restElement:
                    if let inner = p.parts.first { bindPattern(inner, Thunk(.unknown), &f) }
                default:
                    continue
                }
            }
        case .arrayPattern:
            var k = 0
            for p in t.children {
                defer { k += 1 }
                switch p.kind {
                case .elision: continue
                case .restElement:
                    if let inner = p.parts.first {
                        bindPattern(inner, Thunk(lazy: { [unowned self] in
                            ScriptTypes.arrayOf(self.iterationElement(value.get()).widened)
                        }), &f)
                    }
                default:
                    let index = k
                    bindPattern(p, Thunk(lazy: { [unowned self] in self.element(of: value.get(), index) }), &f)
                }
            }
        case .assignPattern:
            let ps = t.parts
            guard let target = ps.first else { return }
            if ps.count >= 2 {
                let d = ps[1]
                let snapshot = f
                bindPattern(target, Thunk(lazy: { [unowned self] in
                    .union([value.get().withoutNone, self.eval(d, snapshot).widened])
                }), &f)
            } else {
                bindPattern(target, value, &f)
            }
        default:
            break
        }
    }

    /// Element `k` when destructuring `value` (tuples per element).
    func element(of value: InferredType, _ k: Int) -> InferredType {
        if case .instance(let ref, let args) = value, ref == ScriptTypes.tuple {
            return k < args.count ? args[k] : .unknown
        }
        return iterationElement(value)
    }

    func bindForOf(_ s: PyNode, _ f: inout SFrame) {
        let cs = s.children
        guard cs.count >= 2 else { return }
        let left = cs[0], iterable = cs[1]
        let snapshot = f
        let isOf = s.kind == .forOf
        let isAwait = isOf && gapHas("await", from: s.start, to: left.start)
        let value = Thunk(lazy: { [unowned self] in
            guard isOf else { return ScriptTypes.stringType }
            let e = self.iterationElement(self.eval(iterable, snapshot))
            return isAwait ? self.awaited(e) : e
        })
        if left.kind == .varDecl {
            for d in left.children where d.kind == .declarator {
                if let b = d.parts.first { bindPattern(b, value, &f) }
            }
        } else {
            bindPattern(left, value, &f)
        }
    }

    func bindCatch(_ clause: PyNode, _ f: inout SFrame) {
        let ps = clause.parts
        guard let b = ps.first, b.kind != .block else { return }
        bindPattern(b, Thunk(.unknown), &f)
    }

    // MARK: - Joins and narrowing

    func join(_ frames: [SFrame]) -> SFrame {
        guard var out = frames.first else { return SFrame() }
        guard frames.count > 1 else { return out }
        var keys = Set<String>()
        for f in frames { keys.formUnion(f.env.keys) }
        var env: [String: Thunk] = [:]
        for key in keys {
            let thunks = frames.compactMap { $0.env[key] }
            if thunks.count == frames.count, thunks.allSatisfy({ $0 === thunks[0] }) {
                env[key] = thunks[0]
            } else if thunks.count < frames.count, key.contains(".") {
                continue    // a narrowed chain on some paths only: back to its plain value
            } else {
                var unique: [Thunk] = []
                for t in thunks where !unique.contains(where: { $0 === t }) { unique.append(t) }
                if unique.count == 1 { env[key] = unique[0]; continue }
                env[key] = Thunk(lazy: { .union(unique.map { $0.get() }) })
            }
        }
        out.env = env
        return out
    }

    /// `frame` with `cond` assumed true (`positive`) or false.
    func narrow(_ frame: SFrame, _ cond: PyNode, _ positive: Bool) -> SFrame {
        guard budget.tick() else { return frame }
        let f = frame
        switch cond.kind {
        case .paren:
            if let inner = cond.parts.first { return narrow(f, inner, positive) }
        case .unary:
            let op = SyntaxParsing.Op(rawValue: UInt8(truncatingIfNeeded: cond.raw.aux))
            if op == .bang, let inner = cond.parts.first { return narrow(f, inner, !positive) }
        case .binary:
            let cs = cond.parts
            guard cs.count == 2 else { return f }
            let op = SyntaxParsing.Op(rawValue: UInt8(truncatingIfNeeded: cond.raw.aux)) ?? .none
            switch op {
            case .ampAmp:
                if positive { return narrow(narrow(f, cs[0], true), cs[1], true) }
                return join([narrow(f, cs[0], false), narrow(narrow(f, cs[0], true), cs[1], false)])
            case .pipePipe:
                if !positive { return narrow(narrow(f, cs[0], false), cs[1], false) }
                return join([narrow(f, cs[0], true), narrow(narrow(f, cs[0], false), cs[1], true)])
            case .eq, .ne, .eqStrict, .neStrict:
                let equal = (op == .eq || op == .eqStrict) == positive
                return narrowEquality(f, cs[0], cs[1], equal: equal)
            case .instanceof:
                guard let key = chainKey(cs[0]) else { return f }
                let classNode = cs[1]
                return narrowKey(key, f) { [unowned self] current, snapshot in
                    self.narrowInstanceof(current, self.eval(classNode, snapshot), positive: positive)
                }
            case .in:
                guard cs[0].kind == .string, let prop = ScriptTypes.unquoted(string(cs[0])), let key = chainKey(cs[1]) else { return f }
                return narrowKey(key, f) { [unowned self] current, _ in self.narrowIn(current, prop, positive: positive) }
            default:
                return f
            }
        case .call:
            // `Array.isArray(x)`
            let cs = cond.parts
            guard positive, cs.count >= 2, string(cs[0]) == "Array.isArray", let args = cs.last, args.kind == .args,
                  let arg = args.parts.first, let key = chainKey(arg) else { return f }
            return narrowKey(key, f) { current, _ in
                let arrays = current.constituents.filter { ScriptTypes.arrayElement($0) != nil }
                return arrays.isEmpty ? ScriptTypes.arrayOf(.unknown) : .union(arrays)
            }
        case .name, .member, .nonNull:
            guard positive, let key = chainKey(cond) else { return f }
            return narrowKey(key, f) { current, _ in current.withoutNone }
        default:
            break
        }
        return f
    }

    /// `a === b` (or `!==` with `equal` false) for `typeof x`, `null` /
    /// `undefined` and discriminant properties.
    private func narrowEquality(_ f: SFrame, _ a: PyNode, _ b: PyNode, equal: Bool) -> SFrame {
        for (x, y) in [(a, b), (b, a)] {
            // `typeof x === 'string'`
            if x.kind == .unary, SyntaxParsing.Op(rawValue: UInt8(truncatingIfNeeded: x.raw.aux)) == .typeofOp,
               let operand = x.parts.first, let key = chainKey(operand), y.kind == .string,
               let tag = ScriptTypes.unquoted(string(y)) {
                return narrowKey(key, f) { [unowned self] current, _ in self.narrowTypeof(current, tag, positive: equal) }
            }
            // `x === null` / `x == undefined`
            if isNullish(y), let key = chainKey(x) {
                return narrowKey(key, f) { current, _ in
                    if equal { return current == .unknown || current.constituents.contains(.none) ? .none : .never }
                    return current.withoutNone
                }
            }
            // `x.kind === 'circle'`
            if x.kind == .member, isLiteral(y), let objectNode = x.parts.first, let key = chainKey(objectNode),
               let nameNode = x.parts.last, nameNode.kind == .name {
                let prop = string(nameNode)
                let literal = string(y)
                return narrowKey(key, f) { [unowned self] current, _ in
                    self.narrowDiscriminant(current, prop, literal, positive: equal)
                }
            }
        }
        return f
    }

    /// `switch (x.kind) { case 'a': … }` / `switch (typeof x)`.
    func narrowCase(_ f: SFrame, _ disc: PyNode, _ test: PyNode) -> SFrame {
        narrowEquality(f, disc, test, equal: true)
    }

    private func isNullish(_ n: PyNode) -> Bool {
        (n.kind == .keywordLit && (string(n) == "null" || string(n) == "undefined")) || (n.kind == .name && string(n) == "undefined")
    }

    private func isLiteral(_ n: PyNode) -> Bool {
        n.kind == .string || n.kind == .number || (n.kind == .keywordLit && (string(n) == "true" || string(n) == "false"))
    }

    /// Rebinds `key` to a narrowed view of its current type (`never`: unchanged).
    func narrowKey(_ key: String, _ frame: SFrame,
                   _ transform: @escaping @MainActor (InferredType, SFrame) -> InferredType) -> SFrame {
        var f = frame
        let snapshot = frame
        let current = f.env[key]
        f.env[key] = Thunk(lazy: { [unowned self] in
            let base = current?.get() ?? self.evalKey(key, snapshot)
            let narrowed = transform(base, snapshot)
            return narrowed == .never ? base : narrowed
        })
        return f
    }

    /// The value of a name chain without the frame's own override of it.
    func evalKey(_ key: String, _ f: SFrame) -> InferredType {
        let parts = key.split(separator: ".").map(String.init)
        guard let first = parts.first else { return .unknown }
        var t: InferredType = first == "this" ? (f.this?.get() ?? .unknown) : (f.env[first]?.get() ?? lookup(first, f))
        var prefix = first
        for part in parts.dropFirst() {
            prefix += "." + part
            if prefix != key, let override = f.env[prefix] { t = override.get(); continue }
            t = memberType(t, part)
        }
        return t
    }

    /// The `typeof` tag a constituent answers to (nil: unknown).
    private func typeofTag(_ t: InferredType) -> String? {
        switch t {
        case .none: return "undefined"
        case .callable, .classObject: return "function"
        case .instance(let ref, _), .literal(let ref, _):
            switch ref {
            case ScriptTypes.string: return "string"
            case ScriptTypes.number: return "number"
            case ScriptTypes.boolean: return "boolean"
            case ScriptTypes.bigint: return "bigint"
            case ScriptTypes.symbol: return "symbol"
            case ScriptTypes.function: return "function"
            default: return "object"
            }
        case .shape(let s): return s.call != nil ? "function" : "object"
        default: return nil
        }
    }

    private func typeForTag(_ tag: String) -> InferredType {
        switch tag {
        case "string": return ScriptTypes.stringType
        case "number": return ScriptTypes.numberType
        case "boolean": return ScriptTypes.booleanType
        case "bigint": return .instance(ScriptTypes.bigint, [])
        case "symbol": return .instance(ScriptTypes.symbol, [])
        case "undefined": return .none
        default: return .unknown
        }
    }

    func narrowTypeof(_ t: InferredType, _ tag: String, positive: Bool) -> InferredType {
        if t == .unknown { return positive ? typeForTag(tag) : .unknown }
        var kept: [InferredType] = []
        for part in t.constituents {
            guard let partTag = typeofTag(part) else {
                kept.append(positive ? typeForTag(tag) : part)
                continue
            }
            if (partTag == tag) == positive { kept.append(part) }
        }
        if kept.isEmpty { return positive ? typeForTag(tag) : .never }
        return .union(kept)
    }

    func narrowInstanceof(_ t: InferredType, _ classValue: InferredType, positive: Bool) -> InferredType {
        guard case .classObject(let ref, let args) = classValue else { return positive ? .unknown : t }
        let target = InferredType.instance(ref, args)
        if t == .unknown { return positive ? target : .unknown }
        var kept: [InferredType] = []
        for part in t.constituents {
            guard let (pref, pargs) = part.instanceClass else {
                if !positive, part != .unknown { kept.append(part) }
                continue
            }
            let isSub = linearization(pref, pargs).contains { $0.0 == ref }
            if positive {
                if isSub { kept.append(part) } else if linearization(ref, args).contains(where: { $0.0 == pref }) {
                    kept.append(target)
                }
            } else if !isSub {
                kept.append(part)
            }
        }
        if kept.isEmpty { return positive ? target : .never }
        return .union(kept)
    }

    func narrowIn(_ t: InferredType, _ prop: String, positive: Bool) -> InferredType {
        guard t != .unknown else { return t }
        let kept = t.constituents.filter { part in
            if part == .none { return false }
            guard let has = hasMember(part, prop) else { return true }
            return has == positive
        }
        return kept.isEmpty ? .never : .union(kept)
    }

    func narrowDiscriminant(_ t: InferredType, _ prop: String, _ literal: String, positive: Bool) -> InferredType {
        guard t != .unknown else { return t }
        let wanted = ScriptTypes.unquoted(literal) ?? literal
        let kept = t.constituents.filter { part in
            if part == .none { return false }
            let m = memberType(part, prop)
            let literals = m.constituents.compactMap { c -> String? in
                if case .literal(_, let text) = c { return ScriptTypes.unquoted(text) ?? text }
                return nil
            }
            guard literals.count == m.constituents.count, !literals.isEmpty else { return true }
            return literals.contains(wanted) == positive || (!positive && literals.count > 1)
        }
        return kept.isEmpty ? .never : .union(kept)
    }

    // MARK: - Names

    /// The value of `name` in frame `f`: local, enclosing, module, lib.
    func lookup(_ name: String, _ f: SFrame) -> InferredType {
        if let t = f.env[name] { return t.get() }
        for env in f.outer { if let t = env[name] { return t.get() } }
        return moduleLookup(name, before: f.modulePosition)
    }

    /// A module-level name: its declarations (before `position` at module
    /// level), then lib globals (ES, then DOM).
    func moduleLookup(_ name: String, before position: Int?) -> InferredType {
        let memoKey = position.map { "\(name)@\($0)" } ?? name
        recordDependency(on: name)
        if let hit = moduleMemo[memoKey] { return hit }
        moduleMemo[memoKey] = .unknown   // recursion guard
        var statements = module.bindingStatements(of: name).filter { isValueBinding($0) }
        if let position {
            statements = statements.filter { $0.start < position && !($0.start <= position && position < $0.end) }
            // Function declarations are hoisted.
            if statements.isEmpty {
                statements = module.bindingStatements(of: name).filter { declaration($0).kind == .funcDecl }
            }
            if let last = statements.last { statements = [last] }
        }
        var result: InferredType
        if statements.isEmpty {
            result = name == "undefined" ? .none : tables.globalValue(name, allowDOM: true)
        } else {
            var values: [InferredType] = []
            for s in statements.prefix(Self.maxUnionSites) { values.append(contentsOf: bindingValues(of: name, in: s)) }
            result = values.isEmpty ? .unknown : .union(values)
        }
        moduleMemo[memoKey] = result
        return result
    }

    /// The declaration inside an `export` wrapper (itself otherwise).
    func declaration(_ s: PyNode) -> PyNode {
        if s.kind == .exportDecl, s.raw.aux & ~SyntaxAux.typeOnly <= 1, let inner = s.parts.first { return inner }
        return s
    }

    private func isValueBinding(_ s: PyNode) -> Bool {
        switch declaration(s).kind {
        case .interfaceDecl, .typeAlias: return false
        default: return true
        }
    }

    /// The values `name` is bound to by module-level statement `s`.
    private func bindingValues(of name: String, in s: PyNode) -> [InferredType] {
        var frame = SFrame()
        frame.modulePosition = s.start
        let d = declaration(s)
        switch d.kind {
        case .funcDecl:
            let fn = registerFunction(d, in: frame, qualname: name)
            return [functionValue(fn)]
        case .classDecl, .enumDecl:
            let cls = registerClass(d, in: frame, qualname: name)
            return [.classObject(cls.ref, [])]
        case .varDecl:
            var tmp = frame
            for decl in d.children where decl.kind == .declarator { bindDeclarator(decl, statement: d, &tmp) }
            return tmp.env[name].map { [$0.get()] } ?? []
        case .importDecl, .namespaceDecl:
            return [.unknown]
        default:
            return []
        }
    }

    /// A module-level type declaration (interface — merged —, alias, class, enum).
    func moduleType(_ name: String) -> STypeDecl? {
        if let hit = typeMemo[name] { return hit }
        typeMemo[name] = .some(nil)
        recordDependency(on: name)
        var result: STypeDecl?
        let statements = module.bindingStatements(of: name).map(declaration)
        let interfaces = statements.filter { $0.kind == .interfaceDecl }
        if !interfaces.isEmpty {
            let frame = SFrame()
            let cls: SDocClass
            if let existing = classes[name], existing.nodes == interfaces { cls = existing } else {
                cls = SDocClass(kind: .interface, nodes: interfaces, qualname: name, defining: frame, evaluator: self)
                classes[name] = cls
                for n in interfaces { nodeClasses[n] = cls }
            }
            result = .decl(cls)
        } else if let s = statements.first(where: { $0.kind == .classDecl || $0.kind == .enumDecl }) {
            result = .decl(registerClass(s, in: SFrame(), qualname: name))
        } else if let s = statements.first(where: { $0.kind == .typeAlias }) {
            result = .alias(makeAlias(s, SFrame()))
        }
        typeMemo[name] = .some(result)
        return result
    }

    // MARK: - Dependencies (return-type cache validation)

    func recordDependency(on name: String) {
        guard !depStack.isEmpty else { return }
        let hash = moduleNameHash(name)
        for k in depStack.indices { depStack[k][name] = hash }
    }

    func moduleNameHash(_ name: String) -> UInt64 {
        if let h = nameHashes[name] { return h }
        var h: UInt64 = 0
        for s in module.bindingStatements(of: name) { h = (h &* 31) &+ module.textHash(s) }
        nameHashes[name] = h
        return h
    }

    // MARK: - Definitions

    /// Registers the function at `node` (one model per node and session).
    @discardableResult
    func registerFunction(_ node: PyNode, in frame: SFrame, owner: SDocClass? = nil, isStatic: Bool = false,
                          qualname: String? = nil) -> SDocFunction {
        if let existing = nodeFunctions[node] { return existing }
        let q: String
        if let qualname {
            q = qualname
        } else if node.kind == .funcDecl, let name = node.firstChild(.name) {
            q = frame.function == nil && frame.qualPrefix.isEmpty ? string(name) : localPrefix(frame) + string(name)
        } else {
            q = localPrefix(frame) + "<fn@\(node.start)>"
        }
        var defining = frame
        defining.modulePosition = nil
        let fn = SDocFunction(node: node, qualname: q, defining: defining, owner: owner, isStatic: isStatic, evaluator: self)
        if isJavaScript {
            var docTarget = node
            if node.kind == .arrow || node.kind == .funcExpr, let decl = enclosingDeclaration(of: node) { docTarget = decl }
            fn.jsdoc = jsdoc(before: docTarget)
        }
        functions[q] = fn
        nodeFunctions[node] = fn
        return fn
    }

    /// `f.<locals>.` inside a function, `<locals>.` elsewhere (not cacheable).
    private func localPrefix(_ frame: SFrame) -> String {
        if let fn = frame.function { return fn.qualname + ".<locals>." }
        return frame.qualPrefix.contains("<locals>") ? frame.qualPrefix : frame.qualPrefix + "<locals>."
    }

    /// The `const f = () => …` statement of a function expression (JSDoc host).
    private func enclosingDeclaration(of node: PyNode) -> PyNode? {
        let chain = node.ancestors
        guard chain.count >= 2 else { return nil }
        let parent = chain[chain.count - 1]
        if parent.kind == .declarator, chain.count >= 2 {
            return chain[chain.count - 2].kind == .varDecl ? chain[chain.count - 2] : nil
        }
        if parent.kind == .property || parent.kind == .prop { return parent }
        return nil
    }

    @discardableResult
    func registerClass(_ node: PyNode, in frame: SFrame, qualname: String? = nil) -> SDocClass {
        if let existing = nodeClasses[node] { return existing }
        let name = node.firstChild(.name).map(string)
        let q: String
        if let qualname {
            q = qualname
        } else if let name {
            q = frame.function == nil && frame.qualPrefix.isEmpty ? name : localPrefix(frame) + name
        } else {
            q = localPrefix(frame) + "<class@\(node.start)>"
        }
        let kind: SDocClass.Kind = node.kind == .interfaceDecl ? .interface : node.kind == .enumDecl ? .enum : .class
        var defining = frame
        defining.modulePosition = nil
        let cls = SDocClass(kind: kind, nodes: [node], qualname: q, defining: defining, evaluator: self)
        classes[q] = cls
        nodeClasses[node] = cls
        return cls
    }

    /// The document class of a qualified name (resolved from the module
    /// when not seen yet in this session).
    func docClass(_ qualname: String) -> SDocClass? {
        if let hit = classes[qualname] { return hit }
        guard !qualname.contains("<locals>"), !qualname.contains(".") else { return nil }
        if case .decl(let cls)? = moduleType(qualname) { return cls }
        return nil
    }

    func docFunction(_ qualname: String) -> SDocFunction? {
        if let hit = functions[qualname] { return hit }
        guard !qualname.contains("<locals>") else { return nil }
        let parts = qualname.split(separator: ".").map(String.init)
        if parts.count == 1 {
            _ = moduleLookup(parts[0], before: nil)
            return functions[qualname]
        }
        guard let owner = docClass(parts[0]) else { return nil }
        owner.buildMembers()
        return functions[qualname]
    }

    func functionValue(_ fn: SDocFunction) -> InferredType {
        .callable(CallableRef(.documentFunction(fn.qualname)))
    }

    /// A function expression bound by `const name = …` at module level gets
    /// the name as its qualified name (cacheable return type).
    func evalNamedFunction(_ node: PyNode, name: String, _ f: SFrame) -> InferredType {
        if node.kind == .classExpr {
            return .classObject(registerClass(node, in: f, qualname: f.function == nil && f.qualPrefix.isEmpty ? name : nil).ref, [])
        }
        let q: String? = f.function == nil && f.qualPrefix.isEmpty ? name : nil
        return functionValue(registerFunction(node, in: f, qualname: q))
    }

    // MARK: - Function frames and returns

    /// The type parameters a function sees (its owner's and its own).
    func typeParams(of fn: SDocFunction) -> [String: InferredType?] {
        var params = fn.defining.typeParams
        for (n, c) in fn.typeParameters(self) {
            params[n] = .some(c.map { typeOf($0, fn.defining) })
        }
        for n in fn.jsdoc?.templates ?? [] where params[n] == nil { params[n] = .some(nil) }
        return params
    }

    /// The frame at the start of `fn`'s body: parameters bound (declared,
    /// JSDoc, `contextual`, default value), `this`.
    func functionFrame(_ fn: SDocFunction, contextual: [InferredType]?) -> SFrame {
        let defining = fn.defining
        var f = SFrame()
        f.outer = defining.env.isEmpty ? defining.outer : [defining.env] + defining.outer
        f.types = defining.types
        f.function = fn
        f.classContext = defining.classContext ?? fn.owner?.qualname
        f.qualPrefix = fn.qualname + ".<locals>."
        f.typeParams = typeParams(of: fn)
        if fn.isArrow {
            f.this = defining.this
        } else if let owner = fn.owner {
            let args = owner.typeParamNames.map { InferredType.typeVar($0, bound: nil) }
            f.this = Thunk(fn.isStatic ? .classObject(owner.ref, []) : .instance(owner.ref, args))
        } else if let thisNode = fn.thisTypeNode {
            let scope = f
            f.this = Thunk(lazy: { [unowned self] in self.typeOf(thisNode, scope) })
        }
        let scope = f
        for (k, p) in fn.params.enumerated() {
            guard let binding = p.binding else { continue }
            let typeNode = p.typeNode
            let defaultNode = p.defaultNode
            let jsdoc = fn.jsdoc?.param(named: p.name)
            let context = contextual.flatMap { k < $0.count ? $0[k] : nil }
            let value = Thunk(lazy: { [unowned self] in
                var t: InferredType = .unknown
                if let typeNode {
                    t = self.typeOf(typeNode, scope)
                } else if let jsdoc {
                    t = self.jsdocType(jsdoc.type, scope)
                    if jsdoc.isOptional, t != .unknown { t = .union([t, .none]) }
                } else if let context {
                    t = context
                } else if let defaultNode {
                    let d = self.eval(defaultNode, defining).widened
                    t = d == .none ? .unknown : d
                }
                if p.isRest, typeNode == nil, jsdoc == nil, context == nil { return ScriptTypes.arrayOf(t) }
                // An optional parameter with a default is defined inside.
                if defaultNode != nil { t = t.withoutNone }
                return t
            })
            bindPattern(binding, value, &f)
        }
        return f
    }

    /// The declared return type of `fn` (annotation; JSDoc `@returns`), nil when none.
    func declaredReturn(_ fn: SDocFunction) -> InferredType? {
        let scope = SFrame(types: fn.defining.types, classContext: fn.defining.classContext, typeParams: typeParams(of: fn))
        if let r = fn.returnTypeNode {
            if r.kind == .typePredicate { return ScriptTypes.booleanType }
            return typeOf(r, scope)
        }
        if let r = fn.jsdoc?.returns { return jsdocType(r, scope) }
        return nil
    }

    /// The return type of a call of `fn` before argument solving.
    func declaredOrInferredReturn(_ fn: SDocFunction, contextual: [InferredType]? = nil) -> InferredType {
        if fn.role == .constructor { return .unknown }
        if let declared = declaredReturn(fn) { return declared }
        var t = inferredReturn(fn, contextual: contextual)
        if fn.isGenerator {
            t = .instance(.table("es", fn.isAsync ? "AsyncGenerator" : "Generator"), [.unknown, .unknown, .unknown])
        } else if fn.isAsync {
            t = .instance(ScriptTypes.promise, [awaited(t)])
        }
        return t
    }

    /// The union of `fn`'s `return`s (`undefined` when its end is reachable).
    private func inferredReturn(_ fn: SDocFunction, contextual: [InferredType]?) -> InferredType {
        let key = fn.qualname
        let memoable = contextual == nil
        if memoable, let hit = returnMemo[key] { return hit }
        if inProgress.contains(key) || callDepth >= Self.maxCallDepth { return .unknown }
        let cacheable = memoable && !key.contains("<locals>")
        var cacheKey = ""
        if cacheable {
            cacheKey = "js:" + key + "#" + String(module.textHash(fn.node))
            if let cached = returnCache.value(for: cacheKey),
               cached.dependencies.allSatisfy({ moduleNameHash($0.key) == $0.value }) {
                returnCacheHits += 1
                returnMemo[key] = cached.type
                for name in cached.dependencies.keys { recordDependency(on: name) }
                return cached.type
            }
        }
        returnInferences += 1
        inProgress.insert(key)
        callDepth += 1
        depStack.append([:])
        if let owner = fn.owner { recordDependency(on: String(owner.qualname.split(separator: ".").first ?? "")) }
        var frame = functionFrame(fn, contextual: contextual)
        var parts: [InferredType] = []
        if let body = fn.body {
            if body.kind == .block {
                let sink = SReturnSink()
                let falls = walkAll(body, &frame, sink: sink)
                parts = sink.values.map { item in
                    guard let node = item.node else { return .none }
                    return self.eval(node, item.frame).widened
                }
                if falls || parts.isEmpty { parts.append(.none) }
            } else {
                parts = [eval(body, frame).widened]
            }
        }
        let result = InferredType.union(parts)
        let deps = depStack.removeLast()
        callDepth -= 1
        inProgress.remove(key)
        for (name, hash) in deps { for k in depStack.indices { depStack[k][name] = hash } }
        if !isAborted, memoable {
            returnMemo[key] = result
            if cacheable, !result.mentionsLocalClass {
                let entry = CachedReturn(type: result, dependencies: deps)
                returnCache.insert(entry, for: cacheKey, cost: entry.approximateBytes + cacheKey.utf8.count)
            }
        }
        return result
    }

    // MARK: - Types from the document

    /// The type a type node denotes in `frame`'s scope.
    func typeOf(_ n: PyNode, _ frame: SFrame) -> InferredType {
        guard budget.tick() else { return .unknown }
        if n.kind == .typePredicate { return ScriptTypes.booleanType }
        if n.kind == .keywordLit { return .unknown }
        return typeText(ScriptTypeText.cleaned(string(n)), frame)
    }

    /// A TypeScript type text in `frame`'s scope.
    func typeText(_ source: String, _ frame: SFrame) -> InferredType {
        guard let expr = TypeExpr.parse(source, syntax: .typescript) else { return .unknown }
        var converter = ScriptTypeConverter(typeParams: frame.typeParams) { [unowned self] name, args in
            self.resolveType(name, args, frame)
        }
        return converter.type(expr)
    }

    /// A JSDoc type text in `frame`'s scope.
    func jsdocType(_ source: String, _ frame: SFrame) -> InferredType {
        guard let ts = JSDoc.typeScriptText(source) else { return .unknown }
        return typeText(ts, frame)
    }

    /// A type name in `frame`'s scope: type parameters (handled by the
    /// converter), local declarations, module declarations, JSDoc
    /// typedefs, utility types, the lib.
    func resolveType(_ name: String, _ args: [InferredType], _ frame: SFrame) -> InferredType {
        guard budget.tick() else { return .unknown }
        if name.contains(".") {
            let head = String(name.prefix { $0 != "." })
            if frame.types[head] != nil || moduleType(head) != nil { return .unknown }
            return tables.resolve(name, args, allowDOM: true)
        }
        if let decl = frame.types[name] { return instantiate(decl, args) }
        if let decl = moduleType(name) { return instantiate(decl, args) }
        if isJavaScript, let typedef = typedef(named: name) { return typedefType(typedef) }
        switch name {
        case "Pick", "Omit":
            guard args.count == 2 else { return .unknown }
            let keys = Set(args[1].constituents.compactMap { c -> String? in
                if case .literal(_, let text) = c { return ScriptTypes.unquoted(text) }
                return nil
            })
            guard let listed = members(of: args[0], insideClass: nil) else { return .unknown }
            let picked = listed.filter { keys.contains($0.name) == (name == "Pick") }
            return .shape(ObjectShape(members: picked.map {
                ObjectShape.Member(name: $0.name, type: memberType(args[0], $0.name), isMethod: $0.kind == .method)
            }))
        case "ReturnType":
            if case .callable(let c)? = args.first { return callCallable(c, []) }
            return .unknown
        case "InstanceType":
            if case .classObject(let ref, let a)? = args.first { return .instance(ref, a) }
            return .unknown
        default:
            return tables.resolve(name, args, allowDOM: true)
        }
    }

    private func instantiate(_ decl: STypeDecl, _ args: [InferredType]) -> InferredType {
        switch decl {
        case .decl(let cls):
            if cls.kind == .enum { return enumType(cls) }
            return .instance(cls.ref, args)
        case .alias(let alias):
            guard let body = alias.body, aliasDepth < 8 else { return .unknown }
            aliasDepth += 1
            defer { aliasDepth -= 1 }
            var scope = alias.defining
            for (n, c) in alias.typeParams { scope.typeParams[n] = .some(c.map { typeOf($0, alias.defining) }) }
            var bindings: [String: InferredType] = [:]
            for (i, (n, _)) in alias.typeParams.enumerated() { bindings[n] = i < args.count ? args[i] : .unknown }
            return typeOf(body, scope).substituting(bindings)
        }
    }

    /// An enum used as a type: its members' value type (string / number).
    func enumType(_ cls: SDocClass) -> InferredType {
        cls.buildMembers()
        let values = cls.order.compactMap { cls.members[$0] }.map { m -> InferredType in
            guard let v = m.valueNode, v.kind == .string || v.kind == .template else { return ScriptTypes.numberType }
            return ScriptTypes.stringType
        }
        return values.isEmpty ? ScriptTypes.numberType : .union(values)
    }

    /// `extends <expr>` of a class: the instance type of its value.
    func classBase(_ node: PyNode, typeArgs: PyNode?, _ frame: SFrame) -> InferredType {
        var scope = frame
        scope.modulePosition = nil
        let value = eval(node, scope)
        let args = typeArgs.map { $0.parts.map { typeOf($0, frame) } } ?? []
        switch value {
        case .classObject(let ref, let a): return .instance(ref, args.isEmpty ? a : args)
        default: return .unknown
        }
    }

    // MARK: - JSDoc typedefs

    private func typedef(named name: String) -> JSDocComment? {
        if typedefs == nil {
            var found: [String: JSDocComment] = [:]
            var search = NSRange(location: 0, length: text.length)
            while found.count < 256 {
                let r = text.range(of: "@typedef", options: .literal, range: search)
                guard r.location != NSNotFound else { break }
                // The enclosing `/** … */`.
                let open = text.range(of: "/**", options: [.literal, .backwards],
                                      range: NSRange(location: 0, length: r.location))
                let close = text.range(of: "*/", options: .literal,
                                       range: NSRange(location: r.location, length: text.length - r.location))
                if open.location != NSNotFound, close.location != NSNotFound {
                    let doc = JSDocComment(text.substring(with: NSRange(location: open.location,
                                                                        length: NSMaxRange(close) - open.location)))
                    if let t = doc.typedef { found[t.name] = doc }
                    search = NSRange(location: NSMaxRange(close), length: text.length - NSMaxRange(close))
                } else {
                    search = NSRange(location: NSMaxRange(r), length: text.length - NSMaxRange(r))
                }
            }
            typedefs = found
        }
        return typedefs?[name]
    }

    private func typedefType(_ doc: JSDocComment) -> InferredType {
        guard let t = doc.typedef else { return .unknown }
        if !t.properties.isEmpty {
            return .shape(ObjectShape(members: t.properties.map {
                ObjectShape.Member(name: $0.name, type: jsdocType($0.type, SFrame()), isOptional: $0.isOptional)
            }))
        }
        guard let type = t.type else { return .unknown }
        return jsdocType(type, SFrame())
    }
}
