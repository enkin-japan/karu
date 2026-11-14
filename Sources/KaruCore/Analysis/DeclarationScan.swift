import Foundation

/// One declaration pass over a document, with every product the editor needs
/// derived from it (M17 T17.1, plan §3 "声明与作用域"; scopes T17.4a).
///
/// Products:
/// - `locations`: every listed declared name with its capture range, document
///   order (the navigator's list);
/// - `table`: the listed names split into functions / types / variables (the
///   highlighter's colours);
/// - `completionSymbols`: the table's union (completion ranking);
/// - the **scope outline** with `visibleBindings(at:)` / `scopeChain(at:)`
///   (T17.5 weights candidates with it).
///
/// **Walkers.** Every language with declarations runs the token-based,
/// resumable `DeclarationScanner`: declarations are read from the lexer's
/// code segments only (never from comments, strings, character literals or
/// raw strings), with a hand-written walker per family that also records
/// parameters, locals, destructuring and the scope outline — Python and JS /
/// TS (T17.4a), and Swift, Go, Rust, Java, C#, C, C++ in one shared brace
/// walker with per-language rules (`BraceDeclarationWalker`, T17.4b). The
/// T17.1 regex pass (`regexScan`, `WordIndex.declarationPatterns`) remains
/// only as the test / benchmark reference of the old behaviour.
///
/// **Table-only references** (Java, C#, C, C++): the regex path coloured
/// every `name(` call and `class` / `struct` name; the walker keeps that
/// colour coverage by entering calls (functions unless also a type) and
/// `new T` / `class T` / `struct T` (types) into `table` and
/// `completionSymbols` without making them declarations.
///
/// **Listed vs scope-only declarations.** Every declaration carries a rich
/// `DeclarationKind`. The table, `completionSymbols` and `locations` keep
/// today's *coverage* (scope-only names reach completion through
/// `visibleBindings`, T17.5): for
/// Python only the forms the legacy regexes captured (def / class names,
/// parameters, a single-name assignment target, the first `for` target, `as`
/// aliases) are *listed*; tuple / starred / annotated targets, imports without
/// alias, comprehension, lambda, walrus, `global` / `nonlocal` and `match`
/// capture names are scope-only (VS Code's Python grammar paints no variable
/// references, so colouring more names would only add disagreement until
/// T17.7 classifies by position). JavaScript / TypeScript list everything
/// (its grammar paints parameters, locals, members and types). The brace
/// languages list per category (`BraceDeclarationWalker.listing`). Rich kinds map
/// to the legacy three: function / method → function; class / type → type;
/// the rest → variable.
///
/// **Memory**: interned names plus two varint byte streams: declarations
/// (`varint(Δlocation)`, `varint(nameIndex << 4 | kindCode)`) and the scope
/// outline (pre-order records `varint(Δstart)`, `varint(length << 4 | kind <<
/// 1 | hasName)`, `[varint(nameIndex)]`; parents are implied by nesting). No
/// per-declaration scope storage: a declaration's scope is the innermost scope
/// containing its location. Queries decode linearly (O(scopes +
/// declarations)).
///
/// Pure value code: no AppKit, no shared mutable state, `Sendable` (plan §3
/// "可移植性约束").
public struct DeclarationScan: Sendable, Equatable {
    /// Rich declaration kinds (T17.4a).
    public enum DeclarationKind: UInt8, Sendable, CaseIterable {
        case function
        /// A method of a class (Python `def` in a class body, JS class method).
        case method
        case `class`
        /// TS interface / type alias / enum / namespace, generic type parameters.
        case type
        /// Python local or global; JS `let` / `const`.
        case variable
        /// JS `var` (function-scoped).
        case functionScopedVariable
        case parameter
        case `import`
        /// Class attribute / field.
        case property
        /// Python `global x`: `x` binds in the module scope.
        case global
        /// Python `nonlocal x`: `x` binds in the nearest enclosing function.
        case nonlocal

        /// The highlighter / navigator category.
        public var symbolKind: WordIndex.SymbolKind {
            switch self {
            case .function, .method: return .function
            case .class, .type: return .type
            default: return .variable
            }
        }
    }

    /// Scope kinds of the outline.
    public enum ScopeKind: UInt8, Sendable {
        case module, `class`, function
        /// Python `lambda`, JS arrow function.
        case lambda
        case comprehension
        /// JS block / `for` / `catch` / namespace.
        case block
    }

