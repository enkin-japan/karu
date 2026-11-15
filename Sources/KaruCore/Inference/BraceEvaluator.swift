import Foundation

// M17 T17.11d — receiver typing for the statically typed brace languages
// (plan §8.1 「只用显式声明」): a receiver's type comes only from what a
// declaration writes — a local's / parameter's / field's / global's type,
// an initializer that constructs a type of this file (`Foo(…)`, `new Foo()`,
// `Foo{…}`, `&Foo{}`, `Foo::new()`), a call to a function or method whose
// result type is written, `self` / `this`. A library or unknown type is
// unknown (usage evidence then), never a guess.

/// An instance of a document type with how it is held.
struct BraceInstance: Equatable {
    var type: Int
    var pointer = 0
    var optional = false
    var smart = false
}

/// A function / method not yet called.
struct BraceCallable {
    var results: [BraceWrittenType?]
    /// Snapshot offset resolving the result types' names.
    var context: Int
    /// The receiver's type (`Self`).
    var selfType: Int?
    /// Calling it constructs this type (Swift `Foo.init`).
    var constructs: Int?
}

/// The value of a receiver expression.
enum BraceValue {
    case unknown
    case instance(BraceInstance)
    /// A type used as a value (`Foo.` / `Foo::`).
    case typeLevel(Int)
    case callable(BraceCallable)
    /// A package / module / namespace path before `.` / `::` (T17.14: Go
    /// `pkg.T`, Rust `crate::m::T`, C++ `ns::T`): only a type can follow.
    case namespace([String])
}

/// Evaluates one member-access request over a `BraceModuleView`.
final class BraceEvaluator {
    let view: BraceModuleView
    private var language: BraceLanguage { view.language }
    private var reader: BraceTokenReader { view.reader }
    private var resolving = Set<Int>()
    private var depth = 0

    init(view: BraceModuleView) {
        self.view = view
    }

    var isAborted: Bool { view.budget.exhausted }

    // MARK: - Request

    /// The access operator at `dot` (live): `.`, `?.` (Swift), `->` (C,
    /// C++), `::` (Rust, C++); nil otherwise.
    static func accessOperator(at dot: Int, in text: NSString, language: BraceLanguage) -> String? {
        guard dot >= 0, dot < text.length else { return nil }
        let c = text.character(at: dot)
        if c == 46 {
            if language == .swift, dot > 0, text.character(at: dot - 1) == 63 { return "?." }
            return "."
        }
        guard dot + 1 < text.length else { return nil }
        let d = text.character(at: dot + 1)
        if c == 45, d == 62, language == .c || language == .cpp { return "->" }
        if c == 58, d == 58, language == .rust || language == .cpp { return "::" }
        return nil
    }

    /// The members of the receiver before the operator at live offset
    /// `dot`; nil when its type is unknown.
    func members(atOperator dot: Int, operator op: String) -> [InferredMember]? {
        let opStart = op == "?." ? dot - 1 : dot
        guard let snapshotDot = view.base(opStart) else { return nil }
        // The receiver: tokens from the line start (earlier lines while the
        // line continues a chain).
        var lineStart = reader.lineStart(of: opStart)
        var tk = reader.tokens(lineStart: lineStart, anchor: opStart, to: opStart)
        var lines = 0
        while lines < 8, lineStart > 0, tk.first.map({ $0.kind == .dot || $0.kind == .thinArrow }) ?? false {
            lineStart = reader.lineStart(of: lineStart - 1)
            tk = reader.tokens(lineStart: lineStart, anchor: opStart, to: opStart)
            lines += 1
        }
        guard !tk.isEmpty, let start = chainStart(tk, end: tk.count) else { return nil }
        var value = evaluate(tk, start, tk.count, context: snapshotDot)
        guard !isAborted else { return nil }
        if op == "?." {
            // Optional chaining: the receiver must be optional; its members follow.
            guard case .instance(var inst) = value, inst.optional else { return nil }
            inst.optional = false
            value = .instance(inst)
        }
        switch value {
        case .instance(let inst):
            guard accessAllowed(inst, op: op == "?." ? "." : op) else { return nil }
            return listing(inst.type, typeLevel: false, at: snapshotDot)
        case .typeLevel(let id):
            switch (language, op) {
            case (.swift, "."), (.java, "."), (.csharp, "."), (.rust, "::"), (.cpp, "::"): break
            default: return nil
            }
            return listing(id, typeLevel: true, at: snapshotDot)
        default:
            return nil
        }
    }

