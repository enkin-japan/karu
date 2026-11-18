import AppKit
import Foundation
import Testing
@testable import KaruCore

// M17 T17.13 — import resolution (plan §9): lookup rules and order per
// language, export summaries, the LRU cap, the `.pth` safety rule, the
// no-project-folder rule, invalidation, module toggles and the
// no-process rule. Every test reads `Tests/Fixtures/M17/imports/` (or a
// temporary copy of it) through an injected project-folder root and
// interpreter; nothing reads the user's folders or Application Support.

enum ImportFixtures {
    static let root: String = {
        URL(fileURLWithPath: #filePath)                     // Tests/KaruCoreTests/ImportResolutionTests.swift
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/M17/imports").path
    }()
    static var python: String { root + "/python" }
    static var ts: String { root + "/ts" }
    static var interpreter: String { root + "/interp/bin/python3" }

    /// A temporary copy of a fixture project (tests that edit files).
    static func copy(_ name: String) -> (path: String, cleanup: () -> Void) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("KaruImportTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let target = base.appendingPathComponent(name)
        try! FileManager.default.copyItem(atPath: root + "/" + name, toPath: target.path)
        let real = SystemImportFileSystem().realPath(target.path)
        return (real, { try? FileManager.default.removeItem(at: base) })
    }
}

/// Records every path the resolvers touch (and, T17.16, the ones touched
/// on the main thread: there should be none).
final class RecordingFileSystem: ImportFileSystem, @unchecked Sendable {
    private let base = SystemImportFileSystem()
    private let lock = NSLock()
    private var paths: [String] = []
    private var mainPaths: [String] = []
    private var infoPaths: [String] = []
    private var readPaths: [String] = []

    var touched: [String] {
        lock.lock(); defer { lock.unlock() }
        return paths
    }

    var touchedOnMainThread: [String] {
        lock.lock(); defer { lock.unlock() }
        return mainPaths
    }

    /// Paths `contents` was called for (R09: a file over its limit never is).
    var read: [String] {
        lock.lock(); defer { lock.unlock() }
        return readPaths
    }

    /// Paths `info` was called for.
    var statted: [String] {
        lock.lock(); defer { lock.unlock() }
        return infoPaths
    }

    private func note(_ path: String) {
        let main = Thread.isMainThread
        lock.lock(); paths.append(path); if main { mainPaths.append(path) }; lock.unlock()
    }

    func info(_ path: String) -> ImportFileInfo? {
        note(path)
        lock.lock(); infoPaths.append(path); lock.unlock()
        return base.info(path)
    }
    func contents(_ path: String) -> Data? {
        note(path)
        lock.lock(); readPaths.append(path); lock.unlock()
        return base.contents(path)
    }
    func list(_ path: String) -> [String]? { note(path); return base.list(path) }
    func list(_ path: String, limit: Int) -> (names: [String], truncated: Bool)? {
        note(path); return base.list(path, limit: limit)
    }
    func realPath(_ path: String) -> String { note(path); return base.realPath(path) }
}

/// An import service over a project root and the fixture interpreter,
/// plus documents to ask for member candidates.
@MainActor
final class ImportHarness {
    let fs = RecordingFileSystem()
    let service: ImportService
    let pythonTables = PythonTypeTables(store: .shared)
    let scriptTables = ScriptTypeTables(store: .shared)
    let suite = "ImportResolutionTests-\(UUID().uuidString)"
    let defaults: UserDefaults
    let center = NotificationCenter()
    let modules: ModuleSettings
    final class RootBox: @unchecked Sendable { var path: String?; init(_ p: String?) { path = p } }
    let rootBox: RootBox
    var projectRoot: String? {
        get { rootBox.path }
        set { rootBox.path = newValue }
    }

    init(projectRoot: String?, interpreter: String? = ImportFixtures.interpreter, workspace: WorkspaceIndex? = nil,
         byteLimit: Int = ImportService.summaryByteLimit, moduleByteLimit: Int = ImportService.moduleByteLimit,
         revalidation: TimeInterval = 2, readByteLimit: Int = ImportService.readByteLimit) {
        defaults = UserDefaults(suiteName: suite)!
        modules = ModuleSettings(defaults: defaults, center: center)
        rootBox = RootBox(projectRoot)
        let discovery = interpreter.map { PythonInterpreterDiscovery.fixed($0) } ?? .none
        var config = ImportService.Configuration(fileSystem: fs, projectFolder: { _ in nil }, interpreter: { discovery },
                                                 revalidationInterval: revalidation, moduleSettings: modules, center: center,
                                                 workspace: workspace, byteLimit: byteLimit, moduleByteLimit: moduleByteLimit,
                                                 readByteLimit: readByteLimit)
        let modules = self.modules
        let box = rootBox
        config.projectFolder = { path in
            guard let root = box.path, modules.isEnabled(.crossFileIndex), ImportPath.isInside(path, root) else {
                return nil
            }
            return root
        }
        service = ImportService(configuration: config)
    }

    deinit {
        defaults.removePersistentDomain(forName: suite)
    }

    /// A document at `path` with `source` (caret marked by `|`).
    func document(_ source: String, language: String = "python", path: String?) -> ImportDocument {
        ImportDocument(source, language: language, path: path, harness: self)
    }

