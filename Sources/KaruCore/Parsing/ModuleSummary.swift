import Foundation

/// The module-level summary kept instead of a full tree for documents over
/// `SyntaxBuild.fullTreeUnitLimit` (M17 T17.11a, plan §8.3): one entry per
/// top-level statement — its kind, flags, range, the names it binds and, for
/// definitions, its signature range — plus the sync starts. A statement's
/// own subtree is parsed on demand (`parseStatement(_:in:)`), so memory grows
/// with the number of statements, not with the tree.
public struct ModuleSummary: Sendable, Equatable {
    public struct Statement: Sendable, Equatable {
        /// The statement's kind; for `export` / `declare` wrappers, the
        /// declaration's (see `traits`).
        public var kind: SyntaxKind
        /// The declaration node's `SyntaxFlags` (async, generator …).
        public var flags: UInt8
        /// `Statement.exported` … bits.
        public var traits: UInt8
        /// Index of its first name's start in `ModuleSummary.nameRanges`; its
        /// names run to the next statement's `firstName` (24-byte entries).
        public var firstName: Int32
        public var start: Int32
        public var end: Int32
        /// Definitions (`def` / `class` / `function` / `class` / `interface`):
        /// from the name to the end of the header (parameters, return
        /// annotation, bases / heritage), before the body. Others: empty at `start`.
        public var signatureStart: Int32
        public var signatureEnd: Int32

        public static let exported: UInt8 = 1
        public static let exportDefault: UInt8 = 2
        /// TS `declare`.
        public static let ambient: UInt8 = 4
        /// `import type` / `export type { … }`.
        public static let typeOnly: UInt8 = 8
        /// The statement holds an error or recovered node.
        public static let hasProblems: UInt8 = 16

        public var range: NSRange { NSRange(location: Int(start), length: Int(end - start)) }
        public var signatureRange: NSRange {
            NSRange(location: Int(signatureStart), length: Int(signatureEnd - signatureStart))
        }
    }

    public let dialect: SyntaxDialect
    public internal(set) var statements: [Statement]
    /// Name ranges, two offsets (start, end) per name.
    public internal(set) var nameRanges: [Int32]
    /// See `SyntaxTree.syncStarts`.
    public internal(set) var syncStarts: [Int32]
    public internal(set) var textLength: Int

    init(dialect: SyntaxDialect, statements: [Statement] = [], nameRanges: [Int32] = [],
         syncStarts: [Int32] = [], textLength: Int = 0) {
        self.dialect = dialect
        self.statements = statements
        self.nameRanges = nameRanges
        self.syncStarts = syncStarts
        self.textLength = textLength
    }

    /// The number of names statement `index` binds.
    public func nameCount(of index: Int) -> Int {
        let end = index + 1 < statements.count ? Int(statements[index + 1].firstName) : nameRanges.count
        return (end - Int(statements[index].firstName)) / 2
    }

    /// The names statement `index` binds (document order).
    public func names(of index: Int) -> [NSRange] {
        let first = Int(statements[index].firstName)
        return (0..<nameCount(of: index)).map { k in
            let p = first + 2 * k
            return NSRange(location: Int(nameRanges[p]), length: Int(nameRanges[p + 1] - nameRanges[p]))
        }
    }