    /// `.` / `->` on an instance held like `inst`.
    private func accessAllowed(_ inst: BraceInstance, op: String) -> Bool {
        switch language {
        case .c, .cpp:
            if op == "." { return inst.pointer == 0 && !inst.smart }
            if op == "->" { return inst.pointer == 1 || inst.pointer == 0 && inst.smart }
            return false
        case .swift:
            return op == "." && !inst.optional
        default:
            return op == "."
        }
    }

    /// The listed members (plan §13 precision: the receiver type's own,
    /// visible from `at`; instance or type level).
    private func listing(_ id: Int, typeLevel: Bool, at offset: Int) -> [InferredMember]? {
        if typeLevel, language == .go || language == .c { return nil }
        let context = view.enclosingTypes(at: offset)
        var out: [InferredMember] = []
        var seen = Set<String>()
        for entry in view.lineage(of: id) {
            guard view.tick() else { return nil }
            let t = view.types[entry.id]
            for m in view.members(of: entry.id) {
                let level = m.isStatic || m.isEnumCase || m.kind == .nestedClass
                guard level == typeLevel else { continue }
                // Static members of interfaces / protocols are not inherited (Java, C#).
                if typeLevel, entry.rank > 0, t.isInterfaceLike, language == .java || language == .csharp { continue }
                guard view.isVisible(m, owner: entry.id, inherited: entry.access, at: offset, contextTypes: context)
                else { continue }
                guard seen.insert(m.name).inserted else { continue }
                out.append(InferredMember(name: m.name, kind: m.kind, rank: entry.rank, detail: m.detail))
            }
        }
        guard !isAborted else { return nil }
        return out
    }

    // MARK: - Chains

    /// The start of the postfix chain ending at `end` (exclusive), read backwards.
    func chainStart(_ tk: [DeclToken], end: Int) -> Int? {
        var k = end - 1
        var start: Int?
        while k >= 0 {
            let t = tk[k]
            switch t.kind {
            case .rparen, .rbracket, .rbrace:
                guard let open = BraceTokens.matchingBackward(tk, k) else { return start }
                // A group with something callable / indexable before it continues the chain.
                if open > 0 {
                    let p = tk[open - 1]
                    let continues = p.kind == .ident && (p.keyword == .none || isReceiverKeyword(p))
                        || p.kind == .rparen || p.kind == .rbracket || p.kind == .greater || p.kind == .bang
                        || p.kind == .question || (t.kind == .rbrace && p.kind == .rparen)
                    if continues, t.kind != .rbrace || p.kind == .ident || p.kind == .greater || p.kind == .rparen {
                        k = open - 1
                        continue
                    }
                }
                return t.kind == .rparen ? open : start
            case .ident:
                guard t.keyword == .none || isReceiverKeyword(t) || (language == .rust && t.keyword == .crate)
                else { return start }
                start = k
                guard k > 0 else { return start }
                let p = tk[k - 1]
                if p.kind == .dot || p.kind == .thinArrow {
                    k -= 2
                    continue
                }
                if p.keyword == .new, language == .java || language == .csharp || language == .cpp { return k - 1 }
                return start
            case .greater:
                // Generic arguments before a call / path (`make_unique<Foo>(`, `Vec::<T>::new`).
                guard k + 1 < end, tk[k + 1].kind == .lparen || tk[k + 1].kind == .dot else { return start }
                var angle = 0
                var j = k
                while j >= 0 {
                    if tk[j].kind == .greater { angle += 1 } else if tk[j].kind == .less {
                        angle -= 1
                        if angle == 0 { break }
                    } else if tk[j].kind == .semicolon || tk[j].kind == .lbrace || tk[j].kind == .rbrace {
                        return start
                    }
                    j -= 1
                }
                guard j > 0 else { return start }
                k = j - 1
                if tk[k].kind == .dot { k -= 1 }   // turbofish `::<`
            case .bang, .question:
                guard language == .swift else { return start }
                k -= 1
            default:
                return start
            }
        }
        return start
    }

