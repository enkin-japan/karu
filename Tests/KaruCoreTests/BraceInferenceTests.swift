import AppKit
import Foundation
import Testing
@testable import KaruCore

// M17 T17.11d — member candidates for Swift, Go, Rust, Java, C#, C and C++
// from explicit declarations (plan §8.1 「只用显式声明」): every receiver
// form per language, extension / impl / base merging, visibility, static vs
// instance, chained fields and written return types, the precision rules
// (library and unknown types, shadowing, wrong access operators), the
// completion wiring (`->` / `::`) and release when a module is switched off.

private func isolatedDefaults() -> (UserDefaults, () -> Void) {
    let name = "BraceInferenceTests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return (d, { d.removePersistentDomain(forName: name) })
}

/// A document with its analysis and an inference service. `‸` marks the
/// caret, right after the access operator (and an optional member prefix).
@MainActor
private final class BraceProbe {
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
    let analysis: DocumentAnalysis
    let service = TypeInferenceService(tables: .shared)
    let caret: Int
    let language: String
    private let clean: () -> Void

    init(_ source: String, _ language: String) {
        let ns = source as NSString
        let mark = ns.range(of: "‸")
        precondition(mark.location != NSNotFound, "mark the caret with ‸")
        caret = mark.location
        self.language = language
        textView.string = ns.replacingCharacters(in: mark, with: "")
        let (defaults, clean) = isolatedDefaults()
        self.clean = clean
        analysis = DocumentAnalysis(textView: textView,
                                    moduleSettings: ModuleSettings(defaults: defaults, center: NotificationCenter()),
                                    moduleCenter: NotificationCenter(), scheduler: AnalysisScheduler())
        analysis.setLanguage(identifier: language)
    }

    deinit { clean() }

    var text: NSString { textView.textStorage!.mutableString }

    /// The access operator's first unit.
    var dot: Int {
        let start = IdentifierText.runStart(before: caret, in: text, dollar: language == "swift" || language == "java")
            ?? caret
        if let op = CompletionContext.accessOperator(before: start, in: text, languageIdentifier: language) {
            return op.location
        }
        return start - 1
    }

    var candidates: [Candidate]? {
        service.memberCandidates(analysis: analysis, text: text, dot: dot).map { CandidateEngine.ranked($0) }
    }

    var names: [String]? { candidates?.map(\.name) }

    func detail(_ name: String) -> String? { candidates?.first { $0.name == name }?.detail }
}

@MainActor private func members(_ source: String, _ language: String) -> [String]? {
    BraceProbe(source, language).names
}

@MainActor private func memberSet(_ source: String, _ language: String) -> Set<String>? {
    members(source, language).map(Set.init)
}

// MARK: - Swift

@Suite("BraceInference Swift")
@MainActor
struct BraceInferenceSwiftTests {
    static let types = """
    protocol Named { var title: String { get } }
    extension Named { func describe() -> String { title } }
    class Shape: Named {
        var title: String = ""
        private var secret = 0
        static var count = 0
        static func make() -> Shape { Shape() }
        func area() -> Double { 0 }
        func copy() -> Self { self }
    }
    final class Circle: Shape {
        var radius: Double = 1
        var center: Point = Point(x: 0, y: 0)
        func scaled(by k: Double) -> Circle { self }
    }
    struct Point { var x: Double; var y: Double }
    extension Point { func distance(to other: Point) -> Double { 0 } }
    enum Kind { case circle, square(Int) }

    """

