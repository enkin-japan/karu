import Foundation

// M17 T17.11c — expression evaluation, calls, member types, linearization
// and member listing of the JS / TS evaluator (see `ScriptEvaluator`).

extension ScriptEvaluator {
    // MARK: - Expressions

    func eval(_ n: PyNode, _ f: SFrame) -> InferredType {
        guard budget.tick() else { return .unknown }
        switch n.kind {
        case .name:
            let name = string(n)
            if name == "undefined", f.env[name] == nil { return .none }
            return lookup(name, f)
        case .number:
            let s = string(n)
            if s.hasSuffix("n") { return .instance(ScriptTypes.bigint, []) }
            return .literal(ScriptTypes.number, s)
        case .string:
            let s = string(n)
            return s.utf16.count > Self.literalLimit ? ScriptTypes.stringType : .literal(ScriptTypes.string, s)
        case .template, .taggedTemplate:
            return n.kind == .template ? ScriptTypes.stringType : .unknown
        case .regex:
            return .instance(ScriptTypes.regExp, [])
        case .keywordLit:
            switch string(n) {
            case "true", "false": return .literal(ScriptTypes.boolean, string(n))
            case "null", "undefined": return .none
            case "this": return f.env["this"]?.get() ?? f.this?.get() ?? .unknown
            case "super": return superType(f)
            default: return .unknown
            }
        case .paren:
            guard let inner = n.parts.last else { return .unknown }
            return eval(inner, f)
        case .sequence:
            return n.parts.last.map { eval($0, f) } ?? .unknown
        case .array:
            var elements: [InferredType] = []
            for item in n.parts where item.kind != .elision {
                if item.kind == .spread, let inner = item.parts.first {
                    elements.append(iterationElement(eval(inner, f)).widened)
                } else {
                    elements.append(eval(item, f).widened)
                }
                if elements.count >= 16 { break }
            }
            return ScriptTypes.arrayOf(elements.isEmpty ? .unknown : .union(elements))
        case .object:
            return objectLiteral(n, f)
        case .member:
            if let key = chainKey(n), let t = f.env[key] { return t.get() }
            let cs = n.parts
            guard cs.count == 2, cs[1].kind == .name || cs[1].kind == .privateName else { return .unknown }
            var object = eval(cs[0], f)
            let optional = n.has(SyntaxFlags.optional)
            if optional { object = object.withoutNone }
            let t = memberType(object, string(cs[1]))
            return optional ? .union([t, .none]) : t
        case .subscript:
            let cs = n.parts
            guard cs.count >= 2 else { return .unknown }
            return elementAccess(eval(cs[0], f), cs[1], f)
        case .call:
            return evalCall(n, f)
        case .new:
            return evalNew(n, f)
        case .binary:
            return evalBinary(n, f)
        case .unary:
            guard let inner = n.parts.first else { return .unknown }
            switch SyntaxParsing.Op(rawValue: UInt8(truncatingIfNeeded: n.raw.aux)) {
            case .bang, .deleteOp: return ScriptTypes.booleanType
            case .typeofOp: return ScriptTypes.stringType
            case .voidOp: return .none
            case .minus, .plus, .tilde:
                let t = eval(inner, f)
                if case .instance(let ref, _) = t.widened, ref == ScriptTypes.bigint { return t.widened }
                return ScriptTypes.numberType
            default: return .unknown
            }
        case .update:
            return ScriptTypes.numberType
        case .ternary:
            let cs = n.parts
            guard cs.count == 3 else { return .unknown }
            return .union([eval(cs[1], narrow(f, cs[0], true)), eval(cs[2], narrow(f, cs[0], false))])
        case .assignExpr:
            return n.parts.last.map { eval($0, f) } ?? .unknown
        case .arrow, .funcExpr:
            return functionValue(registerFunction(n, in: f))
        case .classExpr:
            return .classObject(registerClass(n, in: f).ref, [])
        case .await:
            guard let inner = n.parts.first else { return .unknown }
            return awaited(eval(inner, f))
        case .asExpr, .typeAssertion:
            let ps = n.parts
            guard ps.count == 2 else { return .unknown }
            let (expr, type) = n.kind == .asExpr ? (ps[0], ps[1]) : (ps[1], ps[0])
            if type.kind == .keywordLit { return eval(expr, f) }     // `as const`
            let t = typeOf(type, f)
            return t == .unknown && isJavaScript ? eval(expr, f) : t
        case .satisfiesExpr:
            return n.parts.first.map { eval($0, f) } ?? .unknown
        case .nonNull:
            return n.parts.first.map { eval($0, f).withoutNone } ?? .unknown
        case .importCall:
            return .instance(ScriptTypes.promise, [.unknown])
        default:
            return .unknown
        }
    }

    /// An object literal's shape: property values (widened), methods,
    /// accessors, spreads (as `extends`).
    private func objectLiteral(_ n: PyNode, _ f: SFrame) -> InferredType {
        var shape = ObjectShape()
        for p in n.parts {
            guard budget.tick(), shape.members.count < 64 else { break }
            switch p.kind {
            case .prop:
                let ps = p.parts
                guard let key = ps.first, let name = keyName(key) else { continue }
                let t: InferredType
                if p.raw.aux == 0, ps.count >= 2 {
                    t = eval(ps[1], f).widened
                } else {
                    t = lookup(name, f).widened                 // `{ a }` / `{ a = d }`
                }
                shape.members.removeAll { $0.name == name }
                shape.members.append(ObjectShape.Member(name: name, type: t))
            case .method:
                guard let key = p.parts.first, let name = keyName(key) else { continue }
                let fn = registerFunction(p, in: f)
                let isAccessor = p.raw.aux == 1 || p.raw.aux == 2
                if p.raw.aux == 2, shape.member(named: name) != nil { continue }
                shape.members.removeAll { $0.name == name }
                if isAccessor {
                    shape.members.append(ObjectShape.Member(name: name, type: p.raw.aux == 1 ? declaredOrInferredReturn(fn) : .unknown))
                } else {
                    shape.members.append(ObjectShape.Member(name: name, type: functionValue(fn), isMethod: true))
                }
            case .spread:
                if let inner = p.parts.first {
                    let t = eval(inner, f)
                    if t != .unknown, t != .none { shape.extends.append(t) }
                }
            default:
                continue
            }
        }
        return .shape(shape)
    }

    /// `super` in a method: the base class instance (static: class object).
    private func superType(_ f: SFrame) -> InferredType {
        guard let q = f.classContext, let cls = docClass(q) ?? classes[q], let base = cls.baseInfo.bases.first else { return .unknown }
        if case .classObject = f.this?.get() ?? .unknown, case .instance(let ref, let args) = base {
            return .classObject(ref, args)
        }
        return base
    }