    private func isReceiverKeyword(_ t: DeclToken) -> Bool {
        switch t.keyword {
        case .selfValue, .this, .super, .base: return true
        default: return false
        }
    }

    private func spells(_ t: DeclToken, _ w: String) -> Bool { reader.spells(t, w) }

    /// The value of `tk[from..<to]` seen from snapshot offset `context`;
    /// unknown unless the whole range is one understood expression.
    /// `resultIndex`: Go `a, b := f()` — the result of the final call.
    func evaluate(_ tk: [DeclToken], _ from: Int, _ to: Int, context: Int, resultIndex: Int? = nil) -> BraceValue {
        guard from < to, depth < 24, view.tick() else { return .unknown }
        depth += 1
        defer { depth -= 1 }
        var k = from
        var addressOf = 0
        var derefs = 0
        var tryOptional = false
        // Prefixes.
        while k < to {
            let t = tk[k]
            if language == .swift, spells(t, "try") || t.keyword == .await {
                k += 1
                if k < to, tk[k].kind == .question { tryOptional = true; k += 1 } else if k < to, tk[k].kind == .bang { k += 1 }
                continue
            }
            if t.keyword == .await, language == .csharp { k += 1; continue }
            if t.kind == .op, spells(t, "&") || spells(t, "&&"), language != .java, language != .csharp, language != .swift {
                addressOf += spells(t, "&&") ? 2 : 1
                k += 1
                if language == .rust, k < to, tk[k].keyword == .mut { k += 1 }
                continue
            }
            if t.kind == .star, language == .c || language == .cpp || language == .rust {
                derefs += 1
                k += 1
                continue
            }
            break
        }
        guard k < to else { return .unknown }
        var value: BraceValue = .unknown
        var inOptionalChain = false
        let t = tk[k]
        // Primary.
        if t.keyword == .new, language == .java || language == .csharp || language == .cpp {
            guard case .type(let type, let e)? = view.decls.types.parse(tk, k + 1, to), type.isNominal,
                  e < to, tk[e].kind == .lparen || tk[e].kind == .lbrace,
                  let close = BraceTokens.matching(tk, e, limit: to),
                  let id = view.resolveType(type, context: context) else { return .unknown }
            value = .instance(BraceInstance(type: id, pointer: language == .cpp ? 1 : 0))
            k = close + 1
        } else if t.kind == .lparen {
            guard let close = BraceTokens.matching(tk, k, limit: to) else { return .unknown }
            if [.java, .csharp, .c, .cpp].contains(language), close + 1 < to,
               case .type(let type, let e)? = view.decls.types.parse(tk, k + 1, close), e == close,
               tk[close + 1].kind == .ident || tk[close + 1].kind == .lparen || tk[close + 1].kind == .star {
                // A cast `(Foo) x`: the cast type (the operand binds tighter).
                guard type.isNominal, let id = view.resolveType(type, context: context) else { return .unknown }
                return finish(.instance(BraceInstance(type: id, pointer: type.pointer, smart: type.smart)),
                              addressOf: addressOf, derefs: derefs, tryOptional: tryOptional)
            }
            value = evaluate(tk, k + 1, close, context: context)
            k = close + 1
        } else if language == .rust, t.kind == .ident, t.keyword == .crate || t.keyword == .super
                    || t.keyword == .selfValue, k + 1 < to, view.decls.types.isPathSeparator(tk[k + 1]) {
            // `crate::` / `super::` / `self::`: a module path (T17.14).
            value = .namespace([])
            k += 1
        } else if t.kind == .ident, t.keyword == .none || isReceiverKeyword(t) {
            if let smart = smartFactory(tk, k, to, context: context) {
                value = smart.0
                k = smart.1
            } else {
                value = resolveName(tk[k], context: context)
                k += 1
                // An unresolved name before a path separator: a package /
                // module / namespace (T17.14, cross-file types only).
                if case .unknown = value, view.foreign != nil, t.keyword == .none, k + 1 < to, tk[k + 1].kind == .ident,
                   isNamespaceSeparator(tk[k], name: reader.string(t), context: context) {
                    value = .namespace([reader.string(t)])
                }
                // Composite / struct literals `Foo{…}` (Go, Rust, C++).
                if k < to, tk[k].kind == .lbrace, case .typeLevel(let id) = value,
                   language == .go || language == .rust || language == .cpp,
                   let close = BraceTokens.matching(tk, k, limit: to) {
                    value = .instance(BraceInstance(type: id))
                    k = close + 1
                }
            }
        } else {
            return .unknown
        }
        // Postfix.
        while k < to {
            guard view.tick() else { return .unknown }
            let u = tk[k]
            switch u.kind {
            case .dot, .thinArrow:
                guard k + 1 < to, tk[k + 1].kind == .ident else { return .unknown }
                var op = u.kind == .thinArrow ? "->" : reader.string(u)
                if op == "?." {
                    guard case .instance(var inst) = value, inst.optional else { return .unknown }
                    inst.optional = false
                    value = .instance(inst)
                    inOptionalChain = true
                    op = "."
                }
                if language == .rust, op == ".", spells(tk[k + 1], "await") { return .unknown }
                let calls = k + 2 < to && tk[k + 2].kind == .lparen
                value = access(value, op: op, name: tk[k + 1], context: context, calls: calls,
                               inOptionalChain: inOptionalChain)
                k += 2
            case .lparen:
                guard let close = BraceTokens.matching(tk, k, limit: to) else { return .unknown }
                let last = close + 1 == to || (language == .swift && close + 1 < to && tk[close + 1].kind == .lbrace
                    && BraceTokens.matching(tk, close + 1, limit: to).map { $0 + 1 == to } == true)
                value = call(value, resultIndex: last ? resultIndex : nil)
                k = close + 1
            case .lbrace where language == .swift:
                // Trailing closure.
                guard let close = BraceTokens.matching(tk, k, limit: to) else { return .unknown }
                if case .callable = value { value = call(value, resultIndex: close + 1 == to ? resultIndex : nil) }
                else if case .typeLevel = value { value = call(value, resultIndex: nil) }
                k = close + 1
            case .lbrace where language == .go || language == .rust || language == .cpp:
                // A composite / struct literal of a qualified type (`pkg.T{…}`, `m::T {…}`).
                guard case .typeLevel(let id) = value, let close = BraceTokens.matching(tk, k, limit: to) else {
                    return .unknown
                }
                value = .instance(BraceInstance(type: id))
                k = close + 1
            case .bang where language == .swift:
                guard case .instance(var inst) = value else { return .unknown }
                inst.optional = false
                value = .instance(inst)
                k += 1
            case .question where language == .swift:
                guard case .instance(var inst) = value, inst.optional else { return .unknown }
                inst.optional = false
                value = .instance(inst)
                inOptionalChain = true
                k += 1
            case .less:
                // Generic arguments before a call (`Foo<T>(…)`, `f::<T>()`).
                guard let close = BraceTokens.matchingAngle(tk, k, end: to), close + 1 < to,
                      tk[close + 1].kind == .lparen || tk[close + 1].kind == .dot else { return .unknown }
                k = close + 1
            default:
                return .unknown
            }
            if case .unknown = value { return .unknown }
        }
        if inOptionalChain, case .instance(var inst) = value {
            inst.optional = true
            value = .instance(inst)
        }
        return finish(value, addressOf: addressOf, derefs: derefs, tryOptional: tryOptional)
    }

