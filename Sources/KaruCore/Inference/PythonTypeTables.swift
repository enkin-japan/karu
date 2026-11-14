import Foundation

/// The Python side of the built-in type tables for inference (M17 T17.11b):
/// stub symbols as values, stub type texts converted to `InferredType` in
/// their module's scope, class bases and type parameters, and member lists
/// with signature summaries. Process-wide (`shared`), main-actor only; every
/// derived value lives in byte-capped LRUs (plan §8.3), dropped by
/// `release()` together with `TypeTableStore`'s decoded entries when the
/// completion or type-inference module is switched off.
@MainActor
final class PythonTypeTables {
    static let shared = PythonTypeTables(store: .shared)

    /// Cap on converted stub type texts.
    nonisolated static let typeCacheBytes = 512 * 1024
    /// Cap on member lists (with summaries) of table classes and modules.
    nonisolated static let memberCacheBytes = 1024 * 1024

    let store: TypeTableStore
    private let types: ByteLRU<String, InferredType>
    private let members: ByteLRU<MemberKey, [InferredMember]>

    private struct MemberKey: Hashable {
        let owner: InferredType
        let selfType: InferredType?
    }
    private let classes: ByteLRU<ClassRef, ClassInfo>

    /// A table class's own facts (bases and type parameters converted).
    struct ClassInfo {
        let decl: TypeTable.ClassDecl
        let module: String
        let typeParameters: [String]
        /// Bases as instances whose arguments refer to `typeParameters`
        /// (`Generic[...]` / `Protocol[...]` dropped).
        let bases: [InferredType]
        var bytes: Int { 256 + decl.members.count * 96 + bases.reduce(0) { $0 + $1.approximateBytes } }
    }

    init(store: TypeTableStore, typeCacheBytes: Int = PythonTypeTables.typeCacheBytes,
         memberCacheBytes: Int = PythonTypeTables.memberCacheBytes) {
        self.store = store
        types = ByteLRU(byteLimit: typeCacheBytes, countLimit: 8_192)
        members = ByteLRU(byteLimit: memberCacheBytes, countLimit: 1_024)
        classes = ByteLRU(byteLimit: memberCacheBytes / 2, countLimit: 1_024)
    }

    /// Imported modules (M17 T17.13): overlay modules named `§…`.
    weak var importSource: ImportService?

    nonisolated static func isImportKey(_ module: String) -> Bool { module.hasPrefix("§") }

    /// Drops derived values that mention imported modules (summaries changed).
    func dropImported() {
        types.removeAll { Self.isImportKey($0) }
        members.removeAll { $0.owner.mentionsImport || ($0.selfType?.mentionsImport ?? false) }
        classes.removeAll { if case .table(let m) = $0.origin { return Self.isImportKey(m) }; return false }
    }

    // MARK: - Modules (table or imported)

    /// Stub `name`: a typeshed module, or an imported module's summary.
    func module(_ name: String) -> PythonModuleStub? {
        if Self.isImportKey(name) { return importSource?.pythonModule(name)?.stub }
        return store.pythonModule(name)
    }

    /// Whether module `name` exists (an imported submodule probe loads it
    /// when its parent is a loaded package).
    func hasModule(_ name: String) -> Bool {
        if Self.isImportKey(name) { return importSource?.pythonModule(name, speculative: true) != nil }
        return store.hasPythonModule(name)
    }

    /// The listing kind of a names-only imported module's name.
    func namesOnlyKind(module: String, name: String) -> InferredMemberKind? {
        guard Self.isImportKey(module), let summary = importSource?.pythonModule(module), let kinds = summary.kinds else { return nil }
        return kinds[name]
    }

    /// `TypeTableStore.pythonResolve` over table and imported modules.
    /// Re-export chains through imported modules stop after
    /// `ImportService.reexportDepth` hops (plan §9).
    func resolve(module: String, name: String) -> TypeTableStore.PythonSymbol? {
        guard Self.isImportKey(module) else { return store.pythonResolve(module: module, name: name) }
        return resolve(module, name, depth: 0, hops: 0)
    }