    private func elementAccess(_ object: InferredType, _ index: PyNode, _ f: SFrame) -> InferredType {
        switch object {
        case .anyOf(let parts):
            return .union(parts.filter { $0 != .none }.map { elementAccess($0, index, f) })
        case .instance(let ref, let args):
            if ref == ScriptTypes.tuple {
                if index.kind == .number, let k = Int(string(index)) { return k < args.count ? args[k] : .unknown }
                return args.isEmpty ? .unknown : .union(args)
            }
            if let element = ScriptTypes.arrayElement(object) { return element }
            if ref == ScriptTypes.string { return ScriptTypes.stringType }
            if index.kind == .string, let key = ScriptTypes.unquoted(string(index)) { return memberType(object, key) }
            return libIndexValue(ref, args)
        case .literal(let ref, _):
            return ref == ScriptTypes.string ? ScriptTypes.stringType : .unknown
        case .shape(let s):
            if index.kind == .string, let key = ScriptTypes.unquoted(string(index)), let m = s.member(named: key) {
                return m.isOptional ? .union([m.type, .none]) : m.type
            }
            return s.indexValue ?? .unknown
        default:
            return .unknown
        }
    }

    /// A lib interface's index signature value (`NodeList[0]`).
    private func libIndexValue(_ ref: ClassRef, _ args: [InferredType]) -> InferredType {
        guard let info = tables.classInfo(ref), let index = info.decl.indexSignatures.first else {
            if ref.origin == .document, let cls = docClass(ref.name) {
                cls.buildMembers()
                if let v = cls.indexValueNode {
                    return typeOf(v, cls.bodyFrame).substituting(classBindings(ref, args))
                }
            }
            return .unknown
        }
        return tables.type(text: index.valueType, section: info.section, typeParams: info.typeParameters)
            .substituting(classBindings(ref, args))
    }

    private func evalBinary(_ n: PyNode, _ f: SFrame) -> InferredType {
        let cs = n.parts
        guard cs.count == 2 else { return .unknown }
        let op = SyntaxParsing.Op(rawValue: UInt8(truncatingIfNeeded: n.raw.aux)) ?? .none
        switch op {
        case .ampAmp:
            return eval(cs[1], narrow(f, cs[0], true))
        case .pipePipe, .qq:
            return .union([eval(cs[0], f).withoutNone, eval(cs[1], narrow(f, cs[0], false))])
        case .eq, .ne, .eqStrict, .neStrict, .lt, .gt, .le, .ge, .in, .instanceof:
            return ScriptTypes.booleanType
        case .plus:
            let l = eval(cs[0], f).widened, r = eval(cs[1], f).widened
            if l == ScriptTypes.stringType || r == ScriptTypes.stringType { return ScriptTypes.stringType }
            if l == ScriptTypes.numberType, r == ScriptTypes.numberType { return ScriptTypes.numberType }
            if case .instance(let ref, _) = l, ref == ScriptTypes.bigint { return l }
            return .unknown
        case .minus, .star, .slash, .percent, .starStar, .amp, .pipe, .caret, .shl, .shr, .ushr:
            let l = eval(cs[0], f).widened
            if case .instance(let ref, _) = l, ref == ScriptTypes.bigint { return l }
            return ScriptTypes.numberType
        default:
            return .unknown
        }
    }

    // MARK: - Protocols

    /// The element type `for…of` / spread / destructuring yields.
    func iterationElement(_ t: InferredType) -> InferredType {
        guard budget.tick() else { return .unknown }
        switch t {
        case .unknown, .none, .never: return .unknown
        case .anyOf(let parts): return .union(parts.filter { $0 != .none }.map { iterationElement($0) })
        case .typeVar(_, let bound): return bound.map { iterationElement($0) } ?? .unknown
        case .literal(let ref, _): return ref == ScriptTypes.string ? ScriptTypes.stringType : .unknown
        default: break
        }
        if let element = ScriptTypes.arrayElement(t) { return element }
        guard case .instance(let ref, let args) = t else { return .unknown }
        if ref == ScriptTypes.string { return ScriptTypes.stringType }
        if ref == ScriptTypes.map, args.count == 2 { return .instance(ScriptTypes.tuple, args) }
        if ref == ScriptTypes.set, let a = args.first { return a }
        // `[Symbol.iterator]()`'s iterator type.
        guard let (owner, member) = libMember(t, "[Symbol.iterator]"), let sig = member.overloads.first,
              let r = sig.returnType, let info = tables.classInfo(owner) else { return .unknown }
        let bindings = classBindings(owner, upcast(t, to: owner)?.1 ?? []).merging(["this": t]) { a, _ in a }
        let iterator = tables.type(text: r, section: info.section, typeParams: info.typeParameters).substituting(bindings)
        if let (_, a) = upcast(iterator, to: ScriptTypes.iterator), let first = a.first { return first }
        if case .instance(_, let a) = iterator, let first = a.first { return first }
        return .unknown
    }

    /// `await t`: `Promise<T>` / `PromiseLike<T>` / thenables → T; other values unchanged.
    func awaited(_ t: InferredType) -> InferredType {
        switch t {
        case .anyOf(let parts): return .union(parts.map { awaited($0) })
        case .instance(let ref, let args):
            if ref == ScriptTypes.promise || ref == ScriptTypes.promiseLike { return args.first.map { awaited($0) } ?? .unknown }
            if let (_, a) = upcast(t, to: ScriptTypes.promiseLike), let first = a.first { return awaited(first) }
            return t
        default: return t
        }
    }

    // MARK: - Calls

    private func args(_ n: PyNode?, _ f: SFrame) -> [SArg] {
        guard let n else { return [] }
        return n.parts.map { a in
            if a.kind == .spread {
                let inner = a.parts.first
                return SArg(node: nil, frame: f, value: Thunk(lazy: { [unowned self] in inner.map { self.eval($0, f) } ?? .unknown }),
                            spread: true)
            }
            return SArg(node: a, frame: f, value: Thunk(lazy: { [unowned self] in self.eval(a, f) }), spread: false)
        }
    }

    private func evalCall(_ n: PyNode, _ f: SFrame) -> InferredType {
        let cs = n.parts
        guard let calleeNode = cs.first else { return .unknown }
        if calleeNode.kind == .keywordLit, string(calleeNode) == "super" { return .none }
        if calleeNode.kind == .name, string(calleeNode) == "require", f.env["require"] == nil { return .unknown }
        let typeArgs = cs.first { $0.kind == .typeArgs }.map { $0.parts.map { typeOf($0, f) } } ?? []
        var callee = eval(calleeNode, f)
        if n.has(SyntaxFlags.optional) { callee = callee.withoutNone }
        return call(callee, args(cs.last { $0.kind == .args }, f), typeArgs: typeArgs, frame: f)
    }

