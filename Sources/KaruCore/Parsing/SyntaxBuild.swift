import Foundation

/// What a syntax build produces: the full tree (documents up to
/// `SyntaxBuild.fullTreeUnitLimit`) or the module summary (larger ones).
public enum SyntaxContent: Sendable, Equatable {
    case tree(SyntaxTree)
    case summary(ModuleSummary)

    public var dialect: SyntaxDialect {
        switch self {
        case .tree(let t): return t.dialect
        case .summary(let s): return s.dialect
        }
    }

    public var tree: SyntaxTree? {
        if case .tree(let t) = self { return t }
        return nil
    }

    public var summary: ModuleSummary? {
        if case .summary(let s) = self { return s }
        return nil
    }

    /// The text length it describes.
    public var textLength: Int {
        switch self {
        case .tree(let t): return t.textLength
        case .summary(let s): return s.textLength
        }
    }

    /// Bytes held by its arrays.
    public var retainedBytes: Int {
        switch self {
        case .tree(let t): return t.retainedBytes
        case .summary(let s): return s.retainedBytes
        }
    }
}

/// One replacement between a base text and a later one: `oldLength` units
/// at `start` of the base became `newLength` units.
public struct SyntaxEdit: Sendable, Equatable {
    public var start: Int
    public var oldLength: Int
    public var newLength: Int

    public init(start: Int, oldLength: Int, newLength: Int) {
        self.start = start
        self.oldLength = oldLength
        self.newLength = newLength
    }

    /// The single replacement covering every edit in `journal` (whose base
    /// text had `baseLength` units): the unchanged prefix and suffix common
    /// to all of them. Nil when the journal is unmappable.
    public static func covering(_ journal: EditJournal, baseLength: Int) -> SyntaxEdit? {
        guard !journal.isUnmappable else { return nil }
        var prefix = baseLength, suffix = baseLength, length = baseLength
        for e in journal.edits {
            let after = length + e.newLength - e.oldLength
            prefix = min(prefix, e.location)
            suffix = min(suffix, after - (e.location + e.newLength))
            length = after
        }
        guard !journal.edits.isEmpty else { return SyntaxEdit(start: baseLength, oldLength: 0, newLength: 0) }
        prefix = max(0, prefix)
        suffix = max(0, min(suffix, baseLength - prefix, length - prefix))
        return SyntaxEdit(start: prefix, oldLength: baseLength - suffix - prefix, newLength: length - suffix - prefix)
    }
}

/// The parsers' common surface for the build loop.
protocol TopLevelParser {
    var c: SyntaxParsing.Core { get set }
    mutating func topLevelStep()
}

extension SyntaxParsing.PythonParser: TopLevelParser {}
extension SyntaxParsing.ScriptParser: TopLevelParser {}

/// A resumable parse (M17 T17.11a, plan §3 "调度" and §8.3): a fresh build
/// or an incremental update of a previous result, advanced in bounded steps
/// at top-level statement boundaries so `DocumentAnalysis` can run it in
/// main-thread slices through `AnalysisScheduler`.
///
/// - **Mode.** Texts up to `fullTreeUnitLimit` UTF-16 units keep the whole
///   tree; longer ones only a `ModuleSummary` (each statement is parsed,
///   summarised and dropped).
/// - **Incremental update** (`init(updating:edit:text:)`): reparsing starts at
///   the top-level statement before the first one touching the edit, moved
///   back until it begins its line at a sync start (lexically clean; Python:
///   a logical line start). After each reparsed statement the build tries to
///   resynchronise: the next token is clean, begins its line and is the
///   (shifted) start of an old statement after the edit, with a line break
///   between the edit and it, at an old sync start; a `/` or `<` there (the
///   scanner decides regex / JSX from up to 256 units back) must be at least
///   257 units after the edit. The old statements from there on are reused
///   with their offsets shifted. The result equals a full parse of the new
///   text node for node.
/// - **Steps.** `step(_:budgetUnits:)` parses whole top-level statements
///   until at least `budgetUnits` units were consumed (a statement is never
///   split; one longer than the budget runs in one step). The text must not
///   change between steps (the caller checks its version; a changed length
///   ends the build without a result). Any sequence of budgets gives the
///   same result as `finish(_:)`.
/// - **Bounds.** Each statement runs under the parser core's step cap and
///   nesting guard (`SyntaxParsing.Core`).
///
/// Not `Sendable` (it holds the text between steps); the products are.
public struct SyntaxBuild {
    /// Documents up to this many UTF-16 units keep the full tree (≈ 1 MB).
    public static let fullTreeUnitLimit = 1 << 20