    @Test func annotatedLocalsParametersAndInitializers() throws {
        #expect(memberSet(Self.types + "func f() {\n    let c: Circle = make()\n    c.‸\n}", "swift")
            == ["radius", "center", "scaled", "title", "area", "copy", "describe"])
        #expect(memberSet(Self.types + "func f(p: Point) {\n    p.‸\n}", "swift") == ["x", "y", "distance"])
        #expect(memberSet(Self.types + "func f() {\n    var p = Point(x: 1, y: 2)\n    p.‸\n}", "swift")
            == ["x", "y", "distance"])
        #expect(memberSet(Self.types + "func f() {\n    let p = Point.init(x: 1, y: 2)\n    p.‸\n}", "swift")
            == ["x", "y", "distance"])
        let probe = BraceProbe(Self.types + "func f(c: Circle) {\n    c.‸\n}", "swift")
        let list = try #require(probe.names)
        // Own members before inherited ones, then the protocol's.
        #expect(list.firstIndex(of: "radius")! < list.firstIndex(of: "area")!)
        #expect(list.firstIndex(of: "area")! < list.firstIndex(of: "describe")!)
        #expect(probe.detail("scaled") == "(by k: Double) -> Circle")
        #expect(probe.detail("radius") == "Double")
    }

    @Test func selfStaticAndPrivate() throws {
        let inside = memberSet(Self.types.replacingOccurrences(of: "func area() -> Double { 0 }",
                                                               with: "func area() -> Double { self.‸ }"), "swift")
        #expect(inside == ["title", "secret", "area", "copy", "describe"])
        // `private` is hidden outside the type (and its extensions).
        let outside = try #require(memberSet(Self.types + "func f(s: Shape) {\n    s.‸\n}", "swift"))
        #expect(!outside.contains("secret") && !outside.contains("count") && !outside.contains("make"))
        // Type level: static members and enum cases only.
        #expect(memberSet(Self.types + "func f() {\n    Shape.‸\n}", "swift") == ["count", "make"])
        #expect(memberSet(Self.types + "func f() {\n    Kind.‸\n}", "swift") == ["circle", "square"])
        // `self` in a static method is the type.
        #expect(memberSet(Self.types.replacingOccurrences(of: "static func make() -> Shape { Shape() }",
                                                          with: "static func make() -> Shape { self.‸ }"), "swift")
            == ["count", "make"])
    }

    @Test func chainsOptionalsAndReturnTypes() {
        #expect(memberSet(Self.types + "func f(c: Circle) {\n    c.center.‸\n}", "swift") == ["x", "y", "distance"])
        #expect(memberSet(Self.types + "func f(c: Circle) {\n    c.scaled(by: 2).center.‸\n}", "swift")
            == ["x", "y", "distance"])
        #expect(memberSet(Self.types + "func f() {\n    Shape.make().‸\n}", "swift")?.contains("area") == true)
        // `Self` results follow the receiver.
        #expect(memberSet(Self.types + "func f(c: Circle) {\n    c.copy().‸\n}", "swift")?.contains("radius") == true)
        // Optionals: `?.` and `!.` unwrap, `.` does not.
        #expect(members(Self.types + "func f(p: Point?) {\n    p.‸\n}", "swift") == nil)
        #expect(memberSet(Self.types + "func f(p: Point?) {\n    p?.‸\n}", "swift") == ["x", "y", "distance"])
        #expect(memberSet(Self.types + "func f(p: Point?) {\n    p!.‸\n}", "swift") == ["x", "y", "distance"])
        #expect(memberSet(Self.types + "func f(p: Point?) {\n    if let q = p {\n        q.‸\n    }\n}", "swift")
            == ["x", "y", "distance"])
        #expect(memberSet(Self.types + "func f(c: Circle?) {\n    guard let c else { return }\n    c.‸\n}", "swift")?
            .contains("radius") != false)
    }

    @Test func extensionsOfNestedTypesAndImplicitMembers() {
        let source = """
        struct Outer {
            struct Inner { var a = 0 }
            var inner: Inner
        }
        extension Outer.Inner { func b() {} }
        extension Outer { func c() { inner.‸ } }
        """
        #expect(memberSet(source, "swift") == ["a", "b"])
    }

    @Test func precision() {
        // Library and unknown types give nothing (usage evidence then).
        #expect(members("func f(s: String) {\n    s.‸\n}", "swift") == nil)
        #expect(members("func f() {\n    let x = compute()\n    x.‸\n}", "swift") == nil)
        #expect(members(Self.types + "func f(xs: [Point]) {\n    xs.‸\n}", "swift") == nil)
        #expect(members(Self.types + "func f() {\n    let p = Point(x: 1, y: 2) + q\n    p.‸\n}", "swift") == nil)
        // A local shadows the parameter.
        #expect(memberSet(Self.types + "func f(v: Circle) {\n    let v: Point = .init(x: 0, y: 0)\n    v.‸\n}", "swift")
            == ["x", "y", "distance"])
        // Closure parameters have no written type.
        #expect(members(Self.types + "func f(xs: [Point]) {\n    xs.map { p in p.‸ }\n}", "swift") == nil)
    }
}

// MARK: - Go

@Suite("BraceInference Go")
@MainActor
struct BraceInferenceGoTests {
    static let types = """
    package app

    type Base struct {
    \tID int
    }

    func (b *Base) Key() string { return "" }

    type Server struct {
    \tBase
    \tAddr string
    \tconn *Conn
    }

    type Conn struct {
    \tRemote string
    }

    func (c Conn) Close() error { return nil }
    func (s *Server) Start() error { return nil }
    func (s *Server) Peer() *Conn { return s.conn }

    func NewServer(addr string) *Server { return &Server{Addr: addr} }
    func Open() (*Conn, error) { return nil, nil }
    func helper() {}

    type Celsius float64

    func (c Celsius) Fahrenheit() float64 { return 0 }

    type Reader interface {
    \tRead(p []byte) (int, error)
    }

    type ReadCloser interface {
    \tReader
    \tClose() error
    }

    """

    @Test func receiverForms() {
        let server: Set<String> = ["Base", "Addr", "conn", "Start", "Peer", "ID", "Key"]
        #expect(memberSet(Self.types + "func f() {\n\tvar s Server\n\ts.‸\n}", "go") == server)
        #expect(memberSet(Self.types + "func f() {\n\ts := Server{Addr: \"x\"}\n\ts.‸\n}", "go") == server)
        #expect(memberSet(Self.types + "func f() {\n\ts := &Server{}\n\ts.‸\n}", "go") == server)
        #expect(memberSet(Self.types + "func f() {\n\ts := NewServer(\":80\")\n\ts.‸\n}", "go") == server)
        #expect(memberSet(Self.types + "func f() {\n\tc, err := Open()\n\tc.‸\n}", "go") == ["Remote", "Close"])
        #expect(memberSet(Self.types + "func (s *Server) Stop() {\n\ts.‸\n}", "go")?.isSuperset(of: server) == true)
        #expect(memberSet(Self.types + "func f(c *Conn) {\n\tc.‸\n}", "go") == ["Remote", "Close"])
        #expect(memberSet(Self.types + "func f(a, b Conn) {\n\tb.‸\n}", "go") == ["Remote", "Close"])
    }

