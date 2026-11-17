import Foundation

/// Per-snapshot query acceleration for completion (M17 T17.5, plan §5.2
/// "接口"): answers `visibleBindings`-style questions at the caret without
/// decoding the whole snapshot per keystroke.
///
/// Built once per published `DeclarationScan` (one linear pass over both
/// streams) and cached by the completion engine for that snapshot:
/// - **Module bindings**: the bindings owned by the module scope (one per
///   name, first declaration), sorted by case-folded name for prefix lookup.
///   Inside a function they are visible everywhere; at module level the
///   query applies the JS temporal dead zone / brace "after the
///   declaration" rule against the caret.
/// - **Seek points** into both varint streams (every `declarationStride`
///   declarations, every `scopeStride` scopes with the scopes open there),
///   so the scope chain at an offset and the declarations of one scope
///   range decode locally.
/// - `localBindings(at:)`: the non-module part of `visibleBindings(at:)` —
///   the same rules (`DeclarationScan.sweepBindings`) over the outermost
///   non-module scope of the chain only.
/// - `classMembers(at:)`: members of the innermost enclosing class (`self.` /
///   `this.`): declarations owned by its body plus instance attributes
///   assigned in its methods; for the brace languages also the bodies of
///   same-named class scopes (Rust `impl`, Swift `extension`).
/// - **Embedded regions** (T17.8c, HTML / Markdown hosts): a region is the
///   top level of its child language. The top-level bindings of all regions
///   of one language form that language's *group* (served like module
///   bindings, `group:` = `topLevelGroup(of:)`); `localBindings` sweeps
///   below the region; the host's group (`-1`) never sees a region.
///
/// Offsets are the snapshot's; callers map through
/// `DocumentAnalysis.publishedDeclarations`' journal. Pure value type
/// (`Sendable`), no AppKit.
public struct DeclarationQueryIndex: Sendable {
    public let scan: DeclarationScan

    static let declarationStride = 128
    static let scopeStride = 256

    struct ModuleEntry: Sendable, Equatable {
        var name: Int32
        var location: Int32
        var kind: DeclarationScan.DeclarationKind
    }

    /// A scope record with the stream position it was read from.
    struct PositionedScope: Sendable, Equatable {
        var record: DeclarationScan.ScopeRecord
        /// Reader index of the record's first byte.
        var byte: Int
        /// Running start before the record (its delta's base).
        var base: Int
    }

    private struct DeclarationSeek: Sendable, Equatable {
        var byte: Int32
        var base: Int32
        var first: Int32
    }

    private struct ScopeSeek: Sendable, Equatable {
        var byte: Int32
        var base: Int32
        var index: Int32
        var first: Int32
        /// Scopes open just before this record is read.
        var stack: [PositionedScope]
    }

    /// Named class scope (brace languages), sorted by name index.
    private struct NamedClass: Sendable, Equatable {
        var name: Int32
        /// The top-level group of its chain (`-1` outside regions).
        var group: Int32
        var byte: Int32
        var base: Int32
        var index: Int32
        var start: Int32
        var end: Int32
    }

    private let module: [ModuleEntry]
    /// Embedded regions' top-level bindings by language group (T17.8c).
    private let groups: [Int32: [ModuleEntry]]
    private let declarationSeeks: [DeclarationSeek]
    private let scopeSeeks: [ScopeSeek]
    private let namedClasses: [NamedClass]

    /// Whether `other` holds exactly the same tables (tests: a sliced or
    /// prebuilt index against a fresh one-shot build). The scans are
    /// compared by their streams.
    func hasSameTables(as other: DeclarationQueryIndex) -> Bool {
        module == other.module && groups == other.groups && declarationSeeks == other.declarationSeeks
            && scopeSeeks == other.scopeSeeks && namedClasses == other.namedClasses
            && scan.names == other.scan.names && scan.encodedLocations == other.scan.encodedLocations
            && scan.outline == other.scan.outline && scan.documentLength == other.scan.documentLength
            && scan.constantBits == other.scan.constantBits
    }

    // MARK: - Build

    /// Builds the index of `scan` in one go (`Builder` run to completion).
    public init(scan: DeclarationScan) {
        var builder = Builder(scan: scan)
        while !builder.step(deadline: .max) {}
        self = builder.finish()
    }