    public enum Mode: Sendable, Equatable { case tree, summary }

    /// The mode for a text of `length` units.
    public static func mode(forLength length: Int) -> Mode { length <= fullTreeUnitLimit ? .tree : .summary }

    public let dialect: SyntaxDialect
    public let mode: Mode
    let textLength: Int

    // The previous result (incremental update) and its statements.
    private let baseTree: SyntaxTree?
    private let baseSummary: ModuleSummary?
    private var oldStarts: [Int32] = []
    private var oldFirstNodes: [Int] = []
    /// Statements `[0, prefixCount)` are reused as they are.
    private var prefixCount = 0
    private var startOffset = 0
    /// Old coordinates of the edit end, and the length change.
    private var editEnd = Int.max
    private var delta = 0
    private var firstAfterEdit = 0
    private var syncedAt: Int?

    private var python: SyntaxParsing.PythonParser?
    private var script: SyntaxParsing.ScriptParser?
    /// Summary mode: the reparsed statements' summary.
    private var fresh: ModuleSummary
    public private(set) var result: SyntaxContent?
    /// The text changed between steps: no result.
    public private(set) var isInvalidated = false

    // Statistics.
    public private(set) var reparsedStatements = 0
    public private(set) var reusedStatements = 0
    /// Exhaustions of the step cap (0 on any sane input) and the largest
    /// steps-per-token ratio of a statement.
    public private(set) var capHits = 0
    public private(set) var maxStepRatio = 0.0

    /// A fresh build of `text`.
    public init(dialect: SyntaxDialect, text: NSString, mode: Mode? = nil) {
        self.dialect = dialect
        self.mode = mode ?? Self.mode(forLength: text.length)
        textLength = text.length
        baseTree = nil
        baseSummary = nil
        fresh = ModuleSummary(dialect: dialect)
        makeParser(text, from: 0, incremental: false)
    }

    /// An incremental update of `base` (built from the text before `edit`)
    /// to `text`. The mode follows `base`.
    public init(updating base: SyntaxContent, edit: SyntaxEdit, text: NSString) {
        dialect = base.dialect
        textLength = text.length
        fresh = ModuleSummary(dialect: base.dialect)
        switch base {
        case .tree(let tree):
            mode = .tree
            baseTree = tree
            baseSummary = nil
            tree.forEachChildReversed(tree.root) { i in
                oldStarts.append(tree.nodes[i].start)
                oldFirstNodes.append(i - Int(tree.nodes[i].size))
            }
            oldStarts.reverse()
            oldFirstNodes.reverse()
            planRestart(text, edit: edit, isSync: tree.isSyncStart)
        case .summary(let summary):
            mode = .summary
            baseTree = nil
            baseSummary = summary
            oldStarts = summary.statements.map(\.start)
            planRestart(text, edit: edit, isSync: summary.isSyncStart)
        }
        makeParser(text, from: startOffset, incremental: true)
    }

    // MARK: - Planning

    /// Picks the restart statement (see the type comment).
    private mutating func planRestart(_ text: NSString, edit: SyntaxEdit, isSync: (Int32) -> Bool) {
        let es = edit.start
        let ee = edit.start + edit.oldLength
        editEnd = ee
        delta = edit.newLength - edit.oldLength
        let n = oldStarts.count
        // Statement ends are non-decreasing: binary search the first ending at
        // or after the edit start.
        var lo = 0, hi = n
        while lo < hi {
            let mid = (lo + hi) / 2
            if Int(oldEnd(mid)) >= es { hi = mid } else { lo = mid + 1 }
        }
        var r = max(0, lo - 1)
        // (Several statements may share a start: an empty statement before
        // skipped junk. Start at the first of them.)
        while r > 0, !Self.beginsLine(Int(oldStarts[r]), text)
                || oldStarts[r - 1] >= oldStarts[r]
                || !isSync(oldStarts[r]) { r -= 1 }
        prefixCount = r
        startOffset = r == 0 ? 0 : Int(oldStarts[r])
        // First old statement at or after the edit end.
        lo = r
        hi = n
        while lo < hi {
            let mid = (lo + hi) / 2
            if Int(oldStarts[mid]) >= ee { hi = mid } else { lo = mid + 1 }
        }
        firstAfterEdit = lo
    }

