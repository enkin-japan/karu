import AppKit
import Darwin
import Foundation
import Testing
@testable import KaruCore

// M17 T17.13 — import resolution against plan §13 「导入与跨文件」: resolution
// correctness on the fixtures, first-resolution latency (cold), summary
// memory for the fixture set and larger real sets, LRU behaviour at the cap.
// Opt-in, run alone, ideally in release:
//
//     KARU_TYPE_TABLES=$PWD/assets/typetables KARU_T1713_BENCH=1 \
//       swift test -c release -Xswiftc -enable-testing --filter ImportBenchmark
//
// Real sets are copied into a temporary directory first: a site-packages
// (`KARU_T1713_SITE`, default the uv-managed CPython 3.13's) as a fake
// interpreter's, and the TypeScript package (`KARU_T1713_TYPESCRIPT`) as a
// `node_modules` package. The report goes to `.build/m17-baseline/t1713-bench-<config>.txt`.

private let benchEnabled = ProcessInfo.processInfo.environment["KARU_T1713_BENCH"] == "1"

private func footprint() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Int(info.phys_footprint) : -1
}

private func ms(_ seconds: Double) -> String { String(format: "%.2f", seconds * 1000) }

private func percentile(_ values: [Double], _ p: Double) -> Double {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return 0 }
    return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p + 0.5))]
}

@MainActor
@Suite("T17.13 import benchmark", .enabled(if: benchEnabled))
struct ImportBenchmarkTests {
    /// (language, document path, source, expected member).
    static var cases: [(String, String, String, String)] {
        let py = ImportFixtures.python + "/main.py", deep = ImportFixtures.python + "/myapp/sub/probe.py"
        let ts = ImportFixtures.ts + "/src/main.ts", js = ImportFixtures.ts + "/src/probe.js"
        return [
            ("python", py, "import myapp\nmyapp.|", "User"),
            ("python", py, "from myapp import User\nUser(\"a\").|", "greet"),
            ("python", py, "from myapp import Admin\nAdmin(\"a\").|", "ban"),
            ("python", py, "from myapp.services import make_user\nmake_user(\"a\").|", "email"),
            ("python", py, "import myapp.util\nmyapp.util.|", "slugify"),
            ("python", deep, "from ..models import User\nUser(\"a\").|", "greet"),
            ("python", deep, "from . import deep\ndeep.find(\"x\").|", "name"),
            ("python", py, "from chain import Near\nNear().|", "close"),
            ("python", py, "import typedpkg\ntypedpkg.connect(\"u\").|", "get"),
            ("python", py, "import typedpkg\ntypedpkg.Client().get(\"u\").|", "status"),
            ("python", py, "from plainpkg import Engine\nEngine().|", "speed"),
            ("python", py, "from plainpkg import start_engine\nstart_engine().|", "stop"),
            ("python", py, "import shadowed\nshadowed.|", "FromProject"),
            ("python", py, "import venvonly\nvenvonly.|", "FromVenv"),
            ("python", py, "import interponly\ninterponly.|", "FromInterpreter"),
            ("python", py, "import stdextra\nstdextra.|", "from_stdlib_dir"),
            ("python", py, "import pthmod\npthmod.|", "FromPth"),
            ("python", py, "import json\njson.|", "dumps"),
            ("python", py, "import notapackage.inner\nnotapackage.inner.|", "namespaced"),
            ("typescript", ts, "import { User } from \"./models\";\nnew User(\"a\", 1).|", "greet"),
            ("typescript", ts, "import { User } from \"./models\";\nUser.|", "create"),
            ("typescript", ts, "import { Admin } from \"./models/admin\";\nnew Admin(\"a\", 1).|", "ban"),
            ("typescript", ts, "import * as util from \"./util\";\nutil.|", "SuperUser"),
            ("typescript", ts, "import type { Profile } from \"./models\";\nlet p: Profile;\np.|", "tags"),
            ("typescript", ts, "import { connect } from \"typed-lib\";\nconnect(\"u\").|", "request"),
            ("typescript", ts, "import { condMain } from \"cond-lib\";\ncondMain().|", "reason"),
            ("typescript", ts, "import { extraValue } from \"cond-lib/extra\";\nextraValue.|", "size"),
            ("typescript", ts, "import { fromTypes } from \"untyped-js\";\nfromTypes().|", "label"),
            ("typescript", ts, "import { Widget } from \"plain-js\";\nnew Widget().|", "render"),
            ("typescript", ts, "import { Scoped } from \"@scope/scoped\";\nnew Scoped().|", "hello"),
            ("javascript", js, "const legacy = require(\"./legacy\");\nlegacy.|", "legacyFn"),
            ("javascript", js, "const { Legacy } = require(\"./legacy\");\nnew Legacy().|", "run"),
            ("javascript", js, "const pj = require(\"plain-js\");\npj.makeWidget().|", "size"),
        ]
    }

