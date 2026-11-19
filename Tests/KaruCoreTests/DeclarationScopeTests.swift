import AppKit
import Foundation
import Testing
@testable import KaruCore

// M17 T17.4a — code-only declarations and full scopes for Python and JS/TS:
// fake declarations in comments / strings are gone, `visibleBindings` /
// `scopeChain` answer the scope fixtures, every listed construct binds what
// it should, broken input never hangs or yields out-of-range scopes, and the
// sliced scanner equals the one-shot scan.
//
// T17.4b: the fixture-wide checks (code segments only, document order,
// robustness, slicing) also run the seven brace languages' fixtures; their
// construct tests live in DeclarationScopeStaticTests.

private enum ScopePaths {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let fixtures = root.appendingPathComponent("Tests/Fixtures/M17", isDirectory: true)
}

/// A caret-marked source: `⟨n⟩` markers removed, their UTF-16 offsets kept.
private struct Marked {
    let text: String
    let carets: [Int: Int]

    init(_ raw: String) {
        // swiftlint:disable:next force_try
        let marker = try! NSRegularExpression(pattern: "\u{27E8}(\\d+)\u{27E9}")
        let ns = raw as NSString
        var out = ""
        var carets: [Int: Int] = [:]
        var cursor = 0
        var removed = 0
        for match in marker.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            carets[Int(ns.substring(with: match.range(at: 1)))!] = match.range.location - removed
            removed += match.range.length
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        text = out
        self.carets = carets
    }
}

private func fixture(_ relative: String) throws -> String {
    try String(contentsOf: ScopePaths.fixtures.appendingPathComponent(relative), encoding: .utf8)
}

private func language(of path: String) -> String? {
    if path.hasSuffix(".py") { return "python" }
    if path.hasSuffix(".js") || path.hasSuffix(".jsx") { return "javascript" }
    if path.hasSuffix(".ts") { return "typescript" }
    if path.hasSuffix(".tsx") { return "typescriptreact" }
    let brace: [String: String] = [".swift": "swift", ".go": "go", ".rs": "rust", ".java": "java", ".cs": "csharp",
                                   ".c": "c", ".cpp": "cpp"]
    for (suffix, language) in brace where path.hasSuffix(suffix) { return language }
    return nil
}

/// Every fixture of a walker language under the M17 tree (markers stripped).
private func walkerFixtures() throws -> [(path: String, language: String, text: String)] {
    var out: [(String, String, String)] = []
    let base = ScopePaths.fixtures.path + "/"
    guard let walker = FileManager.default.enumerator(atPath: ScopePaths.fixtures.path) else { return [] }
    for case let relative as String in walker {
        guard let lang = language(of: relative), !relative.hasPrefix("baseline/") else { continue }
        let raw = try String(contentsOfFile: base + relative, encoding: .utf8)
        out.append((relative, lang, Marked(raw).text))
    }
    return out.sorted { $0.0 < $1.0 }
}

private func scan(_ text: String, _ language: String) -> DeclarationScan {
    DeclarationScan.scan(text: text, languageIdentifier: language)
}

/// Visible binding names at caret `n` of a marked source.
private func visible(_ marked: Marked, _ language: String, at n: Int) -> [String: DeclarationScan.ScopedBinding] {
    let result = scan(marked.text, language).visibleBindings(at: marked.carets[n]!)
    var out: [String: DeclarationScan.ScopedBinding] = [:]
    for binding in result { out[binding.name] = binding }
    return out
}

/// The non-code segments of `text` under the walker language's profile.
private func nonCodeRanges(_ text: String, _ language: String) -> [NSRange] {
    let profile = BraceLanguage(identifier: language)?.lexicalProfile
        ?? (language == "python" ? PythonLanguage.analysisProfile
                : JavaScriptLanguage.lexicalProfile(forIdentifier: language)!)
    let scanner = LexicalScanner(profile: profile)
    var state = LexicalScanState()
    var out: [NSRange] = []
    let ns = text as NSString
    scanner.segments(ns, from: 0, to: ns.length, state: &state) { range, segment in
        switch segment {
        case .code, .interpolationDelimiter: break
        default: out.append(range)
        }
    }
    return out
}

/// Deterministic generator (SplitMix64) for the robustness runs.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Checks the outline's structural invariants against `length`.
private func checkOutline(_ scan: DeclarationScan, length: Int, label: String) {
    let scopes = scan.scopes
    #expect(scopes.count == scan.scopeCount, "\(label)")
    if let module = scopes.first {
        #expect(module.kind == .module && module.start == 0 && module.end == length, "\(label)")
    }
    for scope in scopes {
        #expect(scope.start >= 0 && scope.start <= scope.end && scope.end <= length,
                "\(label): scope \(scope.index) [\(scope.start), \(scope.end)) outside 0..<\(length)")
        if let parent = scope.parent {
            let p = scopes[parent]
            #expect(p.start <= scope.start && scope.end <= p.end, "\(label): scope \(scope.index) escapes its parent")
        }
    }
    for declaration in scan.declarations {
        #expect(declaration.location >= 0 && declaration.location < max(1, length), "\(label)")
    }
}

