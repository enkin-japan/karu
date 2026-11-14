import Foundation

/// The TypeScript-lib side of the built-in type tables for inference (M17
/// T17.11c), the counterpart of `PythonTypeTables` over
/// `TypeTableStore.tsSymbol`: lib globals as values, lib type texts
/// converted to `InferredType`, interfaces' bases and type parameters, and
/// member lists with TypeScript-syntax signature summaries.
///
/// **DOM laziness (plan §8.1).** The ES section is always searched first;
/// the DOM section only when a name is not an ES symbol and the lookup
/// allows it — a document name (`fetch`, `HTMLElement`, `document`) or a
/// type text of a DOM symbol. Type texts of ES symbols resolve within ES
/// only, so a document that references only ES globals never reads the DOM
/// section.
///
/// Process-wide (`shared`), main-actor only; derived values live in
/// byte-capped LRUs and are dropped by `release()` (with the store's decoded
/// entries) when the completion or type-inference module is switched off.
@MainActor
final class ScriptTypeTables {
    static let shared = ScriptTypeTables(store: .shared)

    nonisolated static let typeCacheBytes = 512 * 1024
    nonisolated static let memberCacheBytes = 1024 * 1024

    let store: TypeTableStore
    private let types: ByteLRU<String, InferredType>
    private let members: ByteLRU<MemberKey, [InferredMember]>
    private let classes: ByteLRU<ClassRef, ClassInfo>

    private struct MemberKey: Hashable {
        let owner: InferredType
        let selfType: InferredType?
        let instance: Bool
    }

    /// A lib interface's own facts.
    struct ClassInfo {
        let decl: TypeTable.ClassDecl
        let section: TSGlobalSymbol.Section
        let typeParameters: [String]
        /// `extends` types as instances whose arguments refer to `typeParameters`.
        let bases: [InferredType]
        /// The `declare var Name: NameConstructor` type text when the symbol
        /// is a class-like global (`Array`, `Map`, `Promise`, `Error` …).
        let constructorType: String?
        var bytes: Int { 256 + decl.members.count * 96 + bases.reduce(0) { $0 + $1.approximateBytes } }
    }

    init(store: TypeTableStore, typeCacheBytes: Int = ScriptTypeTables.typeCacheBytes,
         memberCacheBytes: Int = ScriptTypeTables.memberCacheBytes) {
        self.store = store
        types = ByteLRU(byteLimit: typeCacheBytes, countLimit: 8_192)
        members = ByteLRU(byteLimit: memberCacheBytes, countLimit: 1_024)
        classes = ByteLRU(byteLimit: memberCacheBytes / 2, countLimit: 1_024)
    }

    func release() {
        types.removeAll()
        members.removeAll()
        classes.removeAll()
        store.release()
    }

    var isReleased: Bool { types.isEmpty && members.isEmpty && classes.isEmpty }

    var retainedBytes: Int { types.bytes + members.bytes + classes.bytes }

    // MARK: - Sections

    static func sectionName(_ s: TSGlobalSymbol.Section) -> String { s == .es ? "es" : "dom" }

    static func section(of ref: ClassRef) -> TSGlobalSymbol.Section? {
        switch ref.origin {
        case .table("es"): return .es
        case .table("dom"): return .dom
        default: return nil
        }
    }

    /// Lib symbol `name`: ES first, DOM only when `allowDOM`.
    func symbol(_ name: String, allowDOM: Bool) -> TSGlobalSymbol? {
        store.tsSymbol(name, includeDOM: allowDOM)
    }

    // MARK: - Type texts

    /// Lib type `text` converted in `section`'s scope (cached); `typeParams`
    /// are the type parameters in scope (left as `.typeVar`).
    func type(text: String, section: TSGlobalSymbol.Section, typeParams: [String] = []) -> InferredType {
        let key = Self.sectionName(section) + "\u{0}" + typeParams.joined(separator: ",") + "\u{0}" + text
        if let cached = types.value(for: key) { return cached }
        var converted = InferredType.unknown
        if let expr = TypeExpr.parse(text, syntax: .typescript) {
            var params: [String: InferredType?] = [:]
            for p in typeParams { params[p] = .some(nil) }
            var converter = ScriptTypeConverter(typeParams: params) { [unowned self] name, args in
                self.resolve(name, args, allowDOM: section == .dom)
            }
            converted = converter.type(expr)
        }
        types.insert(converted, for: key, cost: 48 + key.utf8.count + converted.approximateBytes)
        return converted
    }

