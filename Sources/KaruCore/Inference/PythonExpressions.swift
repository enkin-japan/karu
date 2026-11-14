import Foundation

// M17 T17.11b — expression evaluation, calls, attributes, the MRO and member
// listing of the Python evaluator (see `PythonEvaluator`).

extension PythonEvaluator {
    static let builtinsList = ClassRef.table("builtins", "list")
    static let builtinsDict = ClassRef.table("builtins", "dict")
    static let builtinsSet = ClassRef.table("builtins", "set")
    static let builtinsTuple = ClassRef.table("builtins", "tuple")
    static let builtinsStr = ClassRef.table("builtins", "str")
    static let builtinsInt = ClassRef.table("builtins", "int")
    static let builtinsFloat = ClassRef.table("builtins", "float")
    static let builtinsBool = ClassRef.table("builtins", "bool")
    static let builtinsObject = ClassRef.table("builtins", "object")
    /// Literal values longer than this are kept as plain instances.
    static let literalLimit = 64

    func gapContains(_ ch: Character, from: Int, to: Int) -> Bool {
        guard to > from else { return false }
        return text.substring(with: NSRange(location: from, length: to - from)).contains(ch)
    }

    // MARK: - Expressions

    func eval(_ n: PyNode, _ f: PyFrame) -> InferredType {
        guard budget.tick() else { return .unknown }
        switch n.kind {
        case .name:
            return lookup(string(n), f)
        case .number:
            let s = string(n).lowercased().replacingOccurrences(of: "_", with: "")
            if s.hasSuffix("j") { return .instance(.table("builtins", "complex"), []) }
            if s.hasPrefix("0x") || s.hasPrefix("0o") || s.hasPrefix("0b") { return .literal(Self.builtinsInt, s) }
            if s.contains(".") || s.contains("e") { return .instance(Self.builtinsFloat, []) }
            return .literal(Self.builtinsInt, s)
        case .string:
            let s = string(n)
            let prefix = s.prefix { $0 != "'" && $0 != "\"" }.lowercased()
            if prefix.contains("b") { return .instance(.table("builtins", "bytes"), []) }
            if prefix.contains("f") || prefix.contains("t") || !n.children.isEmpty || s.utf16.count > Self.literalLimit {
                return .instance(Self.builtinsStr, [])
            }
            return .literal(Self.builtinsStr, s)
        case .keywordLit:
            let s = string(n)
            if s == "None" { return .none }
            return .literal(Self.builtinsBool, s)
        case .paren:
            guard let inner = n.parts.first else { return .instance(Self.builtinsTuple, []) }
            return eval(inner, f)
        case .tuple:
            let items = n.parts
            if items.contains(where: { $0.kind == .starred }) { return .instance(Self.builtinsTuple, [.unknown]) }
            return .instance(Self.builtinsTuple, items.map { eval($0, f).widened })
        case .list, .set:
            let ref = n.kind == .list ? Self.builtinsList : Self.builtinsSet
            let items = n.parts
            guard !items.isEmpty else { return .instance(ref, []) }
            let elements = items.map { item -> InferredType in
                if item.kind == .starred, let inner = item.parts.first { return iterationElement(eval(inner, f)).widened }
                return eval(item, f).widened
            }
            return .instance(ref, [.union(elements)])
        case .dict:
            let items = n.parts
            guard !items.isEmpty else { return .instance(Self.builtinsDict, []) }
            var keys: [InferredType] = []
            var values: [InferredType] = []
            for item in items {
                if item.kind == .pair, item.parts.count == 2 {
                    keys.append(eval(item.parts[0], f).widened)
                    values.append(eval(item.parts[1], f).widened)
                } else if item.kind == .starred, let inner = item.parts.first {
                    if let (_, args) = upcast(eval(inner, f), to: Self.builtinsDict), args.count == 2 {
                        keys.append(args[0])
                        values.append(args[1])
                    } else {
                        keys.append(.unknown)
                        values.append(.unknown)
                    }
                }
            }
            return .instance(Self.builtinsDict, [.union(keys), .union(values)])
        case .listComp, .setComp, .genExp, .dictComp:
            let cf = comprehensionFrame(n, f)
            guard let element = n.parts.first else { return .unknown }
            switch n.kind {
            case .listComp: return .instance(Self.builtinsList, [eval(element, cf).widened])
            case .setComp: return .instance(Self.builtinsSet, [eval(element, cf).widened])
            case .genExp: return .instance(.table("typing", "Generator"), [eval(element, cf).widened, .none, .none])
            default:
                let kv = element.parts
                guard element.kind == .pair, kv.count == 2 else { return .instance(Self.builtinsDict, []) }
                return .instance(Self.builtinsDict, [eval(kv[0], cf).widened, eval(kv[1], cf).widened])
            }
        case .member:
            if let key = chainKey(n), let t = f.env[key] { return t.get() }
            let cs = n.parts
            guard cs.count == 2, cs[1].kind == .name else { return .unknown }
            return memberType(eval(cs[0], f), string(cs[1]))
        case .call:
            return evalCall(n, f)
        case .subscript:
            return evalSubscript(n, f)
        case .binary:
            return evalBinary(n, f)
        case .unary:
            guard let inner = n.parts.first else { return .unknown }
            let op = SyntaxParsing.Op(rawValue: UInt8(truncatingIfNeeded: n.raw.aux))
            switch op {
            case .not: return .instance(Self.builtinsBool, [])
            case .minus: return call(memberType(eval(inner, f).widened, "__neg__"), [])
            case .plus: return call(memberType(eval(inner, f).widened, "__pos__"), [])
            case .tilde: return call(memberType(eval(inner, f).widened, "__invert__"), [])
            default: return .unknown
            }
        case .ternary:
            let cs = n.parts
            guard cs.count == 3 else { return .unknown }
            return .union([eval(cs[0], narrow(f, cs[1], true)), eval(cs[2], narrow(f, cs[1], false))])
        case .lambda:
            var params: [InferredParameter] = []
            if let ps = n.firstChild(.params) {
                for p in ps.parts where p.kind == .param {
                    if let name = p.parts.first, name.kind == .name {
                        params.append(InferredParameter(name: string(name), kind: .positional, type: nil,
                                                        hasDefault: p.parts.count > 1))
                    }
                }
            }
            return .callable(CallableRef(.signature(InferredSignature(parameters: params, returnType: .unknown))))
        case .await:
            guard let inner = n.parts.first else { return .unknown }
            return awaited(eval(inner, f))
        case .walrus:
            return n.parts.count == 2 ? eval(n.parts[1], f) : .unknown
        default:
            return .unknown
        }
    }

