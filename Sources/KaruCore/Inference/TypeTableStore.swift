import Foundation

/// Built-in type tables for inference (M17 T17.10, plan §8.2 "T17.10 接口").
///
/// - `python-stdlib.ktt`: typeshed `stdlib/` evaluated for Python 3.13 / darwin,
///   one entry per module.
/// - `typescript-lib.ktt`: TypeScript lib.es5 … esnext (ES section) and
///   lib.dom* (DOM section), one entry per global symbol (qualified names for
///   namespace members).
///
/// Nothing happens at init. The first query of a language maps its file
/// (read-only `mmap`); each query decodes only the one module / symbol it
/// needs, and the decoded value is kept in an LRU bounded by an approximate
/// byte cost (counts toward plan §11 item ②). `release()` drops the cache and
/// unmaps the files (closing the completion module). Thread-safe.
public final class TypeTableStore: @unchecked Sendable {
    public static let pythonFileName = "python-stdlib.ktt"
    public static let typeScriptFileName = "typescript-lib.ktt"
    public static let defaultCacheByteLimit = 4 * 1024 * 1024

    /// Process-wide store used by the editor.
    public static let shared = TypeTableStore()

    /// Counters for tests and measurements.
    public struct Statistics: Sendable, Equatable {
        /// Files currently mapped.
        public var mappedFiles = 0
        /// Blobs decoded since init (cache misses that found an entry).
        public var decodedEntries = 0
        /// Index searches per TypeScript section.
        public var esSectionLookups = 0
        public var domSectionLookups = 0
        /// Current LRU contents.
        public var cachedEntries = 0
        public var cachedBytes = 0
        public var evictions = 0
    }

    private enum Key: Hashable {
        case python(String)
        case ts(TSGlobalSymbol.Section, String)
    }
    private enum Value {
        case python(PythonModuleStub)
        case ts(TSGlobalSymbol)
        case missing
    }
    private struct Slot {
        var value: Value
        var cost: Int
        var tick: UInt64
    }

    private let lock = NSLock()
    private let directories: [URL]
    public let cacheByteLimit: Int
    private var python: MappedTypeTable?
    private var typeScript: MappedTypeTable?
    private var cache: [Key: Slot] = [:]
    private var tick: UInt64 = 0
    private var stats = Statistics()

    /// - Parameters:
    ///   - directory: look only here (tests); nil uses `searchDirectories()`.
    ///   - cacheByteLimit: approximate decoded bytes kept in the LRU.
    public init(directory: URL? = nil, cacheByteLimit: Int = TypeTableStore.defaultCacheByteLimit) {
        self.directories = directory.map { [$0] } ?? Self.searchDirectories()
        self.cacheByteLimit = cacheByteLimit
    }

    /// Lookup order: the app bundle's `Contents/Resources/TypeTables/`, then
    /// `$KARU_TYPE_TABLES`, then the repository's `assets/typetables/` —
    /// derived from the executable's location (an unbundled `.build/*/KaruApp`)
    /// and, in debug builds only, from this source file's path (tests).
    public static func searchDirectories() -> [URL] {
        var dirs: [URL] = []
        if let resources = Bundle.main.resourceURL {
            dirs.append(resources.appendingPathComponent("TypeTables", isDirectory: true))
        }
        if let env = ProcessInfo.processInfo.environment["KARU_TYPE_TABLES"], !env.isEmpty {
            dirs.append(URL(fileURLWithPath: env, isDirectory: true))
        }
        // An unbundled SwiftPM product (`<repo>/.build/<config>/KaruApp`, as
        // visual-smoke and mem-benchmark run it): the repository from the
        // executable's own location, computed at run time.
        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            let repo = executable.deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
            dirs.append(repo.appendingPathComponent("assets/typetables", isDirectory: true))
        }
        #if DEBUG
        // Development and tests: the repository from this source file's path.
        // Debug only, so no build-machine path is compiled into a release.
        let repo = URL(fileURLWithPath: #filePath)   // Sources/KaruCore/Inference/TypeTableStore.swift
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        dirs.append(repo.appendingPathComponent("assets/typetables", isDirectory: true))
        #endif
        return dirs
    }

