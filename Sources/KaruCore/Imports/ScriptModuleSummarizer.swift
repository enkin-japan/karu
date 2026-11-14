import Foundation

// M17 T17.13 — a JS / TS module's export summary (plan §9 "结果形态"):
// declarations as the lib table's records (`TSGlobalSymbol`: merged
// interfaces / classes with members, functions with overloads, variables,
// type aliases, namespaces with qualified member names), the module's import
// bindings, its exports (local names, re-exports, `export *`, `export =` /
// `module.exports`). Produced on the import queue from the script parser's
// top-level statements; the tree is dropped afterwards. Types are the
// source's annotations (`.d.ts` are fully typed), JSDoc `@returns` / `@type`
// in JavaScript, and literal initialisers; anything else stays unknown.

struct ScriptModuleSummary: Sendable {
    enum Export: Sendable, Hashable {
        /// A declaration of this module (qualified for namespace members).
        case local(String)
        /// `export { a as b } from 'm'` (module key, its export name).
        case reexport(module: String, name: String)
        /// `export * as ns from 'm'`.
        case namespace(module: String)
    }

    enum Binding: Sendable, Hashable {
        /// `import { a } from 'm'`, `const { a } = require('m')`.
        case named(module: String, name: String)
        /// `import a from 'm'`.
        case `default`(module: String)
        /// `import * as a from 'm'`, `import a = require('m')`, `const a = require('m')`.
        case namespace(module: String)
    }

    let key: String
    var symbols: [String: TSGlobalSymbol] = [:]
    var imports: [String: Binding] = [:]
    var exports: [String: Export] = [:]
    /// `export * from 'm'` module keys, in order.
    var starExports: [String] = []
    /// `export = X` / `module.exports = X`: the local name it exports.
    var exportAssignment: String?
    /// Names only (over a size cap): the exported names and their kinds.
    var namesOnly: [String: InferredMemberKind]?
    /// Module keys this one imports or re-exports (loaded with it).
    var dependencies: [String] = []

    init(key: String) { self.key = key }

    /// The exported names (sorted), for listings.
    var exportedNames: [String] {
        if let namesOnly { return namesOnly.keys.sorted() }
        return exports.keys.sorted()
    }

    /// Reduced to names (LRU degradation, plan §11).
    func reducedToNames() -> ScriptModuleSummary {
        if namesOnly != nil { return self }
        var out = ScriptModuleSummary(key: key)
        var kinds: [String: InferredMemberKind] = [:]
        for (name, export) in exports {
            guard case .local(let local) = export, let symbol = symbols[local] else { kinds[name] = .variable; continue }
            kinds[name] = Self.kind(of: symbol)
        }
        // `export = ns` (`typescript.d.ts`): the namespace's members.
        if exports.isEmpty, let ea = exportAssignment, let members = symbols[ea]?.namespaceMembers {
            for name in members { kinds[name] = symbols[ea + "." + name].map(Self.kind(of:)) ?? .variable }
        }
        out.namesOnly = kinds
        return out
    }

    static func kind(of symbol: TSGlobalSymbol) -> InferredMemberKind {
        if symbol.isClass || (symbol.interface != nil && symbol.variable != nil) { return .class }
        if symbol.function != nil { return .function }
        if symbol.namespaceMembers != nil { return .submodule }
        if symbol.interface != nil || symbol.alias != nil { return .class }
        return .variable
    }
}

/// Where a script module sits and how to name the modules it imports.
struct ScriptSummaryContext {
    let key: String
    let path: String
    let dialect: SyntaxDialect
    /// A module key for a specifier imported from this file, or nil.
    let resolve: (String) -> String?
}

enum ScriptModuleSummarizer {
    static func summarize(_ text: NSString, context: ScriptSummaryContext, namesOnly: Bool) -> ScriptModuleSummary {
        var builder = ScriptSummaryBuilder(text: text, context: context)
        if namesOnly {
            return builder.names()
        }
        if SyntaxBuild.mode(forLength: text.length) == .tree {
            let unit = PyUnit(SyntaxBuild.parse(text, dialect: context.dialect))
            for i in unit.tree.topLevelStatements { builder.statement(PyNode(unit: unit, i: i), namespace: "", exported: false) }
        } else {
            var build = SyntaxBuild(dialect: context.dialect, text: text, mode: .summary)
            guard let summary = build.finish(text)?.summary else { return builder.result() }
            for index in summary.statements.indices {
                let tree = summary.parseStatement(index, in: text)
                guard tree.nodes.count >= 2 else { continue }
                let unit = PyUnit(tree)
                builder.statement(PyNode(unit: unit, i: tree.root - 1), namespace: "", exported: false)
            }
        }
        return builder.result()
    }
}

