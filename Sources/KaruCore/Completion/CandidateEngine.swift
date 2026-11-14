import Foundation

/// One completion request: the live text and caret plus the analysis data
/// the engine may read (M17 T17.5). Built by `CompletionController` on the
/// main thread; tests build it directly.
public struct CompletionRequest {
    public var text: NSString
    public var caret: Int
    /// `""` = plain text.
    public var languageIdentifier: String
    /// A manual request (T17.6 `complete(_:)`): any position, empty prefix allowed.
    public var manual = false
    public var keywords: [String] = []
    public var builtins: [String] = []
    /// The published declaration snapshot, its version and the edits made
    /// since it was scanned (`DocumentAnalysis.publishedDeclarations`).
    public var snapshot: DeclarationScan?
    public var snapshotVersion: UInt64 = 0
    public var snapshotJournal = EditJournal()
    /// The document word index, a generation that changes with every rebuild,
    /// and the edits since it was built.
    public var words: WordIndex?
    public var wordsGeneration: UInt64 = 0
    public var wordsJournal = EditJournal()
    public var recent = RecentAccepts()
    /// The analysis scanner of the language (`CandidateEngine.contextScanner`);
    /// nil: no lexical structure (plain text).
    public var scanner: LexicalScanner?
    /// Seam for T17.11: members of the receiver's inferred (trusted) type.
    /// When non-nil, usage evidence is never mixed in (plan §5.4).
    public var inferredMembers: [Candidate]?

    public init(text: NSString, caret: Int, languageIdentifier: String) {
        self.text = text
        self.caret = caret
        self.languageIdentifier = languageIdentifier
    }
}

/// The ranked answer to a request.
public struct CompletionResult {
    public let context: CompletionContext
    /// Ranked, at most `CandidateEngine.maxResults`.
    public let candidates: [Candidate]
    /// More candidates matched than were returned.
    public let truncated: Bool
}

/// The completion candidate engine (M17 T17.5, plan §5): collects candidates
/// from the scope chain, the enclosing class, receiver usage, the file's
/// module-level declarations, the language's keywords and the document's
/// words, matches them against the prefix in tiers and ranks them.
///
/// **Triggers** (plan §5.1): an automatic request needs a code (or plain
/// text) position and a prefix of at least two UTF-16 units that starts
/// with a letter, `_` or (JS / TS) `$`; after a `.` a shorter or empty prefix
/// is allowed only with receiver evidence (inferred members, `self.` /
/// `this.` class members, or earlier `obj.name` usage) — with no evidence a
/// member access needs the ordinary two-unit prefix and gets document words
/// only. A manual request allows any position and an empty prefix: code
/// gets the current scope's names, strings and comments document words.
///
/// **Ranking**: match tier → source (`CandidateSource.rank`, scope depth
/// within the scope source) → nearby use (distance from the caret to the
/// nearest occurrence within the current function or ±2 KB; for a member
/// access only occurrences in member position count, since a bare
/// identifier nearby says nothing about a receiver's members) → recent
/// accepts → case-insensitive dictionary order, exact spelling last. Exact
/// spellings from several sources merge; plain text and SQL also merge
/// case-insensitively, keeping the best-ranked spelling. The identifier
/// being typed is dropped when the caret's occurrence is its only one.
///
/// **Bounds**: fuzzy matching only runs over bounded sources (scope, class,
/// usage, keywords, and module names when there are at most `fuzzyLimit`);
/// document words use the index's prefix ranges and initials only. Scope
/// queries go through a `DeclarationQueryIndex` cached per snapshot and a
/// scope cache per mapped caret; a growing prefix refilters the previous
/// matched set (plan §5.3.6).
public struct CandidateEngine {
    public static let maxResults = 50
    /// Largest bounded set fuzzy matching runs over.
    static let fuzzyLimit = 2_000
    /// ±units around the caret that count as "nearby" outside a function.
    static let nearbyUnits = 2_048
    /// ±lines scanned for words typed since the last index build.
    static let windowLines = 40
    static let windowLineUnits = 16_384
    /// ±units of the current function scanned for nearby use.
    static let functionWindowUnits = 32_768
    /// Units scanned back for receiver usage.
    static let usageWindowUnits = 65_536
    /// Matches kept per tier from the document word index / module names.
    static let wordMatchLimit = 64
    /// Entries of a prefix range scanned for them.
    static let rangeScanLimit = 1_024

    private var queryIndex: (version: UInt64, index: DeclarationQueryIndex)?
    private var scopeCache: ScopeInfo?
    private var previous: Pool?

    /// Diagnostics of the last request (tests, benchmarks).
    public private(set) var lastReusedMatches = false

    public init() {}

    /// Drops the query index (and with it the reference to its snapshot)
    /// unless it belongs to snapshot `version` — called when a new snapshot
    /// is published, so a superseded snapshot is not kept alive until the
    /// next request.
    public mutating func dropIndex(unlessVersion version: UInt64?) {
        guard let cached = queryIndex, cached.version != version else { return }
        queryIndex = nil
        scopeCache = nil
        previous = nil
    }

    /// Drops every cache (module off, language change).
    public mutating func reset() {
        queryIndex = nil
        scopeCache = nil
        previous = nil
    }

