import AppKit
import Foundation
import Testing
@testable import KaruCore

// M17 T17.16 — completion inside import statements (plan §9 "T17.16 补充"):
// Python module names (stdlib table, project root, venv, interpreter,
// `.pth`), submodules after a dot, `from x import` names, relative
// `from . import`; JS / TS specifiers (node_modules, `@scope`, `@types`,
// relative directories, Node built-ins) and `import { … }` names; only
// those candidates at an import site; replacement ranges; the nearest venv
// walking up from the document; and no disk read on the main thread.

/// A temporary project folder (real path) with `files` (relative path → text).
private func project(_ files: [String: String]) -> (path: String, cleanup: () -> Void) {
    let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("KaruImportCompletion-\(UUID().uuidString)", isDirectory: true)
    for (relative, text) in files {
        let url = base.appendingPathComponent(relative)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(text.utf8).write(to: url)
    }
    return (SystemImportFileSystem().realPath(base.path), { try? FileManager.default.removeItem(at: base) })
}

private let venvConfig = "home = /usr/bin\nversion_info = 3.13\n"

/// A JS / TS project with packages, scopes, `@types` and relative files.
private let scriptProject: [String: String] = [
    "package.json": "{\"name\": \"probe\"}\n",
    "node_modules/mini/package.json": "{\"name\": \"mini\", \"types\": \"index.d.ts\"}\n",
    "node_modules/mini/index.d.ts": "export declare function hello(): string;\nexport declare const helper: number;\n",
    "node_modules/mini/lib/extra.js": "module.exports = {};\n",
    "node_modules/@scope/pkg/package.json": "{\"name\": \"@scope/pkg\", \"types\": \"index.d.ts\"}\n",
    "node_modules/@scope/pkg/index.d.ts": "export declare const scoped: number;\n",
    "node_modules/@types/typedonly/index.d.ts": "export declare const t: number;\n",
    "node_modules/@types/scope2__thing/index.d.ts": "export declare const u: number;\n",
    "node_modules/.bin/tool": "#!/bin/sh\n",
    "src/main.ts": "\n",
    "src/util.ts": "export const u = 1;\n",
    "src/view.tsx": "export const v = 1;\n",
    "src/types.d.ts": "export type T = number;\n",
    "src/data.json": "{}\n",
    "src/.hidden.ts": "\n",
    "src/models/index.ts": "export class User {}\n",
]

@MainActor
private final class PendingBox { var pending = false }

/// Runs the engine at `│` with the harness's import service as the
/// import-candidate provider, settling the import queue while the answer
/// is pending (bounded). Document words are indexed from the text.
@MainActor
private func complete(_ h: ImportHarness, _ source: String, language: String = "python", path: String?,
                      manual: Bool = false) async -> CompletionResult? {
    let marker = (source as NSString).range(of: "│")
    precondition(marker.location != NSNotFound, "no caret marker")
    let plain = (source as NSString).replacingCharacters(in: marker, with: "")
    h.service.register(python: h.pythonTables, script: h.scriptTables)
    let def = LanguageRegistry.definition(forIdentifier: language)
    let box = PendingBox()
    var request = CompletionRequest(text: plain as NSString, caret: marker.location, languageIdentifier: language)
    request.manual = manual
    request.keywords = def?.keywords ?? []
    request.builtins = def?.builtins ?? []
    request.words = WordIndex(text: plain, languageIdentifier: language)
    request.scanner = CandidateEngine.contextScanner(for: language, definition: def)
    request.importCandidates = { match in
        let answer = h.service.importCompletions(match, documentPath: path, pythonTables: h.pythonTables,
                                                 scriptTables: h.scriptTables)
        box.pending = answer.pending
        return answer.batch
    }
    var engine = CandidateEngine()
    var checkpoints = CheckpointStore()
    var result = engine.complete(request, checkpoints: &checkpoints)
    var rounds = 0
    while box.pending, rounds < 12 {
        await h.settle()
        box.pending = false
        result = engine.complete(request, checkpoints: &checkpoints)
        rounds += 1
    }
    return result
}

private func names(_ result: CompletionResult?) -> [String] { result?.candidates.map(\.name) ?? [] }

/// No import-statement candidate (ordinary completion may still answer).
private func noImportCandidates(_ result: CompletionResult?) -> Bool {
    !(result?.candidates.contains { $0.source == .importedModule } ?? false)
}