    func comprehensionFrame(_ comp: PyNode, _ f: PyFrame) -> PyFrame {
        comprehensionFrameAll(comp, f)
    }

    private func comprehensionFrameAll(_ comp: PyNode, _ frame: PyFrame) -> PyFrame {
        var f = frame
        for c in comp.parts where c.kind == .compFor {
            let cps = c.parts
            guard cps.count >= 2 else { continue }
            let iterable = cps[1]
            let snapshot = f
            let async = c.has(SyntaxFlags.async)
            bindTarget(cps[0], Thunk(lazy: { [unowned self] in
                let t = self.eval(iterable, snapshot)
                return async ? self.asyncIterationElement(t) : self.iterationElement(t)
            }), &f)
            for ci in cps.dropFirst(2) where ci.kind == .compIf {
                if let cond = ci.parts.first { f = narrow(f, cond, true) }
            }
        }
        return f
    }

    private func evalCall(_ n: PyNode, _ f: PyFrame) -> InferredType {
        let cs = n.parts
        guard let calleeNode = cs.first else { return .unknown }
        let argsNode = cs.last { $0.kind == .args }
        if calleeNode.kind == .name, string(calleeNode) == "super", f.env["super"] == nil {
            return superType(f)
        }
        let callee = eval(calleeNode, f)
        var args: [PyArg] = []
        for a in argsNode?.parts ?? [] {
            switch a.kind {
            case .keywordArg:
                let ps = a.parts
                guard ps.count == 2 else { continue }
                let value = ps[1]
                args.append(PyArg(keyword: string(ps[0]), star: 0,
                                  value: Thunk(lazy: { [unowned self] in self.eval(value, f) })))
            case .starred:
                let inner = a.parts.first
                args.append(PyArg(keyword: nil, star: Int(a.raw.aux),
                                  value: Thunk(lazy: { [unowned self] in inner.map { self.eval($0, f) } ?? .unknown })))
            default:
                args.append(PyArg(keyword: nil, star: 0, value: Thunk(lazy: { [unowned self] in self.eval(a, f) })))
            }
        }
        return call(callee, args)
    }

    /// `super()` in a method: an instance of the next class of the MRO.
    private func superType(_ f: PyFrame) -> InferredType {
        var fn = f.function
        while let current = fn, current.owner == nil {
            fn = current.defining.function
        }
        guard let owner = fn?.owner else { return .unknown }
        let args = owner.typeParamNames.map { InferredType.typeVar($0, bound: nil) }
        let chain = mro(owner.ref, args)
        guard chain.count >= 2 else { return .unknown }
        return .instance(chain[1].0, chain[1].1)
    }

    private func evalSubscript(_ n: PyNode, _ f: PyFrame) -> InferredType {
        let cs = n.parts
        guard cs.count >= 2 else { return .unknown }
        let object = eval(cs[0], f)
        let index = cs[1]
        return subscriptType(object, index: index, node: n, f)
    }

    private func subscriptType(_ object: InferredType, index: PyNode, node: PyNode, _ f: PyFrame) -> InferredType {
        switch object {
        case .classObject, .special, .typeForm:
            // A generic alias / special form used as a value.
            let t = annotationType(node, f)
            if case .instance(let ref, let args) = t { return .classObject(ref, args) }
            return t == .unknown ? .unknown : .typeForm(t)
        case .anyOf(let parts):
            return .union(parts.filter { $0 != .none }.map { subscriptType($0, index: index, node: node, f) })
        case .instance(let ref, let args):
            if ref == Self.builtinsTuple, args.count > 1, let k = intLiteral(index) {
                let i = k < 0 ? args.count + k : k
                return i >= 0 && i < args.count ? args[i] : .unknown
            }
            if ref.origin == .document, let cls = docClass(ref.name), cls.isTypedDict, index.kind == .string,
               let key = PythonTypeConverter.unquoted(string(index)) {
                for c in mro(ref, args).map(\.0) where c.origin == .document {
                    guard let dc = docClass(c.name) else { continue }
                    dc.buildMembers()
                    if let m = dc.members[key] { return dc.fieldType(m) }
                }
                return .unknown
            }
            let indexType: InferredType = index.kind == .slice ? .instance(.table("builtins", "slice"), []) : eval(index, f)
            return call(memberType(object, "__getitem__"), [PyArg(keyword: nil, star: 0, value: Thunk(indexType))])
        case .literal:
            let indexType: InferredType = index.kind == .slice ? .instance(.table("builtins", "slice"), []) : eval(index, f)
            return call(memberType(object.widened, "__getitem__"), [PyArg(keyword: nil, star: 0, value: Thunk(indexType))])
        default:
            return .unknown
        }
    }

    private func intLiteral(_ n: PyNode) -> Int? {
        if n.kind == .number { return Int(string(n)) }
        if n.kind == .unary, SyntaxParsing.Op(rawValue: UInt8(truncatingIfNeeded: n.raw.aux)) == .minus,
           let inner = n.parts.first, inner.kind == .number, let v = Int(string(inner)) { return -v }
        return nil
    }

    private static let binaryDunders: [SyntaxParsing.Op: (String, String)] = [
        .plus: ("__add__", "__radd__"), .minus: ("__sub__", "__rsub__"), .star: ("__mul__", "__rmul__"),
        .slash: ("__truediv__", "__rtruediv__"), .slashSlash: ("__floordiv__", "__rfloordiv__"),
        .percent: ("__mod__", "__rmod__"), .starStar: ("__pow__", "__rpow__"), .matMul: ("__matmul__", "__rmatmul__"),
        .amp: ("__and__", "__rand__"), .pipe: ("__or__", "__ror__"), .caret: ("__xor__", "__rxor__"),
        .shl: ("__lshift__", "__rlshift__"), .shr: ("__rshift__", "__rrshift__"),
    ]

