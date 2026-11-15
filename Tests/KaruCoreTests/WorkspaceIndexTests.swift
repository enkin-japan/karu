import AppKit
import Foundation
import SQLite3
import Testing
@testable import KaruCore

// M17 T17.12 — project folders and the cross-file index. Every test works in
// its own temporary directory with an injected Application Support root,
// isolated defaults and its own notification center; nothing reads the
// user's real folders.

/// A temporary workspace: a project folder, an index root, isolated settings.
final class IndexFixture {
    let base: URL
    let folder: URL
    let root: URL
    let suite: String
    let defaults: UserDefaults
    let center = NotificationCenter()
    let modules: ModuleSettings
    let store: ProjectFolderStore

    init() {
        base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("KaruIndexTests-\(UUID().uuidString)", isDirectory: true)
        folder = base.appendingPathComponent("project", isDirectory: true)
        root = base.appendingPathComponent("support", isDirectory: true)
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        suite = "KaruIndexTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        modules = ModuleSettings(defaults: defaults, center: center)
        store = ProjectFolderStore(defaults: defaults)
    }

    deinit {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: base)
    }

    func makeIndex(scope: IndexScope = IndexScope(), latency: TimeInterval = 0.1) -> WorkspaceIndex {
        WorkspaceIndex(root: root, scope: scope, store: store, modules: modules, center: center, latency: latency)
    }

    @discardableResult
    func write(_ relative: String, _ text: String) -> URL {
        let url = folder.appendingPathComponent(relative)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(text.utf8).write(to: url)
        return url
    }

    var path: String { ProjectFolderStore.standardize(folder.path) }

    /// Relative paths of every indexed file.
    func indexedFiles(_ index: WorkspaceIndex) -> [String] {
        let url = index.databaseURL(forFolder: path)
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT path FROM files ORDER BY path", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        var out: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { out.append(String(cString: sqlite3_column_text(statement, 0))) }
        return out
    }
}

/// Polls `condition` every 5 ms (suspending, never blocking a pool thread);
/// returns the elapsed seconds, or nil on timeout.
private func elapsedUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> TimeInterval? {
    let start = Date()
    while Date().timeIntervalSince(start) < timeout {
        if condition() { return Date().timeIntervalSince(start) }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return nil
}

/// Waits until the index has no queued or pending work.
func settle(_ index: WorkspaceIndex, timeout: TimeInterval = 60) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if index.isIdle {
            // A step may be running; once it is done, idle means idle.
            index.queue.sync {}
            if index.isIdle { return true }
        }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return false
}

private func pause(_ seconds: Double) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
}

private func names(_ symbols: [WorkspaceSymbol]) -> Set<String> { Set(symbols.map(\.name)) }

@Suite("Workspace index scope rules")
struct WorkspaceIndexScopeTests {
    @Test func languagesAreTheWalkerLanguages() {
        for (file, language) in [("a.py", "python"), ("a.pyi", "python"), ("a.js", "javascript"), ("a.jsx", "javascript"),
                                 ("a.ts", "typescript"), ("a.d.ts", "typescript"), ("a.tsx", "typescriptreact"),
                                 ("a.swift", "swift"), ("a.go", "go"), ("a.rs", "rust"), ("a.java", "java"),
                                 ("a.cs", "csharp"), ("a.c", "c"), ("a.h", "c"), ("a.cpp", "cpp"), ("A.PY", "python")] {
            #expect(IndexScope.languageIdentifier(forFileName: file) == language, "\(file)")
        }
        for file in ["a.md", "a.json", "a.html", "a.css", "a.sh", "a.sql", "a.yaml", "a.toml", "a.xml", "Makefile", ".py", "a.txt"] {
            #expect(IndexScope.languageIdentifier(forFileName: file) == nil, "\(file)")
        }
    }

