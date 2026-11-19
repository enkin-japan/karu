import AppKit
import Foundation
import Testing
@testable import KaruCore

// M17 T17.11c — type inference for JavaScript / TypeScript member completion
// (plan §8.1 JS / TS column, §5.4, §13): each capability, JSDoc, narrowing,
// incomplete code, the precision rules (unions, `any` / `unknown`,
// optional members, index signatures), DOM laziness, caches and release,
// and the completion wiring (TS-syntax summaries, JSX positions).

private func isolatedDefaults() -> (UserDefaults, () -> Void) {
    let name = "ScriptInferenceTests-\(UUID().uuidString)"
    let d = TestDefaults.make(name)
    d.removePersistentDomain(forName: name)
    return (d, { d.removePersistentDomain(forName: name) })
}

/// A JS / TS document in a text view with its analysis and an inference
/// service. `source` marks the caret with `|` (after `receiver.` and an
/// optional member prefix).
@MainActor
private final class ScriptInference {
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
    let analysis: DocumentAnalysis
    let service: TypeInferenceService
    let tables: ScriptTypeTables
    let caret: Int
    let language: String
    let hub = TextStorageObserverHub()
    private let clean: () -> Void

    init(_ source: String, language: String = "typescript", tables: ScriptTypeTables? = nil) {
        let ns = source as NSString
        let bar = ns.range(of: "|", options: .backwards)
        precondition(bar.location != NSNotFound, "mark the caret with |")
        caret = bar.location
        self.language = language
        textView.string = ns.replacingCharacters(in: bar, with: "")
        let (defaults, clean) = isolatedDefaults()
        self.clean = clean
        analysis = DocumentAnalysis(textView: textView, moduleSettings: ModuleSettings(defaults: defaults, center: NotificationCenter()),
                                    moduleCenter: NotificationCenter(), scheduler: AnalysisScheduler())
        analysis.setLanguage(identifier: language)
        self.tables = tables ?? .shared
        service = TypeInferenceService(tables: .shared, scriptTables: self.tables)
        hub.add(analysis)
        textView.textStorage?.delegate = hub
    }

    deinit { clean() }

    var text: NSString { textView.textStorage!.mutableString }

    var dot: Int {
        let start = IdentifierText.runStart(before: caret, in: text, dollar: true) ?? caret
        return start - 1
    }

    /// Candidates in the engine's ranking order (no prefix filtering).
    var candidates: [Candidate]? {
        service.memberCandidates(analysis: analysis, text: text, dot: dot).map { CandidateEngine.ranked($0) }
    }

    var names: [String]? { candidates?.map(\.name) }

    func detail(_ name: String) -> String? { candidates?.first { $0.name == name }?.detail }

    /// The receiver's type, straight from an evaluator.
    var receiver: InferredType {
        guard let snapshot = analysis.ensureSyntax(), let tree = snapshot.tree,
              let dialect = SyntaxDialect(languageIdentifier: language) else { return .unknown }
        let module = PyModuleView(storage: .tree(PyUnit(tree)), text: text, dialect: dialect, parseStatement: { _ in nil })
        guard let stmt = module.topLevelStatement(containing: dot),
              let member = TypeInferenceService.scriptMemberNode(in: stmt, dot: dot) else { return .unknown }
        let evaluator = ScriptEvaluator(text: text, module: module, tables: tables,
                                        returnCache: ByteLRU(byteLimit: 1 << 20), dialect: dialect, budget: InferenceBudget())
        defer { evaluator.tearDown() }
        return evaluator.receiverType(of: member)
    }
}

@MainActor private func names(_ source: String, _ language: String = "typescript") -> [String]? {
    ScriptInference(source, language: language).names
}

@MainActor private func receiver(_ source: String, _ language: String = "typescript") -> InferredType {
    ScriptInference(source, language: language).receiver
}

private let string = InferredType.instance(.table("es", "String"), [])
private let number = InferredType.instance(.table("es", "Number"), [])
private let boolean = InferredType.instance(.table("es", "Boolean"), [])

// MARK: - Explicit types

@Suite("ScriptInference explicit types")
@MainActor
struct ScriptInferenceExplicitTests {
    @Test func annotationsAndPrimitives() throws {
        let list = try #require(names("function f(name: string) {\n  name.|\n}"))
        #expect(list.contains("toUpperCase") && list.contains("padStart"))
        #expect(!list.contains("push") && !list.contains("toFixed"))
        #expect(receiver("function f(n: number) {\n  n.|\n}") == number)
        #expect(receiver("let flag: boolean = true\nflag.|") == boolean)
    }