    private func evalBinary(_ n: PyNode, _ f: PyFrame) -> InferredType {
        let cs = n.parts
        guard cs.count == 2 else { return .unknown }
        let op = SyntaxParsing.Op(rawValue: UInt8(truncatingIfNeeded: n.raw.aux)) ?? .none
        switch op {
        case .and:
            return .union([eval(cs[0], f), eval(cs[1], narrow(f, cs[0], true))])
        case .or:
            return .union([eval(cs[0], f).withoutNone, eval(cs[1], narrow(f, cs[0], false))])
        case .eq, .ne, .lt, .gt, .le, .ge, .in, .notIn, .is, .isNot:
            return .instance(Self.builtinsBool, [])
        default:
            break
        }
        let left = eval(cs[0], f)
        if op == .pipe {
            switch left {
            case .classObject, .typeForm, .special, .none:
                return .typeForm(.union([PythonTypeConverter.asType(left), PythonTypeConverter.asType(eval(cs[1], f))]))
            default: break
            }
        }
        guard let (dunder, reflected) = Self.binaryDunders[op] else { return .unknown }
        let right = eval(cs[1], f)
        let l = left.widened, r = right.widened
        let direct = call(memberType(l, dunder), [PyArg(keyword: nil, star: 0, value: Thunk(right))])
        if direct != .unknown { return direct }
        return call(memberType(r, reflected), [PyArg(keyword: nil, star: 0, value: Thunk(left))])
    }

    // MARK: - Protocols

    func iterationElement(_ t: InferredType) -> InferredType {
        guard budget.tick() else { return .unknown }
        switch t {
        case .unknown, .none, .never: return .unknown
        case .instance(let ref, let args) where ref == Self.builtinsTuple && args.count != 1:
            return args.isEmpty ? .unknown : .union(args)
        case .classObject(let ref, _):
            if mro(ref, []).contains(where: { $0.0 == .table("enum", "Enum") }) { return .instance(ref, []) }
            return .unknown
        case .anyOf(let parts):
            return .union(parts.filter { $0 != .none }.map { iterationElement($0) })
        case .typeVar(_, let bound):
            return bound.map { iterationElement($0) } ?? .unknown
        default:
            let iterator = call(memberType(t.widened, "__iter__"), [])
            guard iterator != .unknown else { return .unknown }
            return call(memberType(iterator, "__next__"), [])
        }
    }

    func asyncIterationElement(_ t: InferredType) -> InferredType {
        let iterator = call(memberType(t, "__aiter__"), [])
        guard iterator != .unknown else { return .unknown }
        return awaited(call(memberType(iterator, "__anext__"), []))
    }

    func enterType(_ t: InferredType, async: Bool) -> InferredType {
        if async { return awaited(call(memberType(t, "__aenter__"), [])) }
        return call(memberType(t, "__enter__"), [])
    }

    func awaited(_ t: InferredType) -> InferredType {
        switch t {
        case .anyOf(let parts): return .union(parts.map { awaited($0) })
        default:
            if let (_, args) = upcast(t, to: .table("typing", "Awaitable")), let a = args.first { return a }
            return .unknown
        }
    }

    // MARK: - Calls

    func call(_ callee: InferredType, _ args: [PyArg]) -> InferredType {
        guard budget.tick() else { return .unknown }
        switch callee {
        case .classObject(let ref, let cargs):
            return construct(ref, cargs, args)
        case .callable(let c):
            return callCallable(c, args)
        case .instance, .literal:
            let m = memberType(callee, "__call__")
            if case .callable = m { return call(m, args) }
            return .unknown
        case .anyOf(let parts):
            return .union(parts.filter { $0 != .none }.map { call($0, args) })
        case .typeForm(let t):
            if case .instance(let ref, let a) = t { return construct(ref, a, args) }
            return .unknown
        default:
            return .unknown
        }
    }

    private func construct(_ ref: ClassRef, _ cargs: [InferredType], _ args: [PyArg]) -> InferredType {
        if ref.origin == .document { return .instance(ref, cargs) }
        if case .table(let m) = ref.origin {
            switch (m, ref.name) {
            case ("builtins", "type"):
                if args.count == 1, args[0].keyword == nil { return classOf(args[0].value.get()) }
            case ("typing", "TypeVar"), ("typing_extensions", "TypeVar"):
                guard let first = args.first, case .literal(_, let text) = first.value.get(),
                      let name = PythonTypeConverter.unquoted(text) else { return .unknown }
                let bound = args.first { $0.keyword == "bound" }.map { PythonTypeConverter.asType($0.value.get()) }
                return .typeForm(.typeVar(name, bound: bound == .unknown ? nil : bound))
            case ("typing", "NamedTuple"), ("typing", "NewType"), ("typing", "TypeAliasType"):
                return .unknown
            default:
                break
            }
        }
        if !cargs.isEmpty { return .instance(ref, cargs) }
        let params = typeParameters(of: ref)
        guard !params.isEmpty else { return .instance(ref, []) }
        let identity = InferredType.instance(ref, params.map { .typeVar($0, bound: nil) })
        for name in ["__new__", "__init__"] {
            guard let (owner, member) = tableMemberLookup(identity, name), let info = tables.classInfo(owner) else { continue }
            // The owner's parameters in terms of `ref`'s (left unbound for solving).
            var subst: [String: InferredType] = ["Self": identity]
            if owner != ref, let (_, oargs) = upcast(identity, to: owner) {
                for (i, p) in info.typeParameters.enumerated() where i < oargs.count { subst[p] = oargs[i] }
            }
            for sig in member.overloads {
                guard let solved = matchOverload(sig, module: info.module, args, dropFirst: true, subst: subst,
                                                 initial: ["Self": identity]) else { continue }
                if name == "__new__", let r = sig.returnType, r != "Self" {
                    let t = tables.type(text: r, module: info.module).substituting(subst).substituting(solved)
                    if case .instance(let rref, _) = t, rref == ref { return t }
                    continue
                }
                let resolved = params.map { p -> InferredType in
                    guard let s = solved[p] else { return .unknown }
                    if case .typeVar(let n, _) = s, n == p { return .unknown }
                    return s
                }
                // A catch-all `__new__(cls, *args, **kwargs) -> Self` says
                // nothing: let `__init__` decide.
                if name == "__new__", resolved.allSatisfy({ $0 == .unknown }) { break }
                return .instance(ref, resolved)
            }
        }
        return .instance(ref, [])
    }

