import Foundation

/// One declaration pass over a document, with every product the editor needs
/// derived from it (M17 T17.1, plan §3 "声明与作用域").
///
/// Before T17.1 the highlighter (`symbolTable`), completion (`symbols`) and the
/// navigator (`scanSymbolLocations`) each re-ran — and recompiled — the same
/// per-language declaration regexes. `scan` runs them **once** and derives:
/// - `locations`: every declared name with its capture range, document order
///   (the navigator's list);
/// - `table`: the names split into functions / types / variables (the
///   highlighter's colours);
/// - `completionSymbols`: the flat union (completion ranking).
///
/// **Memory**: a scan is held for as long as its document version is current,
/// so the positional list is stored compactly — interned names plus a
/// delta/varint byte stream (about 2–4 bytes per declaration instead of a
/// 40-byte `SymbolLocation`). `locations` materialises the array on demand
/// (the navigator reads it once per open and drops it on close, as before).
///
/// Pure value code: no AppKit, no shared mutable state, `Sendable` — the same
/// function can later run on a background queue for workspace indexing
/// (plan §3 "可移植性约束"). The compiled regexes are immutable statics.
public struct DeclarationScan: Sendable, Equatable {
    public let languageIdentifier: String
    public let table: WordIndex.SymbolTable
    public let completionSymbols: Set<String>

    /// Number of entries in `locations`, without materialising them.
    public let locationCount: Int
    /// Distinct declared names referenced by `encodedLocations`.
    private let names: [String]
    /// The locations in document order, each encoded as
    /// `varint(location − previous location)` then
    /// `varint(nameIndex << 2 | kindCode)`. The range length is the name's
    /// UTF-16 length (the range is exactly the name capture).
    private let encodedLocations: [UInt8]