    /// Whether any cache is held.
    public var holdsState: Bool { queryIndex != nil || scopeCache != nil || previous != nil }

    // MARK: - Scanner

    /// The lexical scanner whose states `DocumentAnalysis.contextCheckpoints`
    /// hold for `languageIdentifier`: the declaration walker's (Python's
    /// analysis profile, the JavaScript family's per identifier — JSX in
    /// JavaScript and TypeScript JSX, not in TypeScript) or the language's own.
    public static func contextScanner(for languageIdentifier: String,
                                      definition: LanguageDefinition?) -> LexicalScanner? {
        if let profile = JavaScriptLanguage.lexicalProfile(forIdentifier: languageIdentifier) {
            return LexicalScanner(profile: profile)
        }
        switch languageIdentifier {
        case "python": return LexicalScanner(profile: PythonLanguage.analysisProfile)
        default:
            if let brace = BraceLanguage(identifier: languageIdentifier) {
                return LexicalScanner(profile: brace.lexicalProfile)
            }
            return definition?.lexicalScanner
        }
    }

    // MARK: - Scope cache

    struct ScopeInfo {
        let version: UInt64
        let mappedCaret: Int
        let chain: [DeclarationQueryIndex.PositionedScope]
        let local: [DeclarationScan.ScopedBinding]
        /// Snapshot range of the innermost function / lambda.
        let functionRange: NSRange?
        var members: [DeclarationQueryIndex.Member]??
    }

    private mutating func index(for request: CompletionRequest) -> DeclarationQueryIndex? {
        guard let scan = request.snapshot, scan.languageIdentifier == request.languageIdentifier else { return nil }
        if let cached = queryIndex, cached.version == request.snapshotVersion,
           cached.index.scan.documentLength == scan.documentLength {
            return cached.index
        }
        let built = DeclarationQueryIndex(scan: scan)
        queryIndex = (request.snapshotVersion, built)
        scopeCache = nil
        return built
    }

    private mutating func scopeInfo(_ index: DeclarationQueryIndex, version: UInt64, mappedCaret: Int) -> ScopeInfo {
        if let cached = scopeCache, cached.version == version, cached.mappedCaret == mappedCaret { return cached }
        let chain = index.positionedChain(at: mappedCaret)
        let local = index.localBindings(at: mappedCaret, chain: chain)
        let function = chain.last { $0.record.kind == .function || $0.record.kind == .lambda }.map {
            NSRange(location: $0.record.start, length: min($0.record.end, index.scan.documentLength) - $0.record.start)
        }
        let info = ScopeInfo(version: version, mappedCaret: mappedCaret, chain: chain, local: local,
                             functionRange: function, members: nil)
        scopeCache = info
        return info
    }

    // MARK: - Matched-set reuse

    /// A bounded-source item before matching.
    struct SourceItem {
        let name: String
        let kind: CandidateKind
        let source: CandidateSource
        let scopeDepth: Int?
        let location: Int?
        let fuzzy: Bool
    }

    /// The previous request's matched set (plan §5.3.6).
    private struct Pool {
        let key: PoolKey
        let prefix: String
        let items: [SourceItem]
        let wordIDs: [UInt32]
        let truncated: Bool
    }

    private struct PoolKey: Equatable {
        let snapshotVersion: UInt64
        let mappedCaret: Int?
        let wordsGeneration: UInt64
        let language: String
        let prefixStart: Int
        let receiver: String?
        let member: Bool
        let position: CompletionContext.Position
        let manual: Bool
        let inferred: Int
    }

    // MARK: - Request

