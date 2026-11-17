import Foundation
import Testing
@testable import KaruCore

// M17 T17.4b — code-only declarations and basic scopes for Swift, Go, Rust,
// Java, C#, C and C++ (`BraceDeclarationWalker`): fake declarations in
// comments / strings / raw strings are ignored, every construct of plan §5.2
// binds what it should (parameters with defaults / generics / pointers,
// locals, loop / catch / closure / lambda bindings), an inner local hides an
// outer parameter, implicit members follow the language, and expression
// statements (`f(x);`, `a = b;`, `x.y = 1;`, `return a * b;`) declare nothing.
// Fixture-wide checks (code segments only, robustness, slicing) run in
// DeclarationScopeTests.

/// A caret-marked source: `⟨n⟩` markers removed, their UTF-16 offsets kept.
private struct Caret {
    let text: String
    let offsets: [Int: Int]

    init(_ raw: String) {
        // swiftlint:disable:next force_try
        let marker = try! NSRegularExpression(pattern: "\u{27E8}(\\d+)\u{27E9}")
        let ns = raw as NSString
        var out = ""
        var offsets: [Int: Int] = [:]
        var cursor = 0
        var removed = 0
        for match in marker.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            offsets[Int(ns.substring(with: match.range(at: 1)))!] = match.range.location - removed
            removed += match.range.length
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        text = out
        self.offsets = offsets
    }
}

private func scan(_ source: String, _ language: String) -> DeclarationScan {
    DeclarationScan.scan(text: Caret(source).text, languageIdentifier: language)
}

/// Visible bindings at caret `n`, by name.
private func visible(_ source: String, _ language: String, at n: Int = 1) -> [String: DeclarationScan.ScopedBinding] {
    let caret = Caret(source)
    let result = DeclarationScan.scan(text: caret.text, languageIdentifier: language)
    var out: [String: DeclarationScan.ScopedBinding] = [:]
    for binding in result.visibleBindings(at: caret.offsets[n]!) { out[binding.name] = binding }
    return out
}

private func declared(_ source: String, _ language: String) -> [String: DeclarationScan.DeclarationKind] {
    Dictionary(scan(source, language).declarations.map { ($0.name, $0.kind) }) { first, _ in first }
}

// MARK: - Fakes