    /// Member names at the caret once imports settled (nil: unknown).
    func names(_ source: String, language: String = "python", at path: String?) -> [String]? {
        document(source, language: language, path: path).names
    }

    /// Sends pending work and waits for the import queue without blocking
    /// the main actor (other tests' main-queue work keeps running).
    func settle() async {
        service.flush()
        let queue = service.queue
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in queue.async { done.resume() } }
        service.applyInbox()
    }

    func namesAsync(_ source: String, language: String = "python", at path: String?) async -> [String]? {
        await document(source, language: language, path: path).namesAsync()
    }
}

@MainActor
final class ImportDocument {
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
    let analysis: DocumentAnalysis
    let inference: TypeInferenceService
    let caret: Int
    let path: String?
    let harness: ImportHarness
    let hub = TextStorageObserverHub()

    init(_ source: String, language: String, path: String?, harness: ImportHarness) {
        let ns = source as NSString
        let bar = ns.range(of: "|", options: .backwards)
        precondition(bar.location != NSNotFound, "mark the caret with |")
        caret = bar.location
        textView.string = ns.replacingCharacters(in: bar, with: "")
        analysis = DocumentAnalysis(textView: textView, moduleSettings: harness.modules, moduleCenter: NotificationCenter(),
                                    scheduler: AnalysisScheduler())
        analysis.setLanguage(identifier: language)
        hub.add(analysis)
        textView.textStorage?.delegate = hub
        inference = TypeInferenceService(tables: harness.pythonTables, scriptTables: harness.scriptTables,
                                         imports: harness.service)
        // Correctness, not latency: no budget abort under a loaded test run.
        inference.budgetMilliseconds = 5_000
        self.path = path
        self.harness = harness
    }

    var text: NSString { textView.textStorage!.mutableString }

    var dot: Int {
        let start = IdentifierText.runStart(before: caret, in: text, dollar: true) ?? caret
        return start - 1
    }

    /// One request, no waiting.
    func request() -> [Candidate]? {
        inference.memberCandidates(analysis: analysis, text: text, dot: dot, documentPath: path)
            .map { CandidateEngine.ranked($0) }
    }

    /// Requests until no import is pending (bounded).
    var candidates: [Candidate]? {
        var result = request()
        var rounds = 0
        while inference.lastRequestPendingImports, rounds < 12 {
            harness.service.waitForImports()
            result = request()
            rounds += 1
        }
        return result
    }

    var names: [String]? { candidates?.map(\.name) }

    func namesAsync() async -> [String]? {
        var result = request()
        var rounds = 0
        while inference.lastRequestPendingImports, rounds < 12 {
            await harness.settle()
            result = request()
            rounds += 1
        }
        return result?.map(\.name)
    }

    func detail(_ name: String) -> String? { candidates?.first { $0.name == name }?.detail }
}

// MARK: - Python

@MainActor
@Suite("T17.13 Python imports")
struct PythonImportTests {
    let main = ImportFixtures.python + "/main.py"

    @Test func packageReexportsAndAll() throws {
        let h = ImportHarness(projectRoot: ImportFixtures.python)
        let names = try #require(h.names("import myapp\nmyapp.|", at: main))
        #expect(names.contains("User") && names.contains("Admin") && names.contains("make_user"))
        #expect(names.contains("VERSION") && names.contains("util"))
        // `__all__` decides what a star import exports and what is listed.
        #expect(!names.contains("_private_helper"))
        #expect(!names.contains("services") && !names.contains("models"))
    }