    private func evalNew(_ n: PyNode, _ f: SFrame) -> InferredType {
        let cs = n.parts
        guard let calleeNode = cs.first else { return .unknown }
        let typeArgs = cs.first { $0.kind == .typeArgs }.map { $0.parts.map { typeOf($0, f) } } ?? []
        let callee = eval(calleeNode, f)
        return construct(callee, args(cs.last { $0.kind == .args }, f), typeArgs: typeArgs, frame: f)
    }

    func call(_ callee: InferredType, _ args: [SArg], typeArgs: [InferredType] = [], frame: SFrame? = nil) -> InferredType {
        guard budget.tick() else { return .unknown }
        switch callee {
        case .callable(let c):
            return callCallable(c, args, typeArgs: typeArgs)
        case .classObject(let ref, _):
            // `String(x)`, `Array(3)`, `Date()`: the constructor's call signatures.
            guard ScriptTypeTables.section(of: ref) != nil else { return .unknown }
            let ctor = tables.constructorType(of: ref)
            guard case .instance(let cref, let cargs) = ctor, let info = tables.classInfo(cref) else { return .unknown }
            return selectOverload(info.decl.callSignatures, section: info.section, classParams: info.typeParameters,
                                  base: classBindings(cref, cargs), args, typeArgs: typeArgs)
        case .instance(let ref, let cargs):
            guard let info = tables.classInfo(ref), !info.decl.callSignatures.isEmpty else { return .unknown }
            return selectOverload(info.decl.callSignatures, section: info.section, classParams: info.typeParameters,
                                  base: classBindings(ref, cargs), args, typeArgs: typeArgs)
        case .shape(let s):
            guard let sig = s.call else { return .unknown }
            return callSignature(sig, args)
        case .anyOf(let parts):
            return .union(parts.filter { $0 != .none }.map { call($0, args, typeArgs: typeArgs, frame: frame) })
        default:
            return .unknown
        }
    }

    func construct(_ callee: InferredType, _ args: [SArg], typeArgs: [InferredType], frame: SFrame?) -> InferredType {
        guard budget.tick() else { return .unknown }
        switch callee {
        case .classObject(let ref, let cargs):
            if ref.origin == .document {
                guard let cls = docClass(ref.name) else { return .instance(ref, typeArgs) }
                let params = cls.typeParamNames
                if !typeArgs.isEmpty || params.isEmpty { return .instance(ref, typeArgs.isEmpty ? cargs : typeArgs) }
                return .instance(ref, solveConstructor(cls, args))
            }
            let ctor = tables.constructorType(of: ref)
            if case .instance(let cref, let ccargs) = ctor, let info = tables.classInfo(cref), !info.decl.constructSignatures.isEmpty {
                let r = selectOverload(info.decl.constructSignatures, section: info.section,
                                       classParams: info.typeParameters, base: classBindings(cref, ccargs), args, typeArgs: typeArgs)
                if case .instance = r { return r }
            }
            return .instance(ref, typeArgs)
        case .anyOf(let parts):
            return .union(parts.filter { $0 != .none }.map { construct($0, args, typeArgs: typeArgs, frame: frame) })
        default:
            return .unknown
        }
    }

    /// Type arguments of a generic document class from its constructor's
    /// annotated parameters (`new Box(5)` → `Box<number>`).
    private func solveConstructor(_ cls: SDocClass, _ args: [SArg]) -> [InferredType] {
        cls.buildMembers()
        let params = cls.typeParamNames
        guard let ctor = functions[cls.qualname + ".constructor"] else { return params.map { _ in .unknown } }
        var bindings: [String: InferredType] = [:]
        let scope = SFrame(types: ctor.defining.types, classContext: cls.qualname, typeParams: typeParams(of: ctor))
        for (k, p) in ctor.params.enumerated() where k < args.count && !args[k].spread {
            guard let tn = p.typeNode else { continue }
            solve(typeOf(tn, scope), args[k].value.get(), &bindings)
        }
        return params.map { bindings[$0] ?? .unknown }
    }

    func callCallable(_ c: CallableRef, _ args: [SArg], typeArgs: [InferredType] = []) -> InferredType {
        switch c.target {
        case .signature(let sig):
            return callSignature(sig, args)
        case .tableFunction(let module, let name):
            let section: TSGlobalSymbol.Section = module == "dom" ? .dom : .es
            guard let symbol = tables.store.tsSymbol(name, in: section), let fn = symbol.function else { return .unknown }
            return selectOverload(fn.overloads, section: section, classParams: [], base: [:], args, typeArgs: typeArgs)
        case .tableMember(let owner, let name):
            guard let info = tables.classInfo(owner), let member = info.decl.member(named: name) else { return .unknown }
            var base: [String: InferredType] = [:]
            if let receiver = c.receiver {
                base = classBindings(owner, upcast(receiver, to: owner)?.1 ?? [])
                base["this"] = receiver
            }
            return selectOverload(member.overloads, section: info.section, classParams: info.typeParameters,
                                  base: base, args, typeArgs: typeArgs)
        case .documentFunction(let q):
            guard let fn = docFunction(q) else { return .unknown }
            return callDocFunction(fn, receiver: c.receiver, args, typeArgs: typeArgs)
        }
    }

    private func callSignature(_ sig: InferredSignature, _ args: [SArg]) -> InferredType {
        var bindings: [String: InferredType] = [:]
        for (k, p) in sig.parameters.enumerated() where k < args.count && !args[k].spread {
            guard let pt = p.type else { continue }
            solveArgument(pt, args[k], &bindings)
        }
        return resolvedTypeVars(sig.returnType.substituting(bindings))
    }

    func callDocFunction(_ fn: SDocFunction, receiver: InferredType?, _ args: [SArg], typeArgs: [InferredType]) -> InferredType {
        var bindings: [String: InferredType] = [:]
        if let receiver, let owner = fn.owner {
            bindings = classBindings(owner.ref, upcast(receiver, to: owner.ref)?.1 ?? [])
            bindings["this"] = receiver
        }
        if let declared = declaredReturn(fn) {
            let own = fn.typeParameters(self).map(\.0) + (fn.jsdoc?.templates ?? [])
            for (i, n) in own.enumerated() where i < typeArgs.count { bindings[n] = typeArgs[i] }
            if !typeVarNames(declared).isEmpty {
                let scope = SFrame(types: fn.defining.types, classContext: fn.defining.classContext, typeParams: typeParams(of: fn))
                for (k, p) in fn.params.enumerated() where k < args.count && !args[k].spread {
                    let ptype: InferredType
                    if let tn = p.typeNode { ptype = typeOf(tn, scope) } else if let j = fn.jsdoc?.param(named: p.name) {
                        ptype = jsdocType(j.type, scope)
                    } else { continue }
                    solveArgument(ptype.substituting(bindings), args[k], &bindings)
                }
            }
            var r = declared.substituting(bindings)
            if fn.isAsync, case .instance(let ref, _) = r, ref != ScriptTypes.promise { r = .instance(ScriptTypes.promise, [r]) }
            return resolvedTypeVars(r)
        }
        // Undeclared: contextual parameter types from the arguments would
        // change the inferred result per call site; the plain one is cached.
        return resolvedTypeVars(declaredOrInferredReturn(fn).substituting(bindings))
    }