    @Test func chainsDefinedTypesAndInterfaces() throws {
        #expect(memberSet(Self.types + "func f(s *Server) {\n\ts.conn.‸\n}", "go") == ["Remote", "Close"])
        #expect(memberSet(Self.types + "func f(s *Server) {\n\ts.Peer().‸\n}", "go") == ["Remote", "Close"])
        #expect(memberSet(Self.types + "func f(t Celsius) {\n\tt.‸\n}", "go") == ["Fahrenheit"])
        #expect(memberSet(Self.types + "func f(r ReadCloser) {\n\tr.‸\n}", "go") == ["Close", "Read"])
        let probe = BraceProbe(Self.types + "func f(s Server) {\n\ts.‸\n}", "go")
        let list = try #require(probe.names)
        #expect(list.firstIndex(of: "Addr")! < list.firstIndex(of: "ID")!)   // promoted fields rank after own
        #expect(probe.detail("Start") == "() error")
        #expect(BraceProbe(Self.types + "func f(r Reader) {\n\tr.‸\n}", "go").detail("Read") == "(p []byte) (int, error)")
    }

    @Test func precision() {
        #expect(members(Self.types + "func f() {\n\tx := 5\n\tx.‸\n}", "go") == nil)
        #expect(members(Self.types + "func f() {\n\tx := helper()\n\tx.‸\n}", "go") == nil)
        #expect(members(Self.types + "func f() {\n\tb := bytes.Buffer{}\n\tb.‸\n}", "go") == nil)
        #expect(members(Self.types + "func f(xs []Conn) {\n\txs.‸\n}", "go") == nil)
        #expect(members(Self.types + "func f() {\n\tc := Open()\n\tc.‸\n}", "go") == nil)   // two results
        #expect(members(Self.types + "func f() {\n\tServer.‸\n}", "go") == nil)            // no static members
        #expect(members(Self.types + "func f(m map[string]Conn) {\n\tfor _, v := range m {\n\t\tv.‸\n\t}\n}", "go") == nil)
    }
}

// MARK: - Rust

@Suite("BraceInference Rust")
@MainActor
struct BraceInferenceRustTests {
    static let types = """
    pub trait Shape {
        fn area(&self) -> f64;
        fn describe(&self) -> String { String::new() }
    }

    pub struct Rect {
        pub w: f64,
        pub h: f64,
        origin: Point,
    }

    pub struct Point { pub x: f64, pub y: f64 }

    impl Rect {
        pub const UNIT: f64 = 1.0;
        pub fn new(w: f64, h: f64) -> Self { Rect { w, h, origin: Point { x: 0.0, y: 0.0 } } }
        pub fn square(s: f64) -> Rect { Rect::new(s, s) }
        pub fn origin(&self) -> &Point { &self.origin }
        fn grow(&mut self) {}
    }

    impl Shape for Rect {
        fn area(&self) -> f64 { self.w * self.h }
    }

    pub enum Mode { Fast, Safe(u8), Custom { level: u8 } }

    mod inner {
        pub struct Hidden { secret: u8, pub open: u8 }
    }

    """

    @Test func receiverForms() throws {
        let rect: Set<String> = ["w", "h", "origin", "grow", "area", "describe"]
        #expect(memberSet(Self.types + "fn f() {\n    let r: Rect = Rect::new(1.0, 2.0);\n    r.‸\n}", "rust") == rect)
        #expect(memberSet(Self.types + "fn f() {\n    let mut r = Rect::new(1.0, 2.0);\n    r.‸\n}", "rust") == rect)
        #expect(memberSet(Self.types + "fn f() {\n    let r = Rect::square(1.0);\n    r.‸\n}", "rust") == rect)
        #expect(memberSet(Self.types + "fn f() {\n    let p = Point { x: 1.0, y: 2.0 };\n    p.‸\n}", "rust") == ["x", "y"])
        #expect(memberSet(Self.types + "fn f(r: &mut Rect) {\n    r.‸\n}", "rust") == rect)
        #expect(memberSet(Self.types + "fn f(r: Box<Rect>) {\n    r.‸\n}", "rust") == rect)
        let probe = BraceProbe(Self.types.replacingOccurrences(of: "fn grow(&mut self) {}",
                                                               with: "fn grow(&mut self) { self.‸ }"), "rust")
        #expect(Set(try #require(probe.names)) == rect)
        #expect(probe.detail("area") == "(&self) -> f64")
    }

    @Test func associatedItemsTraitsAndChains() {
        #expect(memberSet(Self.types + "fn f() {\n    Rect::‸\n}", "rust") == ["UNIT", "new", "square"])
        #expect(memberSet(Self.types + "fn f() {\n    Mode::‸\n}", "rust") == ["Fast", "Safe", "Custom"])
        #expect(memberSet(Self.types + "fn f(r: &Rect) {\n    r.origin().‸\n}", "rust") == ["x", "y"])
        #expect(memberSet(Self.types + "fn f() {\n    Rect::new(1.0, 1.0).‸\n}", "rust")?.contains("area") == true)
        #expect(memberSet(Self.types + "fn f(s: &dyn Shape) {\n    s.‸\n}", "rust") == ["area", "describe"])
    }