    /// The first directory that has `fileName`, or nil.
    public func locate(_ fileName: String) -> URL? {
        for dir in directories {
            let url = dir.appendingPathComponent(fileName)
            if FileManager.default.isReadableFile(atPath: url.path) { return url }
        }
        return nil
    }

    public var statistics: Statistics {
        lock.lock(); defer { lock.unlock() }
        var s = stats
        s.mappedFiles = (python == nil ? 0 : 1) + (typeScript == nil ? 0 : 1)
        s.cachedEntries = cache.count
        s.cachedBytes = cache.values.reduce(0) { $0 + $1.cost }
        return s
    }

    /// Drops every decoded entry and unmaps the files. The next query maps
    /// again. Counters other than the cache totals are kept.
    public func release() {
        lock.lock(); defer { lock.unlock() }
        cache.removeAll()
        python = nil
        typeScript = nil
    }

    // MARK: - Python

    /// Decoded stub of module `name` (`"os.path"`), or nil when the table has
    /// no such module (or the table is unavailable).
    public func pythonModule(_ name: String) -> PythonModuleStub? {
        lock.lock(); defer { lock.unlock() }
        if case .python(let stub)? = cached(.python(name)) { return stub }
        if case .missing? = cache[.python(name)]?.value { return nil }
        guard let table = pythonTable(), let section = table.section(id: 1) else { return nil }
        guard let index = table.find(section, name: name), let entry = table.indexEntry(section, index) else {
            store(.python(name), .missing, cost: 64)
            return nil
        }
        var decoder = TypeTableDecoder(table: table, section: section, blob: entry.blob)
        guard let stub = try? decoder.pythonModule(name: name) else { return nil }
        stats.decodedEntries += 1
        store(.python(name), .python(stub), cost: decoder.cost)
        return stub
    }

    /// Whether the table has module `name`, without decoding it.
    public func hasPythonModule(_ name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if case .python? = cache[.python(name)]?.value { return true }
        guard let table = pythonTable(), let section = table.section(id: 1) else { return false }
        return table.find(section, name: name) != nil
    }