    private var aliasDepth = 0

    /// A lib type name with converted arguments (utility types included).
    func resolve(_ name: String, _ args: [InferredType], allowDOM: Bool) -> InferredType {
        switch name {
        case "Partial", "Required", "Readonly", "NoInfer":
            return args.first ?? .unknown
        case "NonNullable":
            return args.first?.withoutNone ?? .unknown
        case "Record":
            return args.count == 2 ? .shape(ObjectShape(indexValue: args[1])) : .unknown
        case "Awaited":
            return args.first.map(Self.awaited) ?? .unknown
        case "ReadonlyArray":
            return .instance(ScriptTypes.readonlyArray, args.isEmpty ? [.unknown] : args)
        default:
            break
        }
        guard let symbol = symbol(name, allowDOM: allowDOM) else { return .unknown }
        if let iface = symbol.interface {
            var a = args
            if a.count > iface.typeParameters.count { a = Array(a.prefix(iface.typeParameters.count)) }
            return .instance(.table(Self.sectionName(symbol.section), name), a)
        }
        if let alias = symbol.alias {
            guard aliasDepth < 8 else { return .unknown }
            aliasDepth += 1
            defer { aliasDepth -= 1 }
            let params = alias.typeParameters.map(\.name)
            let body = type(text: alias.type, section: symbol.section, typeParams: params)
            var bindings: [String: InferredType] = [:]
            for (i, p) in params.enumerated() { bindings[p] = i < args.count ? args[i] : .unknown }
            return body.substituting(bindings)
        }
        return .unknown
    }

    /// `T` of `Promise<T>` / `PromiseLike<T>` (structurally, without bases).
    static func awaited(_ t: InferredType) -> InferredType {
        switch t {
        case .instance(let ref, let args) where ref == ScriptTypes.promise || ref == ScriptTypes.promiseLike:
            return args.first.map(awaited) ?? .unknown
        case .anyOf(let parts): return .union(parts.map(awaited))
        default: return t
        }
    }

    // MARK: - Classes

    func classInfo(_ ref: ClassRef) -> ClassInfo? {
        guard let section = Self.section(of: ref), ref != ScriptTypes.tuple else { return nil }
        if let cached = classes.value(for: ref) { return cached }
        guard let symbol = store.tsSymbol(ref.name, in: section), let decl = symbol.interface else { return nil }
        let params = decl.typeParameters.map(\.name)
        var bases: [InferredType] = []
        for text in decl.bases {
            let base = type(text: text, section: section, typeParams: params)
            if case .instance = base { bases.append(base) }
        }
        var ctor: String?
        if let v = symbol.variable, let t = v.type, t != ref.name { ctor = t }
        let info = ClassInfo(decl: decl, section: section, typeParameters: params, bases: bases, constructorType: ctor)
        classes.insert(info, for: ref, cost: info.bytes)
        return info
    }

    /// The constructor interface of class-like global `ref` (`ArrayConstructor`).
    func constructorType(of ref: ClassRef) -> InferredType {
        guard let info = classInfo(ref), let text = info.constructorType else { return .unknown }
        return type(text: text, section: info.section)
    }

    /// Own members of lib interface `ref` (rank 0) with summaries for its
    /// arguments `args`: the instance view drops static members and
    /// symbol-keyed ones (`[Symbol.iterator]`).
    func ownMembers(_ ref: ClassRef, args: [InferredType], selfType: InferredType) -> [InferredMember] {
        let key = MemberKey(owner: .instance(ref, args), selfType: selfType, instance: true)
        if let cached = members.value(for: key) { return cached }
        guard let info = classInfo(ref) else { return [] }
        var bindings: [String: String] = [:]
        for (i, p) in info.typeParameters.enumerated() where i < args.count && args[i] != .unknown {
            bindings[p] = args[i].tsDescription
        }
        bindings["this"] = selfType.tsDescription
        var list: [InferredMember] = []
        for m in info.decl.members where !m.name.hasPrefix("[") && !m.flags.contains(.classLevel) {
            // Deprecated members (`trimLeft`, `substr`) rank after the others,
            // as the TypeScript language service sorts them.
            let rank = m.flags.contains(.deprecated) ? Self.deprecatedRank : 0
            list.append(InferredMember(name: m.name, kind: Self.kind(m.kind), rank: rank, detail: Self.detail(m, bindings: bindings)))
        }
        members.insert(list, for: key, cost: 64 + list.reduce(0) { $0 + $1.approximateBytes })
        return list
    }