// MARK: - Python

@MainActor
@Suite("T17.16 Python import statements", .serialized)
struct PythonImportCompletionTests {
    let main = ImportFixtures.python + "/main.py"

    @Test func moduleNamesFromTheStandardLibraryOnly() async throws {
        let h = ImportHarness(projectRoot: ImportFixtures.python)
        let result = await complete(h, "timer_word = 1\ntiny = 2\nimport ti│", path: main)
        let list = names(result)
        #expect(list.contains("time") && list.contains("timeit"))
        // Only the import sources: no document words, no keywords.
        #expect(!list.contains("timer_word") && !list.contains("tiny"))
        #expect(result?.candidates.allSatisfy { $0.source == .importedModule && $0.kind == .module } == true)
        // `import a, ti│` and after `as`.
        #expect(names(await complete(h, "import os, ti│", path: main)).contains("time"))
        #expect(noImportCandidates(await complete(h, "import os as ti│", path: main)))
    }

    @Test func submodulesAfterADot() async throws {
        let h = ImportHarness(projectRoot: ImportFixtures.python)
        let os = await complete(h, "import os.pa│", path: main)
        #expect(names(os) == ["path"])
        #expect(os?.context.replacementRange == NSRange(location: 10, length: 2))
        // Right after the dot: an automatic request (empty prefix).
        let etree = names(await complete(h, "import xml.etree.│", path: main))
        #expect(etree.contains("ElementTree") && etree.contains("ElementPath"))
        #expect(names(await complete(h, "from xml.│", path: main)).contains("etree"))
        // Without the dot an empty prefix needs a manual request.
        #expect(await complete(h, "import │", path: main) == nil)
        // (The first 50 in dictionary order.)
        #expect(names(await complete(h, "import │", path: main, manual: true)).contains("abc"))
    }

    @Test func fromImportNames() async throws {
        let h = ImportHarness(projectRoot: ImportFixtures.python)
        let os = names(await complete(h, "from os import pa│", path: main))
        #expect(os.contains("path") && os.contains("pathsep") && os.contains("pardir"))
        let time = await complete(h, "from time import sl│", path: main)
        #expect(names(time).first == "sleep")
        #expect(time?.candidates.first?.kind == .function && time?.candidates.first?.detail != nil)
        // Comma continuations and a parenthesised multi-line list.
        #expect(names(await complete(h, "from time import time, sl│", path: main)).contains("sleep"))
        #expect(names(await complete(h, "from os import (\n    sep,  # separator\n    pa│", path: main)).contains("path"))
        #expect(names(await complete(h, "from os import \\\n    pa│", path: main)).contains("path"))
        // `as` positions are not name positions.
        #expect(noImportCandidates(await complete(h, "from time import sleep as sl│", path: main)))
        // Replacement: the whole identifier around the caret.
        let mid = await complete(h, "from time import sl│ep", path: main)
        #expect(mid?.context.identifier == "slep")
    }

    @Test func privateModulesOnlyForAnUnderscorePrefix() async throws {
        let h = ImportHarness(projectRoot: ImportFixtures.python)
        let thr = names(await complete(h, "import thr│", path: main))
        #expect(thr.contains("threading"))
        #expect(!thr.contains("_thread"))
        #expect(names(await complete(h, "import _th│", path: main)).contains("_thread"))
        #expect(!names(await complete(h, "import os, │", path: main, manual: true)).contains { $0.hasPrefix("_") })
    }

    @Test func projectModulesAndPackages() async throws {
        let h = ImportHarness(projectRoot: ImportFixtures.python)
        #expect(names(await complete(h, "import my│", path: main)).contains("myapp"))
        #expect(names(await complete(h, "import cha│", path: main)).contains("chain"))
        #expect(names(await complete(h, "import sha│", path: main)).contains("shadowed"))
        // A directory without `__init__` is not listed.
        #expect(await complete(h, "import notap│", path: main) == nil)
        let sub = names(await complete(h, "import myapp.│", path: main))
        #expect(Set(sub) == ["models", "services", "util", "sub"])
        #expect(names(await complete(h, "import myapp.sub.│", path: main)) == ["deep"])
        // `from pkg import`: exports first, then submodules not exported.
        let from = names(await complete(h, "from myapp import │", path: main, manual: true))
        #expect(from.contains("User") && from.contains("make_user") && from.contains("services"))
        #expect(from.firstIndex(of: "User")! < from.firstIndex(of: "services")!)
    }

