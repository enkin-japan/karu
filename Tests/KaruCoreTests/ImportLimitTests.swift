import Foundation
import Testing
@testable import KaruCore

// R08 / R09 — the import-resolution subsystem respects its limits at the
// entrance: the summary cache never ends an `insert` over its byte / entry
// budget (the newest entry included), a rejected module is not re-read until
// its file changes, source files over the hard read limit and manifests /
// `.pth` / config files over 1 MB are never read, and directory listings stop
// enumerating at `directoryScanLimit`. Everything reads temporary
// directories or test doubles only.

/// A temporary directory with `files` (real path).
private func temporaryTree(_ files: [String: Data]) -> (path: String, cleanup: () -> Void) {
    let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("KaruImportLimitTests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    for (relative, data) in files {
        let url = base.appendingPathComponent(relative)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! data.write(to: url)
    }
    return (SystemImportFileSystem().realPath(base.path), { try? FileManager.default.removeItem(at: base) })
}

private func text(_ s: String) -> Data { Data(s.utf8) }

/// Python source of `count` typed functions.
private func pythonSource(functions count: Int) -> String {
    var out = ""
    for k in 0..<count { out += "def function_\(k)(value: int, other: str) -> int:\n    return value\n\n" }
    return out
}

/// A full (typed) Python module summary of `functions` functions.
private func pythonModule(functions: Int, name: String = "m") -> ImportedModule {
    let context = PythonSummaryContext(dotted: name, isPackage: false, isStub: false, keyPrefix: "§0:",
                                       isStdlib: { _ in false })
    let summary = PythonModuleSummarizer.summarize(pythonSource(functions: functions) as NSString, context: context,
                                                   namesOnly: false)
    return ImportedModule(content: .python(summary), sourcePath: "/nonexistent/\(name).py",
                          validators: ["/nonexistent/\(name).py": 1], isProjectFile: false)
}

/// A listing module (already names-only) of `count` entries.
private func listingModule(entries count: Int) -> ImportedModule {
    let entries = (0..<count).map { ImportListing.Entry(name: "listed_entry_name_\($0)", isPackage: $0 % 3 == 0) }
    return ImportedModule(content: .listing(ImportListing(entries: entries)), sourcePath: nil, validators: [:],
                          isProjectFile: false)
}

/// Deterministic generator (SplitMix64) for the randomized sequences.
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

// MARK: - R08: the summary cache

@MainActor
@Suite("R08 import summary cache limits")
struct ImportSummaryCacheLimitTests {
    private func expectWithinLimits(_ cache: ImportSummaryCache, _ note: String = "",
                                    sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(cache.bytes <= cache.byteLimit && cache.count <= cache.countLimit,
                "bytes \(cache.bytes)/\(cache.byteLimit), count \(cache.count)/\(cache.countLimit) \(note)",
                sourceLocation: sourceLocation)
    }

    @Test func newestOverTheBudgetIsStoredNamesOnly() throws {
        let module = pythonModule(functions: 200)
        let full = module.approximateBytes
        let names = module.reducedToNames().approximateBytes
        #expect(names < full)
        // Over the budget in full, within it as names; no module cap applies.
        let cache = ImportSummaryCache(byteLimit: (full + names) / 2, moduleByteLimit: full * 2)
        #expect(cache.insert(module, for: "big"))
        let stored = try #require(cache.peek("big"))
        #expect(stored.isNamesOnly)
        #expect(cache.bytes == names && cache.bytes <= cache.byteLimit)
        #expect(cache.degradations == 1 && cache.rejections == 0 && cache.evictions == 0)
    }

    @Test func newestOverTheBudgetEvenAsNamesIsRejected() {
        let small = listingModule(entries: 2)
        let module = pythonModule(functions: 200)
        let names = module.reducedToNames().approximateBytes
        let cache = ImportSummaryCache(byteLimit: names - 1, moduleByteLimit: Int.max)
        #expect(cache.insert(small, for: "small"))
        #expect(!cache.insert(module, for: "big"))
        #expect(!cache.contains("big"))
        #expect(cache.rejections == 1)
        #expect(cache.bytes <= cache.byteLimit)
        // Already names-only (a listing) and still too large: rejected without a degradation.
        let listing = listingModule(entries: 5_000)
        let degradations = cache.degradations
        #expect(!cache.insert(listing, for: "listing"))
        #expect(cache.rejections == 2 && cache.degradations == degradations)
        #expect(cache.bytes <= cache.byteLimit)
        // A rejected insert under an existing key drops the older entry too.
        #expect(cache.insert(small, for: "k"))
        #expect(!cache.insert(module, for: "k"))
        #expect(!cache.contains("k"))
        #expect(cache.bytes <= cache.byteLimit)
    }