    /// Unsolved type variables → their constraint (else unknown).
    func resolvedTypeVars(_ t: InferredType) -> InferredType {
        switch t {
        case .typeVar(let name, let bound):
            if name == "this" { return .unknown }
            return bound.map(resolvedTypeVars) ?? .unknown
        case .instance(let ref, let args): return .instance(ref, args.map(resolvedTypeVars))
        case .classObject(let ref, let args): return .classObject(ref, args.map(resolvedTypeVars))
        case .anyOf(let parts): return .union(parts.map(resolvedTypeVars))
        case .shape(let s): return .shape(s.map(resolvedTypeVars))
        default: return t
        }
    }

    func typeVarNames(_ t: InferredType) -> [String] {
        var out: [String] = []
        func walk(_ t: InferredType) {
            switch t {
            case .typeVar(let n, _): if !out.contains(n) { out.append(n) }
            case .instance(_, let args), .classObject(_, let args): args.forEach(walk)
            case .anyOf(let parts): parts.forEach(walk)
            case .shape(let s): s.members.forEach { walk($0.type) }; s.indexValue.map(walk)
            case .callable(let c): if case .signature(let sig) = c.target { walk(sig.returnType); sig.parameters.forEach { $0.type.map(walk) } }
            default: break
            }
        }
        walk(t)
        return out
    }

    // MARK: - Overloads

    /// The first overload the arguments fit (arity, lenient types); its
    /// return type with the solved type variables (unsolved → constraint).
    func selectOverload(_ overloads: [TypeTable.Signature], section: TSGlobalSymbol.Section, classParams: [String],
                        base: [String: InferredType], _ args: [SArg], typeArgs: [InferredType]) -> InferredType {
        guard !overloads.isEmpty else { return .unknown }
        var fallback: (TypeTable.Signature, [String: InferredType])?
        for sig in overloads {
            let params = sig.parameters.filter { $0.name != "this" }
            guard arityFits(params, args) else { continue }
            if !typeArgs.isEmpty, sig.typeParameters.count != typeArgs.count { continue }
            let sigParams = classParams + sig.typeParameters.map(\.name)
            var bindings = base
            for (i, tp) in sig.typeParameters.enumerated() where i < typeArgs.count { bindings[tp.name] = typeArgs[i] }
            var fits = true
            // Plain arguments first, then callbacks (their parameters need the bindings).
            let order = args.indices.sorted { a, b in isFunctionNode(args[a].node) == isFunctionNode(args[b].node) ? a < b : !isFunctionNode(args[a].node) }
            for k in order where !args[k].spread {
                guard let p = k < params.count ? params[k] : params.last(where: { $0.kind == .variadic }),
                      let text = p.type else { continue }
                var ptype = tables.type(text: text, section: section, typeParams: sigParams)
                if p.kind == .variadic, let e = ScriptTypes.arrayElement(ptype) { ptype = e }
                ptype = ptype.substituting(bindings)
                if !isFunctionNode(args[k].node), !compatible(args[k].value.get(), ptype) { fits = false; break }
                solveArgument(ptype, args[k], &bindings)
            }
            if fallback == nil { fallback = (sig, bindings) }
            guard fits else { continue }
            return libReturn(sig, section: section, sigParams: sigParams, bindings)
        }
        guard let (sig, bindings) = fallback, Set(overloads.map { $0.returnType ?? "" }).count == 1 else { return .unknown }
        return libReturn(sig, section: section, sigParams: classParams + sig.typeParameters.map(\.name), bindings)
    }

    private func libReturn(_ sig: TypeTable.Signature, section: TSGlobalSymbol.Section, sigParams: [String],
                           _ bindings: [String: InferredType]) -> InferredType {
        guard let r = sig.returnType else { return .none }
        var t = tables.type(text: r, section: section, typeParams: sigParams).substituting(bindings)
        // Unsolved signature type parameters fall back to their constraint.
        var bounds: [String: InferredType] = [:]
        for tp in sig.typeParameters where bindings[tp.name] == nil {
            // TypeScript falls back to the default, then the constraint.
            bounds[tp.name] = (tp.defaultType ?? tp.bound).map {
                tables.type(text: $0, section: section, typeParams: sigParams).substituting(bindings)
            } ?? .unknown
        }
        if !bounds.isEmpty { t = t.substituting(bounds) }
        return resolvedTypeVars(t)
    }

    private func isFunctionNode(_ n: PyNode?) -> Bool { n.map { $0.kind == .arrow || $0.kind == .funcExpr } ?? false }

    /// Solves `param` against an argument; a callback argument is
    /// evaluated with the parameter's (bound) parameter types and its return
    /// solves the parameter's return type.
    func solveArgument(_ param: InferredType, _ arg: SArg, _ bindings: inout [String: InferredType]) {
        let callback = param.constituents.lazy.compactMap { p -> InferredSignature? in
            if case .callable(let c) = p, case .signature(let sig) = c.target { return sig }
            return nil
        }.first
        if let node = arg.node, isFunctionNode(node), let sig = callback {
            let fn = registerFunction(node, in: arg.frame ?? SFrame())
            let context = sig.parameters.map { resolvedTypeVars(($0.type ?? .unknown).substituting(bindings)) }
            solve(sig.returnType, declaredOrInferredReturn(fn, contextual: context), &bindings)
            return
        }
        solve(param, arg.value.get(), &bindings)
    }

    /// Whether `arg` may be passed for `param` (lenient: unknowns pass).
    func compatible(_ arg: InferredType, _ param: InferredType) -> Bool {
        switch param {
        case .unknown, .typeVar, .callable, .shape, .never, .special, .typeForm, .module: return true
        case .anyOf(let parts): return parts.contains { compatible(arg, $0) }
        case .none: return arg == .none || arg == .unknown || arg.constituents.contains(.none)
        default: break
        }
        switch arg {
        case .unknown, .typeVar, .never, .shape, .callable, .classObject: return true
        case .anyOf(let parts): return parts.contains { compatible($0, param) }
        case .none: return false
        default: break
        }
        if case .literal(let pref, let ptext) = param {
            if case .literal(let aref, let atext) = arg {
                return aref == pref && (ScriptTypes.unquoted(atext) ?? atext) == (ScriptTypes.unquoted(ptext) ?? ptext)
            }
            if case .instance(let aref, _) = arg { return aref == pref }
            return false
        }
        guard case .instance(let pref, _) = param, let (aref, aargs) = arg.instanceClass else { return true }
        if pref == aref { return true }
        let primitives: Set<ClassRef> = [ScriptTypes.string, ScriptTypes.number, ScriptTypes.boolean, ScriptTypes.bigint, ScriptTypes.symbol]
        if primitives.contains(pref) || primitives.contains(aref) { return false }
        if pref == ScriptTypes.readonlyArray || pref == ScriptTypes.array {
            return ScriptTypes.arrayElement(arg) != nil || linearization(aref, aargs).contains { $0.0 == pref }
        }
        // Object types are structural: any other object may fit.
        return true
    }