    @Test func importedClassMembersAndPrecision() throws {
        let h = ImportHarness(projectRoot: ImportFixtures.python)
        let doc = h.document("from myapp import User\nu = User(\"a\")\nu.|", path: main)
        let names = try #require(doc.names)
        for n in ["name", "age", "email", "greet", "display", "anonymous", "kind"] { #expect(names.contains(n), "\(n)") }
        // Precision: nothing of a subclass or another module.
        #expect(!names.contains("ban") && !names.contains("promote") && !names.contains("slugify"))
        #expect(doc.detail("greet") == "() -> str")
        #expect(doc.detail("name") == "str")
        let admin = try #require(h.names("from myapp import Admin\nAdmin(\"x\").|", at: main))
        #expect(admin.contains("ban") && admin.contains("greet"))
        #expect(admin.firstIndex(of: "ban")! < admin.firstIndex(of: "greet")!)
    }

    @Test func functionSignaturesAcrossModules() throws {
        let h = ImportHarness(projectRoot: ImportFixtures.python)
        let names = try #require(h.names("from myapp.services import make_user\nmake_user(\"a\").|", at: main))
        #expect(names.contains("greet") && !names.contains("ban"))
        let doc = h.document("import myapp\nmyapp.|", path: main)
        #expect(doc.detail("make_user") == "(name: str) -> User")
    }

    @Test func relativeImportsFromTheDocument() throws {
        let h = ImportHarness(projectRoot: ImportFixtures.python)
        let probe = ImportFixtures.python + "/myapp/sub/probe.py"
        let names = try #require(h.names("from ..models import User\nUser(\"a\").|", at: probe))
        #expect(names.contains("greet"))
        // `.deep` relative to the document; `deep` itself imports `..models` and `..services`.
        let found = try #require(h.names("from . import deep\ndeep.find(\"x\").|", at: probe))
        #expect(found.contains("greet") && found.contains("email"))
        let dotted = try #require(h.names("import myapp.util\nmyapp.util.|", at: main))
        #expect(dotted.contains("slugify") && dotted.contains("count"))
    }

    @Test func reexportDepthIsLimitedToThree() throws {
        let h = ImportHarness(projectRoot: ImportFixtures.python)
        // chain/__init__ → l1 → l2 → l3 (three hops): resolved.
        #expect(h.names("from chain import Near\nNear().|", at: main)?.contains("close") == true)
        // … → l3 → l4 (four hops): unknown.
        #expect(h.names("from chain import Far\nFar().|", at: main) == nil)
    }

    @Test func stubsBeforeSources() throws {
        let h = ImportHarness(projectRoot: ImportFixtures.python)
        let client = try #require(h.names("import typedpkg\ntypedpkg.connect(\"u\").|", at: main))
        #expect(client.contains("get") && client.contains("close") && client.contains("base_url"))
        #expect(!client.contains("implementation_only"))
        let response = try #require(h.names("import typedpkg\ntypedpkg.Client().get(\"u\").|", at: main))
        #expect(Set(response).isSuperset(of: ["status", "json", "raise_for_status"]))
    }

    @Test func sourceOnlyPackage() throws {
        let h = ImportHarness(projectRoot: ImportFixtures.python)
        let engine = try #require(h.names("from plainpkg import Engine\nEngine().|", at: main))
        #expect(Set(engine).isSuperset(of: ["speed", "label", "start", "stop"]))
        // An unannotated `return Engine()` gives the return type.
        let started = try #require(h.names("from plainpkg import start_engine\nstart_engine().|", at: main))
        #expect(started.contains("speed"))
        // `return self` → the same class.
        #expect(h.names("from plainpkg import Engine\nEngine().start().|", at: main)?.contains("stop") == true)
    }

    @Test func lookupOrder() throws {
        let h = ImportHarness(projectRoot: ImportFixtures.python)
        // ① project root over ② the venv.
        let shadowed = try #require(h.names("import shadowed\nshadowed.|", at: main))
        #expect(shadowed.contains("FromProject") && !shadowed.contains("FromVenv"))
        // ② the venv over ③ the interpreter.
        let venv = try #require(h.names("import venvonly\nvenvonly.|", at: main))
        #expect(venv.contains("FromVenv") && !venv.contains("FromInterpreter"))
        // ③ interpreter site-packages, and its stdlib directory.
        #expect(h.names("import interponly\ninterponly.|", at: main)?.contains("FromInterpreter") == true)
        #expect(h.names("import stdextra\nstdextra.|", at: main)?.contains("from_stdlib_dir") == true)
        // The standard library resolves to the built-in typeshed tables first.
        let json = try #require(h.names("import json\njson.|", at: main))
        #expect(json.contains("dumps") && !json.contains("project_json_only"))
        // A namespace package (no `__init__`).
        #expect(h.names("import notapackage.inner\nnotapackage.inner.|", at: main)?.contains("namespaced") == true)
    }

    @Test func pthPathLinesOnly() throws {
        let h = ImportHarness(projectRoot: ImportFixtures.python)
        #expect(h.names("import pthmod\npthmod.|", at: main)?.contains("FromPth") == true)
        // The `import hidden` line is never read as a path (nor executed).
        #expect(h.names("import hiddenmod\nhiddenmod.|", at: main) == nil)
        #expect(!h.fs.touched.contains { $0.contains("import hidden") })
        #expect(PythonSearchPaths.pthPathLines(Data("# c\n\npath/a\nimport x; y()\nimport\tz\n  /abs  \n".utf8))
                == ["path/a", "/abs"])
    }

    @Test func noProjectFolderReadsOnlyInterpreterPaths() throws {
        let (dir, cleanup) = ImportFixtures.copy("python")
        defer { cleanup() }
        // A document outside every project folder, next to modules it imports.
        let h = ImportHarness(projectRoot: nil)
        let doc = dir + "/main.py"
        #expect(h.names("import shadowed\nshadowed.|", at: doc) == nil)
        #expect(h.names("from .myapp import User\nUser().|", at: doc) == nil)
        #expect(h.names("import interponly\ninterponly.|", at: doc)?.contains("FromInterpreter") == true)
        #expect(h.names("import json\njson.|", at: doc)?.contains("dumps") == true)
        // An unsaved buffer: the same.
        #expect(h.names("import interponly\ninterponly.|", at: nil)?.contains("FromInterpreter") == true)
        let interp = ImportFixtures.root + "/interp"
        let touched = h.fs.touched
        #expect(!touched.isEmpty)
        #expect(touched.allSatisfy { ImportPath.isInside($0, interp) }, "\(touched.filter { !ImportPath.isInside($0, interp) })")
        #expect(!touched.contains { ImportPath.isInside($0, dir) })
    }

    @Test func noInterpreterNoPathThree() throws {
        let h = ImportHarness(projectRoot: nil, interpreter: nil)
        #expect(h.names("import interponly\ninterponly.|", at: nil) == nil)
        #expect(h.names("import os\nos.|", at: nil)?.contains("getcwd") == true)
        #expect(h.fs.touched.isEmpty)
    }
}

