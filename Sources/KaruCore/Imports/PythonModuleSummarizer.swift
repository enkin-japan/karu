import Foundation

// M17 T17.13 — a Python module's export summary (plan §9 "结果形态"): the
// same `PythonModuleStub` shape the built-in typeshed table uses, so the
// evaluator reads an imported project / third-party module exactly like a
// standard-library one (classes with members and bases, functions with
// signatures, variables with types, imports, `__all__`, star imports).
// Produced on the import queue from the parser's top-level statements; the
// syntax tree is dropped when the summary is done (never kept).
//
// Types come from annotations (stubs are fully annotated). Unannotated code
// gets a small, precise subset: literals, `ClassName(...)` calls, `self`,
// and `self.x = param` with an annotated parameter; anything else stays
// unknown (plan §13 precision rule: unknown → usage evidence).

/// What the summary of one module needs to know about its place.
struct PythonSummaryContext: Sendable {
    /// The module's absolute dotted name.
    var dotted: String
    var isPackage: Bool
    /// `.pyi`: only `import x as x` / `from m import y as y` re-export.
    var isStub: Bool
    /// Prefix of the context's module keys (`§3:`).
    var keyPrefix: String
    /// Whether a top-level module name is a standard-library module (the
    /// typeshed table): such imports keep their plain names.
    var isStdlib: @Sendable (String) -> Bool

    /// The table / overlay name of absolute module `dotted`.
    func moduleName(_ dotted: String) -> String {
        let head = dotted.split(separator: ".").first.map(String.init) ?? dotted
        return isStdlib(head) ? dotted : keyPrefix + dotted
    }

    var key: String { keyPrefix + dotted }
}

/// A summarised module and the project / third-party modules it imports
/// (loaded with it, up to the re-export depth).
struct PythonModuleSummary: Sendable {
    var stub: PythonModuleStub
    /// Names only (a source over the size cap): every top-level name is an
    /// untyped variable; `kinds` keeps what each was for listings.
    var kinds: [String: InferredMemberKind]?
    /// Absolute dotted names of non-stdlib imports, with the imported names
    /// (`from m import a, b`) for the submodule check.
    var dependencies: [(module: String, names: [String])]
}

enum PythonModuleSummarizer {
    /// Summarises `text`. `namesOnly`: just the top-level names (sources
    /// over `ImportService.namesOnlySourceBytes`).
    static func summarize(_ text: NSString, context: PythonSummaryContext, namesOnly: Bool) -> PythonModuleSummary {
        if namesOnly { return names(text, context: context) }
        var builder = PythonStubBuilder(text: text, context: context)
        if SyntaxBuild.mode(forLength: text.length) == .tree {
            let unit = PyUnit(SyntaxBuild.parse(text, dialect: .python))
            for i in unit.tree.topLevelStatements { builder.statement(PyNode(unit: unit, i: i), conditional: false) }
        } else {
            var build = SyntaxBuild(dialect: .python, text: text, mode: .summary)
            guard let summary = build.finish(text)?.summary else { return builder.result() }
            for index in summary.statements.indices {
                let tree = summary.parseStatement(index, in: text)
                guard tree.nodes.count >= 2 else { continue }
                let unit = PyUnit(tree)
                builder.statement(PyNode(unit: unit, i: tree.root - 1), conditional: false)
            }
        }
        return builder.result()
    }

    /// Top-level names from the parser's module summary (no subtrees).
    static func names(_ text: NSString, context: PythonSummaryContext) -> PythonModuleSummary {
        var build = SyntaxBuild(dialect: .python, text: text, mode: .summary)
        var kinds: [String: InferredMemberKind] = [:]
        if let summary = build.finish(text)?.summary {
            for index in summary.statements.indices {
                let kind: InferredMemberKind
                switch summary.statements[index].kind {
                case .funcDef: kind = .function
                case .classDef: kind = .class
                case .importStmt, .importFrom: continue
                default: kind = .variable
                }
                for r in summary.names(of: index) {
                    let name = text.substring(with: r)
                    if kinds[name] == nil { kinds[name] = kind }
                }
            }
        }
        let variables = kinds.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            .map { TypeTable.Variable(name: $0, type: nil, isConstant: false) }
        let stub = PythonModuleStub(name: context.key, isPackage: context.isPackage, all: nil, imports: [], starImports: [],
                                    typeVars: [], aliases: [], variables: variables, functions: [], classes: [])
        return PythonModuleSummary(stub: stub, kinds: kinds, dependencies: [])
    }

