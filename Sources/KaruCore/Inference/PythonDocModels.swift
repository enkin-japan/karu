import Foundation

// M17 T17.11b — functions and classes declared in the document, as the
// Python evaluator sees them. Built lazily per evaluation session from the
// syntax tree; nothing here outlives a document version (cached return
// types are keyed by text and validated, see `PythonEvaluator`).

/// A `def` of the document.
@MainActor
final class DocFunction {
    enum Decoration: Equatable {
        /// No decorator, or only decorators that keep the call's result
        /// (`abstractmethod`, `overload`, `override`, `final`, `cache`,
        /// `lru_cache`, `wraps(...)`, `deprecated`).
        case none
        case staticMethod, classMethod, property
        /// `contextlib.contextmanager` / `asynccontextmanager`.
        case contextManager, asyncContextManager
        /// A decorator the evaluator does not know: the result is unknown.
        case unknown
    }

    struct Param {
        let name: String
        /// Parser `param` aux: 0 plain, 1 `*x`, 2 `**x`.
        let kind: Int
        let annotation: PyNode?
        let defaultValue: PyNode?
        /// Before a `/` marker.
        let positionalOnly: Bool
        /// After `*` / `*args`.
        let keywordOnly: Bool
    }

    let node: PyNode
    let qualname: String
    let defining: PyFrame
    let owner: DocClass?
    let nameNode: PyNode?
    let parameters: [Param]
    let returnAnnotation: PyNode?
    let block: PyNode?
    let decorators: [PyNode]
    let typeParamNames: [String]
    let isAsync: Bool
    private unowned let evaluator: PythonEvaluator
    private var decorationValue: Decoration?
    private var generatorValue: Bool?

    init(node: PyNode, qualname: String, evaluator: PythonEvaluator, defining: PyFrame) {
        self.node = node
        self.qualname = qualname
        self.evaluator = evaluator
        self.defining = defining
        owner = defining.classBody
        isAsync = node.has(SyntaxFlags.async)
        var decorators: [PyNode] = []
        var nameNode: PyNode?
        var params: [Param] = []
        var returns: PyNode?
        var block: PyNode?
        var typeParams: [String] = []
        var seenParams = false
        for c in node.parts {
            switch c.kind {
            case .decorator: decorators.append(c)
            case .name where nameNode == nil && !seenParams: nameNode = c
            case .typeParams:
                typeParams = c.parts.compactMap { tp in tp.parts.first.map { evaluator.string($0) } }
            case .params:
                seenParams = true
                let raw = c.parts.filter { $0.kind == .param }
                let slash = raw.lastIndex { $0.raw.aux == 4 }
                var keywordOnly = false
                for (k, p) in raw.enumerated() {
                    let aux = Int(p.raw.aux)
                    if aux == 3 || aux == 1 {
                        keywordOnly = true
                        if aux == 3 { continue }
                    }
                    if aux == 4 { continue }
                    let ps = p.parts
                    guard let name = ps.first, name.kind == .name else { continue }
                    var annotation: PyNode?
                    var defaultValue: PyNode?
                    var prevEnd = name.end
                    for extra in ps.dropFirst() {
                        if evaluator.gapHas(":", from: prevEnd, to: extra.start) || evaluator.gapContains(":", from: prevEnd, to: extra.start) {
                            annotation = extra
                        } else {
                            defaultValue = extra
                        }
                        prevEnd = extra.end
                    }
                    params.append(Param(name: evaluator.string(name), kind: aux == 1 || aux == 2 ? aux : 0,
                                        annotation: annotation, defaultValue: defaultValue,
                                        positionalOnly: slash.map { k < $0 } ?? false,
                                        keywordOnly: keywordOnly && aux != 1 && aux != 2))
                }
            case .block: block = c
            default:
                if seenParams, block == nil, returns == nil { returns = c }
            }
        }
        self.decorators = decorators
        self.nameNode = nameNode
        self.parameters = params
        self.returnAnnotation = returns
        self.block = block
        self.typeParamNames = typeParams
    }

    /// The decorators' effect (resolved through the tables).
    var decoration: Decoration {
        if let d = decorationValue { return d }
        var result = Decoration.none
        for d in decorators {
            guard let expr = d.parts.first else { continue }
            let kind = evaluator.classifyDecorator(expr, defining)
            switch kind {
            case .none: continue
            case .unknown: result = .unknown
            default: if result != .unknown { result = kind }
            }
        }
        decorationValue = result
        return result
    }