private struct ScriptSummaryBuilder {
    let text: NSString
    let context: ScriptSummaryContext
    var out: ScriptModuleSummary
    /// Interfaces / classes being merged (name → parts).
    private var classParts: [String: ClassParts] = [:]
    private var namespaceMembers: [String: [String]] = [:]
    private var functionOverloads: [String: [TypeTable.Signature]] = [:]
    /// Functions / methods with bodiless declarations (overloads, `.d.ts`).
    private var declaredOnly = Set<String>()
    private let ambient: Bool

    struct ClassParts {
        var isClass = false
        var typeParameters: [TypeTable.TypeParameter] = []
        var bases: [String] = []
        var members: [String: TypeTable.Member] = [:]
        var calls: [TypeTable.Signature] = []
        var constructs: [TypeTable.Signature] = []
        var indexes: [TypeTable.IndexSignature] = []
    }

    init(text: NSString, context: ScriptSummaryContext) {
        self.text = text
        self.context = context
        out = ScriptModuleSummary(key: context.key)
        ambient = context.path.hasSuffix(".d.ts") || context.path.hasSuffix(".d.mts") || context.path.hasSuffix(".d.cts")
    }

    func string(_ n: PyNode) -> String { text.substring(with: n.range) }
    func typeText(_ n: PyNode) -> String { ScriptTypeText.cleaned(string(n)) }

    func gap(_ from: Int, _ to: Int) -> String {
        guard to > from else { return "" }
        return text.substring(with: NSRange(location: from, length: to - from))
    }

    /// A string literal's value.
    func unquoted(_ n: PyNode) -> String? {
        guard n.kind == .string else { return nil }
        let s = string(n)
        guard s.count >= 2 else { return nil }
        return String(s.dropFirst().dropLast())
    }

    mutating func module(_ specifier: String) -> String? {
        guard let key = context.resolve(specifier) else { return nil }
        if !out.dependencies.contains(key) { out.dependencies.append(key) }
        return key
    }

    // MARK: - Statements

    /// `namespace`: the qualified prefix ("" at module level); `exported`:
    /// inside an `export` or an ambient namespace.
    mutating func statement(_ s: PyNode, namespace: String, exported: Bool) {
        switch s.kind {
        case .importDecl where namespace.isEmpty:
            importDecl(s)
        case .exportDecl:
            exportDecl(s, namespace: namespace)
        case .funcDecl, .classDecl, .interfaceDecl, .typeAlias, .enumDecl, .varDecl, .namespaceDecl:
            let names = declaration(s, namespace: namespace)
            if exported || (!namespace.isEmpty && ambient) {
                for n in names { export(n, local: qualified(namespace, n), namespace: namespace) }
            }
        case .exprStmt where namespace.isEmpty:
            commonJS(s)
        default:
            break
        }
    }

    func qualified(_ namespace: String, _ name: String) -> String { namespace.isEmpty ? name : namespace + "." + name }

    private mutating func export(_ name: String, local: String, namespace: String) {
        if namespace.isEmpty {
            out.exports[name] = .local(local)
        } else {
            var list = namespaceMembers[namespace] ?? []
            if !list.contains(name) { list.append(name) }
            namespaceMembers[namespace] = list
        }
    }

    // MARK: Imports / exports

    private mutating func importDecl(_ s: PyNode) {
        guard let source = s.parts.last(where: { $0.kind == .string }).flatMap(unquoted) else {
            // `import x = require('m')` keeps its source inside the spec.
            for spec in s.parts where spec.kind == .importSpec && spec.raw.aux & 3 == 3 { requireSpec(spec) }
            return
        }
        guard let key = module(source) else { return }
        for spec in s.parts where spec.kind == .importSpec {
            let names = spec.parts.filter { $0.kind == .name || $0.kind == .string }
            switch spec.raw.aux & 3 {
            case 1: if let local = names.first { out.imports[string(local)] = .default(module: key) }
            case 2: if let local = names.last { out.imports[string(local)] = .namespace(module: key) }
            case 3: requireSpec(spec)
            default:
                guard let first = names.first, let local = names.last else { continue }
                let imported = first.kind == .string ? (unquoted(first) ?? "") : string(first)
                out.imports[string(local)] = imported == "default" ? .default(module: key) : .named(module: key, name: imported)
            }
        }
    }

    /// `import x = require('m')`.
    private mutating func requireSpec(_ spec: PyNode) {
        let ps = spec.parts
        guard let local = ps.first, local.kind == .name, let value = ps.last, let source = requireSource(value),
              let key = module(source) else { return }
        out.imports[string(local)] = .namespace(module: key)
    }