    /// A summary reduced to its names (LRU degradation, plan §11).
    static func namesOnly(_ summary: PythonModuleSummary) -> PythonModuleSummary {
        if summary.kinds != nil { return summary }
        let stub = summary.stub
        var kinds: [String: InferredMemberKind] = [:]
        for c in stub.classes where !c.name.contains(".") { kinds[c.name] = .class }
        for f in stub.functions { kinds[f.name] = .function }
        for v in stub.variables { kinds[v.name] = .variable }
        for a in stub.aliases { kinds[a.name] = .class }
        for i in stub.imports where i.isReexport { kinds[i.localName] = i.originalName == nil ? .submodule : .variable }
        let variables = kinds.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            .map { TypeTable.Variable(name: $0, type: nil, isConstant: false) }
        let reduced = PythonModuleStub(name: stub.name, isPackage: stub.isPackage, all: stub.all, imports: [], starImports: [],
                                       typeVars: [], aliases: [], variables: variables, functions: [], classes: [])
        return PythonModuleSummary(stub: reduced, kinds: kinds, dependencies: [])
    }
}

/// Collects one module's definitions statement by statement.
private struct PythonStubBuilder {
    let text: NSString
    let context: PythonSummaryContext

    private var classes: [String: TypeTable.ClassDecl] = [:]
    private var functions: [String: TypeTable.Function] = [:]
    private var variables: [String: TypeTable.Variable] = [:]
    private var aliases: [String: TypeTable.Alias] = [:]
    private var typeVars: [String: TypeTable.TypeParameter] = [:]
    private var imports: [String: PythonModuleStub.Import] = [:]
    private var stars: [String] = []
    private var all: [String]?
    private var dependencies: [(module: String, names: [String])] = []
    /// Names defined so far (a conditional branch never overrides them).
    private var defined = Set<String>()

    init(text: NSString, context: PythonSummaryContext) {
        self.text = text
        self.context = context
    }

    func string(_ n: PyNode) -> String { text.substring(with: n.range) }

    /// Source text with whitespace runs collapsed (annotations, bases).
    func typeText(_ n: PyNode) -> String {
        string(n).split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" || $0 == "\\" })
            .joined(separator: " ")
    }

    func gapHas(_ ch: Character, from: Int, to: Int) -> Bool {
        guard to > from else { return false }
        return text.substring(with: NSRange(location: from, length: to - from)).contains(ch)
    }

    // MARK: - Statements

    mutating func statement(_ s: PyNode, conditional: Bool) {
        switch s.kind {
        case .funcDef:
            guard let name = s.firstChild(.name).map(string) else { return }
            let fn = function(s)
            if isOverload(s), let existing = functions[name], canBind(name, conditional) {
                functions[name] = TypeTable.Function(name: name, flags: existing.flags, overloads: existing.overloads + fn.overloads)
                return
            }
            guard canBind(name, conditional) else { return }
            unbind(name)
            functions[name] = fn
        case .classDef:
            guard let name = s.firstChild(.name).map(string), canBind(name, conditional) else { return }
            unbind(name)
            for decl in classDecls(s, qualname: name) { classes[decl.name] = decl }
        case .assign:
            assign(s, conditional: conditional)
        case .annAssign:
            let ps = s.parts
            guard ps.count >= 2, ps[0].kind == .name else { return }
            let name = string(ps[0])
            guard canBind(name, conditional) else { return }
            let annotation = typeText(ps[1])
            unbind(name)
            if annotation == "TypeAlias" || annotation.hasSuffix(".TypeAlias") {
                if ps.count >= 3 { aliases[name] = TypeTable.Alias(name: name, typeParameters: [], type: typeText(ps[2])) }
                return
            }
            if annotation == "Final" || annotation.hasSuffix(".Final") {
                variables[name] = TypeTable.Variable(name: name, type: ps.count >= 3 ? valueType(ps[2]) : nil, isConstant: true)
                return
            }
            variables[name] = TypeTable.Variable(name: name, type: annotation, isConstant: false)
        case .typeAliasStmt:
            let ps = s.parts
            guard let n = ps.first, n.kind == .name, let value = ps.last, ps.count >= 2 else { return }
            let name = string(n)
            guard canBind(name, conditional) else { return }
            unbind(name)
            aliases[name] = TypeTable.Alias(name: name, typeParameters: [], type: typeText(value))
        case .importStmt:
            importStatement(s, conditional: conditional)
        case .importFrom:
            importFrom(s, conditional: conditional)
        case .augAssign:
            // `__all__ += [...]`
            let ps = s.parts
            if ps.count == 2, ps[0].kind == .name, string(ps[0]) == "__all__" {
                all = (all ?? []) + stringList(ps[1])
            }
        case .exprStmt:
            // `__all__.extend([...])` / `__all__.append("x")`
            guard let call = s.parts.first, call.kind == .call, let callee = call.parts.first, callee.kind == .member,
                  let target = callee.parts.first, target.kind == .name, string(target) == "__all__",
                  let method = callee.parts.last.map(string), let args = call.firstChild(.args) else { return }
            if method == "extend", let list = args.parts.first { all = (all ?? []) + stringList(list) }
            if method == "append", let item = args.parts.first, let value = stringLiteral(item) { all = (all ?? []) + [value] }
        case .ifStmt, .tryStmt:
            for c in s.parts { branch(c) }
        default:
            break
        }
    }