    @Test func venvInterpreterAndPthModules() async throws {
        let h = ImportHarness(projectRoot: ImportFixtures.python)
        #expect(names(await complete(h, "import venvo│", path: main)).contains("venvonly"))
        #expect(names(await complete(h, "import typedp│", path: main)) == ["typedpkg"])
        #expect(names(await complete(h, "import plai│", path: main)).contains("plainpkg"))
        #expect(names(await complete(h, "import interp│", path: main)).contains("interponly"))
        #expect(names(await complete(h, "import pthm│", path: main)).contains("pthmod"))
        #expect(names(await complete(h, "import typedpkg.│", path: main)).contains("response"))
        // The `import` line of the `.pth` file is never a path.
        #expect(await complete(h, "import hidden│", path: main) == nil)
        #expect(!h.fs.touched.contains { $0.contains("import hidden") })
    }

    @Test func relativeFromImportListsSiblingModules() async throws {
        let h = ImportHarness(projectRoot: ImportFixtures.python)
        let services = ImportFixtures.python + "/myapp/services.py"
        let siblings = names(await complete(h, "from . import │", path: services, manual: true))
        #expect(siblings.contains("models") && siblings.contains("util") && siblings.contains("sub"))
        #expect(names(await complete(h, "from . import mo│", path: services)).contains("models"))
        #expect(names(await complete(h, "from .│", path: services)).contains("models"))
        #expect(names(await complete(h, "from .sub import │", path: services, manual: true)).contains("deep"))
        // At the project root: the root's modules.
        #expect(names(await complete(h, "from . import my│", path: main)).contains("myapp"))
        // Outside a project folder: nothing relative.
        let outside = ImportHarness(projectRoot: nil)
        #expect(await complete(outside, "from . import mo│", path: services) == nil)
    }

    @Test func withoutAProjectFolderOnlyTableAndInterpreter() async throws {
        let h = ImportHarness(projectRoot: nil)
        let list = names(await complete(h, "import i│", path: main, manual: true))
        #expect(list.contains("interponly") && list.contains("io"))
        #expect(!names(await complete(h, "import my│", path: main)).contains("myapp"))
        let interp = ImportFixtures.root + "/interp"
        #expect(h.fs.touched.allSatisfy { ImportPath.isInside($0, interp) })
        // An unsaved buffer: the same.
        #expect(names(await complete(h, "import interp│", path: nil)).contains("interponly"))
    }
}

// MARK: - Venv lookup

@MainActor
@Suite("T17.16 venv walk", .serialized)
struct VenvWalkTests {
    @Test func nearestVenvFromTheDocumentUpward() async throws {
        let site = "/lib/python3.13/site-packages"
        let (root, cleanup) = project([
            ".venv/pyvenv.cfg": venvConfig,
            ".venv" + site + "/rootpkg/__init__.py": "def at_root() -> int:\n    return 1\n",
            "svc/.venv/pyvenv.cfg": venvConfig,
            "svc/.venv" + site + "/svcpkg/__init__.py": "def in_svc() -> int:\n    return 1\n",
            "svc/app/main.py": "\n",
            "other/main.py": "\n",
        ])
        defer { cleanup() }
        let h = ImportHarness(projectRoot: root, interpreter: nil)
        let inSvc = root + "/svc/app/main.py"
        let inOther = root + "/other/main.py"
        // Walking up from svc/app: svc/.venv is the nearest (the root's is not used).
        #expect(names(await complete(h, "import svcp│", path: inSvc)) == ["svcpkg"])
        #expect(await complete(h, "import rootp│", path: inSvc) == nil)
        #expect(await h.namesAsync("import svcpkg\nsvcpkg.|", at: inSvc)?.contains("in_svc") == true)
        // A sibling directory's venv is not; the root's is.
        #expect(await complete(h, "import svcp│", path: inOther) == nil)
        #expect(await h.namesAsync("import svcpkg\nsvcpkg.|", at: inOther) == nil)
        #expect(names(await complete(h, "import rootp│", path: inOther)) == ["rootpkg"])
        #expect(await h.namesAsync("import rootpkg\nrootpkg.|", at: inOther)?.contains("at_root") == true)
        // The probe itself.
        let fs = SystemImportFileSystem()
        #expect(PythonVenvProbe.find(from: root + "/svc/app", projectRoot: root, fs: fs).venv == root + "/svc/.venv")
        #expect(PythonVenvProbe.find(from: root + "/other", projectRoot: root, fs: fs).venv == root + "/.venv")
        #expect(PythonVenvProbe.find(from: nil, projectRoot: root, fs: fs).venv == root + "/.venv")
        // Never above the project folder.
        #expect(PythonVenvProbe.find(from: root + "/svc/app", projectRoot: root + "/svc/app", fs: fs).venv == nil)
    }