    @Test func visibilityAndPrecision() {
        // Private fields of a type in another module are hidden.
        #expect(memberSet(Self.types + "fn f(h: inner::Hidden) {\n    h.‸\n}", "rust") == nil)
        #expect(memberSet(Self.types.replacingOccurrences(of: "pub struct Hidden { secret: u8, pub open: u8 }",
                                                          with: "pub struct Hidden { secret: u8, pub open: u8 }\n    fn g(h: Hidden) { h.‸ }"),
                          "rust") == ["secret", "open"])
        #expect(members(Self.types + "fn f(v: Vec<Rect>) {\n    v.‸\n}", "rust") == nil)
        #expect(members(Self.types + "fn f(o: Option<Rect>) {\n    o.‸\n}", "rust") == nil)
        #expect(members(Self.types + "fn f() {\n    let r = make();\n    r.‸\n}", "rust") == nil)
        #expect(members(Self.types + "fn f(o: Option<Rect>) {\n    if let Some(r) = o {\n        r.‸\n    }\n}", "rust")
            == nil)
        // Shadowing with `let`.
        #expect(memberSet(Self.types + "fn f(r: Rect) {\n    let r: Point = Point { x: 0.0, y: 0.0 };\n    r.‸\n}", "rust")
            == ["x", "y"])
    }
}

// MARK: - Java

@Suite("BraceInference Java")
@MainActor
struct BraceInferenceJavaTests {
    static let types = """
    interface Priced { double price(); default String label() { return ""; } }

    abstract class Item implements Priced {
        protected String sku;
        private int stock;
        static int created;
        public abstract double price();
        static Item of(String sku) { return null; }
    }

    class Book extends Item {
        String title;
        Author author;
        public double price() { return 1; }
        Author writer() { return author; }
        private void audit() {}
    }

    class Author { String name; Book[] books; }

    """

    @Test func receiverForms() throws {
        let book: Set<String> = ["title", "author", "price", "writer", "sku", "label"]
        #expect(memberSet(Self.types + "class T { void f() { Book b = new Book(); b.‸ } }", "java") == book)
        #expect(memberSet(Self.types + "class T { void f() { var b = new Book(); b.‸ } }", "java") == book)
        #expect(memberSet(Self.types + "class T { void f(final Book b) { b.‸ } }", "java") == book)
        #expect(memberSet(Self.types + "class T { Book field; void f() { field.‸ } }", "java") == book)
        #expect(memberSet(Self.types + "class T { void f() { new Book().‸ } }", "java") == book)
        let inside = memberSet(Self.types.replacingOccurrences(of: "private void audit() {}",
                                                               with: "private void audit() { this.‸ }"), "java")
        #expect(inside == book.union(["audit"]))
        let probe = BraceProbe(Self.types + "class T { void f(Book b) { b.‸ } }", "java")
        #expect(probe.detail("writer") == "() : Author")
        #expect(probe.detail("title") == "String")
    }

    @Test func chainsStaticsAndPrecision() {
        #expect(memberSet(Self.types + "class T { void f(Book b) { b.author.‸ } }", "java") == ["name", "books"])
        #expect(memberSet(Self.types + "class T { void f(Book b) { b.writer().‸ } }", "java") == ["name", "books"])
        #expect(memberSet(Self.types + "class T { void f() { Item.‸ } }", "java") == ["created", "of"])
        #expect(memberSet(Self.types + "class T { void f() { Item.of(\"x\").‸ } }", "java")?.contains("sku") == true)
        #expect(members(Self.types + "class T { void f(String s) { s.‸ } }", "java") == nil)
        #expect(members(Self.types + "class T { void f(java.util.List<Book> xs) { xs.‸ } }", "java") == nil)
        #expect(members(Self.types + "class T { void f(Author a) { a.books.‸ } }", "java") == nil)
        #expect(members(Self.types + "class T { void f(Book[] bs) { bs.‸ } }", "java") == nil)
        // `stock` is private to Item.
        #expect(memberSet(Self.types + "class T { void f(Item i) { i.‸ } }", "java")?.contains("stock") == false)
        // `this` in an anonymous class is not the enclosing class.
        #expect(members(Self.types + "class T { int a; void f() { Runnable r = new Runnable() { public void run() { this.‸ } }; } }",
                        "java") == nil)
        #expect(memberSet(Self.types + "class T { int a; void f() { Runnable r = () -> { this.‸ }; } }", "java") == ["a", "f"])
    }
}

// MARK: - C#

@Suite("BraceInference CSharp")
@MainActor
struct BraceInferenceCSharpTests {
    static let types = """
    namespace Game
    {
        public interface IMovable { void Move(int dx); }
        public class Entity
        {
            public int Id;
            int hidden;
            protected string tag;
            public static int Count;
            public const int Max = 10;
        }
        public class Player : Entity, IMovable
        {
            public string Name { get; set; }
            public Vector Position { get; set; }
            public void Move(int dx) {}
            public Vector Aim() { return Position; }
        }
        public struct Vector { public float X; public float Y; }
    """