    @Test func interfacesWithOptionalMembersAndMerging() throws {
        let src = """
        interface User { id: number; email: string; profile?: Profile }
        interface Profile { avatarUrl: string; bio: string }
        interface User { nickname: string }
        function f(u: User) {
          u.|
        }
        """
        let list = try #require(names(src))
        #expect(Set(list.prefix(4)) == ["id", "email", "profile", "nickname"])
        #expect(!list.contains("avatarUrl"))
    }

    @Test func optionalChainingAndNonNull() throws {
        let src = """
        interface User { profile?: Profile }
        interface Profile { avatarUrl: string; bio: string }
        function f(u: User) {
          u.profile?.|
        }
        """
        #expect(try #require(names(src)).starts(with: ["avatarUrl", "bio"]))
        let bang = src.replacingOccurrences(of: "u.profile?.|", with: "u.profile!.|")
        #expect(try #require(names(bang)).starts(with: ["avatarUrl", "bio"]))
        // Unnarrowed optional member: the defined part's members (like `Optional[X]`).
        let plain = src.replacingOccurrences(of: "u.profile?.|", with: "u.profile.|")
        #expect(try #require(names(plain)).contains("bio"))
    }

    @Test func typeAliasesGenericsAndUnions() {
        let src = """
        type Maybe<T> = T | undefined;
        interface Page<T> { items: T[]; cursor: Maybe<string> }
        function f(p: Page<Date>) {
          p.items[0].|
        }
        """
        #expect(receiver(src) == .instance(.table("es", "Date"), []))
        #expect(receiver("type Id = string;\nfunction f(x: Id) {\n  x.|\n}") == string)
        let cursor = "interface Page { cursor: string | undefined }\nfunction f(p: Page) {\n  p.cursor.|\n}"
        #expect(receiver(cursor) == .union([string, .none]))
    }

    @Test func classesFieldsParameterPropertiesAccessorsAndStatics() throws {
        let src = """
        class Store<T> {
          private readonly items = new Map<string, T>();
          count = 0;
          static instances = 0;
          constructor(private readonly endpoint: string, public label: string) {}
          get size(): number { return this.items.size; }
          add(key: string, value: T): void { this.items.set(key, value); }
          static create(): Store<number> { return new Store<number>("", ""); }
        }
        function use(s: Store<Date>) {
          s.|
        }
        """
        let list = try #require(names(src))
        for name in ["count", "label", "size", "add"] { #expect(list.contains(name), "\(name)") }
        // Private / static members are not listed outside the class.
        for name in ["items", "endpoint", "instances", "create", "constructor"] { #expect(!list.contains(name), "\(name)") }
        let statics = try #require(names(src.replacingOccurrences(of: "s.|", with: "Store.|")))
        #expect(statics.prefix(2).contains("instances") && statics.contains("create"))
        #expect(!statics.contains("count"))
        // `this.` inside the class sees private members.
        let inside = src.replacingOccurrences(of: "s.|", with: "s.count")
            .replacingOccurrences(of: "this.items.set(key, value);", with: "this.|")
        let mine = try #require(names(inside))
        #expect(mine.contains("items") && mine.contains("endpoint"))
        #expect(receiver(src.replacingOccurrences(of: "s.|", with: "s.size.|")) == number)
    }

    @Test func extendsAndImplements() throws {
        let src = """
        interface Named { name: string }
        class Base { greet(): string { return "hi"; } }
        class Child extends Base implements Named {
          name = "c";
          shout() { return this.greet().toUpperCase(); }
        }
        new Child().|
        """
        let list = try #require(names(src))
        #expect(list.starts(with: ["name", "shout"]))
        #expect(list.contains("greet"))
        let err = "class AppError extends Error { code = 1 }\nnew AppError().|"
        let errors = try #require(names(err))
        #expect(errors.first == "code" && errors.contains("message") && errors.contains("stack"))
    }

    @Test func genericClassesGettersAndThisTypes() throws {
        let src = """
        class Box<T> {
          constructor(public value: T) {}
          get first(): T { return this.value; }
          map<U>(f: (v: T) => U): Box<U> { return new Box(f(this.value)); }
          self(): this { return this; }
        }
        new Box(5).value.|
        """
        #expect(receiver(src) == number)
        #expect(receiver(src.replacingOccurrences(of: "new Box(5).value.|", with: "new Box('a').first.|"))
                == string)
        #expect(receiver(src.replacingOccurrences(of: "new Box(5).value.|", with: "new Box(5).map(v => [v]).value.|"))
                == .instance(.table("es", "Array"), [number]))
        #expect(receiver(src.replacingOccurrences(of: "new Box(5).value.|", with: "new Box<Date>(new Date()).self().value.|"))
                == .instance(.table("es", "Date"), []))
        let typed = try #require(names(src.replacingOccurrences(of: "new Box(5).value.|", with: "new Box(5).|")))
        #expect(Set(typed) == ["value", "first", "map", "self"])
    }

    @Test func enums() throws {
        let src = "enum Status { Draft = \"draft\", Open = \"open\" }\nStatus.|"
        #expect(try #require(names(src)) == ["Draft", "Open"])
        #expect(receiver("enum Status { Draft = \"draft\" }\nfunction f(s: Status) {\n  s.|\n}") == string)
    }
}