    @Test func projectTestsPackageListedSitePackagesTestsNot() async throws {
        // A stray top-level `tests` in site-packages is a packaging slip; the
        // project's own `tests` package is a real import target.
        let site = "/lib/python3.13/site-packages"
        let (root, cleanup) = project([
            ".venv/pyvenv.cfg": venvConfig,
            ".venv" + site + "/tests/__init__.py": "\n",
            ".venv" + site + "/testfixtures/__init__.py": "\n",
            "tests/__init__.py": "\n",
            "main.py": "\n",
        ])
        defer { cleanup() }
        let h = ImportHarness(projectRoot: root, interpreter: nil)
        let found = names(await complete(h, "import test│", path: root + "/main.py"))
        #expect(found.filter { $0 == "tests" }.count == 1)
        #expect(found.contains("testfixtures"))
        let (bare, bareCleanup) = project([".venv/pyvenv.cfg": venvConfig, ".venv" + site + "/tests/__init__.py": "\n",
                                           "main.py": "\n"])
        defer { bareCleanup() }
        let hb = ImportHarness(projectRoot: bare, interpreter: nil)
        #expect(!names(await complete(hb, "import test│", path: bare + "/main.py")).contains("tests"))
    }

    @Test func venvCreatedLaterInASubdirectoryIsPickedUp() async throws {
        let (root, cleanup) = project(["sub/main.py": "\n"])
        defer { cleanup() }
        let h = ImportHarness(projectRoot: root, interpreter: nil, revalidation: 0)
        let doc = root + "/sub/main.py"
        #expect(await complete(h, "import latep│", path: doc) == nil)
        #expect(await h.namesAsync("import latepkg\nlatepkg.|", at: doc) == nil)
        let site = root + "/sub/.venv/lib/python3.13/site-packages"
        try FileManager.default.createDirectory(atPath: site + "/latepkg", withIntermediateDirectories: true)
        try Data(venvConfig.utf8).write(to: URL(fileURLWithPath: root + "/sub/.venv/pyvenv.cfg"))
        try Data("def late() -> int:\n    return 1\n".utf8).write(to: URL(fileURLWithPath: site + "/latepkg/__init__.py"))
        // The next use rechecks the walked directories' mtimes.
        _ = await complete(h, "import latep│", path: doc)
        await h.settle()
        #expect(names(await complete(h, "import latep│", path: doc)) == ["latepkg"])
        #expect(await h.namesAsync("import latepkg\nlatepkg.|", at: doc)?.contains("late") == true)
    }
}

// MARK: - JS / TS

