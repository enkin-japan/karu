import Foundation

/// Pure, AppKit-independent completion data source.
///
/// `WordIndex` owns the document's word set and knows how to merge it with a
/// language's keywords and a lightweight symbol scan into a ranked suggestion
/// list. It has no notion of a text view, so it is trivially unit-testable and
/// carries the completion module's only significant heap state (the word set),
/// which the `CompletionController` drops when the module is switched off.
public struct WordIndex {
    /// Every `\w{2,}` token in the document, original case preserved.
    public private(set) var words: Set<String>

    /// A single compiled `\w{2,}` matcher, reused across builds. Word tokens of
    /// length 1 are excluded (they are never worth completing).
    // swiftlint:disable:next force_try
    private static let wordRegex = try! NSRegularExpression(pattern: #"\w{2,}"#)

    /// Builds the full word set from `text`.
    public init(text: String) {
        words = Self.tokenize(text)
    }

    /// Rebuilds the word set from scratch.
    ///
    /// v1 decision: this is a **full** rebuild, not an incremental diff. Keeping
    /// an incrementally-maintained word set correct across arbitrary edits (a
    /// removed occurrence must only drop the word when *no* other occurrence
    /// remains) needs per-word occurrence counts and range bookkeeping whose
    /// complexity is not justified — a full rebuild of a 1 MB document scans in
    /// well under 10 ms. The `CompletionController` calls this **debounced**
    /// (0.15 s), so bursts of keystrokes collapse into one rebuild.
    public mutating func update(text: String) {
        words = Self.tokenize(text)
    }

    private static func tokenize(_ text: String) -> Set<String> {
        let ns = text as NSString
        guard ns.length > 0 else { return [] }
        var set = Set<String>()
        wordRegex.enumerateMatches(in: text,
                                   range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let range = match?.range else { return }
            set.insert(ns.substring(with: range))
        }
        return set
    }

    // MARK: - Lightweight symbol scan

    /// A document's declared names, split into the three categories the
    /// highlighter colours (and whose union the completion module ranks). This
    /// is the classified result of a rough, single-pass regex scan — not a
    /// parser — so a name may occasionally land in the wrong bucket; the scan
    /// errs toward *not* colouring rather than mis-colouring where cheap.
    public struct SymbolTable: Equatable {
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
    private struct DeclarationPattern {
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
    private static let cLikeNonSymbols: Set<String> = [
        "if", "for", "while", "switch", "catch", "return", "sizeof",
        "else", "do", "new", "delete",
    ]

    /// Names captured by a language's variable heuristics that are pseudo-keywords
    /// rather than user bindings, so they are dropped from the variable set (and
    /// from the navigator). Python's `self` / `cls` are the receiver names of a
    /// method's parameter list; the tokenizer already colours them as `.property`.
    private static func nonVariableNames(for languageIdentifier: String) -> Set<String> {
        switch languageIdentifier {
        case "python": return ["self", "cls"]
        default:       return []
        }
    }

    /// The per-language declaration patterns, in the order they should be scanned.
    /// Empty for unsupported languages. Both symbol scans iterate this list; the
    /// shared classification rules (control-word filtering for the `name(`
    /// heuristic, and demoting a variable name that is also a function/type) are
    /// applied afterwards by whichever scan consumes it.
    private static func declarationPatterns(for languageIdentifier: String) -> [DeclarationPattern] {
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
        default:
            return []
        }
    }

    /// Extracts and **classifies** declared names (functions, types, variables)
    /// from `text` for the given language, in one pass per pattern. This is a
    /// deliberately rough regex scan, not a parser: it feeds both the highlight
    /// engine's in-document symbol colouring and (via `symbols(text:…)`) the
    /// completion ranking. Unsupported languages return `.empty`.
    public static func symbolTable(text: String, languageIdentifier: String) -> SymbolTable {
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
    public static func scanSymbolLocations(text: String,
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
    public static func symbols(text: String, languageIdentifier: String) -> Set<String> {
        symbolTable(text: text, languageIdentifier: languageIdentifier).all
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

    // MARK: - Suggestions

    /// Maximum number of suggestions returned. A completion popup showing more
    /// than this is noise, and capping bounds the work the UI has to do.
    public static let maxSuggestions = 50

    /// Ranked, prefix-matched suggestions for `prefix`.
    ///
    /// Candidates come from three sources — the scanned `symbols`, the language
    /// `keywords`, and the document word set — matched **case-insensitively** on
    /// their prefix while the original casing is preserved in the result.
    /// Ordering is symbols > keywords > document words, each group sorted in
    /// dictionary (case-insensitive) order, deduplicated case-insensitively
    /// across groups by the above priority, and truncated to `maxSuggestions`.
    public func suggestions(prefix: String,
                            language keywords: [String],
                            symbols: Set<String>) -> [String] {
        let lower = prefix.lowercased()
        guard !lower.isEmpty else { return [] }

        func matches(_ word: String) -> Bool { word.lowercased().hasPrefix(lower) }

        let symbolHits = dictSorted(symbols.filter(matches))
        var used = Set(symbolHits.map { $0.lowercased() })

        let keywordHits = dictSorted(keywords.filter { matches($0) && !used.contains($0.lowercased()) })
        used.formUnion(keywordHits.map { $0.lowercased() })

        let wordHits = dictSorted(words.filter { matches($0) && !used.contains($0.lowercased()) })

        return Array((symbolHits + keywordHits + wordHits).prefix(Self.maxSuggestions))
    }

    /// Case-insensitive dictionary sort, with exact-string tie-break so the
    /// order is deterministic when two entries differ only in case.
    private func dictSorted(_ array: [String]) -> [String] {
        array.sorted { lhs, rhs in
            switch lhs.lowercased().compare(rhs.lowercased()) {
            case .orderedSame:       return lhs < rhs
            case .orderedAscending:  return true
            case .orderedDescending: return false
            }
        }
    }
}