    /// Statements of a conditional branch (`if TYPE_CHECKING:`, `try:`):
    /// what an earlier statement or branch defined stays.
    private mutating func branch(_ n: PyNode) {
        switch n.kind {
        case .block:
            for st in n.children { statement(st, conditional: true) }
        case .elifClause, .elseClause, .exceptClause, .finallyClause:
            for c in n.parts where c.kind == .block { branch(c) }
        default:
            break
        }
    }

    private func canBind(_ name: String, _ conditional: Bool) -> Bool { !conditional || !defined.contains(name) }

    private mutating func unbind(_ name: String) {
        defined.insert(name)
        classes[name] = nil
        functions[name] = nil
        variables[name] = nil
        aliases[name] = nil
        typeVars[name] = nil
        imports[name] = nil
    }

    // MARK: - Assignments

    private mutating func assign(_ s: PyNode, conditional: Bool) {
        let ps = s.parts
        guard ps.count >= 2, let value = ps.last else { return }
        for target in ps.dropLast() where target.kind == .name {
            let name = string(target)
            if name == "__all__" {
                all = stringList(value)
                continue
            }
            guard canBind(name, conditional) else { continue }
            unbind(name)
            if let tv = typeVar(name, value) {
                typeVars[name] = tv
            } else if value.kind == .name, string(value) != name, !["None", "True", "False"].contains(string(value)) {
                // `Alias = SomeClass`: the name resolves to what it names.
                imports[name] = PythonModuleStub.Import(localName: name, module: context.key, originalName: string(value),
                                                        isReexport: false)
            } else {
                variables[name] = TypeTable.Variable(name: name, type: valueType(value), isConstant: false)
            }
        }
    }

    /// `T = TypeVar("T", bound=X)`.
    private func typeVar(_ name: String, _ value: PyNode) -> TypeTable.TypeParameter? {
        guard value.kind == .call, let callee = value.parts.first,
              ["TypeVar", "typing.TypeVar", "typing_extensions.TypeVar", "ParamSpec", "TypeVarTuple"].contains(string(callee))
        else { return nil }
        var bound: String?
        var constraints: [String] = []
        for (k, a) in (value.firstChild(.args)?.parts ?? []).enumerated() {
            if a.kind == .keywordArg {
                let kp = a.parts
                if kp.count == 2, string(kp[0]) == "bound" { bound = typeText(kp[1]) }
            } else if k > 0 {
                constraints.append(typeText(a))
            }
        }
        let kind: TypeTable.TypeParameter.Kind = string(callee).hasSuffix("ParamSpec") ? .paramSpec
            : string(callee).hasSuffix("TypeVarTuple") ? .typeVarTuple : .typeVar
        if !constraints.isEmpty {
            return TypeTable.TypeParameter(name: name, bound: constraints.joined(separator: " | "), defaultType: nil,
                                           kind: kind, boundIsConstraints: true)
        }
        return TypeTable.TypeParameter(name: name, bound: bound, defaultType: nil, kind: kind, boundIsConstraints: false)
    }