    /// The statement whose range contains `offset` (start <= offset <= end;
    /// at a shared boundary the later statement wins).
    public func statementIndex(at offset: Int) -> Int? {
        var lo = 0, hi = statements.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if Int(statements[mid].start) <= offset { lo = mid + 1 } else { hi = mid }
        }
        var k = lo - 1
        while k >= 0 {
            let s = statements[k]
            if offset <= Int(s.end) { return k }
            if Int(s.end) < offset { break }
            k -= 1
        }
        return nil
    }

    /// Bytes held by the arrays (their capacities).
    public var retainedBytes: Int {
        statements.capacity * MemoryLayout<Statement>.stride
            + nameRanges.capacity * MemoryLayout<Int32>.stride
            + syncStarts.capacity * MemoryLayout<Int32>.stride
    }

    func isSyncStart(_ offset: Int32) -> Bool {
        var lo = 0, hi = syncStarts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if syncStarts[mid] < offset { lo = mid + 1 } else { hi = mid }
        }
        return lo < syncStarts.count && syncStarts[lo] == offset
    }

    /// Parses statement `index` on demand from `text` (the text this summary
    /// describes): a standalone tree whose root spans the statement and has
    /// the statement as its only child — node for node the subtree a full
    /// parse would hold. Parsing restarts at the nearest sync start at or
    /// before the statement (statements sharing its line are parsed and
    /// dropped).
    public func parseStatement(_ index: Int, in text: NSString) -> SyntaxTree {
        precondition(text.length == textLength, "the text this summary describes")
        let target = statements[index]
        // Restart: the statement itself or an earlier one that begins its
        // line at a sync start (as an incremental reparse would).
        var r = index
        while r > 0, !(SyntaxBuild.beginsLine(Int(statements[r].start), text)
                        && isSyncStart(statements[r].start)
                        && statements[r - 1].start < statements[r].start) {
            r -= 1
        }
        let from = r == 0 ? 0 : Int(statements[r].start)
        return SyntaxBuild.parseStatements(text, dialect: dialect, from: from, skipping: index - r,
                                           start: target.start, end: target.end)
    }

    // MARK: - Building

    /// Appends the summary of the top-level statements in `nodes[from...]`
    /// (complete subtrees, post-order).
    mutating func appendStatements(of nodes: [SyntaxNode], from: Int) {
        var roots: [Int] = []
        var j = nodes.count - 1
        while j >= from {
            roots.append(j)
            j -= Int(nodes[j].size) + 1
        }
        for root in roots.reversed() { append(statement: root, in: nodes) }
    }

    private mutating func append(statement root: Int, in nodes: [SyntaxNode]) {
        let view = NodeView(nodes: nodes)
        let n = nodes[root]
        var decl = root
        var traits: UInt8 = 0
        if n.kind == .exportDecl {
            if n.aux & SyntaxAux.typeOnly != 0 { traits |= Statement.typeOnly }
            let base = n.aux & ~SyntaxAux.typeOnly
            if base <= 1, let inner = view.children(root).first(where: { nodes[$0].kind != .missing }) {
                decl = inner
                traits |= base == 1 ? Statement.exported | Statement.exportDefault : Statement.exported
            }
        }
        if n.kind == .importDecl, n.aux & SyntaxAux.typeOnly != 0 { traits |= Statement.typeOnly }
        let d = nodes[decl]
        if d.flags & SyntaxFlags.modifier != 0, dialect != .python { traits |= Statement.ambient }
        let recoveryBits = SyntaxFlags.missingClose | SyntaxFlags.missingName | SyntaxFlags.recovered
        for k in view.subtree(root) {
            let x = nodes[k]
            if x.kind == .error || x.kind == .missing || x.flags & recoveryBits != 0 {
                traits |= Statement.hasProblems
                break
            }
        }
        let firstName = Int32(nameRanges.count)
        var names: [Int] = []
        if dialect == .python {
            view.pythonBoundNames(decl, &names)
        } else {
            view.scriptBoundNames(decl, &names)
        }
        for name in names {
            nameRanges.append(nodes[name].start)
            nameRanges.append(nodes[name].end)
        }
        var signatureStart = n.start, signatureEnd = n.start
        if let (a, b) = view.signature(decl) {
            signatureStart = a
            signatureEnd = b
        }
        statements.append(Statement(kind: d.kind, flags: d.flags, traits: traits, firstName: firstName,
                                    start: n.start, end: n.end,
                                    signatureStart: signatureStart, signatureEnd: signatureEnd))
    }
}

/// Read-only helpers over a post-order node array (the summary's and the
/// tree's shared vocabulary).
struct NodeView {
    let nodes: [SyntaxNode]