    /// Solves type variables of `param` against `arg` (first binding wins; literals widened).
    func solve(_ param: InferredType, _ arg: InferredType, _ bindings: inout [String: InferredType]) {
        guard budget.tick() else { return }
        switch param {
        case .typeVar(let name, _):
            if name != "this", bindings[name] == nil, arg != .unknown, arg != .none { bindings[name] = arg.widened }
        case .instance(let pref, let pargs):
            guard !pargs.isEmpty else { return }
            for part in arg.constituents where part != .none {
                if pref == ScriptTypes.array || pref == ScriptTypes.readonlyArray, let e = ScriptTypes.arrayElement(part) {
                    solve(pargs[0], e, &bindings)
                    continue
                }
                guard let (_, aargs) = upcast(part, to: pref) else { continue }
                for (p, a) in zip(pargs, aargs) { solve(p, a, &bindings) }
            }
        case .anyOf(let parts):
            let nonNone = arg.withoutNone
            let plain = parts.filter { if case .typeVar = $0 { return false }; return $0 != .none }
            // `T | Promise<T>`: try the structured parts first.
            for p in plain { solve(p, nonNone, &bindings) }
            for p in parts where p != .none { solve(p, nonNone, &bindings) }
        case .shape(let s):
            for m in s.members { solve(m.type, memberType(arg, m.name), &bindings) }
        case .callable(let c):
            if case .signature(let sig) = c.target, case .callable(let ac) = arg {
                if case .signature(let asig) = ac.target { solve(sig.returnType, asig.returnType, &bindings) }
                if case .documentFunction(let q) = ac.target, let fn = docFunction(q) {
                    let ctx = sig.parameters.map { resolvedTypeVars(($0.type ?? .unknown).substituting(bindings)) }
                    solve(sig.returnType, declaredOrInferredReturn(fn, contextual: ctx), &bindings)
                }
            }
        default:
            break
        }
    }

    // MARK: - Contextual parameter types

    /// Parameter types a callback gets from where it is passed: the
    /// callee's parameter type (a function type) at its argument position.
    func contextualParameters(of fnNode: PyNode, parent: PyNode, _ f: SFrame) -> [InferredType]? {
        guard parent.kind == .args else { return nil }
        let argNodes = parent.parts
        guard let k = argNodes.firstIndex(of: fnNode) else { return nil }
        // The call / new that owns `parent`.
        let chain = parent.ancestors
        guard let callNode = chain.last, callNode.kind == .call || callNode.kind == .new,
              let calleeNode = callNode.parts.first else { return nil }
        let callArgs = args(parent, f)
        let callee = eval(calleeNode, f)
        let param = parameterType(of: callee, at: k, args: callArgs, isNew: callNode.kind == .new)
        return signatureParams(param)
    }

    /// The parameter types of a function type (unsolved variables → constraint).
    func signatureParams(_ t: InferredType) -> [InferredType]? {
        switch t {
        case .callable(let c):
            guard case .signature(let sig) = c.target else { return nil }
            return sig.parameters.map { p in
                let pt = resolvedTypeVars(p.type ?? .unknown)
                return p.kind == .variadic ? pt : pt
            }
        case .anyOf(let parts):
            return parts.lazy.compactMap { self.signatureParams($0) }.first
        case .shape(let s):
            return s.call.map { sig in sig.parameters.map { resolvedTypeVars($0.type ?? .unknown) } }
        default:
            return nil
        }
    }

    /// The (bound) type of parameter `k` of what `callee` calls.
    private func parameterType(of callee: InferredType, at k: Int, args: [SArg], isNew: Bool) -> InferredType {
        switch callee {
        case .callable(let c):
            switch c.target {
            case .signature(let sig):
                guard k < sig.parameters.count, let t = sig.parameters[k].type else { return .unknown }
                return t
            case .tableMember(let owner, let name):
                guard let info = tables.classInfo(owner), let member = info.decl.member(named: name) else { return .unknown }
                var base: [String: InferredType] = [:]
                if let receiver = c.receiver {
                    base = classBindings(owner, upcast(receiver, to: owner)?.1 ?? [])
                    base["this"] = receiver
                }
                return libParameter(member.overloads, section: info.section, classParams: info.typeParameters, base: base, k, args)
            case .tableFunction(let module, let name):
                let section: TSGlobalSymbol.Section = module == "dom" ? .dom : .es
                guard let fn = tables.store.tsSymbol(name, in: section)?.function else { return .unknown }
                return libParameter(fn.overloads, section: section, classParams: [], base: [:], k, args)
            case .documentFunction(let q):
                guard let fn = docFunction(q), k < fn.params.count else { return .unknown }
                let p = fn.params[k]
                let scope = SFrame(types: fn.defining.types, classContext: fn.defining.classContext, typeParams: typeParams(of: fn))
                if let tn = p.typeNode { return typeOf(tn, scope) }
                if let j = fn.jsdoc?.param(named: p.name) { return jsdocType(j.type, scope) }
                return .unknown
            }
        case .anyOf(let parts):
            return parts.lazy.map { self.parameterType(of: $0, at: k, args: args, isNew: isNew) }.first { $0 != .unknown } ?? .unknown
        default:
            return .unknown
        }
    }

    /// The function-typed parameter `k` of the first overload the
    /// arguments fit (arity; the other, non-callback arguments' types),
    /// with the type variables solved from those arguments.
    private func libParameter(_ overloads: [TypeTable.Signature], section: TSGlobalSymbol.Section, classParams: [String],
                              base: [String: InferredType], _ k: Int, _ args: [SArg]) -> InferredType {
        var fallback: InferredType?
        for sig in overloads {
            let params = sig.parameters.filter { $0.name != "this" }
            guard let p = k < params.count ? params[k] : params.last(where: { $0.kind == .variadic }), let text = p.type else { continue }
            let sigParams = classParams + sig.typeParameters.map(\.name)
            var ptype = tables.type(text: text, section: section, typeParams: sigParams)
            if p.kind == .variadic, let e = ScriptTypes.arrayElement(ptype) { ptype = e }
            guard signatureParams(ptype) != nil else { continue }
            var bindings = base
            var fits = arityFits(params, args)
            for (j, a) in args.enumerated() where j != k && !a.spread && !isFunctionNode(a.node) && j < params.count {
                guard let t = params[j].type else { continue }
                let pt = tables.type(text: t, section: section, typeParams: sigParams).substituting(bindings)
                if !compatible(a.value.get(), pt) { fits = false }
                solve(pt, a.value.get(), &bindings)
            }
            let result = ptype.substituting(bindings)
            if fits { return result }
            if fallback == nil { fallback = result }
        }
        return fallback ?? .unknown
    }