    private func classOf(_ t: InferredType) -> InferredType {
        switch t {
        case .instance(let ref, let args): return .classObject(ref, args)
        case .literal(let ref, _): return .classObject(ref, [])
        case .anyOf(let parts): return .union(parts.map(classOf))
        default: return .unknown
        }
    }

    func callCallable(_ c: CallableRef, _ args: [PyArg]) -> InferredType {
        switch c.target {
        case .signature(let sig):
            return sig.returnType
        case .tableFunction(let module, let name):
            guard case .function(let fm, let fn)? = tables.store.pythonResolve(module: module, name: name) else { return .unknown }
            return selectOverload(fn.overloads, module: fm, args, dropFirst: false, base: [:])
        case .tableMember(let owner, let name):
            guard let info = tables.classInfo(owner), let member = info.decl.member(named: name) else { return .unknown }
            var base: [String: InferredType] = [:]
            var dropFirst = false
            if let receiver = c.receiver {
                let inst = instanceOf(receiver)
                base["Self"] = inst
                if let (_, oargs) = upcast(inst, to: owner) {
                    for (i, p) in info.typeParameters.enumerated() where i < oargs.count { base[p] = oargs[i] }
                }
                dropFirst = member.kind != .staticMethod
            }
            return selectOverload(member.overloads, module: info.module, args, dropFirst: dropFirst, base: base)
        case .documentFunction(let q):
            guard let fn = docFunction(q) else { return .unknown }
            return callDocFunction(fn, receiver: c.receiver, args)
        }
    }

    private func instanceOf(_ t: InferredType) -> InferredType {
        if case .classObject(let ref, let args) = t { return .instance(ref, args) }
        return t
    }

    func callDocFunction(_ fn: DocFunction, receiver: InferredType?, _ args: [PyArg]) -> InferredType {
        let decoration = fn.decoration
        if decoration == .unknown { return .unknown }
        var bindings: [String: InferredType] = [:]
        if let receiver, let owner = fn.owner {
            let inst = instanceOf(receiver)
            bindings["Self"] = inst
            if let (_, oargs) = upcast(inst, to: owner.ref) {
                for (i, p) in owner.typeParamNames.enumerated() where i < oargs.count { bindings[p] = oargs[i] }
            }
        }
        var r = declaredOrInferredReturn(fn)
        if fn.returnAnnotation != nil, !PythonTypeConverter.typeVarNames(r).isEmpty {
            let dropFirst = receiver != nil && fn.owner != nil && decoration != .staticMethod
            let shapes = fn.shapes(dropFirst: dropFirst)
            let params = dropFirst && !fn.parameters.isEmpty && fn.parameters[0].kind == 0
                ? Array(fn.parameters.dropFirst()) : fn.parameters
            if let mapping = mapArguments(args, shapes) {
                var scope = fn.defining
                scope.typeParams = fn.defining.typeParams + (fn.owner?.typeParamNames ?? []) + fn.typeParamNames
                for (ai, pi) in mapping where args[ai].star == 0 {
                    guard let annotation = params[pi].annotation else { continue }
                    let ptype = annotationType(annotation, scope).substituting(bindings)
                    solve(ptype, args[ai].value.get(), &bindings)
                }
            }
        }
        r = r.substituting(bindings)
        switch decoration {
        case .contextManager, .asyncContextManager:
            var yielded: InferredType = .unknown
            if let (_, a) = upcast(r, to: .table("typing", "Iterator")) ?? upcast(r, to: .table("typing", "AsyncIterator")),
               let first = a.first { yielded = first }
            let wrapper = decoration == .contextManager ? "_GeneratorContextManager" : "_AsyncGeneratorContextManager"
            return .instance(.table("contextlib", wrapper), [yielded, .unknown, .unknown])
        default:
            return r
        }
    }

    // MARK: - Overloads

    private func selectOverload(_ overloads: [TypeTable.Signature], module: String, _ args: [PyArg],
                                dropFirst: Bool, base: [String: InferredType]) -> InferredType {
        for sig in overloads {
            guard let solved = matchOverload(sig, module: module, args, dropFirst: dropFirst, subst: base,
                                             initial: base) else { continue }
            return returnType(sig, module: module, solved)
        }
        let returns = Set(overloads.map { $0.returnType ?? "" })
        if returns.count == 1, let sig = overloads.first { return returnType(sig, module: module, base) }
        return .unknown
    }

    private func returnType(_ sig: TypeTable.Signature, module: String, _ bindings: [String: InferredType]) -> InferredType {
        var r = sig.returnType.map { tables.type(text: $0, module: module) } ?? .unknown
        r = r.substituting(bindings)
        if sig.isAsync { r = .instance(.table("typing", "Coroutine"), [.unknown, .unknown, r]) }
        return r
    }

    /// The bindings solved when `args` fit overload `sig`; nil when they do not.
    private func matchOverload(_ sig: TypeTable.Signature, module: String, _ args: [PyArg], dropFirst: Bool,
                               subst: [String: InferredType],
                               initial: [String: InferredType]) -> [String: InferredType]? {
        var params = sig.parameters
        if dropFirst, let first = params.first, first.kind != .variadic, first.kind != .keywordVariadic { params.removeFirst() }
        let shapes = params.map { p -> ParamShape in
            let kind: InferredParameter.Kind
            switch p.kind {
            case .positionalOnly: kind = .positionalOnly
            case .positional: kind = .positional
            case .variadic: kind = .variadic
            case .keywordOnly: kind = .keywordOnly
            case .keywordVariadic: kind = .keywordVariadic
            }
            return ParamShape(name: p.name, kind: kind, hasDefault: p.hasDefault)
        }
        guard let mapping = mapArguments(args, shapes) else { return nil }
        var solved = initial
        for (ai, pi) in mapping where args[ai].star == 0 {
            guard let text = params[pi].type else { continue }
            let ptype = tables.type(text: text, module: module).substituting(subst)
            let atype = args[ai].value.get()
            guard compatible(atype, ptype) else { return nil }
            solve(ptype, atype, &solved)
        }
        return solved
    }

