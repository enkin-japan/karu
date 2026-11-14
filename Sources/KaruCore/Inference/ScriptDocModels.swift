import Foundation

// M17 T17.11c — functions, classes, interfaces, enums and type aliases
// declared in a JS / TS document, as `ScriptEvaluator` sees them. Built
// lazily per evaluation session from the syntax tree (like
// `PythonDocModels`); nothing here outlives a document version.

/// The environment of one scope during the flow walk (JS / TS).
struct SFrame {
    var env: [String: Thunk] = [:]
    var outer: [[String: Thunk]] = []
    /// Type declarations of the enclosing function scopes (local
    /// interfaces, aliases, classes, enums), innermost wins.
    var types: [String: STypeDecl] = [:]
    /// The function whose body this frame walks.
    var function: SDocFunction?
    /// `this` (nil: unknown — a plain `function`, module level).
    var this: Thunk?
    /// The class whose body encloses this frame (private members visible).
    var classContext: String?
    /// At module level: lookups see module bindings before this offset.
    var modulePosition: Int?
    /// Qualified-name prefix of definitions made here (`f.<locals>.`).
    var qualPrefix = ""
    /// Type parameters in scope → constraint.
    var typeParams: [String: InferredType?] = [:]
}

/// A type declaration bound in a scope.
enum STypeDecl {
    case decl(SDocClass)
    case alias(SAlias)
}

/// `type Name<T> = …` of the document.
@MainActor
final class SAlias {
    let node: PyNode
    let name: String
    let defining: SFrame
    let typeParams: [(String, PyNode?)]
    let body: PyNode?

    init(node: PyNode, name: String, defining: SFrame, typeParams: [(String, PyNode?)], body: PyNode?) {
        self.node = node
        self.name = name
        self.defining = defining
        self.typeParams = typeParams
        self.body = body
    }
}

/// A function, method, accessor, arrow or function expression of the document.
@MainActor
final class SDocFunction {
    enum Role: Equatable { case function, method, getter, setter, constructor }

    struct Param {
        /// The binding (`name`, `objectPattern`, `arrayPattern`); nil for TS `this:`.
        let binding: PyNode?
        let name: String
        let typeNode: PyNode?
        let defaultNode: PyNode?
        let isRest: Bool
        let isOptional: Bool
        /// A TS parameter property (`constructor(private x: T)`).
        let isProperty: Bool
        /// The `param` node's start (modifiers precede the binding).
        let start: Int
    }

    let node: PyNode
    let qualname: String
    let defining: SFrame
    let owner: SDocClass?
    let role: Role
    let isStatic: Bool
    let isArrow: Bool
    let nameNode: PyNode?
    let params: [Param]
    let thisTypeNode: PyNode?
    let returnTypeNode: PyNode?
    /// A block, or an arrow's expression body.
    let body: PyNode?
    let typeParamNodes: [PyNode]
    let isAsync: Bool
    let isGenerator: Bool
    /// The JSDoc comment before the definition (JavaScript only).
    var jsdoc: JSDocComment?

    init(node: PyNode, qualname: String, defining: SFrame, owner: SDocClass?, isStatic: Bool,
         evaluator: ScriptEvaluator) {
        self.node = node
        self.qualname = qualname
        self.defining = defining
        self.owner = owner
        self.isStatic = isStatic
        isArrow = node.kind == .arrow
        isAsync = node.has(SyntaxFlags.async)
        isGenerator = node.has(SyntaxFlags.generator)
        var role = Role.function
        if node.kind == .method {
            switch node.raw.aux {
            case 1: role = .getter
            case 2: role = .setter
            case 3: role = .constructor
            default: role = .method
            }
        }
        self.role = role
        var nameNode: PyNode?
        var params: [Param] = []
        var thisType: PyNode?
        var returnType: PyNode?
        var body: PyNode?
        var typeParams: [PyNode] = []
        var afterParams: [PyNode] = []
        var seenParams = false
        for c in node.parts {
            if seenParams { afterParams.append(c); continue }
            switch c.kind {
            case .decorator: continue
            case .typeParams: typeParams = c.parts.filter { $0.kind == .typeParam }
            case .params:
                seenParams = true
                for p in c.parts where p.kind == .param {
                    let aux = Int(p.raw.aux)
                    let ps = p.parts.filter { $0.kind != .decorator }
                    guard let binding = ps.first else { continue }
                    var k = 1
                    var typeNode: PyNode?
                    var defaultNode: PyNode?
                    if aux & 4 != 0, k < ps.count { typeNode = ps[k]; k += 1 }
                    if aux & 8 != 0, k < ps.count { defaultNode = ps[k] }
                    if binding.kind == .keywordLit {
                        thisType = typeNode
                        continue
                    }
                    params.append(Param(binding: binding, name: evaluator.string(binding), typeNode: typeNode,
                                        defaultNode: defaultNode, isRest: aux & 1 != 0,
                                        isOptional: p.has(SyntaxFlags.optional) || defaultNode != nil,
                                        isProperty: aux & 2 != 0, start: p.start))
                }
            default:
                // The name (function) or key (method) before the parameters.
                if nameNode == nil, c.kind == .name || c.kind == .string || c.kind == .privateName || c.kind == .number {
                    nameNode = c
                }
            }
        }
        if isArrow {
            body = afterParams.last
            if afterParams.count >= 2 { returnType = afterParams[0] }
        } else {
            for c in afterParams {
                if c.kind == .block { body = c } else if returnType == nil { returnType = c }
            }
        }
        self.nameNode = nameNode
        self.params = params
        self.thisTypeNode = thisType
        self.returnTypeNode = returnType
        self.body = body
        self.typeParamNodes = typeParams
    }