    /// Answers `request`; nil when no popup should show. `checkpoints` are
    /// the analysis scanner's checkpoints (`DocumentAnalysis.contextCheckpoints`).
    public mutating func complete(_ request: CompletionRequest,
                                  checkpoints: inout CheckpointStore) -> CompletionResult? {
        lastReusedMatches = false
        let text = request.text
        let caret = request.caret
        guard caret >= 0, caret <= text.length else { return nil }
        let language = request.languageIdentifier

        // Snapshot, mapped caret and scope.
        let index = index(for: request)
        let mappedCaret = index != nil ? request.snapshotJournal.mapToBase(caret) : nil
        var scope: ScopeInfo?
        if let index, let mappedCaret {
            scope = scopeInfo(index, version: request.snapshotVersion, mappedCaret: mappedCaret)
        }
        var functionLive: NSRange?
        if let range = scope?.functionRange,
           let start = request.snapshotJournal.mapFromBase(range.location),
           let end = request.snapshotJournal.mapFromBase(NSMaxRange(range)), end >= start {
            functionLive = NSRange(location: start, length: end - start)
        }

        // Window scan: position class, nearby words.
        let scanner = language.isEmpty ? nil : request.scanner
        let window = WindowScan.run(text: text, caret: caret, languageIdentifier: language, scanner: scanner,
                                    functionRange: functionLive, checkpoints: &checkpoints)
        guard let context = CompletionContext.make(text: text, caret: caret, languageIdentifier: language,
                                                   position: window.position) else { return nil }
        let prefix = context.prefix
        let prefixLength = prefix.utf16.count
        if prefixLength > 0, !context.prefixStartsIdentifier { return nil }
        let autoPrefixOK = prefixLength >= 2
        if !request.manual {
            guard context.position.allowsAutoPopup else { return nil }
            if context.memberAccess == nil, !autoPrefixOK { return nil }
        }
        let codeLike = context.position.allowsAutoPopup
        let matcher = CandidateMatcher(prefix)

        // Matched-set reuse.
        let key = PoolKey(snapshotVersion: request.snapshotVersion, mappedCaret: mappedCaret,
                          wordsGeneration: request.wordsGeneration, language: language,
                          prefixStart: context.prefixRange.location, receiver: context.memberAccess?.receiver,
                          member: context.memberAccess != nil, position: context.position,
                          manual: request.manual, inferred: request.inferredMembers?.count ?? -1)
        var items: [SourceItem] = []
        var wordIDs: [UInt32] = []
        var truncated = false
        var evidence = false
        if let pool = previous, pool.key == key, !pool.truncated, !pool.prefix.isEmpty,
           prefixLength > pool.prefix.utf16.count, prefix.hasPrefix(pool.prefix) {
            items = pool.items
            wordIDs = pool.wordIDs
            evidence = pool.items.contains { $0.source != .documentWord && $0.source != .keyword }
            lastReusedMatches = true
        } else {
            var gathered = Gathered()
            gather(request, context: context, index: index, scope: &scope, mappedCaret: mappedCaret,
                   functionLive: functionLive, matcher: matcher, codeLike: codeLike,
                   nearbyNames: Array(window.words.keys), checkpoints: &checkpoints, into: &gathered)
            items = gathered.items
            wordIDs = gathered.wordIDs
            truncated = gathered.truncated
            evidence = gathered.evidence
            if let scope { scopeCache = scope }
        }
        if context.memberAccess != nil, !evidence {
            // Without receiver evidence a member access is an ordinary word
            // completion: two-unit prefix, document words only.
            if prefixLength == 0 { return nil }
            if !request.manual, !autoPrefixOK { return nil }
        }

        // Match.
        var byName: [String: Candidate] = [:]
        var matchedItems: [SourceItem] = []
        func add(_ item: SourceItem) {
            guard let match = matcher.match(item.name, allowFuzzy: item.fuzzy) else { return }
            matchedItems.append(item)
            var candidate = Candidate(name: item.name, kind: item.kind, source: item.source,
                                      matchTier: match.tier, matchedRanges: match.ranges,
                                      scopeDepth: item.scopeDepth, location: item.location)
            if var existing = byName[item.name] {
                Self.merge(&existing, candidate)
                byName[item.name] = existing
            } else {
                candidate.sources = [item.source]
                byName[item.name] = candidate
            }
        }
        for item in items { add(item) }
        var matchedWordIDs: [UInt32] = []
        if let words = request.words {
            for id in wordIDs {
                let name = words.word(id)
                guard let match = matcher.match(name, allowFuzzy: false) else { continue }
                matchedWordIDs.append(id)
                let candidate = Candidate(name: name, kind: .word, source: .documentWord, matchTier: match.tier,
                                          matchedRanges: match.ranges)
                if var existing = byName[name] {
                    Self.merge(&existing, candidate)
                    byName[name] = existing
                } else {
                    byName[name] = candidate
                }
            }
        }
        // Words of the scanned window (typed since the last index build).
        let wantsWords = !(context.memberAccess != nil && prefixLength == 0)
            && !(codeLike && request.manual && prefixLength == 0)
        if wantsWords {
            for (name, _) in window.words where byName[name] == nil && name.utf16.count >= 2 {
                if let match = matcher.match(name, allowFuzzy: false) {
                    byName[name] = Candidate(name: name, kind: .word, source: .documentWord,
                                             matchTier: match.tier, matchedRanges: match.ranges)
                }
            }
        }
        previous = Pool(key: key, prefix: prefix, items: matchedItems, wordIDs: matchedWordIDs,
                        truncated: truncated)

        // Drop the identifier being typed when the caret holds its only occurrence.
        if let typed = byName[prefix],
           !Self.occursElsewhere(typed, context: context, window: window, request: request) {
            byName[prefix] = nil
        }

        // Nearby use (not the declaration itself; for a member access only
        // uses in member position) and recent accepts.
        var candidates = Array(byName.values)
        let member = context.memberAccess != nil
        for i in candidates.indices {
            candidates[i].nearbyDistance = window.nearby(candidates[i].name, excluding: candidates[i].location,
                                                         member: member)
            candidates[i].recentRank = request.recent.rank(of: candidates[i].identity)
        }
        candidates = Self.ranked(candidates)
        if !context.isCaseSensitive {
            var seen: [String: Int] = [:]
            var kept: [Candidate] = []
            for candidate in candidates {
                let folded = String(utf16CodeUnits: CaseFold.folded(candidate.name),
                                    count: candidate.name.utf16.count)
                if let at = seen[folded] {
                    for source in candidate.sources where !kept[at].sources.contains(source) {
                        kept[at].sources.append(source)
                    }
                    kept[at].sources.sort()
                } else {
                    seen[folded] = kept.count
                    kept.append(candidate)
                }
            }
            candidates = kept
        }
        guard !candidates.isEmpty else { return nil }
        let cut = candidates.count > Self.maxResults
        return CompletionResult(context: context, candidates: Array(candidates.prefix(Self.maxResults)),
                                truncated: cut || truncated)
    }