    private func resolve(_ module: String, _ name: String, depth: Int, hops: Int) -> TypeTableStore.PythonSymbol? {
        guard depth < 8 else { return nil }
        guard Self.isImportKey(module) else { return store.pythonResolve(module: module, name: name) }
        guard let stub = self.module(module) else { return nil }
        if let c = stub.class(named: name) { return .class(module: module, c) }
        if let f = stub.function(named: name) { return .function(module: module, f) }
        if let a = stub.alias(named: name) { return .alias(module: module, a) }
        if let v = stub.variable(named: name) { return .variable(module: module, v) }
        if let t = stub.typeVar(named: name) { return .typeVar(module: module, t) }
        if let imp = stub.import(named: name) {
            let next = imp.module == module ? hops : hops + (Self.isImportKey(imp.module) ? 1 : 0)
            guard next <= ImportService.reexportDepth else { return nil }
            guard let original = imp.originalName else { return hasModule(imp.module) ? .module(imp.module) : nil }
            if let found = resolve(imp.module, original, depth: depth + 1, hops: next) { return found }
            let sub = imp.module + "." + original
            return hasModule(sub) ? .module(sub) : nil
        }
        for star in stub.starImports {
            guard let source = self.module(star) else { continue }
            let exported = source.all.map { $0.contains(name) } ?? !name.hasPrefix("_")
            let next = hops + (Self.isImportKey(star) ? 1 : 0)
            if exported, next <= ImportService.reexportDepth, let found = resolve(star, name, depth: depth + 1, hops: next) {
                return found
            }
        }
        let sub = module + "." + name
        return hasModule(sub) ? .module(sub) : nil
    }

    /// Drops every derived value and the store's decoded entries / mappings.
    func release() {
        types.removeAll()
        members.removeAll()
        classes.removeAll()
        store.release()
    }

    var isReleased: Bool { types.isEmpty && members.isEmpty && classes.isEmpty }

    /// Approximate bytes held by this layer (not counting the store's LRU).
    var retainedBytes: Int { types.bytes + members.bytes + classes.bytes }

    // MARK: - Special forms

    static let typingModules: Set<String> = ["typing", "typing_extensions"]

    /// `typing` names that are plain aliases of classes elsewhere.
    static let typingClassAliases: [String: ClassRef] = [
        "List": .table("builtins", "list"), "Dict": .table("builtins", "dict"), "Set": .table("builtins", "set"),
        "FrozenSet": .table("builtins", "frozenset"), "Text": .table("builtins", "str"),
        "DefaultDict": .table("collections", "defaultdict"), "OrderedDict": .table("collections", "OrderedDict"),
        "Counter": .table("collections", "Counter"), "Deque": .table("collections", "deque"),
        "ChainMap": .table("collections", "ChainMap"),
    ]

    // MARK: - Symbols as values

    /// The value module-level `name` of stub `module` denotes.
    func value(module: String, name: String) -> InferredType {
        if Self.typingModules.contains(module) {
            if let ref = Self.typingClassAliases[name] { return .classObject(ref, []) }
        }
        guard let symbol = resolve(module: module, name: name) else {
            // Builtins are visible in every module.
            return module == "builtins" ? .unknown : value(module: "builtins", name: name)
        }
        return value(of: symbol, name: name)
    }

    /// The value a resolved stub symbol denotes.
    func value(of symbol: TypeTableStore.PythonSymbol, name: String) -> InferredType {
        switch symbol {
        case .module(let m):
            return .module(m)
        case .class(let m, let decl):
            if Self.typingModules.contains(m) {
                if decl.name == "Any" { return .special("Any") }
                if decl.name == "TypeAliasType" { return .unknown }
            }
            return .classObject(.table(m, decl.name), [])
        case .function(let m, let f):
            return .callable(CallableRef(.tableFunction(module: m, name: f.name)))
        case .variable(let m, let v):
            if Self.typingModules.contains(m) {
                if let ref = Self.typingClassAliases[v.name] { return .classObject(ref, []) }
                if v.type == "_SpecialForm" || v.type == nil || v.type == "type[_Generic]" || v.type == "type[_Protocol]" {
                    return .special(v.name)
                }
            }
            guard let text = v.type else { return .unknown }
            return type(text: text, module: m)
        case .alias(let m, let a):
            return .typeForm(type(text: a.type, module: m))
        case .typeVar(let m, let t):
            return .typeForm(typeVar(t, module: m))
        }
    }