    /// Type parameter names (`<T, U extends X>`) with their constraint nodes.
    func typeParameters(_ evaluator: ScriptEvaluator) -> [(String, PyNode?)] {
        typeParamNodes.compactMap { tp in
            let ps = tp.parts
            guard let name = ps.first, name.kind == .name else { return nil }
            let constraint = ps.count >= 2 && evaluator.gapHas("extends", from: name.end, to: ps[1].start) ? ps[1] : nil
            return (evaluator.string(name), constraint)
        }
    }
}

/// A member of a document class, interface or enum.
struct SMember {
    let name: String
    var kind: InferredMemberKind
    var isStatic = false
    var isOptional = false
    /// `private` / `protected` / `#name`: listed only inside the class.
    var isPrivate = false
    /// Methods, accessors (the getter), arrow-valued fields' functions.
    var function: SDocFunction?
    /// Declared type (property / signature annotation, parameter property).
    var typeNode: PyNode?
    /// Initializer (class property, enum member).
    var valueNode: PyNode?
    /// Interface `methodSig` / `callSig` node.
    var signatureNode: PyNode?
    /// `this.name = …` assignments (the `assignExpr` nodes) in methods,
    /// the constructor's first.
    var sites: [PyNode] = []
    /// How many of `sites` are in the constructor (as in TypeScript's JS
    /// inference, they alone type the property when there are any).
    var constructorSites = 0
    /// JSDoc `@type` text (JavaScript).
    var jsdocType: String?
    var order: Int
}

/// A `class`, `interface` (merged declarations) or `enum` of the document.
@MainActor
final class SDocClass {
    enum Kind: Equatable { case `class`, interface, `enum` }

    let kind: Kind
    /// Declarations (several for a merged interface).
    let nodes: [PyNode]
    let qualname: String
    let name: String
    let defining: SFrame
    private unowned let evaluator: ScriptEvaluator

    private var baseValue: BaseInfo?
    private var built = false
    private(set) var members: [String: SMember] = [:]
    private(set) var order: [String] = []
    private(set) var indexValueNode: PyNode?
    private var listed: [String: [InferredMember]] = [:]

    struct BaseInfo {
        var bases: [InferredType] = []
        /// A base that could not be resolved (members past it are unknown).
        var unknownBase = false
    }

    init(kind: Kind, nodes: [PyNode], qualname: String, defining: SFrame, evaluator: ScriptEvaluator) {
        self.kind = kind
        self.nodes = nodes
        self.qualname = qualname
        self.evaluator = evaluator
        self.defining = defining
        let first = nodes.first
        name = first.flatMap { n in n.parts.first { $0.kind == .name }.map(evaluator.string) } ?? "<class>"
    }

    var ref: ClassRef { .document(qualname) }

    func tearDown() {
        members.removeAll()
        order.removeAll()
        listed.removeAll()
        baseValue = nil
        built = true
    }

    /// Type parameter names and constraint nodes (first declaration).
    var typeParameters: [(String, PyNode?)] {
        guard let tps = nodes.first?.firstChild(.typeParams) else { return [] }
        return tps.parts.filter { $0.kind == .typeParam }.compactMap { tp in
            let ps = tp.parts
            guard let n = ps.first, n.kind == .name else { return nil }
            let constraint = ps.count >= 2 && evaluator.gapHas("extends", from: n.end, to: ps[1].start) ? ps[1] : nil
            return (evaluator.string(n), constraint)
        }
    }