    @Test func tinyBudgetsHoldAfterEveryInsert() {
        let pool = [listingModule(entries: 0), listingModule(entries: 40), pythonModule(functions: 1),
                    pythonModule(functions: 30)]
        for (byteLimit, countLimit) in [(1, 4_096), (0, 4_096), (Int.max, 0), (1, 1), (pool[0].approximateBytes, 1)] {
            let cache = ImportSummaryCache(byteLimit: byteLimit, moduleByteLimit: 1, countLimit: countLimit)
            for (k, module) in (pool + pool).enumerated() {
                let stored = cache.insert(module, for: "k\(k % 3)")
                #expect(stored == cache.contains("k\(k % 3)"))
                expectWithinLimits(cache, "limit \(byteLimit), count \(countLimit), insert \(k)")
            }
        }
    }

    @Test func randomizedSequencesHoldAfterEveryInsert() {
        let pool = [listingModule(entries: 1), listingModule(entries: 60), listingModule(entries: 400),
                    pythonModule(functions: 1), pythonModule(functions: 8), pythonModule(functions: 40),
                    pythonModule(functions: 160)]
        let largest = pool.map(\.approximateBytes).max()!
        var inserts = 0, rejected = 0
        for seed in UInt64(1)...24 {
            var rng = SeededGenerator(state: seed)
            let byteLimit = Int.random(in: 1...(largest * 3), using: &rng)
            let moduleLimit = Int.random(in: 1...(largest * 2), using: &rng)
            let countLimit = Int.random(in: 1...8, using: &rng)
            let cache = ImportSummaryCache(byteLimit: byteLimit, moduleByteLimit: moduleLimit, countLimit: countLimit)
            for step in 0..<400 {
                let key = "k\(Int.random(in: 0..<12, using: &rng))"
                switch Int.random(in: 0..<10, using: &rng) {
                case 0..<6:
                    let module = pool.randomElement(using: &rng)!
                    let stored = cache.insert(module, for: key)
                    inserts += 1
                    if !stored { rejected += 1 }
                    #expect(stored == cache.contains(key))
                    expectWithinLimits(cache, "seed \(seed) step \(step)")
                case 6..<8:
                    _ = cache.module(key)
                case 8:
                    cache.beginBatch()
                default:
                    cache.remove(key)
                }
            }
            expectWithinLimits(cache, "seed \(seed) end")
        }
        #expect(inserts > 0 && rejected > 0)   // the sequences exercise the rejection path
    }
}

// MARK: - R08 / R09 through the service