    /// `require('m')` → `m`.
    func requireSource(_ n: PyNode) -> String? {
        guard n.kind == .call, let callee = n.parts.first, callee.kind == .name, string(callee) == "require",
              let args = n.firstChild(.args), let first = args.parts.first else { return nil }
        return unquoted(first)
    }

    private mutating func exportDecl(_ s: PyNode, namespace: String) {
        let aux = s.raw.aux & ~SyntaxAux.typeOnly
        let ps = s.parts
        switch aux {
        case 0:
            if let inner = ps.first { statement(inner, namespace: namespace, exported: true) }
        case 1:
            guard namespace.isEmpty, let inner = ps.first else { return }
            switch inner.kind {
            case .funcDecl, .classDecl, .interfaceDecl:
                if inner.firstChild(.name) == nil {
                    // `export default function () {}`: the declaration itself is `default`.
                    _ = declaration(inner, namespace: "", nameOverride: "default")
                    out.exports["default"] = .local("default")
                } else {
                    for n in declaration(inner, namespace: "") { out.exports["default"] = .local(n) }
                }
            case .name:
                out.exports["default"] = .local(string(inner))
            default:
                break
            }
        default:
            guard namespace.isEmpty else { return }
            var rest = gap(s.start + 6, s.end).trimmingCharacters(in: .whitespacesAndNewlines)
            if rest.hasPrefix("type ") || rest.hasPrefix("type{") || rest.hasPrefix("type*") {
                rest = String(rest.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            }
            let source = ps.last(where: { $0.kind == .string }).flatMap(unquoted)
            if rest.hasPrefix("*") {
                guard let source, let key = module(source) else { return }
                if let ns = ps.first(where: { $0.kind == .name }) {
                    out.exports[string(ns)] = .namespace(module: key)
                } else if !out.starExports.contains(key) {
                    out.starExports.append(key)
                }
            } else if rest.hasPrefix("{") {
                let key = source.flatMap { module($0) }
                if source != nil, key == nil { return }
                for spec in ps where spec.kind == .exportSpec {
                    let names = spec.parts.filter { $0.kind == .name || $0.kind == .string }
                    guard let first = names.first, let last = names.last else { continue }
                    let original = first.kind == .string ? (unquoted(first) ?? "") : string(first)
                    let exported = last.kind == .string ? (unquoted(last) ?? "") : string(last)
                    if let key {
                        out.exports[exported] = .reexport(module: key, name: original)
                    } else {
                        out.exports[exported] = .local(original)
                    }
                }
            } else if rest.hasPrefix("=") {
                if let value = ps.first, value.kind == .name { out.exportAssignment = string(value) }
                else if let value = ps.first, let chain = nameChain(value) { out.exportAssignment = chain }
            }
        }
    }

    /// `module.exports = …`, `module.exports.a = …`, `exports.a = …`.
    private mutating func commonJS(_ s: PyNode) {
        guard let e = s.parts.first, e.kind == .assignExpr else { return }
        let ps = e.parts
        guard ps.count == 2, let target = nameChain(ps[0]) else { return }
        let value = ps[1]
        if target == "module.exports" {
            switch value.kind {
            case .name:
                out.exportAssignment = string(value)
            case .object:
                for prop in value.parts {
                    let pp = prop.parts
                    if prop.kind == .name || (prop.kind == .prop && pp.count == 1 && pp[0].kind == .name) {
                        // `{ a }` shorthand.
                        let name = prop.kind == .name ? string(prop) : string(pp[0])
                        out.exports[name] = .local(name)
                    } else if prop.kind == .prop, pp.count == 2, let key = propertyName(pp[0]) {
                        if pp[1].kind == .name { out.exports[key] = .local(string(pp[1])) }
                        else { bindValue(key, value: pp[1], namespace: "", node: prop); out.exports[key] = .local(key) }
                    } else if prop.kind == .method, let key = prop.parts.first.flatMap(propertyName) {
                        out.symbols[key] = TSGlobalSymbol(name: key, section: .es, interface: nil, isClass: false, variable: nil,
                                                          function: TypeTable.Function(name: key, flags: [],
                                                                                       overloads: [signature(prop, jsdoc: jsdoc(before: prop.start))]),
                                                          alias: nil, namespaceMembers: nil, isDOMAugmented: false)
                        out.exports[key] = .local(key)
                    }
                }
            case .classExpr:
                let name = value.firstChild(.name).map(string) ?? "module.exports"
                classLike(value, name: name)
                out.exportAssignment = name
            default:
                if let source = requireSource(value), let key = module(source) {
                    out.starExports.append(key)
                } else {
                    bindValue("module.exports", value: value, namespace: "", node: s)
                    out.exportAssignment = "module.exports"
                }
            }
            return
        }
        for prefix in ["module.exports.", "exports."] where target.hasPrefix(prefix) {
            let name = String(target.dropFirst(prefix.count))
            guard !name.contains(".") else { return }
            if value.kind == .name { out.exports[name] = .local(string(value)) } else {
                bindValue(name, value: value, namespace: "", node: s)
                out.exports[name] = .local(name)
            }
            return
        }
    }

    func nameChain(_ n: PyNode) -> String? {
        switch n.kind {
        case .name: return string(n)
        case .member:
            let cs = n.parts
            guard cs.count == 2, cs[1].kind == .name, let base = nameChain(cs[0]) else { return nil }
            return base + "." + string(cs[1])
        default: return nil
        }
    }

    func propertyName(_ n: PyNode) -> String? {
        switch n.kind {
        case .name: return string(n)
        case .string: return unquoted(n)
        default: return nil
        }
    }

    // MARK: Declarations

    /// Records a declaration; returns the names it binds.
    @discardableResult
    mutating func declaration(_ s: PyNode, namespace: String, nameOverride: String? = nil) -> [String] {
        switch s.kind {
        case .funcDecl:
            guard let name = nameOverride ?? s.firstChild(.name).map(string) else { return [] }
            let q = qualified(namespace, name)
            let sig = signature(s, jsdoc: jsdoc(before: s.start))
            // Overloads (`function f(a: string): A;` …) hide the implementation.
            if s.firstChild(.block) == nil {
                if declaredOnly.contains(q) { functionOverloads[q, default: []].append(sig) } else {
                    functionOverloads[q] = [sig]
                    declaredOnly.insert(q)
                }
            } else if !declaredOnly.contains(q) {
                functionOverloads[q] = [sig]
            }
            return [name]
        case .classDecl:
            guard let name = nameOverride ?? s.firstChild(.name).map(string) else { return [] }
            classLike(s, name: qualified(namespace, name))
            return [name]
        case .interfaceDecl:
            guard let name = s.firstChild(.name).map(string) else { return [] }
            interface(s, name: qualified(namespace, name))
            return [name]
        case .typeAlias:
            let ps = s.parts
            guard let n = ps.first, n.kind == .name, let body = ps.last, ps.count >= 2 else { return [] }
            let name = string(n)
            let q = qualified(namespace, name)
            var symbol = out.symbols[q] ?? emptySymbol(q)
            symbol = with(symbol, alias: TypeTable.Alias(name: q, typeParameters: typeParameters(s.firstChild(.typeParams)),
                                                         type: typeText(body)))
            out.symbols[q] = symbol
            return [name]
        case .enumDecl:
            guard let name = s.firstChild(.name).map(string) else { return [] }
            let q = qualified(namespace, name)
            var members: [String] = []
            var valueTypes = Set<String>()
            for m in s.parts where m.kind == .enumMember {
                guard let key = m.parts.first.flatMap(propertyName) else { continue }
                let isString = m.parts.count >= 2 && m.parts[1].kind == .string
                valueTypes.insert(isString ? "string" : "number")
                members.append("readonly \(key): \(isString ? "string" : "number")")
            }
            let type = "{ " + members.joined(separator: "; ") + " }"
            var symbol = emptySymbol(q)
            symbol = with(symbol, variable: TypeTable.Variable(name: q, type: type, isConstant: true))
            symbol = with(symbol, alias: TypeTable.Alias(name: q, typeParameters: [],
                                                         type: valueTypes.sorted().joined(separator: " | ").nonEmpty ?? "number"))
            out.symbols[q] = symbol
            return [name]
        case .varDecl:
            var names: [String] = []
            let doc = jsdoc(before: s.start)
            for d in s.parts where d.kind == .declarator {
                let ps = d.parts
                guard let binding = ps.first else { continue }
                let initNode = d.raw.aux & 2 != 0 ? ps.last : nil
                if binding.kind == .objectPattern, namespace.isEmpty, let initNode, let source = requireSource(initNode),
                   let key = module(source) {
                    // `const { a, b: c } = require('m')`
                    for p in binding.parts {
                        if p.kind == .name { out.imports[string(p)] = .named(module: key, name: string(p)) }
                        else if p.kind == .patternProp, let k = p.parts.first.flatMap(propertyName),
                                let v = p.parts.last, v.kind == .name {
                            out.imports[string(v)] = .named(module: key, name: k)
                        }
                    }
                    continue
                }
                guard binding.kind == .name else { continue }
                let name = string(binding)
                names.append(name)
                if namespace.isEmpty, let initNode, let source = requireSource(initNode), let key = module(source) {
                    out.imports[name] = .namespace(module: key)
                    continue
                }
                if d.raw.aux & 1 != 0, ps.count >= 2 {
                    let type = typeText(ps[1])
                    out.symbols[qualified(namespace, name)] = with(emptySymbol(qualified(namespace, name)),
                                                                   variable: TypeTable.Variable(name: qualified(namespace, name),
                                                                                                type: type, isConstant: s.raw.aux == 2))
                } else if let initNode {
                    bindValue(qualified(namespace, name), value: initNode, namespace: namespace, node: s, jsdocType: doc?.type)
                } else {
                    out.symbols[qualified(namespace, name)] = with(emptySymbol(qualified(namespace, name)),
                                                                   variable: TypeTable.Variable(name: qualified(namespace, name),
                                                                                                type: doc?.type.flatMap(JSDoc.typeScriptText),
                                                                                                isConstant: false))
                }
            }
            return names
        case .namespaceDecl:
            guard let nameNode = s.parts.first, nameNode.kind == .qualifiedName || nameNode.kind == .name else { return [] }
            let parts = nameNode.kind == .name ? [string(nameNode)] : nameNode.parts.map(string)
            guard let head = parts.first else { return [] }
            var prefix = namespace
            for (k, part) in parts.enumerated() {
                let q = qualified(prefix, part)
                if out.symbols[q] == nil { out.symbols[q] = emptySymbol(q) }
                if k > 0 { export(part, local: q, namespace: prefix) }
                if namespaceMembers[q] == nil { namespaceMembers[q] = [] }
                prefix = q
            }
            if let block = s.firstChild(.block) {
                let isAmbient = ambient || s.has(SyntaxFlags.modifier)
                for st in block.children {
                    statement(st, namespace: prefix, exported: isAmbient)
                }
            }
            return [head]
        default:
            return []
        }
    }

    /// `name = value`: a function / class expression, a literal, `new X()`.
    private mutating func bindValue(_ q: String, value: PyNode, namespace: String, node: PyNode, jsdocType: String? = nil) {
        switch value.kind {
        case .arrow, .funcExpr:
            let sig = signature(value, jsdoc: jsdoc(before: node.start))
            functionOverloads[q] = [sig]
        case .classExpr:
            classLike(value, name: q)
        default:
            let type = jsdocType.flatMap(JSDoc.typeScriptText) ?? literalType(value)
            out.symbols[q] = with(out.symbols[q] ?? emptySymbol(q), variable: TypeTable.Variable(name: q, type: type, isConstant: false))
        }
    }

    /// The TypeScript type of a literal / `new X()` initialiser.
    func literalType(_ n: PyNode) -> String? {
        switch n.kind {
        case .string, .template: return "string"
        case .number: return "number"
        case .keywordLit:
            switch string(n) {
            case "true", "false": return "boolean"
            case "null": return "null"
            default: return nil
            }
        case .new:
            guard let callee = n.parts.first, let chain = nameChain(callee) else { return nil }
            let args = n.parts.first { $0.kind == .typeArgs }.map { "<" + $0.parts.map(typeText).joined(separator: ", ") + ">" } ?? ""
            return chain + args
        case .object:
            // `{ a: 1, b: 'x', m() {} }` → `{ a: number; b: string; m(): any }`.
            var members: [String] = []
            for prop in n.parts.prefix(32) {
                let pp = prop.parts
                switch prop.kind {
                case .prop where pp.count == 2:
                    guard let key = propertyName(pp[0]) else { continue }
                    members.append(key + ": " + (literalType(pp[1]) ?? "any"))
                case .method:
                    guard let key = pp.first.flatMap(propertyName) else { continue }
                    members.append(key + "(): any")
                default:
                    continue
                }
            }
            return "{ " + members.joined(separator: "; ") + " }"
        case .array:
            let items = n.parts.compactMap(literalType)
            guard let first = items.first, items.count == n.parts.count, items.allSatisfy({ $0 == first }) else { return nil }
            return first + "[]"
        case .asExpr, .satisfiesExpr:
            guard n.kind == .asExpr, let t = n.parts.last else { return nil }
            return typeText(t)
        default:
            return nil
        }
    }

    // MARK: Signatures

    /// The JSDoc comment ending right before `offset` (JavaScript types).
    func jsdoc(before offset: Int) -> JSDocComment? {
        guard context.dialect == .javascript, offset > 0 else { return nil }
        let window = max(0, offset - 4_096)
        let head = text.substring(with: NSRange(location: window, length: offset - window))
        guard let close = head.range(of: "*/", options: .backwards),
              head[close.upperBound...].allSatisfy({ $0.isWhitespace || $0 == "\n" }),
              let open = head.range(of: "/**", options: .backwards, range: head.startIndex..<close.lowerBound) else { return nil }
        return JSDocComment(String(head[open.lowerBound..<close.upperBound]))
    }

    func typeParameters(_ n: PyNode?) -> [TypeTable.TypeParameter] {
        guard let n else { return [] }
        return n.parts.filter { $0.kind == .typeParam }.compactMap { tp in
            let ps = tp.parts
            guard let name = ps.first, name.kind == .name else { return nil }
            var bound: String?
            var def: String?
            var prevEnd = name.end
            for extra in ps.dropFirst() {
                if gap(prevEnd, extra.start).contains("=") { def = typeText(extra) } else { bound = typeText(extra) }
                prevEnd = extra.end
            }
            return TypeTable.TypeParameter(name: string(name), bound: bound, defaultType: def, kind: .typeVar,
                                           boundIsConstraints: false)
        }
    }

    /// A function-like node's signature (`funcDecl`, `funcExpr`, `arrow`,
    /// `method`, `methodSig`, `callSig`, `ctorSig`).
    func signature(_ s: PyNode, jsdoc doc: JSDocComment? = nil) -> TypeTable.Signature {
        var params: [TypeTable.Parameter] = []
        var returns: String?
        var typeParams: [TypeTable.TypeParameter] = []
        var paramsEnd: Int?
        for c in s.parts {
            switch c.kind {
            case .typeParams:
                typeParams = typeParameters(c)
            case .params:
                paramsEnd = c.end
                for p in c.parts where p.kind == .param {
                    let aux = p.raw.aux
                    let ps = p.parts.filter { $0.kind != .decorator }
                    guard let binding = ps.first else { continue }
                    let name = binding.kind == .name || binding.kind == .keywordLit ? string(binding) : "arg"
                    if name == "this" { continue }
                    var type: String?
                    if aux & 4 != 0, ps.count >= 2 { type = typeText(ps[1]) }
                    if type == nil, let doc, let t = doc.params.first(where: { $0.name == name })?.type {
                        type = JSDoc.typeScriptText(t)
                    }
                    let optional = aux & 8 != 0 || p.has(SyntaxFlags.optional)
                    params.append(TypeTable.Parameter(name: name, kind: aux & 1 != 0 ? .variadic : .positional,
                                                      type: type, hasDefault: optional))
                }
            case .block:
                break
            default:
                if let end = paramsEnd, returns == nil, gap(end, c.start).contains(":") { returns = typeText(c) }
            }
        }
        if returns == nil, let doc, let r = doc.returns { returns = JSDoc.typeScriptText(r) }
        if returns == nil, s.kind == .arrow, let body = s.parts.last, body.kind != .block, body.kind != .params {
            returns = literalType(body)
        }
        if returns == nil, s.has(SyntaxFlags.async), context.dialect.hasTypes == false {
            returns = "Promise<any>"
        }
        return TypeTable.Signature(isAsync: s.has(SyntaxFlags.async), typeParameters: typeParams, parameters: params,
                                   returnType: returns)
    }

    // MARK: Classes and interfaces

    private func isHidden(_ member: PyNode, key: PyNode) -> Bool {
        if key.kind == .privateName || key.kind == .computedKey { return true }
        let modifiers = gap(member.start, key.start)
        return modifiers.contains("private") || modifiers.contains("protected")
    }

    private mutating func classLike(_ s: PyNode, name: String) {
        var parts = classParts[name] ?? ClassParts()
        parts.isClass = true
        parts.typeParameters = typeParameters(s.firstChild(.typeParams))
        for h in s.parts where h.kind == .heritage {
            for t in h.parts { parts.bases.append(typeText(t)) }
        }
        if let body = s.firstChild(.classBody) {
            for m in body.parts {
                switch m.kind {
                case .method:
                    let ps = m.parts.filter { $0.kind != .decorator }
                    guard let key = ps.first, !isHidden(m, key: key), let mname = propertyName(key) else { continue }
                    var flags: TypeTable.MemberFlags = m.has(SyntaxFlags.isStatic) ? [.classLevel] : []
                    if m.has(SyntaxFlags.optional) { flags.insert(.optional) }
                    let sig = signature(m, jsdoc: jsdoc(before: m.start))
                    switch m.raw.aux {
                    case 3:
                        parts.constructs.append(TypeTable.Signature(isAsync: false, typeParameters: parts.typeParameters,
                                                                    parameters: sig.parameters, returnType: nil))
                        // Parameter properties (`constructor(private a: T, public b: U)`).
                        if let params = m.firstChild(.params) {
                            for p in params.parts where p.kind == .param && p.raw.aux & 2 != 0 {
                                let pp = p.parts.filter { $0.kind != .decorator }
                                guard let b = pp.first, b.kind == .name else { continue }
                                let mods = gap(p.start, b.start)
                                if mods.contains("private") || mods.contains("protected") { continue }
                                let pname = string(b)
                                parts.members[pname] = TypeTable.Member(name: pname, kind: .field, flags: [],
                                                                        type: p.raw.aux & 4 != 0 && pp.count >= 2 ? typeText(pp[1]) : nil,
                                                                        overloads: [])
                            }
                        }
                        // `this.x = …` in the constructor (JavaScript classes).
                        if let block = m.firstChild(.block) { thisFields(block, into: &parts) }
                    case 1:
                        parts.members[mname] = TypeTable.Member(name: mname, kind: .property, flags: flags, type: sig.returnType,
                                                                overloads: [])
                    case 2:
                        if parts.members[mname] == nil {
                            parts.members[mname] = TypeTable.Member(name: mname, kind: .property, flags: flags,
                                                                    type: sig.parameters.first?.type, overloads: [])
                        }
                    default:
                        let bodiless = m.firstChild(.block) == nil
                        let key = name + "#" + mname
                        var overloads = [sig]
                        if let existing = parts.members[mname], existing.kind == .method, declaredOnly.contains(key) {
                            overloads = bodiless ? existing.overloads + [sig] : existing.overloads
                        }
                        if bodiless { declaredOnly.insert(key) }
                        parts.members[mname] = TypeTable.Member(name: mname, kind: .method, flags: flags, type: nil,
                                                                overloads: overloads)
                    }
                case .property:
                    let ps = m.parts.filter { $0.kind != .decorator }
                    guard let key = ps.first, !isHidden(m, key: key), let mname = propertyName(key) else { continue }
                    var flags: TypeTable.MemberFlags = m.has(SyntaxFlags.isStatic) ? [.classLevel] : []
                    if m.has(SyntaxFlags.optional) { flags.insert(.optional) }
                    var type: String?
                    if m.raw.aux & 1 != 0, ps.count >= 2 { type = typeText(ps[1]) }
                    if type == nil, let doc = jsdoc(before: m.start), let t = doc.type { type = JSDoc.typeScriptText(t) }
                    if type == nil, m.raw.aux & 2 != 0, let value = ps.last {
                        if value.kind == .arrow || value.kind == .funcExpr {
                            parts.members[mname] = TypeTable.Member(name: mname, kind: .method, flags: flags, type: nil,
                                                                    overloads: [signature(value)])
                            continue
                        }
                        type = literalType(value)
                    }
                    parts.members[mname] = TypeTable.Member(name: mname, kind: .field, flags: flags, type: type, overloads: [])
                case .indexSig:
                    if let index = indexSignature(m) { parts.indexes.append(index) }
                default:
                    break
                }
            }
        }
        classParts[name] = parts
    }

    /// `this.x = value` assignments of a constructor body.
    private func thisFields(_ block: PyNode, into parts: inout ClassParts) {
        block.walk { n in
            switch n.kind {
            case .funcDecl, .funcExpr, .classDecl, .classExpr: return false
            case .assignExpr:
                let ps = n.parts
                guard ps.count == 2, ps[0].kind == .member, let object = ps[0].parts.first, object.kind == .keywordLit,
                      string(object) == "this", let attr = ps[0].parts.last, attr.kind == .name else { return true }
                let name = string(attr)
                if parts.members[name] == nil {
                    parts.members[name] = TypeTable.Member(name: name, kind: .field, flags: [], type: literalType(ps[1]),
                                                           overloads: [])
                }
                return false
            default:
                return true
            }
        }
    }

    private mutating func interface(_ s: PyNode, name: String) {
        var parts = classParts[name] ?? ClassParts()
        let params = typeParameters(s.firstChild(.typeParams))
        if !params.isEmpty { parts.typeParameters = params }
        for h in s.parts where h.kind == .heritage {
            for t in h.parts { parts.bases.append(typeText(t)) }
        }
        if let body = s.firstChild(.objectType) { typeMembers(body, into: &parts) }
        classParts[name] = parts
    }

    private func typeMembers(_ body: PyNode, into parts: inout ClassParts) {
        for m in body.parts {
            switch m.kind {
            case .propSig:
                let ps = m.parts
                guard let key = ps.first, let mname = propertyName(key) else { continue }
                var flags: TypeTable.MemberFlags = []
                if m.has(SyntaxFlags.optional) { flags.insert(.optional) }
                if gap(m.start, key.start).contains("readonly") { flags.insert(.readonly) }
                let type = ps.count >= 2 ? typeText(ps[1]) : nil
                parts.members[mname] = TypeTable.Member(name: mname, kind: .property, flags: flags, type: type, overloads: [])
            case .methodSig:
                guard let key = m.parts.first, let mname = propertyName(key) else { continue }
                var flags: TypeTable.MemberFlags = []
                if m.has(SyntaxFlags.optional) { flags.insert(.optional) }
                let sig = signature(m)
                let existing = parts.members[mname].flatMap { $0.kind == .method ? $0.overloads : nil } ?? []
                parts.members[mname] = TypeTable.Member(name: mname, kind: .method, flags: flags, type: nil,
                                                        overloads: existing + [sig])
            case .callSig:
                parts.calls.append(signature(m))
            case .ctorSig:
                parts.constructs.append(signature(m))
            case .indexSig:
                if let index = indexSignature(m) { parts.indexes.append(index) }
            default:
                break
            }
        }
    }

    private func indexSignature(_ m: PyNode) -> TypeTable.IndexSignature? {
        guard let params = m.firstChild(.params), let p = params.parts.first, let key = p.parts.first,
              p.parts.count >= 2, let value = m.parts.last, value.kind != .params else { return nil }
        return TypeTable.IndexSignature(keyName: string(key), keyType: typeText(p.parts[1]), valueType: typeText(value),
                                        isReadonly: gap(m.start, params.start).contains("readonly"))
    }

    // MARK: Symbols

    func emptySymbol(_ name: String) -> TSGlobalSymbol {
        TSGlobalSymbol(name: name, section: .es, interface: nil, isClass: false, variable: nil, function: nil, alias: nil,
                       namespaceMembers: nil, isDOMAugmented: false)
    }

    func with(_ s: TSGlobalSymbol, interface: TypeTable.ClassDecl? = nil, isClass: Bool? = nil,
              variable: TypeTable.Variable? = nil, function: TypeTable.Function? = nil, alias: TypeTable.Alias? = nil,
              namespaceMembers: [String]? = nil) -> TSGlobalSymbol {
        TSGlobalSymbol(name: s.name, section: .es, interface: interface ?? s.interface, isClass: isClass ?? s.isClass,
                       variable: variable ?? s.variable, function: function ?? s.function, alias: alias ?? s.alias,
                       namespaceMembers: namespaceMembers ?? s.namespaceMembers, isDOMAugmented: false)
    }

    // MARK: Result

    mutating func result() -> ScriptModuleSummary {
        for (q, overloads) in functionOverloads where !overloads.isEmpty {
            out.symbols[q] = with(out.symbols[q] ?? emptySymbol(q), function: TypeTable.Function(name: q, flags: [], overloads: overloads))
        }
        for (q, parts) in classParts {
            let members = parts.members.values.sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
            let decl = TypeTable.ClassDecl(name: q, flags: [], typeParameters: parts.typeParameters, bases: parts.bases,
                                           members: members, callSignatures: parts.calls, constructSignatures: parts.constructs,
                                           indexSignatures: parts.indexes)
            out.symbols[q] = with(out.symbols[q] ?? emptySymbol(q), interface: decl, isClass: parts.isClass)
        }
        for (q, list) in namespaceMembers {
            out.symbols[q] = with(out.symbols[q] ?? emptySymbol(q), namespaceMembers: list)
        }
        return out
    }

    /// Names only: exported top-level names and their kinds.
    mutating func names() -> ScriptModuleSummary {
        var build = SyntaxBuild(dialect: context.dialect, text: text, mode: .summary)
        var kinds: [String: InferredMemberKind] = [:]
        if let summary = build.finish(text)?.summary {
            for index in summary.statements.indices {
                let st = summary.statements[index]
                guard st.traits & ModuleSummary.Statement.exported != 0 || st.traits & ModuleSummary.Statement.ambient != 0
                else { continue }
                let kind: InferredMemberKind
                switch st.kind {
                case .funcDecl: kind = .function
                case .classDecl, .interfaceDecl, .typeAlias, .enumDecl: kind = .class
                case .namespaceDecl: kind = .submodule
                default: kind = .variable
                }
                let isDefault = st.traits & ModuleSummary.Statement.exportDefault != 0
                for r in summary.names(of: index) {
                    kinds[isDefault ? "default" : text.substring(with: r)] = kind
                }
            }
        }
        var out = ScriptModuleSummary(key: context.key)
        out.namesOnly = kinds
        return out
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