    @Test func gitIgnorePatterns() {
        let rules = GitIgnoreRule.parse("""
            # comment

            *.gen.py
            /top_only.py
            logs/
            docs/*.py
            !keep.gen.py
            **/deep/x.py
            a/**/b.py
            tmp?.js
            [Cc]ache_*.ts
            \\#hash.py
            """, base: "")
        func ignored(_ path: String, dir: Bool = false) -> Bool {
            GitIgnoreRule.isIgnored(path, isDirectory: dir, rules: rules)
        }
        #expect(ignored("x.gen.py"))
        #expect(ignored("sub/dir/y.gen.py"))
        #expect(!ignored("keep.gen.py"))               // negation
        #expect(!ignored("sub/keep.gen.py"))
        #expect(ignored("top_only.py"))                 // anchored
        #expect(!ignored("sub/top_only.py"))
        #expect(ignored("logs", dir: true))             // directory-only
        #expect(ignored("sub/logs", dir: true))
        #expect(!ignored("logs"))                       // a file named logs
        #expect(ignored("docs/a.py"))                   // inner slash anchors
        #expect(!ignored("docs/sub/a.py"))              // `*` never crosses `/`
        #expect(!ignored("other/docs/a.py"))
        #expect(ignored("deep/x.py") && ignored("m/n/deep/x.py"))
        #expect(ignored("a/b.py") && ignored("a/q/r/b.py"))
        #expect(ignored("tmp1.js") && !ignored("tmp12.js"))
        #expect(ignored("Cache_z.ts") && ignored("cache_z.ts") && !ignored("xache_z.ts"))
        #expect(ignored("#hash.py"))

        // Nested .gitignore: relative to its own directory.
        let nested = GitIgnoreRule.parse("/local.py\nonly_here.py\n", base: "pkg")
        #expect(GitIgnoreRule.isIgnored("pkg/local.py", isDirectory: false, rules: nested))
        #expect(!GitIgnoreRule.isIgnored("pkg/sub/local.py", isDirectory: false, rules: nested))
        #expect(GitIgnoreRule.isIgnored("pkg/sub/only_here.py", isDirectory: false, rules: nested))
        #expect(!GitIgnoreRule.isIgnored("only_here.py", isDirectory: false, rules: nested))
    }

    @Test func walkSkipsDirectoriesIgnoredFilesAndLargeFiles() async throws {
        let f = IndexFixture()
        f.write("main.py", "def main(): pass\n")
        for skipped in IndexScope.skippedDirectoryNames { f.write("\(skipped)/hidden.py", "def nope(): pass\n") }
        f.write("pkg/node_modules/dep/x.js", "function nope() {}\n")
        f.write("src/app.ts", "export function app() {}\n")
        f.write("src/app.gen.ts", "export function gen() {}\n")
        f.write("src/vendor/v.js", "function v() {}\n")
        f.write("src/keep/k.go", "package k\nfunc K() {}\n")
        f.write("src/sub/.gitignore", "local.py\n")
        f.write("src/sub/local.py", "x = 1\n")
        f.write("src/sub/other.py", "y = 1\n")
        f.write(".gitignore", "*.gen.ts\nsrc/vendor/\n")
        f.write("notes.md", "# notes\n")
        f.write("big.py", String(repeating: "a = 1\n", count: 50))   // 300 bytes
        f.write("small.py", "b = 2\n")
        let index = f.makeIndex(scope: IndexScope(maxFileBytes: 200))
        index.start()
        #expect(index.addFolder(f.folder))
        #expect(await settle(index))
        #expect(f.indexedFiles(index) == ["main.py", "small.py", "src/app.ts", "src/keep/k.go", "src/sub/other.py"])
        #expect(index.statuses().first?.state == .upToDate)
        #expect(index.statuses().first?.indexedFiles == 5)
    }

    @Test func fileCapStopsAndFlags() async {
        let f = IndexFixture()
        for i in 0..<7 { f.write(String(format: "m%02d.py", i), "def f\(i)(): pass\n") }
        let index = f.makeIndex(scope: IndexScope(maxFiles: 4))
        index.start()
        index.addFolder(f.folder)
        #expect(await settle(index))
        #expect(f.indexedFiles(index) == ["m00.py", "m01.py", "m02.py", "m03.py"])
        let status = index.statuses().first
        #expect(status?.state == .overLimit)
        #expect(status?.indexedFiles == 4)
        // A new file past the cap is refused incrementally too.
        f.write("zz.py", "def late(): pass\n")
        await pause(1.5)
        #expect(await settle(index))
        #expect(!f.indexedFiles(index).contains("zz.py"))
        #expect(index.statuses().first?.state == .overLimit)
    }
}