// MARK: - Inference

@Suite("ScriptInference values")
@MainActor
struct ScriptInferenceValueTests {
    @Test func literalsAndObjectLiteralShapes() throws {
        #expect(receiver("const s = 'abc';\ns.|") == .literal(.table("es", "String"), "'abc'"))
        let list = try #require(names("const config = { host: 'localhost', port: 8080, start() { return 1; } };\nconfig.|"))
        #expect(list == ["host", "port", "start"])
        #expect(ScriptInference("const config = { host: 'localhost', port: 8080 };\nconfig.|").detail("port") == "number")
        #expect(receiver("const c = { host: 'h' };\nc.host.|") == string)
    }

    @Test func arraysAndElementTypes() {
        #expect(receiver("const xs = [1, 2];\nxs[0].|") == number)
        #expect(receiver("const xs: string[] = [];\nxs.|") == .instance(.table("es", "Array"), [string]))
        #expect(receiver("function f() {\n  const xs = [];\n  xs.push('a');\n  xs[0].|\n}", "javascript") == string)
        #expect(receiver("const xs = ['a'];\nconst ys = xs.map(x => x.length);\nys[0].|") == number)
        #expect(receiver("const xs = ['a'];\nfor (const x of xs) {\n  x.|\n}") == string)
        #expect(receiver("const m = new Map<string, Date>();\nfor (const [k, v] of m) {\n  v.|\n}") == .instance(.table("es", "Date"), []))
        #expect(receiver("const xs = ['a'];\nxs.find(x => x.length > 1).|") == .union([string, .none]))
    }

    @Test func returnTypesAsyncAndAwait() {
        let src = """
        function make() {
          if (Math.random() > 0.5) { return { name: 'Ada', age: 36 }; }
          return { name: 'Bob', age: 1 };
        }
        make().|
        """
        if case .shape(let shape) = receiver(src) {
            #expect(shape.members.map(\.name) == ["name", "age"])
        } else {
            Issue.record("not a shape")
        }
        let async = """
        async function load(): Promise<{ data: string[]; total: number }> { return { data: [], total: 0 }; }
        async function use() {
          const { data } = await load();
          data.|
        }
        """
        #expect(receiver(async) == .instance(.table("es", "Array"), [string]))
        let inferredAsync = "async function n() { return 1; }\nasync function use() {\n  (await n()).|\n}"
        #expect(receiver(inferredAsync) == number)
        #expect(receiver("async function use() {\n  const res = await fetch('x');\n  res.|\n}", "javascript")
                == .instance(.table("dom", "Response"), []))
    }

    @Test func genericFunctionsSolveTypeParameters() {
        let src = """
        function wrap<T>(value: T): { value: T; at: Date } { return { value, at: new Date() }; }
        wrap(42).value.|
        """
        #expect(receiver(src) == number)
        let first = "function firstOrDefault<T>(values: T[], fallback: T): T { return values[0]; }\nfirstOrDefault(['a'], 'b').|"
        #expect(receiver(first) == string)
    }

    @Test func destructuringBindings() {
        #expect(receiver("const { a, b: [c] } = { a: 'x', b: [1] };\nc.|") == number)
        #expect(receiver("const [x, y] = ['a', 1] as [string, number];\ny.|") == number)
        #expect(receiver("function f({ id }: { id: string }) {\n  id.|\n}") == string)
    }

    @Test func callbacksGetContextualParameterTypes() {
        let src = """
        interface Item { id: number; label: string }
        function f(items: Item[]) {
          items.forEach((item) => {
            item.|
          });
        }
        """
        #expect(receiver(src) == .instance(.document("Item"), []))
        let reduce = "const xs = [1, 2];\nxs.reduce((acc, x) => { acc.|; return acc; }, '');"
        #expect(receiver(reduce) == string)
    }

    @Test func importsAreUnknownUntilT1713() {
        #expect(receiver("import { Map } from './collections';\nconst m = new Map();\nm.|") == .unknown)
        #expect(receiver("import fs from 'fs';\nfs.|") == .unknown)
        #expect(names("import * as path from 'path';\npath.|") == nil)
    }
}