// MARK: - Fake declarations

@Suite("DeclarationScope")
struct DeclarationScopeTests {

    @Test func declarationsComeFromCodeSegmentsOnly() throws {
        let required = ["completion/scope/py_params.py", "completion/scope/py_locals.py",
                        "completion/scope/py_negative.py", "completion/scope/js_scope.js",
                        "completion/scope/ts_scope.ts", "highlight/python.py", "highlight/javascript.js",
                        "highlight/typescript.ts", "highlight/swift.swift", "highlight/go.go", "highlight/rust.rs",
                        "highlight/java.java", "highlight/csharp.cs", "highlight/c.c", "highlight/cpp.cpp"]
        let all = try walkerFixtures()
        for path in required { #expect(all.contains { $0.path == path }, "missing fixture \(path)") }
        var checked = 0
        for item in all {
            let result = scan(item.text, item.language)
            let nonCode = nonCodeRanges(item.text, item.language)
            for declaration in result.declarations {
                let inside = nonCode.contains { NSLocationInRange(declaration.location, $0) }
                #expect(!inside, "\(item.path): \(declaration.name) at \(declaration.location) is in a string/comment")
                checked += 1
            }
        }
        #expect(checked > 500)
    }

    @Test func baselineNegativeNamesAreNotDeclarations() throws {
        let fakes = ["fake_name", "ghost_handler", "fakeFn", "fakeHelper", "not_a_function", "NotAClass"]
        for item in try walkerFixtures() {
            let result = scan(item.text, item.language)
            let names = Set(result.declarations.map(\.name))
            for fake in fakes {
                #expect(!names.contains(fake), "\(item.path): \(fake) declared")
                #expect(!result.completionSymbols.contains(fake), "\(item.path): \(fake) is a symbol")
                #expect(!result.table.all.contains(fake), "\(item.path): \(fake) coloured")
            }
        }
    }

    @Test func declarationsArriveInDocumentOrder() throws {
        for item in try walkerFixtures() {
            var scanner = DeclarationScanner(languageIdentifier: item.language)
            let result = scanner.finish(item.text as NSString)
            #expect(scanner.droppedOutOfOrder == 0, "\(item.path)")
            let locations = result.declarations.map(\.location)
            #expect(locations == locations.sorted(), "\(item.path)")
        }
    }

    // MARK: - Scope fixtures (cases.json)

    private struct Case: Decodable {
        let id: String
        let file: String
        let language: String
        let caret: Int
        let kind: String
        let category: String
        let expectTop1: String?
        let expectTop3: [String]?
        let forbidden: [String]
    }

    @Test func scopeCasesSeeTheirParametersAndLocals() throws {
        let data = try Data(contentsOf: ScopePaths.fixtures.appendingPathComponent("completion/cases.json"))
        let cases = try JSONDecoder().decode([Case].self, from: data)
        var checkedNames = 0
        var checkedCases = 0
        for c in cases where c.kind == "scope" && DeclarationScan.usesWalker(c.language) {
            let marked = Marked(try fixture(c.file))
            guard let caret = marked.carets[c.caret] else {
                Issue.record("\(c.id): caret missing")
                continue
            }
            let result = scan(marked.text, c.language)
            let declared = Set(result.declarations.map(\.name))
            let visibleNames = Set(result.visibleBindings(at: caret).map(\.name))
            let expected = ([c.expectTop1].compactMap { $0 } + (c.expectTop3 ?? []))
            for name in expected where declared.contains(name) {
                #expect(visibleNames.contains(name), "\(c.id): \(name) not visible at caret")
                checkedNames += 1
            }
            for name in c.forbidden {
                #expect(!visibleNames.contains(name), "\(c.id): forbidden \(name) visible")
            }
            checkedCases += 1
        }
        #expect(checkedCases >= 40)
        #expect(checkedNames >= 35)
    }

    @Test func scopeFixtureShadowingAndExclusions() throws {
        let js = Marked(try fixture("completion/scope/js_scope.js"))
        // ⟨12⟩: the parameter `timeout` shadows the module constant.
        let atWait = visible(js, "javascript", at: 12)
        #expect(atWait["timeout"]?.kind == .parameter)
        #expect(atWait["timeout"]?.scopeDepth == 0)
        // ⟨1⟩ in applyDiscount: other functions' parameters are not visible.
        let atDiscount = visible(js, "javascript", at: 1)
        #expect(atDiscount["cartTotal"] != nil && atDiscount["couponCode"] != nil)
        #expect(atDiscount["cartTitle"] == nil && atDiscount["eventPayload"] == nil)

        let py = Marked(try fixture("completion/scope/py_locals.py"))
        // ⟨2⟩ in draw: the local `label_text` shadows the module one.
        let atDraw = visible(py, "python", at: 2)
        #expect(atDraw["label_text"]?.scopeDepth == 0)
        #expect(atDraw["label_text"]?.kind == .variable)
        #expect(atDraw["label_width"]?.kind == .parameter)
        // ⟨8⟩ in inner: the enclosing function's local is visible one level up.
        let atInner = visible(py, "python", at: 8)
        #expect(atInner["retry_budget"]?.scopeDepth == 1)
        #expect(atInner["retry_backoff"] == nil)
        // ⟨6⟩ in a comprehension: its target is innermost.
        let atComprehension = visible(py, "python", at: 6)
        #expect(atComprehension["sq_value"]?.scopeDepth == 0)

        let chain = scan(py.text, "python").scopeChain(at: py.carets[8]!)
        #expect(chain.map(\.kind) == [.function, .function, .module])
        #expect(chain.map(\.name) == ["inner", "outer", nil])
    }
}

// MARK: - Python constructs

@Suite("DeclarationScopePython")
struct DeclarationScopePythonTests {
    private func names(_ source: String, at n: Int = 1) -> [String: DeclarationScan.ScopedBinding] {
        visible(Marked(source), "python", at: n)
    }