    /// One declaration (listed or scope-only) in document order.
    public struct Declaration: Equatable, Sendable {
        public let name: String
        public let kind: DeclarationKind
        public let location: Int
        /// In the table and `locations` (see the type comment).
        public let isListed: Bool
        public var range: NSRange { NSRange(location: location, length: name.utf16.count) }
    }

    /// One scope of the outline. `end` is exclusive; a scope ending at the
    /// document end also contains the document-end offset.
    public struct Scope: Equatable, Sendable {
        public let index: Int
        public let parent: Int?
        public let kind: ScopeKind
        public let name: String?
        public let start: Int
        public let end: Int
        public var range: NSRange { NSRange(location: start, length: end - start) }
    }

    /// A binding visible at an offset (`visibleBindings(at:)`).
    public struct ScopedBinding: Equatable, Sendable {
        public let name: String
        public let kind: DeclarationKind
        public let location: Int
        /// 0 = the innermost scope containing the offset, 1 its parent, …
        public let scopeDepth: Int
        public var range: NSRange { NSRange(location: location, length: name.utf16.count) }
    }

    public let languageIdentifier: String
    public let table: WordIndex.SymbolTable
    public let completionSymbols: Set<String>
    /// UTF-16 length of the scanned text; offsets refer to that version.
    public let documentLength: Int
    /// Number of scopes in the outline (0 for the regex languages).
    public let scopeCount: Int

    /// Distinct declared names referenced by the streams.
    let names: [String]
    /// Declarations in document order: `varint(Δlocation)`,
    /// `varint(nameIndex << 4 | kindCode)`; the range length is the name's.
    let encodedLocations: [UInt8]
    /// Scope outline (see the type comment).
    let outline: [UInt8]
    /// Seek points into `encodedLocations` (T17.7): pairs (byte index,
    /// running location before that byte), one every `seekStride`
    /// declarations, ascending. Empty for the regex path (decoded from the
    /// start instead).
    let declarationSeeks: [Int32]

    /// Declarations between two seek points.
    static let seekStride = 64

    init(languageIdentifier: String, table: WordIndex.SymbolTable, completionSymbols: Set<String>,
         names: [String], encodedLocations: [UInt8], outline: [UInt8], scopeCount: Int, documentLength: Int,
         declarationSeeks: [Int32] = []) {
        self.languageIdentifier = languageIdentifier
        self.table = table
        self.completionSymbols = completionSymbols
        self.names = names
        self.encodedLocations = encodedLocations
        self.outline = outline
        self.scopeCount = scopeCount
        self.documentLength = documentLength
        self.declarationSeeks = declarationSeeks
    }

    private static func empty(_ languageIdentifier: String, length: Int) -> DeclarationScan {
        DeclarationScan(languageIdentifier: languageIdentifier, table: .empty, completionSymbols: [],
                        names: [], encodedLocations: [], outline: [], scopeCount: 0, documentLength: length)
    }

    /// Bytes held by the compact storage (names' payload estimate, both
    /// streams), for memory reports.
    var compactStorageBytes: (names: Int, declarations: Int, outline: Int) {
        (names.reduce(0) { $0 + $1.utf8.count + 16 }, encodedLocations.count, outline.count)
    }

    // MARK: - Kind codes

    /// 4-bit codes: (kind, listed). Combinations not listed here never occur.
    private static let codeTable: [(DeclarationKind, Bool)] = [
        (.function, true), (.method, true), (.class, true), (.type, true),
        (.variable, true), (.variable, false), (.functionScopedVariable, true),
        (.parameter, true), (.parameter, false), (.import, true), (.import, false),
        (.property, true), (.property, false), (.global, false), (.nonlocal, false),
        (.functionScopedVariable, false),
    ]

    static func code(_ kind: DeclarationKind, listed: Bool) -> Int {
        if let exact = codeTable.firstIndex(where: { $0.0 == kind && $0.1 == listed }) { return exact }
        return codeTable.firstIndex { $0.0 == kind } ?? 4
    }

    static func decode(code: Int) -> (DeclarationKind, Bool) {
        codeTable[code & 15]
    }

    // MARK: - Decoding