    private init(scan: DeclarationScan, module: [ModuleEntry], groups: [Int32: [ModuleEntry]],
                 declarationSeeks: [DeclarationSeek], scopeSeeks: [ScopeSeek], namedClasses: [NamedClass]) {
        self.scan = scan
        self.module = module
        self.groups = groups
        self.declarationSeeks = declarationSeeks
        self.scopeSeeks = scopeSeeks
        self.namedClasses = namedClasses
    }

    /// Resumable construction (T17.15a): the same passes as one build, cut
    /// into steps that stop at a deadline, so the analysis can build a new
    /// snapshot's index in its ~4 ms slices instead of on the keystroke that
    /// first queries it. Phases: the outline pass (scope seeks, named
    /// classes), the declaration pass (declaration seeks, the first
    /// module-owned declaration per name), case folding of the module names
    /// into one flat buffer, and the sort. `step` with `.max` is the one-shot
    /// build; any split yields an equal index.
    ///
    /// Transient memory is a handful of large buffers (per-name first-entry
    /// table, flat folded names, sort keys) rather than one array per name.
    public struct Builder: Sendable {
        public let scan: DeclarationScan
        private enum Phase: Sendable { case outline, declarations, fold, sort, done }
        private var phase = Phase.outline

        /// Records / declarations / names between deadline checks.
        static let defaultChunk = 4_096
        private let chunk: Int

        // Outline pass.
        private var outlineReader: DeclarationScan.Reader
        private var outlineStart = 0
        private var outlineIndex = 0
        private var outlineStack: [PositionedScope] = []
        private var scopeSeeks: [ScopeSeek] = []
        private var namedClasses: [NamedClass] = []

        // Declaration pass.
        private var scopeReader: DeclarationScan.Reader
        private var scopeStart = 0
        private var scopeIndex = 0
        private var pending: DeclarationScan.ScopeRecord?
        private var declarationStack: [DeclarationScan.ScopeRecord] = []
        private var reader: DeclarationScan.Reader
        private var location = 0
        private var count = 0
        private var declarationSeeks: [DeclarationSeek] = []
        /// Module-owned first declarations in document order; `firstEntry`
        /// maps a name index to its position there (-1: none yet).
        private var entries: [ModuleEntry] = []
        private var firstEntry: [Int32] = []
        private var firstInGroup: [Int32: [Int32: ModuleEntry]] = [:]
        private var groupOrder: [Int32: [Int32]] = [:]

        // Fold / sort.
        private var foldPosition = 0
        private var folded: [UInt16] = []
        private var keys: [SortKey] = []
        private var module: [ModuleEntry] = []
        private var groups: [Int32: [ModuleEntry]] = [:]

        /// A module entry's sort key: the first four folded units packed
        /// (zero-padded) and its slice of the flat folded buffer.
        fileprivate struct SortKey: Sendable {
            var head: UInt64
            var start: Int32
            var length: Int32
            var entry: Int32
        }

        public init(scan: DeclarationScan) {
            self.init(scan: scan, chunk: Self.defaultChunk)
        }

        /// `chunk`: work items between deadline checks (tests use tiny ones).
        init(scan: DeclarationScan, chunk: Int) {
            self.scan = scan
            self.chunk = max(1, chunk)
            outlineReader = DeclarationScan.Reader(scan.outline)
            scopeReader = DeclarationScan.Reader(scan.outline)
            reader = DeclarationScan.Reader(scan.encodedLocations)
        }

        public var isFinished: Bool { phase == .done }

        /// Works until `deadline` (`DispatchTime` uptime nanoseconds; `.max`:
        /// to completion); true once the index is ready for `finish()`.
        public mutating func step(deadline: UInt64) -> Bool {
            while phase != .done {
                switch phase {
                case .outline: outlinePass(deadline)
                case .declarations: declarationPass(deadline)
                case .fold: foldPass(deadline)
                case .sort: sortPass()
                case .done: break
                }
                if phase != .done, deadline != .max, DispatchTime.now().uptimeNanoseconds >= deadline { return false }
            }
            return true
        }

        /// The built index (after `step` returned true).
        public func finish() -> DeclarationQueryIndex {
            precondition(phase == .done, "DeclarationQueryIndex.Builder.finish() before the last step")
            return DeclarationQueryIndex(scan: scan, module: module, groups: groups,
                                         declarationSeeks: declarationSeeks, scopeSeeks: scopeSeeks,
                                         namedClasses: namedClasses)
        }