@MainActor
@Suite("R08/R09 import service limits")
struct ImportServiceLimitTests {
    @Test func rejectedModuleIsReadOnceUntilItsFileChanges() throws {
        let (root, cleanup) = temporaryTree(["big.py": text(pythonSource(functions: 300)), "main.py": text("\n")])
        defer { cleanup() }
        let big = root + "/big.py"
        let main = root + "/main.py"
        // Revalidated on every request: only mtime checks repeat, not reads.
        let h = ImportHarness(projectRoot: root, interpreter: nil, byteLimit: 4_096, revalidation: 0)
        let source = "import big\nbig.|"
        #expect(h.names(source, at: main) == nil)
        #expect(h.service.cacheForTesting.rejections == 1)
        #expect(h.service.statistics.rejectedModules == 1)
        #expect(h.fs.read.filter { $0 == big }.count == 1)
        for _ in 0..<4 {
            #expect(h.names(source, at: main) == nil)
            h.service.waitForImports()
        }
        #expect(h.fs.read.filter { $0 == big }.count == 1)
        #expect(h.service.statistics.rejectedModules == 1)
        #expect(h.service.cacheForTesting.bytes <= 4_096)
        // Edited and smaller: read again and kept.
        try Data("def tiny() -> int:\n    return 1\n".utf8).write(to: URL(fileURLWithPath: big))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(30)], ofItemAtPath: big)
        _ = h.document(source, path: main).request()
        h.service.waitForImports()
        #expect(h.names(source, at: main)?.contains("tiny") == true)
        #expect(h.fs.read.filter { $0 == big }.count == 2)
        #expect(h.service.statistics.rejectedModules == 1)
    }

    @Test func sourceOverTheReadLimitIsNeverRead() throws {
        let limit = 4_096
        var py = pythonSource(functions: 1)
        while py.utf8.count <= limit { py += "def more_\(py.utf8.count)() -> int:\n    return 1\n\n" }
        var ts = "export function first(): number { return 1; }\n"
        while ts.utf8.count <= limit { ts += "export const c\(ts.utf8.count) = 1;\n" }
        let (root, cleanup) = temporaryTree(["big.py": text(py), "main.py": text("\n"), "src/big.ts": text(ts),
                                             "src/main.ts": text("\n")])
        defer { cleanup() }
        let h = ImportHarness(projectRoot: root, interpreter: nil, revalidation: 60, readByteLimit: limit)
        let main = root + "/main.py"
        let source = "import big\nbig.|"
        #expect(h.names(source, at: main) == nil)
        #expect(h.service.statistics.oversizedFiles == 1)
        #expect(h.service.statistics.missingModules == 1)
        let statted = h.fs.statted.count, touched = h.fs.touched.count, jobs = h.service.statistics.jobs
        for _ in 0..<5 {
            #expect(h.names(source, at: main) == nil)
            h.service.waitForImports()
        }
        // A stable answer: no reads, no lookups, no jobs on repeated requests.
        #expect(!h.fs.read.contains(root + "/big.py"))
        #expect(h.fs.statted.count == statted && h.fs.touched.count == touched)
        #expect(h.service.statistics.jobs == jobs)
        #expect(h.service.statistics.oversizedFiles == 1)
        // JS / TS: the same.
        let tsSource = "import * as b from \"./big\";\nb.|"
        #expect(h.names(tsSource, language: "typescript", at: root + "/src/main.ts") == nil)
        #expect(!h.fs.read.contains(root + "/src/big.ts"))
        #expect(h.service.statistics.oversizedFiles == 2)
        _ = h.names(tsSource, language: "typescript", at: root + "/src/main.ts")
        h.service.waitForImports()
        #expect(h.service.statistics.oversizedFiles == 2)
    }

    @Test func sourceAtTheReadLimitIsReadAsBefore() throws {
        let limit = 4_096
        var py = "class Kept:\n    def method(self) -> int:\n        return 1\n\n"
        while py.utf8.count < limit - 40 { py += "# padding \(py.utf8.count)\n" }
        py += String(repeating: "#", count: limit - py.utf8.count - 1) + "\n"
        #expect(py.utf8.count == limit)
        let (root, cleanup) = temporaryTree(["kept.py": text(py), "main.py": text("\n")])
        defer { cleanup() }
        let h = ImportHarness(projectRoot: root, interpreter: nil, readByteLimit: limit)
        let names = try #require(h.names("import kept\nkept.Kept().|", at: root + "/main.py"))
        #expect(names.contains("method"))
        #expect(h.fs.read.filter { $0 == root + "/kept.py" }.count == 1)
        #expect(h.service.statistics.oversizedFiles == 0)
    }

    @Test func readLimitDefaults() {
        #expect(ImportService.readByteLimit == 8 * 1024 * 1024)
        #expect(ImportService.readByteLimit == 4 * ImportService.moduleByteLimit)
        #expect(ImportService.Configuration(projectFolder: { _ in nil }, interpreter: { .none }).readByteLimit
                == ImportService.readByteLimit)
        #expect(ImportWorker.directoryScanLimit == 20_000 && ImportWorker.directoryEntryLimit == 2_000)
        #expect(ScriptModuleLocator.manifestByteLimit == 1 << 20 && PythonSearchPaths.configByteLimit == 1 << 20)
    }
}

// MARK: - R09: manifests, `.pth` and config files

@Suite("R09 small-file read limits")
struct ImportSmallFileLimitTests {
    private static let overOneMegabyte = (1 << 20) + 16

    @Test func largePackageJSONIsNotRead() {
        let pad = String(repeating: "x", count: Self.overOneMegabyte)
        let (root, cleanup) = temporaryTree([
            "node_modules/big/package.json": text("{\"types\": \"typed.d.ts\", \"pad\": \"\(pad)\"}"),
            "node_modules/big/typed.d.ts": text("export const typed: number;\n"),
            "node_modules/big/index.d.ts": text("export const index: number;\n"),
            "node_modules/small/package.json": text("{\"types\": \"typed.d.ts\"}"),
            "node_modules/small/typed.d.ts": text("export const typed: number;\n"),
            "node_modules/small/index.d.ts": text("export const index: number;\n"),
            "main.ts": text("\n"),
        ])
        defer { cleanup() }
        let fs = RecordingFileSystem()
        let big = ScriptModuleLocator.resolve("big", from: root + "/main.ts", projectRoot: root, fs: fs)
        #expect(big.map(ImportPath.normalized) == ImportPath.normalized(root + "/node_modules/big/index.d.ts"))      // the manifest ignored
        #expect(!fs.read.contains(root + "/node_modules/big/package.json"))
        let small = ScriptModuleLocator.resolve("small", from: root + "/main.ts", projectRoot: root, fs: fs)
        #expect(small.map(ImportPath.normalized) == ImportPath.normalized(root + "/node_modules/small/typed.d.ts"))
        #expect(fs.read.contains(root + "/node_modules/small/package.json"))
    }