@Suite("Workspace index storage")
struct WorkspaceIndexStorageTests {
    @Test func schemaAndMigrationByRebuild() throws {
        let f = IndexFixture()
        let url = IndexDatabase.fileURL(forFolder: f.path, root: f.root)
        #expect(url.path.hasPrefix(f.root.path + "/Index/"))
        #expect(url.lastPathComponent.count == "0123456789abcdef.sqlite".count)
        #expect(IndexDatabase.fileURL(forFolder: f.path, root: f.root) == url)          // stable
        #expect(IndexDatabase.fileURL(forFolder: f.path + "x", root: f.root) != url)

        var database = try IndexDatabase(url: url, folderPath: f.path)
        #expect(!database.wasRebuilt)
        #expect(try database.storedSchemaVersion() == Int64(IndexDatabase.schemaVersion))
        #expect(try database.metaValue("folder") == f.path)
        #expect(try database.metaValue("schema") == String(IndexDatabase.schemaVersion))
        let symbol = IndexedSymbol(name: "Thing", kind: .class, container: nil, location: 6, line: 1, signature: nil)
        try database.replaceFile(path: "a.py", language: "python", size: 10, mtime: 5, symbols: [symbol])
        #expect(try database.symbolCount() == 1)
        database.close()

        // Same version and folder: kept.
        database = try IndexDatabase(url: url, folderPath: f.path)
        #expect(!database.wasRebuilt)
        #expect(try database.fileCount() == 1)
        try database.exec("PRAGMA user_version=99")
        database.close()
        // Other version: rebuilt empty.
        database = try IndexDatabase(url: url, folderPath: f.path)
        #expect(database.wasRebuilt)
        #expect(try database.fileCount() == 0)
        #expect(try database.storedSchemaVersion() == Int64(IndexDatabase.schemaVersion))
        try database.replaceFile(path: "a.py", language: "python", size: 10, mtime: 5, symbols: [symbol])
        database.close()
        // Other folder (hash collision): rebuilt.
        database = try IndexDatabase(url: url, folderPath: "/elsewhere")
        #expect(database.wasRebuilt)
        #expect(try database.fileCount() == 0)
        database.close()
        // Garbage file: rebuilt.
        IndexDatabase.remove(at: url)
        try Data(repeating: 0x42, count: 8192).write(to: url)
        database = try IndexDatabase(url: url, folderPath: f.path)
        #expect(database.wasRebuilt)
        #expect(try database.fileCount() == 0)
        // WAL journal, capped cache.
        var db: OpaquePointer?
        sqlite3_open(url.path, &db)
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "PRAGMA journal_mode", -1, &statement, nil)
        sqlite3_step(statement)
        #expect(String(cString: sqlite3_column_text(statement, 0)) == "wal")
        sqlite3_finalize(statement)
        sqlite3_close(db)
        #expect(IndexDatabase.cacheKiB <= 2048)
        database.close()
    }

    /// The indexed symbols of each sample equal the projection of
    /// `DeclarationScan` over the same text.
    @Test func indexedSymbolsEqualDeclarationScan() async throws {
        let f = IndexFixture()
        let samples: [String: String] = [
            "pkg/models.py": """
                import os
                from typing import List
                VERSION = "1"
                class User(Base):
                    role: str = "x"
                    def __init__(self, name, age=3):
                        self.name = name
                        local = 1
                    def greet(self, *args, **kw):
                        return self.name
                def make_user(name):
                    return User(name)
                a, b = 1, 2
                """,
            "web/app.js": """
                export function render(items, options) { const inner = 1; return inner }
                export class View { constructor(el) { this.el = el } update(state) { let t = state } }
                const helper = (x, y) => x + y
                var legacy = 1
                """,
            "web/types.ts": """
                export interface Shape { area(): number }
                export class Circle implements Shape { radius = 1; area(): number { return 3 } }
                export type Id = string
                export function makeCircle(r: number, label?: string): Circle { return new Circle() }
                namespace Geometry { export const unit = 1 }
                export enum Color { Red, Green }
                """,
            "Sources/Model.swift": """
                import Foundation
                struct Point { var x: Int; var y: Int; func moved(dx: Int, dy: Int) -> Point { let p = self; return p } }
                final class Store { static let shared = Store(); func load(path: String) {} }
                func distance(_ a: Point, _ b: Point) -> Int { 0 }
                let origin = Point(x: 0, y: 0)
                enum Mode { case on, off }
                protocol Named { var name: String { get } }
                extension Point { func scaled(by k: Int) -> Point { self } }
                """,
            "cmd/main.go": """
                package main
                import "fmt"
                type Server struct { Addr string }
                func (s *Server) Start(port int) error { x := 1; return nil }
                func NewServer(addr string) *Server { return nil }
                var Default = NewServer("")
                const Version = "1"
                """,
            "src/lib.rs": """
                pub struct Config { pub name: String }
                impl Config { pub fn new(name: String) -> Self { let c = 1; Config { name } } }
                pub fn run(cfg: &Config) {}
                pub enum Kind { A, B }
                pub trait Show { fn show(&self); }
                """,
            "src/Main.java": """
                package demo;
                public class Main { private int count; public static void main(String[] args) { int k = 0; } void tick(int n) {} }
                interface Listener { void on(); }
                """,
            "src/util.c": """
                #include <stdio.h>
                struct point { int x; int y; };
                static int counter = 0;
                int add(int a, int b) { int s = a + b; return s; }
                """,
            "src/shape.cpp": """
                namespace geo { class Shape { public: virtual double area() const; int sides; }; }
                double total(double a, double b) { return a + b; }
                """,
            "src/Program.cs": """
                namespace App { public class Program { public int Count { get; set; } public static void Main(string[] args) { var x = 1; } } }
                """,
        ]
        for (path, text) in samples { f.write(path, text) }
        let index = f.makeIndex()
        index.start()
        index.addFolder(f.folder)
        #expect(await settle(index))
        for (path, text) in samples.sorted(by: { $0.key < $1.key }) {
            let language = try #require(IndexScope.languageIdentifier(forFileName: path))
            let scan = DeclarationScan.scan(text: text, languageIdentifier: language)
            let expected = IndexedSymbol.extract(from: scan, text: text as NSString)
            let stored = index.symbols(inFile: f.folder.appendingPathComponent(path).path)
            #expect(!expected.isEmpty, "\(path)")
            #expect(stored.map(\.name) == expected.map(\.name), "\(path)")
            #expect(stored.map(\.kind) == expected.map(\.kind), "\(path)")
            #expect(stored.map(\.location) == expected.map(\.location), "\(path)")
            #expect(stored.map(\.container) == expected.map(\.container), "\(path)")
            // Signatures: the summaries `IndexSignatures` adds (T17.14).
            let enriched = WorkspaceIndex.symbols(of: Data(text.utf8), language: language)
            #expect(stored.map(\.signature) == enriched.map(\.signature), "\(path)")
            #expect(stored.map(\.line) == expected.map(\.line), "\(path)")
            #expect(stored.allSatisfy { $0.languageIdentifier == language && $0.relativePath == path })
            // Every stored symbol is a declaration of the scan at that location.
            let declarations = Set(scan.declarations.map { "\($0.name)@\($0.location)" })
            #expect(stored.allSatisfy { declarations.contains("\($0.name)@\($0.location)") }, "\(path)")
            // Ranges point at the name in the text.
            let ns = text as NSString
            #expect(stored.allSatisfy { ns.substring(with: $0.range) == $0.name }, "\(path)")
        }
        // Spot checks of the projection rules.
        let py = index.symbols(inFile: f.folder.appendingPathComponent("pkg/models.py").path)
        let byName = Dictionary(py.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        #expect(byName["User"]?.kind == .class && byName["User"]?.container == nil)
        #expect(byName["greet"]?.container == "User" && byName["greet"]?.signature == "(*args, **kw)")
        #expect(byName["__init__"]?.signature == "(name, age = ...)")
        #expect(byName["User"]?.signature == "(name, age = ...)")
        #expect(byName["make_user"]?.signature == "(name) -> User" && byName["make_user"]?.line == 11)
        #expect(byName["role"]?.container == "User")
        #expect(byName["name"]?.container == "User" && byName["name"]?.kind == .property)   // self.name
        #expect(byName["local"] == nil && byName["os"] == nil && byName["age"] == nil)
        #expect(byName["a"] != nil && byName["b"] != nil && byName["VERSION"] != nil)
        let ts = names(index.symbols(inFile: f.folder.appendingPathComponent("web/types.ts").path))
        #expect(ts.isSuperset(of: ["Shape", "Circle", "Id", "makeCircle", "Geometry", "unit", "Color", "radius"]))
        let go = index.symbols(inFile: f.folder.appendingPathComponent("cmd/main.go").path)
        #expect(names(go).isSuperset(of: ["Server", "Start", "NewServer", "Default", "Version", "Addr"]), "\(go.map(\.name))")
        #expect(!names(go).contains("x"))
        #expect(go.first { $0.name == "Start" }?.signature == "(port int) error")
        #expect(go.first { $0.name == "Start" }?.container == "Server")   // T17.14: filed under the receiver
        // Without summaries (`extract` alone) the parameter names stay.
        let plain = IndexedSymbol.extract(from: DeclarationScan.scan(text: samples["cmd/main.go"]!, languageIdentifier: "go"),
                                          text: samples["cmd/main.go"]! as NSString)
        #expect(plain.first { $0.name == "Start" }?.signature == "(s, port)")
    }
}