    func typeVar(_ t: TypeTable.TypeParameter, module: String) -> InferredType {
        var bound: InferredType?
        if let text = t.bound, !t.boundIsConstraints { bound = type(text: text, module: module) }
        return .typeVar(t.name, bound: bound)
    }

    /// The value of a dotted name in stub `module` (`os.PathLike`, `_T`).
    func dottedValue(_ name: String, module: String) -> InferredType {
        let parts = name.split(separator: ".").map(String.init)
        guard let first = parts.first else { return .unknown }
        var current = value(module: module, name: first)
        for part in parts.dropFirst() {
            guard case .module(let m) = current else { return .unknown }
            current = value(module: m, name: part)
        }
        return current
    }

    // MARK: - Type texts

    /// Stub type `text` converted in `module`'s scope (cached). Type
    /// variables stay as `.typeVar` (`Self` too); callers substitute.
    func type(text: String, module: String) -> InferredType {
        let key = module + "\u{0}" + text
        if let cached = types.value(for: key) { return cached }
        let converted: InferredType
        if let expr = TypeExpr.parse(text, syntax: .python) {
            var converter = PythonTypeConverter(resolve: { [unowned self] in self.dottedValue($0, module: module) })
            converted = converter.type(expr)
        } else {
            converted = .unknown
        }
        types.insert(converted, for: key, cost: 48 + key.utf8.count + converted.approximateBytes)
        return converted
    }

    // MARK: - Classes

    func classInfo(_ ref: ClassRef) -> ClassInfo? {
        guard case .table(let module) = ref.origin else { return nil }
        if let cached = classes.value(for: ref) { return cached }
        guard let decl = self.module(module)?.class(named: ref.name) else { return nil }
        let params = decl.typeParameters.map(\.name)
        var bases: [InferredType] = []
        for text in decl.bases {
            let base = type(text: text, module: module)
            if case .instance = base { bases.append(base) }
        }
        let info = ClassInfo(decl: decl, module: module, typeParameters: params, bases: bases)
        classes.insert(info, for: ref, cost: info.bytes)
        return info
    }

    /// Own members of table class `ref` with summaries for the class's
    /// generic arguments `args` (rank 0; cached per instance type).
    func ownMembers(_ ref: ClassRef, args: [InferredType], selfType: InferredType) -> [InferredMember] {
        let mentionsSelf = classInfo(ref)?.decl.members.contains { m in
            m.type?.contains("Self") == true || m.overloads.contains { $0.returnType?.contains("Self") == true }
        } ?? false
        let key = MemberKey(owner: .instance(ref, args), selfType: mentionsSelf ? selfType : nil)
        if let cached = members.value(for: key) { return cached }
        guard let info = classInfo(ref) else { return [] }
        var bindings: [String: String] = [:]
        for (i, p) in info.typeParameters.enumerated() where i < args.count && args[i] != .unknown {
            bindings[p] = args[i].pythonDescription
        }
        bindings["Self"] = selfType.pythonDescription
        let list = info.decl.members.map { m -> InferredMember in
            InferredMember(name: m.name, kind: Self.kind(m.kind), rank: 0,
                           detail: Self.detail(m, bindings: bindings))
        }
        members.insert(list, for: key, cost: 64 + list.reduce(0) { $0 + $1.approximateBytes })
        return list
    }

    static func kind(_ k: TypeTable.Member.Kind) -> InferredMemberKind {
        switch k {
        case .method: return .method
        case .classMethod: return .classMethod
        case .staticMethod: return .staticMethod
        case .property: return .property
        case .field: return .field
        }
    }

    // MARK: - Modules