// MARK: - JSDoc

@Suite("ScriptInference JSDoc")
@MainActor
struct ScriptInferenceJSDocTests {
    @Test func paramReturnsAndType() {
        #expect(receiver("/** @param {string} label */\nfunction show(label) {\n  return label.|\n}", "javascript") == string)
        #expect(receiver("/** @returns {number} */\nfunction n() { return x; }\nn().|", "javascript") == number)
        #expect(receiver("/** @type {Map<string, Date>} */\nconst m = new Map();\nm.get('a').|", "javascript")
                == .union([.instance(.table("es", "Date"), []), .none]))
        #expect(receiver("/**\n * @param {?string} [name] the name\n */\nfunction f(name) {\n  name.|\n}", "javascript")
                == .union([string, .none]))
        // JSDoc is not read in TypeScript (annotations are).
        #expect(receiver("/** @param {string} label */\nfunction show(label) {\n  return label.|\n}") == .unknown)
    }

    @Test func typedefAndTemplate() throws {
        let src = """
        /**
         * @typedef {Object} Point
         * @property {number} x
         * @property {number} y
         */
        /** @param {Point} p */
        function f(p) {
          p.|
        }
        """
        #expect(try #require(names(src, "javascript")) == ["x", "y"])
        let alias = "/** @typedef {string[]} Names */\n/** @param {Names} n */\nfunction f(n) {\n  n.|\n}"
        #expect(receiver(alias, "javascript") == .instance(.table("es", "Array"), [string]))
        let template = "/**\n * @template T\n * @param {T} v\n * @returns {T}\n */\nfunction id(v) { return v; }\nid('a').|"
        #expect(receiver(template, "javascript") == string)
    }
}

// MARK: - Narrowing

@Suite("ScriptInference narrowing")
@MainActor
struct ScriptInferenceNarrowingTests {
    @Test func typeofAndEarlyReturn() {
        #expect(receiver("function f(v) {\n  if (typeof v === 'string') {\n    v.|\n  }\n}", "javascript") == string)
        let union = "function f(v: string | number) {\n  if (typeof v !== 'number') return;\n  v.|\n}"
        #expect(receiver(union) == number)
        let early = "function f(v?: string) {\n  if (!v) {\n    return;\n  }\n  v.|\n}"
        #expect(receiver(early) == string)
    }

    @Test func instanceofInAndDiscriminants() throws {
        let shapes = """
        interface Circle { kind: 'circle'; radius: number }
        interface Square { kind: 'square'; side: number }
        type Shape = Circle | Square;
        function area(s: Shape) {
          if ('radius' in s) {
            s.|
          }
        }
        """
        let list = try #require(names(shapes))
        #expect(list.contains("radius") && list.contains("kind") && !list.contains("side"))
        let disc = shapes.replacingOccurrences(of: "if ('radius' in s)", with: "if (s.kind === 'square')")
        #expect(receiver(disc) == .instance(.document("Square"), []))
        let sw = shapes.replacingOccurrences(of: "if ('radius' in s) {", with: "switch (s.kind) {\n case 'circle':")
        #expect(receiver(sw) == .instance(.document("Circle"), []))
        let inst = "function f(e: Date | RegExp) {\n  if (e instanceof RegExp) {\n    e.|\n  }\n}"
        #expect(receiver(inst) == .instance(.table("es", "RegExp"), []))
    }

    @Test func nullChecksTruthinessAndLogicalOperators() {
        #expect(receiver("function f(s: string | null) {\n  if (s !== null) {\n    s.|\n  }\n}") == string)
        #expect(receiver("function f(s: string | undefined) {\n  if (s) {\n    s.|\n  }\n}") == string)
        #expect(receiver("function f(s: string | undefined) {\n  s && s.|\n}") == string)
        #expect(receiver("function f(s: string | undefined) {\n  const t = s ?? 'x';\n  t.|\n}") == string)
        #expect(receiver("function f(v: string | string[]) {\n  if (Array.isArray(v)) {\n    v.|\n  }\n}")
                == .instance(.table("es", "Array"), [string]))
    }
}