@Suite("Workspace index lifecycle", .serialized)
struct WorkspaceIndexLifecycleTests {
    @Test func incrementalUpdatesWithinOneSecond() async throws {
        let f = IndexFixture()
        f.write("a.py", "def alpha(): pass\n")
        f.write("b.py", "def beta(): pass\n")
        let index = f.makeIndex(latency: 0.3)
        index.start()
        index.addFolder(f.folder)
        #expect(await settle(index))
        #expect(index.symbols(named: "alpha", inFolder: f.path).count == 1)
        var latencies: [TimeInterval] = []
        for trial in 0..<20 {
            let name = "fn_\(trial)_\(UUID().uuidString.prefix(6).lowercased())"
            f.write("a.py", "def \(name)(): pass\n")
            let elapsed = await elapsedUntil(timeout: 5) { index.symbols(named: name, inFolder: f.path).count == 1 }
            #expect(elapsed != nil, "trial \(trial) never reflected")
            latencies.append(elapsed ?? 5)
            #expect(index.symbols(named: "alpha", inFolder: f.path).isEmpty)
        }
        let sorted = latencies.sorted()
        let p50 = sorted[sorted.count / 2], maximum = sorted.last!
        print(String(format: "[T17.12] save → query latency over %d trials (FSEvents latency 0.3 s): p50 %.0f ms, max %.0f ms",
                     latencies.count, p50 * 1000, maximum * 1000))
        #expect(maximum <= 1.0)

        // Delete.
        try FileManager.default.removeItem(at: f.folder.appendingPathComponent("b.py"))
        #expect(await elapsedUntil { index.symbols(named: "beta", inFolder: f.path).isEmpty } != nil)
        // Rename a file.
        f.write("c.py", "def gamma(): pass\n")
        #expect(await elapsedUntil { index.symbols(named: "gamma", inFolder: f.path).count == 1 } != nil)
        try FileManager.default.moveItem(at: f.folder.appendingPathComponent("c.py"),
                                          to: f.folder.appendingPathComponent("d.py"))
        #expect(await elapsedUntil { index.symbols(named: "gamma", inFolder: f.path).map(\.relativePath) == ["d.py"] } != nil)
        // Rename a directory: rows move with it.
        f.write("pkg/inner/e.py", "def epsilon(): pass\n")
        #expect(await elapsedUntil { index.symbols(named: "epsilon", inFolder: f.path).count == 1 } != nil)
        try FileManager.default.moveItem(at: f.folder.appendingPathComponent("pkg"),
                                          to: f.folder.appendingPathComponent("lib"))
        #expect(await elapsedUntil { index.symbols(named: "epsilon", inFolder: f.path).map(\.relativePath) == ["lib/inner/e.py"] } != nil)
        // Delete a directory.
        try FileManager.default.removeItem(at: f.folder.appendingPathComponent("lib"))
        #expect(await elapsedUntil { index.symbols(named: "epsilon", inFolder: f.path).isEmpty } != nil)
        // A new ignored file is never indexed; editing .gitignore re-walks.
        f.write(".gitignore", "ignored_*.py\n")
        f.write("ignored_x.py", "def ignored_fn(): pass\n")
        f.write("visible.py", "def visible_fn(): pass\n")
        #expect(await elapsedUntil { index.symbols(named: "visible_fn", inFolder: f.path).count == 1 } != nil)
        #expect(await settle(index))
        #expect(index.symbols(named: "ignored_fn", inFolder: f.path).isEmpty)
        f.write(".gitignore", "\n")
        #expect(await elapsedUntil { index.symbols(named: "ignored_fn", inFolder: f.path).count == 1 } != nil)
    }