    func subtree(_ i: Int) -> ClosedRange<Int> { (i - Int(nodes[i].size))...i }

    func children(_ i: Int) -> [Int] {
        var out: [Int] = []
        let lo = i - Int(nodes[i].size)
        var c = i - 1
        while c >= lo {
            out.append(c)
            c -= Int(nodes[c].size) + 1
        }
        return out.reversed()
    }

    func firstChild(_ i: Int, kind: SyntaxKind) -> Int? {
        children(i).first { nodes[$0].kind == kind }
    }

    /// From the definition's name to the end of its header (before the body).
    func signature(_ i: Int) -> (Int32, Int32)? {
        let bodyKinds: Set<SyntaxKind>
        switch nodes[i].kind {
        case .funcDef, .classDef: bodyKinds = [.block]
        case .funcDecl, .classDecl: bodyKinds = [.block, .classBody]
        case .interfaceDecl: bodyKinds = [.objectType]
        default: return nil
        }
        let cs = children(i).filter { nodes[$0].kind != .decorator }
        guard let first = cs.first else { return nil }
        var end = nodes[first].start
        for c in cs {
            if bodyKinds.contains(nodes[c].kind) { break }
            end = nodes[c].end
        }
        return (nodes[first].start, end)
    }

    // MARK: Python

    /// Names bound at module level by Python statement `i` (definitions,
    /// assignment targets, imports, `for` / `with` targets, and the same in
    /// the blocks of top-level compound statements — not inside functions
    /// or classes).
    func pythonBoundNames(_ i: Int, _ out: inout [Int]) {
        let n = nodes[i]
        switch n.kind {
        case .funcDef, .classDef, .typeAliasStmt:
            if let name = firstChild(i, kind: .name) { out.append(name) }
        case .assign:
            let cs = children(i)
            for t in cs.dropLast() { pythonTargetNames(t, &out) }
        case .annAssign:
            if let t = children(i).first { pythonTargetNames(t, &out) }
        case .importStmt:
            for alias in children(i) where nodes[alias].kind == .alias {
                let cs = children(alias)
                if cs.count >= 2, nodes[cs[1]].kind == .name {
                    out.append(cs[1])
                } else if let dotted = cs.first, nodes[dotted].kind == .dottedName,
                          let head = children(dotted).first {
                    out.append(head)
                }
            }
        case .importFrom:
            for alias in children(i) where nodes[alias].kind == .alias {
                let cs = children(alias)
                if let last = cs.last, nodes[last].kind == .name { out.append(last) }
            }
        case .forStmt:
            let cs = children(i)
            if let t = cs.first { pythonTargetNames(t, &out) }
            for c in cs where nodes[c].kind == .block || nodes[c].kind == .elseClause { pythonBoundNames(c, &out) }
        case .withStmt:
            for c in children(i) {
                if nodes[c].kind == .withItem {
                    let parts = children(c)
                    if parts.count >= 2 { pythonTargetNames(parts[1], &out) }
                } else if nodes[c].kind == .block {
                    pythonBoundNames(c, &out)
                }
            }
        case .exceptClause:
            for c in children(i) {
                if nodes[c].kind == .name { out.append(c) }
                if nodes[c].kind == .block { pythonBoundNames(c, &out) }
            }
        case .exprStmt:
            for c in children(i) where nodes[c].kind == .walrus {
                if let name = children(c).first { out.append(name) }
            }
        case .block, .ifStmt, .elifClause, .elseClause, .whileStmt, .tryStmt, .finallyClause, .matchStmt,
             .caseClause:
            for c in children(i) {
                switch nodes[c].kind {
                case .block, .elifClause, .elseClause, .exceptClause, .finallyClause, .caseClause, .funcDef, .classDef,
                     .assign, .annAssign, .importStmt, .importFrom, .forStmt, .withStmt, .ifStmt, .whileStmt, .tryStmt,
                     .matchStmt, .typeAliasStmt, .exprStmt:
                    pythonBoundNames(c, &out)
                default:
                    break
                }
            }
        default:
            break
        }
    }