    /// The type text of a value, for the forms whose type is certain.
    func valueType(_ n: PyNode, selfName: String? = nil, params: [String: String] = [:]) -> String? {
        switch n.kind {
        case .number:
            let s = string(n).lowercased()
            if s.hasSuffix("j") { return "complex" }
            if s.hasPrefix("0x") || s.hasPrefix("0o") || s.hasPrefix("0b") { return "int" }
            return s.contains(".") || s.contains("e") ? "float" : "int"
        case .string:
            let s = string(n).lowercased()
            let prefix = s.prefix { $0 != "'" && $0 != "\"" }
            return prefix.contains("b") ? "bytes" : "str"
        case .keywordLit:
            switch string(n) {
            case "True", "False": return "bool"
            case "None": return "None"
            default: return nil
            }
        case .list, .listComp: return "list"
        case .dict, .dictComp: return "dict"
        case .set, .setComp: return "set"
        case .tuple: return "tuple"
        case .call:
            guard let callee = n.parts.first, let chain = nameChain(callee),
                  let last = chain.split(separator: ".").last, last.first?.isUppercase == true else { return nil }
            return chain
        case .name:
            let name = string(n)
            if let selfName, name == selfName { return "Self" }
            return params[name]
        case .paren:
            return n.parts.count == 1 ? valueType(n.parts[0], selfName: selfName, params: params) : nil
        default:
            return nil
        }
    }

    /// `a`, `a.b.C` for a pure name chain.
    func nameChain(_ n: PyNode) -> String? {
        switch n.kind {
        case .name: return string(n)
        case .member:
            let cs = n.children
            guard cs.count == 2, cs[1].kind == .name, let base = nameChain(cs[0]) else { return nil }
            return base + "." + string(cs[1])
        default: return nil
        }
    }

    private func stringLiteral(_ n: PyNode) -> String? {
        guard n.kind == .string, n.children.isEmpty else { return nil }
        var s = string(n)
        while let first = s.first, first != "'" && first != "\"" { s.removeFirst() }
        guard s.count >= 2, let q = s.first, s.last == q else { return nil }
        if s.hasPrefix(String(repeating: q, count: 3)), s.count >= 6 { return String(s.dropFirst(3).dropLast(3)) }
        return String(s.dropFirst().dropLast())
    }

    private func stringList(_ n: PyNode) -> [String] {
        switch n.kind {
        case .list, .tuple, .paren: return n.parts.compactMap(stringLiteral)
        case .binary: return n.parts.flatMap(stringList)
        default: return []
        }
    }

    // MARK: - Imports

    private mutating func importStatement(_ s: PyNode, conditional: Bool) {
        for alias in s.parts where alias.kind == .alias {
            let ps = alias.parts
            guard let dotted = ps.first, dotted.kind == .dottedName else { continue }
            let path = string(dotted).filter { !$0.isWhitespace }
            let head = path.split(separator: ".").first.map(String.init) ?? path
            if ps.count >= 2, ps[1].kind == .name {
                let local = string(ps[1])
                guard canBind(local, conditional) else { continue }
                unbind(local)
                imports[local] = PythonModuleStub.Import(localName: local, module: context.moduleName(path), originalName: nil,
                                                         isReexport: local == path)
            } else {
                guard canBind(head, conditional) else { continue }
                unbind(head)
                imports[head] = PythonModuleStub.Import(localName: head, module: context.moduleName(head), originalName: nil,
                                                        isReexport: false)
            }
            dependency(path, names: [])
        }
    }