// MARK: - Precision

@Suite("ScriptInference precision")
@MainActor
struct ScriptInferencePrecisionTests {
    @Test func anyUnknownAndUnresolvedAreUnknown() {
        #expect(names("function f(x: any) {\n  x.|\n}") == nil)
        #expect(names("function f(x: unknown) {\n  x.|\n}") == nil)
        #expect(names("function f(x) {\n  x.render();\n  x.|\n}", "javascript") == nil)
        #expect(names("undeclaredThing.|", "javascript") == nil)
        #expect(names("function f(x: string | any) {\n  x.|\n}") == nil)
    }

    @Test func unionsListOnlySharedMembers() throws {
        let src = """
        interface A { id: number; a: string }
        interface B { id: number; b: string }
        function f(x: A | B | undefined) {
          x.|
        }
        """
        #expect(try #require(names(src)) == ["id"])
    }

    @Test func indexSignaturesListNoArbitraryKeys() {
        #expect(names("function f(r: Record<string, number>) {\n  r.|\n}") == nil)
        let mixed = "interface Bag { [key: string]: number; size: number }\nfunction f(b: Bag) {\n  b.|\n}"
        #expect(names(mixed) == ["size"])
        #expect(receiver("function f(r: Record<string, Date>) {\n  r['x'].|\n}") == .instance(.table("es", "Date"), []))
    }

    @Test func otherClassesMembersNeverLeak() throws {
        let src = """
        class Counter { constructor() { this.count = 0; } increment() {} }
        class Basket { constructor() { this.fruits = []; } weigh() {} }
        new Counter().|
        """
        let list = try #require(names(src, "javascript"))
        #expect(list == ["count", "increment"])
    }

    @Test func selfReferenceIsBounded() throws {
        let field = "class A {\n  constructor() { this.n = 0; }\n  inc() { this.n = this.n + 1; this.m = this.m; }\n}\nnew A().n.|"
        #expect(receiver(field, "javascript") == number)
        #expect(names(field.replacingOccurrences(of: "new A().n.|", with: "new A().m.|"), "javascript") == nil)
        let tree = "type Tree = { children: Tree[]; label: string };\nfunction f(t: Tree) {\n  t.children[0].children[0].|\n}"
        #expect(try #require(names(tree)) == ["children", "label"])
        #expect(names("function f() { return f(); }\nf().|") == nil)
        #expect(names("const a = b;\nconst b = a;\na.|") == nil)
        _ = names("class A extends A { x = 1 }\nnew A().|")     // a cycle: no hang, no crash
        _ = names("interface I extends J { a: 1 }\ninterface J extends I { b: 2 }\nfunction f(i: I) {\n  i.|\n}")
    }

    @Test func incompleteCode() {
        let src = "function f() {\n  const options = { verbose: true,\n  const text = 'x';\n  text.|\n}"
        #expect(receiver(src, "javascript") == .literal(.table("es", "String"), "'x'"))
        #expect(receiver("function f(s: string) {\n  if (s.length > 1 {\n    s.|\n}") == string)
        #expect(receiver("const xs = ['a'];\nxs.map((x) => x.|") == string)
    }
}

// MARK: - Lib tables

@Suite("ScriptInference lib tables", .serialized)
@MainActor
struct ScriptInferenceLibTests {
    @Test func esOnlyDocumentNeverReadsTheDOMSection() throws {
        let store = TypeTableStore()
        let tables = ScriptTypeTables(store: store)
        let src = """
        const xs = [1, 2, 3];
        const m = new Map<string, number[]>();
        async function f() {
          const p = await Promise.resolve(xs);
          const total = p.reduce((a, b) => a + b, 0);
          JSON.stringify(total).|
        }
        """
        let i = ScriptInference(src, tables: tables)
        #expect(try #require(i.names).contains("padStart"))
        #expect(store.statistics.esSectionLookups > 0)
        #expect(store.statistics.domSectionLookups == 0)
        // A DOM global brings the DOM section in.
        let dom = ScriptInference("document.body.|", tables: tables)
        #expect(try #require(dom.names).contains("appendChild"))
        #expect(store.statistics.domSectionLookups > 0)
        tables.release()
        #expect(tables.isReleased && store.statistics.mappedFiles == 0)
    }