    /// Maps arguments to parameters: `(argument index, parameter index)`;
    /// nil when the arity or a keyword does not fit.
    func mapArguments(_ args: [PyArg], _ params: [ParamShape]) -> [(Int, Int)]? {
        var mapping: [(Int, Int)] = []
        var filled = Set<Int>()
        let positional = params.indices.filter { params[$0].kind == .positionalOnly || params[$0].kind == .positional }
        let variadic = params.firstIndex { $0.kind == .variadic }
        let keywordVariadic = params.firstIndex { $0.kind == .keywordVariadic }
        let starred = args.contains { $0.star != 0 }
        var next = 0
        for (ai, arg) in args.enumerated() where arg.keyword == nil && arg.star == 0 {
            if next < positional.count {
                mapping.append((ai, positional[next]))
                filled.insert(positional[next])
                next += 1
            } else if let variadic {
                mapping.append((ai, variadic))
            } else if !starred {
                return nil
            }
        }
        for (ai, arg) in args.enumerated() {
            guard let keyword = arg.keyword else { continue }
            if let pi = params.firstIndex(where: { $0.name == keyword && $0.kind != .positionalOnly
                                                   && $0.kind != .variadic && $0.kind != .keywordVariadic }) {
                if filled.contains(pi) { return nil }
                mapping.append((ai, pi))
                filled.insert(pi)
            } else if let keywordVariadic {
                mapping.append((ai, keywordVariadic))
            } else {
                return nil
            }
        }
        if !starred {
            for (pi, p) in params.enumerated() where !p.hasDefault && !filled.contains(pi)
                && (p.kind == .positionalOnly || p.kind == .positional || p.kind == .keywordOnly) {
                return nil
            }
        }
        return mapping
    }

    /// Whether `arg` may be passed for `param` (lenient: unknowns pass).
    func compatible(_ arg: InferredType, _ param: InferredType) -> Bool {
        switch param {
        case .unknown, .typeVar, .callable, .special, .typeForm, .module, .never: return true
        case .anyOf(let parts): return parts.contains { compatible(arg, $0) }
        case .none:
            return arg == .none || arg == .unknown || arg.constituents.contains(.none)
        default: break
        }
        switch arg {
        case .unknown, .typeVar, .never: return true
        case .anyOf(let parts): return parts.contains { compatible($0, param) }
        case .none: return false
        default: break
        }
        if case .literal(let pref, let ptext) = param {
            switch arg {
            case .literal(let aref, let atext):
                return aref == pref && Self.sameLiteral(atext, ptext)
            case .instance(let aref, _): return aref == pref
            default: return false
            }
        }
        guard case .instance(let pref, _) = param else {
            if case .classObject = param, case .classObject = arg { return true }
            return true
        }
        guard let (aref, aargs) = arg.instanceClass else {
            if case .callable = arg { return pref.shortName == "function" || isProtocol(pref) || pref == Self.builtinsObject }
            if case .classObject = arg { return pref.shortName == "type" || isProtocol(pref) || pref == Self.builtinsObject }
            return true
        }
        if pref == Self.builtinsObject || pref == aref { return true }
        if pref == Self.builtinsFloat, aref == Self.builtinsInt || aref == Self.builtinsBool { return true }
        if pref == .table("builtins", "complex"),
           [Self.builtinsInt, Self.builtinsFloat, Self.builtinsBool].contains(aref) { return true }
        let ancestry = mro(aref, aargs)
        if ancestry.contains(where: { $0.0 == pref }) { return true }
        if isProtocol(pref) { return protocolSatisfied(arg, pref) }
        // An unresolvable class (document class with an unknown base) may still fit.
        if aref.origin == .document, docClass(aref.name)?.baseInfo.unknownBase != false { return true }
        return false
    }

    private static func sameLiteral(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard let x = PythonTypeConverter.unquoted(a), let y = PythonTypeConverter.unquoted(b) else { return false }
        return x == y
    }

    private func isProtocol(_ ref: ClassRef) -> Bool {
        if case .table = ref.origin { return tables.classInfo(ref)?.decl.flags.contains(.protocol) ?? false }
        return docClass(ref.name)?.baseInfo.protocolClass ?? false
    }

    /// Structural check: every member the protocol declares exists on `arg`.
    private func protocolSatisfied(_ arg: InferredType, _ proto: ClassRef) -> Bool {
        guard let info = tables.classInfo(proto) else { return true }
        for m in info.decl.members where !["__class_getitem__", "__slots__", "__init__", "__subclasshook__",
                                          "__abstractmethods__", "__parameters__"].contains(m.name) {
            if !hasMember(arg, m.name) { return false }
        }
        return true
    }

    private func hasMember(_ t: InferredType, _ name: String) -> Bool {
        guard let (ref, args) = t.instanceClass else { return true }
        for (cref, _) in mro(ref, args) {
            if case .table = cref.origin {
                guard let info = tables.classInfo(cref) else { return true }
                if info.decl.member(named: name) != nil { return true }
            } else {
                guard let dc = docClass(cref.name) else { return true }
                dc.buildMembers()
                if dc.members[name] != nil { return true }
                if dc.baseInfo.unknownBase { return true }
            }
        }
        return false
    }

    /// Solves type variables of `param` against `arg` into `bindings`
    /// (first binding wins; literals widened).
    func solve(_ param: InferredType, _ arg: InferredType, _ bindings: inout [String: InferredType]) {
        guard budget.tick() else { return }
        switch param {
        case .typeVar(let name, _):
            if name != "Self", bindings[name] == nil, arg != .unknown { bindings[name] = arg.widened }
        case .instance(let pref, let pargs):
            guard !pargs.isEmpty else { return }
            for part in arg.constituents where part != .none {
                guard let (_, aargs) = upcast(part, to: pref) else {
                    if isProtocol(pref) { solveProtocol(pref, pargs, part, &bindings) }
                    continue
                }
                if pref == Self.builtinsTuple, pargs.count == 1, aargs.count != 1 {
                    solve(pargs[0], aargs.isEmpty ? .unknown : .union(aargs), &bindings)
                    continue
                }
                for (p, a) in zip(pargs, aargs) { solve(p, a, &bindings) }
            }
        case .anyOf(let parts):
            let nonNone = arg.withoutNone
            for p in parts where p != .none { solve(p, nonNone, &bindings) }
        case .callable(let c):
            if case .signature(let sig) = c.target {
                switch arg {
                case .classObject(let ref, let a): solve(sig.returnType, .instance(ref, a), &bindings)
                case .callable(let ac):
                    if case .signature(let asig) = ac.target { solve(sig.returnType, asig.returnType, &bindings) }
                default: break
                }
            }
        case .classObject(let pref, let pargs):
            if case .classObject(let aref, let aargs) = arg, pref == aref { for (p, a) in zip(pargs, aargs) { solve(p, a, &bindings) } }
        default:
            break
        }
    }