    @Test func receiverForms() throws {
        let player: Set<String> = ["Name", "Position", "Move", "Aim", "Id"]
        #expect(memberSet(Self.types + "    class T { void F() { Player p = new Player(); p.‸ } }\n}", "csharp") == player)
        #expect(memberSet(Self.types + "    class T { void F() { var p = new Player(); p.‸ } }\n}", "csharp") == player)
        #expect(memberSet(Self.types + "    class T { void F(Player p) { p.Position.‸ } }\n}", "csharp") == ["X", "Y"])
        #expect(memberSet(Self.types + "    class T { void F(Player p) { p.Aim().‸ } }\n}", "csharp") == ["X", "Y"])
        #expect(memberSet(Self.types + "    class T { void F() { Entity.‸ } }\n}", "csharp") == ["Count", "Max"])
        let inPlayer = memberSet(Self.types.replacingOccurrences(of: "public void Move(int dx) {}",
                                                                 with: "public void Move(int dx) { this.‸ }") + "}",
                                 "csharp")
        // `protected` from the base is visible inside the subclass; `hidden` (private by default) is not.
        #expect(inPlayer == player.union(["tag"]))
        #expect(BraceProbe(Self.types + "    class T { void F(Player p) { p.‸ } }\n}", "csharp").detail("Aim")
            == "() : Vector")
    }

    @Test func precision() {
        #expect(members(Self.types + "    class T { void F(string s) { s.‸ } }\n}", "csharp") == nil)
        #expect(members(Self.types + "    class T { void F(Vector? v) { v.‸ } }\n}", "csharp") == nil)   // Nullable<T>
        #expect(memberSet(Self.types + "    class T { void F(Player? p) { p.‸ } }\n}", "csharp")?.contains("Aim") == true)
        #expect(members(Self.types + "    class T { void F(List<Player> ps) { ps.‸ } }\n}", "csharp") == nil)
        #expect(memberSet(Self.types + "    class T { void F(Entity e) { e.‸ } }\n}", "csharp") == ["Id"])
    }
}

// MARK: - C

@Suite("BraceInference C")
@MainActor
struct BraceInferenceCTests {
    static let types = """
    struct point { int x; int y; };
    struct rect { struct point origin; int width; struct point *corner; };
    typedef struct rect Rect;
    typedef struct { float r; float g; } Color;
    typedef struct node { int value; struct node *next; } Node;

    """

    @Test func receiverFormsAndOperators() {
        #expect(memberSet(Self.types + "void f(void) {\n    struct point p;\n    p.‸\n}", "c") == ["x", "y"])
        #expect(memberSet(Self.types + "void f(struct point *pp) {\n    pp->‸\n}", "c") == ["x", "y"])
        #expect(memberSet(Self.types + "void f(Rect *r) {\n    r->‸\n}", "c") == ["origin", "width", "corner"])
        #expect(memberSet(Self.types + "void f(Color c) {\n    c.‸\n}", "c") == ["r", "g"])
        #expect(memberSet(Self.types + "void f(Node *n) {\n    n->next->‸\n}", "c") == ["value", "next"])
        #expect(memberSet(Self.types + "void f(Rect r) {\n    r.origin.‸\n}", "c") == ["x", "y"])
        #expect(memberSet(Self.types + "void f(Rect r) {\n    r.corner->‸\n}", "c") == ["x", "y"])
        #expect(memberSet(Self.types + "void f(struct point *pp) {\n    (*pp).‸\n}", "c") == ["x", "y"])
        #expect(memberSet(Self.types + "void f(void) {\n    struct point a, *b;\n    b->‸\n}", "c") == ["x", "y"])
    }

    @Test func precision() {
        // Wrong operator for the indirection.
        #expect(members(Self.types + "void f(struct point *pp) {\n    pp.‸\n}", "c") == nil)
        #expect(members(Self.types + "void f(struct point p) {\n    p->‸\n}", "c") == nil)
        #expect(members(Self.types + "void f(struct point **pp) {\n    pp->‸\n}", "c") == nil)
        // A bare tag is no type name in C; a library type is unknown.
        #expect(members(Self.types + "void f(point p) {\n    p.‸\n}", "c") == nil)
        #expect(members(Self.types + "void f(FILE *fp) {\n    fp->‸\n}", "c") == nil)
        #expect(members(Self.types + "void f(void) {\n    struct point a, *b;\n    a->‸\n}", "c") == nil)
    }
}

// MARK: - C++

@Suite("BraceInference Cpp")
@MainActor
struct BraceInferenceCppTests {
    static let types = """
    #include <memory>
    namespace geo {
    struct Vec { double x; double y; };
    }
    class Base {
    public:
        int id;
        static int total;
        virtual void draw() const;
    protected:
        int flags;
    private:
        int secret;
    };
    class Widget : public Base {
    public:
        Widget(int w);
        int width() const;
        geo::Vec pos;
        Widget* parent;
        static Widget create();
    private:
        int cache;
    };
    int Widget::width() const { return cache; }

    """