    struct Reader {
        let bytes: [UInt8]
        var index = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }
        var atEnd: Bool { index >= bytes.count }
        @inline(__always)
        mutating func varint() -> Int {
            var value = 0
            var shift = 0
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                value |= Int(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            return value
        }
    }

    /// Calls `body(location, nameIndex, kind, listed)` for every declaration.
    private func forEachDeclaration(_ body: (Int, Int, DeclarationKind, Bool) -> Void) {
        var reader = Reader(encodedLocations)
        var location = 0
        while !reader.atEnd {
            location += reader.varint()
            let nameKind = reader.varint()
            let (kind, listed) = Self.decode(code: nameKind & 15)
            body(location, nameKind >> 4, kind, listed)
        }
    }

    /// Calls `body(location, name, kind)` for every declaration (listed or
    /// scope-only) whose location lies in `[from, to)`, in document order.
    /// Starts at the last seek point before `from`, so the cost is the
    /// declarations in the range plus at most `seekStride` (T17.7: the
    /// highlighter's position roles for its band).
    public func forEachDeclaration(from: Int, to: Int, _ body: (Int, String, DeclarationKind) -> Void) {
        guard to > from else { return }
        var reader = Reader(encodedLocations)
        var location = 0
        // Last seek whose running location is < `from` (a declaration at the
        // seek's base location itself may precede it).
        var low = 0, high = declarationSeeks.count / 2
        while low < high {
            let mid = (low + high) / 2
            if Int(declarationSeeks[mid * 2 + 1]) < from { low = mid + 1 } else { high = mid }
        }
        if low > 0 {
            reader.index = Int(declarationSeeks[(low - 1) * 2])
            location = Int(declarationSeeks[(low - 1) * 2 + 1])
        }
        while !reader.atEnd {
            location += reader.varint()
            let nameKind = reader.varint()
            if location < from { continue }
            if location >= to { return }
            body(location, names[nameKind >> 4], Self.decode(code: nameKind & 15).0)
        }
    }

    struct ScopeRecord {
        var index: Int
        var start: Int
        var end: Int
        var kind: ScopeKind
        var name: Int   // -1: none
    }

    /// Calls `body(record)` for every scope in pre-order (ascending start).
    private func forEachScope(_ body: (ScopeRecord) -> Bool) {
        var reader = Reader(outline)
        var start = 0
        var index = 0
        while !reader.atEnd {
            start += reader.varint()
            let packed = reader.varint()
            let name = packed & 1 != 0 ? reader.varint() : -1
            let kind = ScopeKind(rawValue: UInt8((packed >> 1) & 7)) ?? .block
            if !body(ScopeRecord(index: index, start: start, end: start + (packed >> 4), kind: kind, name: name)) {
                return
            }
            index += 1
        }
    }

    func contains(_ scope: ScopeRecord, _ offset: Int) -> Bool {
        scope.start <= offset && (offset < scope.end || scope.end >= documentLength)
    }

    // MARK: - Products

    /// Whether a listed declaration appears in the navigator list: the legacy
    /// subtraction (a variable whose name is also a function / type is not
    /// listed again; Python `self` / `cls` never).
    private func isNavigable(_ kind: DeclarationKind, _ name: String) -> Bool {
        switch kind.symbolKind {
        case .function, .type: return true
        case .variable:
            return !table.functions.contains(name) && !table.types.contains(name)
                && !WordIndex.nonVariableNames(for: languageIdentifier).contains(name)
        }
    }

    /// Every listed declared name with the range of its name, in document
    /// order (the navigator). Materialised on each access.
    public var locations: [WordIndex.SymbolLocation] {
        var out: [WordIndex.SymbolLocation] = []
        let excluded = WordIndex.nonVariableNames(for: languageIdentifier)
        forEachDeclaration { location, nameIndex, kind, listed in
            guard listed else { return }
            let name = names[nameIndex]
            let symbolKind = kind.symbolKind
            if symbolKind == .variable,
               table.functions.contains(name) || table.types.contains(name) || excluded.contains(name) { return }
            out.append(WordIndex.SymbolLocation(name: name, kind: symbolKind,
                                                range: NSRange(location: location, length: name.utf16.count)))
        }
        return out
    }

    /// Number of entries in `locations`.
    public var locationCount: Int { locations.count }