    /// Structural solving for a protocol the argument does not inherit
    /// (`SupportsNext[_T]` against `Iterator[int]`): the protocol's
    /// argument-free methods and properties are matched by their results.
    private func solveProtocol(_ proto: ClassRef, _ pargs: [InferredType], _ arg: InferredType,
                               _ bindings: inout [String: InferredType]) {
        guard let info = tables.classInfo(proto) else { return }
        var protoBindings: [String: InferredType] = [:]
        for (i, p) in info.typeParameters.enumerated() where i < pargs.count { protoBindings[p] = pargs[i] }
        for m in info.decl.members {
            let expected: InferredType
            let actual: InferredType
            switch m.kind {
            case .method:
                guard let sig = m.overloads.first, sig.parameters.count == 1, let r = sig.returnType else { continue }
                expected = tables.type(text: r, module: info.module).substituting(protoBindings)
                actual = call(memberType(arg, m.name), [])
            case .property, .field:
                guard let t = m.type else { continue }
                expected = tables.type(text: t, module: info.module).substituting(protoBindings)
                actual = memberType(arg, m.name)
            default:
                continue
            }
            if actual != .unknown { solve(expected, actual, &bindings) }
        }
    }

    // MARK: - Attributes

    /// The type of attribute `name` of `t`.
    func memberType(_ t: InferredType, _ name: String) -> InferredType {
        guard budget.tick() else { return .unknown }
        switch t {
        case .instance, .literal:
            return instanceAttribute(t, name)
        case .classObject(let ref, let args):
            return classAttribute(ref, args, name)
        case .module(let m):
            let v = tables.value(module: m, name: name)
            if v == .unknown, tables.store.hasPythonModule(m + "." + name) { return .module(m + "." + name) }
            return v
        case .anyOf(let parts):
            let nonNone = parts.filter { $0 != .none }
            guard !nonNone.isEmpty else { return .unknown }
            return .union(nonNone.map { memberType($0, name) })
        case .typeVar(_, let bound):
            return bound.map { memberType($0, name) } ?? .unknown
        case .callable:
            return instanceAttribute(.instance(.table("builtins", "function"), []), name)
        default:
            return .unknown
        }
    }

    /// Finds `name` on the MRO of an instance's table classes: the owning
    /// class and the member.
    private func tableMemberLookup(_ t: InferredType, _ name: String) -> (ClassRef, TypeTable.Member)? {
        guard let (ref, args) = t.instanceClass else { return nil }
        for (cref, _) in mro(ref, args) {
            guard case .table = cref.origin, let info = tables.classInfo(cref) else { continue }
            if let m = info.decl.member(named: name) { return (cref, m) }
        }
        return nil
    }

    private func instanceAttribute(_ t: InferredType, _ name: String) -> InferredType {
        guard let (ref, args) = t.instanceClass else { return .unknown }
        let receiver = t.widened
        for (cref, cargs) in mro(ref, args) {
            switch cref.origin {
            case .table(let module):
                guard let info = tables.classInfo(cref), let m = info.decl.member(named: name) else { continue }
                switch m.kind {
                case .method: return .callable(CallableRef(.tableMember(owner: cref, name: name), receiver: receiver))
                case .classMethod: return .callable(CallableRef(.tableMember(owner: cref, name: name),
                                                                receiver: classOf(receiver)))
                case .staticMethod: return .callable(CallableRef(.tableMember(owner: cref, name: name)))
                case .property, .field:
                    var bindings: [String: InferredType] = ["Self": receiver]
                    for (i, p) in info.typeParameters.enumerated() where i < cargs.count { bindings[p] = cargs[i] }
                    return (m.type.map { tables.type(text: $0, module: module) } ?? .unknown).substituting(bindings)
                }
            case .document:
                guard let dc = docClass(cref.name) else { return .unknown }
                dc.buildMembers()
                guard let m = dc.members[name] else {
                    if dc.baseInfo.unknownBase { return .unknown }
                    continue
                }
                return docMemberType(dc, m, cargs, receiver: receiver, onInstance: true)
            }
        }
        return .unknown
    }

    private func classAttribute(_ ref: ClassRef, _ args: [InferredType], _ name: String) -> InferredType {
        let classValue = InferredType.classObject(ref, args)
        for (cref, cargs) in mro(ref, args) {
            switch cref.origin {
            case .table(let module):
                guard let info = tables.classInfo(cref), let m = info.decl.member(named: name) else { continue }
                switch m.kind {
                case .method: return .callable(CallableRef(.tableMember(owner: cref, name: name)))
                case .classMethod: return .callable(CallableRef(.tableMember(owner: cref, name: name), receiver: classValue))
                case .staticMethod: return .callable(CallableRef(.tableMember(owner: cref, name: name)))
                case .property, .field:
                    var bindings: [String: InferredType] = ["Self": .instance(ref, args)]
                    for (i, p) in info.typeParameters.enumerated() where i < cargs.count { bindings[p] = cargs[i] }
                    return (m.type.map { tables.type(text: $0, module: module) } ?? .unknown).substituting(bindings)
                }
            case .document:
                guard let dc = docClass(cref.name) else { return .unknown }
                dc.buildMembers()
                guard let m = dc.members[name] else {
                    if dc.baseInfo.unknownBase { return .unknown }
                    continue
                }
                if m.instanceOnly { return .unknown }
                return docMemberType(dc, m, cargs, receiver: classValue, onInstance: false)
            }
        }
        // Metaclass attributes (`__name__`, `mro` …).
        return instanceAttribute(.instance(.table("builtins", "type"), []), name)
    }

