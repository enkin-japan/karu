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
///
/// Offsets are the snapshot's; callers map through
/// `DocumentAnalysis.publishedDeclarations`' journal. Pure value type
/// (`Sendable`), no AppKit.
public struct DeclarationQueryIndex: Sendable {
    public let scan: DeclarationScan

    static let declarationStride = 128
    static let scopeStride = 256

    struct ModuleEntry: Sendable {
        var name: Int32
        var location: Int32
        var kind: DeclarationScan.DeclarationKind
    }

    /// A scope record with the stream position it was read from.
    struct PositionedScope: Sendable {
        var record: DeclarationScan.ScopeRecord
        /// Reader index of the record's first byte.
        var byte: Int
        /// Running start before the record (its delta's base).
        var base: Int
    }

    private struct DeclarationSeek: Sendable {
        var byte: Int32
        var base: Int32
        var first: Int32
    }

    private struct ScopeSeek: Sendable {
        var byte: Int32
        var base: Int32
        var index: Int32
        var first: Int32
        /// Scopes open just before this record is read.
        var stack: [PositionedScope]
    }

    /// Named class scope (brace languages), sorted by name index.
    private struct NamedClass: Sendable {
        var name: Int32
        var byte: Int32
        var base: Int32
        var index: Int32
        var start: Int32
        var end: Int32
    }

    private let module: [ModuleEntry]
    private let declarationSeeks: [DeclarationSeek]
    private let scopeSeeks: [ScopeSeek]
    private let namedClasses: [NamedClass]

    // MARK: - Build

    public init(scan: DeclarationScan) {
        self.scan = scan
        let documentLength = scan.documentLength
        let brace = BraceLanguage(identifier: scan.languageIdentifier) != nil

        // 1. Outline pass: scope seeks and named classes.
        var scopeSeeks: [ScopeSeek] = []
        var namedClasses: [NamedClass] = []
        do {
            var reader = DeclarationScan.Reader(scan.outline)
            var nextStart = 0
            var index = 0
            var stack: [PositionedScope] = []
            while !reader.atEnd {
                let byte = reader.index
                let base = nextStart
                nextStart += reader.varint()
                let packed = reader.varint()
                let name = packed & 1 != 0 ? reader.varint() : -1
                let record = DeclarationScan.ScopeRecord(
                    index: index, start: nextStart, end: nextStart + (packed >> 4),
                    kind: DeclarationScan.ScopeKind(rawValue: UInt8((packed >> 1) & 7)) ?? .block, name: name)
                if index > 0, index % Self.scopeStride == 0 {
                    scopeSeeks.append(ScopeSeek(byte: Int32(byte), base: Int32(base), index: Int32(index),
                                                first: Int32(record.start), stack: stack))
                }
                if brace, record.kind == .class, name >= 0 {
                    namedClasses.append(NamedClass(name: Int32(name), byte: Int32(byte), base: Int32(base),
                                                   index: Int32(index), start: Int32(record.start),
                                                   end: Int32(record.end)))
                }
                while let top = stack.last, record.start >= top.record.end, top.record.end < documentLength {
                    stack.removeLast()
                }
                stack.append(PositionedScope(record: record, byte: byte, base: base))
                index += 1
            }
        }
        namedClasses.sort { ($0.name, $0.start) < ($1.name, $1.start) }

        // 2. Declaration pass: seeks and module-owned bindings.
        var declarationSeeks: [DeclarationSeek] = []
        var firstModule: [Int32: ModuleEntry] = [:]
        var order: [Int32] = []
        do {
            var outline = DeclarationScan.Reader(scan.outline)
            var nextStart = 0
            var nextIndex = 0
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
            var reader = DeclarationScan.Reader(scan.encodedLocations)
            var location = 0
            var count = 0
            let hasOutline = scan.scopeCount > 0
            while !reader.atEnd {
                let byte = reader.index
                let base = location
                location += reader.varint()
                let nameKind = reader.varint()
                if count % Self.declarationStride == 0 {
                    declarationSeeks.append(DeclarationSeek(byte: Int32(byte), base: Int32(base),
                                                            first: Int32(location)))
                }
                count += 1
                let nameIndex = Int32(nameKind >> 4)
                let (kind, _) = DeclarationScan.decode(code: nameKind & 15)
                var moduleOwned = !hasOutline
                if hasOutline {
                    while let record = pending, record.start <= location {
                        while let top = stack.last, record.start >= top.end, top.end < documentLength {
                            stack.removeLast()
                        }
                        stack.append(record)
                        pending = readNext()
                    }
                    while let top = stack.last, !scan.contains(top, location) { stack.removeLast() }
                    if !stack.isEmpty {
                        moduleOwned = Self.ownerDepth(of: kind, stack: stack) == 0
                    }
                }
                if moduleOwned, firstModule[nameIndex] == nil {
                    firstModule[nameIndex] = ModuleEntry(name: nameIndex, location: Int32(location), kind: kind)
                    order.append(nameIndex)
                }
            }
        }
        var module = order.compactMap { firstModule[$0] }
        let lowered = scan.names.map(CaseFold.folded)
        module.sort { lhs, rhs in
            let order = Self.compare(lowered[Int(lhs.name)], lowered[Int(rhs.name)])
            if order != 0 { return order < 0 }
            return Self.compare(Array(scan.names[Int(lhs.name)].utf16), Array(scan.names[Int(rhs.name)].utf16)) < 0
        }
        self.module = module
        self.declarationSeeks = declarationSeeks
        self.scopeSeeks = scopeSeeks
        self.namedClasses = namedClasses
    }