// MARK: - Interpreter discovery

@Suite("T17.13 interpreter discovery")
struct InterpreterDiscoveryTests {
    @Test func layoutFromExecutable() {
        let fs = SystemImportFileSystem()
        let layout = PythonInterpreterLayout.derive(executable: ImportFixtures.interpreter, fs: fs)
        #expect(layout.stdlib == ImportFixtures.root + "/interp/lib/python3.13")
        #expect(layout.sitePackages == [ImportFixtures.root + "/interp/lib/python3.13/site-packages"])
    }

    @Test func venvFromPyvenvCfg() {
        let fs = SystemImportFileSystem()
        let paths = PythonSearchPaths.derive(projectRoot: ImportFixtures.python, interpreter: .none, fs: fs)
        let kinds = paths.roots.map(\.kind)
        #expect(kinds.first == .project)
        #expect(paths.roots.contains { $0.path.hasSuffix(".venv/lib/python3.13/site-packages") && $0.kind == .venv })
        #expect(paths.roots.contains { $0.path == ImportFixtures.python + "/pth_extra" })
    }

    @Test func neverStartsTheLoginShell() {
        final class Counter: @unchecked Sendable { var runs = 0 }
        let counter = Counter()
        let login = LoginShellPath(shell: "/bin/zsh", timeout: 1) { _, _, _ in counter.runs += 1; return nil }
        // Not captured yet: no system interpreter, and the shell is not run.
        #expect(login.cachedPathIfCaptured == nil)
        let discovery = PythonInterpreterDiscovery(preference: RunToolPreference(source: .system),
                                                   managedBinDirectory: { nil },
                                                   cachedLoginPath: { login.cachedPathIfCaptured })
        #expect(discovery.executable(fs: SystemImportFileSystem()) == nil)
        #expect(counter.runs == 0)
        // Once Run captured it, its directories are searched (the /usr/bin shim skipped).
        let captured = LoginShellPath(shell: "/bin/zsh", timeout: 1) { _, _, _ in
            "\(LoginShellPath.beginMarker)/usr/bin:\(ImportFixtures.root)/interp/bin\(LoginShellPath.endMarker)"
        }
        _ = captured.path
        let found = PythonInterpreterDiscovery(preference: RunToolPreference(source: .auto), managedBinDirectory: { nil },
                                               cachedLoginPath: { captured.cachedPathIfCaptured })
        #expect(found.executable(fs: SystemImportFileSystem()) == ImportFixtures.interpreter)
    }

    /// Plan §9 / T17.13 acceptance: import resolution never launches a process.
    @Test func importsSourcesNeverLaunchProcesses() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/KaruCore/Imports")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }
        #expect(files.count >= 6)
        let forbidden = [#"\bProcess\b"#, #"\bposix_spawn"#, #"\bsystem\s*\("#, #"\bNSTask\b"#, #"\bSyncCommand\b"#,
                         #"\bexecv"#, #"\bpopen\b"#, #"LoginShellPath\.shared\.path\b"#, #"\.resolve\(\s*\.python"#]
        for file in files {
            let text = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
            for pattern in forbidden {
                #expect(text.range(of: pattern, options: .regularExpression) == nil, "\(file): \(pattern)")
            }
        }
    }
}

// MARK: - JS / TS

@MainActor
@Suite("T17.13 JS/TS imports")
struct ScriptImportTests {
    let main = ImportFixtures.ts + "/src/main.ts"

    func ts(_ h: ImportHarness, _ source: String, _ language: String = "typescript") -> [String]? {
        h.names(source, language: language, at: language == "javascript" ? ImportFixtures.ts + "/src/probe.js" : main)
    }