    @Test func restartPicksUpOfflineChangesAndSkipsUnchangedFiles() async {
        let f = IndexFixture()
        for i in 0..<10 { f.write("m\(i).py", "def keep_\(i)(): pass\n") }
        f.write("gone.py", "def gone(): pass\n")
        f.write("edit.py", "def before(): pass\n")
        var index: WorkspaceIndex? = f.makeIndex()
        index!.start()
        index!.addFolder(f.folder)
        #expect(await settle(index!))
        #expect(index!.writeCount == 12)
        // "Quit": turn the module off (closes databases, stops streams), drop the instance.
        f.modules.setEnabled(false, for: .crossFileIndex)
        #expect(await settle(index!))
        #expect(index!.isRunning(f.path) == (false, false))
        index = nil
        f.modules.setEnabled(true, for: .crossFileIndex)
        // Offline changes.
        try? FileManager.default.removeItem(at: f.folder.appendingPathComponent("gone.py"))
        await pause(0.02)
        f.write("edit.py", "def after(): pass\n")
        f.write("new.py", "def fresh(): pass\n")
        // "Relaunch".
        let relaunched = f.makeIndex()
        relaunched.start()
        #expect(await settle(relaunched))
        #expect(relaunched.symbols(named: "gone", inFolder: f.path).isEmpty)
        #expect(relaunched.symbols(named: "before", inFolder: f.path).isEmpty)
        #expect(relaunched.symbols(named: "after", inFolder: f.path).count == 1)
        #expect(relaunched.symbols(named: "fresh", inFolder: f.path).count == 1)
        #expect(relaunched.symbols(named: "keep_3", inFolder: f.path).count == 1)
        #expect(relaunched.writeCount == 2)        // only edit.py and new.py were read
        #expect(relaunched.statuses().first?.indexedFiles == 12)
    }