    /// Plain names in an assignment target (names, tuples, lists, starred).
    func pythonTargetNames(_ t: Int, _ out: inout [Int]) {
        switch nodes[t].kind {
        case .name: out.append(t)
        case .tuple, .list, .paren, .starred:
            for c in children(t) { pythonTargetNames(c, &out) }
        default: break
        }
    }

    // MARK: Script

    /// Names bound at module level by script statement `i`.
    func scriptBoundNames(_ i: Int, _ out: inout [Int]) {
        switch nodes[i].kind {
        case .funcDecl, .classDecl, .interfaceDecl, .typeAlias, .enumDecl:
            if let name = firstChild(i, kind: .name) { out.append(name) }
        case .namespaceDecl:
            if let q = firstChild(i, kind: .qualifiedName), let head = children(q).first { out.append(head) }
        case .varDecl:
            for d in children(i) where nodes[d].kind == .declarator {
                if let b = children(d).first { bindingNames(b, &out) }
            }
        case .importDecl:
            for spec in children(i) where nodes[spec].kind == .importSpec {
                let names = children(spec).filter { nodes[$0].kind == .name }
                if nodes[spec].aux & 3 == 3 {
                    if let first = names.first { out.append(first) }   // `import x = …`
                } else if let last = names.last {
                    out.append(last)
                }
            }
        case .exportDecl:
            if nodes[i].aux & ~SyntaxAux.typeOnly <= 1 {
                for c in children(i) { scriptBoundNames(c, &out) }
            }
        default:
            break
        }
    }

    /// Names bound by a binding target (name or destructuring pattern).
    func bindingNames(_ b: Int, _ out: inout [Int]) {
        switch nodes[b].kind {
        case .name:
            out.append(b)
        case .objectPattern, .arrayPattern:
            for c in children(b) { bindingNames(c, &out) }
        case .patternProp:
            let cs = children(b)
            // aux 1: shorthand `{a}` / `{a = 1}`; 2: keyed `{k: target}`.
            if nodes[b].aux == 1 { if let f = cs.first { bindingNames(f, &out) } }
            else if cs.count >= 2 { bindingNames(cs[1], &out) }
        case .assignPattern, .restElement:
            if let f = children(b).first { bindingNames(f, &out) }
        default:
            break
        }
    }
}

/// A byte-capped LRU of statement subtrees parsed on demand from a
/// `ModuleSummary` (M17 T17.11a, plan §8.3). Keyed by statement start in the
/// summary's text; the owner clears it whenever a new summary is published.
public struct SyntaxSubtreeCache: Sendable {
    /// Default cap on the cached trees' bytes.
    public static let defaultByteLimit = 2 << 20

    public let byteLimit: Int
    private var entries: [(start: Int32, tree: SyntaxTree, bytes: Int)] = []
    public private(set) var bytes = 0

    public init(byteLimit: Int = SyntaxSubtreeCache.defaultByteLimit) {
        self.byteLimit = byteLimit
    }

    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }

    /// The cached tree of the statement starting at `start` (marks it recent).
    public mutating func tree(startingAt start: Int32) -> SyntaxTree? {
        guard let k = entries.lastIndex(where: { $0.start == start }) else { return nil }
        let entry = entries.remove(at: k)
        entries.append(entry)
        return entry.tree
    }

    /// Caches `tree` (not when it alone exceeds the cap), evicting the least
    /// recently used entries past the cap.
    public mutating func insert(_ tree: SyntaxTree, startingAt start: Int32) {
        let size = tree.retainedBytes
        entries.removeAll { $0.start == start }
        bytes = entries.reduce(0) { $0 + $1.bytes }
        guard size <= byteLimit else { return }
        entries.append((start, tree, size))
        bytes += size
        while bytes > byteLimit, !entries.isEmpty {
            bytes -= entries.removeFirst().bytes
        }
    }

    public mutating func removeAll() {
        entries = []
        bytes = 0
    }
}