@Suite("DeclarationScopeStaticFakes")
struct DeclarationScopeStaticFakeTests {
    /// Per language: a source with fake declarations (all named `fake…`) in
    /// comments, strings, raw strings and character literals, plus a real
    /// function `real` with parameter `realParam`.
    private static let sources: [(String, String)] = [
        ("swift", #"""
        // func fakeLine(fakeParam: Int) {}
        /* outer /* nested */ let fakeNested = 1 */
        let s = "func fakeString() { let fakeInner = 2 }"
        let r = #"var fakeRaw = "x" \(fakeInterp)"#
        let m = """
        func fakeMulti(fakeMultiParam: Int) {}
        """
        func real(realParam: Int) {}
        """#),
        ("go", #"""
        // func fakeLine(fakeParam int) {}
        /* var fakeBlock = 1 */
        var s = "func fakeString() { fakeInner := 2 }"
        var r = `func fakeRaw(fakeRawParam int) {}
        var fakeRawVar = 3`
        var c = '{'
        func real(realParam int) {}
        """#),
        ("rust", #"""
        // fn fake_line(fake_param: i32) {}
        /* outer /* nested */ fn fake_nested() {} */
        const S: &str = "fn fake_string() { let fake_inner = 2; }";
        const R: &str = r#"let fake_raw = "x";"#;
        const B: &[u8] = b"fn fake_bytes() {}";
        const C: char = '{';
        fn real(real_param: i32) {}
        """#),
        ("java", #"""
        /** {@code int fakeJavadoc = 1;} */
        class Real {
            // void fakeLine(int fakeParam) {}
            String t = """
                void fakeBlock(int fakeBlockParam) {}
                """;
            String s = "int fakeString = 1;";
            char c = '{';
            void real(int realParam) {}
        }
        """#),
        ("csharp", #"""
        // void FakeLine(int fakeParam) {}
        class Real {
            string v = @"void FakeVerbatim() { int fakeInner; }";
            string i = $"{x} int fakeInterp = 1";
            string r = """
                int FakeRaw(int fakeRawParam) => 1;
                """;
            char c = '{';
            void real(int realParam) {}
        }
        """#),
        ("c", #"""
        /* int fakeBlock(int fakeParam) { return 0; } */
        // struct fakeStruct { int fakeField; };
        const char *s = "int fakeString(void);";
        char c = '(';
        int real(int realParam) { return realParam; }
        """#),
        ("cpp", #"""
        // class FakeLine { void fakeMethod(int fakeParam); };
        const char *r = R"(int fakeRaw(int fakeRawParam) {})";
        const char *d = R"d(class FakeDelimited { int fakeField; };)d";
        const char *s = "auto fakeString = 1;";
        int real(int realParam) { return realParam; }
        """#),
    ]

    @Test func fakesInCommentsStringsAndRawStringsAreIgnored() {
        for (language, source) in Self.sources {
            let result = scan(source, language)
            let names = result.declarations.map(\.name)
            #expect(names.contains("real"), "\(language): \(names)")
            #expect(names.contains("realParam") || names.contains("real_param"), "\(language): \(names)")
            for name in names {
                #expect(!name.lowercased().hasPrefix("fake"), "\(language): fake declaration \(name)")
            }
            for name in result.table.all.union(result.completionSymbols) {
                #expect(!name.lowercased().hasPrefix("fake"), "\(language): fake symbol \(name)")
            }
        }
    }

    @Test func regexPathFakesOnTheFixturesAreGone() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/M17/highlight")
        let cases: [(String, String, [String])] = [
            ("swift.swift", "swift", ["notReal"]),
            ("go.go", "go", ["fake"]),
            ("rust.rs", "rust", ["fake"]),
            ("c.c", "c", ["static", "struct", "const", "typedef", "int"]),
            ("cpp.cpp", "cpp", ["glsl", "layout", "vec4", "x"]),
            ("csharp.cs", "csharp", ["foreach", "s"]),
        ]
        for (file, language, fakes) in cases {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            let result = DeclarationScan.scan(text: text, languageIdentifier: language)
            let legacy = DeclarationScan.regexScan(text as NSString, languageIdentifier: language)
            for fake in fakes {
                if fake != "s" { #expect(legacy.table.all.contains(fake), "\(file): the regex path had \(fake)") }
                #expect(!result.table.all.contains(fake), "\(file): \(fake) still coloured")
                #expect(!result.declarations.contains { $0.name == fake }, "\(file): \(fake) declared")
            }
        }
    }
}

// MARK: - Swift

@Suite("DeclarationScopeSwift")
struct DeclarationScopeSwiftTests {
    @Test func parametersBindTheirInternalNames() {
        let v = visible("""
        func f(label inner: Int, _ x: [String: Int] = [:], y: Dictionary<String, Int> = g(1, 2), z: inout T) {
            ⟨1⟩
        }
        """, "swift")
        for name in ["inner", "x", "y", "z"] { #expect(v[name]?.kind == .parameter, "\(name)") }
        #expect(v["label"] == nil && v["g"] == nil)
        #expect(v["f"]?.kind == .function)
    }

    @Test func localsPatternsAndConditionalBindings() {
        let source = """
        func run(opt: Int?, items: [Int], pair: (Int, Int)) {
            let (a, b) = pair
            var c = 1, d: Int = 2
            if let e = opt { ⟨1⟩ }
            guard let g = opt else { return }
            while let w = next() { ⟨2⟩ }
            for item in items { ⟨3⟩ }
            for (i, v) in items.enumerated() { ⟨4⟩ }
            switch opt {
            case let .some(z): ⟨5⟩
            default: break
            }
            ⟨6⟩
        }
        """
        #expect(visible(source, "swift", at: 1)["e"]?.scopeDepth == 0)
        #expect(visible(source, "swift", at: 2)["w"] != nil)
        #expect(visible(source, "swift", at: 3)["item"] != nil)
        let loop = visible(source, "swift", at: 4)
        #expect(loop["i"] != nil && loop["v"] != nil)
        #expect(visible(source, "swift", at: 5)["z"] != nil)
        let after = visible(source, "swift", at: 6)
        for name in ["a", "b", "c", "d", "g"] { #expect(after[name]?.kind == .variable, "\(name)") }
        for name in ["e", "w", "item", "i", "v"] { #expect(after[name] == nil, "\(name) leaked") }
        #expect(after["opt"]?.kind == .parameter)
    }

    @Test func closureParameters() {
        let source = """
        let h = items.map { a1, b1 in ⟨1⟩ }
        let k = items.map { (c1: Int, _ d1: Int) -> Int in ⟨2⟩ }
        let m = items.filter { [weak self] e1 in ⟨3⟩ }
        """
        let first = visible(source, "swift", at: 1)
        #expect(first["a1"]?.kind == .parameter && first["b1"]?.kind == .parameter)
        let second = visible(source, "swift", at: 2)
        #expect(second["c1"]?.kind == .parameter && second["d1"]?.kind == .parameter)
        #expect(second["a1"] == nil)
        #expect(visible(source, "swift", at: 3)["e1"]?.kind == .parameter)
        #expect(scan(source, "swift").scopes.filter { $0.kind == .lambda }.count == 3)
    }

    @Test func membersAreImplicitInMethodsAndShadowedByLocals() {
        let source = """
        struct Account {
            var balance = 0
            func deposit(amount: Int) {
                let amount = 2
                ⟨1⟩
            }
            func other() {}
        }
        """
        let v = visible(source, "swift")
        #expect(v["balance"]?.kind == .property)
        #expect(v["other"]?.kind == .method)
        #expect(v["amount"]?.kind == .variable && v["amount"]?.scopeDepth == 0)
        #expect(scan(source, "swift").scopeChain(at: Caret(source).offsets[1]!).map(\.name) == ["deposit", "Account", nil])
    }

    @Test func listedNamesKeepTheRegexCoverage() {
        let result = scan("""
        let top = 1
        struct S { var field = 1; func m(p: Int) { let local = p } }
        """, "swift")
        #expect(result.table.variables == ["top"])
        #expect(result.table.functions == ["m"] && result.table.types == ["S"])
        #expect(result.declarations.contains { $0.name == "local" && !$0.isListed })
    }

    /// A line break after a postfix `?` / `!` / `??` or a closing `>` ends
    /// the statement: the declaration on the next line is its own (a
    /// property stays a property, a method or a nested type is found).
    @Test(arguments: ["Int?", "Handler!", "Set<Int>", "[String: Set<Int>]?", "Box<Box<Int>>", "Context??",
                      "(() -> Void)?"])
    func declarationAfterAPostfixTypeEndIsItsOwnStatement(_ type: String) {
        let source = """
        struct S {
            var first: \(type)
            let second: Int
            var third: \(type)
            func method(p: Int) { let local = p }
            var fourth: \(type)
            struct Row { var cell = 1 }
            var fifth: \(type)
            init(q: Int) { second = q }
        }
        """
        let result = scan(source, "swift")
        let kinds = declared(source, "swift")
        for name in ["first", "second", "third", "fourth", "fifth", "cell"] {
            #expect(kinds[name] == .property, "\(name) after \(type)")
        }
        #expect(kinds["method"] == .method, "method after \(type)")
        #expect(kinds["Row"] == .class, "Row after \(type)")
        #expect(kinds["p"] == .parameter && kinds["q"] == .parameter && kinds["local"] == .variable)
        #expect(result.table.functions.contains("method") && result.table.types.contains("Row"))
        let scopes = result.scopes.filter { $0.kind == .function || $0.kind == .class }.map(\.name)
        #expect(scopes.contains("method") && scopes.contains("Row") && !scopes.contains("first"), "\(scopes)")
    }

    /// Locals too: `let a: Int?` then `let b = 1` are two statements.
    @Test func localAfterAnOptionalLocalIsDeclared() {
        let v = visible("""
        func f(x: Int?) {
            let a: Int?
            let b = 1
            let c = x!
            let d = 2
            ⟨1⟩
        }
        """, "swift")
        #expect(v["a"]?.kind == .variable && v["b"]?.kind == .variable)
        #expect(v["c"]?.kind == .variable && v["d"]?.kind == .variable)
    }

    /// Operators that continue onto the next line still do: a ternary or a
    /// comparison written with blanks, an optional chain broken before `.`.
    @Test func operatorsAtALineEndStillContinueTheStatement() {
        let source = """
        struct S {
            func f(a: Int, b: Int, s: S?) -> Int {
                let big = a >
                    b
                let pick = big ?
                    a : b
                let size = s?
                    .f(a: 1, b: 2, s: nil)
                ⟨1⟩
                return pick
            }
        }
        """
        let v = visible(source, "swift")
        #expect(v["big"]?.kind == .variable && v["pick"]?.kind == .variable && v["size"]?.kind == .variable)
        // No operand of a continued line became a declaration.
        let names = scan(source, "swift").declarations.map(\.name)
        #expect(names == ["S", "f", "a", "b", "s", "big", "pick", "size"], "\(names)")
    }
}

// MARK: - Go

@Suite("DeclarationScopeGo")
struct DeclarationScopeGoTests {
    @Test func receiverParametersAndNamedResults() {
        let v = visible("""
        func (r *T) Name(a, b int, c string, rest ...string) (res int, err error) {
            ⟨1⟩
        }
        """, "go")
        for name in ["r", "a", "b", "c", "rest", "res", "err"] { #expect(v[name]?.kind == .parameter, "\(name)") }
        #expect(v["int"] == nil && v["string"] == nil && v["T"] == nil)
    }

    @Test func unnamedParametersBindNothing() {
        let result = scan("func f(int, string) (bool, error) { return }", "go")
        #expect(result.declarations.map(\.name) == ["f"])
    }

    @Test func shortDeclarationsLoopsAndHeaders() {
        let source = """
        const k = 1
        var (
            gx, gy = 1, 2
        )
        func run() {
            x, y := f()
            var m, n int
            for i, v := range xs { ⟨1⟩ }
            if e := g(); e != nil { ⟨2⟩ }
            fn := func(p int) { ⟨3⟩ }
            ⟨4⟩
        }
        """
        let loop = visible(source, "go", at: 1)
        #expect(loop["i"] != nil && loop["v"] != nil && loop["x"] != nil)
        #expect(visible(source, "go", at: 2)["e"]?.scopeDepth == 0)
        #expect(visible(source, "go", at: 3)["p"]?.kind == .parameter)
        let after = visible(source, "go", at: 4)
        for name in ["x", "y", "m", "n", "fn", "k", "gx", "gy"] { #expect(after[name] != nil, "\(name)") }
        for name in ["i", "v", "e", "p"] { #expect(after[name] == nil, "\(name) leaked") }
    }

    @Test func structFieldsNeedTheReceiver() {
        let source = """
        type Server struct {
            Addr string
            Port int
        }
        func (s *Server) Start() { ⟨1⟩ }
        """
        let v = visible(source, "go")
        #expect(v["s"]?.kind == .parameter)
        #expect(v["Addr"] == nil && v["Port"] == nil)
        #expect(declared(source, "go")["Addr"] == .property)
        // A method's scope starts at its receiver and carries its name.
        #expect(scan(source, "go").scopeChain(at: Caret(source).offsets[1]!).first?.name == "Start")
    }
}

// MARK: - Rust

@Suite("DeclarationScopeRust")
struct DeclarationScopeRustTests {
    @Test func parameterPatterns() {
        let v = visible("""
        impl Point {
            fn name(&self, mut a: T, (x, y): (i32, i32), Point { x: px, y: py }: Point, _: u8) -> i32 {
                ⟨1⟩
            }
        }
        """, "rust")
        for name in ["a", "x", "y", "px", "py"] { #expect(v[name]?.kind == .parameter, "\(name)") }
        #expect(v["self"] == nil && v["T"] == nil && v["Point"] == nil && v["mut"] == nil)
    }

    @Test func letPatternsLoopsAndConditionalBindings() {
        let source = """
        fn run(it: I, o: Option<i32>) {
            let mut m = 1;
            let (t1, t2) = pair;
            let Point { x, y: renamed } = pt;
            let Some(v) = o else { return; };
            for (i, w) in it.enumerate() { ⟨1⟩ }
            if let Some(s) = o { ⟨2⟩ }
            while let Some(st) = stack.pop() { ⟨3⟩ }
            ⟨4⟩
        }
        """
        let loop = visible(source, "rust", at: 1)
        #expect(loop["i"] != nil && loop["w"] != nil)
        #expect(visible(source, "rust", at: 2)["s"] != nil)
        #expect(visible(source, "rust", at: 3)["st"] != nil)
        let after = visible(source, "rust", at: 4)
        for name in ["m", "t1", "t2", "x", "renamed", "v"] { #expect(after[name]?.kind == .variable, "\(name)") }
        for name in ["y", "Some", "Point", "i", "w", "s", "st"] { #expect(after[name] == nil, "\(name)") }
    }

    @Test func closuresAndBitwiseOr() {
        let source = """
        fn run() {
            let f = |c1, c2| c1 + ⟨1⟩;
            let g = |q: i32| -> i32 { ⟨2⟩ };
            let bits = a | b;
        }
        """
        #expect(visible(source, "rust", at: 1)["c1"]?.kind == .parameter)
        #expect(visible(source, "rust", at: 2)["q"]?.kind == .parameter)
        let names = scan(source, "rust").declarations.map(\.name)
        #expect(!names.contains("a") && !names.contains("b"))
    }

    @Test func fieldsNeedSelf() {
        let source = """
        struct Config { name: String, retries: u32 }
        impl Config { fn go(&self, n: u32) { ⟨1⟩ } }
        """
        let v = visible(source, "rust")
        #expect(v["n"]?.kind == .parameter)
        #expect(v["retries"] == nil && v["name"] == nil)
        #expect(declared(source, "rust")["retries"] == .property)
    }
}

// MARK: - Java

@Suite("DeclarationScopeJava")
struct DeclarationScopeJavaTests {
    @Test func parametersSkipModifiersAnnotationsGenericsAndArrays() {
        let v = visible("""
        class A {
            public <R> R m(final int a, List<Map<String, Integer>> b, @Nullable String ann, int[] arr, String... rest) {
                ⟨1⟩
            }
        }
        """, "java")
        for name in ["a", "b", "ann", "arr", "rest"] { #expect(v[name]?.kind == .parameter, "\(name)") }
        for name in ["final", "String", "Integer", "Nullable", "R", "List"] { #expect(v[name] == nil, "\(name)") }
        #expect(v["m"]?.kind == .method)
    }

    @Test func localsLoopsCatchResourcesAndLambdas() {
        let source = """
        class A {
            void m(List<String> list) {
                int x = 1, y;
                var z = new X();
                for (String s : list) { ⟨1⟩ }
                for (int i = 0, j = 1; i < 3; i++) { ⟨2⟩ }
                try (var r = open()) { ⟨3⟩ } catch (IOException | RuntimeException e) { ⟨4⟩ }
                BiFunction<Integer, Integer, Integer> add = (p1, p2) -> ⟨5⟩;
                list.forEach(q -> use(⟨6⟩));
                ⟨7⟩
            }
        }
        """
        #expect(visible(source, "java", at: 1)["s"] != nil)
        let counter = visible(source, "java", at: 2)
        #expect(counter["i"] != nil && counter["j"] != nil)
        #expect(visible(source, "java", at: 3)["r"] != nil)
        #expect(visible(source, "java", at: 4)["e"]?.kind == .parameter)
        let lambda = visible(source, "java", at: 5)
        #expect(lambda["p1"]?.kind == .parameter && lambda["p2"]?.kind == .parameter)
        #expect(visible(source, "java", at: 6)["q"]?.kind == .parameter)
        let after = visible(source, "java", at: 7)
        for name in ["x", "y", "z", "add", "list"] { #expect(after[name] != nil, "\(name)") }
        for name in ["s", "i", "j", "r", "e", "p1", "q"] { #expect(after[name] == nil, "\(name) leaked") }
    }

    @Test func fieldsAreImplicitAndParametersShadowThem() {
        let source = """
        class Counter {
            private int value;
            private int other;
            void set(int value) { ⟨1⟩ }
        }
        """
        let v = visible(source, "java")
        #expect(v["value"]?.kind == .parameter && v["value"]?.scopeDepth == 0)
        #expect(v["other"]?.kind == .property)
        #expect(v["set"]?.kind == .method)
    }

    @Test func expressionStatementsDeclareNothing() {
        let result = scan("""
        class A {
            int m(int a, int b) {
                f(x);
                a = b;
                x.y = 1;
                a * b;
                list.get(0).run();
                return a * b;
            }
        }
        """, "java")
        #expect(Set(result.declarations.map(\.name)) == ["A", "m", "a", "b"])
    }
}

// MARK: - C#

@Suite("DeclarationScopeCSharp")
struct DeclarationScopeCSharpTests {
    @Test func parametersWithModifiersDefaultsAndAttributes() {
        let v = visible("""
        static class E {
            static void M(this Foo self, ref int a, out int b, params string[] rest, int d = 5, int? n = null,
                          [FromBody] Dictionary<string, int> map = null) { ⟨1⟩ }
        }
        """, "csharp")
        for name in ["self", "a", "b", "rest", "d", "n", "map"] { #expect(v[name]?.kind == .parameter, "\(name)") }
        #expect(v["FromBody"] == nil && v["Foo"] == nil && v["string"] == nil)
    }

    @Test func localsForeachCatchUsingOutAndLambdas() {
        let source = """
        class K {
            void M() {
                var x = 1;
                foreach (var item in items) { ⟨1⟩ }
                try { } catch (Exception ex) when (ex != null) { ⟨2⟩ }
                using (var s = Open()) { ⟨3⟩ }
                using var u = Open();
                TryGet(key, out var o);
                Func<int, int, int> add = (l1, l2) => ⟨4⟩;
                items.Select(k2 => ⟨5⟩);
                var (t1, t2) = Pair();
                ⟨6⟩
            }
        }
        """
        #expect(visible(source, "csharp", at: 1)["item"] != nil)
        #expect(visible(source, "csharp", at: 2)["ex"]?.kind == .parameter)
        #expect(visible(source, "csharp", at: 3)["s"] != nil)
        #expect(visible(source, "csharp", at: 4)["l2"]?.kind == .parameter)
        #expect(visible(source, "csharp", at: 5)["k2"]?.kind == .parameter)
        let after = visible(source, "csharp", at: 6)
        for name in ["x", "u", "o", "add", "t1", "t2"] { #expect(after[name] != nil, "\(name)") }
        for name in ["item", "ex", "s", "l1", "k2"] { #expect(after[name] == nil, "\(name) leaked") }
    }

    @Test func propertiesRecordsAndImplicitMembers() {
        let source = """
        public record Line(string Sku, int Qty)
        {
            public decimal Total => Qty * ⟨1⟩;
        }
        public class Invoice
        {
            public string Customer { get; init; } = "unknown";
            public int this[int idx] { get { return idx; } }
            public void Add(Line line) => Print(⟨2⟩);
        }
        """
        let inRecord = visible(source, "csharp", at: 1)
        #expect(inRecord["Qty"]?.kind == .property && inRecord["Sku"]?.kind == .property)
        let inMethod = visible(source, "csharp", at: 2)
        #expect(inMethod["line"]?.kind == .parameter)
        #expect(inMethod["Customer"]?.kind == .property)
        #expect(inMethod["Add"]?.kind == .method)
    }
}

// MARK: - C

@Suite("DeclarationScopeC")
struct DeclarationScopeCTests {
    @Test func parametersPointersArraysAndStructs() {
        let v = visible("""
        int f(int a, const char *b, struct point p, int arr[], unsigned long long *n, void (*cb)(int), ...) {
            ⟨1⟩
        }
        int proto(int, char);
        """, "c")
        for name in ["a", "b", "p", "arr", "n"] { #expect(v[name]?.kind == .parameter, "\(name)") }
        #expect(v["point"] == nil && v["char"] == nil)
        #expect(v["proto"]?.kind == .function)
    }

    @Test func localsDeclaratorsAndLoops() {
        let source = """
        void run(void) {
            int x = 1, *y, z[3];
            struct point pt;
            node_t *head = NULL;
            T *p1;
            T* p2;
            for (int i = 0; i < 10; i++) { ⟨1⟩ }
            ⟨2⟩
        }
        """
        #expect(visible(source, "c", at: 1)["i"] != nil)
        let after = visible(source, "c", at: 2)
        for name in ["x", "y", "z", "pt", "head", "p1", "p2"] { #expect(after[name]?.kind == .variable, "\(name)") }
        #expect(after["i"] == nil)
    }

    @Test func expressionStatementsDeclareNothing() {
        let result = scan("""
        int f(int a, int b) {
            f(x);
            a = b;
            x.y = 1;
            pt.x = 2;
            *y = 3;
            a * b;
            i++;
            return a * b;
        }
        """, "c")
        #expect(Set(result.declarations.map(\.name)) == ["f", "a", "b"])
    }

    @Test func innerLocalHidesParameterAndFieldsNeedTheStruct() {
        let source = """
        struct ring { int head; };
        int f(int v) {
            { int v = 2; ⟨1⟩ }
            ⟨2⟩
        }
        """
        let inner = visible(source, "c", at: 1)
        #expect(inner["v"]?.kind == .variable && inner["v"]?.scopeDepth == 0)
        #expect(inner["head"] == nil)
        #expect(visible(source, "c", at: 2)["v"]?.kind == .parameter)
    }

    @Test func typedefsMacrosAndCallReferences() {
        let result = scan("""
        #define MAX(a, b) ((a) > (b) ? (a) : (b))
        typedef struct node { int value; } node_t;
        int run(void) { return helper(1) + MAX(1, 2); }
        """, "c")
        let kinds = Dictionary(result.declarations.map { ($0.name, $0.kind) }) { first, _ in first }
        #expect(kinds["MAX"] == .function && kinds["node_t"] == .type && kinds["node"] == .class)
        // `helper(` is a call: coloured like the regex path did, never a declaration.
        #expect(result.table.functions.contains("helper"))
        #expect(kinds["helper"] == nil)
        // Listed: parameters and fields; locals stay scope-only.
        #expect(result.table.variables.isSuperset(of: ["value", "a", "b"]))
    }
}

// MARK: - C++

@Suite("DeclarationScopeCpp")
struct DeclarationScopeCppTests {
    @Test func bindingsLambdasAndStructuredBindings() {
        let source = """
        int main() {
            auto [k, v] = pair;
            for (auto& [k2, v2] : m) { ⟨1⟩ }
            for (const auto& e : xs) { ⟨2⟩ }
            std::vector<int> vec{1, 2};
            a::b::Cache<int, int> c(8);
            auto fn = [&](int la, const Foo& lb) -> int { return ⟨3⟩; };
            try { } catch (const std::exception& ex) { ⟨4⟩ }
            ⟨5⟩
        }
        """
        let pairLoop = visible(source, "cpp", at: 1)
        #expect(pairLoop["k2"] != nil && pairLoop["v2"] != nil)
        #expect(visible(source, "cpp", at: 2)["e"] != nil)
        let lambda = visible(source, "cpp", at: 3)
        #expect(lambda["la"]?.kind == .parameter && lambda["lb"]?.kind == .parameter)
        #expect(visible(source, "cpp", at: 4)["ex"]?.kind == .parameter)
        let after = visible(source, "cpp", at: 5)
        for name in ["k", "v", "vec", "c", "fn"] { #expect(after[name]?.kind == .variable, "\(name)") }
        for name in ["k2", "e", "la", "ex"] { #expect(after[name] == nil, "\(name) leaked") }
        // `c(8)` is a direct-initialised variable, not a call.
        #expect(!scan(source, "cpp").table.functions.contains("c"))
    }

    @Test func classMembersConstructorsAndOutOfLineDefinitions() {
        let source = """
        template <typename K, typename V>
        class Cache {
        public:
            explicit Cache(std::size_t limit) : limit_(limit) {}
            bool put(const K& key, V value) { return ⟨1⟩; }
        private:
            std::size_t limit_;
        };
        template <typename K, typename V>
        void Cache<K, V>::evict(K&& key) noexcept { int local = 1; }
        """
        let v = visible(source, "cpp")
        #expect(v["key"]?.kind == .parameter && v["value"]?.kind == .parameter)
        #expect(v["limit_"]?.kind == .property)
        let result = scan(source, "cpp")
        let kinds = Dictionary(result.declarations.map { ($0.name, $0.kind) }) { first, _ in first }
        #expect(kinds["limit"] == .parameter && kinds["evict"] == .function && kinds["local"] == .variable)
        // Constructor names and initialiser lists are no functions; the class is a type.
        #expect(result.table.types.contains("Cache") && !result.table.functions.contains("Cache"))
        #expect(!result.table.functions.contains("limit_"))
    }

    @Test func ambiguousProductsFollowTheBlankRule() {
        let names = Set(scan("""
        void f() {
            a * b;
            a & b;
            T *p;
            T* q;
            int* ok = nullptr;
            Foo& ref = other;
            std::cout << x;
        }
        """, "cpp").declarations.map(\.name))
        #expect(names == ["f", "p", "q", "ok", "ref"])
    }
}

// MARK: - Robustness of incomplete code

@Suite("DeclarationScopeStaticIncomplete")
struct DeclarationScopeStaticIncompleteTests {
    @Test func laterDeclarationsSurviveUnclosedBrackets() {
        let cases: [(String, String)] = [
            ("swift", "func a(x: Int {\n    let y = f(\n}\nfunc later(p: Int) { ⟨1⟩ }\n"),
            ("go", "func a(x int {\n\ty := f(\n}\nfunc later(p int) { ⟨1⟩ }\n"),
            ("rust", "fn a(x: i32 {\n    let y = f(\n}\nfn later(p: i32) { ⟨1⟩ }\n"),
            ("java", "class A {\n  void a(int x {\n    int y = f(\n  }\n  public void later(int p) { ⟨1⟩ }\n}\n"),
            ("csharp", "class A {\n  void a(int x {\n    int y = f(\n  }\n  public void later(int p) { ⟨1⟩ }\n}\n"),
            ("c", "int a(int x {\n  int y = f(\n}\ntypedef int later_t;\nint later(int p) { ⟨1⟩ }\n"),
            ("cpp", "int a(int x {\n  int y = f(\n}\ntemplate <typename T>\nint later(int p) { ⟨1⟩ }\n"),
        ]
        for (language, source) in cases {
            let result = scan(source, language)
            #expect(result.declarations.contains { $0.name == "later" }, "\(language)")
            #expect(visible(source, language)["p"]?.kind == .parameter, "\(language)")
        }
    }
}

// MARK: - Slicing on a construct zoo

/// One source per language exercising the constructs above (and more):
/// every lookahead decision must be the same however the text is sliced.
private let constructZoo: [(String, String)] = [
    ("swift", #"""
    func f(label inner: Int, _ x: [String: Int] = [:], y: Int = g(1, 2)) {
        let (a, b) = pair
        var c = 1, d: Int = 2
        if let e = opt { use(e) }
        guard let g2 = opt else { return }
        while let w = it.next() { use(w) }
        for item in items { use(item) }
        for (i, v) in xs.enumerated() { use(i) }
        switch val {
        case let .some(z): use(z)
        case .pair(let p1, let p2): use(p1)
        default: break
        }
        let h = items.map { a1, b1 in a1 + b1 }
        let k = items.map { (c1: Int) -> Int in c1 }
        let m = items.filter { $0 > 1 }
        do { try run() } catch let err as MyError { use(err) }
    }
    struct S {
        var field = 1
        lazy var lz: Int = 2
        private(set) var ps = 3
        @Published var pub = 4
        static let shared = S()
        func method(v: Int) { let v = 2; print(field) }
        init?(raw: String) { self.field = 0 }
        subscript(index: Int) -> Int { index }
        var computed: Int { let inner = 1; return inner }
        var observed: Int = 0 {
            didSet { print(oldValue) }
        }
    }
    protocol P {
        func req(a: Int) -> Int
        var prop: Int { get }
    }
    class C: Base {
        class func cf() {}
        final class Nested {}
        override func ov(q: Int) {}
    }
    extension S: P { func req(a: Int) -> Int { a } }
    #if DEBUG
    let debugOnly = 1
    #endif
    typealias Alias = Int
    enum E { case a, b(Int) }
    """#),
    ("go", #"""
    package main

    type T struct {
    	A, B int
    	inner struct{ X int }
    	sync.Mutex
    }

    type (
    	Alias = int
    	Pair[K comparable, V any] struct{ k K }
    )

    type Shape interface {
    	Area(scale float64) float64
    	fmt.Stringer
    }

    var (
    	gx, gy = 1, 2
    	gz     int
    )

    const k = 1

    func (r *T) name(a, b int, c string) (res int, err error) {
    	x, y := f()
    	var m, n int
    	for i, v := range xs {
    		use(i, v)
    	}
    	for j := 0; j < 10; j++ {
    	}
    	if e := g(); e != nil {
    		return
    	}
    	switch s := v.(type) {
    	case int:
    		use(s)
    	}
    	select {
    	case msg := <-ch:
    		use(msg)
    	}
    	fn := func(p int) (q int) { return p }
    	go func() { local := 1 }()
    	return
    }

    func Generic[T any](items []T) map[string]interface{} {
    	return nil
    }
    func noNames(int, string) {}
    func variadic(prefix string, args ...interface{}) {}
    """#),
    ("rust", #"""
    struct Point { x: i32, y: i32 }
    enum E { A, B(i32), C { inner: u8 } }
    trait Tr { fn req(&self, n: u32) -> u32; type Item; const K: u32; }
    impl Point {
        fn name(mut a: T, (x, y): (i32, i32), &self, Point { x: px, y }: Point, _: u8) -> i32 {
            let mut m = 1;
            let (t1, t2) = p;
            let Point { x: renamed, y: py } = pt;
            let Some(v) = opt else { return 0; };
            for (i, w) in it.enumerate() { use(i); }
            if let Some(s) = o { use(s); }
            while let Some(st) = stack.pop() {}
            let f = |c1, c2| c1 + c2;
            let g = |q: i32| -> i32 { let qq = q; qq };
            let h = move || x;
            let bits = a | b;
            match val { Some(arm) => arm, None => 0 }
            'outer: loop { break 'outer; }
            0
        }
    }
    pub(crate) fn free<T: Clone>(v: Vec<T>) where T: Copy {}
    static mut COUNTER: u32 = 0;
    macro_rules! mac { ($x:expr) => { let y = $x; } }
    mod inner { pub fn nested() {} }
    #[cfg(test)]
    mod tests { #[test] fn t() { let z = 1; } }
    """#),
    ("java", #"""
    @SuppressWarnings("unchecked")
    public class A<T extends Comparable<T>> extends B implements C, D {
        private static final Map<String, List<Integer>> table = new HashMap<>();
        int[] arr = {1, 2}, other;
        public A(int seed) { this.seed = seed; }
        @Override
        public <R> R m(final int a, List<Map<String, Integer>> b, @Nullable String ann, int[] arr2, String... rest) {
            int x = 1, y;
            var z = new X();
            for (String s : list) { use(s); }
            for (int i = 0, j = 1; i < n; i++) { }
            try (var r = open(); Reader rd = other()) { } catch (IOException | RuntimeException e) { } finally { }
            Runnable run = () -> System.out.println(x);
            BiFunction<Integer, Integer, Integer> add = (p1, p2) -> p1 + p2;
            list.forEach(q -> use(q));
            list.forEach((Item it) -> { int inLambda = 1; });
            f(x);
            a = b;
            x.y = 1;
            a * b;
            switch (k) { case ONE -> use(1); case TWO, THREE -> { int c = 2; } default -> {} }
            new Thread(new Runnable() { public void run() { int anon = 1; } }).start();
            return a * b;
        }
        enum Color { RED("r"), GREEN("g"); private final String code; Color(String code) { this.code = code; } }
        record Point(int px, int py) { int sum() { return px + py; } }
        interface I { void req(int ri); default int d() { return 1; } }
    }
    """#),
    ("csharp", #"""
    using System;
    using Alias = System.Text;
    namespace N.Sub {
    [Serializable]
    public partial class K<T> : Base where T : class {
        public int Prop { get; set; } = 3;
        public string Name => _name;
        private event EventHandler Changed;
        public K(int seed) : base(seed) { }
        public static int operator +(K a, K b) => 1;
        public int this[int idx] { get { return idx; } }
        void M(ref int a, out int b, params string[] rest, int d = 5, int? n = null, [FromBody] Foo attr = null) {
            var x = 1;
            int[] arr = new int[3];
            foreach (var item in items) { }
            foreach (var (k1, v1) in pairs) { }
            try { } catch (Exception ex) when (ex != null) { }
            using (var s = Open()) { }
            using var u = Open();
            TryGet(key, out var o);
            int.TryParse(str, out int parsed);
            Func<int, int, int> add = (l1, l2) => l1 + l2;
            items.Select(k2 => k2 * 2);
            var (t1, t2) = Pair();
            Dictionary<string, Foo> dict = new Dictionary<string, Foo>();
            int Local(int lp) => lp;
            f(x);
            a = b;
            x.y = 1;
            await Task.Delay(1);
        }
    }
    public record Line(string Sku, int Qty);
    }
    """#),
    ("c", #"""
    #include <stdio.h>
    #define MAX(a, b) ((a) > (b) ? (a) : (b))
    #define LIMIT 10
    typedef struct node { int value; struct node *next; } node_t;
    typedef int (*cmp_fn)(const void *, const void *);
    struct point origin;
    static const char *names[] = { "a", "b" };
    unsigned long long counter = 0, *ptr;
    int f(int a, const char *b, struct point p, int arr[], void (*cb)(int), ...) {
        int x = 1, *y, z[3];
        struct point pt;
        node_t *head = NULL;
        for (int i = 0; i < 10; i++) { int inner = i; }
        T *p1;
        T* p2;
        a * b;
        f(x);
        a = b;
        x.y = 1;
        pt.x = 2;
        *y = 3;
        return a * b;
    }
    int proto(int, char);
    void kr();
    static inline size_t len(const node_t *n) { return n->value; }
    int main(int argc, char **argv) { return f(argc, argv[0], origin, 0, 0); }
    """#),
    ("cpp", #"""
    #include <map>
    namespace a::b {
    template <typename K, typename V>
    class Cache : public Base<K> {
    public:
        Cache(int limit) : limit_(limit), map_{} {}
        ~Cache() {}
        V* get(const K& key) const { return nullptr; }
        void put(K&& key, V value) noexcept override;
        bool operator==(const Cache& other) const { return true; }
        static constexpr int kMax = 3;
    private:
        int limit_;
        std::map<K, V> map_;
    };
    template <typename K, typename V>
    void Cache<K, V>::put(K&& key, V value) noexcept { int local = 1; }
    Cache<int, int>::Cache(int limit) : limit_(limit) {}
    }
    int main() {
        auto [k, v] = pair;
        for (auto& [k2, v2] : m) {}
        for (const auto& e : xs) {}
        auto it = m.find(1);
        std::vector<int> vec{1, 2};
        a::b::Cache<int, int> c(8);
        auto fn = [&](int la, const Foo& lb) -> int { int body = la; return body; };
        auto noargs = [] { return 1; };
        try { } catch (const std::exception& ex) { }
        if (auto p = get(); p != nullptr) { }
        std::cout << x << std::endl;
        a * b;
        a & b;
        int* ok = nullptr;
        Foo& ref = other;
        delete ok;
        return 0;
    }
    """#),
]

@Suite("DeclarationScopeStaticSlicing")
struct DeclarationScopeStaticSlicingTests {
    @Test func slicedScansEqualTheOneShotScan() {
        var rng = SystemRandomNumberGenerator()
        for (language, source) in constructZoo {
            let ns = source as NSString
            var oneShotScanner = DeclarationScanner(languageIdentifier: language)
            let oneShot = oneShotScanner.finish(ns)
            #expect(oneShotScanner.droppedOutOfOrder == 0, "\(language)")
            #expect(oneShot.declarations.count > 20, "\(language)")
            for budget in [1, 2, 3, 5, 7, 13, 64, 4096] {
                var scanner = DeclarationScanner(languageIdentifier: language)
                while !scanner.step(ns, budgetUnits: budget) {}
                #expect(scanner.scan == oneShot, "\(language) budget \(budget)")
            }
            for _ in 0..<5 {
                var scanner = DeclarationScanner(languageIdentifier: language)
                while !scanner.step(ns, budgetUnits: Int.random(in: 1...40, using: &rng)) {}
                #expect(scanner.scan == oneShot, "\(language) random budgets")
            }
        }
    }
}

// MARK: - Function shadowing (VH5)

/// The highlighter's shadowing inputs (LEDGER VH5): the function names also
/// declared as a binding, and the scopes `shadowScopes(at:)` picks.
@Suite("DeclarationShadowing")
struct DeclarationShadowingTests {
    /// Per language: a function named like a parameter / local / property
    /// enters `shadowableFunctionNames`; a function without such a binding,
    /// and a binding without such a function, do not.
    static let samples: [(language: String, source: String, expected: Set<String>)] = [
        ("c", "int total(int a) { return a; }\nint size(void) { return 0; }\nint keep(void) { return 1; }\n"
            + "int f(int total) { int size = 1; return total + size; }\nint g(int other) { return other; }\n",
         ["total", "size"]),
        ("cpp", "int total(int a) { return a; }\nstruct Box { int size; int size_of() const { return size; } };\n"
            + "int size() { return 0; }\nint f(int total) { auto keep = 1; return total + keep; }\n",
         ["total", "size"]),
        ("java", "class Cases {\n    private int size;\n    int size() { return size; }\n    int count() { return 0; }\n"
            + "    int keep() { return 1; }\n    void m(int count) { int other = count; }\n}\n",
         ["size", "count"]),
        ("csharp", "class Cases {\n    private int size;\n    int Size() { return size; }\n    int Count { get; set; }\n"
            + "    void Grow() { }\n    int Shadow(int Size) { var Grow = Size; return Grow; }\n}\n",
         ["Size", "Grow"]),
        ("swift", "struct Cases {\n    var count: Int\n    func count(of x: Int) -> Int { count + x }\n}\n"
            + "func code() {}\nfunc keep() {}\nfunc f(code: Int) { let other = code }\n"
            + "func g() { [1].map { keep in keep } }\n",
         ["count", "code", "keep"]),
        ("go", "package cases\n\nfunc handler(w int) {}\nfunc size() int { return 1 }\nfunc keep() {}\n"
            + "func shadow(handler int) int { size := handler; return size }\n",
         ["handler", "size"]),
    ]

    @Test(arguments: 0..<6)
    func shadowableNamesPerLanguage(_ index: Int) {
        let sample = Self.samples[index]
        let result = scan(sample.source, sample.language)
        #expect(result.shadowableFunctionNames == sample.expected, "\(sample.language)")
        #expect(result.shadowableFunctionNames.isSubset(of: result.table.functions), "\(sample.language)")
    }

    @Test(arguments: ["c", "cpp", "java", "csharp", "swift", "go"])
    func emptyWhenNoNameIsBoth(_ language: String) {
        let source: String
        switch language {
        case "go": source = "package p\n\nfunc total(a int) int { b := a; return b }\n"
        case "swift": source = "func total(a: Int) -> Int { let b = a; return b }\n"
        case "java", "csharp": source = "class C {\n    int f;\n    int Total(int a) { int b = a; return b; }\n}\n"
        default: source = "int total(int a) { int b = a; return b; }\n"
        }
        let result = scan(source, language)
        #expect(!result.table.functions.isEmpty, "\(language)")
        #expect(result.shadowableFunctionNames.isEmpty, "\(language)")
        // The regex path never fills it.
        let legacy = DeclarationScan.regexScan(Caret(source).text as NSString, languageIdentifier: language)
        #expect(legacy.shadowableFunctionNames.isEmpty, "\(language)")
    }

    /// A function's own parameters lie inside its scope (so
    /// `shadowingBindings(inFunction:)` of the scope found in the body holds
    /// them) in every language with the check.
    @Test(arguments: [
        ("c", "int total(int a) { return a; }\nint f(int total) { return ⟨1⟩total; }\n"),
        ("cpp", "int total(int a) { return a; }\nint f(int total) { return ⟨1⟩total; }\n"),
        ("java", "class C {\n    int total() { return 0; }\n    int f(int total) { return ⟨1⟩total; }\n}\n"),
        ("csharp", "class C {\n    int Total() { return 0; }\n    int F(int Total) { return ⟨1⟩Total; }\n}\n"),
        ("swift", "func total() {}\nfunc f(total: Int) -> Int { return ⟨1⟩total }\n"),
        ("go", "package p\n\nfunc total() {}\nfunc (r R) f(total int) int { return ⟨1⟩total }\n"),
    ])
    func parametersLieInsideTheirFunctionScope(_ language: String, _ source: String) throws {
        let caret = Caret(source)
        let result = DeclarationScan.scan(text: caret.text, languageIdentifier: language)
        let function = try #require(result.shadowScopes(at: caret.offsets[1]!).function, "\(language)")
        let name = language == "csharp" ? "Total" : "total"
        let parameter = try #require(result.declarations.first { $0.kind == .parameter && $0.name == name },
                                     "\(language)")
        #expect(function.start <= parameter.location && parameter.location < function.end, "\(language)")
        #expect(result.shadowingBindings(inFunction: function) == [name], "\(language)")
    }

    /// The highlighter's `ShadowScopeIndex` answers what `shadowScopes(at:)`
    /// answers, at every offset (nested types, closures, local classes).
    @Test(arguments: 0..<6)
    func shadowScopeIndexAgreesWithShadowScopes(_ index: Int) {
        let sample = Self.samples[index]
        let extra: String
        switch sample.language {
        case "swift": extra = "struct A { struct B { func m() { let f = { (x: Int) in x }; class L { var y = 1 } } } var z = 2 }\n"
        case "java", "csharp": extra = "class A { class B { void M() { Runnable r = () -> { int k = 0; }; } } int z; }\n"
        case "go": extra = "func (a A) m() { f := func(x int) { _ = x }; _ = f }\n"
        default: extra = "struct A { int z; };\nint m(void) { { int k = 0; } return 0; }\n"
        }
        let text = sample.source + extra
        let result = scan(text, sample.language)
        let shadowIndex = result.shadowScopeIndex()
        for offset in 0...(text as NSString).length {
            let expected = result.shadowScopes(at: offset)
            let actual = shadowIndex.scopes(at: offset)
            #expect(actual.function == expected.function && actual.type == expected.type,
                    "\(sample.language) at \(offset)")
        }
    }

    /// The properties of the enclosing type hide a function's name; a local
    /// of a method in that type is not one of them.
    @Test func typePropertiesAreTheShadowingMembers() throws {
        let caret = Caret("""
            struct S {
                let a: Int?
                let code: Int
                func run() { let render = 1; _ = render; ⟨1⟩ }
            }
            func code() {}
            func render() {}
            """)
        let s = DeclarationScan.scan(text: caret.text, languageIdentifier: "swift")
        #expect(s.declarations.first { $0.name == "code" }?.kind == .property)
        let type = try #require(s.shadowScopes(at: caret.offsets[1]!).type)
        #expect(s.shadowingProperties(inType: type) == ["code"])
    }

    /// The outermost function / lambda (a closure's parameters count for the
    /// enclosing function), and the innermost type around that function.
    @Test func shadowScopesPicksTheOutermostFunctionAndTheInnermostType() throws {
        let swift = Caret("""
            struct Outer {
                struct Inner {
                    var code: Int
                    func run() { let f = { (code: Int) in ⟨1⟩code }; _ = f }
                }
                func code() {}
            }
            let top = { (x: Int) in ⟨2⟩x }
            ⟨3⟩
            """)
        let s = DeclarationScan.scan(text: swift.text, languageIdentifier: "swift")
        let inClosure = s.shadowScopes(at: swift.offsets[1]!)
        let function = try #require(inClosure.function)
        #expect(function.kind == .function)
        #expect(s.scopeChain(at: swift.offsets[1]!).first?.kind == .lambda)
        #expect(inClosure.type?.name == "Inner")
        #expect(s.shadowingBindings(inFunction: function) == ["code"])     // the closure's parameter
        #expect(s.shadowingProperties(inType: try #require(inClosure.type)) == ["code"])
        // A file-level closure is its own outermost function; no type.
        let top = s.shadowScopes(at: swift.offsets[2]!)
        #expect(top.function?.kind == .lambda)
        #expect(top.type == nil)
        #expect(s.shadowScopes(at: swift.offsets[3]!).function == nil)

        // Java: a lambda inside a method belongs to the method; a local class
        // inside the method is not the type (the enclosing one is).
        let java = Caret("""
            class Outer {
                int size;
                int size() { return 0; }
                void m() {
                    Runnable r = () -> { int k = ⟨1⟩size; };
                    class Local { int size; void n() { ⟨2⟩size = 1; } }
                }
            }
            """)
        let j = DeclarationScan.scan(text: java.text, languageIdentifier: "java")
        let lambda = j.shadowScopes(at: java.offsets[1]!)
        #expect(lambda.function?.kind == .function)
        #expect(lambda.type?.name == "Outer")
        let local = j.shadowScopes(at: java.offsets[2]!)
        #expect(local.function == lambda.function)
        #expect(local.type?.name == "Outer")
        #expect(j.shadowingProperties(inType: try #require(local.type)) == ["size"])
    }
}