    private func docMemberType(_ dc: DocClass, _ m: DocMember, _ cargs: [InferredType], receiver: InferredType,
                               onInstance: Bool) -> InferredType {
        var bindings: [String: InferredType] = [:]
        for (i, p) in dc.typeParamNames.enumerated() where i < cargs.count { bindings[p] = cargs[i] }
        switch m.kind {
        case .method:
            guard let fn = m.function else { return .unknown }
            return .callable(CallableRef(.documentFunction(fn.qualname), receiver: onInstance ? receiver : nil))
        case .classMethod:
            guard let fn = m.function else { return .unknown }
            let classReceiver: InferredType
            if case .classObject = receiver { classReceiver = receiver } else { classReceiver = classOf(receiver) }
            return .callable(CallableRef(.documentFunction(fn.qualname), receiver: classReceiver))
        case .staticMethod:
            guard let fn = m.function else { return .unknown }
            return .callable(CallableRef(.documentFunction(fn.qualname)))
        case .property:
            guard let fn = m.function else { return .unknown }
            return callDocFunction(fn, receiver: receiver, [])
        case .field:
            return dc.fieldType(m).substituting(bindings)
        case .nestedClass:
            return .classObject(.document(dc.qualname + "." + m.name), [])
        default:
            return .unknown
        }
    }

    // MARK: - MRO

    func typeParameters(of ref: ClassRef) -> [String] {
        switch ref.origin {
        case .table: return tables.classInfo(ref)?.typeParameters ?? []
        case .document: return docClass(ref.name)?.typeParamNames ?? []
        }
    }

    private func bases(of ref: ClassRef) -> [InferredType] {
        switch ref.origin {
        case .table: return tables.classInfo(ref)?.bases ?? []
        case .document: return docClass(ref.name)?.bases ?? []
        }
    }

    /// The bindings of `ref`'s type parameters for arguments `args`.
    func classBindings(_ ref: ClassRef, _ args: [InferredType]) -> [String: InferredType] {
        let params = typeParameters(of: ref)
        guard !params.isEmpty else { return [:] }
        if ref == Self.builtinsTuple, args.count != 1 {
            return [params[0]: args.isEmpty ? .unknown : .union(args)]
        }
        var out: [String: InferredType] = [:]
        for (i, p) in params.enumerated() { out[p] = i < args.count ? args[i] : .unknown }
        return out
    }

    /// The method resolution order of `ref` instantiated with `args` (C3,
    /// generic arguments substituted down the hierarchy; `object` last).
    func mro(_ ref: ClassRef, _ args: [InferredType]) -> [(ClassRef, [InferredType])] {
        let lin = linearization(ref)
        let bindings = classBindings(ref, args)
        guard !bindings.isEmpty else { return lin }
        return lin.map { ($0.0, $0.1.map { $0.substituting(bindings) }) }
    }

    private func linearization(_ ref: ClassRef) -> [(ClassRef, [InferredType])] {
        if let hit = linearizations[ref] { return hit }
        let params = typeParameters(of: ref)
        let head = (ref, params.map { InferredType.typeVar($0, bound: nil) })
        guard linearizing.insert(ref).inserted else { return [head] }
        defer { linearizing.remove(ref) }
        var baseList = bases(of: ref)
        if baseList.isEmpty, ref != Self.builtinsObject { baseList = [.instance(Self.builtinsObject, [])] }
        var sequences: [[(ClassRef, [InferredType])]] = []
        var direct: [(ClassRef, [InferredType])] = []
        for b in baseList {
            guard case .instance(let bref, let bargs) = b else { continue }
            let bb = classBindings(bref, bargs)
            sequences.append(linearization(bref).map { ($0.0, $0.1.map { $0.substituting(bb) }) })
            direct.append((bref, bargs))
        }
        sequences.append(direct)
        let result = [head] + Self.c3(sequences)
        linearizations[ref] = result
        return result
    }

    private static func c3(_ input: [[(ClassRef, [InferredType])]]) -> [(ClassRef, [InferredType])] {
        var seqs = input.filter { !$0.isEmpty }
        var out: [(ClassRef, [InferredType])] = []
        while !seqs.isEmpty {
            var picked: (ClassRef, [InferredType])?
            for s in seqs {
                let candidate = s[0]
                if !seqs.contains(where: { $0.dropFirst().contains { $0.0 == candidate.0 } }) {
                    picked = candidate
                    break
                }
            }
            guard let p = picked else {
                // Inconsistent hierarchy: keep the remaining classes in order.
                for s in seqs { for c in s where !out.contains(where: { $0.0 == c.0 }) { out.append(c) } }
                break
            }
            if !out.contains(where: { $0.0 == p.0 }) { out.append(p) }
            seqs = seqs.map { $0.first?.0 == p.0 ? Array($0.dropFirst()) : $0 }.filter { !$0.isEmpty }
        }
        return out
    }

    /// The class `target` as seen from instance `t` (its generic arguments).
    func upcast(_ t: InferredType, to target: ClassRef) -> (ClassRef, [InferredType])? {
        guard let (ref, args) = t.instanceClass else { return nil }
        return mro(ref, args).first { $0.0 == target }
    }

    // MARK: - Member listing

    /// The members completion lists for `t`; nil when unknown (plan §5.4:
    /// usage evidence then). Unions list the members every non-`None`
    /// constituent has (`Optional[X]` → X's members).
    func members(of t: InferredType) -> [InferredMember]? {
        guard budget.tick() else { return nil }
        switch t {
        case .instance(let ref, let args):
            return instanceMembers(ref, args)
        case .literal(let ref, _):
            return instanceMembers(ref, [])
        case .classObject(let ref, let args):
            return classObjectMembers(ref, args)
        case .module(let m):
            let list = tables.moduleMembers(m)
            return list.isEmpty ? nil : list
        case .callable:
            return instanceMembers(.table("builtins", "function"), [])
        case .anyOf(let parts):
            let nonNone = parts.filter { $0 != .none }
            guard !nonNone.isEmpty else { return nil }
            var lists: [[InferredMember]] = []
            for p in nonNone {
                guard let l = members(of: p) else { return nil }
                lists.append(l)
            }
            return InferredMemberList.intersection(lists)
        case .typeVar(_, let bound):
            return bound.flatMap { members(of: $0) }
        default:
            return nil
        }
    }

    private func instanceMembers(_ ref: ClassRef, _ args: [InferredType]) -> [InferredMember]? {
        switch ref.origin {
        case .table: guard tables.classInfo(ref) != nil else { return nil }
        case .document: guard docClass(ref.name) != nil else { return nil }
        }
        let selfType = InferredType.instance(ref, args)
        var seen = Set<String>()
        var out: [InferredMember] = []
        for (k, (cref, cargs)) in mro(ref, args).enumerated() {
            let own: [InferredMember]
            switch cref.origin {
            case .table: own = tables.ownMembers(cref, args: cargs, selfType: selfType)
            case .document: own = docClass(cref.name)?.listedMembers(instance: true) ?? []
            }
            for m in own where seen.insert(m.name).inserted {
                out.append(InferredMember(name: m.name, kind: m.kind, rank: k, detail: m.detail))
            }
        }
        return out
    }