    @Test func parametersWithBracketedDefaults() {
        let v = names("""
        def f(a=(1, 2), b=[3], c={"k": (4,)}, *args, d: int = 5, **kw):
            return ⟨1⟩
        """)
        for name in ["a", "b", "c", "args", "d", "kw"] {
            #expect(v[name]?.kind == .parameter, "\(name)")
            #expect(v[name]?.scopeDepth == 0, "\(name)")
        }
        #expect(v["f"]?.kind == .function)
        #expect(v["int"] == nil && v["k"] == nil)
    }

    @Test func parameterMarkersStringsAndLambdaDefaults() {
        let v = names("""
        def g(a, /, b, *, c, x=lambda y: (y, ")"), z="(", w=f(1, (2, 3)), q: dict[str, int] = {}):
            pass⟨1⟩
        """)
        for name in ["a", "b", "c", "x", "z", "w", "q"] { #expect(v[name]?.kind == .parameter, "\(name)") }
        #expect(v["y"] == nil)          // the lambda's own parameter
        #expect(v["str"] == nil && v["dict"] == nil)
        let result = scan("def g(x=lambda y: y):\n    pass\n", "python")
        #expect(result.scopes.map(\.kind) == [.module, .function, .lambda])
    }

    @Test func assignmentTargets() {
        let v = names("""
        def body(items, obj, arr, pair):
            a, (b, c), *d = items
            [e, f] = pair
            g = h = 0
            i: int = 1
            j: str
            obj.attr = 1
            arr[0] = 2
            k += 1
            if (n := len(items)) > 3:
                pass
            ⟨1⟩
        """)
        for name in ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "n"] {
            #expect(v[name]?.kind == .variable, "\(name)")
        }
        #expect(v["attr"] == nil)
        #expect(v["k"] == nil)          // augmented assignment never binds
        #expect(v["len"] == nil)
    }

    @Test func listedTargetsKeepTheLegacyCoverage() {
        let result = scan("""
        first = 1
        a, b = 1, 2
        c: int = 3
        x = y = 4
        for p, q in pairs:
            pass
        import os
        import json as j
        """, "python")
        let listed = Set(result.declarations.filter(\.isListed).map(\.name))
        let all = Set(result.declarations.map(\.name))
        #expect(listed == ["first", "x", "p", "j"])
        #expect(all.isSuperset(of: ["a", "b", "c", "y", "q", "os"]))
        #expect(result.table.variables == ["first", "x", "p", "j"])
        #expect(result.completionSymbols == result.table.all)
    }

    @Test func loopWithExceptAndImportBindings() {
        let v = names("""
        import os.path as osp
        import sys, json
        from a.b import c as d, e
        from m import (f, g as h)
        from . import sibling
        from star import *

        def run(p, lock, ctx, a, b, d1):
            for idx, (key, val) in enumerate(d1.items()):
                pass
            with open(p) as fh, lock:
                pass
            with (open(a) as fa, open(b) as fb):
                pass
            with ctx() as (x1, y1):
                pass
            try:
                pass
            except (ValueError, KeyError) as err:
                pass
            ⟨1⟩
        """)
        for name in ["idx", "key", "val", "fh", "fa", "fb", "x1", "y1", "err"] {
            #expect(v[name]?.kind == .variable, "\(name)")
        }
        for name in ["osp", "sys", "json", "d", "e", "f", "h", "sibling"] {
            #expect(v[name]?.kind == .import, "\(name)")
        }
        #expect(v["os"] == nil && v["c"] == nil && v["g"] == nil && v["path"] == nil)
    }