        @inline(__always)
        private func pastDeadline(_ deadline: UInt64) -> Bool {
            deadline != .max && DispatchTime.now().uptimeNanoseconds >= deadline
        }

        // MARK: Outline pass: scope seeks and named classes

        private mutating func outlinePass(_ deadline: UInt64) {
            let documentLength = scan.documentLength
            let brace = BraceLanguage(identifier: scan.languageIdentifier) != nil
            let regions = scan.hasEmbeddedRegions
            var budget = chunk
            while !outlineReader.atEnd {
                if budget == 0 {
                    if pastDeadline(deadline) { return }
                    budget = chunk
                }
                budget -= 1
                let byte = outlineReader.index
                let base = outlineStart
                outlineStart += outlineReader.varint()
                let packed = outlineReader.varint()
                let name = packed & 1 != 0 ? outlineReader.varint() : -1
                let record = DeclarationScan.ScopeRecord(
                    index: outlineIndex, start: outlineStart, end: outlineStart + (packed >> 4),
                    kind: DeclarationScan.ScopeKind(rawValue: UInt8((packed >> 1) & 7)) ?? .block, name: name)
                if outlineIndex > 0, outlineIndex % DeclarationQueryIndex.scopeStride == 0 {
                    scopeSeeks.append(ScopeSeek(byte: Int32(byte), base: Int32(base), index: Int32(outlineIndex),
                                                first: Int32(record.start), stack: outlineStack))
                }
                while let top = outlineStack.last, record.start >= top.record.end, top.record.end < documentLength {
                    outlineStack.removeLast()
                }
                if record.kind == .class, name >= 0 {
                    // Brace languages: the document's, or an embedded region's child.
                    var group: Int32 = -1
                    if regions, outlineStack.count > 1, outlineStack[1].record.kind == .embedded {
                        group = Int32(outlineStack[1].record.name)
                    }
                    let isBrace = group >= 0 ? BraceLanguage(identifier: scan.names[Int(group)]) != nil : brace
                    if isBrace {
                        namedClasses.append(NamedClass(name: Int32(name), group: group, byte: Int32(byte),
                                                       base: Int32(base), index: Int32(outlineIndex),
                                                       start: Int32(record.start), end: Int32(record.end)))
                    }
                }
                outlineStack.append(PositionedScope(record: record, byte: byte, base: base))
                outlineIndex += 1
            }
            outlineStack = []
            namedClasses.sort { ($0.name, $0.start) < ($1.name, $1.start) }
            firstEntry = [Int32](repeating: -1, count: scan.names.count)
            pending = readScope()
            phase = .declarations
        }

        // MARK: Declaration pass: seeks and module-owned bindings

        private mutating func readScope() -> DeclarationScan.ScopeRecord? {
            guard !scopeReader.atEnd else { return nil }
            scopeStart += scopeReader.varint()
            let packed = scopeReader.varint()
            let name = packed & 1 != 0 ? scopeReader.varint() : -1
            let record = DeclarationScan.ScopeRecord(
                index: scopeIndex, start: scopeStart, end: scopeStart + (packed >> 4),
                kind: DeclarationScan.ScopeKind(rawValue: UInt8((packed >> 1) & 7)) ?? .block, name: name)
            scopeIndex += 1
            return record
        }