    /// Rank offset of deprecated lib members (after every inherited level).
    static let deprecatedRank = 500

    static func kind(_ k: TypeTable.Member.Kind) -> InferredMemberKind {
        switch k {
        case .method, .classMethod, .staticMethod: return .method
        case .property: return .property
        case .field: return .field
        }
    }

    // MARK: - Values

    /// The value lib global `name` denotes: a class-like global's class
    /// object, a value object (`JSON`, `Math`, `console`), a function, a
    /// namespace (`.module`).
    func globalValue(_ name: String, allowDOM: Bool) -> InferredType {
        guard let symbol = symbol(name, allowDOM: allowDOM) else { return .unknown }
        let sec = Self.sectionName(symbol.section)
        if let v = symbol.variable {
            if symbol.interface != nil {
                if v.type == name { return .instance(.table(sec, name), []) }
                return .classObject(.table(sec, name), [])
            }
            guard let t = v.type else { return .unknown }
            return type(text: t, section: symbol.section)
        }
        if symbol.isClass, symbol.interface != nil { return .classObject(.table(sec, name), []) }
        if symbol.function != nil { return .callable(CallableRef(.tableFunction(module: sec, name: name))) }
        if symbol.namespaceMembers != nil { return .module(name) }
        return .unknown
    }

    /// The members of lib namespace `name` (`Intl`).
    func namespaceMembers(_ name: String) -> [InferredMember] {
        let key = MemberKey(owner: .module(name), selfType: nil, instance: false)
        if let cached = members.value(for: key) { return cached }
        guard let symbol = store.tsSymbol(name), let names = symbol.namespaceMembers else { return [] }
        var list: [InferredMember] = []
        for n in names {
            guard let member = store.tsSymbol(name + "." + n, in: symbol.section) else { continue }
            let kind: InferredMemberKind
            if member.interface != nil, member.variable != nil || member.isClass { kind = .class }
            else if member.function != nil { kind = .function }
            else if member.namespaceMembers != nil { kind = .submodule }
            else if member.variable != nil { kind = .variable }
            else { continue }
            list.append(InferredMember(name: n, kind: kind, rank: 0, detail: member.variable?.type))
        }
        members.insert(list, for: key, cost: 64 + list.reduce(0) { $0 + $1.approximateBytes })
        return list
    }

    // MARK: - Summaries

    /// A lib member's summary: a method's first overload, a property's type.
    static func detail(_ m: TypeTable.Member, bindings: [String: String]) -> String? {
        switch m.kind {
        case .method, .classMethod, .staticMethod:
            return m.overloads.first.map { signatureText($0, bindings: bindings) }
        case .property, .field:
            return m.type.map { ScriptTypeText.substituted($0, bindings) }
        }
    }

    /// `(callbackfn: (value: string, …) => U, thisArg?: any) -> U[]`. When
    /// the whole text would not fit `InferredMemberList.detailLimit`,
    /// callback parameter lists keep their first parameter only, then
    /// callback return types become `…` (the shared shortening then drops
    /// trailing parameters, keeping the return type).
    static func signatureText(_ sig: TypeTable.Signature, bindings: [String: String]) -> String {
        func render(compact: Int) -> String {
            var parts: [String] = []
            for p in sig.parameters where p.name != "this" {
                var text = (p.kind == .variadic ? "..." : "") + p.name + (p.hasDefault && p.kind != .variadic ? "?" : "")
                if let type = p.type {
                    if compact > 0, let expr = TypeExpr.parse(type, syntax: .typescript) {
                        text += ": " + ScriptTypeText.compact(expr, replacing: bindings, elideReturn: compact > 1)
                    } else {
                        text += ": " + ScriptTypeText.substituted(type, bindings)
                    }
                }
                parts.append(text)
            }
            return "(" + parts.joined(separator: ", ") + ") -> "
                + (sig.returnType.map { ScriptTypeText.substituted($0, bindings) } ?? "void")
        }
        // The least compaction whose shortened form still shows the first
        // parameter.
        for level in 0..<2 {
            let text = render(compact: level)
            if !InferredMemberList.shortened(text).hasPrefix("(…") { return text }
        }
        return render(compact: 2)
    }
}