    @Test func comprehensionsAndLambdasHaveTheirOwnScopes() {
        let source = """
        def calc(xs, ys):
            vals = [x * y for x in xs for y in ys if ⟨1⟩]
            table = {k: v for k, v in pairs}
            gen = (z for z in xs)
            fn = lambda p, q=1, *r, **s: p + ⟨2⟩
            ⟨3⟩
        """
        let inComprehension = names(source, at: 1)
        #expect(inComprehension["x"]?.scopeDepth == 0 && inComprehension["y"]?.scopeDepth == 0)
        #expect(inComprehension["xs"]?.scopeDepth == 1)
        let inLambda = names(source, at: 2)
        for name in ["p", "q", "r", "s"] { #expect(inLambda[name]?.scopeDepth == 0, "\(name)") }
        let after = names(source, at: 3)
        for name in ["x", "y", "k", "v", "z", "p", "q"] { #expect(after[name] == nil, "\(name) leaked") }
        for name in ["vals", "table", "gen", "fn"] { #expect(after[name] != nil, "\(name)") }
    }

    @Test func globalAndNonlocalBindOutside() {
        let source = """
        counter = 0

        def bump():
            global counter, fresh
            counter = 1
            fresh = 2
            ⟨1⟩

        def outer():
            total = 0
            def inner():
                nonlocal total
                total = 5
                ⟨2⟩
            return inner
        result = ⟨3⟩0
        """
        let result = scan(Marked(source).text, "python")
        let kinds = result.declarations.map { "\($0.name):\($0.kind)" }
        #expect(kinds.contains("counter:global") && kinds.contains("fresh:global"))
        #expect(kinds.contains("total:nonlocal"))
        // The assignments after `global` / `nonlocal` are not locals.
        #expect(result.declarations.filter { $0.name == "counter" }.map(\.kind) == [.variable, .global])
        #expect(result.declarations.filter { $0.name == "total" }.map(\.kind) == [.variable, .nonlocal])
        let inBump = names(source, at: 1)
        #expect(inBump["counter"]?.scopeDepth == 1)          // the module's
        let inInner = names(source, at: 2)
        #expect(inInner["total"]?.scopeDepth == 1)           // outer's
        let atModule = names(source, at: 3)
        #expect(atModule["fresh"]?.kind == .global)           // bound in the module by `global`
        #expect(atModule["total"] == nil)
    }

    @Test func classScopeIsInvisibleFromMethods() {
        let source = """
        class Config:
            limit = 10
            ⟨1⟩
            def method(self, other):
                return ⟨2⟩
            class Inner:
                pass
        """
        let inBody = names(source, at: 1)
        #expect(inBody["limit"]?.kind == .property && inBody["limit"]?.scopeDepth == 0)
        let inMethod = names(source, at: 2)
        #expect(inMethod["self"]?.kind == .parameter && inMethod["other"] != nil)
        #expect(inMethod["limit"] == nil && inMethod["method"] == nil && inMethod["Inner"] == nil)
        #expect(inMethod["Config"]?.kind == .class)
        let result = scan(Marked(source).text, "python")
        #expect(result.declarations.first { $0.name == "method" }?.kind == .method)
        #expect(result.table.functions.contains("method"))
        #expect(!result.table.variables.contains("self"))
    }

    @Test func shadowingKeepsTheNearestBinding() {
        let v = names("""
        name = 1
        def f(name):
            def g():
                return ⟨1⟩
        """)
        #expect(v["name"]?.kind == .parameter)
        #expect(v["name"]?.scopeDepth == 1)
        #expect(v["g"]?.scopeDepth == 1 && v["f"]?.scopeDepth == 2)
    }

    @Test func matchCaseCapturesAndAsyncDefs() {
        let v = names("""
        async def handle(cmd):
            match cmd:
                case Point(x=px, y=0) as pt:
                    pass
                case [first, *rest]:
                    pass
                case {"k": value, **others}:
                    pass
                case _:
                    pass
            ⟨1⟩
        """)
        for name in ["px", "pt", "first", "rest", "value", "others"] { #expect(v[name] != nil, "\(name)") }
        #expect(v["Point"] == nil && v["x"] == nil && v["_"] == nil)
        #expect(v["handle"]?.kind == .function)
    }

    @Test func singleLineBodiesAndDedentEnds() {
        let source = "def f(x): return x\ny = 1\n\nclass K: pass\nz = ⟨1⟩2\n"
        let result = scan(Marked(source).text, "python")
        let f = result.scopes.first { $0.name == "f" }
        #expect(f != nil && f!.end == (Marked(source).text as NSString).range(of: "y = 1").location)
        let v = names(source)
        #expect(v["x"] == nil && v["y"] != nil && v["K"] != nil)
    }

    @Test func unbalancedBracketsRecoverAtTheNextDefinition() {
        let v = names("""
        def broken(a, b=(1,
        def ok(c):
            return ⟨1⟩
        """)
        #expect(v["c"]?.kind == .parameter && v["c"]?.scopeDepth == 0)
        #expect(v["ok"]?.kind == .function)
    }

    @Test func fStringFieldsAreCode() {
        let result = scan("msg = f\"{(lambda q: q)(1)} {[w for w in ws]}\"\n# def hidden(): pass\n", "python")
        let names = Set(result.declarations.map(\.name))
        #expect(names.contains("q") && names.contains("w") && !names.contains("hidden"))
    }
}

// MARK: - JavaScript / TypeScript constructs

@Suite("DeclarationScopeJavaScript")
struct DeclarationScopeJavaScriptTests {
    private func names(_ source: String, _ language: String = "javascript",
                       at n: Int = 1) -> [String: DeclarationScan.ScopedBinding] {
        visible(Marked(source), language, at: n)
    }

    @Test func arrowFunctionsNeedTheArrow() {
        let result = scan("const total = (a + b);\nconst f = (a, b) => a;\nconst sq = x => x * x;\n", "javascript")
        let kinds = Dictionary(result.declarations.map { ($0.name + "@\($0.location)", $0.kind) }) { a, _ in a }
        #expect(result.declarations.first { $0.name == "total" }?.kind == .variable)
        #expect(result.declarations.first { $0.name == "f" }?.kind == .function)
        #expect(result.declarations.first { $0.name == "sq" }?.kind == .function)
        #expect(result.table.variables.contains("total") && !result.table.functions.contains("total"))
        #expect(result.table.functions.contains("f"))
        let params = result.declarations.filter { $0.kind == .parameter }.map(\.name)
        #expect(params == ["a", "b", "x"], "\(kinds)")
        let f = result.scopes.first { $0.name == "f" }
        #expect(f?.kind == .lambda)
        // `a` / `b` of `total` are uses, not bindings.
        #expect(result.declarations.filter { $0.name == "a" }.count == 1)
    }

    @Test func parametersWithDefaultsAndPatterns() {
        let v = names("""
        function g(a = (1 + 2), b = ")", {c, d: e = f(1, 2), ...rest} = {}, [h, , i = 2] = [], ...others) {
          ⟨1⟩
        }
        """)
        for name in ["a", "b", "c", "e", "rest", "h", "i", "others"] {
            #expect(v[name]?.kind == .parameter, "\(name)")
        }
        #expect(v["d"] == nil && v["f"] == nil)
        #expect(v["g"]?.kind == .function)
    }

    @Test func declaratorListsAndDestructuring() {
        let v = names("""
        const { a1, b1: renamed, c1 = 3, d1: { deep }, ...others1 } = obj;
        let [p1, , p2 = 1, [nested], ...rest1] = arr;
        let m1 = 1, m2 = (2, 3), m3;
        var v1 = function named() {}, v2 = class {};
        ⟨1⟩
        """)
        for name in ["a1", "renamed", "c1", "deep", "others1", "p1", "p2", "nested", "rest1", "m1", "m2", "m3"] {
            #expect(v[name]?.kind == .variable, "\(name)")
        }
        #expect(v["b1"] == nil && v["d1"] == nil)
        #expect(v["v1"]?.kind == .function && v["v2"]?.kind == .class)
    }

    @Test func catchAndLoopBindingsStayInTheirBlocks() {
        let source = """
        function run(list, obj, n) {
          try { work(); } catch (err) { ⟨1⟩ }
          for (const item of list) { ⟨2⟩ }
          for (let i = 0; i < n; i++) { ⟨3⟩ }
          for (const key in obj) use(⟨4⟩);
          for (var legacy of list) {}
          ⟨5⟩
        }
        """
        #expect(names(source, at: 1)["err"]?.kind == .parameter)
        #expect(names(source, at: 2)["item"]?.scopeDepth == 0)
        #expect(names(source, at: 3)["i"] != nil)
        #expect(names(source, at: 4)["key"] != nil)
        let after = names(source, at: 5)
        for name in ["err", "item", "i", "key"] { #expect(after[name] == nil, "\(name) leaked") }
        #expect(after["legacy"]?.kind == .functionScopedVariable)   // `var` is function-scoped
    }

    @Test func classesMethodsAndFields() {
        let source = """
        class Shape extends Base {
          #id = 0;
          area = 1
          static count;
          constructor(w, h) { super(); }
          get size() { return 1; }
          method(a) { return ⟨1⟩; }
          static { let inStatic = 1; }
        }
        """
        let result = scan(Marked(source).text, "javascript")
        let byName = Dictionary(result.declarations.map { ($0.name, $0.kind) }) { a, _ in a }
        #expect(byName["Shape"] == .class)
        #expect(byName["#id"] == .property && byName["area"] == .property && byName["count"] == .property)
        #expect(byName["size"] == .method && byName["method"] == .method)
        #expect(byName["constructor"] == nil && byName["Base"] == nil)
        let v = names(source)
        #expect(v["a"]?.kind == .parameter && v["Shape"] != nil)
        #expect(v["area"] == nil && v["method"] == nil && v["w"] == nil)
        #expect(result.table.functions.contains("method"))
    }

    @Test func importsBind() {
        let v = names("""
        import def0, { a as b, c, "str-name" as d } from 'm';
        import * as ns from 'n';
        import 'side-effect';
        import {
          multi,
          line as ml,
        } from 'x';
        ⟨1⟩
        """)
        for name in ["def0", "b", "c", "d", "ns", "multi", "ml"] { #expect(v[name]?.kind == .import, "\(name)") }
        #expect(v["a"] == nil && v["line"] == nil)
    }

    @Test func letBeforeDeclarationAndHoisting() {
        let source = """
        ⟨4⟩
        function f() {
          ⟨1⟩
          let late = 1;
          const g = () => ⟨2⟩;
          if (x) { var hoisted = 1; let blockOnly = 2; }
          ⟨3⟩
        }
        function later() {}
        """
        let before = names(source, at: 1)
        #expect(before["late"] == nil)
        #expect(before["hoisted"]?.kind == .functionScopedVariable)
        #expect(before["blockOnly"] == nil)
        let inArrow = names(source, at: 2)
        #expect(inArrow["late"] != nil && inArrow["g"] != nil)
        let after = names(source, at: 3)
        #expect(after["late"] != nil && after["hoisted"] != nil && after["blockOnly"] == nil)
        let top = names(source, at: 4)
        #expect(top["later"]?.kind == .function && top["f"] != nil)
    }

    @Test func shadowedParameterWins() {
        let v = names("const timeout = 1;\nfunction wait(timeout) { return ⟨1⟩; }\n")
        #expect(v["timeout"]?.kind == .parameter && v["timeout"]?.scopeDepth == 0)
    }

    @Test func bracesInStringsRegexesAndTemplatesNeverCount() {
        let source = """
        const t = `{ not a block ${(() => { const inner = 1; return inner; })()} }`;
        const re = /{(/;
        // function fakeFn() {
        /* class Nope { */
        const s = "{";
        function after(p) { return ⟨1⟩; }
        """
        let result = scan(Marked(source).text, "javascript")
        #expect(result.declarations.contains { $0.name == "inner" })
        #expect(!result.declarations.contains { $0.name == "fakeFn" || $0.name == "Nope" })
        let chain = result.scopeChain(at: Marked(source).carets[1]!)
        #expect(chain.map(\.name) == ["after", nil])
        #expect(names(source)["p"]?.kind == .parameter)
    }

    @Test func typeScriptAnnotationsAreNotBindings() {
        let source = """
        interface Shape { area(): number; name: string }
        type Pair<T> = [T, T];
        enum Color { Red, Green }
        const enum Flag { On }
        namespace Geo { export const origin = 0; }
        function gen<T, U extends T>(a: Foo, b?: Bar<T> = x, c: Map<string, U> = new Map()): T {
          const local: Array<number> = [];
          return ⟨1⟩;
        }
        class Svc {
          constructor(private readonly api: Api, public name: string) {}
          handle(x: unknown): void { const y = x as (p: number) => void; }
        }
        const typed = <K extends string>(key: K): K => key;
        """
        let result = scan(Marked(source).text, "typescript")
        let byName = Dictionary(result.declarations.map { ($0.name, $0.kind) }) { a, _ in a }
        for name in ["Shape", "Pair", "Color", "Flag", "Geo", "T", "U", "K"] { #expect(byName[name] == .type, "\(name)") }
        for name in ["a", "b", "c", "api", "name", "x", "key"] { #expect(byName[name] == .parameter, "\(name)") }
        for name in ["Foo", "Bar", "Map", "string", "number", "Api", "area", "Red", "p", "unknown"] {
            #expect(byName[name] == nil, "\(name) bound")
        }
        #expect(byName["typed"] == .function)
        let v = names(source, "typescript")
        for name in ["a", "b", "c", "local", "T", "U", "gen", "Shape"] { #expect(v[name] != nil, "\(name)") }
        #expect(v["origin"] == nil)
    }

    @Test func incompleteCodeKeepsLaterDeclarations() {
        let source = "function a(x, {\nconst b = foo(\nfunction c(d) { return ⟨1⟩; }\n"
        let v = names(source)
        #expect(v["d"]?.kind == .parameter)
        #expect(scan(Marked(source).text, "javascript").declarations.contains { $0.name == "c" })
    }
}

// MARK: - Robustness and slicing

@Suite("DeclarationScopeRobustness")
struct DeclarationScopeRobustnessTests {

    @Test func truncationsAndDeletionsNeverHangOrEscape() throws {
        var rng = SeededGenerator(state: 0x4B41_5255)
        var variants = 0
        var slowest = 0.0
        for item in try walkerFixtures() {
            let units = Array((item.text as NSString).utf16Prefix())
            guard units.count > 2 else { continue }
            func run(_ variant: [unichar], _ label: String) {
                let text = String(utf16CodeUnits: variant, count: variant.count)
                let length = (text as NSString).length
                let start = Date()
                let result = scan(text, item.language)
                let elapsed = Date().timeIntervalSince(start)
                slowest = max(slowest, elapsed)
                #expect(elapsed < 1, "\(label) took \(elapsed) s")
                checkOutline(result, length: length, label: label)
                _ = result.visibleBindings(at: Int.random(in: 0...length, using: &rng))
                _ = result.scopeChain(at: length)
                variants += 1
            }
            for _ in 0..<200 {
                let cut = Int.random(in: 0..<units.count, using: &rng)
                run(Array(units[0..<cut]), "\(item.path) prefix \(cut)")
            }
            for _ in 0..<200 {
                var edited = units
                let at = Int.random(in: 0..<units.count, using: &rng)
                edited.remove(at: at)
                run(edited, "\(item.path) delete \(at)")
            }
        }
        #expect(variants >= 29 * 400)   // T17.4b: 15 Python / JS / TS + 14 brace-language fixtures
        #expect(slowest < 1)
    }

    /// A ~1 MB generated document mixing the walker constructs.
    private static func generated(_ language: String, bytes: Int = 1 << 20) throws -> String {
        let block: String
        if language == "python" {
            block = try fixture("completion/scope/py_locals.py") + "\n" + fixture("highlight/python.py") + "\n"
        } else if language == "c" {
            block = try fixture("highlight/c.c") + "\n" + fixture("completion/explicit/point.c") + "\n"
        } else if language == "swift" {
            block = try fixture("highlight/swift.swift") + "\n" + fixture("completion/explicit/account.swift") + "\n"
        } else {
            block = try fixture("completion/scope/js_scope.js") + "\n" + fixture("highlight/javascript.js") + "\n"
                + (language == "typescript" ? try fixture("highlight/typescript.ts") : "") + "\n"
        }
        let clean = Marked(block).text
        return String(repeating: clean, count: max(1, bytes / clean.utf8.count))
    }

    private static func sliced(_ text: String, _ language: String, budget: Int) -> (DeclarationScan, Int) {
        var scanner = DeclarationScanner(languageIdentifier: language)
        let ns = text as NSString
        var steps = 0
        while !scanner.step(ns, budgetUnits: budget) { steps += 1 }
        return (scanner.scan!, steps)
    }

    @Test func slicedScanEqualsOneShotOnFixtures() throws {
        for item in try walkerFixtures() {
            let oneShot = scan(item.text, item.language)
            for budget in [1, 7, 64, 4096] {
                let (result, _) = Self.sliced(item.text, item.language, budget: budget)
                #expect(result == oneShot, "\(item.path) budget \(budget)")
            }
        }
        // T17.11c: an object type inside a class's generics or heritage is
        // not the class body (it used to open the body early, record `id`
        // as a member and depend on the slice budget).
        let generic = """
        class R<T extends { id: string }> {
          rows: T[] = [];
          add(row: T) { return row; }
        }
        class S extends Base<{ key: number }> implements Shape<{ tag: string }> { size = 1; }
        const after = new R();
        """
        let oneShot = scan(generic, "typescript")
        for budget in Array(1...7) + [64, 4096] {
            let (result, _) = Self.sliced(generic, "typescript", budget: budget)
            #expect(result == oneShot, "generic class header, budget \(budget)")
        }
        let names = oneShot.declarations.map { "\($0.name):\($0.kind)" }
        #expect(!names.contains { $0.hasPrefix("id:") || $0.hasPrefix("key:") || $0.hasPrefix("tag:") }, "\(names)")
        for expected in ["R", "S", "T", "rows", "add", "row", "size", "after"] {
            #expect(names.contains { $0.hasPrefix(expected + ":") }, "\(expected) in \(names)")
        }
    }

    @Test func varyingStepBudgetsEqualOneShot() throws {
        var rng = SeededGenerator(state: 0x5354_4550)
        for item in try walkerFixtures() {
            let oneShot = scan(item.text, item.language)
            for _ in 0..<3 {
                var scanner = DeclarationScanner(languageIdentifier: item.language)
                let ns = item.text as NSString
                while !scanner.step(ns, budgetUnits: Int.random(in: 1...300, using: &rng)) {}
                #expect(scanner.scan == oneShot, "\(item.path)")
            }
        }
    }

    @Test func slicedScanEqualsOneShotOnAMegabyte() throws {
        for language in ["python", "typescript", "c", "swift"] {
            let text = try Self.generated(language)
            let oneShot = scan(text, language)
            #expect(oneShot.scopeCount > 100)
            for budget in [7, 64, 4096] {
                let (result, steps) = Self.sliced(text, language, budget: budget)
                #expect(steps > 10)
                #expect(result == oneShot, "\(language) budget \(budget)")
            }
        }
    }

    @Test func aTextChangedBetweenStepsIsNeverReadAgain() throws {
        for language in ["python", "javascript"] {
            let long = try Self.generated(language, bytes: 64 << 10) as NSString
            var scanner = DeclarationScanner(languageIdentifier: language)
            for _ in 0..<3 { _ = scanner.step(long, budgetUnits: 1000) }
            let short = "x = 1\n" as NSString
            var steps = 0
            while !scanner.step(short, budgetUnits: 1000) { steps += 1 }
            #expect(steps < 10_000)
            #expect(scanner.scan != nil)
        }
    }

    @Test func languagesWithoutAWalkerScanInOneStep() {
        // T17.4b: every language with declarations has a walker; the rest
        // finish in one step with empty products.
        for language in ["swift", "go", "rust", "java", "csharp", "c", "cpp"] {
            #expect(DeclarationScan.usesWalker(language))
        }
        var scanner = DeclarationScanner(languageIdentifier: "bash")
        let done = scanner.step("f() { local a=1; }" as NSString, budgetUnits: 1)
        #expect(done)
        #expect(scanner.scan?.table == .empty)
        #expect(scanner.scan?.scopeCount == 0)
        #expect(scanner.scan?.visibleBindings(at: 0).isEmpty == true)
    }
}

// MARK: - DocumentAnalysis slicing

@MainActor
@Suite("DeclarationScopeSlicing", .serialized)
struct DeclarationScopeSlicingTests {
    @MainActor private final class Harness {
        let center = NotificationCenter()
        let scheduler = AnalysisScheduler()
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let hub = TextStorageObserverHub()
        let analysis: DocumentAnalysis

        init(text: String) {
            let name = "DeclarationScopeSlicing-\(UUID().uuidString)"
            let defaults = TestDefaults.make(name)
            defaults.removePersistentDomain(forName: name)
            let settings = ModuleSettings(defaults: defaults, center: center)
            analysis = DocumentAnalysis(textView: textView, moduleSettings: settings, moduleCenter: center,
                                        scheduler: scheduler)
            textView.textStorage?.delegate = hub
            hub.add(analysis)
            textView.string = text
            analysis.setLanguage(identifier: "python")
        }

        func edit(_ insert: String, at location: Int) {
            textView.textStorage?.replaceCharacters(in: NSRange(location: location, length: 0), with: insert)
        }
    }

    private func pump(until done: () -> Bool, timeout: TimeInterval = 20) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !done(), Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    @Test func editsRescanInSlicesAndPublishTheOneShotResult() async throws {
        let block = Marked(try fixture("completion/scope/py_locals.py")).text + "\n"
        let harness = Harness(text: String(repeating: block, count: 300))   // ~450 KB
        defer { harness.analysis.cancelPendingWork() }
        let slicesBefore = harness.scheduler.sliceCount
        harness.edit("def fresh_fn(fresh_param):\n    pass\n", at: 0)
        #expect(harness.analysis.declarations == nil)
        // A second edit while the first rescan may be in flight supersedes it.
        try? await Task.sleep(nanoseconds: 90_000_000)
        harness.edit("# touched\n", at: 0)
        await pump(until: { harness.analysis.declarations != nil })
        let published = try #require(harness.analysis.declarations)
        #expect(published.version == harness.analysis.version)
        #expect(harness.scheduler.sliceCount - slicesBefore > 1)
        let oneShot = DeclarationScan.scan(text: harness.textView.string, languageIdentifier: "python")
        #expect(published.scan == oneShot)
        #expect(published.scan.table.functions.contains("fresh_fn"))
    }

    @Test func synchronousRequestFinishesTheInFlightScan() async throws {
        let block = Marked(try fixture("completion/scope/py_locals.py")).text + "\n"
        let harness = Harness(text: String(repeating: block, count: 300))
        defer { harness.analysis.cancelPendingWork() }
        harness.edit("x_new = 1\n", at: 0)
        let scans = harness.analysis.declarationScanCount
        try? await Task.sleep(nanoseconds: 100_000_000)        // let a few slices run
        let snapshot = harness.analysis.ensureDeclarations()
        #expect(snapshot.version == harness.analysis.version)
        #expect(harness.analysis.declarationScanCount == scans + 1)
        #expect(snapshot.scan == DeclarationScan.scan(text: harness.textView.string, languageIdentifier: "python"))
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(harness.analysis.declarationScanCount == scans + 1)   // the job does not scan again
    }
}

private extension NSString {
    func utf16Prefix() -> [unichar] {
        var units = [unichar](repeating: 0, count: length)
        units.withUnsafeMutableBufferPointer { getCharacters($0.baseAddress!, range: NSRange(location: 0, length: length)) }
        return units
    }
}