    private func oldEnd(_ k: Int) -> Int32 {
        if let tree = baseTree {
            // The root's children in order: statement k is a child of the root.
            return tree.nodes[statementNode(k, in: tree)].end
        }
        return baseSummary!.statements[k].end
    }

    private func statementNode(_ k: Int, in tree: SyntaxTree) -> Int {
        k + 1 < oldFirstNodes.count ? oldFirstNodes[k + 1] - 1 : tree.root - 1
    }

    private mutating func makeParser(_ text: NSString, from: Int, incremental: Bool) {
        var lexer = SyntaxParsing.Lexer(text: text, dialect: dialect, from: from)
        if incremental { lexer.chunkSize = 2048 }
        let reserve = mode == .tree && !incremental
        var core = SyntaxParsing.Core(text: text, lexer: lexer, reserveNodes: reserve)
        if !reserve { core.nodes.reserveCapacity(1024) }
        if dialect == .python {
            python = SyntaxParsing.PythonParser(core: core)
        } else {
            script = SyntaxParsing.ScriptParser(core: core, dialect: dialect)
        }
    }

    /// Whether only blanks precede `offset` on its line.
    static func beginsLine(_ offset: Int, _ text: NSString) -> Bool {
        var p = offset
        while p > 0 {
            let u = text.character(at: p - 1)
            if u == 10 || u == 13 { return true }
            if u != 32 && u != 9 && u != 12 { return false }
            p -= 1
        }
        return true
    }

    // MARK: - Stepping

    public var isFinished: Bool { result != nil || isInvalidated }

    /// Parses top-level statements until `budgetUnits` units were consumed
    /// (at least one statement); true when finished (`result` set, or
    /// `isInvalidated`).
    @discardableResult
    public mutating func step(_ text: NSString, budgetUnits: Int) -> Bool {
        if isFinished { return true }
        guard text.length == textLength else {
            isInvalidated = true
            python = nil
            script = nil
            return true
        }
        // Moved out while it runs (no copy of its buffers, no overlapping access).
        if var p = python.take() {
            let done = run(&p, text, budgetUnits: budgetUnits)
            if !done { python = p }
            return done
        }
        var p = script.take()!
        let done = run(&p, text, budgetUnits: budgetUnits)
        if !done { script = p }
        return done
    }

    /// Runs to completion.
    public mutating func finish(_ text: NSString) -> SyntaxContent? {
        while !step(text, budgetUnits: Int.max) {}
        return result
    }

    private mutating func run<P: TopLevelParser>(_ p: inout P, _ text: NSString, budgetUnits: Int) -> Bool {
        p.c.rebind(text)
        let stepStart = Int(p.c.toks[p.c.i].start)
        while true {
            if p.c.toks[p.c.i].kind == .eof {
                finalize(&p.c, text)
                return true
            }
            let mark = p.c.nodes.count
            p.topLevelStep()
            reparsedStatements += 1
            if mode == .summary {
                fresh.appendStatements(of: p.c.nodes, from: mark)
                p.c.nodes.removeAll(keepingCapacity: true)
            }
            if baseTree != nil || baseSummary != nil, let k = syncPoint(&p.c, text) {
                syncedAt = k
                finalize(&p.c, text)
                return true
            }
            if Int(p.c.toks[p.c.i].start) - stepStart >= budgetUnits { return false }
        }
    }