    private func finish(_ value: BraceValue, addressOf: Int, derefs: Int, tryOptional: Bool) -> BraceValue {
        guard case .instance(var inst) = value else {
            return addressOf + derefs == 0 && !tryOptional ? value : .unknown
        }
        switch language {
        case .c, .cpp:
            for _ in 0..<derefs {
                if inst.pointer > 0 { inst.pointer -= 1 } else if inst.smart { inst.smart = false } else { return .unknown }
            }
            inst.pointer += addressOf
        case .rust:
            for _ in 0..<derefs { if inst.smart { inst.smart = false } }
        default:
            break
        }
        if tryOptional { inst.optional = true }
        return .instance(inst)
    }

    /// C++ `std::make_unique<T>(…)` / `std::make_shared<T>(…)`.
    private func smartFactory(_ tk: [DeclToken], _ k: Int, _ to: Int, context: Int) -> (BraceValue, Int)? {
        guard language == .cpp else { return nil }
        var j = k
        if spells(tk[j], "std"), j + 2 < to, view.decls.types.isPathSeparator(tk[j + 1]) { j += 2 }
        guard j < to, spells(tk[j], "make_unique") || spells(tk[j], "make_shared"), j + 1 < to,
              tk[j + 1].kind == .less, let close = BraceTokens.matchingAngle(tk, j + 1, end: to),
              close + 1 < to, tk[close + 1].kind == .lparen,
              let end = BraceTokens.matching(tk, close + 1, limit: to),
              case .type(let type, let e)? = view.decls.types.parse(tk, j + 2, close), e == close,
              type.isNominal, type.pointer == 0, let id = view.resolveType(type, context: context) else { return nil }
        return (.instance(BraceInstance(type: id, smart: true)), end + 1)
    }