    @Test func libGlobalsAndNamespaces() throws {
        #expect(try #require(names("Array.|")).contains("isArray"))
        #expect(try #require(names("Math.|")).contains("floor"))
        #expect(try #require(names("Intl.|")).contains("DateTimeFormat"))
        #expect(receiver("new Intl.DateTimeFormat().|") == .instance(.table("es", "Intl.DateTimeFormat"), []))
        #expect(receiver("const d = new Date();\nd.toISOString().|") == string)
        #expect(receiver("Promise.resolve(1).then(x => x.toFixed()).|")
                == .instance(.table("es", "Promise"), [string]))
    }

    @Test func tsSyntaxSummaries() throws {
        let i = ScriptInference("const xs: string[] = [];\nxs.|")
        let map = try #require(i.detail("map"))
        #expect(map.hasPrefix("(callbackfn: (value: string, ") && map.hasSuffix(") -> U[]"))
        #expect(map.utf16.count <= InferredMemberList.detailLimit)
        #expect(i.detail("length") == "number")
        #expect(i.detail("push") == "(...items: string[]) -> number")
        let doc = ScriptInference("class C {\n  add(a: number, label?: string): string { return ''; }\n  n = 1;\n}\nnew C().|")
        #expect(doc.detail("add") == "(a: number, label?: string) -> string")
        #expect(doc.detail("n") == "number")
    }
}


// MARK: - Caches and budget

@Suite("ScriptInference caches", .serialized)
@MainActor
struct ScriptInferenceCacheTests {
    @Test func returnTypesAreCachedAcrossVersionsAndValidated() {
        let src = "function make() {\n  return 'x';\n}\nfunction use() {\n  make().|\n}"
        let i = ScriptInference(src)
        #expect(i.names?.contains("padStart") == true)
        let first = i.service.statistics
        #expect(first.returnInferences >= 1)
        i.textView.textStorage?.replaceCharacters(in: NSRange(location: i.text.length, length: 0), with: "\n// end")
        i.service.noteEdit(editedRange: NSRange(location: i.text.length - 7, length: 7), changeInLength: 7)
        i.service.noteEdit(editedRange: NSRange(location: 0, length: 0), changeInLength: 0)
        _ = i.names
        #expect(i.service.statistics.returnCacheHits > first.returnCacheHits)
        let at = i.text.range(of: "'x'")
        i.textView.textStorage?.replaceCharacters(in: at, with: "123")
        i.service.noteEdit(editedRange: NSRange(location: at.location, length: 3), changeInLength: 0)
        #expect(i.names?.contains("toFixed") == true)
        i.service.release()
        #expect(i.service.isReleased)
    }

    @Test func exhaustedBudgetGivesNoMembersAndIsNotRetried() {
        let i = ScriptInference("const s = 'a';\ns.|")
        i.service.budgetSteps = 3
        #expect(i.candidates == nil)
        #expect(i.service.statistics.aborted == 1)
        #expect(i.candidates == nil)
        #expect(i.service.statistics.aborted == 1 && i.service.statistics.reused == 1)
    }

    @Test func largeDocumentUsesTheSummary() throws {
        var body = ""
        var k = 0
        while body.utf16.count < SyntaxBuild.fullTreeUnitLimit + 64 * 1024 {
            body += "export function helper\(k)(value: number): number {\n  return value + \(k);\n}\n\n"
            k += 1
        }
        let src = "interface Store { root: string[]; open(): Promise<Response> }\n\n" + body
            + "export async function use(s: Store) {\n  const r = await s.open();\n  r.|\n}\n"
        let i = ScriptInference(src)
        i.service.budgetMilliseconds = 2_000   // debug builds
        #expect(SyntaxBuild.mode(forLength: i.text.length) == .summary)
        #expect(i.candidates == nil)
        #expect(i.service.statistics.skippedLarge == 1)
        _ = i.analysis.ensureSyntax()
        let list = try #require(i.names)
        #expect(list.contains("json") && list.contains("headers"))
        #expect(i.analysis.syntax?.summary != nil)
    }
}

// MARK: - Completion wiring

@Suite("ScriptInference completion", .serialized)
@MainActor
struct ScriptInferenceCompletionTests {
    @MainActor
    private final class Harness {
        let center = NotificationCenter()
        let settings: ModuleSettings
        let clean: () -> Void
        let textView = EditorTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let window: NSWindow
        let hub = TextStorageObserverHub()
        let controller: CompletionController

