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

    /// Control-flow words that look like a call (`if (…)`, `while (…)`) in the
    /// brace languages' `name(` heuristic but are not user-declared symbols.
    private static let cLikeNonSymbols: Set<String> = [
        "if", "for", "while", "switch", "catch", "return", "sizeof",
        "else", "do", "new", "delete",
    ]

    /// Extracts and **classifies** declared names (functions, types, variables)
    /// from `text` for the given language, in one pass per pattern. This is a
    /// deliberately rough regex scan, not a parser: it feeds both the highlight
    /// engine's in-document symbol colouring and (via `symbols(text:…)`) the
    /// completion ranking. Unsupported languages return `.empty`.
    public static func symbolTable(text: String, languageIdentifier: String) -> SymbolTable {
        switch languageIdentifier {
        case "python":
            let functions = Set(captures(#"\bdef\s+(\w+)"#, in: text))
            let types = Set(captures(#"\bclass\s+(\w+)"#, in: text))
            // Module-level / plain assignments `name = …`, excluding the `==`
            // comparison. `(?m)` anchors `^` to each line, not just the string.
            var variables = Set(captures(#"(?m)^\s*(\w+)\s*=(?!=)"#, in: text))
            variables.subtract(functions)
            variables.subtract(types)
            return SymbolTable(functions: functions, types: types, variables: variables)

        case "javascript", "typescript":
            var functions = Set(captures(#"\bfunction\s+(\w+)"#, in: text))
            let types = Set(captures(#"\bclass\s+(\w+)"#, in: text))
            var variables = Set(captures(#"\b(?:const|let|var)\s+(\w+)"#, in: text))
            // Arrow-function bindings (`const f = (…) => …`, `g = async (…) =>`)
            // read as functions, not plain variables.
            let arrows = Set(captures(#"\b(\w+)\s*=\s*(?:async\s*)?\("#, in: text))
            functions.formUnion(arrows)
            variables.subtract(arrows)
            return SymbolTable(functions: functions, types: types, variables: variables)

        case "c", "cpp", "java", "csharp":
            let functions = Set(captures(#"(\w+)\s*\("#, in: text)
                .filter { !cLikeNonSymbols.contains($0) })
            let types = Set(captures(#"\b(?:class|struct)\s+(\w+)"#, in: text))
            return SymbolTable(functions: functions, types: types)

        default:
            return .empty
        }
    }

    /// Flat set of every declared name, for the completion module's ranking.
    /// Kept as the union of `symbolTable(text:…)` so `CompletionController`
    /// stays unchanged while the highlighter gets the classified view.
    public static func symbols(text: String, languageIdentifier: String) -> Set<String> {
        symbolTable(text: text, languageIdentifier: languageIdentifier).all
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