    /// Every declared name with the range of its name capture, in document
    /// order — exactly what `WordIndex.scanSymbolLocations` returned before
    /// T17.1. Materialised on each access; callers keep it only transiently.
    public var locations: [WordIndex.SymbolLocation] {
        var out: [WordIndex.SymbolLocation] = []
        out.reserveCapacity(locationCount)
        var index = 0
        var location = 0
        let bytes = encodedLocations
        func varint() -> Int {
            var value = 0
            var shift = 0
            while true {
                let byte = bytes[index]
                index += 1
                value |= Int(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
        }
        while index < bytes.count {
            location += varint()
            let nameKind = varint()
            let name = names[nameKind >> 2]
            out.append(WordIndex.SymbolLocation(
                name: name, kind: Self.kind(code: nameKind & 3),
                range: NSRange(location: location, length: name.utf16.count)))
        }
        return out
    }

    // MARK: - Compiled patterns

    /// A declaration pattern with its regexes compiled once per process.
    private struct Compiled: @unchecked Sendable {
        // NSRegularExpression is immutable and documented thread-safe.
        let regex: NSRegularExpression
        let itemRegex: NSRegularExpression?
        let kind: WordIndex.SymbolKind
    }

    private static func compile(_ patterns: [WordIndex.DeclarationPattern]) -> [Compiled] {
        patterns.compactMap { pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern.pattern) else { return nil }
            let item = pattern.listItemPattern.flatMap { try? NSRegularExpression(pattern: $0) }
            if pattern.listItemPattern != nil, item == nil { return nil }
            return Compiled(regex: regex, itemRegex: item, kind: pattern.kind)
        }
    }

    /// Identifier → compiled patterns, compiled on the first scan of that
    /// language only (a JSON-only session compiles nothing). Lock-protected so
    /// the scan stays callable from any thread.
    private final class PatternCache: @unchecked Sendable {
        private let lock = NSLock()
        private var compiled: [String: [Compiled]] = [:]

        func patterns(for languageIdentifier: String) -> [Compiled] {
            let declared = WordIndex.declarationPatterns(for: languageIdentifier)
            guard !declared.isEmpty else { return [] }
            lock.lock()
            defer { lock.unlock() }
            if let cached = compiled[languageIdentifier] { return cached }
            let fresh = DeclarationScan.compile(declared)
            compiled[languageIdentifier] = fresh
            return fresh
        }
    }

    private static let patternCache = PatternCache()

    private static func compiledPatterns(for languageIdentifier: String) -> [Compiled] {
        patternCache.patterns(for: languageIdentifier)
    }

    private static func code(of kind: WordIndex.SymbolKind) -> Int {
        switch kind {
        case .function: return 0
        case .type:     return 1
        case .variable: return 2
        }
    }

    private static func kind(code: Int) -> WordIndex.SymbolKind {
        switch code {
        case 0:  return .function
        case 1:  return .type
        default: return .variable
        }
    }

    private init(languageIdentifier: String, table: WordIndex.SymbolTable, completionSymbols: Set<String>,
                 names: [String], encodedLocations: [UInt8], locationCount: Int) {
        self.languageIdentifier = languageIdentifier
        self.table = table
        self.completionSymbols = completionSymbols
        self.names = names
        self.encodedLocations = encodedLocations
        self.locationCount = locationCount
    }

    private static func empty(_ languageIdentifier: String) -> DeclarationScan {
        DeclarationScan(languageIdentifier: languageIdentifier, table: .empty, completionSymbols: [],
                        names: [], encodedLocations: [], locationCount: 0)
    }

    // MARK: - Scan

    /// One raw capture: absolute location of the name and its interned index.
    private struct Hit {
        let location: Int
        let name: UInt32
    }

    /// Scans `text` for `languageIdentifier`'s declarations — every regex runs
    /// exactly once — and derives the three products. Unsupported languages
    /// (and empty text) yield empty products.
    public static func scan(text: String, languageIdentifier: String) -> DeclarationScan {
        let patterns = compiledPatterns(for: languageIdentifier)
        let ns = text as NSString
        guard !patterns.isEmpty, ns.length > 0 else { return empty(languageIdentifier) }

        // 1. Raw hits per pattern (each list ascending by location), names
        //    interned, plus which kinds each name was captured as.
        var names: [String] = []
        var nameIndex: [String: UInt32] = [:]
        var kindMasks: [UInt8] = []
        func intern(_ name: String, _ kind: WordIndex.SymbolKind) -> UInt32 {
            let index: UInt32
            if let known = nameIndex[name] {
                index = known
            } else {
                index = UInt32(names.count)
                nameIndex[name] = index
                names.append(name)
                kindMasks.append(0)
            }
            kindMasks[Int(index)] |= 1 << UInt8(code(of: kind))
            return index
        }
        let full = NSRange(location: 0, length: ns.length)
        var hitsByPattern: [[Hit]] = []
        for declaration in patterns {
            var hits: [Hit] = []
            declaration.regex.enumerateMatches(in: text, range: full) { match, _, _ in
                guard let match, match.numberOfRanges > 1 else { return }
                let listRange = match.range(at: 1)
                guard listRange.location != NSNotFound else { return }
                guard let itemRegex = declaration.itemRegex else {
                    hits.append(Hit(location: listRange.location,
                                    name: intern(ns.substring(with: listRange), declaration.kind)))
                    return
                }
                // List pattern: each inner name, mapped back to absolute offsets.
                let list = ns.substring(with: listRange)
                let listNS = list as NSString
                itemRegex.enumerateMatches(in: list,
                                           range: NSRange(location: 0, length: listNS.length)) { inner, _, _ in
                    guard let inner, inner.numberOfRanges > 1 else { return }
                    let nameRange = inner.range(at: 1)
                    guard nameRange.location != NSNotFound else { return }
                    hits.append(Hit(location: listRange.location + nameRange.location,
                                    name: intern(listNS.substring(with: nameRange), declaration.kind)))
                }
            }
            hitsByPattern.append(hits)
        }

        // 2. Classified sets — the legacy `symbolTable` rules: the `name(`
        //    heuristic never means a control word, and a name that is also a
        //    function/type is not a plain variable.
        let functionBit: UInt8 = 1 << 0, typeBit: UInt8 = 1 << 1, variableBit: UInt8 = 1 << 2
        let excludedVariables = WordIndex.nonVariableNames(for: languageIdentifier)
        var functions = Set<String>()
        var types = Set<String>()
        var variables = Set<String>()
        for (index, name) in names.enumerated() {
            let mask = kindMasks[index]
            if mask & functionBit != 0, !WordIndex.cLikeNonSymbols.contains(name) { functions.insert(name) }
            if mask & typeBit != 0 { types.insert(name) }
        }
        for (index, name) in names.enumerated() where kindMasks[index] & variableBit != 0 {
            if functions.contains(name) || types.contains(name) || excludedVariables.contains(name) { continue }
            variables.insert(name)
        }
        let table = WordIndex.SymbolTable(functions: functions, types: types, variables: variables)

        // 3. Positional list — the legacy `scanSymbolLocations` rules (the
        //    same subtraction hit by hit; a name captured at the same range
        //    with the same kind by two patterns appears once), in document
        //    order with ties in pattern order: a k-way merge of the already
        //    ascending per-pattern lists, which is exactly the legacy stable
        //    sort of the deduplicated raw list.
        // Per interned name: may a function hit / a variable hit be listed?
        let functionOK = names.map { !WordIndex.cLikeNonSymbols.contains($0) }
        let variableOK = names.map {
            !excludedVariables.contains($0) && !functions.contains($0) && !types.contains($0)
        }
        let kinds = patterns.map(\.kind)
        var cursors = [Int](repeating: 0, count: hitsByPattern.count)
        var encoded: [UInt8] = []
        var count = 0
        var previous = 0
        var groupLocation = -1
        var groupSeen: [(name: UInt32, kind: Int)] = []
        func appendVarint(_ value: Int) {
            var v = value
            while v >= 0x80 {
                encoded.append(UInt8(v & 0x7F) | 0x80)
                v >>= 7
            }
            encoded.append(UInt8(v))
        }
        while true {
            // The pattern whose next hit has the smallest location (lowest
            // pattern index on ties).
            var best = -1
            for p in 0..<hitsByPattern.count where cursors[p] < hitsByPattern[p].count {
                if best < 0 || hitsByPattern[p][cursors[p]].location < hitsByPattern[best][cursors[best]].location {
                    best = p
                }
            }
            guard best >= 0 else { break }
            let hit = hitsByPattern[best][cursors[best]]
            cursors[best] += 1
            let kind = kinds[best]
            let nameIdx = Int(hit.name)
            switch kind {
            case .function: if !functionOK[nameIdx] { continue }
            case .variable: if !variableOK[nameIdx] { continue }
            case .type: break
            }
            let kindCode = code(of: kind)
            if hit.location != groupLocation {
                groupLocation = hit.location
                groupSeen.removeAll(keepingCapacity: true)
            }
            if groupSeen.contains(where: { $0.name == hit.name && $0.kind == kindCode }) { continue }
            groupSeen.append((hit.name, kindCode))
            appendVarint(hit.location - previous)
            appendVarint(nameIdx << 2 | kindCode)
            previous = hit.location
            count += 1
        }
        hitsByPattern.removeAll()

        return DeclarationScan(languageIdentifier: languageIdentifier,
                               table: table,
                               completionSymbols: table.all,
                               names: names,
                               encodedLocations: encoded,
                               locationCount: count)
    }
}