    /// The argument count fits the parameters (optional and rest ones included).
    private func arityFits(_ params: [TypeTable.Parameter], _ args: [SArg]) -> Bool {
        guard !args.contains(where: \.spread) else { return true }
        let required = params.filter { !$0.hasDefault && $0.kind != .variadic }.count
        let hasRest = params.contains { $0.kind == .variadic }
        return args.count >= required && (hasRest || args.count <= params.count)
    }

    // MARK: - Attributes

    /// The type of property `name` of `t`.
    func memberType(_ t: InferredType, _ name: String) -> InferredType {
        guard budget.tick() else { return .unknown }
        switch t {
        case .instance, .literal:
            return instanceAttribute(ScriptTypes.apparent(t), name)
        case .classObject(let ref, let args):
            return classAttribute(ref, args, name)
        case .shape(let s):
            if let m = s.member(named: name) {
                if case .callable(var c) = m.type, case .documentFunction = c.target, c.receiver == nil {
                    c.receiver = t
                    return .callable(c)
                }
                return m.isOptional ? .union([m.type, .none]) : m.type
            }
            for e in s.extends {
                let v = memberType(e, name)
                if v != .unknown { return v }
            }
            return s.indexValue ?? .unknown
        case .module(let ns):
            return tables.globalValue(ns + "." + name, allowDOM: true)
        case .anyOf(let parts):
            let nonNone = parts.filter { $0 != .none }
            guard !nonNone.isEmpty else { return .unknown }
            return .union(nonNone.map { memberType($0, name) })
        case .typeVar(let n, let bound):
            if n == "this" { return .unknown }
            return bound.map { memberType($0, name) } ?? .unknown
        case .callable:
            return instanceAttribute(.instance(ScriptTypes.function, []), name)
        default:
            return .unknown
        }
    }

    /// Finds `name` on a lib instance's linearization: the owner and the member.
    func libMember(_ t: InferredType, _ name: String) -> (ClassRef, TypeTable.Member)? {
        guard let (ref, args) = t.instanceClass else { return nil }
        for (cref, _) in linearization(ref, args) {
            guard let info = tables.classInfo(cref), let m = info.decl.member(named: name) else { continue }
            return (cref, m)
        }
        return nil
    }

    private func instanceAttribute(_ t: InferredType, _ name: String) -> InferredType {
        guard let (ref, args) = t.instanceClass else { return .unknown }
        let receiver = t.widened
        for (cref, cargs) in linearization(ref, args) {
            switch cref.origin {
            case .table:
                guard let info = tables.classInfo(cref), let m = info.decl.member(named: name),
                      !m.flags.contains(.classLevel) else { continue }
                switch m.kind {
                case .method, .classMethod, .staticMethod:
                    return .callable(CallableRef(.tableMember(owner: cref, name: name), receiver: receiver))
                case .property, .field:
                    var bindings = classBindings(cref, cargs)
                    bindings["this"] = receiver
                    var v = (m.type.map { tables.type(text: $0, section: info.section, typeParams: info.typeParameters) } ?? .unknown)
                        .substituting(bindings)
                    if m.flags.contains(.optional) { v = .union([v, .none]) }
                    return v
                }
            case .document:
                guard let cls = docClass(cref.name) ?? classes[cref.name] else { return .unknown }
                cls.buildMembers()
                guard let m = cls.members[name], cls.kind == .enum || !m.isStatic else {
                    if cls.baseInfo.unknownBase { return .unknown }
                    continue
                }
                return docMemberType(cls, m, cargs, receiver: receiver)
            }
        }
        return .unknown
    }

    private func classAttribute(_ ref: ClassRef, _ args: [InferredType], _ name: String) -> InferredType {
        if ScriptTypeTables.section(of: ref) != nil {
            let ctor = tables.constructorType(of: ref)
            if name == "prototype" { return .instance(ref, args) }
            return ctor == .unknown ? .unknown : memberType(ctor, name)
        }
        guard let cls = docClass(ref.name) ?? classes[ref.name] else { return .unknown }
        cls.buildMembers()
        if cls.kind == .enum {
            guard let m = cls.members[name] else { return .unknown }
            if let v = m.valueNode, v.kind == .string { return .literal(ScriptTypes.string, string(v)) }
            if let v = m.valueNode, v.kind == .number { return .literal(ScriptTypes.number, string(v)) }
            return enumType(cls).constituents.count == 1 ? enumType(cls) : ScriptTypes.numberType
        }
        if name == "prototype" { return .instance(ref, args) }
        for (cref, cargs) in linearization(ref, args) where cref.origin == .document {
            guard let c = docClass(cref.name) ?? classes[cref.name] else { return .unknown }
            c.buildMembers()
            if let m = c.members[name], m.isStatic {
                return docMemberType(c, m, cargs, receiver: .classObject(ref, args))
            }
            if c.baseInfo.unknownBase { return .unknown }
        }
        return instanceAttribute(.instance(ScriptTypes.function, []), name)
    }

    func docMemberType(_ cls: SDocClass, _ m: SMember, _ cargs: [InferredType], receiver: InferredType) -> InferredType {
        var bindings = classBindings(cls.ref, cargs)
        bindings["this"] = receiver
        switch m.kind {
        case .method, .staticMethod:
            if let fn = m.function { return .callable(CallableRef(.documentFunction(fn.qualname), receiver: receiver)) }
            if let sigNode = m.signatureNode {
                let t = signatureType(sigNode, cls.bodyFrame).substituting(bindings)
                return m.isOptional ? .union([t, .none]) : t
            }
            return fieldType(cls, m).substituting(bindings)
        case .property:
            guard let fn = m.function else { return .unknown }
            return callDocFunction(fn, receiver: receiver, [], typeArgs: [])
        default:
            let t = fieldType(cls, m).substituting(bindings)
            return m.isOptional ? .union([t, .none]) : t
        }
    }