    /// Every declaration, listed and scope-only, in document order.
    public var declarations: [Declaration] {
        var out: [Declaration] = []
        forEachDeclaration { location, nameIndex, kind, listed in
            out.append(Declaration(name: names[nameIndex], kind: kind, location: location, isListed: listed))
        }
        return out
    }

    /// The whole outline in pre-order (index 0 is the module scope).
    public var scopes: [Scope] {
        var out: [Scope] = []
        var stack: [ScopeRecord] = []
        forEachScope { record in
            while let top = stack.last,
                  (record.start >= top.end && top.end < documentLength) || record.end > top.end {
                stack.removeLast()
            }
            out.append(Scope(index: record.index, parent: stack.last?.index, kind: record.kind,
                             name: record.name >= 0 ? names[record.name] : nil,
                             start: record.start, end: record.end))
            stack.append(record)
            return true
        }
        return out
    }

    /// The scopes containing `offset`, outermost first (decoded linearly).
    func chainRecords(at offset: Int) -> [ScopeRecord] {
        var stack: [ScopeRecord] = []
        forEachScope { record in
            guard record.start <= offset else { return false }
            while let top = stack.last, record.start >= top.end, top.end < documentLength { stack.removeLast() }
            stack.append(record)
            return true
        }
        while let top = stack.last, !contains(top, offset) { stack.removeLast() }
        return stack
    }

    /// The scopes containing `offset`, **innermost first** (for T17.5's
    /// "current function" weighting). Offsets refer to this scan's text
    /// version; mapping through later edits is the caller's job.
    public func scopeChain(at offset: Int) -> [Scope] {
        let chain = chainRecords(at: offset)
        var out: [Scope] = []
        for (position, record) in chain.enumerated().reversed() {
            out.append(Scope(index: record.index, parent: position > 0 ? chain[position - 1].index : nil,
                             kind: record.kind, name: record.name >= 0 ? names[record.name] : nil,
                             start: record.start, end: record.end))
        }
        return out
    }

    /// The bindings visible at `offset`, one per name, nearest scope first
    /// (sorted by `scopeDepth`, then location).
    ///
    /// Walks the scope chain innermost → module; the nearest scope's binding
    /// of a name shadows outer ones (within one scope the first visible
    /// declaration wins). Rules:
    /// - **Brace languages** (T17.4b): within one scope the latest
    ///   declaration before the offset wins (a body local hides a parameter
    ///   of the same function scope; Rust `let` shadowing).
    /// - A declaration belongs to the innermost scope containing its location,
    ///   except JS `var` (nearest function / arrow / module scope), Python
    ///   `global` (module) and `nonlocal` (the function enclosing its own).
    /// - **Class scopes**: once the chain has crossed a function, lambda or
    ///   comprehension, an enclosing class scope's names are skipped (Python's
    ///   rule; for JS / TS methods and fields likewise, but generic type
    ///   parameters stay visible; for Go, Rust and C likewise, but nested
    ///   types stay visible). **Implicit members** (T17.4b): in Java, C#, C++
    ///   and Swift every member of an enclosing type body (fields, methods,
    ///   nested types — also C++ / C# namespace members) stays visible inside
    ///   its methods (implicit `this` / `self`).
    /// - **JS TDZ**: `let` / `const` / `class` are visible only after their
    ///   declaration when no function boundary lies between the offset and
    ///   their scope; `var`, functions, parameters, imports and types anywhere
    ///   in their scope. The brace languages apply the same rule to their
    ///   locals / file-level variables (`.variable`): a local is visible after
    ///   its declaration only. Python names are visible anywhere in their scope.
    /// - **Instance attributes** (T17.5): a `.property` owned by a function,
    ///   lambda, comprehension or block scope (Python `self.x = …`, JS
    ///   `this.x = …` inside a method) is a class member, not a binding.
    /// - Languages without an outline: every declaration, depth 0.
    ///
    /// Offsets refer to this scan's text version; mapping through later
    /// edits is the caller's job (T17.5: `DocumentAnalysis.publishedDeclarations`
    /// and `DeclarationQueryIndex`, which also serves the same result without
    /// decoding the whole snapshot).
    public func visibleBindings(at offset: Int) -> [ScopedBinding] {
        guard scopeCount > 0 else {
            var seen = Set<Int>()
            var out: [ScopedBinding] = []
            forEachDeclaration { location, nameIndex, kind, _ in
                if seen.insert(nameIndex).inserted {
                    out.append(ScopedBinding(name: names[nameIndex], kind: kind, location: location, scopeDepth: 0))
                }
            }
            return out
        }
        let chain = chainRecords(at: offset)
        guard !chain.isEmpty else { return [] }
        return sweepBindings(at: offset, chain: chain, start: SweepStart(), includeModule: true)
    }

