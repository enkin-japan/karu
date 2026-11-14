import Foundation
import Testing
@testable import KaruCore

// M17 T17.10 — built-in type tables: lookups the inference (T17.11) relies on,
// laziness, the LRU, and that every stored type text parses with `TypeExpr`.

private func makeStore(cap: Int = TypeTableStore.defaultCacheByteLimit) -> TypeTableStore {
    TypeTableStore(cacheByteLimit: cap)
}

private func returns(_ m: TypeTable.Member?) -> [String] {
    m?.overloads.map { $0.returnType ?? "" } ?? []
}

@Suite("TypeTable Python")
struct TypeTablePythonTests {
    let store = makeStore()

    @Test func strSplitReturnsListOfStr() throws {
        let str = try #require(store.pythonModule("builtins")?.class(named: "str"))
        let split = try #require(str.member(named: "split"))
        #expect(split.kind == .method)
        #expect(returns(split).contains("list[str]"))
        let plain = try #require(split.overloads.first { $0.returnType == "list[str]" })
        #expect(plain.parameters.map(\.name) == ["self", "sep", "maxsplit"])
        #expect(plain.parameters[1].type == "str | None" && plain.parameters[1].hasDefault)
        #expect(TypeExpr.parse("list[str]", syntax: .python) == .generic(.name("list"), [.name("str")]))
    }

    @Test func listAppendAndTypeParameters() throws {
        let list = try #require(store.pythonModule("builtins")?.class(named: "list"))
        #expect(list.typeParameters.map(\.name) == ["_T"])
        let append = try #require(list.member(named: "append"))
        let sig = try #require(append.overloads.first)
        #expect(sig.parameters.map(\.name) == ["self", "object"])
        #expect(sig.parameters.last?.type == "_T" && sig.parameters.last?.kind == .positionalOnly)
        #expect(sig.returnType == "None")
    }

    @Test func dictGetOverloads() throws {
        let dict = try #require(store.pythonModule("builtins")?.class(named: "dict"))
        #expect(dict.typeParameters.map(\.name) == ["_KT", "_VT"])
        let get = try #require(dict.member(named: "get"))
        #expect(get.overloads.count >= 3)
        #expect(returns(get).contains("_VT | None"))
        #expect(TypeExpr.parse("_VT | None", syntax: .python) == .union([.name("_VT"), .name("None")]))
    }

    @Test func osPathJoinThroughReexport() throws {
        // os.path is `from posixpath import *` on darwin.
        let osPath = try #require(store.pythonModule("os.path"))
        #expect(osPath.starImports == ["posixpath"])
        #expect(store.pythonResolve(module: "os", name: "path") == .module("os.path"))
        guard case .function(let module, let join)? = store.pythonResolve(dotted: "os.path.join") else {
            Issue.record("os.path.join did not resolve to a function"); return
        }
        #expect(module == "posixpath")
        #expect(join.overloads.contains { $0.returnType == "str" })
        // os re-exports `sep` from os.path.
        #expect(store.pythonModule("os")?.import(named: "sep")?.isReexport == true)
    }

    @Test func pathlibPathReadText() throws {
        guard case .class(_, let path)? = store.pythonResolve(dotted: "pathlib.Path") else {
            Issue.record("pathlib.Path missing"); return
        }
        #expect(path.member(named: "read_text")?.overloads.first?.returnType == "str")
        #expect(path.bases == ["PurePath"])
        #expect(path.member(named: "from_uri") != nil)            // 3.13
    }

    @Test func collectionsDefaultdictTypeParameters() throws {
        let dd = try #require(store.pythonModule("collections")?.class(named: "defaultdict"))
        #expect(dd.typeParameters.map(\.name) == ["_KT", "_VT"])
        #expect(dd.bases == ["dict[_KT, _VT]"])
        #expect(dd.member(named: "default_factory")?.type == "Callable[[], _VT] | None")
        if case .union(let parts)? = TypeExpr.parse("Callable[[], _VT] | None", syntax: .python),
           case .function(let fn) = parts[0] {
            #expect(fn.parameters.isEmpty && fn.returnType == .name("_VT"))
        } else {
            Issue.record("Callable did not parse as a function type")
        }
    }

