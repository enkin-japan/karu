import Foundation

// M17 T17.11b — Python type evaluation over the hand-written parser's tree
// (plan §8.1, the Python column). Demand-driven and lazy:
//
// - **Scope of work (plan §8.3).** A request evaluates the receiver of one
//   member access: the flow of the caret's function up to that point, and
//   whatever the receiver depends on — module-level bindings, called
//   functions' return types (bounded call depth, recursion guard), classes'
//   members. Nothing else is analysed.
// - **Flow.** A function body is walked statement by statement up to the
//   receiver with an environment of lazy `Thunk`s: assignments, `for` /
//   `with` / comprehension / `except` / `match` bindings, walrus, imports,
//   local `def` / `class`; `if` / `while` / `try` branches join, branches
//   that cannot fall through (return, raise, continue, break) are dropped
//   (early return narrows what follows). Conditions narrow (`isinstance`,
//   `is None` / `is not None`, `==` / `!=` None, truthiness, `and` / `or` /
//   `not`, `assert`) names and attribute chains (`self.x`). `append` / `add`
//   / `extend` / `insert` / `update` / item assignment give an empty
//   container literal its element type.
// - **Types.** Annotations (string annotations, `TypeVar`, generics, PEP 695
//   parameters), literals and container literals, calls (classes, document
//   functions — annotated or inferred from the union of `return`s — and
//   table functions with overload selection and type-variable solving),
//   attributes through the MRO with generic substitution, subscripts,
//   operators, `await`, iteration and context managers through the
//   protocols in the tables.
// - **Precision first (plan §13).** Anything not understood is `unknown`;
//   an unknown decorator makes a function's result unknown; a project
//   import (relative or not in the tables) is unknown until T17.13.

/// The environment of one scope during the flow walk.
struct PyFrame {
    var env: [String: Thunk] = [:]
    /// Names declared `global` / `nonlocal` here (looked up outside).
    var globals: Set<String> = []
    /// Enclosing function scopes' environments, innermost first.
    var outer: [[String: Thunk]] = []
    /// The function whose body this frame walks.
    var function: DocFunction?
    /// Evaluating directly in a class body.
    var classBody: DocClass?
    /// At module level: lookups see module bindings before this offset.
    var modulePosition: Int?
    /// Qualified-name prefix of definitions made here (`f.<locals>.`).
    var qualPrefix = ""
    /// PEP 695 / class type parameters visible here.
    var typeParams: [String] = []
}

/// A call argument.
struct PyArg {
    let keyword: String?
    /// `*x` (1) / `**x` (2).
    let star: Int
    let value: Thunk
}

/// Collects `return` values during a whole-body walk.
final class ReturnSink {
    var values: [(node: PyNode?, frame: PyFrame)] = []
}

@MainActor
final class PythonEvaluator {
    let text: NSString
    let module: PyModuleView
    let tables: PythonTypeTables
    /// Cross-version return-type cache (owned by the service).
    let returnCache: ByteLRU<String, CachedReturn>
    var budget: InferenceBudget

    static let maxCallDepth = 2
    static let maxUnionSites = 4

    private var callDepth = 0
    private var inProgress = Set<String>()
    private var returnMemo: [String: InferredType] = [:]
    private var moduleMemo: [String: InferredType] = [:]
    private var classes: [String: DocClass] = [:]
    private var functions: [String: DocFunction] = [:]
    var linearizations: [ClassRef: [(ClassRef, [InferredType])]] = [:]
    var linearizing = Set<ClassRef>()
    private var nameHashes: [String: UInt64] = [:]
    private var depStack: [[String: UInt64]] = []
    /// Results computed with an exhausted budget are not cached.
    var isAborted: Bool { budget.exhausted }

    /// Statistics (tests / perf).
    private(set) var returnCacheHits = 0
    private(set) var returnInferences = 0

    init(text: NSString, module: PyModuleView, tables: PythonTypeTables,
         returnCache: ByteLRU<String, CachedReturn>, budget: InferenceBudget) {
        self.text = text
        self.module = module
        self.tables = tables
        self.returnCache = returnCache
        self.budget = budget
    }

    /// Breaks the reference cycles between document classes and their
    /// methods (a method's defining frame holds its class) once a request
    /// is answered, so nothing of the request outlives it.
    func tearDown() {
        for cls in classes.values { cls.tearDown() }
        classes.removeAll()
        functions.removeAll()
        moduleMemo.removeAll()
        returnMemo.removeAll()
        linearizations.removeAll()
    }

    // MARK: - Text

    func string(_ n: PyNode) -> String { text.substring(with: n.range) }

    /// `a`, `a.b.c` for a pure name chain; nil otherwise.
    func chainKey(_ n: PyNode) -> String? {
        switch n.kind {
        case .name: return string(n)
        case .member:
            let cs = n.children
            guard cs.count == 2, cs[1].kind == .name, let base = chainKey(cs[0]) else { return nil }
            return base + "." + string(cs[1])
        case .paren:
            return n.parts.count == 1 ? chainKey(n.parts[0]) : nil
        default: return nil
        }
    }