    @Test func removeFolderDeletesDatabaseAndClearRebuilds() async {
        let f = IndexFixture()
        f.write("a.py", "def alpha(): pass\n")
        let index = f.makeIndex()
        index.start()
        index.addFolder(f.folder)
        #expect(await settle(index))
        let url = index.databaseURL(forFolder: f.path)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(index.statuses().first.map { $0.diskBytes > 0 } == true)

        // Clear: a junk row disappears, real symbols come back.
        var db: OpaquePointer?
        sqlite3_open(url.path, &db)
        sqlite3_exec(db, "INSERT INTO files(path, language, size, mtime, indexed_at) VALUES('junk.py', 'python', 1, 1, 1)", nil, nil, nil)
        sqlite3_close(db)
        #expect(f.indexedFiles(index).contains("junk.py"))
        await withCheckedContinuation { continuation in index.clearIndex(f.path) { continuation.resume() } }
        #expect(await settle(index))
        #expect(f.indexedFiles(index) == ["a.py"])
        #expect(index.symbols(named: "alpha", inFolder: f.path).count == 1)

        await withCheckedContinuation { continuation in index.removeFolder(f.path) { continuation.resume() } }
        for companion in IndexDatabase.companionURLs(url) {
            #expect(!FileManager.default.fileExists(atPath: companion.path))
        }
        #expect(index.folderPaths.isEmpty && index.statuses().isEmpty)
        #expect(index.isRunning(f.path) == (false, false))
        #expect(index.projectFolder(containing: f.folder.appendingPathComponent("a.py").path) == nil)
        // Re-adding is refused for non-directories and duplicates.
        #expect(!index.addFolder(f.folder.appendingPathComponent("a.py")))
        #expect(index.addFolder(f.folder))
        #expect(!index.addFolder(f.folder))
    }

    @Test func toggleOffClosesAndOnCatchesUp() async {
        let f = IndexFixture()
        f.write("a.py", "def alpha(): pass\n")
        let index = f.makeIndex()
        index.start()
        index.addFolder(f.folder)
        #expect(await settle(index))
        #expect(index.isRunning(f.path) == (true, true))
        f.modules.setEnabled(false, for: .crossFileIndex)
        #expect(!index.isEnabled)
        #expect(await settle(index))
        #expect(index.isRunning(f.path) == (false, false))
        #expect(index.statuses().first?.state == .paused)
        #expect(index.projectFolder(containing: f.folder.appendingPathComponent("a.py").path) == nil)
        #expect(index.symbols(named: "alpha", inFolder: f.path).isEmpty)
        let url = index.databaseURL(forFolder: f.path)
        #expect(FileManager.default.fileExists(atPath: url.path))      // stays on disk
        // Changes while off are not watched…
        let writes = index.writeCount
        f.write("b.py", "def beta(): pass\n")
        await pause(0.6)
        #expect(index.writeCount == writes)
        // …and are caught up when turned back on.
        f.modules.setEnabled(true, for: .crossFileIndex)
        #expect(await settle(index))
        #expect(index.isRunning(f.path) == (true, true))
        #expect(index.symbols(named: "beta", inFolder: f.path).count == 1)
        #expect(index.writeCount == writes + 1)
        #expect(index.statuses().first?.state == .upToDate)
    }

