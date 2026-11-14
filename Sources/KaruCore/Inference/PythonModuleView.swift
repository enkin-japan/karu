import Foundation

// M17 T17.11b — the evaluator's view of a Python syntax snapshot: nodes of
// one parsed unit (the whole tree, or one top-level statement parsed on
// demand from a module summary), and module-level name lookups over either
// form (plan §8.3: a large document keeps only the summary; statements are
// parsed when needed).

/// One parsed tree the evaluator reads (identity matters: nodes compare by
/// unit and index).
final class PyUnit {
    let tree: SyntaxTree
    init(_ tree: SyntaxTree) { self.tree = tree }
}

/// A node of a `PyUnit`.
struct PyNode: Hashable {
    let unit: PyUnit
    let i: Int

    static func == (a: PyNode, b: PyNode) -> Bool { a.unit === b.unit && a.i == b.i }
    func hash(into h: inout Hasher) {
        h.combine(ObjectIdentifier(unit))
        h.combine(i)
    }

    @inline(__always) var raw: SyntaxNode { unit.tree.nodes[i] }
    @inline(__always) var kind: SyntaxKind { raw.kind }
    @inline(__always) var start: Int { Int(raw.start) }
    @inline(__always) var end: Int { Int(raw.end) }
    var range: NSRange { raw.range }
    func has(_ flag: UInt8) -> Bool { raw.has(flag) }

    /// Children in document order.
    var children: [PyNode] { unit.tree.children(i).map { PyNode(unit: unit, i: $0) } }

    /// Children without recovery placeholders (`missing`, `error`).
    var parts: [PyNode] {
        unit.tree.children(i).compactMap {
            let k = unit.tree.nodes[$0].kind
            return k == .missing || k == .error ? nil : PyNode(unit: unit, i: $0)
        }
    }

    func firstChild(_ kind: SyntaxKind) -> PyNode? { unit.tree.firstChild(i, kind: kind).map { PyNode(unit: unit, i: $0) } }

    /// `other` lies in this node's subtree (or is this node).
    func contains(_ other: PyNode) -> Bool {
        unit === other.unit && other.i <= i && other.i >= i - Int(raw.size)
    }

    /// The nodes from the unit's root down to this node's parent.
    var ancestors: [PyNode] {
        let tree = unit.tree
        var out: [PyNode] = []
        var cur = tree.root
        guard cur != i else { return [] }
        while true {
            out.append(PyNode(unit: unit, i: cur))
            var next: Int?
            tree.forEachChildReversed(cur) { c in
                if next == nil, i <= c, i >= c - Int(tree.nodes[c].size) { next = c }
            }
            guard let n = next, n != i else { return out }
            cur = n
        }
    }

    /// Every node of the subtree (descendants first), as `visit` asks:
    /// `visit` returns false to skip a node's subtree (pre-order walk).
    func walk(_ visit: (PyNode) -> Bool) {
        guard visit(self) else { return }
        for c in children { c.walk(visit) }
    }
}

/// Module-level access over a full tree or a summary (one per snapshot
/// version): the statement containing an offset, the top-level statements
/// binding a name, star imports. Name lookups are memoised (the per-version
/// module memo of plan §8.3).
@MainActor
final class PyModuleView {
    enum Storage {
        case tree(PyUnit)
        case summary(ModuleSummary)
    }

    let storage: Storage
    let text: NSString
    /// Summary mode: the standalone tree of the statement starting at an
    /// offset (`DocumentAnalysis.syntaxStatement(at:)`).
    private let parseStatement: @MainActor (Int) -> SyntaxTree?
    private var units: [Int32: PyUnit] = [:]
    /// Tree mode: (start, end, statement node) per module-level name.
    private var treeNames: [Int32]?
    private var memo: [String: [PyNode]] = [:]
    private var stars: [String]?
    private var topLevel: [Int]?
    /// Kept across versions by the service; nil: scan every name.
    var nameIndex: PyNameIndex?
    /// Statements parsed on demand so far (summary mode; tests).
    private(set) var parsedStatements = 0

    static let memoLimit = 512
    static let unitLimit = 256

    init(storage: Storage, text: NSString, parseStatement: @escaping @MainActor (Int) -> SyntaxTree?) {
        self.storage = storage
        self.text = text
        self.parseStatement = parseStatement
    }