    private mutating func importFrom(_ s: PyNode, conditional: Bool) {
        let level = Int(s.raw.aux)
        let source = s.firstChild(.dottedName).map { string($0).filter { !$0.isWhitespace } } ?? ""
        guard let absolute = PythonModuleLocator.absolute(level: level, name: source, from: context.dotted,
                                                          isPackage: context.isPackage) else { return }
        // Not a stub: the package's own modules re-export (`from .core import X`).
        let samePackage = level > 0 || absolute.split(separator: ".").first == context.dotted.split(separator: ".").first
        if let star = s.children.last, star.kind == .name, string(star) == "*" {
            guard !absolute.isEmpty else { return }
            stars.append(context.moduleName(absolute))
            dependency(absolute, names: [])
            return
        }
        var names: [String] = []
        for alias in s.parts where alias.kind == .alias {
            let ps = alias.parts
            guard let original = ps.first, original.kind == .name else { continue }
            let name = string(original)
            let hasAs = ps.count >= 2 && ps[1].kind == .name
            let local = hasAs ? string(ps[1]) : name
            names.append(name)
            guard canBind(local, conditional) else { continue }
            unbind(local)
            let reexport = context.isStub ? (hasAs && local == name) : (samePackage || (hasAs && local == name))
            if absolute.isEmpty {
                // `from . import x` at a search root: `x` is a top-level module.
                imports[local] = PythonModuleStub.Import(localName: local, module: context.moduleName(name), originalName: nil,
                                                         isReexport: reexport)
                dependency(name, names: [])
            } else {
                imports[local] = PythonModuleStub.Import(localName: local, module: context.moduleName(absolute),
                                                         originalName: name, isReexport: reexport)
            }
        }
        if !absolute.isEmpty { dependency(absolute, names: names) }
    }

    private mutating func dependency(_ dotted: String, names: [String]) {
        let head = dotted.split(separator: ".").first.map(String.init) ?? dotted
        guard !dotted.isEmpty, !context.isStdlib(head) else { return }
        dependencies.append((dotted, names))
    }

    // MARK: - Functions

    private func decorators(_ s: PyNode) -> [String] {
        s.parts.filter { $0.kind == .decorator }.compactMap { d in d.parts.first.map { typeText($0) } }
    }

    private func isOverload(_ s: PyNode) -> Bool {
        decorators(s).contains { $0 == "overload" || $0.hasSuffix(".overload") }
    }

    /// The parameters (name → annotation) and signature of a `def`.
    func signature(_ s: PyNode) -> (TypeTable.Signature, [String: String]) {
        var params: [TypeTable.Parameter] = []
        var annotations: [String: String] = [:]
        var returns: String?
        var typeParams: [TypeTable.TypeParameter] = []
        var seenParams = false
        var hasBlock = false
        for c in s.parts {
            switch c.kind {
            case .typeParams:
                typeParams = c.parts.compactMap { tp in
                    tp.parts.first.map { TypeTable.TypeParameter(name: string($0), bound: nil, defaultType: nil, kind: .typeVar,
                                                                 boundIsConstraints: false) }
                }
            case .params:
                seenParams = true
                var keywordOnly = false
                let raw = c.parts.filter { $0.kind == .param }
                let slash = raw.lastIndex { $0.raw.aux == 4 }
                for (k, p) in raw.enumerated() {
                    let aux = Int(p.raw.aux)
                    if aux == 3 { keywordOnly = true; continue }
                    if aux == 4 { continue }
                    let ps = p.parts
                    guard let nameNode = ps.first, nameNode.kind == .name else { continue }
                    var annotation: String?
                    var hasDefault = false
                    var prevEnd = nameNode.end
                    for extra in ps.dropFirst() {
                        if gapHas(":", from: prevEnd, to: extra.start) { annotation = typeText(extra) } else { hasDefault = true }
                        prevEnd = extra.end
                    }
                    let kind: TypeTable.Parameter.Kind
                    switch aux {
                    case 1: kind = .variadic; keywordOnly = true
                    case 2: kind = .keywordVariadic
                    default:
                        if let slash, k < slash { kind = .positionalOnly } else { kind = keywordOnly ? .keywordOnly : .positional }
                    }
                    let name = string(nameNode)
                    if let annotation { annotations[name] = annotation }
                    params.append(TypeTable.Parameter(name: name, kind: kind, type: annotation, hasDefault: hasDefault))
                }
            case .block:
                hasBlock = true
            default:
                if seenParams, !hasBlock, returns == nil, c.kind != .decorator { returns = typeText(c) }
            }
        }
        return (TypeTable.Signature(isAsync: s.has(SyntaxFlags.async), typeParameters: typeParams, parameters: params,
                                    returnType: returns), annotations)
    }