        init(_ text: String, language: String) {
            let (defaults, clean) = isolatedDefaults()
            self.clean = clean
            settings = ModuleSettings(defaults: defaults, center: center)
            let scroll = NSScrollView(frame: textView.frame)
            scroll.documentView = textView
            window = NSWindow(contentRect: textView.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = scroll
            textView.string = text
            textView.textStorage?.delegate = hub
            controller = CompletionController(textView: textView, moduleSettings: settings, moduleCenter: center,
                                              scheduler: AnalysisScheduler())
            hub.add(controller)
            textView.completionKeyHandler = controller
            controller.labelLanguageOverride = .en
            controller.setLanguage(identifier: language)
            controller.indexDocument()
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }

        func caret(at marker: String) {
            let r = (textView.string as NSString).range(of: marker)
            textView.textStorage?.replaceCharacters(in: r, with: "")
            textView.setSelectedRange(NSRange(location: r.location, length: 0))
        }

        func type(_ s: String) {
            for ch in s {
                let key = String(ch)
                textView.insertText(key, replacementRange: NSRange(location: NSNotFound, length: 0))
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, characters: key,
                                             charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0)!
                controller.textViewDidInsertKey(event)
            }
        }

        var names: [String] { controller.currentSuggestionsForTesting }

        func close() {
            controller.dismissCompletion()
            textView.textStorage?.delegate = nil
            window.close()
            clean()
        }
    }

    @Test func typeScriptPopupShowsInferredMembersWithSummaries() throws {
        let h = Harness("const words = 'pushy pusher';\nconst names: string[] = [];\n", language: "typescript")
        defer { h.close() }
        h.type("names.pu")
        let candidates = h.controller.currentCandidatesForTesting
        #expect(candidates.first?.name == "push")
        #expect(candidates.allSatisfy { $0.source == .inferredType })      // no document words
        let cell = try #require(h.controller.cellForTesting(row: 0))
        #expect(cell.content?.detail == "(...items: string[]) -> number")
    }

    @Test func javaScriptThisAndJSDoc() {
        let h = Harness("""
        class Counter {
          constructor() { this.count = 0; this.step = 1; }
          reset() {
            ⟨⟩
          }
        }
        """, language: "javascript")
        defer { h.close() }
        h.caret(at: "⟨⟩")
        h.type("this.")
        #expect(Set(h.names.prefix(3)) == ["count", "step", "reset"])
    }

    @Test func jsxExpressionContainersInTSX() {
        let h = Harness("""
        interface User { name: string; email: string }
        export function Card({ user }: { user: User }) {
          return <div className="card">{⟨⟩}</div>;
        }
        """, language: "typescriptreact")
        defer { h.close() }
        h.caret(at: "⟨⟩")
        h.type("user.")
        #expect(Set(h.names) == ["name", "email"])
        #expect(h.controller.currentCandidatesForTesting.first?.source == .inferredType)
    }

    @Test func unknownReceiverKeepsUsageEvidence() {
        let h = Harness("function f(widget) {\n  widget.mount();\n  ", language: "javascript")
        defer { h.close() }
        h.type("widget.")
        #expect(h.names == ["mount"])
        #expect(h.controller.currentCandidatesForTesting.first?.source == .receiverUsage)
    }

    @Test func turningModulesOffReleasesInference() {
        let h = Harness("const name = 'abc';\n", language: "typescript")
        defer { h.close() }
        h.type("name.")
        #expect(!h.controller.isInferenceStateReleased)
        #expect(!ScriptTypeTables.shared.isReleased)
        h.settings.setEnabled(false, for: .typeInference)
        #expect(h.controller.isInferenceStateReleased)
        #expect(ScriptTypeTables.shared.isReleased)
        #expect(TypeTableStore.shared.statistics.mappedFiles == 0)
        #expect(h.controller.analysis.syntax == nil)
        h.settings.setEnabled(true, for: .typeInference)
        h.type("\nname.")
        #expect(!h.controller.isInferenceStateReleased)
        h.settings.setEnabled(false, for: .completion)
        #expect(h.controller.isRuntimeStateReleased)
        #expect(ScriptTypeTables.shared.isReleased)
    }