    @Test func dataclassesFieldAndTypingOptional() throws {
        guard case .function(_, let field)? = store.pythonResolve(dotted: "dataclasses.field") else {
            Issue.record("dataclasses.field missing"); return
        }
        #expect(field.overloads.count >= 3)
        #expect(field.overloads.allSatisfy { $0.parameters.allSatisfy { $0.kind == .keywordOnly } })
        guard case .variable(_, let optional)? = store.pythonResolve(module: "typing", name: "Optional") else {
            Issue.record("typing.Optional missing"); return
        }
        #expect(optional.type == "_SpecialForm")
        #expect(TypeExpr.parse("Optional[int]", syntax: .python) == .union([.name("int"), .name("None")]))
    }

    @Test func reMatchGroupAndJsonLoads() throws {
        let match = try #require(store.pythonModule("re")?.class(named: "Match"))
        #expect(match.typeParameters.map(\.name) == ["AnyStr"])
        #expect((match.member(named: "group")?.overloads.count ?? 0) >= 2)
        guard case .function(_, let loads)? = store.pythonResolve(dotted: "json.loads") else {
            Issue.record("json.loads missing"); return
        }
        #expect(loads.overloads.first?.returnType == "Any")
        #expect(loads.overloads.first?.parameters.first?.name == "s")
    }

    @Test func evaluatedForPython313OnDarwin() throws {
        // Added in 3.13.
        #expect(store.pythonModule("copy")?.function(named: "replace") != nil)
        #expect(store.pythonModule("warnings")?.class(named: "deprecated") != nil)
        #expect(store.pythonModule("builtins")?.class(named: "PythonFinalizationError") != nil)
        // Removed before 3.13 (module-level, VERSIONS, and inside a module).
        #expect(!store.hasPythonModule("distutils"))
        #expect(!store.hasPythonModule("asynchat"))
        #expect(!store.hasPythonModule("cgi"))                    // removed in 3.13
        #expect(store.pythonModule("inspect")?.function(named: "getargspec") == nil)
        // Not yet in 3.13.
        #expect(!store.hasPythonModule("annotationlib"))
        // Platform: darwin, not win32.
        #expect(store.pythonModule("os")?.function(named: "fork") != nil)
        #expect(store.pythonModule("os")?.function(named: "startfile") == nil)
    }
}

@Suite("TypeTable TypeScript")
struct TypeTableTypeScriptTests {
    let store = makeStore()

    @Test func arrayMapIsGeneric() throws {
        let array = try #require(store.tsSymbol("Array"))
        #expect(array.section == .es)
        #expect(array.variable?.type == "ArrayConstructor")
        let iface = try #require(array.interface)
        #expect(iface.typeParameters.map(\.name) == ["T"])
        let map = try #require(iface.member(named: "map")?.overloads.first)
        #expect(map.typeParameters.map(\.name) == ["U"])
        #expect(map.returnType == "U[]")
        #expect(TypeExpr.parse("U[]", syntax: .typescript) == .array(.name("U")))
        let callback = try #require(map.parameters.first?.type)
        guard case .function(let fn)? = TypeExpr.parse(callback, syntax: .typescript) else {
            Issue.record("callback is not a function type: \(callback)"); return
        }
        #expect(fn.parameters.map(\.name) == ["value", "index", "array"])
        #expect(fn.returnType == .name("U"))
        // Merged across lib files: es2023.array adds findLast.
        #expect((iface.member(named: "findLast")?.overloads.count ?? 0) >= 2)
        #expect(iface.member(named: "includes") != nil)            // es2016
        #expect(iface.member(named: "[Symbol.iterator]") != nil)   // es2015.iterable
    }