    /// Stack position of the scope owning a declaration of `kind` whose
    /// innermost scope is `stack.last` (`visibleBindings`' rules); nil when
    /// it is no binding (an instance attribute).
    private static func ownerDepth(of kind: DeclarationScan.DeclarationKind,
                                   stack: [DeclarationScan.ScopeRecord]) -> Int? {
        var owner = stack.count - 1
        switch kind {
        case .functionScopedVariable:
            while owner > 0, stack[owner].kind != .function, stack[owner].kind != .lambda { owner -= 1 }
        case .global:
            owner = 0
        case .nonlocal:
            var o = owner
            while o > 0, stack[o].kind != .function { o -= 1 }
            o -= 1
            while o > 0, stack[o].kind != .function { o -= 1 }
            owner = max(0, o)
        case .property:
            switch stack[owner].kind {
            case .function, .lambda, .comprehension, .block: return nil
            default: break
            }
        default:
            break
        }
        return owner
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

    public var moduleBindingCount: Int { module.count }

    public func moduleBinding(at position: Int) -> ModuleBinding {
        let entry = module[position]
        return ModuleBinding(name: scan.names[Int(entry.name)], kind: entry.kind, location: Int(entry.location))
    }

    /// Positions (in sorted order) of the module bindings whose case-folded
    /// name (`CaseFold`) starts with `loweredPrefix` (already folded).
    /// Empty prefix: everything.
    public func moduleRange(loweredPrefix: [UInt16]) -> Range<Int> {
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

    /// The module binding spelled exactly `name`, if any.
    public func moduleBinding(named name: String) -> ModuleBinding? {
        let lowered = CaseFold.folded(name)
        let range = moduleRange(loweredPrefix: lowered)
        // Exact lowercase matches sort first within the prefix range.
        for i in range {
            let binding = moduleBinding(at: i)
            guard CaseFold.folded(binding.name) == lowered else { break }
            if binding.name == name { return binding }
        }
        return nil
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
        guard scan.scopeCount > 0, chain.count >= 2 else { return [] }
        let outer = chain[1]
        var start = DeclarationScan.SweepStart()
        let declaration = declarationStart(atOrAfter: outer.record.start)
        start.declarationByte = declaration.byte
        start.declarationBase = declaration.base
        start.outlineByte = outer.byte
        start.outlineBase = outer.base
        start.outlineIndex = outer.record.index
        start.stack = [chain[0].record]
        start.from = outer.record.start
        start.until = outer.record.end >= scan.documentLength ? Int.max : outer.record.end
        return scan.sweepBindings(at: offset, chain: chain.map(\.record), start: start, includeModule: false)
    }

    /// Module bindings visible at `offset` given its chain: everything inside
    /// a function; at module level, JS `let` / `const` / `class` and brace
    /// file-level variables only before `offset`.
    func moduleVisible(_ binding: ModuleBinding, at offset: Int, chain: [PositionedScope]) -> Bool {
        let python = scan.languageIdentifier == "python"
        guard !python, binding.location >= offset else { return true }
        let crossed = chain.dropFirst().contains {
            $0.record.kind == .function || $0.record.kind == .lambda || $0.record.kind == .comprehension
        }
        if crossed { return true }
        let brace = BraceLanguage(identifier: scan.languageIdentifier) != nil
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
        let depth = chain.count - 1
        for i in 0..<module.count {
            let b = moduleBinding(at: i)
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
                if Int(other.index) == classScope.record.index { continue }
                let record = DeclarationScan.ScopeRecord(index: Int(other.index), start: Int(other.start),
                                                         end: Int(other.end), kind: .class, name: name)
                collectMembers(of: PositionedScope(record: record, byte: Int(other.byte), base: Int(other.base)),
                               into: &out, seen: &seen)
            }
        }
        return out
    }

    private func collectMembers(of classScope: PositionedScope, into out: inout [Member], seen: inout Set<String>) {
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
            } else if kind == .property {
                // An instance attribute: a member of the nearest class above it.
                isMember = stack.last(where: { $0.kind == .class })?.index == target.index
            } else {
                isMember = false
            }
            guard isMember else { continue }
            let name = scan.names[nameKind >> 4]
            if seen.insert(name).inserted { out.append(Member(name: name, kind: kind, location: location)) }
        }
    }
}