    // MARK: - Gathering

    private struct Gathered {
        var items: [SourceItem] = []
        var wordIDs: [UInt32] = []
        var truncated = false
        var evidence = false
    }

    // swiftlint:disable:next function_parameter_count function_body_length cyclomatic_complexity
    private func gather(_ request: CompletionRequest, context: CompletionContext,
                        index: DeclarationQueryIndex?, scope: inout ScopeInfo?, mappedCaret: Int?,
                        functionLive: NSRange?, matcher: CandidateMatcher, codeLike: Bool,
                        nearbyNames: [String], checkpoints: inout CheckpointStore, into out: inout Gathered) {
        let journal = request.snapshotJournal
        let prefixLength = context.prefix.utf16.count
        func live(_ location: Int) -> Int? { journal.mapFromBase(location) }

        if let member = context.memberAccess {
            // Members: inferred (seam), class, usage; then document words.
            if let inferred = request.inferredMembers {
                for candidate in inferred {
                    out.items.append(SourceItem(name: candidate.name, kind: candidate.kind, source: .inferredType,
                                                scopeDepth: nil, location: candidate.location, fuzzy: true))
                }
                out.evidence = out.evidence || !inferred.isEmpty
            }
            if member.isSelfOrThis, let index, let mappedCaret, var info = scope {
                // Class members are computed once per scope-cache entry.
                if info.members == nil {
                    info.members = .some(index.classMembers(at: mappedCaret))
                    scope = info
                }
                if let members = info.members ?? nil {
                    for m in members {
                        out.items.append(SourceItem(name: m.name, kind: CandidateKind.member(m.kind),
                                                    source: .selfMember, scopeDepth: nil,
                                                    location: live(m.location), fuzzy: true))
                    }
                    out.evidence = out.evidence || !members.isEmpty
                }
            }
            if request.inferredMembers == nil, let receiver = member.receiver, let range = member.receiverRange {
                let from = max(functionLive?.location ?? 0, range.location - Self.usageWindowUnits)
                let usage = UsageScan.run(text: request.text, receiver: receiver, from: from, to: range.location,
                                          languageIdentifier: request.languageIdentifier,
                                          scanner: request.languageIdentifier.isEmpty ? nil : request.scanner,
                                          checkpoints: &checkpoints)
                for hit in usage {
                    out.items.append(SourceItem(name: hit.name, kind: hit.isCall ? .method : .property,
                                                source: hit.stale ? .staleReceiverUsage : .receiverUsage,
                                                scopeDepth: nil, location: hit.location, fuzzy: true))
                }
                out.evidence = out.evidence || !usage.isEmpty
            }
            if prefixLength > 0 { gatherWords(request, matcher: matcher, into: &out) }
            return
        }

        if !codeLike {
            // Strings and comments (manual only): document words.
            if prefixLength > 0 { gatherWords(request, matcher: matcher, into: &out) }
            return
        }

        // Scope bindings.
        if let scope {
            for binding in scope.local {
                out.items.append(SourceItem(name: binding.name, kind: CandidateKind.from(binding.kind, scoped: true),
                                            source: .scope, scopeDepth: binding.scopeDepth,
                                            location: live(binding.location), fuzzy: true))
            }
        }
        let atModuleLevel = (scope?.chain.count ?? 1) <= 1
        let emptyManual = prefixLength == 0
        // Module-level declarations.
        if let index, !emptyManual || atModuleLevel {
            func visible(_ binding: DeclarationQueryIndex.ModuleBinding) -> Bool {
                guard let mappedCaret, let scope else { return true }
                return index.moduleVisible(binding, at: mappedCaret, chain: scope.chain)
            }
            func append(_ binding: DeclarationQueryIndex.ModuleBinding, fuzzy: Bool) {
                guard visible(binding) else { return }
                out.items.append(SourceItem(name: binding.name, kind: CandidateKind.from(binding.kind, scoped: false),
                                            source: .fileDeclaration, scopeDepth: nil,
                                            location: mappedCaret == nil ? nil : live(binding.location),
                                            fuzzy: fuzzy))
            }
            let count = index.moduleBindingCount
            if count <= Self.fuzzyLimit {
                for i in 0..<count { append(index.moduleBinding(at: i), fuzzy: true) }
            } else {
                // Bounded: the head of the prefix range (dictionary order, so
                // the first matches per tier are the best-ranked ones), names
                // used near the caret or recently accepted (they may rank
                // higher), then word-start through the word index's initials.
                let range = index.moduleRange(loweredPrefix: matcher.folded)
                var exact = 0
                var other = 0
                var scanned = 0
                for i in range {
                    if scanned >= Self.rangeScanLimit
                        || (exact >= Self.wordMatchLimit && other >= Self.wordMatchLimit) {
                        out.truncated = true
                        break
                    }
                    scanned += 1
                    let binding = index.moduleBinding(at: i)
                    if binding.name.hasPrefix(context.prefix) {
                        guard exact < Self.wordMatchLimit else { continue }
                        exact += 1
                    } else {
                        guard other < Self.wordMatchLimit else { continue }
                        other += 1
                    }
                    append(binding, fuzzy: false)
                }
                let first = matcher.folded.first
                for name in nearbyNames + request.recent.entries.map(\.name)
                where name.utf16.first.map(CaseFold.fold) == first && matcher.match(name, allowFuzzy: false) != nil {
                    if let binding = index.moduleBinding(named: name) { append(binding, fuzzy: false) }
                }
                if let words = request.words, matcher.folded.count >= 2 {
                    let initials = words.initialsMatches(matcher.folded, limit: Self.wordMatchLimit)
                    if initials.truncated { out.truncated = true }
                    for id in initials.ids {
                        if let binding = index.moduleBinding(named: words.word(id)) { append(binding, fuzzy: false) }
                    }
                }
            }
        }
        if emptyManual { return }
        // Keywords and builtins.
        for keyword in request.keywords {
            out.items.append(SourceItem(name: keyword, kind: .keyword, source: .keyword, scopeDepth: nil,
                                        location: nil, fuzzy: true))
        }
        for builtin in request.builtins {
            out.items.append(SourceItem(name: builtin, kind: .builtin, source: .keyword, scopeDepth: nil,
                                        location: nil, fuzzy: true))
        }
        gatherWords(request, matcher: matcher, into: &out)
    }