@MainActor
@Suite("T17.16 JS/TS import statements", .serialized)
struct ScriptImportCompletionTests {
    @Test func packagesScopesAndTypes() async throws {
        let (root, cleanup) = project(scriptProject)
        defer { cleanup() }
        let h = ImportHarness(projectRoot: root, interpreter: nil)
        let main = root + "/src/main.ts"
        let mini = await complete(h, "import x from 'mi│';", language: "typescript", path: main)
        #expect(names(mini) == ["mini"])
        // Replacement: inside the quotes, up to the caret.
        #expect(mini?.context.replacementRange == NSRange(location: 15, length: 2))
        #expect(Set(names(await complete(h, "import x from '@sc│'", language: "typescript", path: main)))
                == ["@scope/pkg", "@scope2/thing"])
        #expect(names(await complete(h, "import x from '@scope/│'", language: "typescript", path: main)) == ["pkg"])
        #expect(names(await complete(h, "import x from 'typedo│'", language: "typescript", path: main)) == ["typedonly"])
        #expect(names(await complete(h, "import x from '@scope2/│'", language: "typescript", path: main)) == ["thing"])
        #expect(names(await complete(h, "import x from '@sco│'", language: "typescript", path: main)).contains("@scope2/thing"))
        #expect(!names(await complete(h, "import x from '│'", language: "typescript", path: main, manual: true))
            .contains { $0.hasPrefix(".") || $0.hasPrefix("@types") })
        // Inside a package after `/`.
        #expect(names(await complete(h, "import x from 'mini/│'", language: "typescript", path: main))
            .contains("lib/"))
        // Every specifier form.
        for source in ["export * from \"mi│\"", "import \"mi│\";", "const m = require('mi│')",
                       "const m = await import('mi│')"] {
            #expect(names(await complete(h, source, language: "javascript", path: root + "/src/a.js")).contains("mini"),
                    "\(source)")
        }
    }

    @Test func relativeDirectories() async throws {
        let (root, cleanup) = project(scriptProject)
        defer { cleanup() }
        let h = ImportHarness(projectRoot: root, interpreter: nil)
        let main = root + "/src/main.ts"
        let here = await complete(h, "import { u } from './│'", language: "typescript", path: main)
        let list = names(here)
        #expect(Set(list) == ["util", "view", "types", "data.json", "models/"])
        #expect(here?.context.replacementRange == NSRange(location: 21, length: 0))
        #expect(names(await complete(h, "import { u } from './mo│'", language: "typescript", path: main)) == ["models/"])
        #expect(names(await complete(h, "import { u } from './models/│'", language: "typescript", path: main)) == ["index"])
        #expect(names(await complete(h, "import { u } from '../│'", language: "typescript", path: main))
            .contains("src/"))
        // Never above the project folder.
        #expect(await complete(h, "import { u } from '../../│'", language: "typescript", path: main) == nil)
        // The caret mid-segment: only up to the caret is replaced.
        let mid = await complete(h, "import { u } from './ut│il'", language: "typescript", path: main)
        #expect(mid?.context.identifier == "ut")
    }

    @Test func nodeBuiltins() async throws {
        let (root, cleanup) = project(scriptProject)
        defer { cleanup() }
        let h = ImportHarness(projectRoot: root, interpreter: nil)
        let js = root + "/src/a.js"
        #expect(names(await complete(h, "const fs = require('f│')", language: "javascript", path: js, manual: true))
            .contains("fs"))
        #expect(names(await complete(h, "import fs from 'node:f│'", language: "javascript", path: js))
            .contains("node:fs"))
        let te = names(await complete(h, "import t from 'node:te│'", language: "javascript", path: js))
        #expect(te.first == "node:test", "\(te)")      // then word-start matches (`node:trace_events`)
        #expect(names(await complete(h, "import fs from 'fs/│'", language: "javascript", path: js)) == ["promises"])
        // Without a project folder: built-ins only.
        let outside = ImportHarness(projectRoot: nil, interpreter: nil)
        #expect(names(await complete(outside, "import p from 'pa│'", language: "javascript", path: nil)) == ["path"])
        #expect(await complete(outside, "import m from 'mi│'", language: "javascript", path: nil) == nil)
        #expect(outside.fs.touched.isEmpty)
    }

    @Test func namedImports() async throws {
        let (root, cleanup) = project(scriptProject)
        defer { cleanup() }
        let h = ImportHarness(projectRoot: root, interpreter: nil)
        let main = root + "/src/main.ts"
        let he = await complete(h, "import { he│ } from 'mini';", language: "typescript", path: main)
        #expect(Set(names(he)) == ["hello", "helper"])
        #expect(he?.candidates.first { $0.name == "hello" }?.kind == .function)
        #expect(names(await complete(h, "import {\n  hello,\n  he│\n} from \"mini\"", language: "typescript", path: main))
            .contains("helper"))
        #expect(names(await complete(h, "import type { he│ } from 'mini'", language: "typescript", path: main))
            .contains("hello"))
        #expect(Set(names(await complete(h, "import def, { │ } from 'mini'", language: "typescript", path: main,
                                         manual: true))) == ["hello", "helper"])
        // `a as b│` is no import position.
        #expect(names(await complete(h, "const helium = 1;\nimport { hello as he│ } from 'mini'", language: "typescript",
                                     path: main)) != ["hello", "helper"])
    }

    @Test func otherStringsAndCommentsStillDoNotPop() async throws {
        let (root, cleanup) = project(scriptProject)
        defer { cleanup() }
        let h = ImportHarness(projectRoot: root, interpreter: nil)
        let main = root + "/src/main.ts"
        let minimum = "const minimum = 1;\n"
        #expect(await complete(h, minimum + "const s = 'mi│'", language: "typescript", path: main) == nil)
        #expect(await complete(h, minimum + "console.log(\"./│\")", language: "typescript", path: main) == nil)
        #expect(await complete(h, minimum + "x.from('mi│')", language: "typescript", path: main) == nil)
        #expect(await complete(h, minimum + "// import x from 'mi│'", language: "typescript", path: main) == nil)
        // Python: comments and strings are no import positions.
        let py = ImportHarness(projectRoot: ImportFixtures.python)
        #expect(await complete(py, "timer = 1\n# import ti│", path: ImportFixtures.python + "/main.py") == nil)
        #expect(await complete(py, "timer = 1\ns = 'import ti│'", path: ImportFixtures.python + "/main.py") == nil)
    }
}