    /// Where a binding sweep starts reading (T17.5): byte offsets and running
    /// bases of both streams, the scopes already open there, and the
    /// declaration window `[from, until)`. The default reads everything.
    struct SweepStart {
        var declarationByte = 0
        var declarationBase = 0
        var outlineByte = 0
        var outlineBase = 0
        var outlineIndex = 0
        var stack: [ScopeRecord] = []
        var from = 0
        var until = Int.max
    }

    /// The `visibleBindings` rules applied to the declarations of
    /// `start`'s window, for the scope `chain` (outermost first) at
    /// `offset`. `includeModule: false` drops bindings owned by the module
    /// scope (served from `DeclarationQueryIndex.moduleBindings`).
    func sweepBindings(at offset: Int, chain: [ScopeRecord], start: SweepStart,
                       includeModule: Bool) -> [ScopedBinding] {
        let python = languageIdentifier == "python"
        let brace = BraceLanguage(identifier: languageIdentifier)
        let implicitMembers = brace?.implicitMembers ?? false
        // Chain position by scope index → depth (0 = innermost).
        var depthOf: [Int: Int] = [:]
        for (position, record) in chain.enumerated() { depthOf[record.index] = chain.count - 1 - position }
        // crossed[d]: a function-like scope lies strictly inside depth d.
        var crossed = [Bool](repeating: false, count: chain.count)
        var seenFunction = false
        for depth in 0..<chain.count {
            crossed[depth] = seenFunction
            let kind = chain[chain.count - 1 - depth].kind
            if kind == .function || kind == .lambda || kind == .comprehension { seenFunction = true }
        }

        struct Best { var depth: Int; var location: Int; var kind: DeclarationKind }
        var best: [Int: Best] = [:]

        // Merged sweep: declarations and scopes are both in document order.
        var stack = start.stack
        var reader = Reader(outline)
        reader.index = start.outlineByte
        var nextStart = start.outlineBase
        var nextIndex = start.outlineIndex
        var pending: ScopeRecord?
        func readNext() -> ScopeRecord? {
            guard !reader.atEnd else { return nil }
            nextStart += reader.varint()
            let packed = reader.varint()
            let name = packed & 1 != 0 ? reader.varint() : -1
            let record = ScopeRecord(index: nextIndex, start: nextStart, end: nextStart + (packed >> 4),
                                     kind: ScopeKind(rawValue: UInt8((packed >> 1) & 7)) ?? .block, name: name)
            nextIndex += 1
            return record
        }
        pending = readNext()

        var declarations = Reader(encodedLocations)
        declarations.index = start.declarationByte
        var location = start.declarationBase
        while !declarations.atEnd {
            location += declarations.varint()
            let nameKind = declarations.varint()
            if location < start.from { continue }
            if location >= start.until { break }
            let nameIndex = nameKind >> 4
            let (kind, _) = Self.decode(code: nameKind & 15)
            while let record = pending, record.start <= location {
                while let top = stack.last, record.start >= top.end, top.end < documentLength { stack.removeLast() }
                stack.append(record)
                pending = readNext()
            }
            while let top = stack.last, !contains(top, location) { stack.removeLast() }
            guard !stack.isEmpty else { continue }
            // The scope the binding belongs to.
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
                // An instance attribute assigned inside a method (Python
                // `self.x = …`, JS `this.x = …`; T17.5) is a member of the
                // class, never a binding of the method or block.
                switch stack[owner].kind {
                case .function, .lambda, .comprehension, .block: continue
                default: break
                }
            default:
                break
            }
            if !includeModule, stack[owner].index == 0 { continue }
            guard let depth = depthOf[stack[owner].index] else { continue }
            // Class scope seen from inside a function.
            if chain[chain.count - 1 - depth].kind == .class, crossed[depth], !implicitMembers {
                if python { continue }
                if brace == nil ? kind != .type : kind != .type && kind != .class { continue }
            }
            // JS temporal dead zone; brace-language locals after their declaration.
            if !python, location >= offset, !crossed[depth],
               kind == .variable || kind == .class && brace == nil { continue }
            if let current = best[nameIndex] {
                if current.depth < depth { continue }
                if current.depth == depth, brace == nil || location >= offset { continue }
            }
            best[nameIndex] = Best(depth: depth, location: location, kind: kind)
        }