    @Test func unreadableFolderIsFlagged() async {
        let f = IndexFixture()
        f.store.add(f.folder.appendingPathComponent("missing").path)
        let other = f.makeIndex()
        other.start()
        #expect(await settle(other))
        #expect(other.statuses().first(where: { $0.path.hasSuffix("missing") })?.state == .unreadable)
    }
}

@Suite("Workspace index queries")
struct WorkspaceIndexQueryTests {
    @Test func queriesAcrossTheFolder() async throws {
        let f = IndexFixture()
        f.write("app/user.py", "class UserAccount:\n    def display_name(self): pass\ndef user_count(): pass\n")
        f.write("app/util.py", "def userDisplayName(): pass\ndef unrelated(): pass\nUSER_LIMIT = 3\n")
        f.write("web/main.ts", "export function useRouter(path: string) {}\n")
        f.write("nested/inner.py", "def inner_only(): pass\n")
        let nested = f.folder.appendingPathComponent("nested")
        let index = f.makeIndex()
        index.start()
        index.addFolder(f.folder)
        index.addFolder(nested)
        #expect(await settle(index))

        // Longest match.
        #expect(index.projectFolder(containing: f.folder.appendingPathComponent("app/user.py").path) == f.path)
        #expect(index.projectFolder(containing: nested.appendingPathComponent("inner.py").path) == ProjectFolderStore.standardize(nested.path))
        #expect(index.projectFolder(containing: f.base.appendingPathComponent("elsewhere.py").path) == nil)
        #expect(index.projectFolder(containing: f.path + "-sibling/x.py") == nil)
        #expect(index.projectFolder(containing: f.path) == nil)

        // Prefix (case-insensitive), excluding a file.
        let user = f.folder.appendingPathComponent("app/user.py").path
        let all = names(index.names(withPrefix: "user", inFolder: f.path))
        #expect(all == ["UserAccount", "user_count", "userDisplayName", "USER_LIMIT", "useRouter"], "\(all)")
        let others = index.names(withPrefix: "user_", inFolder: f.path, excludingFile: user)
        #expect(names(others) == ["USER_LIMIT"], "\(others.map { "\($0.name) \($0.relativePath)" })")
        #expect(others.allSatisfy { $0.relativePath == "app/util.py" && $0.path.hasSuffix("app/util.py") })
        #expect(index.names(withPrefix: "u", inFolder: f.path, limit: 2).count == 2)

        // Exact.
        let exact = index.symbols(named: "display_name", inFolder: f.path)
        #expect(exact.count == 1 && exact[0].container == "UserAccount" && exact[0].kind == .method && exact[0].line == 2)
        #expect(index.symbols(named: "Display_name", inFolder: f.path).isEmpty)

        // Fuzzy workspace search: tiers best first.
        let hits = index.searchSymbols("udn", inFolder: f.path)
        #expect(hits.first?.symbol.name == "userDisplayName" && hits.first?.tier == .wordStart)
        #expect(hits.first?.ranges.isEmpty == false)
        let prefixHits = index.searchSymbols("user", inFolder: f.path)
        #expect(prefixHits.first?.tier == .exactPrefix)
        #expect(Set(prefixHits.prefix(2).map(\.symbol.name)) == ["user_count", "userDisplayName"])
        let allFolders = index.searchSymbols("inner", limit: 10)
        #expect(allFolders.contains { $0.symbol.name == "inner_only" })
        #expect(index.searchSymbols("zzzq", inFolder: f.path).isEmpty)
        #expect(index.searchSymbols("user", inFolder: f.path, limit: 1).count == 1)
    }
}