// MARK: - Threading, caches, toggles

@MainActor
@Suite("T17.16 import statement plumbing", .serialized)
struct ImportCompletionPlumbingTests {
    @Test func noDiskReadOnTheMainThread() async throws {
        let (root, cleanup) = project(scriptProject.merging([
            ".venv/pyvenv.cfg": venvConfig,
            ".venv/lib/python3.13/site-packages/vpkg/__init__.py": "x = 1\n",
            "py/app.py": "\n",
        ]) { a, _ in a })
        defer { cleanup() }
        let h = ImportHarness(projectRoot: root)
        let py = root + "/py/app.py"
        let ts = root + "/src/main.ts"
        #expect(names(await complete(h, "import vp│", path: py)) == ["vpkg"])
        #expect(names(await complete(h, "from vpkg import │", path: py, manual: true)).contains("x"))
        #expect(names(await complete(h, "import interp│", path: py)).contains("interponly"))
        #expect(!names(await complete(h, "import x from 'mi│'", language: "typescript", path: ts)).isEmpty)
        #expect(!names(await complete(h, "import x from './│'", language: "typescript", path: ts)).isEmpty)
        #expect(!names(await complete(h, "import { he│ } from 'mini'", language: "typescript", path: ts)).isEmpty)
        #expect(!h.fs.touched.isEmpty)
        #expect(h.fs.touchedOnMainThread.isEmpty, "\(h.fs.touchedOnMainThread)")
    }

    @Test func listingsAreCachedCappedAndRevalidated() async throws {
        var files: [String: String] = ["main.py": "\n"]
        for i in 0..<2_100 { files[String(format: "m%04d.py", i)] = "\n" }
        let (root, cleanup) = project(files)
        defer { cleanup() }
        let h = ImportHarness(projectRoot: root, interpreter: nil, revalidation: 0)
        let doc = root + "/main.py"
        let first = await complete(h, "import m│", path: doc, manual: true)
        #expect(first != nil)
        // At most 2,000 entries of the directory (sorted: `m0000` … `m1999`).
        let key = try #require(h.service.cacheForTesting.allKeys.first { $0.hasSuffix("#py") })
        guard case .listing(let listing)? = h.service.cacheForTesting.peek(key)?.content else {
            Issue.record("no listing")
            return
        }
        #expect(listing.entries.count == ImportWorker.directoryEntryLimit)
        #expect(h.service.retainedBytes >= listing.approximateBytes)
        // Cached: the next request reads nothing.
        let reads = h.fs.touched.count
        _ = await complete(h, "import m0│", path: doc)
        #expect(h.fs.touched.count - reads <= 4)       // only mtime checks
        // A new module changes the directory's mtime: re-listed.
        try Data("\n".utf8).write(to: URL(fileURLWithPath: root + "/aaa_new.py"))
        _ = await complete(h, "import aaa│", path: doc)
        await h.settle()
        #expect(names(await complete(h, "import aaa│", path: doc)) == ["aaa_new"])
    }

    @Test func typeInferenceOffReleasesAndDisables() throws {
        let h = ImportHarness(projectRoot: ImportFixtures.python)
        let tv = ImportControllerWindow(h, "import ti", path: ImportFixtures.python + "/main.py")
        defer { tv.close() }
        tv.requestManual()
        #expect(tv.controller.currentCandidatesForTesting.contains { $0.name == "time" })
        h.modules.setEnabled(false, for: .typeInference)
        #expect(h.service.isReleased)
        tv.requestManual()
        // Back to ordinary completion (no import candidates).
        #expect(!tv.controller.currentCandidatesForTesting.contains { $0.source == .importedModule })
    }
}