    @Test func relativeImportWithIndexAndClassMembers() throws {
        let h = ImportHarness(projectRoot: ImportFixtures.ts)
        let doc = h.document("import { User } from \"./models\";\nconst u = new User(\"a\", 1);\nu.|", language: "typescript",
                             path: main)
        let names = try #require(doc.names)
        #expect(Set(names).isSuperset(of: ["name", "greet", "label"]))
        // Precision: private / protected / static members and other classes' members are not listed.
        #expect(!names.contains("secret") && !names.contains("age") && !names.contains("count")
                && !names.contains("create") && !names.contains("ban"))
        #expect(doc.detail("greet") == "() -> string")
        let statics = try #require(ts(h, "import { User } from \"./models\";\nUser.|"))
        #expect(statics.contains("create") && statics.contains("count") && !statics.contains("greet"))
        #expect(ts(h, "import { User } from \"./models\";\nUser.create(\"a\").|")?.contains("greet") == true)
    }

    @Test func crossModuleInheritanceAndReexports() throws {
        let h = ImportHarness(projectRoot: ImportFixtures.ts)
        let admin = try #require(ts(h, "import { Admin } from \"./models/admin\";\nnew Admin(\"a\", 1).|"))
        #expect(admin.contains("ban") && admin.contains("greet"))
        #expect(admin.firstIndex(of: "ban")! < admin.firstIndex(of: "greet")!)
        // `export * from` and `export { Admin as SuperUser } from`.
        let util = try #require(ts(h, "import * as util from \"./util\";\nutil.|"))
        #expect(Set(util).isSuperset(of: ["helper", "settings", "User", "SuperUser"]))
        #expect(!util.contains("Profile") && !util.contains("UserId"))      // types, not values
        #expect(ts(h, "import * as util from \"./util\";\nnew util.SuperUser(\"a\", 1).|")?.contains("ban") == true)
        #expect(ts(h, "import { helper } from \"./util\";\nhelper(1).|")?.contains("toUpperCase") == true)
        #expect(ts(h, "import { settings } from \"./util\";\nsettings.|").map(Set.init) == ["debug", "level"])
        // An imported interface used as an annotation.
        let profile = try #require(ts(h, "import type { Profile } from \"./models\";\nlet p: Profile;\np.|"))
        #expect(Set(profile) == ["id", "tags", "owner"])
        #expect(ts(h, "import { Profile } from \"./models\";\nlet p: Profile;\np.owner!.|")?.contains("greet") == true)
    }

    @Test func requireAndCommonJS() throws {
        let h = ImportHarness(projectRoot: ImportFixtures.ts)
        let legacy = try #require(ts(h, "const legacy = require(\"./legacy\");\nlegacy.|", "javascript"))
        #expect(legacy.contains("legacyFn") && legacy.contains("Legacy"))
        let inst = try #require(ts(h, "const { Legacy } = require(\"./legacy\");\nnew Legacy().|", "javascript"))
        #expect(inst.contains("run") && inst.contains("ready"))
        // A `.js` specifier names the TypeScript source next to it.
        #expect(ts(h, "import { fromJsSpecifier } from \"./esmhelper.js\";\nfromJsSpecifier().|")?.contains("toFixed") == true)
    }

    @Test func packageWithTypes() throws {
        let h = ImportHarness(projectRoot: ImportFixtures.ts)
        let client = try #require(ts(h, "import { connect } from \"typed-lib\";\nconnect(\"u\").|"))
        #expect(Set(client).isSuperset(of: ["baseUrl", "request", "close"]))
        #expect(!client.contains("jsOnlyName"))
        #expect(ts(h, "import Client from \"typed-lib\";\nnew Client().|")?.contains("request") == true)
        let reply = try #require(ts(h, "import { connect } from \"typed-lib\";\nasync function f() {\n  (await connect(\"u\").request(\"p\")).|\n}"))
        #expect(Set(reply) == ["status", "body"])
    }

    @Test func exportsConditionsAndSubpaths() throws {
        let h = ImportHarness(projectRoot: ImportFixtures.ts)
        #expect(ts(h, "import { condMain } from \"cond-lib\";\ncondMain().|").map(Set.init) == ["ok", "reason"])
        #expect(ts(h, "import { extraValue } from \"cond-lib/extra\";\nextraValue.|").map(Set.init) == ["size", "name"])
        #expect(ts(h, "import { alpha } from \"cond-lib/feature/alpha\";\nalpha().|") == ["alphaOnly"])
        #expect(ts(h, "import { wrongCond } from \"cond-lib\";\nwrongCond().|") == nil)
    }

    @Test func typesPackagesAndJavaScriptOnly() throws {
        let h = ImportHarness(projectRoot: ImportFixtures.ts)
        // `@types/untyped-js` before the package's JavaScript.
        #expect(ts(h, "import { fromTypes } from \"untyped-js\";\nfromTypes().|").map(Set.init) == ["label", "size"])
        // A `.js`-only package (JSDoc `@returns`, `this.x =` fields).
        let widget = try #require(ts(h, "const pj = require(\"plain-js\");\npj.makeWidget().|", "javascript"))
        #expect(widget.contains("render") && widget.contains("size"))
        #expect(ts(h, "import { Widget } from \"plain-js\";\nnew Widget().|")?.contains("render") == true)
        #expect(ts(h, "import { Scoped } from \"@scope/scoped\";\nnew Scoped().|") == ["hello"])
    }

    @Test func neverAboveTheProjectFolder() throws {
        let h = ImportHarness(projectRoot: ImportFixtures.ts)
        #expect(ts(h, "import { aboveProject } from \"above-pkg\";\naboveProject().|") == nil)
        #expect(!h.fs.touched.contains { $0.hasPrefix(ImportFixtures.root + "/node_modules") })
        // Without a project folder nothing is read for JS / TS.
        let none = ImportHarness(projectRoot: nil)
        #expect(ts(none, "import { User } from \"./models\";\nnew User(\"a\", 1).|") == nil)
        #expect(none.fs.touched.allSatisfy { !$0.hasPrefix(ImportFixtures.ts) })
    }

    @Test func locatorRules() {
        #expect(ScriptModuleLocator.splitPackage("@scope/pkg/a/b") == ("@scope/pkg", "a/b"))
        #expect(ScriptModuleLocator.splitPackage("pkg") == ("pkg", ""))
        #expect(ScriptModuleLocator.typesName("@scope/pkg") == "scope__pkg")
        let exports: [String: Any] = [".": ["import": "./m.mjs", "types": "./m.d.ts"],
                                      "./sub/*": ["default": "./lib/*.js"], "./x": "./x.js"]
        #expect(ScriptModuleLocator.exportTarget(exports, subpath: ".") == "./m.d.ts")
        #expect(ScriptModuleLocator.exportTarget(exports, subpath: "./sub/deep/y") == "./lib/deep/y.js")
        #expect(ScriptModuleLocator.exportTarget(exports, subpath: "./x") == "./x.js")
        #expect(ScriptModuleLocator.exportTarget(exports, subpath: "./nope") == nil)
        #expect(ScriptModuleLocator.exportTarget("./only.js", subpath: ".") == "./only.js")
        #expect(ScriptModuleLocator.exportTarget(["require": ["default": "./c.cjs"]], subpath: ".") == "./c.cjs")
    }
}