    @Test func stringPromiseMapJson() throws {
        let string = try #require(store.tsSymbol("String")?.interface)
        for name in ["charAt", "split", "replaceAll", "at", "padStart", "toUpperCase"] {
            #expect(string.member(named: name) != nil, "String.\(name)")
        }
        let then = try #require(store.tsSymbol("Promise")?.interface?.member(named: "then")?.overloads.first)
        #expect(then.typeParameters.map(\.name) == ["TResult1", "TResult2"])
        #expect(then.returnType == "Promise<TResult1 | TResult2>")
        let map = try #require(store.tsSymbol("Map"))
        #expect(map.interface?.typeParameters.map(\.name) == ["K", "V"])
        #expect(map.interface?.member(named: "get")?.overloads.first?.returnType == "V | undefined")
        #expect(map.variable?.type == "MapConstructor")
        let json = try #require(store.tsSymbol("JSON"))
        #expect(json.variable?.type == "JSON")
        #expect((json.interface?.member(named: "parse")?.overloads.first?.returnType) == "any")
        #expect(store.statistics.domSectionLookups == 0)
    }

    @Test func intlNamespace() throws {
        let intl = try #require(store.tsSymbol("Intl"))
        #expect(intl.namespaceMembers?.contains("DateTimeFormat") == true)
        let dtf = try #require(store.tsSymbol("Intl.DateTimeFormat"))
        #expect(dtf.interface?.member(named: "format") != nil)
        #expect(dtf.interface?.member(named: "formatRange") != nil)  // es2021.intl merge
        #expect(dtf.variable != nil)
        #expect(store.statistics.domSectionLookups == 0)
    }

    @Test func domSymbols() throws {
        let console = try #require(store.tsSymbol("console"))
        #expect(console.section == .dom && console.variable?.type == "Console")
        #expect(store.tsSymbol("Console")?.interface?.member(named: "log") != nil)
        #expect(store.tsSymbol("document")?.variable?.type == "Document")
        let element = try #require(store.tsSymbol("HTMLElement"))
        #expect(element.section == .dom)
        #expect(element.interface?.bases.contains("Element") == true)
        let listen = try #require(element.interface?.member(named: "addEventListener"))
        #expect(listen.overloads.count >= 2)
        #expect(listen.overloads.first?.typeParameters.map(\.name) == ["K"])
        #expect(listen.overloads.first?.typeParameters.first?.bound == "keyof HTMLElementEventMap")
        #expect(store.tsSymbol("HTMLElement", includeDOM: false) == nil)
        // ES symbol augmented by DOM: both parts are reachable.
        #expect(store.tsSymbol("ImportMeta")?.isDOMAugmented == true)
        #expect(store.tsSymbol("ImportMeta", in: .dom)?.interface?.member(named: "url") != nil)
    }
}

@Suite("TypeTable store")
struct TypeTableStoreTests {
    @Test func openingDecodesNothingAndESNeverTouchesDOM() throws {
        let store = makeStore()
        #expect(store.statistics == TypeTableStore.Statistics())
        for name in ["Array", "Promise", "Map", "JSON", "String", "Intl.DateTimeFormat", "Object", "Math"] {
            #expect(store.tsSymbol(name) != nil, "\(name)")
        }
        let stats = store.statistics
        #expect(stats.mappedFiles == 1)
        #expect(stats.domSectionLookups == 0)
        #expect(stats.decodedEntries == 8)
        // Second query is a cache hit.
        _ = store.tsSymbol("Array")
        #expect(store.statistics.decodedEntries == 8)
        #expect(store.statistics.esSectionLookups == stats.esSectionLookups)
    }

    @Test func lruRespectsByteCapAndReleaseUnmaps() throws {
        let store = makeStore(cap: 256 * 1024)
        for module in ["builtins", "typing", "os", "collections", "re", "json", "pathlib"] {
            #expect(store.pythonModule(module) != nil)
        }
        let stats = store.statistics
        #expect(stats.evictions > 0)
        #expect(stats.cachedEntries >= 1)
        // Over the cap only when the newest entry alone exceeds it.
        #expect(stats.cachedBytes <= 256 * 1024 || stats.cachedEntries == 1)
        store.release()
        let released = store.statistics
        #expect(released.mappedFiles == 0 && released.cachedEntries == 0 && released.cachedBytes == 0)
        #expect(store.pythonModule("json") != nil)                   // maps again
    }

    @Test func missingDirectoryYieldsNothing() {
        let store = TypeTableStore(directory: URL(fileURLWithPath: "/nonexistent-karu-type-tables"))
        #expect(store.pythonModule("builtins") == nil)
        #expect(store.tsSymbol("Array") == nil)
        #expect(store.statistics.mappedFiles == 0)
    }