// MARK: - Controller

/// A completion controller in a window, wired to an import harness.
@MainActor
private final class ImportControllerWindow {
    let textView = EditorTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    let window: NSWindow
    let hub = TextStorageObserverHub()
    let controller: CompletionController
    let harness: ImportHarness

    init(_ h: ImportHarness, _ text: String, language: String = "python", path: String) {
        harness = h
        let scroll = NSScrollView(frame: textView.frame)
        scroll.documentView = textView
        window = NSWindow(contentRect: textView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        textView.allowsUndo = true
        textView.isRichText = false
        textView.string = text
        textView.textStorage?.delegate = hub
        controller = CompletionController(textView: textView, moduleSettings: h.modules, moduleCenter: h.center,
                                          scheduler: AnalysisScheduler(), importService: h.service)
        controller.documentURLProvider = { URL(fileURLWithPath: path) }
        hub.add(controller)
        textView.completionKeyHandler = controller
        controller.setLanguage(identifier: language)
        controller.indexDocument()
        window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
    }

    func type(_ string: String) {
        for ch in string {
            let key = String(ch)
            textView.insertText(key, replacementRange: NSRange(location: NSNotFound, length: 0))
            controller.textViewDidInsertKey(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key,
                isARepeat: false, keyCode: 0)!)
        }
    }

    func requestManual() {
        controller.requestCompletion(manual: true)
        settle()
    }

    /// Lets queued listings / summaries arrive (the popup refreshes itself).
    func settle() {
        for _ in 0..<8 where harness.service.waitForImports() {}
    }

    var names: [String] { controller.currentCandidatesForTesting.map(\.name) }

    func pressReturn() -> Bool {
        controller.handleCompletionKeyDown(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36)!)
    }

    func close() {
        controller.dismissCompletion()
        textView.textStorage?.delegate = nil
        window.close()
    }
}

@MainActor
@Suite("T17.16 import statements in the editor", .serialized)
struct ImportCompletionControllerTests {
    @Test func typingOpensRefreshesAndAccepts() throws {
        let h = ImportHarness(projectRoot: ImportFixtures.python)
        let w = ImportControllerWindow(h, "timer_word = 1\n", path: ImportFixtures.python + "/main.py")
        defer { w.close() }
        w.type("import ti")
        w.settle()
        #expect(w.names.contains("time"))
        #expect(!w.names.contains("timer_word"))
        // The project's modules arrive from the queue and refresh the open popup.
        w.type("\nimport my")
        #expect(w.controller.isWaitingForImportsForTesting || w.names.contains("myapp"))
        w.settle()
        #expect(w.names.contains("myapp"))
        #expect(w.pressReturn())
        #expect(w.textView.string.hasSuffix("import myapp"))
        // `.` opens the package's submodules; typing filters; accept replaces the segment.
        w.type(".")
        w.settle()
        #expect(Set(w.names) == ["models", "services", "util", "sub"])
        w.type("se")
        #expect(w.names == ["services"])
        #expect(w.pressReturn())
        #expect(w.textView.string.hasSuffix("import myapp.services"))
        #expect(!w.controller.isInferenceStateReleased)
    }

    @Test func slashOpensAModuleDirectory() throws {
        let (root, cleanup) = project(scriptProject)
        defer { cleanup() }
        let h = ImportHarness(projectRoot: root, interpreter: nil)
        let w = ImportControllerWindow(h, "", language: "typescript", path: root + "/src/main.ts")
        defer { w.close() }
        w.type("import { u } from '.")
        #expect(!w.controller.isCompletionActive)
        w.type("/")
        w.settle()
        #expect(w.names.contains("util") && w.names.contains("models/"))
        w.type("ut")
        #expect(w.names == ["util"])
        #expect(w.pressReturn())
        #expect(w.textView.string.hasPrefix("import { u } from './util"))
        // A string that is not a specifier: no popup after `/`.
        let other = ImportControllerWindow(h, "const s = '.", language: "typescript", path: root + "/src/main.ts")
        defer { other.close() }
        other.type("/")
        other.settle()
        #expect(!other.controller.isCompletionActive)
    }
}