    @Test func largePthAndConfigFilesAreNotRead() throws {
        let (root, cleanup) = temporaryTree([
            "site/fromsmall/__init__.py": text("\n"),
            "site/frombig/__init__.py": text("\n"),
            "venv/pyvenv.cfg": text("version_info = 3.13\n# " + String(repeating: "x", count: Self.overOneMegabyte) + "\n"),
            "okvenv/pyvenv.cfg": text("version_info = 3.13\n"),
        ])
        defer { cleanup() }
        let site = root + "/site"
        try Data((root + "/site/fromsmall\n").utf8).write(to: URL(fileURLWithPath: site + "/a_small.pth"))
        try Data((root + "/site/frombig\n# " + String(repeating: "y", count: Self.overOneMegabyte) + "\n").utf8)
            .write(to: URL(fileURLWithPath: site + "/b_big.pth"))
        let fs = RecordingFileSystem()
        var paths = PythonSearchPaths()
        paths.addSitePackages(site, kind: .venv, allowedRoots: [root], fs: fs)
        let roots = paths.roots.map { ImportPath.normalized($0.path) }
        #expect(roots.contains(ImportPath.normalized(root + "/site/fromsmall")))
        #expect(!roots.contains(ImportPath.normalized(root + "/site/frombig")))
        #expect(fs.read.contains(site + "/a_small.pth"))
        #expect(!fs.read.contains(site + "/b_big.pth"))
        #expect(PythonSearchPaths.readConfig(root + "/venv/pyvenv.cfg", fs) == nil)
        #expect(!fs.read.contains(root + "/venv/pyvenv.cfg"))
        #expect(PythonSearchPaths.readConfig(root + "/okvenv/pyvenv.cfg", fs)?["version_info"] == "3.13")
    }
}

// MARK: - R09: bounded directory listings

/// One synthetic directory of `count` `.py` entries (enumerated in reverse
/// name order); counts how many entries were pulled from it.
private final class SyntheticDirectory: ImportFileSystem, @unchecked Sendable {
    let directory: String
    let count: Int
    private let lock = NSLock()
    private var pulledEntries = 0
    private var fullListings = 0

    init(_ directory: String, count: Int) {
        self.directory = directory
        self.count = count
    }

    var pulled: Int { lock.lock(); defer { lock.unlock() }; return pulledEntries }
    var unboundedListings: Int { lock.lock(); defer { lock.unlock() }; return fullListings }

    func name(_ i: Int) -> String { String(format: "m%05d.py", count - 1 - i) }

    func info(_ path: String) -> ImportFileInfo? {
        path == directory ? ImportFileInfo(isDirectory: true, size: 0, modificationTime: 1) : nil
    }

    func contents(_ path: String) -> Data? { nil }

    func list(_ path: String) -> [String]? {
        guard path == directory else { return nil }
        lock.lock(); fullListings += 1; pulledEntries += count; lock.unlock()
        return (0..<count).map(name)
    }

    func list(_ path: String, limit: Int) -> (names: [String], truncated: Bool)? {
        guard path == directory else { return nil }
        var names: [String] = []
        for i in 0..<count {
            lock.lock(); pulledEntries += 1; lock.unlock()
            if names.count >= limit { return (names, true) }
            names.append(name(i))
        }
        return (names, false)
    }

    func realPath(_ path: String) -> String { path }
}

@Suite("R09 bounded directory listings")
struct ImportDirectoryLimitTests {
    private func snapshot(root: String) -> ImportContextSnapshot {
        ImportContextSnapshot(id: 990_001, prefix: "§990001:", projectRoot: root, venv: nil, interpreter: .none)
    }

    private func listing(_ module: ImportedModule) throws -> ImportListing {
        guard case .listing(let listing) = module.content else { throw CancellationError() }
        return listing
    }

    /// What the listing was before R09: the whole directory, sorted, capped.
    private func unboundedStems(_ fs: SyntheticDirectory) -> [String] {
        Array(fs.list(fs.directory)!.sorted().prefix(ImportWorker.directoryEntryLimit)).map { String($0.dropLast(3)) }
    }