    /// All module names, sorted (allocates; for listings and tests).
    public func pythonModuleNames() -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard let table = pythonTable(), let section = table.section(id: 1) else { return [] }
        return table.names(section)
    }

    /// What a module-level name refers to after following imports.
    public enum PythonSymbol: Hashable, Sendable {
        case module(String)
        case `class`(module: String, TypeTable.ClassDecl)
        case function(module: String, TypeTable.Function)
        case variable(module: String, TypeTable.Variable)
        case alias(module: String, TypeTable.Alias)
        case typeVar(module: String, TypeTable.TypeParameter)
    }

    /// Resolves `name` in `module`: own definitions first, then imports
    /// (`from x import y`, `import x as y`), star imports (honouring the
    /// source's `__all__`), then submodules. Follows at most 8 hops.
    public func pythonResolve(module: String, name: String) -> PythonSymbol? {
        resolve(module: module, name: name, depth: 0)
    }

    /// Resolves a dotted path such as `"os.path.join"` or
    /// `"collections.abc.Mapping"`: the longest module prefix, then names.
    public func pythonResolve(dotted path: String) -> PythonSymbol? {
        let parts = path.split(separator: ".").map(String.init)
        guard !parts.isEmpty else { return nil }
        var moduleEnd = 0
        for i in stride(from: parts.count, through: 1, by: -1) where hasPythonModule(parts[0..<i].joined(separator: ".")) {
            moduleEnd = i
            break
        }
        guard moduleEnd > 0 else { return nil }
        var current = PythonSymbol.module(parts[0..<moduleEnd].joined(separator: "."))
        for part in parts[moduleEnd...] {
            guard case .module(let m) = current, let next = pythonResolve(module: m, name: part) else { return nil }
            current = next
        }
        return current
    }

    private func resolve(module: String, name: String, depth: Int) -> PythonSymbol? {
        guard depth < 8, let stub = pythonModule(module) else { return nil }
        if let c = stub.class(named: name) { return .class(module: module, c) }
        if let f = stub.function(named: name) { return .function(module: module, f) }
        if let a = stub.alias(named: name) { return .alias(module: module, a) }
        if let v = stub.variable(named: name) { return .variable(module: module, v) }
        if let t = stub.typeVar(named: name) { return .typeVar(module: module, t) }
        if let imp = stub.import(named: name) {
            guard let original = imp.originalName else { return hasPythonModule(imp.module) ? .module(imp.module) : nil }
            if let found = resolve(module: imp.module, name: original, depth: depth + 1) { return found }
            let sub = imp.module + "." + original
            return hasPythonModule(sub) ? .module(sub) : nil
        }
        for star in stub.starImports {
            guard let source = pythonModule(star) else { continue }
            let exported = source.all.map { $0.contains(name) } ?? !name.hasPrefix("_")
            if exported, let found = resolve(module: star, name: name, depth: depth + 1) { return found }
        }
        let sub = module + "." + name
        return hasPythonModule(sub) ? .module(sub) : nil
    }

    // MARK: - TypeScript

    /// Global symbol `name` (`"Array"`, `"Intl.DateTimeFormat"`). The ES
    /// section is searched first; the DOM section only when the name is not an
    /// ES symbol (or is an ES symbol the DOM augments) and `includeDOM` is set.
    /// For `ImportMeta` the ES symbol is returned; ask `tsSymbol(_:in: .dom)`
    /// for the DOM part.
    public func tsSymbol(_ name: String, includeDOM: Bool = true) -> TSGlobalSymbol? {
        if let es = tsSymbol(name, in: .es) { return es }
        return includeDOM ? tsSymbol(name, in: .dom) : nil
    }

    /// Symbol `name` from one section only.
    public func tsSymbol(_ name: String, in section: TSGlobalSymbol.Section) -> TSGlobalSymbol? {
        lock.lock(); defer { lock.unlock() }
        let key = Key.ts(section, name)
        if case .ts(let symbol)? = cached(key) { return symbol }
        if case .missing? = cache[key]?.value { return nil }
        guard let table = tsTable(), let sec = table.section(id: section == .es ? 2 : 3) else { return nil }
        if section == .es { stats.esSectionLookups += 1 } else { stats.domSectionLookups += 1 }
        guard let index = table.find(sec, name: name), let entry = table.indexEntry(sec, index) else {
            store(key, .missing, cost: 64)
            return nil
        }
        var decoder = TypeTableDecoder(table: table, section: sec, blob: entry.blob)
        guard let symbol = try? decoder.tsSymbol(name: name, section: section) else { return nil }
        stats.decodedEntries += 1
        store(key, .ts(symbol), cost: decoder.cost)
        return symbol
    }

    /// All symbol names of a section, sorted (allocates; for tests).
    public func tsSymbolNames(in section: TSGlobalSymbol.Section) -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard let table = tsTable(), let sec = table.section(id: section == .es ? 2 : 3) else { return [] }
        return table.names(sec)
    }

    // MARK: - Internals (lock held)

    private func pythonTable() -> MappedTypeTable? {
        if python == nil, let url = locate(Self.pythonFileName) {
            python = MappedTypeTable(url: url).flatMap { $0.language == 1 ? $0 : nil }
        }
        return python
    }

    private func tsTable() -> MappedTypeTable? {
        if typeScript == nil, let url = locate(Self.typeScriptFileName) {
            typeScript = MappedTypeTable(url: url).flatMap { $0.language == 2 ? $0 : nil }
        }
        return typeScript
    }

    private func cached(_ key: Key) -> Value? {
        guard var slot = cache[key] else { return nil }
        tick += 1
        slot.tick = tick
        cache[key] = slot
        return slot.value
    }

    private func store(_ key: Key, _ value: Value, cost: Int) {
        tick += 1
        cache[key] = Slot(value: value, cost: cost, tick: tick)
        var total = cache.values.reduce(0) { $0 + $1.cost }
        // Evict least recently used entries, but always keep the newest one
        // even when it alone exceeds the limit.
        while total > cacheByteLimit, cache.count > 1,
              let victim = cache.min(by: { $0.value.tick < $1.value.tick }), victim.key != key {
            total -= victim.value.cost
            cache.removeValue(forKey: victim.key)
            stats.evictions += 1
        }
    }
}