    /// Document-word ids for the prefix: both prefix tiers and initials.
    private func gatherWords(_ request: CompletionRequest, matcher: CandidateMatcher, into out: inout Gathered) {
        guard let words = request.words, !matcher.isEmpty else { return }
        let prefix = words.prefixMatches(matcher.query, limit: Self.wordMatchLimit, scanLimit: Self.rangeScanLimit)
        out.wordIDs.append(contentsOf: prefix.exact)
        out.wordIDs.append(contentsOf: prefix.folded)
        if prefix.truncated { out.truncated = true }
        let initials = words.initialsMatches(matcher.folded, limit: Self.wordMatchLimit)
        if initials.truncated { out.truncated = true }
        out.wordIDs.append(contentsOf: initials.ids)
    }

    // MARK: - Ranking

    /// Merges another source of the same spelling into `existing`: the best
    /// source decides kind, depth and location; the best tier wins.
    static func merge(_ existing: inout Candidate, _ other: Candidate) {
        if !existing.sources.contains(other.source) {
            existing.sources.append(other.source)
            existing.sources.sort()
        }
        let otherBetter = (other.source.rank, other.scopeDepth ?? 0) < (existing.source.rank, existing.scopeDepth ?? 0)
        if otherBetter {
            existing.source = other.source
            existing.kind = other.kind
            existing.scopeDepth = other.scopeDepth
            existing.location = other.location ?? existing.location
        }
        if other.matchTier < existing.matchTier {
            existing.matchTier = other.matchTier
            existing.matchedRanges = other.matchedRanges
        }
    }

    /// `candidates` in ranking order (folded spellings computed once).
    static func ranked(_ candidates: [Candidate]) -> [Candidate] {
        let keyed = candidates.map { (candidate: $0, folded: CaseFold.folded($0.name), units: Array($0.name.utf16)) }
        return keyed.sorted { a, b in
            if let order = precedes(a.candidate, b.candidate) { return order }
            let order = DeclarationQueryIndex.compare(a.folded, b.folded)
            if order != 0 { return order < 0 }
            return DeclarationQueryIndex.compare(a.units, b.units) < 0
        }.map(\.candidate)
    }

    /// The ranking keys before dictionary order; nil when they tie.
    private static func precedes(_ a: Candidate, _ b: Candidate) -> Bool? {
        if a.matchTier != b.matchTier { return a.matchTier < b.matchTier }
        if a.source.rank != b.source.rank { return a.source.rank < b.source.rank }
        let depthA = a.scopeDepth ?? 0
        let depthB = b.scopeDepth ?? 0
        if depthA != depthB { return depthA < depthB }
        let nearA = a.nearbyDistance ?? Int.max
        let nearB = b.nearbyDistance ?? Int.max
        if nearA != nearB { return nearA < nearB }
        let recentA = a.recentRank ?? Int.max
        let recentB = b.recentRank ?? Int.max
        if recentA != recentB { return recentA < recentB }
        return nil
    }

    /// Whether the typed identifier also occurs outside the caret's
    /// identifier (another occurrence in the scanned window, a declaration /
    /// usage elsewhere, or the word index).
    static func occursElsewhere(_ candidate: Candidate, context: CompletionContext, window: WindowScan,
                                request: CompletionRequest) -> Bool {
        if (window.words[candidate.name]?.count ?? 0) > 0 { return true }
        if let location = candidate.location, location != context.replacementRange.location { return true }
        if let words = request.words, let id = words.lookup(Array(candidate.name.utf16)) {
            let (count, first) = words.occurrences(of: id)
            if count >= 2 { return true }
            if let mapped = request.wordsJournal.mapFromBase(first), mapped != context.replacementRange.location {
                return true
            }
        }
        return false
    }

    // MARK: - Context-free ranking