    /// Whether the source between two offsets holds the word `word`.
    func gapHas(_ word: String, from: Int, to: Int) -> Bool {
        guard to > from else { return false }
        return text.substring(with: NSRange(location: from, length: to - from))
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == "\\" })
            .contains { $0 == word }
    }

    // MARK: - Entry

    /// The type of the object of member access `member` (a `.member` node).
    func receiverType(of member: PyNode) -> InferredType {
        guard let object = member.children.first else { return .unknown }
        let frame = frame(at: object)
        return eval(object, frame)
    }

    // MARK: - Frames at a position

    /// The flow environment right before `target` is evaluated.
    func frame(at target: PyNode) -> PyFrame {
        let chain = target.ancestors
        var f = PyFrame()
        f.modulePosition = target.start
        guard chain.count >= 2 else { return f }
        let onChain = Set(chain.map(\.i))
        return descend(chain[1], f, onChain, target)
    }

    private func descend(_ s: PyNode, _ frame: PyFrame, _ chain: Set<Int>, _ target: PyNode) -> PyFrame {
        guard budget.tick() else { return frame }
        var f = frame
        switch s.kind {
        case .funcDef:
            guard let block = s.firstChild(.block), chain.contains(block.i) else { return descendExpr(s, f, chain, target) }
            let fn = registerFunction(s, in: f)
            var inner = functionFrame(fn)
            return walkTo(block, &inner, chain, target)
        case .classDef:
            guard let block = s.firstChild(.block), chain.contains(block.i) else { return descendExpr(s, f, chain, target) }
            let cls = registerClass(s, in: f)
            var inner = PyFrame()
            inner.outer = f.function != nil || f.classBody != nil ? [f.env] + f.outer : f.outer
            inner.classBody = cls
            inner.qualPrefix = cls.qualname + "."
            inner.typeParams = f.typeParams + cls.typeParamNames
            return walkTo(block, &inner, chain, target)
        case .block:
            return walkTo(s, &f, chain, target)
        case .ifStmt:
            let ps = s.parts
            guard let cond = ps.first else { return f }
            if chain.contains(cond.i) { return descendExpr(cond, f, chain, target) }
            var cur = f
            var k = 0
            while k < ps.count {
                let p = ps[k]
                if p.kind == .block {
                    if chain.contains(p.i) { var b = narrow(cur, cond, true); return walkTo(p, &b, chain, target) }
                    cur = narrow(cur, cond, false)
                } else if p.kind == .elifClause {
                    let eps = p.parts
                    guard let econd = eps.first else { k += 1; continue }
                    if chain.contains(p.i) {
                        if chain.contains(econd.i) { return descendExpr(econd, cur, chain, target) }
                        if let eb = eps.first(where: { $0.kind == .block }), chain.contains(eb.i) {
                            var b = narrow(cur, econd, true)
                            return walkTo(eb, &b, chain, target)
                        }
                        return cur
                    }
                    cur = narrow(cur, econd, false)
                } else if p.kind == .elseClause, chain.contains(p.i), let eb = p.firstChild(.block) {
                    return walkTo(eb, &cur, chain, target)
                }
                k += 1
            }
            return cur
        case .whileStmt:
            let ps = s.parts
            guard let cond = ps.first else { return f }
            if chain.contains(cond.i) { return descendExpr(cond, f, chain, target) }
            if let block = s.firstChild(.block), chain.contains(block.i) {
                var b = narrow(f, cond, true)
                return walkTo(block, &b, chain, target)
            }
            if let e = s.firstChild(.elseClause), chain.contains(e.i), let eb = e.firstChild(.block) {
                var b = narrow(f, cond, false)
                return walkTo(eb, &b, chain, target)
            }
            return f
        case .forStmt:
            let ps = s.parts
            guard ps.count >= 2 else { return f }
            let targetNode = ps[0], iterable = ps[1]
            if chain.contains(iterable.i) { return descendExpr(iterable, f, chain, target) }
            if chain.contains(targetNode.i) { return f }
            bindFor(s, &f)
            if let block = s.firstChild(.block), chain.contains(block.i) { return walkTo(block, &f, chain, target) }
            if let e = s.firstChild(.elseClause), chain.contains(e.i), let eb = e.firstChild(.block) {
                return walkTo(eb, &f, chain, target)
            }
            return f
        case .withStmt:
            for p in s.parts {
                if p.kind == .withItem {
                    if chain.contains(p.i) {
                        if let e = p.parts.first, chain.contains(e.i) { return descendExpr(e, f, chain, target) }
                        return f
                    }
                    bindWithItem(p, async: s.has(SyntaxFlags.async), &f)
                } else if p.kind == .block, chain.contains(p.i) {
                    return walkTo(p, &f, chain, target)
                }
            }
            return f
        case .tryStmt:
            var afterTry = f
            for p in s.parts {
                switch p.kind {
                case .block:
                    if chain.contains(p.i) { return walkTo(p, &f, chain, target) }
                    _ = walkAll(p, &afterTry, sink: nil)
                case .exceptClause:
                    if chain.contains(p.i) {
                        var e = join([f, afterTry])
                        let eps = p.parts
                        if let typeNode = eps.first, typeNode.kind != .block, chain.contains(typeNode.i) {
                            return descendExpr(typeNode, f, chain, target)
                        }
                        bindExcept(p, &e)
                        if let eb = p.firstChild(.block), chain.contains(eb.i) { return walkTo(eb, &e, chain, target) }
                        return e
                    }
                case .elseClause, .finallyClause:
                    if chain.contains(p.i), let eb = p.firstChild(.block) {
                        var e = p.kind == .elseClause ? afterTry : join([f, afterTry])
                        return walkTo(eb, &e, chain, target)
                    }
                default: break
                }
            }
            return f
        case .matchStmt:
            let ps = s.parts
            guard let subject = ps.first else { return f }
            if chain.contains(subject.i) { return descendExpr(subject, f, chain, target) }
            guard let body = s.firstChild(.block) else { return f }
            for clause in body.parts where clause.kind == .caseClause && chain.contains(clause.i) {
                var c = f
                bindCase(clause, subject: subject, &c)
                let cps = clause.parts
                if cps.count >= 2, cps[1].kind != .block, chain.contains(cps[1].i) { return descendExpr(cps[1], c, chain, target) }
                if cps.count >= 2, cps[1].kind != .block { c = narrow(c, cps[1], true) }
                if let cb = clause.firstChild(.block), chain.contains(cb.i) { return walkTo(cb, &c, chain, target) }
                return c
            }
            return f
        case .elifClause, .elseClause, .exceptClause, .finallyClause, .caseClause:
            if let b = s.firstChild(.block), chain.contains(b.i) { return walkTo(b, &f, chain, target) }
            return f
        default:
            return descendStatementExpr(s, f, chain, target)
        }
    }

    /// Walks `block`'s statements up to the one on the chain, then descends.
    private func walkTo(_ block: PyNode, _ f: inout PyFrame, _ chain: Set<Int>, _ target: PyNode) -> PyFrame {
        for st in block.children {
            if chain.contains(st.i) { return descend(st, f, chain, target) }
            if st.start > target.start { break }
            guard budget.tick() else { return f }
            _ = exec(st, &f, sink: nil)
        }
        return f
    }

    /// A simple statement on the chain: walrus targets and recovered
    /// assignments before the target, then the expression chain.
    private func descendStatementExpr(_ s: PyNode, _ frame: PyFrame, _ chain: Set<Int>, _ target: PyNode) -> PyFrame {
        var f = frame
        bindRecovered(in: s, before: target.start, &f)
        s.walk { n in
            if n.kind == .lambda || n.kind == .listComp || n.kind == .setComp || n.kind == .dictComp || n.kind == .genExp {
                return false
            }
            if n.kind == .walrus, n.end <= target.start, !n.contains(target) {
                let cs = n.parts
                if cs.count == 2, cs[0].kind == .name {
                    let snapshot = f
                    let value = cs[1]
                    bindName(string(cs[0]), Thunk(lazy: { [unowned self] in self.eval(value, snapshot) }), &f)
                }
            }
            return true
        }
        return descendExpr(s, f, chain, target)
    }

    /// Follows the chain inside an expression: comprehensions, lambdas,
    /// conditional expressions and `and` / `or` operands adjust the frame.
    private func descendExpr(_ start: PyNode, _ frame: PyFrame, _ chain: Set<Int>, _ target: PyNode) -> PyFrame {
        var f = frame
        var node = start
        while node != target {
            guard let next = node.children.first(where: { chain.contains($0.i) || $0 == target }) else { return f }
            switch node.kind {
            case .listComp, .setComp, .dictComp, .genExp:
                f = comprehensionFrame(node, f, upTo: next)
            case .lambda:
                if let params = node.firstChild(.params), next != params {
                    var lf = PyFrame()
                    lf.outer = [f.env] + f.outer
                    lf.qualPrefix = f.qualPrefix
                    for p in params.parts where p.kind == .param {
                        if let name = p.children.first, name.kind == .name { lf.env[string(name)] = Thunk(.unknown) }
                    }
                    f = lf
                }
            case .ternary:
                let cs = node.parts
                if cs.count == 3 {
                    if next == cs[0] { f = narrow(f, cs[1], true) } else if next == cs[2] { f = narrow(f, cs[1], false) }
                }
            case .binary:
                let cs = node.parts
                if cs.count == 2, next == cs[1] {
                    let op = SyntaxParsing.Op(rawValue: UInt8(truncatingIfNeeded: node.raw.aux))
                    if op == .and { f = narrow(f, cs[0], true) } else if op == .or { f = narrow(f, cs[0], false) }
                }
            default:
                break
            }
            node = next
        }
        return f
    }

    /// The frame of a comprehension's element (or of its part `upTo`):
    /// each `for` binds its target, each `if` narrows.
    private func comprehensionFrame(_ comp: PyNode, _ frame: PyFrame, upTo: PyNode?) -> PyFrame {
        var f = frame
        for c in comp.parts where c.kind == .compFor {
            if let upTo, c == upTo || c.contains(upTo) {
                let cps = c.parts
                if cps.count >= 2, cps[1].contains(upTo) { return f }
                if cps.count >= 2 { bindTarget(cps[0], iterationThunk(cps[1], f, async: c.has(SyntaxFlags.async)), &f) }
                for ci in cps.dropFirst(2) where ci.kind == .compIf {
                    if ci.contains(upTo) { return f }
                    if let cond = ci.parts.first { f = narrow(f, cond, true) }
                }
                return f
            }
            let cps = c.parts
            guard cps.count >= 2 else { continue }
            bindTarget(cps[0], iterationThunk(cps[1], f, async: c.has(SyntaxFlags.async)), &f)
            for ci in cps.dropFirst(2) where ci.kind == .compIf {
                if let cond = ci.parts.first { f = narrow(f, cond, true) }
            }
        }
        return f
    }

    private func iterationThunk(_ iterable: PyNode, _ f: PyFrame, async: Bool) -> Thunk {
        Thunk(lazy: { [unowned self] in
            let t = self.eval(iterable, f)
            return async ? self.asyncIterationElement(t) : self.iterationElement(t)
        })
    }

    // MARK: - Statements

    /// Executes a statement not containing the target. Returns false when
    /// control cannot fall through it.
    @discardableResult
    func exec(_ s: PyNode, _ f: inout PyFrame, sink: ReturnSink?) -> Bool {
        guard budget.tick() else { return true }
        switch s.kind {
        case .assign:
            let cs = s.parts
            guard let valueNode = cs.last, cs.count >= 2 else { return true }
            let snapshot = f
            let value = Thunk(lazy: { [unowned self] in self.eval(valueNode, snapshot) })
            for t in cs.dropLast() { bindTarget(t, value, &f) }
        case .annAssign:
            let cs = s.parts
            guard cs.count >= 2 else { return true }
            let snapshot = f
            let annotation = cs[1]
            let valueNode = cs.count >= 3 ? cs[2] : nil
            let declared = Thunk(lazy: { [unowned self] in
                let t = self.annotationType(annotation, snapshot)
                if t == .unknown, let valueNode { return self.eval(valueNode, snapshot) }
                return t
            })
            bindTarget(cs[0], declared, &f)
        case .augAssign:
            let cs = s.parts
            guard cs.count == 2, let key = chainKey(cs[0]) else { return true }
            if lookupThunk(key, f) == nil {
                let snapshot = f
                let valueNode = cs[1]
                bindName(key, Thunk(lazy: { [unowned self] in self.eval(valueNode, snapshot).widened }), &f)
            }
        case .exprStmt:
            for e in s.parts {
                containerEvidence(e, &f)
                if isExitCall(e) { return false }
            }
            bindRecovered(in: s, before: Int.max, &f)
            bindWalrus(in: s, &f)
        case .returnStmt:
            sink?.values.append((s.parts.first, f))
            return false
        case .raiseStmt, .continueStmt, .breakStmt:
            return false
        case .ifStmt:
            return execIf(s, &f, sink: sink)
        case .whileStmt:
            let ps = s.parts
            guard let cond = ps.first else { return true }
            bindWalrus(in: cond, &f)
            var body = narrow(f, cond, true)
            if let block = s.firstChild(.block) {
                if walkAll(block, &body, sink: sink) { f = join([narrow(f, cond, false), body]) } else { f = narrow(f, cond, false) }
            }
            if let e = s.firstChild(.elseClause), let eb = e.firstChild(.block) { _ = walkAll(eb, &f, sink: sink) }
            if isTrueLiteral(cond), !containsBreak(s) { return false }
        case .forStmt:
            var body = f
            bindFor(s, &body)
            if let block = s.firstChild(.block) {
                let falls = walkAll(block, &body, sink: sink)
                f = falls ? join([f, body]) : join([f, bodyBeforeExit(body)])
            }
            if let e = s.firstChild(.elseClause), let eb = e.firstChild(.block) { _ = walkAll(eb, &f, sink: sink) }
        case .withStmt:
            for p in s.parts where p.kind == .withItem { bindWithItem(p, async: s.has(SyntaxFlags.async), &f) }
            if let block = s.firstChild(.block) { return walkAll(block, &f, sink: sink) }
        case .tryStmt:
            return execTry(s, &f, sink: sink)
        case .matchStmt:
            let ps = s.parts
            guard let subject = ps.first, let body = s.firstChild(.block) else { return true }
            var outs: [PyFrame] = [f]
            for clause in body.parts where clause.kind == .caseClause {
                var c = f
                bindCase(clause, subject: subject, &c)
                let cps = clause.parts
                if cps.count >= 2, cps[1].kind != .block { c = narrow(c, cps[1], true) }
                if let cb = clause.firstChild(.block), walkAll(cb, &c, sink: sink) { outs.append(c) }
            }
            f = join(outs)
        case .funcDef:
            let fn = registerFunction(s, in: f)
            if let name = fn.nameNode { bindName(string(name), Thunk(.callable(CallableRef(.documentFunction(fn.qualname)))), &f) }
        case .classDef:
            let cls = registerClass(s, in: f)
            bindName(cls.name, Thunk(.classObject(.document(cls.qualname), [])), &f)
        case .importStmt, .importFrom:
            bindImport(s, &f)
        case .globalStmt, .nonlocalStmt:
            for n in s.parts where n.kind == .name {
                let name = string(n)
                f.globals.insert(name)
                f.env[name] = nil
            }
        case .delStmt:
            for t in s.parts { if let key = chainKey(t) { f.env[key] = nil } }
        case .assertStmt:
            if let cond = s.parts.first { f = narrow(f, cond, true) }
        case .typeAliasStmt:
            if let n = s.parts.first, n.kind == .name { bindName(string(n), Thunk(.typeForm(.unknown)), &f) }
        case .block:
            return walkAll(s, &f, sink: sink)
        case .error:
            bindRecovered(in: s, before: Int.max, &f)
        default:
            break
        }
        return true
    }

    /// Walks every statement of `block`; false when its end is unreachable.
    @discardableResult
    func walkAll(_ block: PyNode, _ f: inout PyFrame, sink: ReturnSink?) -> Bool {
        var falls = true
        for st in block.children {
            guard budget.tick() else { return true }
            if !exec(st, &f, sink: sink) { falls = false; break }
        }
        return falls
    }

    private func bodyBeforeExit(_ f: PyFrame) -> PyFrame { f }

    private func execIf(_ s: PyNode, _ f: inout PyFrame, sink: ReturnSink?) -> Bool {
        let ps = s.parts
        guard let cond = ps.first else { return true }
        bindWalrus(in: cond, &f)
        var outs: [PyFrame] = []
        var cur = f
        var hasElse = false
        var lastCond = cond
        for p in ps.dropFirst() {
            switch p.kind {
            case .block:
                var b = narrow(cur, lastCond, true)
                if walkAll(p, &b, sink: sink) { outs.append(b) }
                cur = narrow(cur, lastCond, false)
            case .elifClause:
                let eps = p.parts
                guard let econd = eps.first else { continue }
                bindWalrus(in: econd, &cur)
                lastCond = econd
                var b = narrow(cur, econd, true)
                if let eb = p.firstChild(.block), walkAll(eb, &b, sink: sink) { outs.append(b) }
                cur = narrow(cur, econd, false)
            case .elseClause:
                hasElse = true
                var b = cur
                if let eb = p.firstChild(.block), walkAll(eb, &b, sink: sink) { outs.append(b) }
            default:
                break
            }
        }
        if !hasElse { outs.append(cur) }
        guard !outs.isEmpty else { return false }
        f = join(outs)
        return true
    }

    private func execTry(_ s: PyNode, _ f: inout PyFrame, sink: ReturnSink?) -> Bool {
        var outs: [PyFrame] = []
        var afterTry = f
        var tryFalls = true
        var elseFalls = true
        var finallyBlock: PyNode?
        for p in s.parts {
            switch p.kind {
            case .block:
                tryFalls = walkAll(p, &afterTry, sink: sink)
            case .exceptClause:
                var e = join([f, afterTry])
                bindExcept(p, &e)
                if let eb = p.firstChild(.block), walkAll(eb, &e, sink: sink) { outs.append(e) }
            case .elseClause:
                if tryFalls, let eb = p.firstChild(.block) { elseFalls = walkAll(eb, &afterTry, sink: sink) }
            case .finallyClause:
                finallyBlock = p.firstChild(.block)
            default: break
            }
        }
        if tryFalls && elseFalls { outs.append(afterTry) }
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

    private func isTrueLiteral(_ n: PyNode) -> Bool {
        (n.kind == .keywordLit && string(n) == "True") || (n.kind == .number && string(n) == "1")
    }

    private func containsBreak(_ loop: PyNode) -> Bool {
        var found = false
        loop.parts.first(where: { $0.kind == .block })?.walk { n in
            if found { return false }
            switch n.kind {
            case .breakStmt: found = true; return false
            case .forStmt, .whileStmt, .funcDef, .classDef, .lambda: return false
            default: return true
            }
        }
        return found
    }

    /// `sys.exit()`, `exit()`, `quit()`, `os._exit()`, `os.abort()`.
    private func isExitCall(_ e: PyNode) -> Bool {
        guard e.kind == .call, let callee = e.children.first, let key = chainKey(callee) else { return false }
        return ["sys.exit", "exit", "quit", "os._exit", "os.abort"].contains(key)
    }

    // MARK: - Bindings

    func bindName(_ name: String, _ value: Thunk, _ f: inout PyFrame) {
        let prefix = name + "."
        if f.env.keys.contains(where: { $0.hasPrefix(prefix) }) {
            for k in f.env.keys where k.hasPrefix(prefix) { f.env[k] = nil }
        }
        f.env[name] = value
    }

    /// Binds an assignment / loop / `with` target to `value`.
    func bindTarget(_ t: PyNode, _ value: Thunk, _ f: inout PyFrame) {
        switch t.kind {
        case .name:
            bindName(string(t), value, &f)
        case .tuple, .list:
            let items = t.parts
            for (k, item) in items.enumerated() {
                if item.kind == .starred {
                    if let inner = item.parts.first {
                        bindTarget(inner, Thunk(lazy: { [unowned self] in
                            .instance(.table("builtins", "list"), [self.iterationElement(value.get()).widened])
                        }), &f)
                    }
                } else {
                    let count = items.count
                    bindTarget(item, Thunk(lazy: { [unowned self] in self.element(of: value.get(), k, count) }), &f)
                }
            }
        case .paren:
            if let inner = t.parts.first { bindTarget(inner, value, &f) }
        case .starred:
            if let inner = t.parts.first {
                bindTarget(inner, Thunk(lazy: { [unowned self] in
                    .instance(.table("builtins", "list"), [self.iterationElement(value.get()).widened])
                }), &f)
            }
        case .member:
            if let key = chainKey(t) { bindName(key, value, &f) }
        case .subscript:
            // `d[k] = v`: element evidence for an empty dict / list.
            let cs = t.parts
            guard cs.count >= 2, let key = chainKey(cs[0]), let old = lookupThunk(key, f) else { return }
            let snapshot = f
            let index = cs[1]
            bindName(key, Thunk(lazy: { [unowned self] in
                let current = old.get()
                guard case .instance(let ref, let args) = current, args.allSatisfy({ $0 == .unknown }),
                      ref == .table("builtins", "dict") else { return current }
                return .instance(ref, [self.eval(index, snapshot).widened, value.get().widened])
            }), &f)
        default:
            break
        }
    }

    /// Element `k` of `count` when destructuring `value`.
    func element(of value: InferredType, _ k: Int, _ count: Int) -> InferredType {
        if case .instance(let ref, let args) = value, ref == .table("builtins", "tuple") {
            if args.count == count, k < args.count { return args[k] }
            if args.count == 1 { return args[0] }
        }
        return iterationElement(value)
    }

    func bindFor(_ s: PyNode, _ f: inout PyFrame) {
        let ps = s.parts
        guard ps.count >= 2 else { return }
        bindTarget(ps[0], iterationThunk(ps[1], f, async: s.has(SyntaxFlags.async)), &f)
    }

    func bindWithItem(_ item: PyNode, async: Bool, _ f: inout PyFrame) {
        let ps = item.parts
        guard ps.count >= 2 else { return }
        let snapshot = f
        let expr = ps[0]
        bindTarget(ps[1], Thunk(lazy: { [unowned self] in
            self.enterType(self.eval(expr, snapshot), async: async)
        }), &f)
    }

    func bindExcept(_ clause: PyNode, _ f: inout PyFrame) {
        let ps = clause.parts.filter { $0.kind != .block }
        guard ps.count >= 2, let alias = ps.last, alias.kind == .name,
              gapHas("as", from: ps[ps.count - 2].end, to: alias.start) else { return }
        let snapshot = f
        let typeNode = ps[0]
        bindName(string(alias), Thunk(lazy: { [unowned self] in
            self.exceptionInstance(self.eval(typeNode, snapshot))
        }), &f)
    }

    private func exceptionInstance(_ t: InferredType) -> InferredType {
        switch t {
        case .classObject(let ref, let args): return .instance(ref, args)
        case .instance(let ref, let args) where ref == .table("builtins", "tuple"):
            return .union(args.map { exceptionInstance($0) })
        case .anyOf(let parts): return .union(parts.map { exceptionInstance($0) })
        default: return .unknown
        }
    }

    func bindCase(_ clause: PyNode, subject: PyNode, _ f: inout PyFrame) {
        guard let pattern = clause.parts.first else { return }
        let snapshot = f
        let subjectThunk = Thunk(lazy: { [unowned self] in self.eval(subject, snapshot) })
        // Capture names anywhere in the pattern are unknown unless bound below.
        pattern.walk { n in
            if n.kind == .patternCapture || n.kind == .patternStar || n.kind == .patternAs,
               let name = n.children.last, name.kind == .name, n.raw.aux != 1 || n.kind != .patternCapture {
                bindName(string(name), Thunk(.unknown), &f)
            }
            return true
        }
        var top = pattern
        var alias: PyNode?
        if top.kind == .patternAs, let inner = top.parts.first, let name = top.parts.last, name.kind == .name {
            alias = name
            top = inner
        }
        switch top.kind {
        case .patternCapture where top.raw.aux != 1:
            if let name = top.parts.first, name.kind == .name { bindName(string(name), subjectThunk, &f) }
        case .patternClass:
            guard let classNode = top.parts.first else { break }
            let classThunk = Thunk(lazy: { [unowned self] in self.eval(classNode, snapshot) })
            let narrowed = Thunk(lazy: { [unowned self] in
                self.narrowIsInstance(subjectThunk.get(), classThunk.get(), positive: true)
            })
            if let key = chainKey(subject) { bindName(key, narrowed, &f) }
            if let alias { bindName(string(alias), narrowed, &f) }
        default:
            if let alias { bindName(string(alias), subjectThunk, &f) }
        }
    }

    private func bindWalrus(in n: PyNode, _ f: inout PyFrame) {
        n.walk { x in
            if x.kind == .lambda || x.kind == .listComp || x.kind == .setComp || x.kind == .dictComp || x.kind == .genExp {
                return false
            }
            if x.kind == .walrus {
                let cs = x.parts
                if cs.count == 2, cs[0].kind == .name {
                    let snapshot = f
                    let value = cs[1]
                    bindName(string(cs[0]), Thunk(lazy: { [unowned self] in self.eval(value, snapshot) }), &f)
                }
            }
            return true
        }
    }

    /// Incomplete code: inside an unclosed call, a `name = value` keyword
    /// argument that starts its own line is most likely the next statement
    /// swallowed by the open bracket (`x = f(a,` ⏎ `text = "hi"`).
    private func bindRecovered(in s: PyNode, before: Int, _ f: inout PyFrame) {
        var found: [PyNode] = []
        s.walk { n in
            if n.kind == .args, n.has(SyntaxFlags.missingClose) {
                for c in n.parts where c.kind == .keywordArg && c.end <= before && beginsLine(c.start) { found.append(c) }
            }
            return n.kind != .lambda && n.kind != .funcDef && n.kind != .classDef
        }
        for kw in found {
            let cs = kw.parts
            guard cs.count == 2, cs[0].kind == .name else { continue }
            let snapshot = f
            let value = cs[1]
            bindName(string(cs[0]), Thunk(lazy: { [unowned self] in self.eval(value, snapshot) }), &f)
        }
    }

    private func beginsLine(_ offset: Int) -> Bool {
        var k = offset - 1
        while k >= 0 {
            let u = text.character(at: k)
            if u == 10 || u == 13 { return true }
            if u != 32 && u != 9 { return false }
            k -= 1
        }
        return true
    }

    /// `x.append(v)` / `add` / `appendleft` / `insert` / `extend` / `update`
    /// on a local empty container gives it an element type.
    private func containerEvidence(_ e: PyNode, _ f: inout PyFrame) {
        guard e.kind == .call else { return }
        let cs = e.parts
        guard cs.count >= 2, cs[0].kind == .member else { return }
        let mcs = cs[0].parts
        guard mcs.count == 2, mcs[1].kind == .name, let key = chainKey(mcs[0]), let old = lookupThunk(key, f),
              let argsNode = cs.last, argsNode.kind == .args else { return }
        let method = string(mcs[1])
        guard ["append", "add", "appendleft", "insert", "extend", "update"].contains(method) else { return }
        let args = argsNode.parts.filter { $0.kind != .keywordArg && $0.kind != .starred }
        let snapshot = f
        bindName(key, Thunk(lazy: { [unowned self] in
            let current = old.get()
            guard case .instance(let ref, let targs) = current, targs.allSatisfy({ $0 == .unknown }) else { return current }
            let sequence: Set<String> = ["list", "set", "deque", "frozenset"]
            @MainActor func arg(_ k: Int) -> InferredType? { k < args.count ? self.eval(args[k], snapshot) : nil }
            switch method {
            case "append", "add", "appendleft":
                guard sequence.contains(ref.shortName), let a = arg(0) else { return current }
                return .instance(ref, [a.widened])
            case "insert":
                guard sequence.contains(ref.shortName), let a = arg(1) else { return current }
                return .instance(ref, [a.widened])
            case "extend":
                guard sequence.contains(ref.shortName), let a = arg(0) else { return current }
                return .instance(ref, [self.iterationElement(a).widened])
            case "update":
                guard let a = arg(0) else { return current }
                if ref.shortName == "dict", let (_, dargs) = self.upcast(a, to: .table("builtins", "dict")), dargs.count == 2 {
                    return .instance(ref, dargs)
                }
                if sequence.contains(ref.shortName) { return .instance(ref, [self.iterationElement(a).widened]) }
                return current
            default:
                return current
            }
        }), &f)
    }

    private func bindImport(_ s: PyNode, _ f: inout PyFrame) {
        if s.kind == .importStmt {
            for alias in s.parts where alias.kind == .alias {
                let ps = alias.parts
                guard let dotted = ps.first, dotted.kind == .dottedName else { continue }
                let path = string(dotted).filter { !$0.isWhitespace }
                if ps.count >= 2, ps[1].kind == .name {
                    bindName(string(ps[1]), Thunk(lazy: { [unowned self] in self.moduleValue(path) }), &f)
                } else if let head = path.split(separator: ".").first.map(String.init) {
                    bindName(head, Thunk(lazy: { [unowned self] in self.moduleValue(head) }), &f)
                }
            }
            return
        }
        let level = s.raw.aux
        let source = s.firstChild(.dottedName).map { string($0).filter { !$0.isWhitespace } }
        for alias in s.parts where alias.kind == .alias {
            let ps = alias.parts
            guard let original = ps.first, original.kind == .name else { continue }
            let local = ps.count >= 2 && ps[1].kind == .name ? string(ps[1]) : string(original)
            let name = string(original)
            bindName(local, Thunk(lazy: { [unowned self] in
                guard level == 0, let source else { return .unknown }
                return self.importedValue(module: source, name: name)
            }), &f)
        }
    }

    func moduleValue(_ path: String) -> InferredType {
        tables.store.hasPythonModule(path) ? .module(path) : .unknown
    }

    func importedValue(module: String, name: String) -> InferredType {
        guard tables.store.hasPythonModule(module) else { return .unknown }
        let v = tables.value(module: module, name: name)
        if v == .unknown, tables.store.hasPythonModule(module + "." + name) { return .module(module + "." + name) }
        return v
    }

    // MARK: - Joins and narrowing

    func join(_ frames: [PyFrame]) -> PyFrame {
        guard var out = frames.first else { return PyFrame() }
        guard frames.count > 1 else { return out }
        var keys = Set<String>()
        for f in frames { keys.formUnion(f.env.keys) }
        var env: [String: Thunk] = [:]
        for key in keys {
            let thunks = frames.compactMap { $0.env[key] }
            if thunks.allSatisfy({ $0 === thunks[0] }) {
                env[key] = thunks[0]
            } else {
                var unique: [Thunk] = []
                for t in thunks where !unique.contains(where: { $0 === t }) { unique.append(t) }
                env[key] = Thunk(lazy: { .union(unique.map { $0.get() }) })
            }
        }
        out.env = env
        for f in frames.dropFirst() { out.globals.formUnion(f.globals) }
        return out
    }

    /// The thunk currently bound to `key` (a name or `a.b` chain) in the
    /// frame's own environment; nil when it is not bound there.
    func lookupThunk(_ key: String, _ f: PyFrame) -> Thunk? { f.env[key] }

    /// `frame` with `cond` assumed true (`positive`) or false.
    func narrow(_ frame: PyFrame, _ cond: PyNode, _ positive: Bool) -> PyFrame {
        guard budget.tick() else { return frame }
        var f = frame
        switch cond.kind {
        case .paren:
            if let inner = cond.parts.first { return narrow(f, inner, positive) }
        case .unary:
            let op = SyntaxParsing.Op(rawValue: UInt8(truncatingIfNeeded: cond.raw.aux))
            if op == .not, let inner = cond.parts.first { return narrow(f, inner, !positive) }
        case .binary:
            let cs = cond.parts
            guard cs.count == 2 else { return f }
            let op = SyntaxParsing.Op(rawValue: UInt8(truncatingIfNeeded: cond.raw.aux))
            switch op {
            case .and:
                if positive { return narrow(narrow(f, cs[0], true), cs[1], true) }
                return join([narrow(f, cs[0], false), narrow(narrow(f, cs[0], true), cs[1], false)])
            case .or:
                if !positive { return narrow(narrow(f, cs[0], false), cs[1], false) }
                return join([narrow(f, cs[0], true), narrow(narrow(f, cs[0], false), cs[1], true)])
            case .is, .isNot, .eq, .ne:
                let isNone: PyNode?
                let subject: PyNode
                if isNoneLiteral(cs[1]) { isNone = cs[1]; subject = cs[0] } else if isNoneLiteral(cs[0]) { isNone = cs[0]; subject = cs[1] } else {
                    // `type(x) is C`
                    if (op == .is || op == .eq), positive, cs[0].kind == .call, let callee = cs[0].children.first,
                       string(callee) == "type", let arg = cs[0].firstChild(.args)?.parts.first, let key = chainKey(arg) {
                        let classNode = cs[1]
                        return narrowKey(key, f) { [unowned self] current, snapshot in
                            self.narrowIsInstance(current, self.eval(classNode, snapshot), positive: true)
                        }
                    }
                    return f
                }
                _ = isNone
                guard let key = chainKey(subject) else { return f }
                let toNone = (op == .is || op == .eq) == positive
                return narrowKey(key, f) { current, _ in toNone ? Self.onlyNone(current) : current.withoutNone }
            default:
                return f
            }
        case .call:
            let cs = cond.parts
            guard cs.count >= 2, string(cs[0]) == "isinstance", let args = cs.last, args.kind == .args else { break }
            let ps = args.parts
            guard ps.count == 2, let key = chainKey(ps[0]) else { return f }
            let classNode = ps[1]
            return narrowKey(key, f) { [unowned self] current, snapshot in
                self.narrowIsInstance(current, self.eval(classNode, snapshot), positive: positive)
            }
        case .walrus:
            let cs = cond.parts
            if cs.count == 2, cs[0].kind == .name, positive {
                let key = string(cs[0])
                if f.env[key] == nil {
                    let snapshot = f
                    let value = cs[1]
                    bindName(key, Thunk(lazy: { [unowned self] in self.eval(value, snapshot) }), &f)
                }
                return narrowKey(key, f) { current, _ in current.withoutNone }
            }
        case .name, .member:
            guard positive, let key = chainKey(cond) else { return f }
            return narrowKey(key, f) { current, _ in current.withoutNone }
        default:
            break
        }
        return f
    }

    private static func onlyNone(_ t: InferredType) -> InferredType {
        if t == .unknown { return .none }
        return t.constituents.contains(.none) || t.containsUnknown ? .none : .never
    }

    private func isNoneLiteral(_ n: PyNode) -> Bool { n.kind == .keywordLit && string(n) == "None" }

    /// Rebinds `key` to a narrowed view of its current type.
    private func narrowKey(_ key: String, _ frame: PyFrame,
                           _ transform: @escaping @MainActor (InferredType, PyFrame) -> InferredType) -> PyFrame {
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
    private func evalKey(_ key: String, _ f: PyFrame) -> InferredType {
        let parts = key.split(separator: ".").map(String.init)
        guard let first = parts.first else { return .unknown }
        var t = f.env[first]?.get() ?? lookup(first, f)
        var prefix = first
        for part in parts.dropFirst() {
            prefix += "." + part
            if prefix != key, let override = f.env[prefix] { t = override.get(); continue }
            t = memberType(t, part)
        }
        return t
    }

    /// `isinstance(x, C)` applied to `t` (`classes`: the evaluated second argument).
    func narrowIsInstance(_ t: InferredType, _ classes: InferredType, positive: Bool) -> InferredType {
        var targets: [(ClassRef, [InferredType])] = []
        func collect(_ c: InferredType) {
            switch c {
            case .classObject(let ref, let args): targets.append((ref, args))
            case .instance(let ref, let args) where ref == .table("builtins", "tuple"): args.forEach(collect)
            case .anyOf(let parts): parts.forEach(collect)
            case .typeForm(let inner): if case .instance(let ref, let args) = inner { targets.append((ref, args)) }
            default: break
            }
        }
        collect(classes)
        guard !targets.isEmpty else { return positive ? .unknown : t }
        if t == .unknown { return positive ? .union(targets.map { .instance($0.0, $0.1) }) : .unknown }
        var kept: [InferredType] = []
        for part in t.constituents {
            guard let (ref, args) = part.instanceClass else {
                if part == .none { if !positive { kept.append(part) }; continue }
                if part == .unknown { kept.append(positive ? .union(targets.map { .instance($0.0, $0.1) }) : part) }
                else if !positive { kept.append(part) }
                continue
            }
            let ancestry = mro(ref, args).map(\.0)
            var matched = false
            for (tref, targs) in targets {
                if ancestry.contains(tref) {
                    matched = true
                    if positive { kept.append(part) }
                    break
                }
                if positive, mro(tref, targs).map(\.0).contains(ref) {
                    matched = true
                    kept.append(.instance(tref, targs))
                    break
                }
            }
            if !matched, !positive { kept.append(part) }
        }
        if kept.isEmpty { return positive ? .union(targets.map { .instance($0.0, $0.1) }) : .never }
        return .union(kept)
    }

    // MARK: - Names

    /// The value of `name` in frame `f`: local, enclosing, module, builtins.
    func lookup(_ name: String, _ f: PyFrame) -> InferredType {
        if !f.globals.contains(name) {
            if let t = f.env[name] { return t.get() }
            for env in f.outer { if let t = env[name] { return t.get() } }
            if f.typeParams.contains(name) { return .typeForm(.typeVar(name, bound: nil)) }
        }
        return moduleLookup(name, before: f.modulePosition)
    }

    /// A module-level name: its binding statements (before `position` when
    /// evaluating at module level; else all of them, joined), then star
    /// imports, then builtins.
    func moduleLookup(_ name: String, before position: Int?) -> InferredType {
        let memoKey = position.map { "\(name)@\($0)" } ?? name
        recordDependency(on: name)
        if let hit = moduleMemo[memoKey] { return hit }
        moduleMemo[memoKey] = .unknown   // recursion guard
        var statements = module.bindingStatements(of: name)
        if let position {
            statements = statements.filter { $0.start < position && !($0.start <= position && position < $0.end) }
            if let last = statements.last { statements = [last] }
        }
        var result: InferredType
        if statements.isEmpty {
            result = .unknown
            for star in module.starImports() where tables.store.hasPythonModule(star) {
                let v = tables.value(module: star, name: name)
                if v != .unknown { result = v; break }
            }
            if result == .unknown { result = tables.value(module: "builtins", name: name) }
        } else {
            var values: [InferredType] = []
            for s in statements.suffix(Self.maxUnionSites) {
                values.append(contentsOf: bindingValues(of: name, in: s))
            }
            result = values.isEmpty ? .unknown : .union(values)
        }
        moduleMemo[memoKey] = result
        return result
    }

    /// The values `name` is bound to by top-level statement `s`.
    private func bindingValues(of name: String, in s: PyNode) -> [InferredType] {
        var out: [InferredType] = []
        var moduleFrame = PyFrame()
        moduleFrame.modulePosition = s.start
        func visit(_ n: PyNode) {
            guard out.count < Self.maxUnionSites, budget.tick() else { return }
            switch n.kind {
            case .funcDef:
                if let nameNode = n.firstChild(.name), string(nameNode) == name {
                    let fn = registerFunction(n, in: moduleFrame, qualname: name)
                    out.append(functionValue(fn))
                }
            case .classDef:
                if let nameNode = n.firstChild(.name), string(nameNode) == name {
                    _ = registerClass(n, in: moduleFrame, qualname: name)
                    out.append(.classObject(.document(name), []))
                }
            case .assign, .annAssign, .importStmt, .importFrom, .forStmt, .withStmt, .exprStmt, .typeAliasStmt:
                var tmp = moduleFrame
                if n.kind == .forStmt {
                    bindFor(n, &tmp)
                    if let t = tmp.env[name] { out.append(t.get()) }
                    if let block = n.firstChild(.block) { block.children.forEach(visit) }
                    return
                }
                if n.kind == .withStmt {
                    for p in n.parts where p.kind == .withItem { bindWithItem(p, async: n.has(SyntaxFlags.async), &tmp) }
                    if let t = tmp.env[name] { out.append(t.get()) }
                    if let block = n.firstChild(.block) { block.children.forEach(visit) }
                    return
                }
                _ = exec(n, &tmp, sink: nil)
                if let t = tmp.env[name] { out.append(t.get()) }
            case .ifStmt, .whileStmt, .tryStmt, .block, .elifClause, .elseClause, .exceptClause, .finallyClause,
                 .matchStmt, .caseClause:
                for c in n.parts where c.kind == .block || c.kind == .elifClause || c.kind == .elseClause
                    || c.kind == .exceptClause || c.kind == .finallyClause || c.kind == .caseClause {
                    if c.kind == .block { c.children.forEach(visit) } else { visit(c) }
                }
                if n.kind == .block { n.children.forEach(visit) }
            default:
                break
            }
        }
        visit(s)
        return out
    }

    // MARK: - Dependencies (return-type cache validation)

    private func recordDependency(on name: String) {
        guard !depStack.isEmpty else { return }
        let hash = moduleNameHash(name)
        for k in depStack.indices { depStack[k][name] = hash }
    }

    /// Hash of the texts of `name`'s top-level binding statements (0: none).
    func moduleNameHash(_ name: String) -> UInt64 {
        if let h = nameHashes[name] { return h }
        var h: UInt64 = 0
        for s in module.bindingStatements(of: name) { h = (h &* 31) &+ module.textHash(s) }
        nameHashes[name] = h
        return h
    }

    // MARK: - Definitions

    @discardableResult
    func registerFunction(_ node: PyNode, in frame: PyFrame, qualname: String? = nil) -> DocFunction {
        let name = node.firstChild(.name).map(string) ?? "<lambda>"
        let q = qualname ?? frame.qualPrefix + name
        if let existing = functions[q], existing.node == node { return existing }
        // Definitions see every module binding (annotations may name later
        // classes; bodies run after the module was executed).
        var defining = frame
        defining.modulePosition = nil
        let fn = DocFunction(node: node, qualname: q, evaluator: self, defining: defining)
        functions[q] = fn
        return fn
    }

    @discardableResult
    func registerClass(_ node: PyNode, in frame: PyFrame, qualname: String? = nil) -> DocClass {
        let name = node.firstChild(.name).map(string) ?? "<class>"
        let q = qualname ?? frame.qualPrefix + name
        if let existing = classes[q], existing.node == node { return existing }
        var defining = frame
        defining.modulePosition = nil
        let cls = DocClass(node: node, qualname: q, evaluator: self, defining: defining)
        classes[q] = cls
        return cls
    }

    /// The document class of a qualified name (resolved from the module
    /// when not seen yet in this session).
    func docClass(_ qualname: String) -> DocClass? {
        if let hit = classes[qualname] { return hit }
        guard !qualname.contains("<locals>") else { return nil }
        var parts = qualname.split(separator: ".").map(String.init)
        guard !parts.isEmpty else { return nil }
        let head = parts.removeFirst()
        guard case .classObject(let ref, _) = moduleLookup(head, before: nil), ref.origin == .document,
              var cls = classes[ref.name] else { return nil }
        for part in parts {
            guard let member = cls.members[part], member.kind == .nestedClass, let inner = classes[cls.qualname + "." + part]
            else { return nil }
            cls = inner
        }
        return cls
    }

    func docFunction(_ qualname: String) -> DocFunction? {
        if let hit = functions[qualname] { return hit }
        guard !qualname.contains("<locals>") else { return nil }
        let parts = qualname.split(separator: ".").map(String.init)
        if parts.count == 1 {
            _ = moduleLookup(parts[0], before: nil)
            return functions[qualname]
        }
        guard let owner = docClass(parts.dropLast().joined(separator: ".")) else { return nil }
        owner.buildMembers()
        return functions[qualname]
    }

    /// The value a `def` binds (decorators considered at call time).
    func functionValue(_ fn: DocFunction) -> InferredType {
        .callable(CallableRef(.documentFunction(fn.qualname)))
    }

    // MARK: - Function frames and returns

    /// The frame at the start of `fn`'s body: parameters bound.
    func functionFrame(_ fn: DocFunction) -> PyFrame {
        var f = PyFrame()
        let defining = fn.defining
        f.outer = defining.function != nil ? [defining.env] + defining.outer : defining.outer
        f.function = fn
        f.qualPrefix = fn.qualname + ".<locals>."
        f.typeParams = defining.typeParams + (fn.owner?.typeParamNames ?? []) + fn.typeParamNames
        for (k, p) in fn.parameters.enumerated() {
            let value: Thunk
            if k == 0, let owner = fn.owner, fn.decoration != .staticMethod, p.kind == 0 {
                let args = owner.typeParamNames.map { InferredType.typeVar($0, bound: nil) }
                value = Thunk(fn.decoration == .classMethod ? .classObject(.document(owner.qualname), args)
                                                            : .instance(.document(owner.qualname), args))
            } else {
                let annotation = p.annotation
                let defaultNode = p.defaultValue
                let typeParams = f.typeParams
                let kind = p.kind
                value = Thunk(lazy: { [unowned self] in
                    var t: InferredType = .unknown
                    var scope = defining
                    scope.typeParams = typeParams
                    if let annotation { t = self.annotationType(annotation, scope) } else if let defaultNode {
                        let d = self.eval(defaultNode, defining).widened
                        t = d == .none ? .unknown : d
                    }
                    switch kind {
                    case 1: return .instance(.table("builtins", "tuple"), [t])
                    case 2: return .instance(.table("builtins", "dict"), [.instance(.table("builtins", "str"), []), t])
                    default: return t
                    }
                })
            }
            f.env[p.name] = value
        }
        return f
    }

    /// The return type of a call of `fn` (unsolved type variables kept),
    /// for `receiver` (methods), before decorators.
    func declaredOrInferredReturn(_ fn: DocFunction) -> InferredType {
        if let annotation = fn.returnAnnotation {
            var scope = fn.defining
            scope.typeParams = fn.defining.typeParams + (fn.owner?.typeParamNames ?? []) + fn.typeParamNames
            var t = annotationType(annotation, scope)
            if fn.isAsync { t = .instance(.table("typing", "Coroutine"), [.unknown, .unknown, t]) }
            return t
        }
        var t = inferredReturn(fn)
        if fn.isGenerator {
            t = .instance(.table("typing", "Generator"), [.unknown, .unknown, .unknown])
        } else if fn.isAsync {
            t = .instance(.table("typing", "Coroutine"), [.unknown, .unknown, t])
        }
        return t
    }

    /// The union of `fn`'s `return`s (and `None` when its end is reachable).
    private func inferredReturn(_ fn: DocFunction) -> InferredType {
        let key = fn.qualname
        if let hit = returnMemo[key] { return hit }
        if inProgress.contains(key) || callDepth >= Self.maxCallDepth { return .unknown }
        let cacheable = !key.contains("<locals>")
        var cacheKey = ""
        if cacheable {
            cacheKey = key + "#" + String(module.textHash(fn.node))
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
        var frame = functionFrame(fn)
        let sink = ReturnSink()
        var falls = true
        if let block = fn.block { falls = walkAll(block, &frame, sink: sink) }
        var parts: [InferredType] = sink.values.map { item in
            guard let node = item.node else { return .none }
            return self.eval(node, item.frame).widened
        }
        if falls || parts.isEmpty { parts.append(.none) }
        let result = InferredType.union(parts)
        let deps = depStack.removeLast()
        callDepth -= 1
        inProgress.remove(key)
        for (name, hash) in deps { for k in depStack.indices { depStack[k][name] = hash } }
        if !isAborted {
            returnMemo[key] = result
            if cacheable, !result.mentionsLocalClass {
                let entry = CachedReturn(type: result, dependencies: deps)
                returnCache.insert(entry, for: cacheKey, cost: entry.approximateBytes + cacheKey.utf8.count)
            }
        }
        return result
    }

    // MARK: - Annotations

    /// The type an annotation expression denotes in `frame`'s scope
    /// (string annotations parsed; names resolved as values).
    func annotationType(_ n: PyNode, _ frame: PyFrame) -> InferredType {
        var source = string(n)
        if n.kind == .string, n.children.isEmpty, let inner = PythonTypeConverter.unquoted(source.trimmingCharacters(in: .whitespaces)) {
            source = inner
        }
        guard let expr = TypeExpr.parse(source, syntax: .python) else { return .unknown }
        var converter = PythonTypeConverter(resolve: { [unowned self] name in self.dottedValue(name, frame) })
        return converter.type(expr)
    }

    /// The value of a dotted name in `frame` (annotation resolution).
    private func dottedValue(_ name: String, _ frame: PyFrame) -> InferredType {
        let parts = name.split(separator: ".").map(String.init)
        guard let first = parts.first else { return .unknown }
        var t = lookup(first, frame)
        for part in parts.dropFirst() {
            switch t {
            case .module(let m): t = tables.value(module: m, name: part)
            case .classObject: t = memberType(t, part)
            default: return .unknown
            }
        }
        return t
    }
}

/// A cached inferred return type and the module-level names it depended on
/// (name → hash of their binding statements' text when computed).
struct CachedReturn {
    let type: InferredType
    let dependencies: [String: UInt64]
    var approximateBytes: Int { 64 + type.approximateBytes + dependencies.reduce(0) { $0 + 24 + $1.key.utf8.count } }
}