    private func function(_ s: PyNode, selfName: String? = nil) -> TypeTable.Function {
        var (sig, annotations) = signature(s)
        if sig.returnType == nil, !context.isStub, let inferred = returnType(s, selfName: selfName, params: annotations) {
            sig = TypeTable.Signature(isAsync: sig.isAsync, typeParameters: sig.typeParameters, parameters: sig.parameters,
                                      returnType: inferred)
        }
        let name = s.firstChild(.name).map(string) ?? ""
        return TypeTable.Function(name: name, flags: [], overloads: [sig])
    }

    /// The union of a body's `return` value types when every one is known
    /// (none for a generator or a body without `return`).
    private func returnType(_ s: PyNode, selfName: String?, params: [String: String]) -> String? {
        guard let block = s.firstChild(.block) else { return nil }
        var types: [String] = []
        var unknown = false
        var generator = false
        block.walk { n in
            if unknown || generator { return false }
            switch n.kind {
            case .funcDef, .classDef, .lambda: return false
            case .yield: generator = true; return false
            case .returnStmt:
                guard let v = n.parts.first else { if !types.contains("None") { types.append("None") }; return false }
                if let t = valueType(v, selfName: selfName, params: params) {
                    if !types.contains(t) { types.append(t) }
                } else {
                    unknown = true
                }
                return false
            default: return true
            }
        }
        guard !unknown, !generator, !types.isEmpty, types.count <= 4 else { return nil }
        return types.joined(separator: " | ")
    }

    // MARK: - Classes

    /// The class and its nested classes (`Outer.Inner`).
    private func classDecls(_ s: PyNode, qualname: String) -> [TypeTable.ClassDecl] {
        var bases: [String] = []
        var typeParams: [String] = []
        var flags: TypeTable.ClassFlags = []
        for c in s.parts {
            switch c.kind {
            case .typeParams:
                typeParams += c.parts.compactMap { tp in tp.parts.first.map(string) }
            case .args:
                for a in c.parts where a.kind != .keywordArg {
                    let text = typeText(a)
                    let head = text.split(separator: "[").first.map(String.init) ?? text
                    let short = head.split(separator: ".").last.map(String.init) ?? head
                    switch short {
                    case "Generic", "Protocol":
                        if short == "Protocol" { flags.insert(.protocol) }
                        if case .generic(_, let args)? = TypeExpr.parse(text, syntax: .python) {
                            for arg in args { if case .name(let n) = arg, !typeParams.contains(n) { typeParams.append(n) } }
                        }
                        continue   // `Generic[...]` / `Protocol[...]` carry type parameters, not members
                    case "TypedDict": flags.insert(.typedDict)
                    case "NamedTuple": flags.insert(.namedTuple)
                    case "Enum", "IntEnum", "StrEnum", "Flag", "IntFlag": flags.insert(.enum)
                    default: break
                    }
                    bases.append(text)
                }
            default:
                break
            }
        }
        var members: [String: TypeTable.Member] = [:]
        var nested: [TypeTable.ClassDecl] = []
        if let block = s.firstChild(.block) {
            classBody(block, qualname: qualname, isEnum: flags.contains(.enum), members: &members, nested: &nested)
        }
        let sorted = members.values.sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
        let params = typeParams.map {
            TypeTable.TypeParameter(name: $0, bound: nil, defaultType: nil, kind: .typeVar, boundIsConstraints: false)
        }
        let decl = TypeTable.ClassDecl(name: qualname, flags: flags, typeParameters: params, bases: bases, members: sorted,
                                       callSignatures: [], constructSignatures: [], indexSignatures: [])
        return [decl] + nested
    }