    /// Ranks `symbols` (file declarations), `keywords` and `words` for
    /// `prefix` without any context (`WordIndex.suggestions`).
    static func contextFreeRanking(prefix: String, symbols: Set<String>, keywords: [String],
                                   words: WordIndex) -> [Candidate] {
        let matcher = CandidateMatcher(prefix)
        var byName: [String: Candidate] = [:]
        func add(_ name: String, _ kind: CandidateKind, _ source: CandidateSource, fuzzy: Bool) {
            guard let match = matcher.match(name, allowFuzzy: fuzzy) else { return }
            let candidate = Candidate(name: name, kind: kind, source: source, matchTier: match.tier,
                                      matchedRanges: match.ranges)
            if var existing = byName[name] {
                merge(&existing, candidate)
                byName[name] = existing
            } else {
                byName[name] = candidate
            }
        }
        for symbol in symbols { add(symbol, .variable, .fileDeclaration, fuzzy: symbols.count <= fuzzyLimit) }
        for keyword in keywords { add(keyword, .keyword, .keyword, fuzzy: true) }
        let prefixHits = words.prefixMatches(matcher.query, limit: wordMatchLimit)
        let initials = words.initialsMatches(matcher.folded, limit: wordMatchLimit)
        for id in prefixHits.exact + prefixHits.folded + initials.ids { add(words.word(id), .word, .documentWord, fuzzy: false) }
        return Array(ranked(Array(byName.values)).prefix(maxResults))
    }
}

// MARK: - Window scan

/// The lexical scan around the caret: the caret's position class and the
/// identifiers in code within ±40 lines, ±2 KB and the current function
/// (clipped), with their nearest distance to the caret.
struct WindowScan {
    struct Hit {
        /// Occurrences in the window outside the caret's identifier.
        var count: Int
        /// The nearest occurrences within the "nearby" range (at most
        /// `keptOccurrences`): start, distance from the caret, and whether
        /// it is in member position (after a `.`).
        var near: [Occurrence] = []
    }

    struct Occurrence {
        let start: Int
        let distance: Int
        let member: Bool
    }

    static let keptOccurrences = 4

    /// Distance to the nearest use of `name`: occurrences other than the
    /// candidate's own declaration (`location`); for a member access only
    /// occurrences in member position.
    func nearby(_ name: String, excluding location: Int?, member: Bool) -> Int? {
        guard let hit = words[name] else { return nil }
        var best: Int?
        for occurrence in hit.near where occurrence.start != location && (!member || occurrence.member) {
            if occurrence.distance < (best ?? Int.max) { best = occurrence.distance }
        }
        return best
    }

    var position: CompletionContext.Position
    var words: [String: Hit]