    var isSummary: Bool { if case .summary = storage { return true }; return false }

    /// Summary mode: the unit of statement `index`.
    private func unit(ofStatement index: Int, in summary: ModuleSummary) -> PyNode? {
        let start = summary.statements[index].start
        if let u = units[start] { return PyNode(unit: u, i: u.tree.root - 1) }
        guard let tree = parseStatement(Int(start)), tree.nodes.count >= 2 else { return nil }
        if units.count >= Self.unitLimit { units.removeAll() }
        let u = PyUnit(tree)
        units[start] = u
        parsedStatements += 1
        return PyNode(unit: u, i: u.tree.root - 1)
    }

    /// The top-level statement containing `offset`.
    func topLevelStatement(containing offset: Int) -> PyNode? {
        switch storage {
        case .tree(let u):
            return u.tree.topLevelStatement(at: offset).map { PyNode(unit: u, i: $0) }
        case .summary(let s):
            return s.statementIndex(at: offset).flatMap { unit(ofStatement: $0, in: s) }
        }
    }

    /// The top-level statements binding `name` (document order).
    func bindingStatements(of name: String) -> [PyNode] {
        if let hit = memo[name] { return hit }
        let units16 = Array(name.utf16)
        func matches(_ s: Int32, _ e: Int32) -> Bool {
            guard Int(e - s) == units16.count, Int(e) <= text.length else { return false }
            for k in 0..<units16.count where text.character(at: Int(s) + k) != units16[k] { return false }
            return true
        }
        let out = nameIndex.map { indexedBindingStatements(units16, index: $0, matches: matches) }
            ?? scannedBindingStatements(matches: matches)
        if memo.count >= Self.memoLimit { memo.removeAll() }
        memo[name] = out
        return out
    }

    /// Through the persistent index: the statements at the indexed names'
    /// mapped offsets, and those in the region edited since it was built.
    private func indexedBindingStatements(_ units16: [UInt16], index: PyNameIndex,
                                          matches: (Int32, Int32) -> Bool) -> [PyNode] {
        let dirty = index.dirtyRanges()
        var byStart: [Int: PyNode] = [:]
        for offset in index.liveOffsets(of: units16) {
            if dirty.contains(where: { offset >= $0.location && offset <= NSMaxRange($0) }) { continue }
            guard matches(Int32(offset), Int32(offset + units16.count)),
                  let stmt = topLevelStatement(containing: offset) else { continue }
            byStart[stmt.start] = stmt
        }
        for range in dirty {
            for stmt in statementsBinding(in: range, matches: matches) { byStart[stmt.start] = stmt }
        }
        return byStart.keys.sorted().compactMap { byStart[$0] }
    }