    // MARK: - Names

    /// The value of a bare name at snapshot offset `context`.
    private func resolveName(_ t: DeclToken, context: Int) -> BraceValue {
        switch t.keyword {
        case .selfValue where language == .swift || language == .rust:
            return selfValue(at: context)
        case .this where language == .java || language == .csharp || language == .cpp:
            return selfValue(at: context)
        case .super where language == .java || language == .swift, .base where language == .csharp:
            guard let id = view.enclosingTypes(at: context).first else { return .unknown }
            for base in view.types[id].bases {
                guard let b = view.resolveType(base.type, context: base.context) else { continue }
                if !view.types[b].isInterfaceLike { return .instance(BraceInstance(type: b)) }
            }
            return .unknown
        default:
            break
        }
        let name = reader.string(t)
        if name == "Self", language == .swift || language == .rust {
            return view.enclosingTypes(at: context).first.map { .typeLevel($0) } ?? .unknown
        }
        if let binding = binding(named: name, at: context) {
            switch binding.kind {
            case .variable, .parameter, .property, .functionScopedVariable, .global:
                return bindingValue(binding, context: context)
            case .function, .method:
                return callable(at: binding.location, kind: binding.kind, selfType: nil)
            case .class, .type:
                var written = BraceWrittenType()
                written.path = [name]
                return view.resolveType(written, context: context).map { .typeLevel($0) } ?? .unknown
            default:
                return .unknown
            }
        }
        // Implicit members outside the type's own body (Swift extensions,
        // C++ out-of-class definitions).
        if language == .swift || language == .cpp || language == .java || language == .csharp,
           !inAnonymousClass(view.chain(at: context)), let owner = view.enclosingTypes(at: context).first,
           let found = view.lookupMember(owner, name, typeLevel: false) ?? view.lookupMember(owner, name, typeLevel: true) {
            return memberValue(found.member, receiver: owner)
        }
        var written = BraceWrittenType()
        written.path = [name]
        if let id = view.resolveType(written, context: context) { return .typeLevel(id) }
        return .unknown
    }

    /// The binding `name` visible at `offset` (locals, parameters, implicit
    /// members, then module-level declarations).
    private func binding(named name: String, at offset: Int) -> DeclarationScan.ScopedBinding? {
        if view.bindingCache[offset] == nil {
            let chain = view.chain(at: offset)
            var map: [String: DeclarationScan.ScopedBinding] = [:]
            for b in view.index.localBindings(at: offset, chain: chain) where map[b.name] == nil { map[b.name] = b }
            view.bindingCache[offset] = map
        }
        if let local = view.bindingCache[offset]?[name] { return local }
        guard let module = view.index.moduleBinding(named: name) else { return nil }
        let chain = view.chain(at: offset)
        guard view.index.moduleVisible(module, at: offset, chain: chain) else { return nil }
        return DeclarationScan.ScopedBinding(name: module.name, kind: module.kind, location: module.location, scopeDepth: 0)
    }

