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
/// Where a TypeScript type text or symbol name is resolved: a lib section,
/// or (T17.13) an imported module with the namespace a declaration sits in.
enum ScriptScope: Hashable {
    case es, dom
    case module(String, namespace: String)

    init(_ section: TSGlobalSymbol.Section) { self = section == .es ? .es : .dom }

    var cacheName: String {
        switch self {
        case .es: return "es"
        case .dom: return "dom"
        case .module(let key, let ns): return key + "\u{2}" + ns
        }
    }
}

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
        let section: ScriptScope
        /// A `class` declaration (imported modules: static members are its
        /// `classLevel` members, not a constructor interface's).
        let isClass: Bool
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

    /// Imported modules (M17 T17.13): overlay modules named `§…`.
    weak var importSource: ImportService?

    nonisolated static func isModuleKey(_ name: String) -> Bool { name.hasPrefix("§") }

    /// Drops derived values that mention imported modules (summaries changed).
    func dropImported() {
        types.removeAll { Self.isModuleKey($0) }
        members.removeAll { $0.owner.mentionsImport || ($0.selfType?.mentionsImport ?? false) }
        classes.removeAll { if case .table(let m) = $0.origin { return Self.isModuleKey(m) }; return false }
    }

    var isReleased: Bool { types.isEmpty && members.isEmpty && classes.isEmpty }

    var retainedBytes: Int { types.bytes + members.bytes + classes.bytes }

    // MARK: - Sections

    static func sectionName(_ s: TSGlobalSymbol.Section) -> String { s == .es ? "es" : "dom" }

    /// The scope of a table class: a lib section or an imported module (nil
    /// for document classes).
    static func section(of ref: ClassRef) -> ScriptScope? {
        switch ref.origin {
        case .table("es"): return .es
        case .table("dom"): return .dom
        case .table(let m) where isModuleKey(m): return .module(m, namespace: namespacePrefix(ref.name))
        default: return nil
        }
    }

    /// `ns.sub` of `ns.sub.Name` ("" for a top-level name).
    nonisolated static func namespacePrefix(_ qualified: String) -> String {
        guard let dot = qualified.lastIndex(of: ".") else { return "" }
        return String(qualified[..<dot])
    }

    /// Symbol `name` of one scope.
    func symbol(_ name: String, in scope: ScriptScope) -> TSGlobalSymbol? {
        switch scope {
        case .es: return store.tsSymbol(name, in: .es)
        case .dom: return store.tsSymbol(name, in: .dom)
        case .module(let key, _): return importSource?.scriptModule(key)?.symbols[name]
        }
    }

    /// The scope of a table function (`tableFunction(module:name:)`).
    static func functionScope(module: String, name: String) -> ScriptScope {
        if isModuleKey(module) { return .module(module, namespace: namespacePrefix(name)) }
        return module == "dom" ? .dom : .es
    }

    /// Lib symbol `name`: ES first, DOM only when `allowDOM`.
    func symbol(_ name: String, allowDOM: Bool) -> TSGlobalSymbol? {
        store.tsSymbol(name, includeDOM: allowDOM)
    }

    // MARK: - Type texts

    /// Lib type `text` converted in `section`'s scope (cached); `typeParams`
    /// are the type parameters in scope (left as `.typeVar`).
    func type(text: String, section: ScriptScope, typeParams: [String] = []) -> InferredType {
        let key = section.cacheName + "\u{0}" + typeParams.joined(separator: ",") + "\u{0}" + text
        if let cached = types.value(for: key) { return cached }
        var converted = InferredType.unknown
        if let expr = TypeExpr.parse(text, syntax: .typescript) {
            var params: [String: InferredType?] = [:]
            for p in typeParams { params[p] = .some(nil) }
            var converter = ScriptTypeConverter(typeParams: params) { [unowned self] name, args in
                switch section {
                case .es, .dom: return self.resolve(name, args, allowDOM: section == .dom)
                case .module(let key, let ns): return self.moduleType(key, namespace: ns, name, args, hops: 0)
                }
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
            let body = type(text: alias.type, section: ScriptScope(symbol.section), typeParams: params)
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
        guard let symbol = symbol(ref.name, in: section), let decl = symbol.interface else { return nil }
        let params = decl.typeParameters.map(\.name)
        var bases: [InferredType] = []
        for text in decl.bases {
            let base = type(text: text, section: section, typeParams: params)
            if case .instance = base { bases.append(base) }
        }
        var ctor: String?
        if let v = symbol.variable, let t = v.type, t != ref.name, t != ref.shortName { ctor = t }
        let info = ClassInfo(decl: decl, section: section, isClass: symbol.isClass, typeParameters: params, bases: bases,
                             constructorType: ctor)
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
            return type(text: t, section: ScriptScope(symbol.section))
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

    // MARK: - Imported modules (T17.13)

    /// `.module` names of imported modules: `§k:/path` (the module object) or
    /// `§k:/path` + U+0002 + `ns.sub` (a namespace declared in it).
    nonisolated static func splitModuleValue(_ name: String) -> (key: String, namespace: String) {
        guard let sep = name.firstIndex(of: "\u{2}") else { return (name, "") }
        return (String(name[..<sep]), String(name[name.index(after: sep)...]))
    }

    private func summary(_ key: String) -> ScriptModuleSummary? { importSource?.scriptModule(key) }

    private static func qualified(_ namespace: String, _ name: String) -> String {
        namespace.isEmpty ? name : namespace + "." + name
    }

    /// The value module-level (possibly qualified) name `q` of module `key` denotes.
    func moduleLocalValue(_ key: String, _ q: String, hops: Int) -> InferredType {
        guard hops <= ImportService.reexportDepth, let s = summary(key) else { return .unknown }
        if let symbol = s.symbols[q] {
            if symbol.interface != nil {
                if symbol.isClass { return .classObject(.table(key, q), []) }
                if let v = symbol.variable {
                    let short = q.split(separator: ".").last.map(String.init) ?? q
                    return v.type == short || v.type == q ? .instance(.table(key, q), []) : .classObject(.table(key, q), [])
                }
            }
            if symbol.function != nil { return .callable(CallableRef(.tableFunction(module: key, name: q))) }
            if let v = symbol.variable {
                return v.type.map { type(text: $0, section: .module(key, namespace: Self.namespacePrefix(q))) } ?? .unknown
            }
            if symbol.namespaceMembers != nil { return .module(key + "\u{2}" + q) }
            return .unknown
        }
        if !q.contains("."), let binding = s.imports[q] { return bindingValue(binding, hops: hops + 1) }
        return .unknown
    }

    func bindingValue(_ binding: ScriptModuleSummary.Binding, hops: Int) -> InferredType {
        switch binding {
        case .named(let m, let n): return moduleExportValue(m, n, hops: hops)
        case .default(let m): return moduleDefaultValue(m, hops: hops)
        case .namespace(let m): return moduleNamespaceValue(m, hops: hops)
        }
    }

    /// Export `name` of module `key` as a value.
    func moduleExportValue(_ key: String, _ name: String, hops: Int = 0) -> InferredType {
        if name == "default" { return moduleDefaultValue(key, hops: hops) }
        guard hops <= ImportService.reexportDepth, let s = summary(key) else { return .unknown }
        if let e = s.exports[name] {
            switch e {
            case .local(let n): return moduleLocalValue(key, n, hops: hops)
            case .reexport(let m, let n): return moduleExportValue(m, n, hops: hops + 1)
            case .namespace(let m): return moduleNamespaceValue(m, hops: hops + 1)
            }
        }
        for star in s.starExports {
            let v = moduleExportValue(star, name, hops: hops + 1)
            if v != .unknown { return v }
        }
        if let ea = s.exportAssignment, s.symbols[ea]?.namespaceMembers != nil {
            return moduleLocalValue(key, ea + "." + name, hops: hops)
        }
        return .unknown
    }

    /// `import x from 'm'`: the default export, else `export =` / `module.exports`.
    func moduleDefaultValue(_ key: String, hops: Int = 0) -> InferredType {
        guard hops <= ImportService.reexportDepth, let s = summary(key) else { return .unknown }
        if let e = s.exports["default"] {
            switch e {
            case .local(let n): return moduleLocalValue(key, n, hops: hops)
            case .reexport(let m, let n): return moduleExportValue(m, n, hops: hops + 1)
            case .namespace(let m): return moduleNamespaceValue(m, hops: hops + 1)
            }
        }
        if let ea = s.exportAssignment { return moduleLocalValue(key, ea, hops: hops) }
        return .unknown
    }

    /// `import * as x from 'm'` / `require('m')`: the module object, or the
    /// `export =` value.
    func moduleNamespaceValue(_ key: String, hops: Int = 0) -> InferredType {
        guard hops <= ImportService.reexportDepth, let s = summary(key) else { return .unknown }
        if let ea = s.exportAssignment, s.exports.isEmpty { return moduleLocalValue(key, ea, hops: hops) }
        return .module(key)
    }

    /// `ns.name` for a module object / namespace value `.module(moduleName)`.
    func moduleMemberValue(_ moduleName: String, _ name: String) -> InferredType {
        let (key, ns) = Self.splitModuleValue(moduleName)
        if ns.isEmpty { return moduleExportValue(key, name) }
        guard let members = summary(key)?.symbols[ns]?.namespaceMembers, members.contains(name) else { return .unknown }
        return moduleLocalValue(key, ns + "." + name, hops: 0)
    }

    /// The declaration export `name` of `key` resolves to.
    private func exportedSymbol(_ key: String, _ name: String, hops: Int) -> (key: String, q: String, symbol: TSGlobalSymbol)? {
        guard hops <= ImportService.reexportDepth, let s = summary(key) else { return nil }
        if let e = s.exports[name] {
            switch e {
            case .local(let n):
                if let symbol = s.symbols[n] { return (key, n, symbol) }
                if let binding = s.imports[n] {
                    switch binding {
                    case .named(let m, let n2): return exportedSymbol(m, n2, hops: hops + 1)
                    case .default(let m): return exportedSymbol(m, "default", hops: hops + 1)
                    case .namespace: return nil
                    }
                }
                return nil
            case .reexport(let m, let n): return exportedSymbol(m, n, hops: hops + 1)
            case .namespace: return nil
            }
        }
        for star in s.starExports where name != "default" {
            if let found = exportedSymbol(star, name, hops: hops + 1) { return found }
        }
        return nil
    }

    /// The members of `.module(moduleName)`: a module's exports or a namespace's members.
    func moduleMembers(_ moduleName: String) -> [InferredMember] {
        let ownerKey = MemberKey(owner: .module(moduleName), selfType: nil, instance: false)
        if let cached = members.value(for: ownerKey) { return cached }
        let list = moduleMembers(moduleName, hops: 0)
        members.insert(list, for: ownerKey, cost: 64 + list.reduce(0) { $0 + $1.approximateBytes })
        return list
    }

    private func moduleMembers(_ moduleName: String, hops: Int) -> [InferredMember] {
        let (key, ns) = Self.splitModuleValue(moduleName)
        guard hops <= ImportService.reexportDepth, let s = summary(key) else { return [] }
        var list: [InferredMember] = []
        var seen = Set<String>()
        func add(_ name: String, _ symbol: TSGlobalSymbol?, kind: InferredMemberKind? = nil) {
            guard !seen.contains(name) else { return }
            if let symbol {
                // A value position: interfaces and type aliases are not listed.
                let typeOnly = !symbol.isClass && symbol.variable == nil && symbol.function == nil
                    && symbol.namespaceMembers == nil
                if typeOnly { return }
                seen.insert(name)
                var detail: String?
                if let f = symbol.function?.overloads.first { detail = Self.signatureText(f, bindings: [:]) }
                else if symbol.interface == nil, let t = symbol.variable?.type { detail = t }
                list.append(InferredMember(name: name, kind: ScriptModuleSummary.kind(of: symbol), rank: 0, detail: detail))
            } else {
                seen.insert(name)
                list.append(InferredMember(name: name, kind: kind ?? .variable, rank: 0, detail: nil))
            }
        }
        if !ns.isEmpty {
            for n in s.symbols[ns]?.namespaceMembers ?? [] { add(n, s.symbols[ns + "." + n]) }
        } else if let kinds = s.namesOnly {
            for n in kinds.keys.sorted() where n != "default" { add(n, nil, kind: kinds[n]) }
        } else {
            for n in s.exports.keys.sorted() where n != "default" {
                if case .namespace? = s.exports[n] { add(n, nil, kind: .submodule); continue }
                let found = exportedSymbol(key, n, hops: 0)
                // A name whose declaration is not loaded yet is still listed (it is exported).
                add(n, found?.symbol, kind: found == nil ? .variable : nil)
            }
            for star in s.starExports {
                for m in moduleMembers(star, hops: hops + 1) where seen.insert(m.name).inserted {
                    list.append(m)
                }
            }
            if s.exports.isEmpty, let ea = s.exportAssignment, let names = s.symbols[ea]?.namespaceMembers {
                for n in names { add(n, s.symbols[ea + "." + n]) }
            }
        }
        return list
    }

    /// Type name `name` in module `key`'s scope (inside namespace `namespace`):
    /// its declarations (innermost namespace first), its imports, then the lib.
    func moduleType(_ key: String, namespace: String, _ name: String, _ args: [InferredType], hops: Int) -> InferredType {
        guard hops <= ImportService.reexportDepth, let s = summary(key) else {
            return resolve(name, args, allowDOM: true)
        }
        var prefix: String? = namespace
        while let p = prefix {
            let q = Self.qualified(p, name)
            if let symbol = s.symbols[q] { return typeOfSymbol(key, q, symbol, args) }
            prefix = p.isEmpty ? nil : Self.namespacePrefix(p)
        }
        let head = String(name.prefix { $0 != "." })
        if let binding = s.imports[head] {
            let rest = name.count > head.count ? String(name.dropFirst(head.count + 1)) : ""
            switch binding {
            case .named(let m, let n):
                return moduleExportType(m, rest.isEmpty ? n : n + "." + rest, args, hops: hops + 1)
            case .default(let m):
                return rest.isEmpty ? moduleExportType(m, "default", args, hops: hops + 1) : .unknown
            case .namespace(let m):
                return rest.isEmpty ? .unknown : moduleExportType(m, rest, args, hops: hops + 1)
            }
        }
        return resolve(name, args, allowDOM: true)
    }

    /// Export `name` of module `key` used as a type.
    func moduleExportType(_ key: String, _ name: String, _ args: [InferredType], hops: Int = 0) -> InferredType {
        guard hops <= ImportService.reexportDepth, let s = summary(key) else { return .unknown }
        let head = String(name.prefix { $0 != "." })
        let rest = name.count > head.count ? String(name.dropFirst(head.count + 1)) : ""
        if let e = s.exports[head] {
            switch e {
            case .local(let n):
                return moduleType(key, namespace: "", rest.isEmpty ? n : n + "." + rest, args, hops: hops)
            case .reexport(let m, let n):
                return moduleExportType(m, rest.isEmpty ? n : n + "." + rest, args, hops: hops + 1)
            case .namespace(let m):
                return rest.isEmpty ? .unknown : moduleExportType(m, rest, args, hops: hops + 1)
            }
        }
        if head == "default" { return s.exportAssignment.map { moduleType(key, namespace: "", $0, args, hops: hops) } ?? .unknown }
        for star in s.starExports {
            let t = moduleExportType(star, name, args, hops: hops + 1)
            if t != .unknown { return t }
        }
        if let ea = s.exportAssignment, s.symbols[ea]?.namespaceMembers != nil {
            return moduleType(key, namespace: ea, name, args, hops: hops)
        }
        return .unknown
    }

    private func typeOfSymbol(_ key: String, _ q: String, _ symbol: TSGlobalSymbol, _ args: [InferredType]) -> InferredType {
        if let iface = symbol.interface {
            var a = args
            if a.count > iface.typeParameters.count { a = Array(a.prefix(iface.typeParameters.count)) }
            return .instance(.table(key, q), a)
        }
        if let alias = symbol.alias {
            guard aliasDepth < 8 else { return .unknown }
            aliasDepth += 1
            defer { aliasDepth -= 1 }
            let params = alias.typeParameters.map(\.name)
            let body = type(text: alias.type, section: .module(key, namespace: Self.namespacePrefix(q)), typeParams: params)
            var bindings: [String: InferredType] = [:]
            for (i, p) in params.enumerated() { bindings[p] = i < args.count ? args[i] : .unknown }
            return body.substituting(bindings)
        }
        return .unknown
    }

    /// Static members of an imported `class` (its `classLevel` members).
    func staticMembers(_ ref: ClassRef) -> [InferredMember]? {
        guard let info = classInfo(ref), info.isClass else { return nil }
        return info.decl.members.filter { $0.flags.contains(.classLevel) }.map {
            InferredMember(name: $0.name, kind: Self.kind($0.kind), rank: 0, detail: Self.detail($0, bindings: [:]))
        }
    }

    /// Static member `name` of an imported `class`.
    func staticMemberType(_ ref: ClassRef, _ name: String) -> InferredType? {
        guard let info = classInfo(ref), info.isClass else { return nil }
        guard let m = info.decl.member(named: name), m.flags.contains(.classLevel) else { return .unknown }
        switch m.kind {
        case .method, .classMethod, .staticMethod:
            return .callable(CallableRef(.tableMember(owner: ref, name: name), receiver: .classObject(ref, [])))
        case .property, .field:
            return m.type.map { type(text: $0, section: info.section, typeParams: info.typeParameters) } ?? .unknown
        }
    }

    // MARK: - Summaries

    /// A lib member's summary: a method's first overload, a property's type.
    nonisolated static func detail(_ m: TypeTable.Member, bindings: [String: String]) -> String? {
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
    nonisolated static func signatureText(_ sig: TypeTable.Signature, bindings: [String: String]) -> String {
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