    @Test func lookupOrderEndsWithRepositoryAssets() throws {
        let dirs = TypeTableStore.searchDirectories()
        #expect(dirs.last?.path.hasSuffix("assets/typetables") == true)
        #expect(makeStore().locate(TypeTableStore.pythonFileName) != nil)
    }
}

// MARK: - Every stored type text parses

private func pythonTexts(_ stub: PythonModuleStub) -> [String] {
    var out: [String] = []
    func tp(_ p: TypeTable.TypeParameter) { out += [p.bound, p.defaultType].compactMap { $0 } }
    func sig(_ s: TypeTable.Signature) {
        s.typeParameters.forEach(tp)
        out += s.parameters.compactMap(\.type)
        if let r = s.returnType { out.append(r) }
    }
    func cls(_ c: TypeTable.ClassDecl) {
        c.typeParameters.forEach(tp)
        out += c.bases
        for m in c.members {
            if let t = m.type { out.append(t) }
            m.overloads.forEach(sig)
        }
        (c.callSignatures + c.constructSignatures).forEach(sig)
        for i in c.indexSignatures { out += [i.keyType, i.valueType] }
    }
    stub.typeVars.forEach(tp)
    for a in stub.aliases { a.typeParameters.forEach(tp); out.append(a.type) }
    out += stub.variables.compactMap(\.type)
    stub.functions.forEach { $0.overloads.forEach(sig) }
    stub.classes.forEach(cls)
    return out
}

private func tsTexts(_ symbol: TSGlobalSymbol) -> [String] {
    let shell = PythonModuleStub(
        name: symbol.name, isPackage: false, all: nil, imports: [], starImports: [], typeVars: [],
        aliases: symbol.alias.map { [$0] } ?? [], variables: symbol.variable.map { [$0] } ?? [],
        functions: symbol.function.map { [$0] } ?? [], classes: symbol.interface.map { [$0] } ?? [])
    return pythonTexts(shell)
}

@Suite("TypeTable validation")
struct TypeTableValidationTests {
    @Test func everyPythonTypeTextParses() throws {
        let store = makeStore(cap: 1 << 30)
        let names = store.pythonModuleNames()
        #expect(names.count > 500)
        var total = 0
        var failures: [String] = []
        for name in names {
            let stub = try #require(store.pythonModule(name), "module \(name) failed to decode")
            for text in pythonTexts(stub) {
                total += 1
                if TypeExpr.parse(text, syntax: .python) == nil { failures.append("\(name): \(text)") }
            }
        }
        print("[T17.10] python type texts: \(total), parse failures: \(failures.count)")
        #expect(failures.isEmpty, "\(failures.prefix(20))")
        #expect(total > 40_000)
    }

    @Test func everyTypeScriptTypeTextParses() throws {
        let store = makeStore(cap: 1 << 30)
        var total = 0
        var failures: [String] = []
        for section in [TSGlobalSymbol.Section.es, .dom] {
            let names = store.tsSymbolNames(in: section)
            #expect(!names.isEmpty)
            for name in names {
                let symbol = try #require(store.tsSymbol(name, in: section), "symbol \(name) failed to decode")
                for text in tsTexts(symbol) {
                    total += 1
                    if TypeExpr.parse(text, syntax: .typescript) == nil { failures.append("\(name): \(text)") }
                }
            }
        }
        print("[T17.10] typescript type texts: \(total), parse failures: \(failures.count)")
        #expect(failures.isEmpty, "\(failures.prefix(20))")
        #expect(total > 20_000)
    }
}

// MARK: - TypeExpr grammar

@Suite("TypeExpr")
struct TypeExprTests {
    private func py(_ s: String) -> TypeExpr? { TypeExpr.parse(s, syntax: .python) }
    private func ts(_ s: String) -> TypeExpr? { TypeExpr.parse(s, syntax: .typescript) }