    /// Java: inside an anonymous class body (`new T() { … }`, a method
    /// scope directly inside a block), where `this` and implicit members are
    /// the anonymous class's, which has no name to look up.
    private func inAnonymousClass(_ chain: [DeclarationQueryIndex.PositionedScope]) -> Bool {
        guard language == .java, chain.count > 2 else { return false }
        let innermostClass = chain.lastIndex { $0.record.kind == .class } ?? 0
        for k in (innermostClass + 1)..<chain.count where chain[k].record.kind == .function
            && chain[k - 1].record.kind == .block {
            return true
        }
        return false
    }

    /// `self` / `this` at `offset`.
    private func selfValue(at offset: Int) -> BraceValue {
        let chain = view.chain(at: offset)
        guard !inAnonymousClass(chain), let id = view.enclosingTypes(at: offset).first else { return .unknown }
        // The method: the outermost function scope inside the innermost class
        // scope (nested functions and closures capture its `self`).
        let classPosition = chain.lastIndex { $0.record.kind == .class } ?? 0
        if let method = chain[classPosition...].first(where: { $0.record.kind == .function }),
           let decl = view.functionDeclaration(of: method.record),
           let info = view.functionInfo(at: decl.location, kind: decl.kind) {
            if language == .rust, !info.hasSelfParameter { return .unknown }
            // A static method: Swift `self` is the type; `this` is invalid elsewhere.
            if info.isStatic { return language == .swift ? .typeLevel(id) : .unknown }
        }
        return .instance(BraceInstance(type: id, pointer: language == .cpp ? 1 : 0))
    }

    /// The value of the variable / parameter / field declared at `binding`.
    private func bindingValue(_ binding: DeclarationScan.ScopedBinding, context: Int) -> BraceValue {
        let location = binding.location
        if let cached = view.bindingValues[location] { return cached }
        guard !resolving.contains(location), resolving.count < 16 else { return .unknown }
        resolving.insert(location)
        defer { resolving.remove(location) }
        let value = readBinding(at: location, kind: binding.kind)
        view.bindingValues[location] = value
        return value
    }

    private func readBinding(at location: Int, kind: DeclarationScan.DeclarationKind) -> BraceValue {
        guard let (tk, n) = view.tokens(atDeclaration: location) else { return .unknown }
        let info = view.decls.read(tk, name: n, kind: kind)
        var value: BraceValue
        if let type = info.type {
            value = instance(of: type, context: location, selfType: nil)
        } else if let range = info.initializer {
            value = evaluate(tk, range.lowerBound, range.upperBound, context: location,
                             resultIndex: info.resultIndex)
            if case .typeLevel = value { value = .unknown }
            if case .callable = value { value = .unknown }
        } else {
            value = .unknown
        }
        if info.unwrap, case .instance(var inst) = value {
            guard inst.optional else { return .unknown }   // `if let` on a non-optional: not ours
            inst.optional = false
            value = .instance(inst)
        }
        return value
    }

    /// An instance of a written type as seen from `context`.
    private func instance(of type: BraceWrittenType, context: Int, selfType: Int?) -> BraceValue {
        guard type.isNominal else { return .unknown }
        let id: Int?
        if type.path == ["Self"], language == .swift || language == .rust {
            id = selfType ?? view.enclosingTypes(at: context).first
        } else {
            id = view.resolveType(type, context: context)
        }
        guard let id else { return .unknown }
        if type.nullable, view.types[id].isValueType { return .unknown }   // C# `Nullable<T>`
        return .instance(BraceInstance(type: id, pointer: type.pointer, optional: type.optional, smart: type.smart))
    }

    /// A function or method declared at `location`.
    private func callable(at location: Int, kind: DeclarationScan.DeclarationKind, selfType: Int?) -> BraceValue {
        guard let info = view.functionInfo(at: location, kind: kind) else { return .unknown }
        let results = info.results.isEmpty ? [info.type] : info.results
        return .callable(BraceCallable(results: results, context: location, selfType: selfType))
    }