    /// The type of a field: its annotation, JSDoc `@type`, initialiser, or
    /// the union of what `this.x = …` assigns (class type parameters unsubstituted).
    func fieldType(_ cls: SDocClass, _ m: SMember) -> InferredType {
        let key = cls.qualname + "#" + m.name
        guard fieldsInProgress.insert(key).inserted else { return .unknown }
        defer { fieldsInProgress.remove(key) }
        var scope = cls.bodyFrame
        if let tn = m.typeNode {
            let t = typeOf(tn, scope)
            if t != .unknown || m.valueNode == nil { return t }
        }
        if let j = m.jsdocType {
            let t = jsdocType(j, scope)
            if t != .unknown { return t }
        }
        if let fn = m.function { return functionValue(fn) }
        if let v = m.valueNode {
            scope.this = Thunk(m.isStatic ? .classObject(cls.ref, []) : .instance(cls.ref, cls.typeParamNames.map { .typeVar($0, bound: nil) }))
            return eval(v, scope).widened
        }
        var values: [InferredType] = []
        let sites = m.constructorSites > 0 ? Array(m.sites.prefix(m.constructorSites)) : m.sites
        for site in sites.prefix(Self.maxUnionSites) {
            guard let rhs = site.parts.last else { continue }
            let f = frame(at: rhs)
            values.append(eval(rhs, f).widened)
        }
        return values.isEmpty ? .unknown : .union(values)
    }

    /// An interface method signature's function type.
    func signatureType(_ sigNode: PyNode, _ scope: SFrame) -> InferredType {
        var f = scope
        if let tps = sigNode.firstChild(.typeParams) {
            for tp in tps.parts where tp.kind == .typeParam {
                if let n = tp.parts.first, n.kind == .name { f.typeParams[string(n)] = .some(nil) }
            }
        }
        var params: [InferredParameter] = []
        var returnType: InferredType = .unknown
        var seenParams = false
        for c in sigNode.parts {
            if c.kind == .params {
                seenParams = true
                for p in c.parts where p.kind == .param {
                    let ps = p.parts.filter { $0.kind != .decorator }
                    guard let b = ps.first, b.kind != .keywordLit else { continue }
                    let tn = p.raw.aux & 4 != 0 && ps.count >= 2 ? ps[1] : nil
                    params.append(InferredParameter(name: string(b), kind: p.raw.aux & 1 != 0 ? .variadic : .positional,
                                                    type: tn.map { typeOf($0, f) },
                                                    hasDefault: p.has(SyntaxFlags.optional)))
                }
            } else if seenParams {
                returnType = c.kind == .typePredicate ? ScriptTypes.booleanType : typeOf(c, f)
            }
        }
        return .callable(CallableRef(.signature(InferredSignature(parameters: params, returnType: returnType))))
    }

    /// Whether `t` has property `name` (nil: cannot tell).
    func hasMember(_ t: InferredType, _ name: String) -> Bool? {
        switch t {
        case .shape(let s):
            if s.member(named: name) != nil { return true }
            for e in s.extends { if hasMember(e, name) == true { return true } }
            return s.extends.isEmpty && s.indexValue == nil ? false : nil
        case .instance, .literal:
            guard let (ref, args) = ScriptTypes.apparent(t).instanceClass else { return nil }
            for (cref, _) in linearization(ref, args) {
                switch cref.origin {
                case .table:
                    guard let info = tables.classInfo(cref) else { return nil }
                    if info.decl.member(named: name) != nil { return true }
                case .document:
                    guard let c = docClass(cref.name) ?? classes[cref.name] else { return nil }
                    c.buildMembers()
                    if c.members[name] != nil { return true }
                    if c.baseInfo.unknownBase { return nil }
                }
            }
            return false
        default:
            return nil
        }
    }

    // MARK: - Linearization

    func typeParameters(of ref: ClassRef) -> [String] {
        if ScriptTypeTables.section(of: ref) != nil { return tables.classInfo(ref)?.typeParameters ?? [] }
        return (docClass(ref.name) ?? classes[ref.name])?.typeParamNames ?? []
    }

    func classBindings(_ ref: ClassRef, _ args: [InferredType]) -> [String: InferredType] {
        let params = typeParameters(of: ref)
        var out: [String: InferredType] = [:]
        for (i, p) in params.enumerated() { out[p] = i < args.count ? args[i] : .unknown }
        return out
    }

    private func bases(of ref: ClassRef) -> [InferredType] {
        if ScriptTypeTables.section(of: ref) != nil { return tables.classInfo(ref)?.bases ?? [] }
        return (docClass(ref.name) ?? classes[ref.name])?.baseInfo.bases ?? []
    }

    /// `ref` and its bases, depth first, each once (generic arguments
    /// substituted down the hierarchy); shapes among the bases are skipped.
    func linearization(_ ref: ClassRef, _ args: [InferredType]) -> [(ClassRef, [InferredType])] {
        let lin = rawLinearization(ref)
        let bindings = classBindings(ref, args)
        guard !bindings.isEmpty else { return lin }
        return lin.map { ($0.0, $0.1.map { $0.substituting(bindings) }) }
    }

    private func rawLinearization(_ ref: ClassRef) -> [(ClassRef, [InferredType])] {
        if let hit = linearizations[ref] { return hit }
        let head = (ref, typeParameters(of: ref).map { InferredType.typeVar($0, bound: nil) })
        guard linearizing.insert(ref).inserted else { return [head] }
        defer { linearizing.remove(ref) }
        var out = [head]
        for b in bases(of: ref) {
            guard case .instance(let bref, let bargs) = b else { continue }
            let bb = classBindings(bref, bargs)
            for item in rawLinearization(bref) where !out.contains(where: { $0.0 == item.0 }) {
                out.append((item.0, item.1.map { $0.substituting(bb) }))
            }
        }
        linearizations[ref] = out
        return out
    }

    /// The class `target` as seen from instance `t` (its generic arguments).
    func upcast(_ t: InferredType, to target: ClassRef) -> (ClassRef, [InferredType])? {
        guard let (ref, args) = ScriptTypes.apparent(t).instanceClass else { return nil }
        return linearization(ref, args).first { $0.0 == target }
    }

    // MARK: - Member listing