    private func classObjectMembers(_ ref: ClassRef, _ args: [InferredType]) -> [InferredMember]? {
        switch ref.origin {
        case .table: guard tables.classInfo(ref) != nil else { return nil }
        case .document: guard docClass(ref.name) != nil else { return nil }
        }
        let selfType = InferredType.instance(ref, args)
        var seen = Set<String>()
        var out: [InferredMember] = []
        let chain = mro(ref, args)
        for (k, (cref, cargs)) in chain.enumerated() {
            switch cref.origin {
            case .table:
                guard let info = tables.classInfo(cref) else { continue }
                let own = tables.ownMembers(cref, args: cargs, selfType: selfType)
                for (m, decl) in zip(own, info.decl.members) where seen.insert(m.name).inserted {
                    if decl.kind == .field, !decl.flags.contains(.classLevel), !decl.flags.contains(.assigned) { continue }
                    out.append(InferredMember(name: m.name, kind: m.kind, rank: k, detail: m.detail))
                }
            case .document:
                for m in docClass(cref.name)?.listedMembers(instance: false) ?? [] where seen.insert(m.name).inserted {
                    out.append(InferredMember(name: m.name, kind: m.kind, rank: k, detail: m.detail))
                }
            }
        }
        let meta = tables.ownMembers(.table("builtins", "type"), args: [], selfType: .instance(.table("builtins", "type"), []))
        for m in meta where seen.insert(m.name).inserted {
            out.append(InferredMember(name: m.name, kind: m.kind, rank: chain.count, detail: m.detail))
        }
        return out
    }

    // MARK: - Summaries of document members

    /// Whether optional work (inferring types only for summaries) still fits.
    private var hasSpareBudget: Bool { budget.steps < budget.maxSteps / 4 }

    func detail(of m: DocMember, in cls: DocClass) -> String? {
        switch m.kind {
        case .method, .classMethod, .staticMethod:
            guard let fn = m.function else { return nil }
            return signatureText(fn, dropFirst: m.kind != .staticMethod)
        case .property:
            guard let fn = m.function else { return nil }
            if let annotation = fn.returnAnnotation { return annotationText(annotation) }
            guard hasSpareBudget else { return nil }
            let t = declaredOrInferredReturn(fn)
            return t == .unknown ? nil : t.pythonDescription
        case .field:
            if let annotation = m.annotation { return annotationText(annotation) }
            guard hasSpareBudget else { return nil }
            let t = cls.fieldType(m)
            return t == .unknown || t.containsUnknown ? nil : t.pythonDescription
        default:
            return nil
        }
    }

    /// `(a: int, b: str = "x") -> bool` of a document function.
    func signatureText(_ fn: DocFunction, dropFirst: Bool) -> String {
        var params = fn.parameters
        if dropFirst, let first = params.first, first.kind == 0 { params.removeFirst() }
        var parts: [String] = []
        var starred = false
        for (k, p) in params.enumerated() {
            var s: String
            switch p.kind {
            case 1: s = "*" + p.name; starred = true
            case 2: s = "**" + p.name
            default:
                if p.keywordOnly, !starred { parts.append("*"); starred = true }
                s = p.name
            }
            if let a = p.annotation { s += ": " + annotationText(a) }
            if let d = p.defaultValue {
                var dt = Self.collapsed(string(d))
                if dt.count > 16 { dt = "..." }
                s += p.annotation == nil ? "=" + dt : " = " + dt
            }
            parts.append(s)
            if p.positionalOnly, k + 1 < params.count, !params[k + 1].positionalOnly { parts.append("/") }
        }
        var out = "(" + parts.joined(separator: ", ") + ")"
        if let r = fn.returnAnnotation {
            out += " -> " + annotationText(r)
        } else if hasSpareBudget, fn.decoration != .unknown {
            let t = declaredOrInferredReturn(fn)
            if t != .unknown, !t.containsUnknown { out += " -> " + t.pythonDescription }
        }
        return out
    }

    func annotationText(_ n: PyNode) -> String {
        var s = Self.collapsed(string(n))
        if n.kind == .string, let inner = PythonTypeConverter.unquoted(s) { s = inner }
        return s
    }

    static func collapsed(_ s: String) -> String {
        s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }).joined(separator: " ")
    }

    // MARK: - Decorators

    /// What a decorator expression does to a function (resolved, not by spelling).
    func classifyDecorator(_ expr: PyNode, _ frame: PyFrame) -> DocFunction.Decoration {
        // `@x.setter` / `.getter` / `.deleter` on a property.
        if expr.kind == .member, let last = expr.parts.last, expr.parts.count == 2,
           ["setter", "getter", "deleter"].contains(string(last)) { return .property }
        var target = expr
        if expr.kind == .call, let callee = expr.parts.first { target = callee }
        let value = eval(target, frame)
        switch value {
        case .classObject(let ref, _):
            switch (ref.origin, ref.name) {
            case (.table("builtins"), "staticmethod"): return .staticMethod
            case (.table("builtins"), "classmethod"): return .classMethod
            case (.table("builtins"), "property"), (.table("functools"), "cached_property"): return .property
            case (.table("typing_extensions"), "deprecated"), (.table("warnings"), "deprecated"): return .none
            default: return .unknown
            }
        case .callable(let c):
            guard case .tableFunction(let m, let name) = c.target else { return .unknown }
            switch (m, name) {
            case ("abc", "abstractmethod"), ("typing", "overload"), ("typing", "final"), ("typing", "override"),
                 ("typing_extensions", "overload"), ("typing_extensions", "final"), ("typing_extensions", "override"),
                 ("typing", "no_type_check"), ("functools", "cache"), ("functools", "lru_cache"),
                 ("functools", "wraps"), ("functools", "singledispatch"):
                return .none
            case ("contextlib", "contextmanager"): return .contextManager
            case ("contextlib", "asynccontextmanager"): return .asyncContextManager
            default: return .unknown
            }
        default:
            return .unknown
        }
    }
}