    @Test func hugeDirectoryIsEnumeratedOnlyUpToTheScanLimit() throws {
        let fs = SyntheticDirectory("/synthetic/huge", count: 50_000)
        let worker = ImportWorker(fs: fs, isStdlib: { _ in false })
        let result = try listing(worker.list(.pythonProjectTop, context: snapshot(root: fs.directory)))
        #expect(fs.pulled <= ImportWorker.directoryScanLimit + 1)
        #expect(fs.unboundedListings == 0)
        #expect(result.entries.count == ImportWorker.directoryEntryLimit)
        #expect(result.truncated)
        // The first 20 000 enumerated (m49999 … m30000), sorted, capped.
        #expect(result.entries.first?.name == "m30000" && result.entries.last?.name == "m31999")
    }

    @Test func smallAndMidSizedDirectoriesListAsBefore() throws {
        for (count, truncated) in [(100, false), (2_000, false), (2_500, true)] {
            let fs = SyntheticDirectory("/synthetic/dir\(count)", count: count)
            let worker = ImportWorker(fs: fs, isStdlib: { _ in false })
            let result = try listing(worker.list(.pythonProjectTop, context: snapshot(root: fs.directory)))
            #expect(result.entries.map(\.name) == unboundedStems(fs), "\(count) entries")
            #expect(result.entries.allSatisfy { !$0.isPackage })
            #expect(result.truncated == truncated, "\(count) entries")
        }
    }

    @Test func realDirectoryListsAsBefore() throws {
        var files: [String: Data] = [:]
        for k in 0..<90 { files["f\(k).ts"] = text("\n") }
        for k in 0..<10 { files["dir\(k)/index.ts"] = text("\n") }
        let (root, cleanup) = temporaryTree(files)
        defer { cleanup() }
        let fs = SystemImportFileSystem()
        let worker = ImportWorker(fs: fs, isStdlib: { _ in false })
        let result = try listing(worker.list(.scriptDirectory(root), context: snapshot(root: root)))
        let expected = try FileManager.default.contentsOfDirectory(atPath: root).sorted().map { name in
            ImportListing.Entry(name: name.hasPrefix("dir") ? name : ImportService.scriptStem(name),
                                isPackage: name.hasPrefix("dir"))
        }
        #expect(result.entries == expected)
        #expect(result.entries.count == 100)
        #expect(!result.truncated)
    }

    @Test func systemListingStopsAtTheLimit() throws {
        var files: [String: Data] = [:]
        for k in 0..<25 { files["file\(k).txt"] = text("") }
        files["sub/inner.txt"] = text("")
        let (root, cleanup) = temporaryTree(files)
        defer { cleanup() }
        let fs = SystemImportFileSystem()
        let all = Set(try FileManager.default.contentsOfDirectory(atPath: root))
        #expect(all.count == 26)
        let cut = try #require(fs.list(root, limit: 10))
        #expect(cut.names.count == 10 && cut.truncated)
        #expect(Set(cut.names).isSubset(of: all) && Set(cut.names).count == 10)
        #expect(!cut.names.contains(".") && !cut.names.contains(".."))
        let exact = try #require(fs.list(root, limit: 26))
        #expect(Set(exact.names) == all && exact.names.count == 26 && !exact.truncated)
        let roomy = try #require(fs.list(root, limit: 1_000))
        #expect(Set(roomy.names) == all && !roomy.truncated)
        let none = try #require(fs.list(root, limit: 0))
        #expect(none.names.isEmpty && none.truncated)
        #expect(fs.list(root + "/missing", limit: 10) == nil)
        #expect(fs.list(root + "/file0.txt", limit: 10) == nil)
        // The default (protocol extension) agrees for doubles built on `list(_:)`.
        let empty = try #require(fs.list(root + "/sub", limit: 10))
        #expect(empty.names == ["inner.txt"] && !empty.truncated)
    }

    @Test func defaultBoundedListingBuildsOnTheFullOne() throws {
        let fs = SyntheticDirectory("/synthetic/default", count: 30)
        struct Plain: ImportFileSystem {
            let base: SyntheticDirectory
            func info(_ path: String) -> ImportFileInfo? { base.info(path) }
            func contents(_ path: String) -> Data? { nil }
            func list(_ path: String) -> [String]? { base.list(path) }
            func realPath(_ path: String) -> String { path }
        }
        let plain = Plain(base: fs)
        let cut = try #require(plain.list(fs.directory, limit: 10))
        #expect(cut.names == (0..<10).map(fs.name) && cut.truncated)
        let whole = try #require(plain.list(fs.directory, limit: 30))
        #expect(whole.names.count == 30 && !whole.truncated)
        #expect(plain.list("/elsewhere", limit: 10) == nil)
    }
}