    /// Top-level statements overlapping `range` that bind a matching name.
    private func statementsBinding(in range: NSRange, matches: (Int32, Int32) -> Bool) -> [PyNode] {
        var out: [PyNode] = []
        switch storage {
        case .tree(let u):
            let stmts = topLevelStatements(u)
            var lo = 0, hi = stmts.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if Int(u.tree.nodes[stmts[mid]].end) < range.location { lo = mid + 1 } else { hi = mid }
            }
            let view = NodeView(nodes: u.tree.nodes)
            var names: [Int] = []
            var k = lo
            while k < stmts.count, Int(u.tree.nodes[stmts[k]].start) <= NSMaxRange(range) {
                names.removeAll(keepingCapacity: true)
                view.pythonBoundNames(stmts[k], &names)
                if names.contains(where: { matches(u.tree.nodes[$0].start, u.tree.nodes[$0].end) }) {
                    out.append(PyNode(unit: u, i: stmts[k]))
                }
                k += 1
            }
        case .summary(let s):
            var lo = 0, hi = s.statements.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if Int(s.statements[mid].end) < range.location { lo = mid + 1 } else { hi = mid }
            }
            var k = lo
            while k < s.statements.count, Int(s.statements[k].start) <= NSMaxRange(range) {
                let first = Int(s.statements[k].firstName)
                for n in 0..<s.nameCount(of: k) where matches(s.nameRanges[first + 2 * n], s.nameRanges[first + 2 * n + 1]) {
                    if let node = unit(ofStatement: k, in: s) { out.append(node) }
                    break
                }
                k += 1
            }
        }
        return out
    }

    private func topLevelStatements(_ u: PyUnit) -> [Int] {
        if let t = topLevel { return t }
        let t = u.tree.topLevelStatements
        topLevel = t
        return t
    }

    /// Every module-level name range (start, end) — the index's input.
    func forEachModuleName(_ body: (Int32, Int32) -> Void) {
        switch storage {
        case .tree(let u):
            let names = treeNameTable(u)
            var k = 0
            while k + 2 < names.count {
                body(names[k], names[k + 1])
                k += 3
            }
        case .summary(let s):
            var k = 0
            while k + 1 < s.nameRanges.count {
                body(s.nameRanges[k], s.nameRanges[k + 1])
                k += 2
            }
        }
    }

    /// Without an index: every module-level name compared.
    private func scannedBindingStatements(matches: (Int32, Int32) -> Bool) -> [PyNode] {
        var out: [PyNode] = []
        switch storage {
        case .tree(let u):
            let names = treeNameTable(u)
            var k = 0
            var last = -1
            while k + 2 < names.count {
                if matches(names[k], names[k + 1]), Int(names[k + 2]) != last {
                    last = Int(names[k + 2])
                    out.append(PyNode(unit: u, i: last))
                }
                k += 3
            }
        case .summary(let s):
            for index in s.statements.indices {
                let first = Int(s.statements[index].firstName)
                let count = s.nameCount(of: index)
                for n in 0..<count where matches(s.nameRanges[first + 2 * n], s.nameRanges[first + 2 * n + 1]) {
                    if let node = unit(ofStatement: index, in: s) { out.append(node) }
                    break
                }
            }
        }
        return out
    }

    private func treeNameTable(_ u: PyUnit) -> [Int32] {
        if let t = treeNames { return t }
        var out: [Int32] = []
        let view = NodeView(nodes: u.tree.nodes)
        var names: [Int] = []
        for stmt in u.tree.topLevelStatements {
            names.removeAll(keepingCapacity: true)
            view.pythonBoundNames(stmt, &names)
            for n in names {
                out.append(u.tree.nodes[n].start)
                out.append(u.tree.nodes[n].end)
                out.append(Int32(stmt))
            }
        }
        treeNames = out
        return out
    }

    /// Modules of top-level `from m import *` statements (absolute only).
    func starImports() -> [String] {
        if let s = stars { return s }
        var out: [String] = []
        func scan(_ stmt: PyNode) {
            guard stmt.kind == .importFrom, stmt.raw.aux == 0,
                  let star = stmt.children.last, star.kind == .name, text.substring(with: star.range) == "*",
                  let dotted = stmt.firstChild(.dottedName) else { return }
            out.append(text.substring(with: dotted.range).filter { !$0.isWhitespace })
        }
        switch storage {
        case .tree(let u):
            for i in u.tree.topLevelStatements where u.tree.nodes[i].kind == .importFrom { scan(PyNode(unit: u, i: i)) }
        case .summary(let s):
            for index in s.statements.indices where s.statements[index].kind == .importFrom && s.nameCount(of: index) == 0 {
                if let node = unit(ofStatement: index, in: s) { scan(node) }
            }
        }
        stars = out
        return out
    }

    /// FNV-1a hash of `node`'s text (dependency validation of cached results).
    func textHash(_ node: PyNode) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        let range = node.range
        var buffer = [UInt16](repeating: 0, count: min(range.length, 4_096))
        var at = range.location
        let end = NSMaxRange(range)
        while at < end {
            let n = min(buffer.count, end - at)
            buffer.withUnsafeMutableBufferPointer { text.getCharacters($0.baseAddress!, range: NSRange(location: at, length: n)) }
            for k in 0..<n {
                h ^= UInt64(buffer[k])
                h = h &* 0x100_0000_01b3
            }
            at += n
        }
        return h
    }
}

/// A lazily computed type with a recursion guard (a cycle yields `unknown`).
@MainActor
final class Thunk {
    private var value: InferredType?
    private var compute: (@MainActor () -> InferredType)?
    private var busy = false

    init(_ value: InferredType) { self.value = value }
    init(lazy compute: @escaping @MainActor () -> InferredType) { self.compute = compute }

    func get() -> InferredType {
        if let value { return value }
        if busy { return .unknown }
        busy = true
        let v = compute?() ?? .unknown
        busy = false
        value = v
        compute = nil
        return v
    }
}