    @Test func report() throws {
        var lines: [String] = []
        func log(_ s: String) { lines.append(s); print(s) }
        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        #if DEBUG
        let config = "debug"
        #else
        let config = "release"
        #endif
        log("T17.13 import benchmark (\(config), load \(String(format: "%.1f", loads[0])))")

        // 1. Correctness and cold first-resolution latency (a fresh service per case).
        var ok = 0, wall: [Double] = [], main: [Double] = [], rounds: [Int] = []
        for (language, path, source, expected) in Self.cases {
            let root = language == "python" ? ImportFixtures.python : ImportFixtures.ts
            let h = ImportHarness(projectRoot: root)
            let doc = h.document(source, language: language, path: path)
            let start = DispatchTime.now().uptimeNanoseconds
            var mainNs: UInt64 = 0
            var t = DispatchTime.now().uptimeNanoseconds
            var result = doc.request()
            mainNs += DispatchTime.now().uptimeNanoseconds - t
            var n = 0
            while doc.inference.lastRequestPendingImports, n < 12 {
                h.service.flush()
                h.service.queue.sync {}
                t = DispatchTime.now().uptimeNanoseconds
                h.service.applyInbox()
                result = doc.request()
                mainNs += DispatchTime.now().uptimeNanoseconds - t
                n += 1
            }
            wall.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
            main.append(Double(mainNs) / 1e9)
            rounds.append(n)
            if result?.contains(where: { $0.name == expected }) == true { ok += 1 } else { log("  MISS \(source.debugDescription)") }
        }
        log("resolution correctness: \(ok)/\(Self.cases.count)")
        log("first resolution (cold, request → members): p50 \(ms(percentile(wall, 0.5))) ms, p95 \(ms(percentile(wall, 0.95))) ms, "
            + "max \(ms(wall.max() ?? 0)) ms; main-thread part p50 \(ms(percentile(main, 0.5))) ms, max \(ms(main.max() ?? 0)) ms; "
            + "rounds max \(rounds.max() ?? 0)")

        // 2. The fixture set in one service.
        let before = footprint()
        let both = ImportHarness(projectRoot: ImportFixtures.python)
        for (language, path, source, _) in Self.cases {
            both.projectRoot = language == "python" ? ImportFixtures.python : ImportFixtures.ts
            _ = both.names(source, language: language, at: path)
        }
        let cache = both.service.cacheForTesting
        log("fixture set: \(cache.count) modules, summaries \(cache.bytes) B (≈\(cache.bytes / max(1, cache.count)) B each), "
            + "footprint Δ \((footprint() - before) / 1024) KB")

        // 3. Real sets.
        try realSitePackages(log)
        try realTypeScript(log)

        let dir = URL(fileURLWithPath: ImportFixtures.root).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/m17-baseline")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("t1713-bench-\(config).txt"),
                                                         atomically: true, encoding: .utf8)
    }

    /// Every module of a site-packages copy through path ③, unbounded and at the 8 MB cap.
    func realSitePackages(_ log: (String) -> Void) throws {
        let source = ProcessInfo.processInfo.environment["KARU_T1713_SITE"]
            ?? NSHomeDirectory() + "/.local/share/uv/python/cpython-3.13-macos-aarch64-none/lib/python3.13/site-packages"
        guard FileManager.default.fileExists(atPath: source) else { log("site-packages: \(source) not found, skipped"); return }
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("KaruImportBench-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let lib = base.appendingPathComponent("interp/lib/python3.13")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("interp/bin"), withIntermediateDirectories: true)
        try Data().write(to: base.appendingPathComponent("interp/bin/python3"))
        try FileManager.default.copyItem(atPath: source, toPath: lib.appendingPathComponent("site-packages").path)
        let site = SystemImportFileSystem().realPath(lib.appendingPathComponent("site-packages").path)
        var modules: [String] = []
        var bytes = 0
        let walker = FileManager.default.enumerator(atPath: site)
        while let relative = walker?.nextObject() as? String {
            guard relative.hasSuffix(".py") || relative.hasSuffix(".pyi"), !relative.contains(".dist-info"),
                  !relative.contains("-") else { continue }
            var dotted = String(relative.dropLast(relative.hasSuffix(".pyi") ? 4 : 3)).replacingOccurrences(of: "/", with: ".")
            if dotted.hasSuffix(".__init__") { dotted = String(dotted.dropLast(9)) }
            guard !dotted.contains(" "), !modules.contains(dotted) else { continue }
            modules.append(dotted)
            bytes += (try? FileManager.default.attributesOfItem(atPath: site + "/" + relative)[.size] as? Int) ?? 0
        }
        log("site-packages copy: \(modules.count) modules, \(bytes / 1024) KB of source")
        for (label, limit) in [("unbounded", Int.max / 4), ("8 MB cap", ImportService.summaryByteLimit),
                               ("2 MB cap (LRU behaviour)", 2 * 1024 * 1024)] {
            let interpreter = SystemImportFileSystem().realPath(base.appendingPathComponent("interp/bin/python3").path)
            let h = ImportHarness(projectRoot: nil, interpreter: interpreter, byteLimit: limit)
            let scope = h.service.scope(forDocument: nil)
            let before = footprint()
            let start = DispatchTime.now().uptimeNanoseconds
            for dotted in modules { _ = scope.pythonKey(dotted) }
            h.service.waitForImports(rounds: 2)
            let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            let cache = h.service.cacheForTesting
            let namesOnly = cache.allKeys.filter { cache.peek($0)?.isNamesOnly == true }.count
            log("site-packages \(label): \(cache.count) summaries, \(cache.bytes / 1024) KB (\(namesOnly) names-only, "
                + "\(cache.degradations) reduced, \(cache.evictions) evicted), \(h.service.statistics.missingModules) not found, "
                + "\(ms(seconds / Double(max(1, modules.count)))) ms/module, footprint Δ \((footprint() - before) / 1024) KB")
        }
    }

    /// The TypeScript package as a `node_modules` package.
    func realTypeScript(_ log: (String) -> Void) throws {
        let source = ProcessInfo.processInfo.environment["KARU_T1713_TYPESCRIPT"]
            ?? "/Volumes/enkin/project-support/KaruM17-TypeSources/typescript-6.0.3/package"
        guard FileManager.default.fileExists(atPath: source + "/package.json") else {
            log("typescript: \(source) not found, skipped")
            return
        }
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("KaruImportBench-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let package = base.appendingPathComponent("project/node_modules/typescript")
        try FileManager.default.createDirectory(at: package.appendingPathComponent("lib"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: source + "/package.json", toPath: package.appendingPathComponent("package.json").path)
        for file in try FileManager.default.contentsOfDirectory(atPath: source + "/lib") where file.hasSuffix(".d.ts") {
            try FileManager.default.copyItem(atPath: source + "/lib/" + file, toPath: package.appendingPathComponent("lib/" + file).path)
        }
        let root = SystemImportFileSystem().realPath(base.appendingPathComponent("project").path)
        for (label, moduleLimit) in [("per-module cap 2 MB", ImportService.moduleByteLimit), ("per-module cap 1 MB", 1 << 20)] {
            let h = ImportHarness(projectRoot: root, interpreter: nil, byteLimit: Int.max / 4, moduleByteLimit: moduleLimit)
            let before = footprint()
            let start = DispatchTime.now().uptimeNanoseconds
            let names = h.names("import * as ts from \"typescript\";\nts.|", language: "typescript", at: root + "/main.ts") ?? []
            let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            let factory = h.names("import * as ts from \"typescript\";\nts.createSourceFile(\"a\", \"\", ts.ScriptTarget.Latest).|",
                                  language: "typescript", at: root + "/main.ts") ?? []
            let cache = h.service.cacheForTesting
            let key = cache.allKeys.first { $0.hasSuffix("typescript.d.ts") }
            log("typescript (\(label)): \(names.count) members of `ts.`, SourceFile members \(factory.count), "
                + "summary \(cache.bytes / 1024) KB, names-only \(key.flatMap { cache.peek($0)?.isNamesOnly } ?? false), "
                + "first resolution \(ms(seconds)) ms, footprint Δ \((footprint() - before) / 1024) KB")
        }
    }
}