// MARK: - Caps, invalidation, toggles

/// A temporary project folder (real path).
private func temporaryProject(_ files: [String: String]) -> (path: String, cleanup: () -> Void) {
    let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("KaruImportTests-\(UUID().uuidString)", isDirectory: true)
    for (relative, text) in files {
        let url = base.appendingPathComponent(relative)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(text.utf8).write(to: url)
    }
    return (SystemImportFileSystem().realPath(base.path), { try? FileManager.default.removeItem(at: base) })
}

private func write(_ path: String, _ text: String) {
    try! Data(text.utf8).write(to: URL(fileURLWithPath: path))
}

@MainActor
@Suite("T17.13 caps and invalidation")
struct ImportCapTests {
    @Test func budgetConstants() {
        #expect(ImportService.summaryByteLimit == 8 * 1024 * 1024)
        #expect(ImportService.namesOnlySourceBytes == 2 * 1024 * 1024)
        #expect(ImportService.reexportDepth == 3)
    }

    @Test func sourcesOverTwoMegabytesKeepNamesOnly() async throws {
        var py = "class Big:\n    def method(self) -> int:\n        return 1\n\n"
        var ts = "export class Big {\n  method(): number { return 1; }\n}\n"
        var k = 0
        while py.utf8.count <= ImportService.namesOnlySourceBytes {
            py += "def function_\(k)(value: int) -> int:\n    return value + \(k)\n\n"
            ts += "export function function\(k)(value: number): number {\n  return value + \(k);\n}\n"
            k += 1
        }
        while ts.utf8.count <= ImportService.namesOnlySourceBytes {
            ts += "export const constant\(k) = \(k);\n"
            k += 1
        }
        let (root, cleanup) = temporaryProject(["big.py": py, "src/big.ts": ts, "small.py": "class Small:\n    x: int\n"])
        defer { cleanup() }
        let h = ImportHarness(projectRoot: root, interpreter: nil)
        let names = try #require(await h.namesAsync("import big\nbig.|", at: root + "/main.py"))
        #expect(names.contains("Big") && names.contains("function_0") && names.contains("function_\(k / 2)"))
        // Names only: no types.
        #expect(h.names("import big\nbig.Big().|", at: root + "/main.py") == nil)
        #expect(h.names("import big\nbig.function_0(1).|", at: root + "/main.py") == nil)
        let key = try #require(h.service.cacheForTesting.allKeys.first { $0.hasSuffix(":big") })
        #expect(h.service.cacheForTesting.peek(key)?.isNamesOnly == true)
        #expect(h.names("import small\nsmall.Small().|", at: root + "/main.py")?.filter { !$0.hasPrefix("__") } == ["x"])
        let tsNames = try #require(await h.namesAsync("import * as b from \"./big\";\nb.|", language: "typescript",
                                                      at: root + "/src/main.ts"))
        #expect(tsNames.contains("Big") && tsNames.contains("function0"))
        #expect(h.names("import { Big } from \"./big\";\nnew Big().|", language: "typescript", at: root + "/src/main.ts") == nil)
    }

    @Test func moduleOverItsCapKeepsNamesOnly() throws {
        let h = ImportHarness(projectRoot: ImportFixtures.python, moduleByteLimit: 400)
        let main = ImportFixtures.python + "/main.py"
        let names = try #require(h.names("import myapp.models\nmyapp.models.|", at: main))
        #expect(names.contains("User") && names.contains("Admin"))
        #expect(h.names("from myapp.models import User\nUser(\"a\").|", at: main) == nil)
        let cache = h.service.cacheForTesting
        #expect(cache.degradations > 0)
        #expect(cache.allKeys.allSatisfy { cache.peek($0)?.isNamesOnly == true || (cache.peek($0)?.approximateBytes ?? 0) <= 400 })
    }

    @Test func lruCapDegradesOldestFirst() throws {
        let main = ImportFixtures.python + "/main.py"
        // Measure the full set, then cap below it.
        let full = ImportHarness(projectRoot: ImportFixtures.python)
        for source in ["import myapp\nmyapp.|", "import typedpkg\ntypedpkg.|", "import plainpkg\nplainpkg.|"] {
            _ = full.names(source, at: main)
        }
        let total = full.service.cacheForTesting.bytes
        #expect(total > 0)
        // Room for the newest batch, not for everything: older modules degrade.
        let limit = total * 5 / 6
        let h = ImportHarness(projectRoot: ImportFixtures.python, byteLimit: limit)
        _ = h.names("import myapp\nmyapp.|", at: main)
        _ = h.names("import typedpkg\ntypedpkg.|", at: main)
        // The newest module stays complete; the cache never exceeds its cap.
        let engine = try #require(h.names("from plainpkg import Engine\nEngine().|", at: main))
        #expect(engine.contains("speed"))
        let cache = h.service.cacheForTesting
        #expect(cache.bytes <= limit)
        #expect(cache.degradations + cache.evictions > 0)
        // A degraded module is still listed by name.
        let myapp = try #require(h.names("import myapp\nmyapp.|", at: main))
        #expect(myapp.contains("User"))
        print("T17.13 LRU: full set \(total) B, cap \(limit) B → \(cache.bytes) B, \(cache.count) modules, "
              + "\(cache.degradations) reduced to names, \(cache.evictions) evicted")
    }

    @Test func savingAnotherProjectFileIsReflectedWithinOneSecond() async throws {
        let (root, cleanup) = ImportFixtures.copy("python")
        defer { cleanup() }
        let fixture = IndexFixture()
        let index = WorkspaceIndex(root: fixture.root, store: fixture.store, modules: fixture.modules, center: fixture.center)
        index.start()
        #expect(index.addFolder(URL(fileURLWithPath: root)))
        let deadline = Date().addingTimeInterval(10)
        while !index.isRunning(root).stream, Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        #expect(index.isRunning(root).stream)
        let h = ImportHarness(projectRoot: root, workspace: index)
        let doc = h.document("from myapp.models import User\nUser(\"a\").|", path: root + "/main.py")
        #expect(await doc.namesAsync()?.contains("greet") == true)
        let models = root + "/myapp/models.py"
        let original = try String(contentsOfFile: models, encoding: .utf8)
        let cache = h.service.cacheForTesting
        let key = try #require(cache.allKeys.first { $0.hasSuffix(":myapp.models") })
        func hasMember(_ name: String) -> Bool {
            guard case .python(let p)? = cache.peek(key)?.content else { return false }
            return p.stub.class(named: "User")?.member(named: name) != nil
        }
        // Pipeline: save → FSEvents → the queue re-reads the module (no main
        // thread involved; asserted). End to end: until the document's member
        // request shows it (includes waiting for the main actor; reported).
        var pipeline: [Double] = [], endToEnd: [Double] = []
        for trial in 0..<10 {
            let edited = original.replacingOccurrences(of: "    def greet(self) -> str:",
                                                       with: "    def wave\(trial)(self) -> int:\n        return \(trial)\n\n    def greet(self) -> str:")
            let start = ProcessInfo.processInfo.systemUptime
            write(models, edited)
            while ProcessInfo.processInfo.systemUptime - start < 5, !hasMember("wave\(trial)") {
                h.service.applyInbox()
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            #expect(hasMember("wave\(trial)"), "trial \(trial)")
            #expect(await doc.namesAsync()?.contains("wave\(trial)") == true)
            endToEnd.append(ProcessInfo.processInfo.systemUptime - start)
            pipeline.append((h.service.loadedAt[key] ?? .infinity) - start)
        }
        index.removeFolder(root)
        func stats(_ v: [Double]) -> (Double, Double) { let s = v.sorted(); return (s[s.count / 2], s.last!) }
        let (p50, maximum) = stats(pipeline), (e50, emax) = stats(endToEnd)
        print(String(format: "T17.13 save → summary re-read: p50 %.0f ms, max %.0f ms; → visible in the request: p50 %.0f ms, "
                     + "max %.0f ms (n=%d)", p50 * 1000, maximum * 1000, e50 * 1000, emax * 1000, pipeline.count))
        #expect(p50 <= 1.0 && maximum <= 1.0)
    }

    @Test func sitePackagesChangesByModificationTime() throws {
        let (root, cleanup) = ImportFixtures.copy("python")
        defer { cleanup() }
        // No FSEvents: only the mtime checks see site-packages changes.
        let h = ImportHarness(projectRoot: root, revalidation: 0)
        let main = root + "/main.py"
        let site = root + "/.venv/lib/python3.13/site-packages"
        let source = "import venvonly\nvenvonly.FromVenv().|"
        func own(_ names: [String]?) -> [String]? { names?.filter { !$0.hasPrefix("__") } }
        #expect(own(h.names(source, at: main)) == ["venv_only"])
        // Edit the package: the next request (a new evaluation) revalidates it on the queue.
        write(site + "/venvonly/__init__.py", "class FromVenv:\n    def venv_only(self) -> int:\n        return 1\n\n"
              + "    def reinstalled(self) -> int:\n        return 2\n")
        _ = h.document(source, path: main).request()
        h.service.waitForImports()
        #expect(h.service.statistics.invalidations >= 1)
        #expect(h.names(source, at: main)?.contains("reinstalled") == true)
        // A package installed later: the site-packages mtime changes.
        #expect(h.names("import freshpkg\nfreshpkg.|", at: main) == nil)
        try FileManager.default.createDirectory(atPath: site + "/freshpkg", withIntermediateDirectories: true)
        write(site + "/freshpkg/__init__.py", "def installed() -> int:\n    return 1\n")
        _ = h.document("import freshpkg\nfreshpkg.|", path: main).request()
        h.service.waitForImports()
        #expect(h.names("import freshpkg\nfreshpkg.|", at: main)?.contains("installed") == true)
    }

    @Test func venvCreatedAfterTheFirstLookupIsPickedUp() throws {
        // T17.15c: a project opened before `uv venv` / `python -m venv`: the
        // search paths had no venv and nothing to revalidate, so its packages
        // stayed missing until Karu restarted.
        let (root, cleanup) = temporaryProject(["main.py": "\n"])
        defer { cleanup() }
        let h = ImportHarness(projectRoot: root, interpreter: nil, revalidation: 0)
        let main = root + "/main.py"
        let source = "import latepkg\nlatepkg.|"
        #expect(h.names(source, at: main) == nil)
        let site = root + "/.venv/lib/python3.13/site-packages"
        try FileManager.default.createDirectory(atPath: site + "/latepkg", withIntermediateDirectories: true)
        write(root + "/.venv/pyvenv.cfg", "home = /usr/bin\nversion_info = 3.13\n")
        write(site + "/latepkg/__init__.py", "def late() -> int:\n    return 1\n")
        _ = h.document(source, path: main).request()
        h.service.waitForImports()
        #expect(h.names(source, at: main)?.contains("late") == true)
    }

    @Test func documentPathTakesTheProjectRootSpelling() throws {
        // T17.15c: AppKit spells an opened file `/private/tmp/…` while the
        // project folder is stored standardized (`/tmp/…`); JS / TS packages
        // and Python relative imports compared the two as strings and found
        // nothing.
        let (root, cleanup) = temporaryProject(["a.js": "\n"])
        defer { cleanup() }
        let standardRoot = ProjectFolderStore.standardize(root)
        #expect(ImportService.path(root + "/a.js", spelledUnder: standardRoot) == standardRoot + "/a.js")
        #expect(ImportService.path(standardRoot + "/a.js", spelledUnder: standardRoot) == standardRoot + "/a.js")
        // A symlinked folder: its documents opened through the real path.
        let link = NSTemporaryDirectory() + "KaruImportLink-\(UUID().uuidString)"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: root)
        defer { try? FileManager.default.removeItem(atPath: link) }
        #expect(ImportService.path(root + "/a.js", spelledUnder: link) == link + "/a.js")
        // Outside the root: unchanged.
        #expect(ImportService.path("/usr/bin/env", spelledUnder: standardRoot) == "/usr/bin/env")
    }

    @Test func moduleTogglesReleaseEverything() throws {
        let h = ImportHarness(projectRoot: ImportFixtures.python)
        let main = ImportFixtures.python + "/main.py"
        #expect(h.names("import shadowed\nshadowed.|", at: main)?.contains("FromProject") == true)
        #expect(!h.service.isReleased && h.service.retainedBytes > 0)
        h.modules.setEnabled(false, for: .typeInference)
        #expect(h.service.isReleased && h.service.retainedBytes == 0)
        h.modules.setEnabled(true, for: .typeInference)
        #expect(h.names("import shadowed\nshadowed.|", at: main)?.contains("FromProject") == true)
        // Cross-file index off: released; afterwards no project folder (① / ②),
        // while stdlib stubs and the interpreter (③) keep working.
        h.modules.setEnabled(false, for: .crossFileIndex)
        #expect(h.service.isReleased)
        #expect(h.names("import shadowed\nshadowed.|", at: main) == nil)
        #expect(h.names("import interponly\ninterponly.|", at: main)?.contains("FromInterpreter") == true)
        #expect(h.names("import json\njson.|", at: main)?.contains("dumps") == true)
        h.modules.setEnabled(false, for: .completion)
        #expect(h.service.isReleased)
    }

    @Test func openPopupRefreshesWhenSummariesArrive() throws {
        let h = ImportHarness(projectRoot: ImportFixtures.python)
        let textView = EditorTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let scroll = NSScrollView(frame: textView.frame)
        scroll.documentView = textView
        let window = NSWindow(contentRect: textView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { window.close() }
        let hub = TextStorageObserverHub()
        textView.string = "import myapp\nmyapp"
        textView.textStorage?.delegate = hub
        let controller = CompletionController(textView: textView, moduleSettings: h.modules, moduleCenter: h.center,
                                              scheduler: AnalysisScheduler(), importService: h.service)
        controller.documentURLProvider = { URL(fileURLWithPath: ImportFixtures.python + "/main.py") }
        hub.add(controller)
        textView.completionKeyHandler = controller
        controller.setLanguage(identifier: "python")
        controller.indexDocument()
        window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        textView.insertText(".", replacementRange: NSRange(location: NSNotFound, length: 0))
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                     context: nil, characters: ".", charactersIgnoringModifiers: ".", isARepeat: false,
                                     keyCode: 0)!
        controller.textViewDidInsertKey(event)
        // The module is still loading: no inferred members yet.
        #expect(controller.isWaitingForImportsForTesting)
        #expect(!controller.currentCandidatesForTesting.contains { $0.name == "User" })
        // Its summary arrives (and the ones it re-exports from): the popup refreshes at the same caret.
        for _ in 0..<6 where !controller.currentCandidatesForTesting.contains(where: { $0.name == "User" }) {
            h.service.waitForImports()
        }
        let candidates = controller.currentCandidatesForTesting
        #expect(candidates.contains { $0.name == "User" && $0.source == .inferredType })
        #expect(candidates.contains { $0.name == "make_user" })
        controller.dismissCompletion()
    }
}