    /// The public members of stub module `module` (`__all__` and public
    /// names, re-exports; cached).
    func moduleMembers(_ module: String) -> [InferredMember] {
        let key = MemberKey(owner: .module(module), selfType: nil)
        if let cached = members.value(for: key) { return cached }
        guard let stub = self.module(module) else { return [] }
        var names: [String] = []
        var seen = Set<String>()
        func add(_ name: String) { if seen.insert(name).inserted { names.append(name) } }
        stub.all?.forEach(add)
        for c in stub.classes where !c.name.contains(".") && !c.name.hasPrefix("_") { add(c.name) }
        for f in stub.functions where !f.name.hasPrefix("_") { add(f.name) }
        for v in stub.variables where !v.name.hasPrefix("_") { add(v.name) }
        for a in stub.aliases where !a.name.hasPrefix("_") { add(a.name) }
        for i in stub.imports where i.isReexport && !i.localName.hasPrefix("_") { add(i.localName) }
        if stub.all == nil {
            for star in stub.starImports {
                guard let source = self.module(star) else { continue }
                if let all = source.all { all.forEach(add) } else {
                    for c in source.classes where !c.name.contains(".") && !c.name.hasPrefix("_") { add(c.name) }
                    for f in source.functions where !f.name.hasPrefix("_") { add(f.name) }
                    for v in source.variables where !v.name.hasPrefix("_") { add(v.name) }
                }
            }
        }
        var list: [InferredMember] = []
        for name in names {
            if let kind = namesOnlyKind(module: module, name: name) {
                list.append(InferredMember(name: name, kind: kind, rank: 0, detail: nil))
                continue
            }
            guard let symbol = resolve(module: module, name: name) else { continue }
            switch symbol {
            case .module:
                list.append(InferredMember(name: name, kind: .submodule, rank: 0, detail: nil))
            case .class:
                list.append(InferredMember(name: name, kind: .class, rank: 0, detail: nil))
            case .function(_, let f):
                list.append(InferredMember(name: name, kind: .function, rank: 0,
                                           detail: f.overloads.first.map { Self.signatureText($0, dropFirst: false, bindings: [:]) }))
            case .variable(_, let v):
                list.append(InferredMember(name: name, kind: .variable, rank: 0, detail: v.type))
            case .alias:
                list.append(InferredMember(name: name, kind: .class, rank: 0, detail: nil))
            case .typeVar:
                continue
            }
        }
        members.insert(list, for: key, cost: 64 + list.reduce(0) { $0 + $1.approximateBytes })
        return list
    }

    // MARK: - Summaries

    /// Summary of a table member: a method's first overload (without `self`
    /// / `cls`), a field's or property's type.
    static func detail(_ m: TypeTable.Member, bindings: [String: String]) -> String? {
        switch m.kind {
        case .method, .classMethod, .staticMethod:
            // The general overload: `self` not narrowed by an annotation
            // (`str.upper`'s `self: LiteralString` variant comes first).
            let general = m.kind == .staticMethod ? nil : m.overloads.first { $0.parameters.first?.type == nil }
            guard let sig = general ?? m.overloads.first else { return nil }
            return signatureText(sig, dropFirst: m.kind != .staticMethod, bindings: bindings)
        case .property, .field:
            return m.type.map { substituted($0, bindings) }
        }
    }

    /// `(a: T, *args: U, key: V = ...) -> R` from a table signature.
    static func signatureText(_ sig: TypeTable.Signature, dropFirst: Bool, bindings: [String: String]) -> String {
        var params = sig.parameters
        if dropFirst, let first = params.first, first.kind != .variadic, first.kind != .keywordVariadic {
            params.removeFirst()
        }
        var parts: [String] = []
        var starred = false
        for p in params {
            var text: String
            switch p.kind {
            case .variadic:
                text = "*" + p.name
                starred = true
            case .keywordVariadic:
                text = "**" + p.name
            case .keywordOnly:
                if !starred { parts.append("*"); starred = true }
                text = p.name
            default:
                text = p.name
            }
            if let type = p.type { text += ": " + substituted(type, bindings) }
            if p.hasDefault { text += " = ..." }
            parts.append(text)
        }
        var out = "(" + parts.joined(separator: ", ") + ")"
        if let r = sig.returnType { out += " -> " + substituted(r, bindings) }
        return out
    }