    var typeParamNames: [String] { typeParameters.map(\.0) }

    /// The frame inside the class: type parameters, class context.
    var bodyFrame: SFrame {
        var f = defining
        f.outer = [defining.env] + defining.outer
        f.env = [:]
        f.qualPrefix = qualname + "."
        f.classContext = qualname
        for (n, c) in typeParameters { f.typeParams[n] = .some(c.map { evaluator.typeOf($0, defining) }) }
        return f
    }

    // MARK: Bases

    var baseInfo: BaseInfo {
        if let b = baseValue { return b }
        baseValue = BaseInfo()     // recursion guard
        var info = BaseInfo()
        let scope = bodyFrame
        for node in nodes {
            for h in node.parts where h.kind == .heritage {
                // Classes implement interfaces without inheriting members.
                if h.raw.aux == 1, kind == .class { continue }
                let ps = h.parts
                var k = 0
                while k < ps.count {
                    let b = ps[k]
                    k += 1
                    if b.kind == .typeArgs { continue }
                    var typeArgs: PyNode?
                    if k < ps.count, ps[k].kind == .typeArgs { typeArgs = ps[k]; k += 1 }
                    // A class extends an expression (`Base<T>` / `mixin(Base)`);
                    // an interface extends types.
                    let t = kind == .class ? evaluator.classBase(b, typeArgs: typeArgs, scope) : evaluator.typeOf(b, scope)
                    switch t {
                    case .instance, .shape: info.bases.append(t)
                    default: info.unknownBase = true
                    }
                }
            }
        }
        baseValue = info
        return info
    }

    // MARK: Members

