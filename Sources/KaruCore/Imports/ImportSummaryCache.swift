import Foundation

/// One imported module's summary as cached (M17 T17.13).
struct ImportedModule: Sendable {
    enum Content: Sendable {
        case python(PythonModuleSummary)
        case script(ScriptModuleSummary)
    }

    var content: Content
    /// `realpath` of the source file (nil for a namespace package).
    let sourcePath: String?
    /// Path → mtime when read: the file itself, its site-packages /
    /// node_modules directory and package directory (plan §9 "失效").
    let validators: [String: Double]
    /// Read from the project folder itself (FSEvents invalidate it);
    /// otherwise from site-packages / node_modules / the interpreter (mtime checks).
    let isProjectFile: Bool

    var isNamesOnly: Bool {
        switch content {
        case .python(let p): return p.kinds != nil
        case .script(let s): return s.namesOnly != nil
        }
    }

    /// The names-only form (LRU degradation, plan §11 降级 2).
    func reducedToNames() -> ImportedModule {
        var out = self
        switch content {
        case .python(let p): out.content = .python(PythonModuleSummarizer.namesOnly(p))
        case .script(let s): out.content = .script(s.reducedToNames())
        }
        return out
    }

    /// Approximate retained bytes (strings, arrays, records).
    var approximateBytes: Int {
        var n = 128 + ImportCost.string(sourcePath ?? "") + validators.reduce(0) { $0 + 48 + ImportCost.string($1.key) }
        switch content {
        case .python(let p): n += ImportCost.python(p)
        case .script(let s): n += ImportCost.script(s)
        }
        return n
    }
}

/// The app-wide import-summary LRU (plan §11 item ③: ≤ 8 MB, counted in the
/// per-file inference budget). Bounded by bytes and entries. Over the byte
/// cap the least recently used *full* summaries are first reduced to their
/// names (they stay listable, their types become unknown); only when every
/// entry is names-only are the oldest evicted (and re-read on demand). A
/// module whose own summary exceeds `moduleByteLimit` is stored names-only.
/// Main-actor only.
@MainActor
final class ImportSummaryCache {
    private struct Slot {
        var module: ImportedModule
        var cost: Int
        var tick: UInt64
    }

    let byteLimit: Int
    let moduleByteLimit: Int
    let countLimit: Int
    private var slots: [String: Slot] = [:]
    private var tick: UInt64 = 0
    /// Entries stored or used since this tick (the current batch) are
    /// degraded only after every older one.
    private var batchStart: UInt64 = 0
    private(set) var bytes = 0
    private(set) var degradations = 0
    private(set) var evictions = 0

    init(byteLimit: Int, moduleByteLimit: Int, countLimit: Int = 4_096) {
        self.byteLimit = byteLimit
        self.moduleByteLimit = moduleByteLimit
        self.countLimit = countLimit
    }

    var count: Int { slots.count }
    var isEmpty: Bool { slots.isEmpty }
    var allKeys: [String] { Array(slots.keys) }

    /// The module (marks it recent).
    func module(_ key: String) -> ImportedModule? {
        guard var slot = slots[key] else { return nil }
        tick &+= 1
        slot.tick = tick
        slots[key] = slot
        return slot.module
    }

    /// Starts a batch: what is inserted / used from now on is kept full
    /// before anything older (a module and the dependencies it arrived with).
    func beginBatch() { batchStart = tick + 1 }

    /// Without touching recency.
    func peek(_ key: String) -> ImportedModule? { slots[key]?.module }

    func contains(_ key: String) -> Bool { slots[key] != nil }

    /// Stores `module`; one over `moduleByteLimit` is stored names-only.
    func insert(_ module: ImportedModule, for key: String) {
        remove(key)
        var stored = module
        var cost = stored.approximateBytes
        if cost > moduleByteLimit, !stored.isNamesOnly {
            stored = stored.reducedToNames()
            cost = stored.approximateBytes
            degradations += 1
        }
        tick &+= 1
        slots[key] = Slot(module: stored, cost: cost, tick: tick)
        bytes += cost
        enforceLimits(keeping: key)
    }

    @discardableResult
    func remove(_ key: String) -> ImportedModule? {
        guard let slot = slots.removeValue(forKey: key) else { return nil }
        bytes -= slot.cost
        return slot.module
    }

    func removeAll() {
        slots = [:]
        bytes = 0
    }

    /// Keys whose module satisfies `predicate`.
    func keys(where predicate: (ImportedModule) -> Bool) -> [String] {
        slots.compactMap { predicate($0.value.module) ? $0.key : nil }
    }