    /// Holds `yield` outside nested scopes.
    var isGenerator: Bool {
        if let g = generatorValue { return g }
        var found = false
        block?.walk { n in
            if found { return false }
            switch n.kind {
            case .yield: found = true; return false
            case .funcDef, .classDef, .lambda: return false
            default: return true
            }
        }
        generatorValue = found
        return found
    }

    /// Shapes for argument mapping (`self` / `cls` dropped when bound).
    func shapes(dropFirst: Bool) -> [ParamShape] {
        var ps = parameters
        if dropFirst, !ps.isEmpty, ps[0].kind == 0 { ps.removeFirst() }
        return ps.map { p in
            let kind: InferredParameter.Kind
            switch p.kind {
            case 1: kind = .variadic
            case 2: kind = .keywordVariadic
            default: kind = p.positionalOnly ? .positionalOnly : (p.keywordOnly ? .keywordOnly : .positional)
            }
            return ParamShape(name: p.name, kind: kind, hasDefault: p.defaultValue != nil)
        }
    }
}

/// A parameter for argument mapping (tables and document alike).
struct ParamShape {
    let name: String
    let kind: InferredParameter.Kind
    let hasDefault: Bool
}

/// A member of a document class.
struct DocMember {
    let name: String
    var kind: InferredMemberKind
    var function: DocFunction?
    /// Class-level annotation, or `self.x: T`.
    var annotation: PyNode?
    /// Statements assigning it (class body or methods).
    var sites: [FieldSite] = []
    /// Assigned only through `self.x` in methods.
    var instanceOnly = false
    var order: Int
}

struct FieldSite {
    let statement: PyNode
    /// The method (`self.x = …`), nil in the class body.
    let method: DocFunction?
    /// The env key the statement binds (`x` or `self.x`).
    let key: String
}

/// A `class` of the document.
@MainActor
final class DocClass {
    let node: PyNode
    let qualname: String
    let name: String
    let defining: PyFrame
    let block: PyNode?
    let baseNodes: [PyNode]
    let decorators: [PyNode]
    let pep695Params: [String]
    private unowned let evaluator: PythonEvaluator

    private var basesValue: BaseInfo?
    private var built = false
    private(set) var members: [String: DocMember] = [:]
    private(set) var order: [String] = []
    private var listed: [Bool: [InferredMember]] = [:]

    struct BaseInfo {
        var bases: [InferredType] = []
        var typeParams: [String] = []
        var typedDict = false
        var namedTuple = false
        var protocolClass = false
        var unknownBase = false
    }

    init(node: PyNode, qualname: String, evaluator: PythonEvaluator, defining: PyFrame) {
        self.node = node
        self.qualname = qualname
        self.evaluator = evaluator
        self.defining = defining
        var name = "<class>"
        var bases: [PyNode] = []
        var decorators: [PyNode] = []
        var block: PyNode?
        var params: [String] = []
        for c in node.parts {
            switch c.kind {
            case .decorator: decorators.append(c)
            case .name where name == "<class>": name = evaluator.string(c)
            case .typeParams: params = c.parts.compactMap { tp in tp.parts.first.map { evaluator.string($0) } }
            case .args: bases = c.parts.filter { $0.kind != .keywordArg && $0.kind != .starred }
            case .block: block = c
            default: break
            }
        }
        self.name = name
        self.baseNodes = bases
        self.decorators = decorators
        self.block = block
        self.pep695Params = params
    }

    var ref: ClassRef { .document(qualname) }

    /// Drops the members (and with them the methods' frames that point back here).
    func tearDown() {
        members.removeAll()
        order.removeAll()
        listed.removeAll()
        basesValue = nil
        built = true
    }

    /// The class body frame (definitions inside are qualified by the class).
    var bodyFrame: PyFrame {
        var f = PyFrame()
        f.outer = defining.function != nil || defining.classBody != nil ? [defining.env] + defining.outer : defining.outer
        f.classBody = self
        f.qualPrefix = qualname + "."
        f.typeParams = defining.typeParams + pep695Params
        return f
    }

    // MARK: Bases