    func buildMembers() {
        guard !built else { return }
        built = true
        var methods: [SDocFunction] = []
        func add(_ name: String, _ make: () -> SMember, update: (inout SMember) -> Void) {
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
        let frame = bodyFrame
        for node in nodes {
            switch kind {
            case .class:
                guard let body = node.firstChild(.classBody) else { continue }
                for m in body.parts {
                    switch m.kind {
                    case .method:
                        guard let key = m.parts.first(where: { $0.kind != .decorator }), let name = evaluator.keyName(key) else { continue }
                        let isStatic = m.has(SyntaxFlags.isStatic)
                        let fn = evaluator.registerFunction(m, in: frame, owner: self, isStatic: isStatic,
                                                            qualname: qualname + (isStatic ? ".<static>." : ".") + name)
                        methods.append(fn)
                        if fn.role == .constructor {
                            for p in fn.params where p.isProperty {
                                guard let b = p.binding, b.kind == .name else { continue }
                                let pn = evaluator.string(b)
                                add(pn, { SMember(name: pn, kind: .field, order: order.count) }) {
                                    $0.typeNode = $0.typeNode ?? p.typeNode
                                    $0.isPrivate = evaluator.gapHas("private", from: p.start, to: b.start)
                                        || evaluator.gapHas("protected", from: p.start, to: b.start)
                                }
                            }
                            continue
                        }
                        if fn.role == .setter, members[name] != nil { continue }
                        let kind: InferredMemberKind = fn.role == .getter || fn.role == .setter ? .property
                            : (isStatic ? .staticMethod : .method)
                        add(name, { SMember(name: name, kind: kind, order: order.count) }) {
                            if $0.function == nil || fn.role == .getter { $0.function = fn }
                            $0.kind = kind
                            $0.isStatic = isStatic
                            $0.isPrivate = evaluator.isPrivateMember(m, key: key)
                        }
                    case .property:
                        let ps = m.parts.filter { $0.kind != .decorator }
                        guard let key = ps.first, let name = evaluator.keyName(key) else { continue }
                        let aux = Int(m.raw.aux)
                        var k = 1
                        var typeNode: PyNode?
                        var valueNode: PyNode?
                        if aux & 1 != 0, k < ps.count { typeNode = ps[k]; k += 1 }
                        if aux & 2 != 0, k < ps.count { valueNode = ps[k] }
                        let isStatic = m.has(SyntaxFlags.isStatic)
                        var fn: SDocFunction?
                        if let v = valueNode, v.kind == .arrow || v.kind == .funcExpr {
                            // An arrow field sees the instance (or the class) as `this`.
                            var fieldFrame = frame
                            let args = typeParamNames.map { InferredType.typeVar($0, bound: nil) }
                            fieldFrame.this = Thunk(isStatic ? .classObject(ref, []) : .instance(ref, args))
                            fn = evaluator.registerFunction(v, in: fieldFrame, owner: v.kind == .arrow ? nil : self, isStatic: isStatic,
                                                            qualname: qualname + (isStatic ? ".<static>." : ".") + name)
                        }
                        let jsdoc = evaluator.jsdoc(before: m)?.type
                        add(name, { SMember(name: name, kind: fn != nil && typeNode == nil ? .method : .field, order: order.count) }) {
                            $0.typeNode = typeNode
                            $0.valueNode = valueNode
                            $0.function = fn
                            $0.isStatic = isStatic
                            $0.isOptional = m.has(SyntaxFlags.optional)
                            $0.isPrivate = evaluator.isPrivateMember(m, key: key)
                            $0.jsdocType = jsdoc
                        }
                    case .indexSig:
                        indexValueNode = m.parts.last { $0.kind != .params }
                    default:
                        continue
                    }
                }
            case .interface:
                guard let body = node.parts.last(where: { $0.kind == .objectType }) else { continue }
                for m in body.parts {
                    switch m.kind {
                    case .propSig:
                        let ps = m.parts
                        guard let key = ps.first, let name = evaluator.keyName(key) else { continue }
                        add(name, { SMember(name: name, kind: .field, order: order.count) }) {
                            $0.typeNode = ps.count >= 2 ? ps[1] : nil
                            $0.isOptional = m.has(SyntaxFlags.optional)
                        }
                    case .methodSig:
                        guard let key = m.parts.first, let name = evaluator.keyName(key) else { continue }
                        add(name, { SMember(name: name, kind: .method, order: order.count) }) {
                            if $0.signatureNode == nil { $0.signatureNode = m }
                            $0.isOptional = m.has(SyntaxFlags.optional)
                        }
                    case .indexSig:
                        indexValueNode = m.parts.last { $0.kind != .params }
                    default:
                        continue
                    }
                }
            case .enum:
                for m in node.parts where m.kind == .enumMember {
                    guard let key = m.parts.first, let name = evaluator.keyName(key) else { continue }
                    add(name, { SMember(name: name, kind: .field, order: order.count) }) {
                        $0.isStatic = true
                        $0.valueNode = m.parts.count >= 2 ? m.parts[1] : nil
                    }
                }
            }
        }
        // `this.x = …` in methods (constructor first): instance fields.
        let sorted = methods.filter { $0.role == .constructor } + methods.filter { $0.role != .constructor }
        for fn in sorted where !fn.isStatic {
            guard let body = fn.body, body.kind == .block else { continue }
            body.walk { n in
                switch n.kind {
                case .funcDecl, .funcExpr, .classDecl, .classExpr, .method: return false
                case .assignExpr:
                    guard n.raw.aux == UInt16(SyntaxParsing.Op.assign.rawValue),
                          let target = n.parts.first, target.kind == .member else { return true }
                    let tps = target.parts
                    guard tps.count == 2, tps[0].kind == .keywordLit, evaluator.string(tps[0]) == "this",
                          tps[1].kind == .name || tps[1].kind == .privateName else { return true }
                    let attr = evaluator.string(tps[1])
                    let inConstructor = fn.role == .constructor
                    add(attr, { SMember(name: attr, kind: .field, order: order.count) }) {
                        if $0.sites.count < 8, $0.function == nil {
                            $0.sites.append(n)
                            if inConstructor { $0.constructorSites += 1 }
                        }
                        if attr.hasPrefix("#") { $0.isPrivate = true }
                    }
                    return true
                default:
                    return true
                }
            }
        }
    }

    /// The members listed for completion (own only, rank 0): the instance
    /// view (non-static) or the class-object view (static); private members
    /// only when `insideClass`.
    func listedMembers(instance: Bool, insideClass: Bool) -> [InferredMember] {
        let key = "\(instance)\(insideClass)"
        if let hit = listed[key] { return hit }
        buildMembers()
        var out: [InferredMember] = []
        for name in order {
            guard let m = members[name], name != "constructor" else { continue }
            if kind != .enum, m.isStatic == instance { continue }
            if m.isPrivate, !insideClass { continue }
            out.append(InferredMember(name: name, kind: m.kind, rank: 0, detail: evaluator.detail(of: m, in: self)))
        }
        listed[key] = out
        return out
    }
}