        private mutating func declarationPass(_ deadline: UInt64) {
            let documentLength = scan.documentLength
            let hasOutline = scan.scopeCount > 0
            var budget = chunk
            while !reader.atEnd {
                if budget == 0 {
                    if pastDeadline(deadline) { return }
                    budget = chunk
                }
                budget -= 1
                let byte = reader.index
                let base = location
                location += reader.varint()
                let nameKind = reader.varint()
                if count % DeclarationQueryIndex.declarationStride == 0 {
                    declarationSeeks.append(DeclarationSeek(byte: Int32(byte), base: Int32(base),
                                                            first: Int32(location)))
                }
                count += 1
                let nameIndex = Int32(nameKind >> 4)
                let (kind, _) = DeclarationScan.decode(code: nameKind & 15)
                var moduleOwned = !hasOutline
                var group: Int32 = -1
                if hasOutline {
                    while let record = pending, record.start <= location {
                        while let top = declarationStack.last, record.start >= top.end, top.end < documentLength {
                            declarationStack.removeLast()
                        }
                        declarationStack.append(record)
                        pending = readScope()
                    }
                    while let top = declarationStack.last, !scan.contains(top, location) {
                        declarationStack.removeLast()
                    }
                    if !declarationStack.isEmpty {
                        let floor = DeclarationScan.topLevelPosition(declarationStack)
                        moduleOwned = DeclarationScan.ownerPosition(of: kind, stack: declarationStack) == floor
                        if floor == 1 { group = Int32(declarationStack[1].name) }
                    }
                }
                if moduleOwned, group >= 0 {
                    if firstInGroup[group, default: [:]][nameIndex] == nil {
                        firstInGroup[group, default: [:]][nameIndex] = ModuleEntry(name: nameIndex,
                                                                                   location: Int32(location),
                                                                                   kind: kind)
                        groupOrder[group, default: []].append(nameIndex)
                    }
                } else if moduleOwned, firstEntry[Int(nameIndex)] < 0 {
                    firstEntry[Int(nameIndex)] = Int32(entries.count)
                    entries.append(ModuleEntry(name: nameIndex, location: Int32(location), kind: kind))
                }
            }
            declarationStack = []
            firstEntry = []
            folded.reserveCapacity(entries.count * 8)
            keys.reserveCapacity(entries.count)
            phase = .fold
        }

        // MARK: Fold and sort

        /// Appends `name`'s folded units to `buffer`; returns its sort key.
        private static func key(_ name: String, entry: Int, into buffer: inout [UInt16]) -> SortKey {
            let start = buffer.count
            var head: UInt64 = 0
            var n = 0
            for unit in name.utf16 {
                let f = CaseFold.fold(unit)
                buffer.append(f)
                if n < 4 { head |= UInt64(f) << UInt64(48 - 16 * n) }
                n += 1
            }
            return SortKey(head: head, start: Int32(start), length: Int32(n), entry: Int32(entry))
        }

        private mutating func foldPass(_ deadline: UInt64) {
            var budget = chunk
            while foldPosition < entries.count {
                if budget == 0 {
                    if pastDeadline(deadline) { return }
                    budget = chunk
                }
                budget -= 1
                let entry = entries[foldPosition]
                keys.append(Self.key(scan.names[Int(entry.name)], entry: foldPosition, into: &folded))
                foldPosition += 1
            }
            phase = .sort
        }

        /// Sorts `keys` by folded name (`compare`), then by exact UTF-16
        /// spelling — the order `moduleRange` binary-searches.
        private static func sortedEntries(_ entries: [ModuleEntry], keys: inout [SortKey], folded: [UInt16],
                                          names: [String]) -> [ModuleEntry] {
            folded.withUnsafeBufferPointer { f in
                keys.sort { a, b in
                    if a.head != b.head { return a.head < b.head }
                    let la = Int(a.length), lb = Int(b.length)
                    let sa = Int(a.start), sb = Int(b.start)
                    let n = min(la, lb)
                    var i = 0
                    while i < n {
                        let x = f[sa + i], y = f[sb + i]
                        if x != y { return x < y }
                        i += 1
                    }
                    if la != lb { return la < lb }
                    let ra = Array(names[Int(entries[Int(a.entry)].name)].utf16)
                    let rb = Array(names[Int(entries[Int(b.entry)].name)].utf16)
                    return DeclarationQueryIndex.compare(ra, rb) < 0
                }
            }
            return keys.map { entries[Int($0.entry)] }
        }

        private mutating func sortPass() {
            module = Self.sortedEntries(entries, keys: &keys, folded: folded, names: scan.names)
            entries = []
            keys = []
            folded = []
            // Embedded regions' groups (HTML / Markdown hosts; small).
            for (group, order) in groupOrder {
                let first = firstInGroup[group] ?? [:]
                let list = order.compactMap { first[$0] }
                var buffer: [UInt16] = []
                var groupKeys = list.indices.map { Self.key(scan.names[Int(list[$0].name)], entry: $0, into: &buffer) }
                groups[group] = Self.sortedEntries(list, keys: &groupKeys, folded: buffer, names: scan.names)
            }
            firstInGroup = [:]
            groupOrder = [:]
            phase = .done
        }
    }