    var baseInfo: BaseInfo {
        if let b = basesValue { return b }
        basesValue = BaseInfo()     // recursion guard
        var info = BaseInfo()
        info.typeParams = pep695Params
        var scope = defining
        scope.typeParams = defining.typeParams + pep695Params
        for b in baseNodes {
            // `Generic[T]` / `Protocol[T]`: type parameters.
            if b.kind == .subscript, let object = b.parts.first,
               case .special(let s) = evaluator.eval(object, scope), s == "Generic" || s == "Protocol" {
                if s == "Protocol" { info.protocolClass = true }
                if b.parts.count >= 2 {
                    let index = b.parts[1]
                    let items = index.kind == .tuple ? index.parts : [index]
                    for item in items {
                        if case .typeForm(.typeVar(let n, _)) = evaluator.eval(item, scope), !info.typeParams.contains(n) {
                            info.typeParams.append(n)
                        }
                    }
                }
                continue
            }
            let value = evaluator.eval(b, scope)
            switch value {
            case .classObject(let ref, let args):
                if ref == .table("typing", "NamedTuple") { info.namedTuple = true }
                info.bases.append(.instance(ref, args))
                for n in PythonTypeConverter.typeVarNames(.instance(ref, args)) where !info.typeParams.contains(n) {
                    info.typeParams.append(n)
                }
            case .special(let s):
                switch s {
                case "TypedDict":
                    info.typedDict = true
                    info.bases.append(.instance(.table("typing", "_TypedDict"), []))
                case "Protocol": info.protocolClass = true
                case "Generic": break
                default: info.unknownBase = true
                }
            case .typeForm(let t):
                if case .instance = t { info.bases.append(t) } else { info.unknownBase = true }
            default:
                info.unknownBase = true
            }
        }
        // A subclass of a TypedDict is a TypedDict.
        if !info.typedDict {
            for b in info.bases {
                if case .instance(let r, _) = b, r.origin == .document, evaluator.docClass(r.name)?.baseInfo.typedDict == true {
                    info.typedDict = true
                }
            }
        }
        basesValue = info
        return info
    }

    var bases: [InferredType] { baseInfo.bases }
    var typeParamNames: [String] { baseInfo.typeParams }
    var isTypedDict: Bool { baseInfo.typedDict }

    var isEnum: Bool {
        evaluator.mro(ref, []).contains { $0.0 == .table("enum", "Enum") }
    }

    // MARK: Members

    func buildMembers() {
        guard !built else { return }
        built = true
        guard let block else { return }
        let frame = bodyFrame
        var methods: [DocFunction] = []
        func add(_ name: String, _ make: () -> DocMember, update: (inout DocMember) -> Void) {
            if var existing = members[name] {
                update(&existing)
                members[name] = existing
            } else {
                var m = make()
                update(&m)
                members[name] = m
                order.append(name)
            }
        }
        func visitBody(_ stmts: [PyNode]) {
            for s in stmts {
                switch s.kind {
                case .funcDef:
                    let fn = evaluator.registerFunction(s, in: frame)
                    guard let nameNode = fn.nameNode else { continue }
                    let name = evaluator.string(nameNode)
                    methods.append(fn)
                    guard members[name] == nil else { continue }
                    let kind: InferredMemberKind
                    switch fn.decoration {
                    case .property: kind = .property
                    case .staticMethod: kind = .staticMethod
                    case .classMethod: kind = .classMethod
                    default: kind = .method
                    }
                    add(name, { DocMember(name: name, kind: kind, function: fn, order: order.count) }, update: { _ in })
                case .classDef:
                    let inner = evaluator.registerClass(s, in: frame)
                    add(inner.name, { DocMember(name: inner.name, kind: .nestedClass, order: order.count) }, update: { _ in })
                case .assign:
                    for t in s.parts.dropLast() {
                        for n in targetNames(t) {
                            add(n, { DocMember(name: n, kind: .field, order: order.count) }) {
                                $0.sites.append(FieldSite(statement: s, method: nil, key: n))
                                $0.instanceOnly = false
                            }
                        }
                    }
                case .annAssign:
                    let ps = s.parts
                    guard let t = ps.first, t.kind == .name, ps.count >= 2 else { continue }
                    let n = evaluator.string(t)
                    add(n, { DocMember(name: n, kind: .field, order: order.count) }) {
                        if $0.annotation == nil { $0.annotation = ps[1] }
                        $0.sites.append(FieldSite(statement: s, method: nil, key: n))
                        $0.instanceOnly = false
                    }
                case .ifStmt, .tryStmt, .elifClause, .elseClause, .exceptClause, .finallyClause, .withStmt, .forStmt, .whileStmt:
                    for c in s.parts {
                        if c.kind == .block { visitBody(c.children) } else if c.kind != .name { visitBody([c]) }
                    }
                default:
                    break
                }
            }
        }
        visitBody(block.children)
        // `self.x` / `cls.x` assignments in methods (`__init__` first).
        let initNames: Set<String> = ["__init__", "__new__", "__post_init__", "setUp", "__enter__"]
        let sorted = methods.filter { $0.nameNode.map { initNames.contains(evaluator.string($0)) } ?? false }
            + methods.filter { !($0.nameNode.map { initNames.contains(evaluator.string($0)) } ?? false) }
        for fn in sorted {
            guard fn.decoration != .staticMethod, let receiver = fn.parameters.first, receiver.kind == 0,
                  let body = fn.block else { continue }
            let isClass = fn.decoration == .classMethod
            body.walk { n in
                switch n.kind {
                case .funcDef, .classDef, .lambda: return false
                case .assign, .annAssign, .augAssign, .forStmt, .withItem:
                    let targets: [PyNode]
                    switch n.kind {
                    case .assign: targets = Array(n.parts.dropLast())
                    case .forStmt: targets = Array(n.parts.prefix(1))
                    case .withItem: targets = n.parts.count >= 2 ? [n.parts[1]] : []
                    default: targets = Array(n.parts.prefix(1))
                    }
                    for t in targets {
                        for (attr, _) in selfAttributes(t, receiver: receiver.name) {
                            let annotation = n.kind == .annAssign && n.parts.count >= 2 ? n.parts[1] : nil
                            let statement = n.kind == .withItem ? enclosingWith(n) ?? n : n
                            let key = receiver.name + "." + attr
                            add(attr, { DocMember(name: attr, kind: .field, order: order.count) }) {
                                if $0.annotation == nil, let annotation { $0.annotation = annotation }
                                if $0.sites.count < 8, n.kind != .augAssign {
                                    $0.sites.append(FieldSite(statement: statement, method: fn, key: key))
                                }
                                if $0.sites.count == 1, $0.function == nil, $0.kind == .field { $0.instanceOnly = !isClass }
                            }
                        }
                    }
                    return true
                default:
                    return true
                }
            }
        }
    }