    /// `text` with type-variable names replaced (`_T` → `str`).
    static func substituted(_ text: String, _ bindings: [String: String]) -> String {
        guard !bindings.isEmpty, bindings.keys.contains(where: { text.contains($0) }),
              let expr = TypeExpr.parse(text, syntax: .python) else { return text }
        return PythonTypeConverter.text(expr, replacing: bindings)
    }
}

/// Converts a Python `TypeExpr` to an `InferredType`, resolving names
/// through `resolve` (the value a dotted name denotes in the scope: a stub
/// module's or the document's).
@MainActor
struct PythonTypeConverter {
    let resolve: @MainActor (String) -> InferredType
    private var depth = 0

    init(resolve: @escaping @MainActor (String) -> InferredType) {
        self.resolve = resolve
    }

    /// The type a value denotes in a type position (`int` → instance of int).
    static func asType(_ value: InferredType) -> InferredType {
        switch value {
        case .classObject(let ref, let args): return .instance(ref, args)
        case .typeForm(let t): return t
        case .none: return .none
        case .special(let name):
            switch name {
            case "LiteralString": return .instance(.table("builtins", "str"), [])
            case "Never", "NoReturn": return .never
            case "Self": return .typeVar("Self", bound: nil)
            case "Tuple": return .instance(.table("builtins", "tuple"), [])
            case "Type": return .classObject(.table("builtins", "object"), [])
            case "Callable": return .callable(CallableRef(.signature(InferredSignature(parameters: [], returnType: .unknown,
                                                                                         acceptsAnyArguments: true))))
            default: return .unknown
            }
        case .anyOf(let parts): return .union(parts.map(asType))
        default: return .unknown
        }
    }

    mutating func type(_ expr: TypeExpr) -> InferredType {
        depth += 1
        defer { depth -= 1 }
        guard depth < 24 else { return .unknown }
        switch expr {
        case .name(let n):
            if n == "None" { return .none }
            return Self.asType(resolve(n))
        case .generic(let base, let args):
            guard case .name(let n) = base else { return .unknown }
            return applied(resolve(n), args)
        case .union(let parts):
            return .union(parts.map { type($0) })
        case .function(let fn):
            let params = fn.parameters.map {
                InferredParameter(name: $0.name, kind: .positionalOnly, type: $0.type.map { type($0) }, hasDefault: false)
            }
            return .callable(CallableRef(.signature(InferredSignature(parameters: params, returnType: type(fn.returnType),
                                                                      acceptsAnyArguments: fn.acceptsAnyArguments
                                                                        || fn.parameterSpec != nil))))
        case .literal(let text):
            // A quoted forward reference.
            guard let inner = Self.unquoted(text), let parsed = TypeExpr.parse(inner, syntax: .python) else { return .unknown }
            return type(parsed)
        default:
            return .unknown
        }
    }

    /// `base[args]` for the value `base` denotes.
    mutating func applied(_ base: InferredType, _ args: [TypeExpr]) -> InferredType {
        switch base {
        case .special(let name):
            switch name {
            case "Optional": return args.count == 1 ? .union([type(args[0]), .none]) : .unknown
            case "Union": return .union(args.map { type($0) })
            case "Literal": return .union(args.map { literal($0) })
            case "ClassVar", "Final", "Annotated", "Required", "NotRequired", "ReadOnly":
                return args.first.map { type($0) } ?? .unknown
            case "TypeGuard", "TypeIs": return .instance(.table("builtins", "bool"), [])
            case "Type": return args.first.map { classObject(of: type($0)) } ?? .unknown
            case "Tuple": return tuple(args)
            default: return .unknown
            }
        case .classObject(let ref, _):
            if ref == .table("builtins", "type") { return args.first.map { classObject(of: type($0)) } ?? .unknown }
            if ref == .table("builtins", "tuple") { return tuple(args) }
            return .instance(ref, args.map { type($0) })
        case .typeForm(let t):
            // A generic alias: its type variables in order of appearance.
            let names = Self.typeVarNames(t)
            var bindings: [String: InferredType] = [:]
            for (i, n) in names.enumerated() where i < args.count { bindings[n] = type(args[i]) }
            return t.substituting(bindings)
        default:
            return .unknown
        }
    }