    private func call(_ value: BraceValue, resultIndex: Int?) -> BraceValue {
        switch value {
        case .callable(let c):
            if let id = c.constructs { return .instance(BraceInstance(type: id)) }
            let index = resultIndex ?? 0
            guard resultIndex != nil || c.results.count == 1, index < c.results.count,
                  let result = c.results[index] else { return .unknown }
            return instance(of: result, context: c.context, selfType: c.selfType)
        case .typeLevel(let id):
            // Swift initialisers, C++ temporaries, Go conversions, Rust tuple structs.
            switch language {
            case .swift, .cpp, .go, .rust: return view.types[id].isInterfaceLike ? .unknown : .instance(BraceInstance(type: id))
            default: return .unknown
            }
        default:
            return .unknown
        }
    }

    /// `.` (Go, no binding of that name) / `::` (Rust, C++) after a name.
    private func isNamespaceSeparator(_ t: DeclToken, name: String, context: Int) -> Bool {
        switch language {
        case .go: return view.decls.types.isPlainDot(t) && binding(named: name, at: context) == nil
        case .rust, .cpp: return view.decls.types.isPathSeparator(t)
        default: return false
        }
    }

    /// `value op name`.
    private func access(_ value: BraceValue, op: String, name t: DeclToken, context: Int, calls: Bool,
                        inOptionalChain: Bool) -> BraceValue {
        let name = reader.string(t)
        switch value {
        case .namespace(let path):
            switch (language, op) {
            case (.go, "."), (.rust, "::"), (.cpp, "::"): break
            default: return .unknown
            }
            var written = BraceWrittenType()
            written.path = path + [name]
            if let id = view.resolveType(written, context: context) { return .typeLevel(id) }
            return language == .go ? .unknown : .namespace(path + [name])
        case .instance(var inst):
            if inOptionalChain { inst.optional = false }
            guard accessAllowed(inst, op: op) else { return .unknown }
            guard let found = view.lookupMember(inst.type, name, typeLevel: false, calls: calls) else { return .unknown }
            return memberValue(found.member, receiver: inst.type)
        case .typeLevel(let id):
            switch (language, op) {
            case (.swift, "."), (.java, "."), (.csharp, "."), (.rust, "::"), (.cpp, "::"): break
            default: return .unknown
            }
            if language == .swift, name == "init" {
                return .callable(BraceCallable(results: [], context: context, selfType: id, constructs: id))
            }
            guard let found = view.lookupMember(id, name, typeLevel: true, calls: calls) else { return .unknown }
            let m = found.member
            if m.isEnumCase {
                // A case with a payload is called (`.circle(radius: 1)`, `Safe(1)`).
                return calls ? .callable(BraceCallable(results: [], context: context, selfType: id, constructs: id))
                    : .instance(BraceInstance(type: id))
            }
            if m.kind == .nestedClass {
                var written = BraceWrittenType()
                written.path = [name]
                let inside = view.types[found.owner].primary.map { $0.record.start } ?? context
                return view.resolveType(written, context: inside).map { .typeLevel($0) } ?? .unknown
            }
            return memberValue(m, receiver: id)
        default:
            return .unknown
        }
    }

    /// A member's value: a field's type, or the method as a callable.
    private func memberValue(_ m: BraceMember, receiver: Int) -> BraceValue {
        switch m.kind {
        case .method, .staticMethod, .classMethod:
            let results = m.results.isEmpty ? [m.type] : m.results
            return .callable(BraceCallable(results: results, context: m.location, selfType: receiver))
        case .nestedClass:
            return .unknown
        default:
            if let type = m.type { return instance(of: type, context: m.location, selfType: receiver) }
            if let range = m.initializer, !resolving.contains(m.location) {
                resolving.insert(m.location)
                defer { resolving.remove(m.location) }
                let tk = reader.tokens(anchor: range.lowerBound, to: range.upperBound)
                let from = BraceTokens.index(atOrAfter: range.lowerBound, in: tk)
                let value = evaluate(tk, from, tk.count, context: m.location)
                if case .instance = value { return value }
            }
            return .unknown
        }
    }
}