    @Test func receiverForms() throws {
        let widget: Set<String> = ["width", "pos", "parent", "id", "draw"]
        #expect(memberSet(Self.types + "void f() {\n    Widget w(1);\n    w.‸\n}", "cpp") == widget)
        #expect(memberSet(Self.types + "void f(Widget* w) {\n    w->‸\n}", "cpp") == widget)
        #expect(memberSet(Self.types + "void f(const Widget& w) {\n    w.‸\n}", "cpp") == widget)
        #expect(memberSet(Self.types + "void f() {\n    auto w = Widget(1);\n    w.‸\n}", "cpp") == widget)
        #expect(memberSet(Self.types + "void f() {\n    auto w = new Widget(1);\n    w->‸\n}", "cpp") == widget)
        #expect(memberSet(Self.types + "void f() {\n    auto w = std::make_unique<Widget>(1);\n    w->‸\n}", "cpp") == widget)
        #expect(members(Self.types + "void f() {\n    auto w = std::make_unique<Widget>(1);\n    w.‸\n}", "cpp") == nil)
        #expect(memberSet(Self.types + "void f(Widget w) {\n    w.pos.‸\n}", "cpp") == ["x", "y"])
        #expect(memberSet(Self.types + "void f(Widget w) {\n    w.parent->pos.‸\n}", "cpp") == ["x", "y"])
        #expect(memberSet(Self.types + "void f() {\n    geo::Vec v;\n    v.‸\n}", "cpp") == ["x", "y"])
        #expect(memberSet(Self.types + "void f() {\n    Widget::‸\n}", "cpp") == ["create", "total"])
        #expect(BraceProbe(Self.types + "void f(Widget w) {\n    w.‸\n}", "cpp").detail("width") == "() const : int")
    }

    @Test func thisAndAccess() {
        // In an out-of-class definition `this->` sees private and protected members.
        let source = Self.types + "void Widget::draw() const {\n    this->‸\n}"
        #expect(memberSet(source, "cpp") == ["width", "pos", "parent", "cache", "id", "draw", "flags"])
        // Implicit members there too.
        #expect(memberSet(Self.types + "void Widget::draw() const {\n    parent->pos.‸\n}", "cpp") == ["x", "y"])
        // Outside: no private / protected.
        #expect(memberSet(Self.types + "void f(Base b) {\n    b.‸\n}", "cpp") == ["id", "draw"])
        // `this.` is wrong (a pointer).
        #expect(members(Self.types + "void Widget::draw() const {\n    this.‸\n}", "cpp") == nil)
    }

    @Test func precision() {
        #expect(members(Self.types + "void f(std::string s) {\n    s.‸\n}", "cpp") == nil)
        #expect(members(Self.types + "void f(std::vector<Widget> ws) {\n    ws.‸\n}", "cpp") == nil)
        #expect(members(Self.types + "void f() {\n    Vec v;\n    v.‸\n}", "cpp") == nil)   // not visible unqualified
        #expect(members(Self.types + "void f() {\n    auto w = make();\n    w.‸\n}", "cpp") == nil)
    }
}

// MARK: - Enumerations

@Suite("BraceInference enums")
@MainActor
struct BraceInferenceEnumTests {
    @Test func casesAreTypeLevel() {
        let swift = """
        enum Shape { case circle(radius: Double), square(side: Double)
            indirect case pair(Shape, Shape)
            var area: Double { 0 }
            static let unit = Shape.circle(radius: 1)
        }

        """
        #expect(memberSet(swift + "func f() { Shape.‸ }", "swift") == ["circle", "square", "pair", "unit"])
        #expect(memberSet(swift + "func f(s: Shape) { s.‸ }", "swift") == ["area"])
        #expect(memberSet(swift + "func f() { Shape.unit.‸ }", "swift") == ["area"])
        let java = """
        enum Color { RED("r"), GREEN("g") { void x() {} };
            private final String code;
            Color(String c) { code = c; }
            String code() { return code; }
            static Color parse(String s) { return null; }
        }

        """
        #expect(memberSet(java + "class T { void f() { Color.‸ } }", "java") == ["RED", "GREEN", "parse"])
        #expect(memberSet(java + "class T { void f() { Color.RED.‸ } }", "java") == ["code"])
        #expect(memberSet("enum Level { [Obsolete] Low = 1, High }\nclass T { void F() { Level.‸ } }", "csharp")
            == ["Low", "High"])
        #expect(memberSet("enum class Mode { Fast, Safe = 2 };\nvoid f() { Mode::‸ }", "cpp") == ["Fast", "Safe"])
        let rust = "enum Mode { Fast, Safe(u8), #[allow(x)] Custom { level: u8 } }\n"
            + "impl Mode { fn is_fast(&self) -> bool { true } fn all() -> Vec<Mode> { vec![] } }\n"
        #expect(memberSet(rust + "fn f() { Mode::‸ }", "rust") == ["Fast", "Safe", "Custom", "all"])
        #expect(memberSet(rust + "fn f(m: Mode) { m.‸ }", "rust") == ["is_fast"])
        #expect(memberSet(rust + "fn f() { Mode::Fast.‸ }", "rust") == ["is_fast"])
    }
}

// MARK: - Cross-cutting

@Suite("BraceInference model")
@MainActor
struct BraceInferenceModelTests {
    @Test func inheritanceCyclesTerminate() {
        let source = "class A: B { var a = 0 }\nclass B: A { var b = 0 }\nfunc f(x: A) { x.‸ }"
        #expect(memberSet(source, "swift") == ["a", "b"])
        let java = "class A extends B { int a; }\nclass B extends A { int b; }\nclass T { void f(A x) { x.‸ } }"
        #expect(memberSet(java, "java") == ["a", "b"])
    }

