import Foundation

/// The document word index (M17 T17.5, plan §5.3; `WordIndex` also hosts
/// the declaration-pattern helpers below).
///
/// Every identifier-like word of at least two UTF-16 units in the document
/// (comments and strings included; Unicode letters / digits / `_`, `$` for
/// JS / TS — `IdentifierText`), case preserved, once per spelling, with a
/// saturating occurrence count and its first location. Replaces the
/// pre-T17.5 `Set<String>` that every keystroke filtered with `lowercased()`
/// (141–300 ms on the 10 MB distinct-name probe):
/// - words live in one UTF-16 buffer, ordered by case-folded spelling with
///   an exact-spelling tie-break, so a prefix is a contiguous range found by
///   binary search (`prefixMatches`) and the range is already in dictionary
///   order;
/// - multi-part words are also ordered by their folded initials
///   (`initialsMatches`: `udn` → `userDisplayName`, `user_display_name`).
///
/// Built by `WordIndexBuilder` — in one go (`init(text:)`, small documents,
/// tests) or in bounded steps from a sliced `AnalysisScheduler` job. A full
/// rebuild, never an incremental diff: the controller rebuilds after an
/// edit pause and covers words typed since with its nearby-line scan.
public struct WordIndex: Sendable {
    var storage: WordStorage
    /// Word ids in (folded, exact) order.
    var sorted: [UInt32]
    /// Ids of words with two or more parts, in (folded initials, `sorted`
    /// position) order.
    var initials: [UInt32]
    /// Whether `$` counted as a word character.
    public let allowsDollar: Bool

    /// Builds the index of `text` synchronously.
    public init(text: String, languageIdentifier: String = "") {
        var builder = WordIndexBuilder(dollar: IdentifierText.allowsDollar(languageIdentifier))
        self = builder.finish(text as NSString)
    }

    init(storage: WordStorage, sorted: [UInt32], initials: [UInt32], allowsDollar: Bool) {
        self.storage = storage
        self.sorted = sorted
        self.initials = initials
        self.allowsDollar = allowsDollar
    }

    /// Rebuilds from scratch (see the type comment).
    public mutating func update(text: String) {
        var builder = WordIndexBuilder(dollar: allowsDollar)
        self = builder.finish(text as NSString)
    }

    /// Number of distinct words.
    public var count: Int { sorted.count }

    /// Every word (materialised; tests and diagnostics).
    public var words: Set<String> { Set((0..<storage.count).map { storage.string(UInt32($0)) }) }

    /// Approximate resident bytes (memory reports).
    public var residentBytes: Int {
        storage.units.count * 2 + storage.starts.count * 4 + storage.counts.count
            + storage.firstLocations.count * 4 + sorted.count * 4 + initials.count * 4
    }

    // MARK: - Queries

    public func word(_ id: UInt32) -> String { storage.string(id) }

    /// Occurrences counted at build time (saturating at 255) and the first
    /// location (index-time offsets).
    public func occurrences(of id: UInt32) -> (count: Int, firstLocation: Int) {
        (Int(storage.counts[Int(id)]), Int(storage.firstLocations[Int(id)]))
    }