    /// The old statement index to resume from when the parser stands at a
    /// synchronisation point.
    private func syncPoint(_ c: inout SyntaxParsing.Core, _ text: NSString) -> Int? {
        let t = c.toks[c.i]
        guard t.kind != .eof, t.isLineStart, t.flags & SyntaxParsing.Token.clean != 0 else { return nil }
        if dialect == .python, !t.isLogicalStart { return nil }
        let oldStart = Int(t.start) - delta
        guard oldStart >= editEnd else { return nil }
        // The first old statement starting there.
        var lo = firstAfterEdit, hi = oldStarts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if Int(oldStarts[mid]) >= oldStart { hi = mid } else { lo = mid + 1 }
        }
        guard lo < oldStarts.count, Int(oldStarts[lo]) == oldStart else { return nil }
        let isSync = baseTree?.isSyncStart(Int32(oldStart)) ?? baseSummary!.isSyncStart(Int32(oldStart))
        guard isSync else { return nil }
        // A line break between the edit and the statement (in new
        // coordinates: the text there is unchanged), and only blanks before
        // it on its line.
        let newStart = Int(t.start)
        let newEditEnd = editEnd + delta
        var p = newStart
        var lineBreak = false
        while p > newEditEnd {
            let u = text.character(at: p - 1)
            if u == 10 || u == 13 { lineBreak = true; break }
            p -= 1
        }
        guard lineBreak, Self.beginsLine(newStart, text) else { return nil }
        // `/` (regex or division) and `<` (JSX or less-than) are decided by
        // the scanner from up to 256 units of preceding text.
        let first = text.character(at: newStart)
        if first == 47 || first == 60, oldStart - editEnd < 257 { return nil }
        return lo
    }

    // MARK: - Finishing

    private mutating func finalize(_ c: inout SyntaxParsing.Core, _ text: NSString) {
        capHits = c.capHits
        maxStepRatio = c.maxStepRatio
        switch mode {
        case .tree: result = .tree(spliceTree(&c))
        case .summary: result = .summary(spliceSummary(&c))
        }
        python = nil
        script = nil
    }

    private mutating func spliceTree(_ c: inout SyntaxParsing.Core) -> SyntaxTree {
        guard let old = baseTree else {
            c.emit(.module, 0, 0, Int32(textLength))
            var nodes = c.nodes
            c.nodes = []
            nodes.shrinkToFit()
            var starts = c.syncStarts
            starts.shrinkToFit()
            return SyntaxTree(dialect: dialect, nodes: nodes, syncStarts: starts)
        }
        let oldNodes = old.nodes
        let prefixNodes = prefixCount == 0 ? 0 : oldFirstNodes[prefixCount]
        let suffixFirst = syncedAt.map { oldFirstNodes[$0] } ?? old.root
        var out: [SyntaxNode] = []
        out.reserveCapacity(prefixNodes + c.nodes.count + (old.root - suffixFirst) + 1)
        out.append(contentsOf: oldNodes[0..<prefixNodes])
        out.append(contentsOf: c.nodes)
        if syncedAt != nil {
            let d = Int32(delta)
            for n in oldNodes[suffixFirst..<old.root] {
                var n = n
                n.start += d
                n.end += d
                out.append(n)
            }
        }
        out.append(SyntaxNode(kind: .module, flags: 0, aux: 0, start: 0, end: Int32(textLength), size: Int32(out.count)))
        reusedStatements = prefixCount + (syncedAt.map { oldStarts.count - $0 } ?? 0)
        let starts = spliceSyncStarts(old.syncStarts, c.syncStarts)
        return SyntaxTree(dialect: dialect, nodes: out, syncStarts: starts)
    }

    private mutating func spliceSummary(_ c: inout SyntaxParsing.Core) -> ModuleSummary {
        guard let old = baseSummary else {
            var out = fresh
            out.syncStarts = c.syncStarts
            out.textLength = textLength
            out.statements.shrinkToFit()
            out.nameRanges.shrinkToFit()
            out.syncStarts.shrinkToFit()
            return out
        }
        var out = ModuleSummary(dialect: dialect, textLength: textLength)
        let suffixFrom = syncedAt ?? old.statements.count
        let prefixNames = prefixCount < old.statements.count
            ? Int(old.statements[prefixCount].firstName) : old.nameRanges.count
        let suffixNames = suffixFrom < old.statements.count
            ? Int(old.statements[suffixFrom].firstName) : old.nameRanges.count
        out.statements.reserveCapacity(prefixCount + fresh.statements.count + old.statements.count - suffixFrom)
        out.nameRanges.reserveCapacity(prefixNames + fresh.nameRanges.count + old.nameRanges.count - suffixNames)
        out.statements.append(contentsOf: old.statements[0..<prefixCount])
        out.nameRanges.append(contentsOf: old.nameRanges[0..<prefixNames])
        let freshBase = Int32(out.nameRanges.count)
        for var s in fresh.statements {
            s.firstName += freshBase
            out.statements.append(s)
        }
        out.nameRanges.append(contentsOf: fresh.nameRanges)
        if suffixFrom < old.statements.count {
            let d = Int32(delta)
            let rebase = Int32(out.nameRanges.count) - Int32(suffixNames)
            for var s in old.statements[suffixFrom...] {
                s.start += d
                s.end += d
                s.signatureStart += d
                s.signatureEnd += d
                s.firstName += rebase
                out.statements.append(s)
            }
            for v in old.nameRanges[suffixNames...] { out.nameRanges.append(v + d) }
        }
        reusedStatements = prefixCount + (syncedAt.map { old.statements.count - $0 } ?? 0)
        out.syncStarts = spliceSyncStarts(old.syncStarts, c.syncStarts)
        return out
    }

    /// Old sync starts before the restart, the reparsed ones, and the old
    /// ones from the resynchronised statement on (shifted).
    private func spliceSyncStarts(_ old: [Int32], _ reparsed: [Int32]) -> [Int32] {
        var lo = 0, hi = old.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if Int(old[mid]) < startOffset { lo = mid + 1 } else { hi = mid }
        }
        var out: [Int32] = []
        var suffixFrom = old.count
        if let k = syncedAt {
            let suffixStart = oldStarts[k]
            var a = lo, b = old.count
            while a < b {
                let mid = (a + b) / 2
                if old[mid] < suffixStart { a = mid + 1 } else { b = mid }
            }
            suffixFrom = a
        }
        out.reserveCapacity(lo + reparsed.count + old.count - suffixFrom)
        out.append(contentsOf: old[0..<lo])
        out.append(contentsOf: reparsed)
        let d = Int32(delta)
        for v in old[suffixFrom...] { out.append(v + d) }
        return out
    }

    // MARK: - One-shot entry points

    /// Parses `text` completely into a tree (any length).
    public static func parse(_ text: NSString, dialect: SyntaxDialect) -> SyntaxTree {
        var build = SyntaxBuild(dialect: dialect, text: text, mode: .tree)
        return build.finish(text)!.tree!
    }

    /// Updates `old` (the tree of the text before `edit`) to `text`.
    public static func update(_ old: SyntaxTree, edit: SyntaxEdit, text: NSString) -> SyntaxTree {
        var build = SyntaxBuild(updating: .tree(old), edit: edit, text: text)
        return build.finish(text)!.tree!
    }

    /// The `skipping`-th top-level statement parsed from `from` (a sync
    /// start), as a standalone tree whose root spans `[start, end)`.
    static func parseStatements(_ text: NSString, dialect: SyntaxDialect, from: Int, skipping: Int,
                                start: Int32, end: Int32) -> SyntaxTree {
        var lexer = SyntaxParsing.Lexer(text: text, dialect: dialect, from: from)
        lexer.chunkSize = 2048
        var core = SyntaxParsing.Core(text: text, lexer: lexer, reserveNodes: false)
        core.nodes.reserveCapacity(1024)
        var nodes: [SyntaxNode] = []
        func collect<P: TopLevelParser>(_ p: inout P) {
            var seen = 0
            while p.c.toks[p.c.i].kind != .eof {
                p.c.nodes.removeAll(keepingCapacity: true)
                p.topLevelStep()
                var roots: [Int] = []
                var j = p.c.nodes.count - 1
                while j >= 0 {
                    roots.append(j)
                    j -= Int(p.c.nodes[j].size) + 1
                }
                for root in roots.reversed() {
                    if seen == skipping {
                        nodes.append(contentsOf: p.c.nodes[(root - Int(p.c.nodes[root].size))...root])
                        return
                    }
                    seen += 1
                }
            }
        }
        if dialect == .python {
            var p = SyntaxParsing.PythonParser(core: core)
            collect(&p)
        } else {
            var p = SyntaxParsing.ScriptParser(core: core, dialect: dialect)
            collect(&p)
        }
        nodes.append(SyntaxNode(kind: .module, flags: 0, aux: 0, start: start, end: end, size: Int32(nodes.count)))
        return SyntaxTree(dialect: dialect, nodes: nodes, syncStarts: [])
    }
}

extension Array {
    /// Drops excess capacity beyond 1/16 (the retained tree / summary
    /// should cost what it holds; one copy at the end of a build).
    mutating func shrinkToFit() {
        guard capacity > count + count / 16 + 16 else { return }
        var copy: [Element] = []
        copy.reserveCapacity(count)
        copy.append(contentsOf: self)
        self = copy
    }
}