    private func classBody(_ block: PyNode, qualname: String, isEnum: Bool, members: inout [String: TypeTable.Member],
                           nested: inout [TypeTable.ClassDecl]) {
        for st in block.children {
            switch st.kind {
            case .funcDef:
                method(st, members: &members)
            case .classDef:
                guard let name = st.firstChild(.name).map(string) else { continue }
                nested += classDecls(st, qualname: qualname + "." + name)
            case .annAssign:
                let ps = st.parts
                guard ps.count >= 2, ps[0].kind == .name else { continue }
                var annotation = typeText(ps[1])
                var flags: TypeTable.MemberFlags = []
                for prefix in ["ClassVar[", "typing.ClassVar["] where annotation.hasPrefix(prefix) && annotation.hasSuffix("]") {
                    flags.insert(.classLevel)
                    annotation = String(annotation.dropFirst(prefix.count).dropLast())
                }
                let name = string(ps[0])
                members[name] = TypeTable.Member(name: name, kind: .field, flags: flags, type: annotation, overloads: [])
            case .assign:
                let ps = st.parts
                guard ps.count >= 2, let value = ps.last else { continue }
                for target in ps.dropLast() where target.kind == .name {
                    let name = string(target)
                    if members[name] != nil { continue }
                    members[name] = TypeTable.Member(name: name, kind: .field, flags: [.assigned, .classLevel],
                                                     type: isEnum ? nil : valueType(value), overloads: [])
                }
            case .ifStmt, .tryStmt:
                for c in st.parts {
                    if c.kind == .block {
                        classBody(c, qualname: qualname, isEnum: isEnum, members: &members, nested: &nested)
                    } else if let b = c.firstChild(.block) {
                        classBody(b, qualname: qualname, isEnum: isEnum, members: &members, nested: &nested)
                    }
                }
            default:
                break
            }
        }
    }

    private func method(_ s: PyNode, members: inout [String: TypeTable.Member]) {
        guard let name = s.firstChild(.name).map(string) else { return }
        let decos = decorators(s)
        if decos.contains(where: { $0.hasSuffix(".setter") || $0.hasSuffix(".deleter") }) { return }
        var kind = TypeTable.Member.Kind.method
        for d in decos {
            switch d.split(separator: ".").last.map(String.init) ?? d {
            case "staticmethod": kind = .staticMethod
            case "classmethod": kind = .classMethod
            case "property", "cached_property": kind = .property
            default: break
            }
        }
        let (sig0, annotations) = signature(s)
        let selfName = kind == .staticMethod ? nil : sig0.parameters.first?.name
        let fn = function(s, selfName: kind == .method || kind == .property ? selfName : nil)
        guard let sig = fn.overloads.first else { return }
        if kind == .property {
            members[name] = TypeTable.Member(name: name, kind: .property, flags: [], type: sig.returnType, overloads: [])
        } else if isOverload(s), let existing = members[name], existing.kind == kind {
            members[name] = TypeTable.Member(name: name, kind: kind, flags: [], type: nil, overloads: existing.overloads + [sig])
        } else {
            members[name] = TypeTable.Member(name: name, kind: kind, flags: [], type: nil, overloads: [sig])
        }
        // `self.x = …` in any method: instance fields.
        guard kind == .method, let selfName, let block = s.firstChild(.block) else { return }
        block.walk { n in
            switch n.kind {
            case .funcDef, .classDef, .lambda: return false
            case .assign, .annAssign:
                let ps = n.parts
                guard let target = ps.first, target.kind == .member, let object = target.parts.first, object.kind == .name,
                      string(object) == selfName, let attr = target.parts.last, attr.kind == .name else { return false }
                let field = string(attr)
                var type: String?
                if n.kind == .annAssign, ps.count >= 2 {
                    type = typeText(ps[1])
                } else if let value = ps.last, ps.count >= 2 {
                    type = valueType(value, params: annotations)
                    if type == "Self" { type = nil }
                }
                if let existing = members[field] {
                    // An annotation beats an inferred type; a method keeps its kind.
                    guard existing.kind == .field, existing.type == nil || n.kind == .annAssign, type != nil else { return false }
                }
                members[field] = TypeTable.Member(name: field, kind: .field, flags: [], type: type, overloads: [])
                return false
            default:
                return true
            }
        }
    }

    // MARK: - Result

    func result() -> PythonModuleSummary {
        func sorted<T>(_ d: [String: T], _ key: (T) -> String) -> [T] {
            d.values.sorted { key($0).utf8.lexicographicallyPrecedes(key($1).utf8) }
        }
        let stub = PythonModuleStub(name: context.key, isPackage: context.isPackage, all: all,
                                    imports: sorted(imports) { $0.localName }, starImports: stars,
                                    typeVars: sorted(typeVars) { $0.name }, aliases: sorted(aliases) { $0.name },
                                    variables: sorted(variables) { $0.name }, functions: sorted(functions) { $0.name },
                                    classes: sorted(classes) { $0.name })
        return PythonModuleSummary(stub: stub, kinds: nil, dependencies: dependencies)
    }
}