    @Test func typeInferenceOffFallsBackToUsage() {
        let h = Harness("const name = 'abc';\nname.trim();\n", language: "javascript")
        defer { h.close() }
        h.settings.setEnabled(false, for: .typeInference)
        h.type("name.")
        #expect(h.names == ["trim"])
        #expect(h.controller.isInferenceStateReleased)
    }

    @Test func embeddedScriptIsNotInferred() {
        let h = Harness("<script>\nconst name = 'abc';\nname.trim();\n", language: "html")
        defer { h.close() }
        h.type("name.")
        #expect(h.controller.isInferenceStateReleased)
        #expect(h.controller.currentCandidatesForTesting.allSatisfy { $0.source != .inferredType })
    }
}


// MARK: - Screenshots (opt-in)

/// `KARU_T1711C_SHOTS=<dir> swift test --filter ScriptInferenceScreenshots`
/// renders the TypeScript member popup with TS-syntax summaries over the
/// editor in light / dark and zh-Hans / en (as T17.11b's).
@MainActor
@Suite("ScriptInferenceScreenshots", .serialized)
struct ScriptInferenceScreenshots {
    @Test func render() throws {
        guard let dir = ProcessInfo.processInfo.environment["KARU_T1711C_SHOTS"] else { return }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let source = """
        interface Invoice {
          label: string;
          amount: number;
          tags?: string[];
          total(tax?: number, rounded?: boolean): number;
        }

        export function render(invoice: Invoice, lines: string[]) {

        """
        for (typed, shot) in [("  invoice.", "ts-members"), ("  lines.ma", "ts-array")] {
            for (appearance, look) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                for language in [AppLanguage.zhHans, .en] {
                    let (defaults, clean) = isolatedDefaults()
                    defer { clean() }
                    let center = NotificationCenter()
                    let settings = ModuleSettings(defaults: defaults, center: center)
                    let size = NSSize(width: 640, height: 300)
                    let frame = NSRect(origin: .zero, size: size)
                    let scroll = NSScrollView(frame: frame)
                    let textView = EditorTextView(frame: frame)
                    textView.isRichText = false
                    textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
                    scroll.documentView = textView
                    let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: size.width, height: size.height),
                                          styleMask: [.titled], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.contentView = scroll
                    window.appearance = NSAppearance(named: appearance)
                    textView.string = source
                    let hub = TextStorageObserverHub()
                    textView.textStorage?.delegate = hub
                    let controller = CompletionController(textView: textView, moduleSettings: settings, moduleCenter: center,
                                                          scheduler: AnalysisScheduler())
                    hub.add(controller)
                    textView.completionKeyHandler = controller
                    controller.labelLanguageOverride = language
                    controller.setLanguage(identifier: "typescript")
                    controller.indexDocument()
                    window.makeFirstResponder(textView)
                    textView.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
                    for ch in typed {
                        let key = String(ch)
                        textView.insertText(key, replacementRange: NSRange(location: NSNotFound, length: 0))
                        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: window.windowNumber, context: nil, characters: key,
                                                     charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0)!
                        controller.textViewDidInsertKey(event)
                    }
                    let panel = try #require(controller.panelForTesting)
                    panel.appearance = NSAppearance(named: appearance)
                    controller.selectRowForTesting(1)
                    panel.contentView?.layoutSubtreeIfNeeded()
                    let content = try #require(window.contentView)
                    content.layoutSubtreeIfNeeded()
                    func bitmap(_ view: NSView) -> NSBitmapImageRep {
                        var rep: NSBitmapImageRep!
                        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                            rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                            view.cacheDisplay(in: view.bounds, to: rep)
                        }
                        return rep
                    }
                    let editor = bitmap(content)
                    let popup = bitmap(try #require(panel.contentView))
                    let panelInWindow = window.convertFromScreen(panel.frame)
                    let scale: CGFloat = 2
                    let canvas = try #require(NSBitmapImageRep(
                        bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
                    canvas.size = size
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
                    NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                        NSColor.textBackgroundColor.setFill()
                        NSRect(origin: .zero, size: size).fill()
                    }
                    editor.draw(in: NSRect(origin: .zero, size: size))
                    popup.draw(in: panelInWindow)
                    NSGraphicsContext.restoreGraphicsState()
                    let png = try #require(canvas.representation(using: .png, properties: [:]))
                    try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(shot)-\(look)-\(language.rawValue).png"))
                    controller.dismissCompletion()
                    textView.textStorage?.delegate = nil
                    window.close()
                }
            }
        }
    }
}