    @Test func ambiguousTypesAreUnknown() {
        // Two same-named types in different nested scopes: the visible one wins.
        let nested = """
        struct Outer { struct Item { var a = 0 }; func f(i: Item) { i.‸ } }
        struct Item { var b = 0 }
        """
        #expect(memberSet(nested, "swift") == ["a"])
        // Two top-level `struct point` bodies: unknown rather than a guess.
        #expect(members("struct point { int x; };\nstruct point { int y; };\nvoid f(struct point p) { p.‸ }", "c") == nil)
    }

    @Test func commentsAndStringsAreNotDeclarations() {
        let source = """
        struct Account {
            var owner: String  // var fake: Int
            var note = "var other: Int"
        }
        func f(a: Account) { a.‸ }
        """
        #expect(memberSet(source, "swift") == ["owner", "note"])
    }

    @Test func reusesTheAnswerAfterTheSameDotAndReleases() throws {
        let probe = BraceProbe("struct P { var x = 0 }\nfunc f(p: P) {\n    p.‸\n}", "swift")
        #expect(probe.names == ["x"])
        #expect(probe.names == ["x"])
        #expect(probe.service.statistics.reused == 1)
        #expect(!probe.service.isReleased)
        #expect(probe.service.retainedBytes > 0)
        probe.service.release()
        #expect(probe.service.isReleased)
        #expect(probe.service.retainedBytes == 0)
    }

    @Test func budgetExhaustionIsUnknown() {
        let probe = BraceProbe("struct P { var x = 0; var y = 0 }\nfunc f(p: P) {\n    p.x\n    p.‸\n}", "swift")
        probe.service.budgetSteps = 3
        #expect(probe.names == nil)
        #expect(probe.service.statistics.aborted == 1)
        // No partial result survives the aborted request.
        probe.service.budgetSteps = InferenceBudget.defaultSteps
        let other = probe.text.range(of: "p.x").location + 1
        #expect(probe.service.memberCandidates(analysis: probe.analysis, text: probe.text, dot: other)
            .map { Set($0.map(\.name)) } == ["x", "y"])
    }

    @Test func summariesAreShortened() {
        let fitted = BraceSummary.fit(head: "VeryLongReturnTypeName<WithGenerics> ",
                                      params: ["int firstParameter", "String secondParameter", "double third"],
                                      tail: " const")
        #expect(fitted.utf16.count <= InferredMemberList.detailLimit)
        #expect(fitted.contains("(int firstParameter, …)") || fitted.contains("(…)"))
        #expect(BraceSummary.fit(head: "", params: ["a: Int"], tail: " -> Bool") == "(a: Int) -> Bool")
    }
}

// MARK: - Completion wiring

@Suite("BraceInference completion", .serialized)
@MainActor
struct BraceInferenceCompletionTests {
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
            let r = (text as NSString).range(of: "⟨⟩")
            if r.location != NSNotFound {
                textView.textStorage?.replaceCharacters(in: r, with: "")
                textView.setSelectedRange(NSRange(location: r.location, length: 0))
            } else {
                textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            }
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

    @Test func dotPopupShowsTypedMembersOnly() throws {
        let h = Harness("struct Account { var owner: String; var balance: Double; static var bank = 0 }\n"
                        + "func f(account: Account, other: Int) {\n    other.description\n    ⟨⟩\n}", language: "swift")
        defer { h.close() }
        h.type("account.")
        #expect(Set(h.names) == ["owner", "balance"])
        #expect(h.controller.currentCandidatesForTesting.allSatisfy { $0.source == .inferredType })
        let cell = try #require(h.controller.cellForTesting(row: 0))
        #expect(cell.content?.detail == "String" || cell.content?.detail == "Double")
    }

    @Test func arrowAndPathOperatorsTrigger() {
        let c = Harness("struct point { int x; int y; };\nvoid f(struct point *p) {\n    ⟨⟩\n}", language: "c")
        defer { c.close() }
        c.type("p->")
        #expect(Set(c.names) == ["x", "y"])
        let rust = Harness("struct Cfg { n: u8 }\nimpl Cfg { fn new() -> Self { Cfg { n: 0 } } fn get(&self) -> u8 { 0 } }\n"
                           + "fn main() {\n    ⟨⟩\n}", language: "rust")
        defer { rust.close() }
        rust.type("Cfg::")
        #expect(rust.names == ["new"])
    }

    @Test func unknownArrowKeepsOrdinaryCompletion() {
        let h = Harness("void f(FILE *fp, int fpos) {\n    ⟨⟩\n}", language: "c")
        defer { h.close() }
        h.type("fp->")
        #expect(h.names.isEmpty)
        h.type("fp")
        #expect(h.names.contains("fpos"))   // scope names, as before T17.11d
    }

    @Test func thisListsInferredMembersOnly() {
        let h = Harness("class Box { static int made; int size; void grow() {\n    ⟨⟩\n} }", language: "java")
        defer { h.close() }
        h.type("this.")
        #expect(Set(h.names) == ["size", "grow"])   // no static `made` from the class body
    }