    private func enclosingWith(_ item: PyNode) -> PyNode? {
        item.ancestors.last { $0.kind == .withStmt }
    }

    /// Names a class-body assignment target binds.
    private func targetNames(_ t: PyNode) -> [String] {
        switch t.kind {
        case .name: return [evaluator.string(t)]
        case .tuple, .list, .paren: return t.parts.flatMap { targetNames($0) }
        default: return []
        }
    }

    /// `self.attr` targets in `t` (tuples searched).
    private func selfAttributes(_ t: PyNode, receiver: String) -> [(String, PyNode)] {
        switch t.kind {
        case .member:
            let ps = t.parts
            if ps.count == 2, ps[0].kind == .name, evaluator.string(ps[0]) == receiver, ps[1].kind == .name {
                return [(evaluator.string(ps[1]), t)]
            }
            return []
        case .tuple, .list, .paren, .starred:
            return t.parts.flatMap { selfAttributes($0, receiver: receiver) }
        default:
            return []
        }
    }

    /// The type of field `m` (class type parameters unsubstituted).
    func fieldType(_ m: DocMember) -> InferredType {
        if m.kind == .field, !m.instanceOnly, m.annotation == nil, !m.name.hasPrefix("_"), isEnum {
            return .instance(ref, [])
        }
        if let annotation = m.annotation {
            var scope = bodyFrame
            scope.classBody = nil
            scope.outer = defining.function != nil ? [defining.env] + defining.outer : defining.outer
            let t = evaluator.annotationType(annotation, scope)
            if t != .unknown { return t }
        }
        var values: [InferredType] = []
        for site in m.sites.prefix(PythonEvaluator.maxUnionSites) {
            var f: PyFrame
            if site.method != nil {
                f = evaluator.frame(at: site.statement)
            } else {
                f = bodyFrame
            }
            evaluator.exec(site.statement, &f, sink: nil)
            values.append((f.env[site.key]?.get() ?? .unknown).widened)
        }
        return values.isEmpty ? .unknown : .union(values)
    }

    /// The members listed for completion (own members only; rank 0):
    /// instance view (`instance`) or class-object view.
    func listedMembers(instance: Bool) -> [InferredMember] {
        if let hit = listed[instance] { return hit }
        buildMembers()
        var out: [InferredMember] = []
        let typedDict = isTypedDict
        for name in order {
            guard let m = members[name] else { continue }
            if instance, typedDict, m.kind == .field { continue }
            if !instance, m.instanceOnly { continue }
            out.append(InferredMember(name: name, kind: m.kind, rank: 0, detail: evaluator.detail(of: m, in: self)))
        }
        listed[instance] = out
        return out
    }
}