/// The module-level names of a document, kept across versions (plan §8.3:
/// the per-document module memo): a hash of each name with its offset when
/// built, mapped to the live text through an edit journal. Names in the
/// region edited since are found by scanning only the statements there.
/// Rebuilt when the journal becomes unmappable or the edited region grows
/// past `dirtyLimit`. 12 bytes per module-level name.
@MainActor
final class PyNameIndex {
    static let dirtyLimit = 256 * 1024

    private var hashes: [UInt64] = []
    private var offsets: [Int32] = []
    private var journal = EditJournal()
    private var builtLength = -1

    var isEmpty: Bool { builtLength < 0 }
    var retainedBytes: Int { hashes.capacity * 8 + offsets.capacity * 4 }

    func removeAll() {
        hashes = []
        offsets = []
        journal.reset()
        dirtyCache = nil
        builtLength = -1
    }

    func record(editedRange: NSRange, changeInLength delta: Int) {
        guard builtLength >= 0 else { return }
        journal.record(editedRange: editedRange, changeInLength: delta)
        dirtyCache = nil
    }

    /// Whether the index still maps onto a text of `length` units.
    func isUsable(forLength length: Int) -> Bool {
        guard builtLength >= 0, let delta = journal.netDelta, builtLength + delta == length else { return false }
        return dirtyRanges().reduce(0) { $0 + $1.length } <= Self.dirtyLimit
    }

    /// The live ranges written since the build (each edit's new text,
    /// carried through the later edits; merged when they touch).
    func dirtyRanges() -> [NSRange] {
        let edits = journal.edits
        guard !edits.isEmpty else { return [] }
        if let cached = dirtyCache, cached.count == edits.count { return cached.ranges }
        func carry(_ p: Int, from k: Int) -> Int {
            var p = p
            for e in edits[(k + 1)...] {
                if p >= e.location + e.oldLength { p += e.newLength - e.oldLength } else if p > e.location {
                    p = e.location + min(p - e.location, e.newLength)
                }
            }
            return p
        }
        var ranges: [NSRange] = []
        for (k, e) in edits.enumerated() {
            let start = carry(e.location, from: k)
            let end = max(start, carry(e.location + e.newLength, from: k))
            ranges.append(NSRange(location: start, length: end - start))
        }
        ranges.sort { $0.location < $1.location }
        var merged: [NSRange] = []
        for r in ranges {
            if let last = merged.last, r.location <= NSMaxRange(last) {
                merged[merged.count - 1].length = max(NSMaxRange(last), NSMaxRange(r)) - last.location
            } else {
                merged.append(r)
            }
        }
        dirtyCache = (edits.count, merged)
        return merged
    }

    private var dirtyCache: (count: Int, ranges: [NSRange])?

    func rebuild(from module: PyModuleView) {
        let text = module.text
        var pairs: [(UInt64, Int32)] = []
        var buffer = [UInt16](repeating: 0, count: 256)
        module.forEachModuleName { start, end in
            let n = Int(end - start)
            guard n > 0, n <= buffer.count, Int(end) <= text.length else { return }
            buffer.withUnsafeMutableBufferPointer {
                text.getCharacters($0.baseAddress!, range: NSRange(location: Int(start), length: n))
            }
            pairs.append((Self.hash(buffer[0..<n]), start))
        }
        pairs.sort { $0.0 < $1.0 || ($0.0 == $1.0 && $0.1 < $1.1) }
        hashes = pairs.map(\.0)
        offsets = pairs.map(\.1)
        journal.reset()
        dirtyCache = nil
        builtLength = text.length
    }

    /// Live offsets of the indexed names hashing like `units` (callers
    /// verify the text).
    func liveOffsets(of units: [UInt16]) -> [Int] {
        let h = Self.hash(units[...])
        var lo = 0, hi = hashes.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if hashes[mid] < h { lo = mid + 1 } else { hi = mid }
        }
        var out: [Int] = []
        while lo < hashes.count, hashes[lo] == h {
            if let live = journal.mapFromBase(Int(offsets[lo])) { out.append(live) }
            lo += 1
        }
        return out
    }

    static func hash(_ units: ArraySlice<UInt16>) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for u in units {
            h ^= UInt64(u)
            h = h &* 0x100_0000_01b3
        }
        return h
    }
}