    @Test func pythonForms() {
        #expect(py("os.PathLike[str]") == .generic(.name("os.PathLike"), [.name("str")]))
        #expect(py("Union[int, str, None]") == .union([.name("int"), .name("str"), .name("None")]))
        #expect(py("typing.Optional[Union[int, str]]") == .union([.name("int"), .name("str"), .name("None")]))
        #expect(py("tuple[int, ...]") == .generic(.name("tuple"), [.name("int"), .ellipsis]))
        #expect(py("tuple[()]") == .generic(.name("tuple"), [.generic(.name("tuple"), [])]))
        #expect(py("Literal['r', b'x', -1, True]") == .generic(.name("Literal"),
                                                              [.literal("'r'"), .literal("b'x'"), .literal("-1"), .name("True")]))
        if case .function(let fn)? = py("Callable[..., Awaitable[_T]]") {
            #expect(fn.acceptsAnyArguments && fn.returnType == .generic(.name("Awaitable"), [.name("_T")]))
        } else { Issue.record("Callable[..., R]") }
        if case .function(let fn)? = py("Callable[Concatenate[int, _P], _R]") {
            #expect(fn.parameterSpec == .generic(.name("Concatenate"), [.name("int"), .name("_P")]))
        } else { Issue.record("Callable[P, R]") }
        #expect(py("tuple[*_Ts]") == .generic(.name("tuple"), [.unpacked(.name("_Ts"))]))
        #expect(py("") == nil)
        #expect(py("list[") == nil)
        #expect(py("int str") == nil)
    }

    @Test func typeScriptForms() {
        #expect(ts("Array<string>") == .generic(.name("Array"), [.name("string")]))
        #expect(ts("readonly string[]") == .array(.name("string")))
        #expect(ts("[start: number, end?: number, ...rest: string[]]") == .tuple([
            .init(name: "start", type: .name("number")),
            .init(name: "end", type: .name("number"), isOptional: true),
            .init(name: "rest", type: .array(.name("string")), isRest: true),
        ]))
        #expect(ts("HTMLElementEventMap[K]") == .indexed(.name("HTMLElementEventMap"), .name("K")))
        #expect(ts("keyof T") == .opaque(.keyof, "keyof T"))
        #expect(ts("typeof globalThis") == .opaque(.typeQuery, "typeof globalThis"))
        #expect(ts("'a' | \"b\" | 1 | -2 | true | null") == .union([
            .literal("'a'"), .literal("\"b\""), .literal("1"), .literal("-2"), .literal("true"), .name("null"),
        ]))
        if case .function(let fn)? = ts("<T>(this: HTMLElement, ev: T, ...args: any[]) => void") {
            #expect(fn.typeParameters == ["T"])
            #expect(fn.parameters.map(\.name) == ["this", "ev", "args"] && fn.parameters[2].isRest)
            #expect(fn.returnType == .name("void"))
        } else { Issue.record("function type") }
        if case .function(let fn)? = ts("abstract new (...args: any) => any") {
            #expect(fn.isConstructor)
        } else { Issue.record("constructor type") }
        if case .object(let members)? = ts("{ prototype: X; new (s?: string): X; readonly a?: number; m<T>(x: T): T; [key: string]: any; get v(): string; }") {
            #expect(members.map(\.kind) == [.property, .construct, .property, .method, .index, .getter])
            #expect(members[2].isOptional && members[2].isReadonly)
        } else { Issue.record("object type") }
        #expect(ts("{ [P in keyof T]?: T[P]; }") == .opaque(.mapped, "{ [P in keyof T]?: T[P]; }"))
        let conditional = "T extends PromiseLike<infer U> ? Awaited<U> : T"
        #expect(ts(conditional) == .opaque(.conditional, conditional))
        let returnType = "T extends (...args: any) => infer R ? R : any"
        #expect(ts(returnType) == .opaque(.conditional, returnType))
        #expect(ts("value is S") == .opaque(.predicate, "value is S"))
        #expect(ts("asserts this is T") == .opaque(.predicate, "asserts this is T"))
        #expect(ts("`${A}-${B}`") == .literal("`${A}-${B}`"))
        #expect(ts("unique symbol") == .opaque(.uniqueSymbol, "unique symbol"))
        #expect(ts("((a: string) => void) | null") != nil)
        #expect(ts("A & (B | C)") == .intersection([.name("A"), .union([.name("B"), .name("C")])]))
        #expect(ts("Array<") == nil)
        #expect(ts("(a: string") == nil)
    }
}