    private mutating func tuple(_ args: [TypeExpr]) -> InferredType {
        // `tuple[int, ...]` is homogeneous: one argument.
        let items = args.filter { if case .ellipsis = $0 { return false }; return true }
        return .instance(.table("builtins", "tuple"), items.map { type($0) })
    }

    private func classObject(of t: InferredType) -> InferredType {
        switch t {
        case .instance(let ref, let args): return .classObject(ref, args)
        case .anyOf(let parts): return .union(parts.map(classObject(of:)))
        default: return .unknown
        }
    }

    private mutating func literal(_ e: TypeExpr) -> InferredType {
        switch e {
        case .literal(let text):
            if text.hasPrefix("b'") || text.hasPrefix("b\"") || text.hasPrefix("B") { return .literal(.table("builtins", "bytes"), text) }
            if text.hasPrefix("'") || text.hasPrefix("\"") { return .literal(.table("builtins", "str"), text) }
            if text.contains(".") { return .instance(.table("builtins", "float"), []) }
            return .literal(.table("builtins", "int"), text)
        case .name(let n):
            if n == "True" || n == "False" { return .literal(.table("builtins", "bool"), n) }
            if n == "None" { return .none }
            // An enum member (`Color.RED`): an instance of the enum class.
            let parts = n.split(separator: ".")
            if parts.count >= 2, case .classObject(let ref, _) = resolve(parts.dropLast().joined(separator: ".")) {
                return .instance(ref, [])
            }
            return .unknown
        case .union(let parts): return .union(parts.map { literal($0) })
        default: return .unknown
        }
    }

    static func unquoted(_ text: String) -> String? {
        guard text.count >= 2, let first = text.first, first == "'" || first == "\"", text.last == first else { return nil }
        var inner = String(text.dropFirst().dropLast())
        if inner.hasPrefix("\"\""), inner.hasSuffix("\"\""), inner.count >= 4 { inner = String(inner.dropFirst(2).dropLast(2)) }
        return inner
    }

    static func typeVarNames(_ t: InferredType) -> [String] {
        var out: [String] = []
        func walk(_ t: InferredType) {
            switch t {
            case .typeVar(let n, _): if !out.contains(n) { out.append(n) }
            case .instance(_, let args), .classObject(_, let args): args.forEach(walk)
            case .anyOf(let parts): parts.forEach(walk)
            case .typeForm(let inner): walk(inner)
            default: break
            }
        }
        walk(t)
        return out
    }

    /// Python text of `expr`, names in `replacing` substituted.
    static func text(_ expr: TypeExpr, replacing: [String: String] = [:]) -> String {
        switch expr {
        case .name(let n):
            if let r = replacing[n] { return r }
            if n.hasPrefix("typing"), let dot = n.lastIndex(of: "."), let r = replacing[String(n[n.index(after: dot)...])] {
                return r
            }
            return n
        case .generic(let base, let args):
            return text(base, replacing: replacing) + "[" + args.map { text($0, replacing: replacing) }.joined(separator: ", ") + "]"
        case .union(let parts): return parts.map { text($0, replacing: replacing) }.joined(separator: " | ")
        case .function(let fn):
            let ret = text(fn.returnType, replacing: replacing)
            if fn.acceptsAnyArguments { return "Callable[..., \(ret)]" }
            if let spec = fn.parameterSpec { return "Callable[\(text(spec, replacing: replacing)), \(ret)]" }
            let params = fn.parameters.map { $0.type.map { text($0, replacing: replacing) } ?? "Any" }
            return "Callable[[" + params.joined(separator: ", ") + "], \(ret)]"
        case .list(let items): return "[" + items.map { text($0, replacing: replacing) }.joined(separator: ", ") + "]"
        case .literal(let t): return t
        case .ellipsis: return "..."
        case .unpacked(let t): return "*" + text(t, replacing: replacing)
        case .opaque(_, let t): return t
        case .array(let t): return text(t, replacing: replacing) + "[]"
        case .intersection(let parts): return parts.map { text($0, replacing: replacing) }.joined(separator: " & ")
        case .tuple, .object, .indexed: return "…"
        }
    }
}