    // swiftlint:disable:next function_body_length
    static func run(text: NSString, caret: Int, languageIdentifier: String, scanner: LexicalScanner?,
                    functionRange: NSRange?, checkpoints: inout CheckpointStore) -> WindowScan {
        let length = text.length
        let dollar = IdentifierText.allowsDollar(languageIdentifier)
        // Window bounds.
        var lineStart = caret
        var lines = 0
        while lineStart > 0, caret - lineStart < CandidateEngine.windowLineUnits {
            let u = text.character(at: lineStart - 1)
            if u == 10 || u == 13 {
                lines += 1
                if lines > CandidateEngine.windowLines { break }
            }
            lineStart -= 1
        }
        var lineEnd = caret
        lines = 0
        while lineEnd < length, lineEnd - caret < CandidateEngine.windowLineUnits {
            let u = text.character(at: lineEnd)
            if u == 10 || u == 13 {
                lines += 1
                if lines > CandidateEngine.windowLines { break }
            }
            lineEnd += 1
        }
        let nearStart = max(0, caret - CandidateEngine.nearbyUnits)
        let nearEnd = min(length, caret + CandidateEngine.nearbyUnits)
        var start = min(lineStart, nearStart)
        var end = max(lineEnd, nearEnd)
        var nearLow = nearStart
        var nearHigh = nearEnd
        if let function = functionRange {
            let low = max(function.location, caret - CandidateEngine.functionWindowUnits)
            let high = min(NSMaxRange(function), caret + CandidateEngine.functionWindowUnits, length)
            if low <= caret, high >= caret {
                start = min(start, low)
                end = max(end, high)
                nearLow = min(nearLow, low)
                nearHigh = max(nearHigh, high)
            }
        }
        start = max(0, start)
        end = min(length, end)
        // The caret's identifier (skipped as an occurrence).
        let identifierStart = IdentifierText.runStart(before: caret, in: text, dollar: dollar) ?? caret
        let identifierEnd = IdentifierText.runEnd(after: caret, in: text, dollar: dollar)

        var codeRanges: [NSRange] = []
        var position: CompletionContext.Position
        if let scanner {
            // Resume at a line start / safe point at or before `start`.
            let ls = text.lineRange(for: NSRange(location: start, length: 0)).location
            var resume = HighlightEngine.resumeLexicalState(
                at: start - ls > CheckpointStore.spacing ? start : ls, in: text,
                languageIdentifier: languageIdentifier, initial: LexicalScanState(), checkpoints: &checkpoints,
                unwrap: { if case .generic(let s) = $0 { return s } else { return nil } },
                wrap: { .generic($0) },
                advance: { from, to, state in scanner.advance(text, from: from, to: to, state: &state) },
                advanceToSafePoint: { from, to, target, state in
                    scanner.advance(text, from: from, to: to, stoppingAtSafePointFrom: target, state: &state)
                })
            if resume.position > caret {
                let caretLine = text.lineRange(for: NSRange(location: caret, length: 0)).location
                resume = HighlightEngine.resumeLexicalState(
                    at: caretLine, in: text, languageIdentifier: languageIdentifier, initial: LexicalScanState(),
                    checkpoints: &checkpoints,
                    unwrap: { if case .generic(let s) = $0 { return s } else { return nil } },
                    wrap: { .generic($0) },
                    advance: { from, to, state in scanner.advance(text, from: from, to: to, state: &state) })
            }
            var state = resume.state
            let from = min(resume.position, caret)
            scanner.segments(text, from: from, to: caret, state: &state) { range, segment in
                if CompletionContext.isCode(segment) { codeRanges.append(range) }
            }
            position = CompletionContext.position(of: state)
            if position == .string, CompletionContext.stringsAreContent(languageIdentifier) {
                position = .plainText
            }
            if end > caret {
                scanner.segments(text, from: caret, to: end, state: &state) { range, segment in
                    if CompletionContext.isCode(segment) { codeRanges.append(range) }
                }
            }
        } else {
            position = languageIdentifier.isEmpty ? .plainText : .code
            codeRanges = [NSRange(location: start, length: end - start)]
        }

        // Identifiers in the code ranges.
        var words: [String: Hit] = [:]
        guard end > start else { return WindowScan(position: position, words: words) }
        let base = start
        var buffer = [UInt16](repeating: 0, count: end - start)
        buffer.withUnsafeMutableBufferPointer { pointer in
            text.getCharacters(pointer.baseAddress!, range: NSRange(location: start, length: end - start))
        }
        for range in codeRanges {
            var i = max(range.location, start) - base
            let stop = min(NSMaxRange(range), end) - base
            while i < stop {
                let u = buffer[i]
                var width = 1
                var isPart: Bool
                var isStart: Bool
                if u < 128 {
                    isStart = IdentifierText.isASCIIStart(u, dollar: dollar)
                    isPart = isStart || (u >= 48 && u <= 57)
                } else {
                    let (scalar, w) = Self.scalar(buffer, i, stop)
                    width = w
                    isPart = IdentifierText.isPart(scalar, dollar: dollar)
                    isStart = isPart && IdentifierText.isStart(scalar, dollar: dollar)
                }
                guard isPart else {
                    i += width
                    continue
                }
                let runStart = i
                i += width
                while i < stop {
                    let v = buffer[i]
                    if v < 128 {
                        guard IdentifierText.isASCIIPart(v, dollar: dollar) else { break }
                        i += 1
                    } else {
                        let (scalar, w) = Self.scalar(buffer, i, stop)
                        guard IdentifierText.isPart(scalar, dollar: dollar) else { break }
                        i += w
                    }
                }
                guard isStart, i - runStart <= WordIndexBuilder.maximumWordLength else { continue }
                let absoluteStart = base + runStart
                let absoluteEnd = base + i
                // The caret's own identifier (possibly split at the caret).
                if identifierEnd > identifierStart, absoluteStart >= identifierStart,
                   absoluteEnd <= identifierEnd { continue }
                let name = String(utf16CodeUnits: Array(buffer[runStart..<i]), count: i - runStart)
                let distance = absoluteEnd <= caret ? caret - absoluteEnd : absoluteStart - caret
                let near = absoluteEnd >= nearLow && absoluteStart <= nearHigh ? distance : nil
                var hit = words[name] ?? Hit(count: 0)
                hit.count += 1
                if let near {
                    let member = runStart > 0 && buffer[runStart - 1] == 46
                        && (runStart < 2 || buffer[runStart - 2] != 46)
                    let occurrence = Occurrence(start: absoluteStart, distance: near, member: member)
                    if hit.near.count < Self.keptOccurrences {
                        hit.near.append(occurrence)
                    } else if let worst = hit.near.indices.max(by: { hit.near[$0].distance < hit.near[$1].distance }),
                              hit.near[worst].distance > near {
                        hit.near[worst] = occurrence
                    }
                }
                words[name] = hit
            }
        }
        return WindowScan(position: position, words: words)
    }

    static func scalar(_ buffer: [UInt16], _ i: Int, _ stop: Int) -> (Unicode.Scalar, Int) {
        let u = buffer[i]
        if IdentifierText.isHighSurrogate(u), i + 1 < stop, IdentifierText.isLowSurrogate(buffer[i + 1]) {
            let value = 0x10000 + ((UInt32(u) - 0xD800) << 10) + (UInt32(buffer[i + 1]) - 0xDC00)
            return (Unicode.Scalar(value) ?? "\u{FFFD}", 2)
        }
        return (Unicode.Scalar(u) ?? "\u{FFFD}", 1)
    }
}

// MARK: - Receiver usage