    /// The id of the word spelled exactly `units`.
    public func lookup(_ units: [UInt16]) -> UInt32? {
        var lo = 0
        var hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if storage.compare(sorted[mid], units) < 0 { lo = mid + 1 } else { hi = mid }
        }
        guard lo < sorted.count, storage.equals(sorted[lo], units) else { return nil }
        return sorted[lo]
    }

    /// Words starting with `query` ignoring case, in dictionary order: up to
    /// `limit` exact-case and `limit` other-case matches among the first
    /// `scanLimit` of the range. `truncated`: the range held more.
    public func prefixMatches(_ query: [UInt16], limit: Int, scanLimit: Int = 4096)
        -> (exact: [UInt32], folded: [UInt32], truncated: Bool) {
        let folded = query.map(CaseFold.fold)
        var lo = 0
        var hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if storage.comparePrefix(sorted[mid], folded) < 0 { lo = mid + 1 } else { hi = mid }
        }
        var exact: [UInt32] = []
        var other: [UInt32] = []
        var position = lo
        var scanned = 0
        while position < sorted.count, storage.comparePrefix(sorted[position], folded) == 0 {
            if scanned >= scanLimit || (exact.count >= limit && other.count >= limit) {
                return (exact, other, true)
            }
            let id = sorted[position]
            if storage.hasExactPrefix(id, query) {
                if exact.count < limit { exact.append(id) }
            } else if other.count < limit {
                other.append(id)
            }
            position += 1
            scanned += 1
        }
        return (exact, other, false)
    }

    /// Multi-part words whose folded initials start with `foldedQuery`, in
    /// dictionary order within equal initials (at most `limit`).
    public func initialsMatches(_ foldedQuery: [UInt16], limit: Int) -> (ids: [UInt32], truncated: Bool) {
        guard foldedQuery.count >= 2 else { return ([], false) }
        var lo = 0
        var hi = initials.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if WordStorage.comparePrefix(storage.initials(initials[mid]), foldedQuery) < 0 {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        var out: [UInt32] = []
        while lo < initials.count, WordStorage.comparePrefix(storage.initials(initials[lo]), foldedQuery) == 0 {
            if out.count >= limit { return (out, true) }
            out.append(initials[lo])
            lo += 1
        }
        return (out, false)
    }

    // MARK: - Lightweight symbol scan

    /// A document's declared names, split into the three categories the
    /// highlighter colours (and whose union the completion module ranks). This
    /// is the classified result of a rough, single-pass regex scan — not a
    /// parser — so a name may occasionally land in the wrong bucket; the scan
    /// errs toward *not* colouring rather than mis-colouring where cheap.
    public struct SymbolTable: Equatable, Sendable {
        public let functions: Set<String>
        public let types: Set<String>
        public let variables: Set<String>

        public init(functions: Set<String> = [],
                    types: Set<String> = [],
                    variables: Set<String> = []) {
            self.functions = functions
            self.types = types
            self.variables = variables
        }

        /// The empty table (unsupported languages, or a released module).
        public static let empty = SymbolTable()

        /// Flat union of all three categories — the shape the completion
        /// module's ranking still consumes via `symbols(text:…)`.
        public var all: Set<String> { functions.union(types).union(variables) }

        public var isEmpty: Bool {
            functions.isEmpty && types.isEmpty && variables.isEmpty
        }
    }

    /// The three declaration categories a scanned name can fall into — the same
    /// split `SymbolTable` colours, exposed as an ordered enum so the positional
    /// scan (`scanSymbolLocations`) and the navigator can tag each hit.
    public enum SymbolKind: Equatable, Sendable {
        case function
        case type
        case variable
    }

    /// A single declared name with its **capture-group range** (the name itself,
    /// so a jump can select exactly that identifier). Produced by
    /// `scanSymbolLocations` in document order.
    public struct SymbolLocation: Equatable, Sendable {
        public let name: String
        public let kind: SymbolKind
        /// Range of the name capture group in the source `NSString`.
        public let range: NSRange

        public init(name: String, kind: SymbolKind, range: NSRange) {
            self.name = name
            self.kind = kind
            self.range = range
        }
    }

    /// A declaration matcher: a regex whose **capture group 1** is the declared
    /// name, plus the category that name belongs to. This is the single shared
    /// source of truth the two scans consume — the `Set`-building
    /// `symbolTable(text:…)` and the positional `scanSymbolLocations(text:…)` —
    /// so neither copies the other's regexes.
    struct DeclarationPattern: Sendable {
        let pattern: String
        let kind: SymbolKind
        /// When non-nil, capture group 1 of `pattern` is a **list** substring —
        /// a parameter list or a destructuring pattern — rather than a single
        /// name. Each match of this inner pattern's group 1 *within that
        /// substring* is then one declared name. This keeps the "group 1 is the
        /// name" contract for the simple patterns while letting a single def /
        /// arrow / destructuring match yield several bindings.
        let listItemPattern: String?

        init(pattern: String, kind: SymbolKind, listItemPattern: String? = nil) {
            self.pattern = pattern
            self.kind = kind
            self.listItemPattern = listItemPattern
        }
    }

    /// Control-flow words that look like a call (`if (…)`, `while (…)`) in the
    /// brace languages' `name(` heuristic but are not user-declared symbols.
    static let cLikeNonSymbols: Set<String> = [
        "if", "for", "while", "switch", "catch", "return", "sizeof",
        "else", "do", "new", "delete",
    ]

    /// Names captured by a language's variable heuristics that are pseudo-keywords
    /// rather than user bindings, so they are dropped from the variable set (and
    /// from the navigator). Python's `self` / `cls` are the receiver names of a
    /// method's parameter list; the tokenizer already colours them as `.property`.
    static func nonVariableNames(for languageIdentifier: String) -> Set<String> {
        switch languageIdentifier {
        case "python": return ["self", "cls"]
        default:       return []
        }
    }

    /// The per-language declaration patterns, in the order they should be scanned.
    /// Empty for unsupported languages. Since T17.4b every language listed here
    /// runs a token-based declaration walker (Python and JS/TS since T17.4a,
    /// the seven brace languages since T17.4b), so these patterns only feed
    /// `DeclarationScan.regexScan` and the legacy scans below — the test and
    /// benchmark reference of the pre-walker behaviour; the shared
    /// classification rules (control-word filtering for the `name(` heuristic,
    /// and demoting a variable name that is also a function/type) are applied
    /// afterwards by whichever scan consumes it.
    static func declarationPatterns(for languageIdentifier: String) -> [DeclarationPattern] {
        switch languageIdentifier {
        case "python":
            return [
                DeclarationPattern(pattern: #"\bdef\s+(\w+)"#, kind: .function),
                DeclarationPattern(pattern: #"\bclass\s+(\w+)"#, kind: .type),
                // Module-level / plain assignments `name = …`, excluding the `==`
                // comparison. `(?m)` anchors `^` to each line, not the whole string.
                DeclarationPattern(pattern: #"(?m)^\s*(\w+)\s*=(?!=)"#, kind: .variable),
                // Loop target: `for name in …` (tuple targets capture the first).
                DeclarationPattern(pattern: #"\bfor\s+(\w+)"#, kind: .variable),
                // Context-manager / import / except alias: `… as name`.
                DeclarationPattern(pattern: #"\bas\s+(\w+)"#, kind: .variable),
                // Function parameters: each name in a `def f(a, b=1, *args, **kw)`
                // list. Group 1 is the parenthesised list; the inner pattern
                // picks the name after `(` or a comma, past any `*`/`**` and
                // skipping default values / annotations. `self` / `cls` are
                // dropped later by `nonVariableNames`.
                DeclarationPattern(pattern: #"\bdef\s+\w+\s*\(([^)]*)\)"#, kind: .variable,
                                   listItemPattern: #"(?:^|,)\s*\*{0,2}\s*([A-Za-z_]\w*)"#),
            ]
        case "javascript", "typescript":
            return [
                DeclarationPattern(pattern: #"\bfunction\s+(\w+)"#, kind: .function),
                DeclarationPattern(pattern: #"\bclass\s+(\w+)"#, kind: .type),
                DeclarationPattern(pattern: #"\b(?:const|let|var)\s+(\w+)"#, kind: .variable),
                // Arrow-function bindings (`const f = (…) => …`, `g = async (…) =>`)
                // read as functions; the shared demotion rule then drops the
                // duplicate variable hit for the same name.
                DeclarationPattern(pattern: #"\b(\w+)\s*=\s*(?:async\s*)?\("#, kind: .function),
                // Named-function parameters: each simple name in a
                // `function f(a, b)` list (past an optional `...` rest).
                DeclarationPattern(pattern: #"\bfunction\s+\w+\s*\(([^)]*)\)"#, kind: .variable,
                                   listItemPattern: #"(?:^|,)\s*(?:\.\.\.)?\s*([A-Za-z_$][\w$]*)"#),
                // Arrow-function parameters: each simple name in `(a, b) => …`.
                DeclarationPattern(pattern: #"\b\w+\s*=\s*(?:async\s*)?\(([^)]*)\)\s*=>"#, kind: .variable,
                                   listItemPattern: #"(?:^|,)\s*(?:\.\.\.)?\s*([A-Za-z_$][\w$]*)"#),
                // Object destructuring: `const { a, b } = …` (first identifier
                // per entry; rename targets / defaults are approximated).
                DeclarationPattern(pattern: #"\b(?:const|let|var)\s*\{([^}]*)\}\s*="#, kind: .variable,
                                   listItemPattern: #"(?:^|,)\s*([A-Za-z_$][\w$]*)"#),
                // Array destructuring: `const [ a, b ] = …`.
                DeclarationPattern(pattern: #"\b(?:const|let|var)\s*\[([^\]]*)\]\s*="#, kind: .variable,
                                   listItemPattern: #"(?:^|,)\s*([A-Za-z_$][\w$]*)"#),
            ]
        case "c", "cpp", "java", "csharp":
            return [
                DeclarationPattern(pattern: #"(\w+)\s*\("#, kind: .function),
                DeclarationPattern(pattern: #"\b(?:class|struct)\s+(\w+)"#, kind: .type),
            ]
        case "go":
            return [
                // Free functions and methods (`func Name(` / `func (r T) Name(`).
                DeclarationPattern(pattern: #"\bfunc\s+(\w+)"#, kind: .function),
                DeclarationPattern(pattern: #"\bfunc\s+\([^)]*\)\s+(\w+)"#, kind: .function),
                DeclarationPattern(pattern: #"\btype\s+(\w+)"#, kind: .type),
            ]
        case "rust":
            return [
                DeclarationPattern(pattern: #"\bfn\s+(\w+)"#, kind: .function),
                DeclarationPattern(pattern: #"\b(?:struct|enum|trait|union)\s+(\w+)"#, kind: .type),
            ]
        case "swift":
            return [
                DeclarationPattern(pattern: #"\bfunc\s+(\w+)"#, kind: .function),
                DeclarationPattern(pattern: #"\b(?:class|struct|enum|protocol|extension)\s+(\w+)"#, kind: .type),
                // Top-level `var` / `let` bindings (declared at column 0, past any
                // access / storage modifiers), so nested properties are excluded.
                DeclarationPattern(
                    pattern: #"(?m)^(?:(?:public|private|internal|fileprivate|open|static|final|lazy|weak|unowned)\s+)*(?:var|let)\s+(\w+)"#,
                    kind: .variable
                ),
            ]
        default:
            return []
        }
    }

    /// Extracts and **classifies** declared names (functions, types, variables)
    /// from `text` for the given language: it feeds both the highlight
    /// engine's in-document symbol colouring and (via `symbols(text:…)`) the
    /// completion ranking. Unsupported languages return `.empty`. Thin wrapper
    /// over `DeclarationScan.scan`, which derives all three declaration
    /// products from one token-walker pass over code segments.
    public static func symbolTable(text: String, languageIdentifier: String) -> SymbolTable {
        DeclarationScan.scan(text: text, languageIdentifier: languageIdentifier).table
    }

    /// One-shot positional scan for the symbol navigator (T8.4): every declared
    /// name with the range of its **name capture group**, in document order.
    /// Same classification as `symbolTable(text:…)`, so the navigator's list
    /// and the highlighter's colours agree. Thin wrapper over
    /// `DeclarationScan.scan`; builds no resident index.
    public static func scanSymbolLocations(text: String,
                                           languageIdentifier: String) -> [SymbolLocation] {
        DeclarationScan.scan(text: text, languageIdentifier: languageIdentifier).locations
    }

    /// Flat set of every declared name, for the completion module's ranking
    /// (the union of `symbolTable(text:…)`). Thin wrapper over
    /// `DeclarationScan.scan`.
    public static func symbols(text: String, languageIdentifier: String) -> Set<String> {
        DeclarationScan.scan(text: text, languageIdentifier: languageIdentifier).completionSymbols
    }

    // MARK: - Legacy scans (test oracle only)

    // The pre-T17.1 implementations, kept verbatim and internal so the
    // `DeclarationScan` equivalence test can assert the shared single pass
    // reproduces them exactly. Production code must not call these: each one
    // re-runs (and recompiles) every declaration regex.

    /// Extracts and **classifies** declared names (functions, types, variables)
    /// from `text` for the given language, in one pass per pattern. This is a
    /// deliberately rough regex scan, not a parser: it feeds both the highlight
    /// engine's in-document symbol colouring and (via `symbols(text:…)`) the
    /// completion ranking. Unsupported languages return `.empty`.
    static func legacySymbolTable(text: String, languageIdentifier: String) -> SymbolTable {
        let patterns = declarationPatterns(for: languageIdentifier)
        guard !patterns.isEmpty else { return .empty }

        var functions = Set<String>()
        var types = Set<String>()
        var variables = Set<String>()
        for declaration in patterns {
            let names: [String]
            if let itemPattern = declaration.listItemPattern {
                names = listCaptures(declaration.pattern, item: itemPattern, in: text)
            } else {
                names = captures(declaration.pattern, in: text)
            }
            switch declaration.kind {
            case .function: functions.formUnion(names)
            case .type:     types.formUnion(names)
            case .variable: variables.formUnion(names)
            }
        }
        // Shared classification: the `name(` heuristic never means a control word,
        // and a name that is also a function/type is not a plain variable (covers
        // Python's assignment-vs-def overlap and JS's arrow-vs-const binding).
        functions.subtract(cLikeNonSymbols)
        variables.subtract(functions)
        variables.subtract(types)
        variables.subtract(nonVariableNames(for: languageIdentifier))
        return SymbolTable(functions: functions, types: types, variables: variables)
    }

    /// One-shot positional scan for the symbol navigator (T8.4): every declared
    /// name with the range of its **name capture group**, in document order.
    ///
    /// Shares `declarationPatterns` and the exact classification rules of
    /// `symbolTable(text:…)` — a control word matched by the `name(` heuristic is
    /// dropped, and a variable hit whose name is also a function/type is dropped —
    /// so the navigator's list and the highlighter's colours agree. This builds
    /// no resident index (ARCHITECTURE.md §3.4 "瞬时不常驻"): the caller uses the
    /// returned array and lets it go.
    static func legacyScanSymbolLocations(text: String,
                                          languageIdentifier: String) -> [SymbolLocation] {
        let patterns = declarationPatterns(for: languageIdentifier)
        guard !patterns.isEmpty else { return [] }
        let ns = text as NSString
        guard ns.length > 0 else { return [] }

        var raw: [SymbolLocation] = []
        for declaration in patterns {
            guard let regex = try? NSRegularExpression(pattern: declaration.pattern) else { continue }
            let itemRegex = declaration.listItemPattern.flatMap { try? NSRegularExpression(pattern: $0) }
            regex.enumerateMatches(in: text,
                                   range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                guard let match, match.numberOfRanges > 1 else { return }
                let listRange = match.range(at: 1)
                guard listRange.location != NSNotFound else { return }
                guard let itemRegex else {
                    raw.append(SymbolLocation(name: ns.substring(with: listRange),
                                              kind: declaration.kind, range: listRange))
                    return
                }
                // List pattern: scan the captured substring for individual names,
                // mapping each inner name range back to absolute text offsets.
                let list = ns.substring(with: listRange)
                let listNS = list as NSString
                itemRegex.enumerateMatches(in: list,
                                           range: NSRange(location: 0, length: listNS.length)) { inner, _, _ in
                    guard let inner, inner.numberOfRanges > 1 else { return }
                    let nameRange = inner.range(at: 1)
                    guard nameRange.location != NSNotFound else { return }
                    let absolute = NSRange(location: listRange.location + nameRange.location,
                                           length: nameRange.length)
                    raw.append(SymbolLocation(name: listNS.substring(with: nameRange),
                                              kind: declaration.kind, range: absolute))
                }
            }
        }
        let excludedVariables = nonVariableNames(for: languageIdentifier)

        // Names promoted to function/type (after control-word filtering) demote a
        // same-named variable hit — the positional mirror of `symbolTable`'s set
        // subtraction — so the arrow binding shows once (as a function) and a
        // reassigned def is not also listed as a variable.
        let functionNames = Set(raw.lazy
            .filter { $0.kind == .function && !cLikeNonSymbols.contains($0.name) }
            .map(\.name))
        let typeNames = Set(raw.lazy.filter { $0.kind == .type }.map(\.name))

        var seen = Set<String>()
        var out: [SymbolLocation] = []
        for hit in raw {
            if hit.kind == .function, cLikeNonSymbols.contains(hit.name) { continue }
            if hit.kind == .variable, excludedVariables.contains(hit.name) { continue }
            if hit.kind == .variable,
               functionNames.contains(hit.name) || typeNames.contains(hit.name) { continue }
            // Collapse a name captured at the same range by two patterns (e.g. a
            // JS arrow binding matched as both variable and function).
            let key = "\(hit.range.location):\(hit.range.length):\(hit.kind)"
            if seen.insert(key).inserted { out.append(hit) }
        }
        out.sort { $0.range.location < $1.range.location }
        return out
    }

    /// Flat set of every declared name, for the completion module's ranking.
    /// Kept as the union of `symbolTable(text:…)` so `CompletionController`
    /// stays unchanged while the highlighter gets the classified view.
    static func legacySymbols(text: String, languageIdentifier: String) -> Set<String> {
        legacySymbolTable(text: text, languageIdentifier: languageIdentifier).all
    }

    /// Collects declared names from a *list* pattern: for every match of
    /// `pattern`, capture group 1 is a list substring (a parameter list or a
    /// destructuring pattern), and every group-1 match of `item` within that
    /// substring is one name. Used for def / arrow parameters and destructuring.
    private static func listCaptures(_ pattern: String, item: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let itemRegex = try? NSRegularExpression(pattern: item) else { return [] }
        let ns = text as NSString
        guard ns.length > 0 else { return [] }
        var out: [String] = []
        regex.enumerateMatches(in: text,
                               range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match, match.numberOfRanges > 1 else { return }
            let listRange = match.range(at: 1)
            guard listRange.location != NSNotFound else { return }
            let list = ns.substring(with: listRange)
            let listNS = list as NSString
            itemRegex.enumerateMatches(in: list,
                                       range: NSRange(location: 0, length: listNS.length)) { inner, _, _ in
                guard let inner, inner.numberOfRanges > 1 else { return }
                let nameRange = inner.range(at: 1)
                guard nameRange.location != NSNotFound else { return }
                out.append(listNS.substring(with: nameRange))
            }
        }
        return out
    }

    /// Collects capture group 1 of every match of `pattern` in `text`.
    private static func captures(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        guard ns.length > 0 else { return [] }
        var out: [String] = []
        regex.enumerateMatches(in: text,
                               range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match, match.numberOfRanges > 1 else { return }
            let range = match.range(at: 1)
            guard range.location != NSNotFound else { return }
            out.append(ns.substring(with: range))
        }
        return out
    }

    // MARK: - Suggestions (context-free)

    /// Maximum number of suggestions returned. A completion popup showing more
    /// than this is noise, and capping bounds the work the UI has to do.
    public static let maxSuggestions = 50

    /// Context-free ranked suggestions for `prefix`: `symbols` as file
    /// declarations, `keywords` as keywords, this index's words as document
    /// words, ranked by `CandidateEngine`'s rules without scope or nearby
    /// information (match tier, then source, then dictionary order).
    /// Duplicate spellings merge; an empty prefix yields nothing.
    public func suggestions(prefix: String,
                            language keywords: [String],
                            symbols: Set<String>) -> [String] {
        guard !prefix.isEmpty else { return [] }
        return CandidateEngine.contextFreeRanking(prefix: prefix, symbols: symbols, keywords: keywords,
                                                  words: self).map(\.name)
    }
}

// MARK: - Storage and builder

/// Interned words: one UTF-16 buffer plus per-word bookkeeping.
struct WordStorage: Sendable {
    var units: [UInt16] = []
    /// Word `i` is `units[starts[i] ..< starts[i + 1]]`.
    var starts: [UInt32] = [0]
    var counts: [UInt8] = []
    var firstLocations: [UInt32] = []

    var count: Int { counts.count }

    @inline(__always) func range(_ id: UInt32) -> Range<Int> {
        Int(starts[Int(id)])..<Int(starts[Int(id) + 1])
    }

    func string(_ id: UInt32) -> String {
        String(utf16CodeUnits: Array(units[range(id)]), count: range(id).count)
    }

    /// Folded order, exact tie-break: −1, 0, 1.
    func compare(_ a: UInt32, _ b: UInt32) -> Int {
        let ra = range(a)
        let rb = range(b)
        let n = min(ra.count, rb.count)
        var exact = 0
        var i = 0
        while i < n {
            let ua = units[ra.lowerBound + i]
            let ub = units[rb.lowerBound + i]
            if ua != ub {
                let fa = CaseFold.fold(ua)
                let fb = CaseFold.fold(ub)
                if fa != fb { return fa < fb ? -1 : 1 }
                if exact == 0 { exact = ua < ub ? -1 : 1 }
            }
            i += 1
        }
        if ra.count != rb.count { return ra.count < rb.count ? -1 : 1 }
        return exact
    }

    /// Word `a` against exact `units`, in the same order as `compare`.
    func compare(_ a: UInt32, _ other: [UInt16]) -> Int {
        let ra = range(a)
        let n = min(ra.count, other.count)
        var exact = 0
        var i = 0
        while i < n {
            let ua = units[ra.lowerBound + i]
            let ub = other[i]
            if ua != ub {
                let fa = CaseFold.fold(ua)
                let fb = CaseFold.fold(ub)
                if fa != fb { return fa < fb ? -1 : 1 }
                if exact == 0 { exact = ua < ub ? -1 : 1 }
            }
            i += 1
        }
        if ra.count != other.count { return ra.count < other.count ? -1 : 1 }
        return exact
    }

    func equals(_ a: UInt32, _ other: [UInt16]) -> Bool {
        let ra = range(a)
        guard ra.count == other.count else { return false }
        var i = 0
        while i < other.count {
            if units[ra.lowerBound + i] != other[i] { return false }
            i += 1
        }
        return true
    }

    /// −1: the folded word sorts before every word with prefix `folded`;
    /// 0: it starts with it; 1: after.
    func comparePrefix(_ a: UInt32, _ folded: [UInt16]) -> Int {
        let ra = range(a)
        var i = 0
        while i < folded.count {
            guard i < ra.count else { return -1 }
            let f = CaseFold.fold(units[ra.lowerBound + i])
            if f != folded[i] { return f < folded[i] ? -1 : 1 }
            i += 1
        }
        return 0
    }

    static func comparePrefix(_ key: [UInt16], _ folded: [UInt16]) -> Int {
        var i = 0
        while i < folded.count {
            guard i < key.count else { return -1 }
            if key[i] != folded[i] { return key[i] < folded[i] ? -1 : 1 }
            i += 1
        }
        return 0
    }

    func hasExactPrefix(_ a: UInt32, _ query: [UInt16]) -> Bool {
        let ra = range(a)
        guard ra.count >= query.count else { return false }
        var i = 0
        while i < query.count {
            if units[ra.lowerBound + i] != query[i] { return false }
            i += 1
        }
        return true
    }

    /// Folded first units of the word's parts (`CandidateMatcher.partStarts`).
    func initials(_ a: UInt32) -> [UInt16] {
        let word = Array(units[range(a)])
        return CandidateMatcher.partStarts(word).map { CaseFold.fold(word[$0]) }
    }
}

/// Bottom-up merge sort of ids that can stop after any number of element
/// moves and resume (sliced index builds).
struct ResumableSort: Sendable {
    private(set) var items: [UInt32]
    private var scratch: [UInt32]
    private var width = 0
    private var cursor = 0
    private var left = 0, leftEnd = 0, right = 0, rightEnd = 0, out = 0
    private var merging = false
    static let run = 16

    init(_ items: [UInt32]) {
        self.items = items
        scratch = []
    }

    var isDone: Bool { width > 0 && width >= items.count && !merging }

    /// Sorts by `less` for about `budget` element moves; true when sorted.
    mutating func step(budget: Int, less: (UInt32, UInt32) -> Bool) -> Bool {
        let n = items.count
        var budget = budget
        if width == 0 {
            // Insertion-sorted runs.
            while cursor < n, budget > 0 {
                let end = min(n, cursor + Self.run)
                var i = cursor + 1
                while i < end {
                    let value = items[i]
                    var j = i - 1
                    while j >= cursor, less(value, items[j]) {
                        items[j + 1] = items[j]
                        j -= 1
                    }
                    items[j + 1] = value
                    i += 1
                }
                budget -= Self.run * 2
                cursor = end
            }
            guard cursor >= n else { return false }
            width = Self.run
            cursor = 0
            if scratch.count != n { scratch = [UInt32](repeating: 0, count: n) }
        }
        while width < n {
            if !merging {
                if cursor >= n {
                    swap(&items, &scratch)
                    width *= 2
                    cursor = 0
                    continue
                }
                left = cursor
                leftEnd = min(n, cursor + width)
                right = leftEnd
                rightEnd = min(n, cursor + 2 * width)
                out = cursor
                merging = true
            }
            while out < rightEnd {
                guard budget > 0 else { return false }
                budget -= 1
                if left < leftEnd, right >= rightEnd || !less(items[right], items[left]) {
                    scratch[out] = items[left]
                    left += 1
                } else {
                    scratch[out] = items[right]
                    right += 1
                }
                out += 1
            }
            merging = false
            cursor = rightEnd
        }
        scratch = []
        return true
    }
}

/// Builds a `WordIndex` in bounded steps over an `NSString` that must not
/// change between steps (the controller's job checks the document version
/// before each slice and drops the builder on any edit).
public struct WordIndexBuilder: Sendable {
    let dollar: Bool
    private var storage = WordStorage()
    private var slots: [Int32] = []
    private var mask = 0
    /// The previous table while `grow` moves it into `slots`.
    private var draining: [Int32] = []
    private var drainMask = 0
    private var drainCursor = 0
    private var position = 0
    private var length = -1
    /// 0 tokenize, 1 sort, 2 initials keys, 3 sort initials, 4 done (diagnostics).
    private(set) var phase = 0
    private var sorter = ResumableSort([])
    private var rank: [UInt32] = []
    private var multiPart: [UInt32] = []
    private var initialSorter = ResumableSort([])
    private var initialKeys: [[UInt16]] = []
    private var result: WordIndex?

    /// Longest run indexed as a word.
    static let maximumWordLength = 128
    /// Units tokenized per step; other phases scale their work from it.
    static let stepUnits = 16_384

    public init(dollar: Bool) {
        self.dollar = dollar
    }

    public var isFinished: Bool { result != nil }
    public var index: WordIndex? { result }

    public mutating func finish(_ text: NSString) -> WordIndex {
        while !step(text, budgetUnits: Self.stepUnits) {}
        return result!
    }

    /// Advances about `budgetUnits` units of work; true when finished.
    @discardableResult
    public mutating func step(_ text: NSString, budgetUnits: Int) -> Bool {
        if result != nil { return true }
        if length < 0 {
            length = text.length
            // Small to start and doubled as words arrive: a large document
            // with few distinct words (generated / repetitive text) must not
            // pay for a table sized by its length.
            let capacity = 4096
            slots = [Int32](repeating: -1, count: capacity)
            mask = capacity - 1
        }
        switch phase {
        case 0:
            if text.length != length {
                // The text changed under the builder: finish with what was read.
                position = length
            }
            if position < length {
                if !draining.isEmpty { drain(budget: max(256, budgetUnits)) }
                tokenize(text, budget: max(1, budgetUnits))
            }
            if position >= length {
                slots = []
                draining = []
                sorter = ResumableSort((0..<UInt32(storage.count)).map { $0 })
                phase = 1
            }
            return false
        case 1:
            let storage = self.storage
            if sorter.step(budget: max(64, budgetUnits / 16), less: { storage.compare($0, $1) < 0 }) {
                rank = [UInt32](repeating: 0, count: storage.count)
                phase = 2
                position = 0
            }
            return false
        case 2:
            // Sorted ranks and the initials of multi-part words.
            var budget = max(32, budgetUnits / 128)
            while position < storage.count, budget > 0 {
                rank[Int(sorter.items[position])] = UInt32(position)
                let key = storage.initials(UInt32(position))
                initialKeys.append(key.count >= 2 ? key : [])
                if key.count >= 2 { multiPart.append(UInt32(position)) }
                position += 1
                budget -= 1
            }
            if position >= storage.count {
                initialSorter = ResumableSort(multiPart)
                multiPart = []
                phase = 3
            }
            return false
        case 3:
            let keys = initialKeys
            let rank = self.rank
            if initialSorter.step(budget: max(64, budgetUnits / 16), less: {
                let order = DeclarationQueryIndex.compare(keys[Int($0)], keys[Int($1)])
                return order != 0 ? order < 0 : rank[Int($0)] < rank[Int($1)]
            }) {
                phase = 4
            }
            return false
        default:
            // Exact-size copies: the buffers grew by doubling.
            storage.units = storage.units.withUnsafeBufferPointer { Array($0) }
            storage.starts = storage.starts.withUnsafeBufferPointer { Array($0) }
            storage.counts = storage.counts.withUnsafeBufferPointer { Array($0) }
            storage.firstLocations = storage.firstLocations.withUnsafeBufferPointer { Array($0) }
            result = WordIndex(storage: storage, sorted: sorter.items, initials: initialSorter.items,
                               allowsDollar: dollar)
            sorter = ResumableSort([])
            initialSorter = ResumableSort([])
            rank = []
            initialKeys = []
            return true
        }
    }

    private mutating func tokenize(_ text: NSString, budget: Int) {
        var end = min(length, position + budget)
        // Never split a word: extend through the run in progress.
        var extended = 0
        while end < length, extended < Self.maximumWordLength * 2 {
            let u = text.character(at: end)
            guard u >= 128 || IdentifierText.isASCIIPart(u, dollar: dollar) else { break }
            end += 1
            extended += 1
        }
        let count = end - position
        guard count > 0 else { return }
        var buffer = [UInt16](repeating: 0, count: count)
        buffer.withUnsafeMutableBufferPointer { pointer in
            text.getCharacters(pointer.baseAddress!, range: NSRange(location: position, length: count))
        }
        let base = position
        var i = 0
        while i < count {
            let u = buffer[i]
            var isStart = false
            var isPart = false
            var width = 1
            if u < 128 {
                isStart = IdentifierText.isASCIIStart(u, dollar: dollar)
                isPart = isStart || (u >= 48 && u <= 57)
            } else {
                let (scalar, w) = Self.scalar(buffer, i)
                width = w
                isPart = IdentifierText.isPart(scalar, dollar: dollar)
                isStart = isPart && IdentifierText.isStart(scalar, dollar: dollar)
            }
            guard isPart else {
                i += width
                continue
            }
            let start = i
            i += width
            while i < count {
                let v = buffer[i]
                if v < 128 {
                    guard IdentifierText.isASCIIPart(v, dollar: dollar) else { break }
                    i += 1
                } else {
                    let (scalar, w) = Self.scalar(buffer, i)
                    guard IdentifierText.isPart(scalar, dollar: dollar) else { break }
                    i += w
                }
            }
            let runLength = i - start
            if isStart, runLength >= 2, runLength <= Self.maximumWordLength {
                intern(buffer, start, i, location: base + start)
            }
        }
        position = end
    }

    private static func scalar(_ buffer: [UInt16], _ i: Int) -> (Unicode.Scalar, Int) {
        let u = buffer[i]
        if IdentifierText.isHighSurrogate(u), i + 1 < buffer.count, IdentifierText.isLowSurrogate(buffer[i + 1]) {
            let value = 0x10000 + ((UInt32(u) - 0xD800) << 10) + (UInt32(buffer[i + 1]) - 0xDC00)
            return (Unicode.Scalar(value) ?? "\u{FFFD}", 2)
        }
        return (Unicode.Scalar(u) ?? "\u{FFFD}", 1)
    }

    private static func hash(_ units: ArraySlice<UInt16>) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for u in units { hash = (hash ^ UInt32(u)) &* 16_777_619 }
        return hash
    }

    /// The id of the word `buffer[start..<end]` in `table`, or the free slot
    /// where its probe ended.
    private func probe(_ table: [Int32], _ tableMask: Int, _ hash: UInt32, _ buffer: [UInt16],
                       _ start: Int, _ end: Int) -> (id: Int32?, slot: Int) {
        var slot = Int(hash) & tableMask
        while true {
            let id = table[slot]
            if id < 0 { return (nil, slot) }
            let range = storage.range(UInt32(id))
            if range.count == end - start {
                var same = true
                var k = 0
                while k < range.count {
                    if storage.units[range.lowerBound + k] != buffer[start + k] {
                        same = false
                        break
                    }
                    k += 1
                }
                if same { return (id, slot) }
            }
            slot = (slot + 1) & tableMask
        }
    }

    private mutating func intern(_ buffer: [UInt16], _ start: Int, _ end: Int, location: Int) {
        let hash = Self.hash(buffer[start..<end])
        var found = probe(slots, mask, hash, buffer, start, end)
        if found.id == nil, !draining.isEmpty {
            let old = probe(draining, drainMask, hash, buffer, start, end)
            if old.id != nil { found = (old.id, found.slot) }
        }
        if let id = found.id {
            if storage.counts[Int(id)] < 255 { storage.counts[Int(id)] += 1 }
            return
        }
        let id = Int32(storage.count)
        storage.units.append(contentsOf: buffer[start..<end])
        storage.starts.append(UInt32(storage.units.count))
        storage.counts.append(1)
        storage.firstLocations.append(UInt32(clamping: location))
        slots[found.slot] = id
        if storage.count * 5 > slots.count * 3 { grow() }
    }

    /// Doubles the table. The old one is moved over incrementally
    /// (`drain`, a bounded amount per step), so no single step rehashes
    /// every word; until then lookups probe both tables.
    private mutating func grow() {
        if !draining.isEmpty { drain(budget: Int.max) }
        draining = slots
        drainMask = mask
        drainCursor = 0
        let capacity = slots.count * 2
        slots = [Int32](repeating: -1, count: capacity)
        mask = capacity - 1
    }

    private mutating func drain(budget: Int) {
        var budget = budget
        while drainCursor < draining.count, budget > 0 {
            let id = draining[drainCursor]
            drainCursor += 1
            budget -= 1
            guard id >= 0 else { continue }
            let range = storage.range(UInt32(id))
            var slot = Int(Self.hash(storage.units[range])) & mask
            while slots[slot] >= 0 { slot = (slot + 1) & mask }
            slots[slot] = id
        }
        if drainCursor >= draining.count {
            draining = []
            drainCursor = 0
        }
    }
}