        var out = best.map { ScopedBinding(name: names[$0.key], kind: $0.value.kind,
                                           location: $0.value.location, scopeDepth: $0.value.depth) }
        out.sort { ($0.scopeDepth, $0.location) < ($1.scopeDepth, $1.location) }
        return out
    }

    // MARK: - Scan

    /// Languages read by the token-based walkers (T17.4a; the seven brace
    /// languages since T17.4b): every language with declaration patterns.
    static func usesWalker(_ languageIdentifier: String) -> Bool {
        languageIdentifier == "python" || languageIdentifier == "javascript" || languageIdentifier == "typescript"
            || BraceLanguage(identifier: languageIdentifier) != nil
    }

    /// Scans `text` for `languageIdentifier`'s declarations to completion.
    /// Walker languages: the resumable `DeclarationScanner` run in one go
    /// (the sliced path through `DocumentAnalysis` yields an equal value).
    /// Unsupported languages (and empty text) yield empty products.
    public static func scan(text: String, languageIdentifier: String) -> DeclarationScan {
        let ns = text as NSString
        var scanner = DeclarationScanner(languageIdentifier: languageIdentifier)
        return scanner.finish(ns)
    }

    // MARK: - Regex path (T17.1; the test / benchmark reference since T17.4b)

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

    private static func legacyCode(of kind: WordIndex.SymbolKind) -> Int {
        switch kind {
        case .function: return code(.function, listed: true)
        case .type:     return code(.type, listed: true)
        case .variable: return code(.variable, listed: true)
        }
    }

    /// One raw capture: absolute location of the name and its interned index.
    private struct Hit {
        let location: Int
        let name: UInt32
    }

    /// The T17.1 single regex pass (every regex runs exactly once).
    /// Reproduces the legacy scans exactly. Since T17.4b every language with
    /// patterns has a walker, so production only reaches it for languages
    /// without patterns (an empty result); it remains the reference of the
    /// old behaviour for tests and the declaration-scan benchmark.
    static func regexScan(_ ns: NSString, languageIdentifier: String) -> DeclarationScan {
        let patterns = patternCache.patterns(for: languageIdentifier)
        guard !patterns.isEmpty, ns.length > 0 else { return empty(languageIdentifier, length: ns.length) }
        let text = ns as String

        // 1. Raw hits per pattern (each list ascending by location), names
        //    interned, plus which kinds each name was captured as.
        var names: [String] = []
        var nameIndex: [String: UInt32] = [:]
        var kindMasks: [UInt8] = []
        func bit(_ kind: WordIndex.SymbolKind) -> UInt8 {
            switch kind {
            case .function: return 1
            case .type:     return 2
            case .variable: return 4
            }
        }
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
            kindMasks[Int(index)] |= bit(kind)
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
        let functionBit: UInt8 = 1, typeBit: UInt8 = 2, variableBit: UInt8 = 4
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
        let functionOK = names.map { !WordIndex.cLikeNonSymbols.contains($0) }
        let variableOK = names.map {
            !excludedVariables.contains($0) && !functions.contains($0) && !types.contains($0)
        }
        let kinds = patterns.map(\.kind)
        var cursors = [Int](repeating: 0, count: hitsByPattern.count)
        var encoded: [UInt8] = []
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
            let kindCode = legacyCode(of: kind)
            if hit.location != groupLocation {
                groupLocation = hit.location
                groupSeen.removeAll(keepingCapacity: true)
            }
            if groupSeen.contains(where: { $0.name == hit.name && $0.kind == kindCode }) { continue }
            groupSeen.append((hit.name, kindCode))
            appendVarint(hit.location - previous)
            appendVarint(nameIdx << 4 | kindCode)
            previous = hit.location
        }
        hitsByPattern.removeAll()

        return DeclarationScan(languageIdentifier: languageIdentifier,
                               table: table,
                               completionSymbols: table.all,
                               names: names,
                               encodedLocations: encoded,
                               outline: [],
                               scopeCount: 0,
                               documentLength: ns.length)
    }
}