@Suite("Project folder settings", .serialized)
@MainActor
struct ProjectFolderSettingsTests {
    @Test func exportExcludesFoldersButKeepsModuleToggles() throws {
        let f = IndexFixture()
        f.store.add("/Users/someone/secret-project", bookmark: Data([1, 2, 3]))
        f.defaults.set(false, forKey: FeatureModule.crossFileIndex.defaultsKey)
        f.defaults.set(true, forKey: FeatureModule.typeInference.defaultsKey)
        let model = ShortcutSettings(defaults: f.defaults)
        let data = try SettingsArchive.export(defaults: f.defaults, commands: model.commands)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("secret-project"))
        #expect(!json.contains(ProjectFolderStore.foldersKey) && !json.contains(ProjectFolderStore.bookmarksKey))
        #expect(json.contains(FeatureModule.crossFileIndex.defaultsKey))
        #expect(json.contains(FeatureModule.typeInference.defaultsKey))
        #expect(!SettingsArchive.keys.contains(ProjectFolderStore.foldersKey))
        // Import never clears the local folder list.
        let doc = try SettingsArchive.decode(data, commands: model.commands)
        try SettingsArchive.apply(doc, defaults: f.defaults, shortcuts: model)
        #expect(f.store.folders == ["/Users/someone/secret-project"])
    }

    @Test func newStringsInAllThreeLanguages() {
        let keys: [L10nKey] = [.projectFoldersTitle, .projectFoldersHelp, .projectFoldersAdd, .projectFoldersRemove,
                               .projectFoldersClear, .projectFoldersEmpty, .projectFoldersColumnFolder,
                               .projectFoldersColumnFiles, .projectFoldersColumnDisk, .projectFoldersColumnStatus,
                               .projectFolderStateIndexing, .projectFolderStateUpToDate, .projectFolderStateOverLimit,
                               .projectFolderStateUnreadable, .projectFolderStatePaused, .projectFoldersLimitNotice]
        for key in keys {
            let values = AppLanguage.allCases.map { L10n.table(for: $0)[key] ?? "" }
            #expect(values.allSatisfy { !$0.isEmpty }, "\(key)")
            if key != .projectFoldersColumnDisk { #expect(Set(values).count == 3, "\(key) not translated") }
        }
        #expect(L10n.string(.projectFoldersLimitNotice, language: .en, 50_000).contains("50000"))
        #expect(L10n.string(.projectFoldersLimitNotice, language: .zhHans, 50_000).contains("50000"))
        #expect(L10n.string(.projectFoldersLimitNotice, language: .ja, 50_000).contains("50000"))
    }

    @Test func controllerAddsRemovesAndClears() async throws {
        let f = IndexFixture()
        f.write("a.py", "def alpha(): pass\n")
        let index = f.makeIndex()
        index.start()
        var chosen: URL? = f.folder
        let controller = ProjectFoldersPreferencesController(index: index, center: f.center) { reply in reply(chosen) }
        #expect(controller.window != nil)
        #expect(controller.rows.isEmpty && !controller.emptyLabel.isHidden)

        controller.addFolderClicked(nil)
        #expect(index.folderPaths == [f.path])
        #expect(controller.rows.count == 1)
        #expect(controller.rows[0].pathLabel.stringValue.contains("project"))
        #expect(await settle(index))
        controller.reload()
        #expect(controller.rows[0].filesLabel.stringValue == "1")
        // Reloads replace the rows' views instead of stacking them (T17.15c:
        // stale labels kept drawing under the new ones).
        controller.reload()
        let gridViews = Set(controller.grid.subviews.map(ObjectIdentifier.init))
        #expect(gridViews.contains(ObjectIdentifier(controller.rows[0].filesLabel)))
        #expect(controller.grid.subviews.filter { ($0 as? NSTextField)?.stringValue == "1" }.count == 1)
        #expect(controller.grid.subviews.count == 4 + 6)
        #expect(controller.rows[0].statusLabel.stringValue == L10n.t(.projectFolderStateUpToDate))
        #expect(controller.limitNotice.isHidden)
        // The window is never narrower than the help text wraps (T17.15c:
        // Chinese clipped it at the right edge).
        #expect((controller.window?.contentView?.frame.width ?? 0) >= 640)

        // Cancelled panel: nothing changes.
        chosen = nil
        controller.addFolderClicked(nil)
        #expect(index.folderPaths == [f.path])

        let url = index.databaseURL(forFolder: f.path)
        await controller.clearIndex(at: 0)
        #expect(await settle(index))
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(index.symbols(named: "alpha", inFolder: f.path).count == 1)

        await controller.removeFolder(at: 0)
        #expect(index.folderPaths.isEmpty)
        #expect(controller.rows.isEmpty && !controller.emptyLabel.isHidden)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        controller.close()
    }

    @Test func controllerShowsLimitNotice() async {
        let f = IndexFixture()
        for i in 0..<3 { f.write("m\(i).py", "x\(i) = 1\n") }
        let index = f.makeIndex(scope: IndexScope(maxFiles: 2))
        index.start()
        index.addFolder(f.folder)
        #expect(await settle(index))
        let controller = ProjectFoldersPreferencesController(index: index, center: f.center) { $0(nil) }
        #expect(controller.rows.first?.statusLabel.stringValue == L10n.t(.projectFolderStateOverLimit))
        #expect(!controller.limitNotice.isHidden)
        #expect(controller.limitNotice.stringValue.contains("2"))
        controller.close()
    }
}