/// Usage evidence for `receiver.` (plan §5.4 item 3): `receiver.name` in code
/// between `from` and `to` (the receiver at the caret), nearest last.
///
/// Heuristic: an occurrence counts when the receiver text stands alone (not
/// the tail of a longer identifier or of another member access) and is
/// followed by `.` and an identifier. A **rebinding** — `receiver =` (not
/// `==`), `receiver :=`, or `for` / `as` / `let` / `const` / `var` right
/// before it — makes every usage before it *stale* (lower confidence,
/// ranked after the fresh ones); usages after the last rebinding are fresh.
enum UsageScan {
    struct Hit {
        let name: String
        let location: Int
        let isCall: Bool
        var stale: Bool
    }

    static func run(text: NSString, receiver: String, from: Int, to: Int, languageIdentifier: String,
                    scanner: LexicalScanner?, checkpoints: inout CheckpointStore) -> [Hit] {
        guard to > from, !receiver.isEmpty else { return [] }
        let dollar = IdentifierText.allowsDollar(languageIdentifier)
        var codeRanges: [NSRange] = []
        if let scanner {
            let ls = text.lineRange(for: NSRange(location: from, length: 0)).location
            let resume = HighlightEngine.resumeLexicalState(
                at: from - ls > CheckpointStore.spacing ? from : ls, in: text,
                languageIdentifier: languageIdentifier, initial: LexicalScanState(), checkpoints: &checkpoints,
                unwrap: { if case .generic(let s) = $0 { return s } else { return nil } },
                wrap: { .generic($0) },
                advance: { a, b, state in scanner.advance(text, from: a, to: b, state: &state) },
                advanceToSafePoint: { a, b, target, state in
                    scanner.advance(text, from: a, to: b, stoppingAtSafePointFrom: target, state: &state)
                })
            guard resume.position < to else { return [] }
            var state = resume.state
            scanner.segments(text, from: resume.position, to: to, state: &state) { range, segment in
                if CompletionContext.isCode(segment) { codeRanges.append(range) }
            }
        } else {
            codeRanges = [NSRange(location: from, length: to - from)]
        }
        let receiverLength = receiver.utf16.count
        var hits: [Hit] = []
        var lastRebinding = -1
        for range in codeRanges {
            var searchRange = range
            while searchRange.length >= receiverLength {
                let found = text.range(of: receiver, options: .literal, range: searchRange)
                guard found.location != NSNotFound else { break }
                let r = found.location
                let after = r + receiverLength
                searchRange = NSRange(location: after, length: NSMaxRange(range) - after)
                // Standalone: not the tail of an identifier or member access.
                if r > 0 {
                    let (scalar, _) = IdentifierText.scalar(before: r, in: text)
                    if scalar == "." || IdentifierText.isPart(scalar, dollar: dollar) { continue }
                }
                guard after < to else { continue }
                let next = text.character(at: after)
                if next == 46 {                                   // receiver.name
                    let nameStart = after + 1
                    guard nameStart < to else { continue }
                    let nameEnd = IdentifierText.runEnd(after: nameStart, in: text, dollar: dollar, limit: 128)
                    guard nameEnd > nameStart, nameEnd <= to else { continue }
                    let units = (nameStart..<nameEnd).map { text.character(at: $0) }
                    guard IdentifierText.startsIdentifier(units, dollar: dollar) else { continue }
                    var k = nameEnd
                    while k < to, text.character(at: k) == 32 { k += 1 }
                    let isCall = k < to && text.character(at: k) == 40
                    let name = String(utf16CodeUnits: units, count: units.count)
                    hits.append(Hit(name: name, location: nameStart, isCall: isCall, stale: false))
                    continue
                }
                if IdentifierText.isPart(IdentifierText.scalar(at: after, in: text).0, dollar: dollar) { continue }
                if isRebinding(text, r, after, to) { lastRebinding = r }
            }
        }
        // One hit per name: the latest; stale when before the last rebinding.
        var latest: [String: Hit] = [:]
        for var hit in hits {
            hit.stale = hit.location < lastRebinding
            if let existing = latest[hit.name], !existing.stale, hit.stale { continue }
            latest[hit.name] = hit
        }
        return latest.values.sorted { $0.location > $1.location }
    }

    /// `receiver = …` / `receiver := …` / `for receiver` / `as receiver` /
    /// `let|const|var receiver`.
    private static func isRebinding(_ text: NSString, _ start: Int, _ end: Int, _ limit: Int) -> Bool {
        var k = end
        while k < limit, text.character(at: k) == 32 || text.character(at: k) == 9 { k += 1 }
        if k < limit {
            let u = text.character(at: k)
            if u == 61 { return !(k + 1 < limit && text.character(at: k + 1) == 61) }   // = but not ==
            if u == 58, k + 1 < limit, text.character(at: k + 1) == 61 { return true }  // :=
        }
        var j = start
        while j > 0, text.character(at: j - 1) == 32 || text.character(at: j - 1) == 9 { j -= 1 }
        guard j < start, let wordStart = IdentifierText.runStart(before: j, in: text, dollar: false, limit: 8),
              wordStart < j else { return false }
        let word = text.substring(with: NSRange(location: wordStart, length: j - wordStart))
        return ["for", "as", "let", "const", "var"].contains(word)
    }
}