    private func enforceLimits(keeping newest: String) {
        guard bytes > byteLimit || slots.count > countLimit else { return }
        // 1. Reduce the oldest full summaries to names (entries of the
        //    current batch last), 2. evict the oldest entries.
        for protectBatch in [true, false] {
            guard bytes > byteLimit else { break }
            let full = slots.filter {
                $0.key != newest && !$0.value.module.isNamesOnly && (!protectBatch || $0.value.tick < batchStart)
            }.sorted { $0.value.tick < $1.value.tick }
            for (key, slot) in full {
                guard bytes > byteLimit else { break }
                let reduced = slot.module.reducedToNames()
                let cost = reduced.approximateBytes
                bytes += cost - slot.cost
                slots[key] = Slot(module: reduced, cost: cost, tick: slot.tick)
                degradations += 1
            }
        }
        for protectBatch in [true, false] {
            guard bytes > byteLimit || slots.count > countLimit else { return }
            let ordered = slots.filter { $0.key != newest && (!protectBatch || $0.value.tick < batchStart) }
                .sorted { $0.value.tick < $1.value.tick }
            for (key, _) in ordered {
                guard bytes > byteLimit || slots.count > countLimit else { break }
                remove(key)
                evictions += 1
            }
        }
    }
}

/// Approximate heap cost of summaries (cache accounting).
enum ImportCost {
    /// A `String` value: inline up to 15 UTF-8 bytes, else a heap buffer.
    static func string(_ s: String) -> Int {
        let n = s.utf8.count
        return n > 15 ? 16 + ((n + 32 + 15) & ~15) : 16
    }

    static func optional(_ s: String?) -> Int { s.map(string) ?? 16 }

    static func signature(_ s: TypeTable.Signature) -> Int {
        64 + optional(s.returnType) + s.parameters.reduce(0) { $0 + 24 + string($1.name) + optional($1.type) }
            + s.typeParameters.reduce(0) { $0 + 48 + string($1.name) + optional($1.bound) }
    }

    static func classDecl(_ c: TypeTable.ClassDecl) -> Int {
        var n = 160 + string(c.name) + c.bases.reduce(0) { $0 + string($1) }
        n += c.typeParameters.reduce(0) { $0 + 48 + string($1.name) + optional($1.bound) }
        for m in c.members {
            n += 64 + string(m.name) + optional(m.type) + m.overloads.reduce(0) { $0 + signature($1) }
        }
        n += (c.callSignatures + c.constructSignatures).reduce(0) { $0 + signature($1) }
        n += c.indexSignatures.reduce(0) { $0 + 80 + string($1.keyType) + string($1.valueType) }
        return n
    }

    static func python(_ p: PythonModuleSummary) -> Int {
        let s = p.stub
        var n = 256 + string(s.name)
        n += (s.all ?? []).reduce(0) { $0 + string($1) }
        n += s.imports.reduce(0) { $0 + 56 + string($1.localName) + string($1.module) + optional($1.originalName) }
        n += s.starImports.reduce(0) { $0 + string($1) }
        n += s.typeVars.reduce(0) { $0 + 48 + string($1.name) + optional($1.bound) }
        n += s.aliases.reduce(0) { $0 + 48 + string($1.name) + string($1.type) }
        n += s.variables.reduce(0) { $0 + 40 + string($1.name) + optional($1.type) }
        n += s.functions.reduce(0) { $0 + 48 + string($1.name) + $1.overloads.reduce(0) { $0 + signature($1) } }
        n += s.classes.reduce(0) { $0 + classDecl($1) }
        n += (p.kinds ?? [:]).reduce(0) { $0 + 24 + string($1.key) }
        n += p.dependencies.reduce(0) { $0 + 48 + string($1.module) + $1.names.reduce(0) { $0 + string($1) } }
        return n
    }

    static func script(_ s: ScriptModuleSummary) -> Int {
        var n = 256 + string(s.key)
        for (name, symbol) in s.symbols {
            n += 128 + string(name)
            if let i = symbol.interface { n += classDecl(i) }
            if let v = symbol.variable { n += 40 + optional(v.type) }
            if let f = symbol.function { n += 48 + f.overloads.reduce(0) { $0 + signature($1) } }
            if let a = symbol.alias { n += 48 + string(a.type) }
            n += (symbol.namespaceMembers ?? []).reduce(0) { $0 + string($1) }
        }
        n += s.imports.reduce(0) { $0 + 64 + string($1.key) }
        n += s.exports.reduce(0) { $0 + 64 + string($1.key) }
        n += s.starExports.reduce(0) { $0 + string($1) }
        n += s.dependencies.reduce(0) { $0 + string($1) }
        n += (s.namesOnly ?? [:]).reduce(0) { $0 + 24 + string($1.key) }
        return n
    }
}