    /// Lexicographic UTF-16 comparison (−1, 0, 1): prefix-contiguous order.
    static func compare(_ a: [UInt16], _ b: [UInt16]) -> Int {
        let n = min(a.count, b.count)
        var i = 0
        while i < n {
            if a[i] != b[i] { return a[i] < b[i] ? -1 : 1 }
            i += 1
        }
        return a.count == b.count ? 0 : (a.count < b.count ? -1 : 1)
    }

    // MARK: - Module bindings

    /// A module-level binding.
    public struct ModuleBinding: Sendable, Equatable {
        public let name: String
        public let kind: DeclarationScan.DeclarationKind
        public let location: Int
    }

    /// The module bindings (`group` -1) or an embedded language group's
    /// top-level bindings (T17.8c), sorted by folded name.
    @inline(__always)
    private func entries(_ group: Int32) -> [ModuleEntry] {
        group < 0 ? module : groups[group] ?? []
    }

    public var moduleBindingCount: Int { module.count }

    /// Number of top-level bindings of `group` (see `topLevelGroup(of:)`).
    public func moduleBindingCount(group: Int32) -> Int { entries(group).count }

    public func moduleBinding(at position: Int, group: Int32 = -1) -> ModuleBinding {
        let entry = entries(group)[position]
        return ModuleBinding(name: scan.names[Int(entry.name)], kind: entry.kind, location: Int(entry.location))
    }