    @Test func unknownReceiverKeepsUsageEvidence() {
        let h = Harness("func f(s: String) {\n    s.lowercased()\n    ⟨⟩\n}", language: "swift")
        defer { h.close() }
        h.type("s.")
        #expect(h.names == ["lowercased"])
        #expect(h.controller.currentCandidatesForTesting.first?.source == .receiverUsage)
    }

    @Test func turningModulesOffReleasesInference() {
        let h = Harness("struct P { var x = 0 }\nfunc f(p: P) {\n    ⟨⟩\n}", language: "swift")
        defer { h.close() }
        h.type("p.")
        #expect(h.names == ["x"])
        #expect(!h.controller.isInferenceStateReleased)
        let service = h.controller.typeInferenceForTesting
        #expect(service?.braceViewForTesting != nil)
        // The engine's query index is shared, not rebuilt by inference.
        #expect(service?.holdsOwnQueryIndex == false)
        h.settings.setEnabled(false, for: .typeInference)
        #expect(h.controller.isInferenceStateReleased)
        #expect(service?.isReleased == true)
        h.type("\np.")
        #expect(h.controller.isInferenceStateReleased)   // nothing new while off
        h.settings.setEnabled(true, for: .typeInference)
        h.type("\np.")
        #expect(!h.controller.isInferenceStateReleased)
        h.settings.setEnabled(false, for: .completion)
        #expect(h.controller.isRuntimeStateReleased)
    }
}

// MARK: - Robustness

@Suite("BraceInference robustness")
@MainActor
struct BraceInferenceRobustnessTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let corpus: [(String, String)] = [
        ("Tests/Fixtures/M17/highlight/swift.swift", "swift"), ("Tests/Fixtures/M17/highlight/go.go", "go"),
        ("Tests/Fixtures/M17/highlight/rust.rs", "rust"), ("Tests/Fixtures/M17/highlight/java.java", "java"),
        ("Tests/Fixtures/M17/highlight/csharp.cs", "csharp"), ("Tests/Fixtures/M17/highlight/c.c", "c"),
        ("Tests/Fixtures/M17/highlight/cpp.cpp", "cpp"),
        // Real Swift code of this repository.
        ("Sources/KaruCore/Inference/BraceModel.swift", "swift"),
        ("Sources/KaruCore/Completion/CandidateEngine.swift", "swift"),
    ]

    /// Every access operator of a file, answered on the unmodified text:
    /// no crash, and every listed member is a name the file declares (or an
    /// identifier written in it — enum cases, Go embedded fields).
    @Test func everyAccessOperatorOfTheCorpus() throws {
        for (path, language) in Self.corpus {
            let source = try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
            let probe = BraceProbe(source + "\n‸", language)
            let text = probe.text
            let scan = probe.analysis.ensureDeclarations().scan
            let declared = Set(scan.declarations.map(\.name))
            var answered = 0
            var positions = 0
            let brace = BraceLanguage(identifier: language)!
            for i in 0..<max(0, text.length - 1) {
                guard BraceEvaluator.accessOperator(at: i, in: text, language: brace) != nil else { continue }
                if text.character(at: i) == 46, i > 0, text.character(at: i - 1) == 63 { continue }   // `?.`: at the `.`
                positions += 1
                guard let list = probe.service.memberCandidates(analysis: probe.analysis, text: text, dot: i) else {
                    continue
                }
                answered += 1
                for c in list where !declared.contains(c.name) {
                    #expect(text.range(of: c.name).location != NSNotFound, "\(path): \(c.name) at \(i)")
                }
            }
            #expect(positions > 0, "\(path)")
            print("BraceInference robustness \(path): \(answered)/\(positions) access operators typed")
        }
    }

    /// Truncated and randomly damaged documents never crash or hang.
    @Test func damagedDocuments() throws {
        var rng = SystemRandomNumberGenerator()
        for (path, language) in Self.corpus.prefix(7) {
            let source = try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8) as NSString
            for round in 0..<40 {
                var text = source.substring(to: Int.random(in: 1...source.length, using: &rng))
                if round % 2 == 1 {
                    let ns = text as NSString
                    let at = Int.random(in: 0..<ns.length, using: &rng)
                    text = ns.replacingCharacters(in: NSRange(location: at, length: min(8, ns.length - at)), with: "")
                }
                // Request at the last access operator.
                let probe = BraceProbe(text + "‸", language)
                let ns = probe.text
                let brace = BraceLanguage(identifier: language)!
                var i = ns.length - 1
                while i >= 0, BraceEvaluator.accessOperator(at: i, in: ns, language: brace) == nil { i -= 1 }
                if i >= 0 { _ = probe.service.memberCandidates(analysis: probe.analysis, text: ns, dot: i) }
            }
        }
    }
}

@Suite("BraceInference C typedefs")
@MainActor
struct BraceInferenceCTypedefTests {
    @Test func sameNamedTypedefAfterTheBody() {
        let source = """
        typedef struct ring_buffer {
            unsigned char data[16];
            size_t head;
        } ring_buffer;
        typedef struct node node;
        struct node { int value; node *next; };
        static size_t rb_free(const ring_buffer *rb) {
            return rb->‸
        }
        """
        #expect(memberSet(source, "c") == ["data", "head"])
        let forward = source.replacingOccurrences(of: "return rb->‸", with: "node *n = 0; n->next->‸")
        #expect(memberSet(forward, "c") == ["value", "next"])
    }
}