    /// The members completion lists for `t`; nil when unknown (plan §5.4:
    /// usage evidence then). Unions list the members every non-`null` /
    /// `undefined` constituent has. `insideClass`: the class whose body the
    /// access is in (its private members are listed).
    func members(of t: InferredType, insideClass: String?) -> [InferredMember]? {
        guard budget.tick() else { return nil }
        switch t {
        case .instance, .literal:
            guard let (ref, args) = ScriptTypes.apparent(t).instanceClass else { return nil }
            return instanceMembers(ref, args, insideClass: insideClass)
        case .classObject(let ref, let args):
            return classObjectMembers(ref, args, insideClass: insideClass)
        case .shape(let s):
            var seen = Set<String>()
            var out: [InferredMember] = []
            for m in s.members where seen.insert(m.name).inserted {
                out.append(InferredMember(name: m.name, kind: m.isMethod ? .method : .property, rank: 0,
                                          detail: memberDetail(m)))
            }
            for (k, e) in s.extends.enumerated() {
                guard let list = members(of: e, insideClass: insideClass) else { return nil }
                for m in list where seen.insert(m.name).inserted {
                    out.append(InferredMember(name: m.name, kind: m.kind, rank: k + 1 + m.rank, detail: m.detail))
                }
            }
            return out.isEmpty ? nil : out
        case .module(let ns):
            let list = tables.namespaceMembers(ns)
            return list.isEmpty ? nil : list
        case .callable:
            return instanceMembers(ScriptTypes.function, [], insideClass: nil)
        case .anyOf(let parts):
            let nonNone = parts.filter { $0 != .none }
            guard !nonNone.isEmpty else { return nil }
            var lists: [[InferredMember]] = []
            for p in nonNone {
                guard let l = members(of: p, insideClass: insideClass) else { return nil }
                lists.append(l)
            }
            return InferredMemberList.intersection(lists)
        case .typeVar(let n, let bound):
            if n == "this" { return nil }
            return bound.flatMap { members(of: $0, insideClass: insideClass) }
        default:
            return nil
        }
    }

    private func memberDetail(_ m: ObjectShape.Member) -> String? {
        if case .callable(let c) = m.type, case .documentFunction(let q) = c.target, let fn = docFunction(q) {
            return signatureText(fn)
        }
        guard m.type != .unknown, !m.type.containsUnknown else { return nil }
        return m.type.tsDescription
    }

    private func instanceMembers(_ ref: ClassRef, _ args: [InferredType], insideClass: String?) -> [InferredMember]? {
        if ScriptTypeTables.section(of: ref) != nil {
            guard tables.classInfo(ref) != nil else { return nil }
        } else if docClass(ref.name) == nil, classes[ref.name] == nil {
            return nil
        }
        let selfType = InferredType.instance(ref, args)
        var seen = Set<String>()
        var out: [InferredMember] = []
        for (k, (cref, cargs)) in linearization(ref, args).enumerated() {
            let own: [InferredMember]
            if ScriptTypeTables.section(of: cref) != nil {
                own = tables.ownMembers(cref, args: cargs, selfType: selfType)
            } else if let cls = docClass(cref.name) ?? classes[cref.name] {
                own = cls.listedMembers(instance: cls.kind != .enum, insideClass: insideClass == cls.qualname)
            } else {
                own = []
            }
            for m in own where seen.insert(m.name).inserted {
                out.append(InferredMember(name: m.name, kind: m.kind, rank: k + m.rank, detail: m.detail))
            }
        }
        return out
    }

    private func classObjectMembers(_ ref: ClassRef, _ args: [InferredType], insideClass: String?) -> [InferredMember]? {
        if ScriptTypeTables.section(of: ref) != nil {
            let ctor = tables.constructorType(of: ref)
            return ctor == .unknown ? nil : members(of: ctor, insideClass: nil)
        }
        guard let cls = docClass(ref.name) ?? classes[ref.name] else { return nil }
        if cls.kind == .enum { return cls.listedMembers(instance: true, insideClass: true) }
        var seen = Set<String>()
        var out: [InferredMember] = []
        let chain = linearization(ref, args)
        for (k, (cref, _)) in chain.enumerated() where cref.origin == .document {
            guard let c = docClass(cref.name) ?? classes[cref.name] else { continue }
            for m in c.listedMembers(instance: false, insideClass: insideClass == c.qualname) where seen.insert(m.name).inserted {
                out.append(InferredMember(name: m.name, kind: m.kind, rank: k, detail: m.detail))
            }
        }
        if seen.insert("prototype").inserted {
            out.append(InferredMember(name: "prototype", kind: .field, rank: 0, detail: cls.name))
        }
        for m in tables.ownMembers(ScriptTypes.function, args: [], selfType: .instance(ScriptTypes.function, []))
        where seen.insert(m.name).inserted {
            out.append(InferredMember(name: m.name, kind: m.kind, rank: chain.count, detail: m.detail))
        }
        return out
    }

    // MARK: - Summaries of document members

    private var hasSpareBudget: Bool { budget.steps < budget.maxSteps / 4 }

    func detail(of m: SMember, in cls: SDocClass) -> String? {
        switch m.kind {
        case .method, .staticMethod:
            if let fn = m.function { return signatureText(fn) }
            if let sig = m.signatureNode { return sigNodeText(sig) }
            return nil
        case .property:
            guard let fn = m.function else { return nil }
            if let r = fn.returnTypeNode { return ScriptTypeText.cleaned(string(r)) }
            guard hasSpareBudget else { return nil }
            let t = declaredOrInferredReturn(fn)
            return t == .unknown || t.containsUnknown ? nil : t.tsDescription
        default:
            if let tn = m.typeNode { return ScriptTypeText.cleaned(string(tn)) }
            if let j = m.jsdocType { return j }
            if cls.kind == .enum { return m.valueNode.map { ScriptTypeText.cleaned(string($0)) } }
            guard hasSpareBudget else { return nil }
            let t = fieldType(cls, m)
            return t == .unknown || t.containsUnknown ? nil : t.tsDescription
        }
    }

    /// `(value: number, label?: string) -> string` of a document function.
    func signatureText(_ fn: SDocFunction) -> String {
        var parts: [String] = []
        for p in fn.params {
            var s = (p.isRest ? "..." : "") + p.name + (p.isOptional && !p.isRest ? "?" : "")
            if let tn = p.typeNode {
                s += ": " + ScriptTypeText.cleaned(string(tn))
            } else if let j = fn.jsdoc?.param(named: p.name), let t = JSDoc.typeScriptText(j.type) {
                s += ": " + t
            }
            parts.append(s)
        }
        var out = "(" + parts.joined(separator: ", ") + ")"
        if let r = fn.returnTypeNode {
            out += " -> " + ScriptTypeText.cleaned(string(r))
        } else if let r = fn.jsdoc?.returns, let t = JSDoc.typeScriptText(r) {
            out += " -> " + t
        } else if hasSpareBudget {
            let t = declaredOrInferredReturn(fn)
            if t != .unknown, !t.containsUnknown { out += " -> " + t.tsDescription }
        }
        return out
    }

    private func sigNodeText(_ sig: PyNode) -> String {
        var params = "()"
        var returns: String?
        var seen = false
        for c in sig.parts {
            if c.kind == .params { params = ScriptTypeText.cleaned(string(c)); seen = true } else if seen {
                returns = ScriptTypeText.cleaned(string(c))
            }
        }
        return params + (returns.map { " -> " + $0 } ?? "")
    }
}