    /// Positions (in sorted order) of the module bindings (of `group`) whose
    /// case-folded name (`CaseFold`) starts with `loweredPrefix` (already
    /// folded). Empty prefix: everything.
    public func moduleRange(loweredPrefix: [UInt16], group: Int32 = -1) -> Range<Int> {
        let module = entries(group)
        guard !loweredPrefix.isEmpty else { return 0..<module.count }
        func key(_ i: Int) -> [UInt16] { CaseFold.folded(scan.names[Int(module[i].name)]) }
        var lo = 0
        var hi = module.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if Self.compare(key(mid), loweredPrefix) < 0 { lo = mid + 1 } else { hi = mid }
        }
        let lower = lo
        hi = module.count
        while lo < hi {
            let mid = (lo + hi) / 2
            let k = key(mid)
            if k.starts(with: loweredPrefix) || Self.compare(k, loweredPrefix) < 0 { lo = mid + 1 } else { hi = mid }
        }
        return lower..<lo
    }

    /// The module binding (of `group`) spelled exactly `name`, if any.
    public func moduleBinding(named name: String, group: Int32 = -1) -> ModuleBinding? {
        let lowered = CaseFold.folded(name)
        let range = moduleRange(loweredPrefix: lowered, group: group)
        // Exact lowercase matches sort first within the prefix range.
        for i in range {
            let binding = moduleBinding(at: i, group: group)
            guard CaseFold.folded(binding.name) == lowered else { break }
            if binding.name == name { return binding }
        }
        return nil
    }

    /// The name index of the module binding spelled exactly `name` (T17.11d).
    func moduleNameIndex(named name: String, group: Int32 = -1) -> Int? {
        let lowered = CaseFold.folded(name)
        let module = entries(group)
        for i in moduleRange(loweredPrefix: lowered, group: group) {
            let candidate = scan.names[Int(module[i].name)]
            guard CaseFold.folded(candidate) == lowered else { break }
            if candidate == name { return Int(module[i].name) }
        }
        return nil
    }

    /// The top-level group of a chain (outermost first): -1 for the module,
    /// else the name index of the embedded region's language (T17.8c).
    func topLevelGroup(of chain: [PositionedScope]) -> Int32 {
        chain.count > 1 && chain[1].record.kind == .embedded ? Int32(chain[1].record.name) : -1
    }

    /// The top-level group of the regions of child language `language`
    /// (nil when no region of it declares anything at its top level).
    func topLevelGroup(language: String) -> Int32? {
        groups.keys.first { scan.names[Int($0)] == language }
    }

    /// The child language of the embedded region a chain is in, or nil
    /// outside regions (T17.8c).
    func regionLanguage(of chain: [PositionedScope]) -> String? {
        let group = topLevelGroup(of: chain)
        return group >= 0 ? scan.names[Int(group)] : nil
    }

    // MARK: - Chain

    /// The scopes containing `offset`, outermost first, with stream positions.
    func positionedChain(at offset: Int) -> [PositionedScope] {
        let documentLength = scan.documentLength
        var lo = 0
        var hi = scopeSeeks.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if Int(scopeSeeks[mid].first) <= offset { lo = mid + 1 } else { hi = mid }
        }
        var reader = DeclarationScan.Reader(scan.outline)
        var nextStart = 0
        var index = 0
        var stack: [PositionedScope] = []
        if lo > 0 {
            let seek = scopeSeeks[lo - 1]
            reader.index = Int(seek.byte)
            nextStart = Int(seek.base)
            index = Int(seek.index)
            stack = seek.stack
        }
        while !reader.atEnd {
            let byte = reader.index
            let base = nextStart
            nextStart += reader.varint()
            let packed = reader.varint()
            let name = packed & 1 != 0 ? reader.varint() : -1
            let record = DeclarationScan.ScopeRecord(
                index: index, start: nextStart, end: nextStart + (packed >> 4),
                kind: DeclarationScan.ScopeKind(rawValue: UInt8((packed >> 1) & 7)) ?? .block, name: name)
            guard record.start <= offset else { break }
            while let top = stack.last, record.start >= top.record.end, top.record.end < documentLength {
                stack.removeLast()
            }
            stack.append(PositionedScope(record: record, byte: byte, base: base))
            index += 1
        }
        while let top = stack.last, !scan.contains(top.record, offset) { stack.removeLast() }
        return stack
    }

    /// `scopeChain(at:)` served from the seeks (innermost first).
    public func scopeChain(at offset: Int) -> [DeclarationScan.Scope] {
        let chain = positionedChain(at: offset)
        var out: [DeclarationScan.Scope] = []
        for (position, item) in chain.enumerated().reversed() {
            let record = item.record
            out.append(DeclarationScan.Scope(index: record.index,
                                             parent: position > 0 ? chain[position - 1].record.index : nil,
                                             kind: record.kind, name: record.name >= 0 ? scan.names[record.name] : nil,
                                             start: record.start, end: record.end))
        }
        return out
    }

    /// Reader position and base of the first declaration at or after `location`.
    private func declarationStart(atOrAfter location: Int) -> (byte: Int, base: Int) {
        var lo = 0
        var hi = declarationSeeks.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if Int(declarationSeeks[mid].first) < location { lo = mid + 1 } else { hi = mid }
        }
        guard lo > 0 else { return (0, 0) }
        let seek = declarationSeeks[lo - 1]
        return (Int(seek.byte), Int(seek.base))
    }

    // MARK: - Bindings

    /// The bindings `visibleBindings(at:)` returns that are owned by a scope
    /// other than the module (nearest first), and the scope chain at
    /// `offset` (outermost first).
    public func localBindings(at offset: Int) -> [DeclarationScan.ScopedBinding] {
        let chain = positionedChain(at: offset)
        return localBindings(at: offset, chain: chain)
    }

    func localBindings(at offset: Int, chain: [PositionedScope]) -> [DeclarationScan.ScopedBinding] {
        // Below the top level: the module, or an embedded region (T17.8c).
        let top = topLevelGroup(of: chain) >= 0 ? 1 : 0
        guard scan.scopeCount > 0, chain.count >= top + 2 else { return [] }
        let outer = chain[top + 1]
        var start = DeclarationScan.SweepStart()
        let declaration = declarationStart(atOrAfter: outer.record.start)
        start.declarationByte = declaration.byte
        start.declarationBase = declaration.base
        start.outlineByte = outer.byte
        start.outlineBase = outer.base
        start.outlineIndex = outer.record.index
        start.stack = chain[0...top].map(\.record)
        start.from = outer.record.start
        start.until = outer.record.end >= scan.documentLength ? Int.max : outer.record.end
        return scan.sweepBindings(at: offset, chain: chain.map(\.record), start: start, includeModule: false)
    }

    /// Module bindings visible at `offset` given its chain: everything inside
    /// a function; at module level, JS `let` / `const` / `class` and brace
    /// file-level variables only before `offset`.
    func moduleVisible(_ binding: ModuleBinding, at offset: Int, chain: [PositionedScope]) -> Bool {
        let language = regionLanguage(of: chain) ?? scan.languageIdentifier
        let python = language == "python"
        guard !python, binding.location >= offset else { return true }
        let crossed = chain.dropFirst().contains {
            $0.record.kind == .function || $0.record.kind == .lambda || $0.record.kind == .comprehension
        }
        if crossed { return true }
        let brace = BraceLanguage(identifier: language) != nil
        return !(binding.kind == .variable || binding.kind == .class && !brace)
    }

    /// `visibleBindings(at:)` assembled from `localBindings` and the module
    /// bindings (tests; completion matches module names by prefix instead).
    /// Equal to the full sweep in names, kinds and depths; a brace-language
    /// module binding reports its first declaration's location.
    public func visibleBindings(at offset: Int) -> [DeclarationScan.ScopedBinding] {
        guard scan.scopeCount > 0 else {
            return (0..<module.count).map {
                let b = moduleBinding(at: $0)
                return DeclarationScan.ScopedBinding(name: b.name, kind: b.kind, location: b.location, scopeDepth: 0)
            }.sorted { $0.location < $1.location }
        }
        let chain = positionedChain(at: offset)
        guard !chain.isEmpty else { return [] }
        var out = localBindings(at: offset, chain: chain)
        let local = Set(out.map(\.name))
        let group = topLevelGroup(of: chain)
        let depth = chain.count - 1 - (group >= 0 ? 1 : 0)
        for i in 0..<moduleBindingCount(group: group) {
            let b = moduleBinding(at: i, group: group)
            guard !local.contains(b.name), moduleVisible(b, at: offset, chain: chain) else { continue }
            out.append(DeclarationScan.ScopedBinding(name: b.name, kind: b.kind, location: b.location,
                                                     scopeDepth: depth))
        }
        out.sort { ($0.scopeDepth, $0.location) < ($1.scopeDepth, $1.location) }
        return out
    }

    // MARK: - Ranges

    /// The innermost function-like scope (function, lambda) containing
    /// `offset`, as a snapshot range; nil at module / class level.
    public func enclosingFunctionRange(at offset: Int) -> NSRange? {
        let chain = positionedChain(at: offset)
        guard let scope = chain.last(where: { $0.record.kind == .function || $0.record.kind == .lambda }) else {
            return nil
        }
        return NSRange(location: scope.record.start,
                       length: min(scope.record.end, scan.documentLength) - scope.record.start)
    }

    // MARK: - Class members

    /// A member of a class body.
    public struct Member: Sendable, Equatable {
        public let name: String
        public let kind: DeclarationScan.DeclarationKind
        public let location: Int
    }

    /// Members of the innermost class enclosing `offset` (nil when there is
    /// none): declarations owned by its body (methods, fields, class
    /// attributes, nested types) and instance attributes assigned in its
    /// methods, one per name, in document order. For the brace languages,
    /// same-named class scopes (Rust `impl`, Swift `extension`, C# `partial`)
    /// contribute their body declarations too.
    public func classMembers(at offset: Int) -> [Member]? {
        let chain = positionedChain(at: offset)
        guard let classScope = chain.last(where: { $0.record.kind == .class }) else { return nil }
        var seen = Set<String>()
        var out: [Member] = []
        collectMembers(of: classScope, into: &out, seen: &seen)
        let name = classScope.record.name
        let group = topLevelGroup(of: chain)
        if name >= 0, !namedClasses.isEmpty {
            var lo = 0
            var hi = namedClasses.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if Int(namedClasses[mid].name) < name { lo = mid + 1 } else { hi = mid }
            }
            while lo < namedClasses.count, Int(namedClasses[lo].name) == name {
                let other = namedClasses[lo]
                lo += 1
                if Int(other.index) == classScope.record.index || other.group != group { continue }
                let record = DeclarationScan.ScopeRecord(index: Int(other.index), start: Int(other.start),
                                                         end: Int(other.end), kind: .class, name: name)
                collectMembers(of: PositionedScope(record: record, byte: Int(other.byte), base: Int(other.base)),
                               into: &out, seen: &seen)
            }
        }
        return out
    }

    // MARK: - Named class scopes (T17.11d)

    /// The name index of the class scopes named `name` (brace languages:
    /// type bodies, Swift extensions, Rust `impl`s, C++ / C# namespaces),
    /// if any: through the module bindings when the name is one, else by
    /// comparing the distinct class scope names (nested types).
    func classNameIndex(named name: String, group: Int32 = -1) -> Int? {
        func hasScopes(_ index: Int) -> Bool {
            var lo = 0
            var hi = namedClasses.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if Int(namedClasses[mid].name) < index { lo = mid + 1 } else { hi = mid }
            }
            return lo < namedClasses.count && Int(namedClasses[lo].name) == index
        }
        if let index = moduleNameIndex(named: name, group: group), hasScopes(index) { return index }
        let length = name.utf16.count
        var previous: Int32 = -1
        for entry in namedClasses where entry.name != previous {
            previous = entry.name
            let candidate = scan.names[Int(entry.name)]
            if candidate.utf16.count == length, candidate == name { return Int(entry.name) }
        }
        return nil
    }

    /// The class scopes named `nameIndex` in `group` (`-1`: the document's
    /// own top level), in document order.
    func classScopes(nameIndex: Int, group: Int32 = -1) -> [PositionedScope] {
        var lo = 0
        var hi = namedClasses.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if Int(namedClasses[mid].name) < nameIndex { lo = mid + 1 } else { hi = mid }
        }
        var out: [PositionedScope] = []
        while lo < namedClasses.count, Int(namedClasses[lo].name) == nameIndex {
            let entry = namedClasses[lo]
            lo += 1
            guard entry.group == group else { continue }
            let record = DeclarationScan.ScopeRecord(index: Int(entry.index), start: Int(entry.start),
                                                     end: Int(entry.end), kind: .class, name: nameIndex)
            out.append(PositionedScope(record: record, byte: Int(entry.byte), base: Int(entry.base)))
        }
        return out
    }

    /// The members declared directly in one class scope's body (not its
    /// same-named siblings), in document order — every declaration, so a
    /// method sharing a field's name (Rust, Java) is kept.
    func members(ofClassScope scope: PositionedScope) -> [Member] {
        var seen = Set<String>()
        var out: [Member] = []
        collectMembers(of: scope, into: &out, seen: &seen, directOnly: true)
        return out
    }

    /// `directOnly`: only declarations whose innermost scope is the class
    /// body (no instance attributes assigned in its methods), not deduplicated.
    private func collectMembers(of classScope: PositionedScope, into out: inout [Member], seen: inout Set<String>,
                                directOnly: Bool = false) {
        let documentLength = scan.documentLength
        let target = classScope.record
        let until = target.end >= documentLength ? Int.max : target.end
        var outline = DeclarationScan.Reader(scan.outline)
        outline.index = classScope.byte
        var nextStart = classScope.base
        var nextIndex = target.index
        func readNext() -> DeclarationScan.ScopeRecord? {
            guard !outline.atEnd else { return nil }
            nextStart += outline.varint()
            let packed = outline.varint()
            let name = packed & 1 != 0 ? outline.varint() : -1
            let record = DeclarationScan.ScopeRecord(
                index: nextIndex, start: nextStart, end: nextStart + (packed >> 4),
                kind: DeclarationScan.ScopeKind(rawValue: UInt8((packed >> 1) & 7)) ?? .block, name: name)
            nextIndex += 1
            return record
        }
        var pending = readNext()
        var stack: [DeclarationScan.ScopeRecord] = []
        let start = declarationStart(atOrAfter: target.start)
        var reader = DeclarationScan.Reader(scan.encodedLocations)
        reader.index = start.byte
        var location = start.base
        while !reader.atEnd {
            location += reader.varint()
            let nameKind = reader.varint()
            if location < target.start { continue }
            if location >= until { break }
            while let record = pending, record.start <= location {
                while let top = stack.last, record.start >= top.end, top.end < documentLength { stack.removeLast() }
                stack.append(record)
                pending = readNext()
            }
            while let top = stack.last, !scan.contains(top, location) { stack.removeLast() }
            guard let innermost = stack.last else { continue }
            let (kind, _) = DeclarationScan.decode(code: nameKind & 15)
            let isMember: Bool
            if innermost.index == target.index {
                switch kind {
                case .parameter, .import, .global, .nonlocal: isMember = false
                default: isMember = true
                }
            } else if kind == .property, !directOnly {
                // An instance attribute: a member of the nearest class above it.
                isMember = stack.last(where: { $0.kind == .class })?.index == target.index
            } else {
                isMember = false
            }
            guard isMember else { continue }
            let name = scan.names[nameKind >> 4]
            if directOnly || seen.insert(name).inserted {
                out.append(Member(name: name, kind: kind, location: location))
            }
        }
    }
}
