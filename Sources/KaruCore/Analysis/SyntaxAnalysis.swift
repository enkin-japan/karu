import AppKit

/// A syntax tree or module summary of one document version (M17 T17.11a),
/// published by `DocumentAnalysis` like its declaration snapshot.
public struct SyntaxSnapshot: Sendable {
    public let version: UInt64
    public let content: SyntaxContent

    public var dialect: SyntaxDialect { content.dialect }
    /// The full tree (documents up to `SyntaxBuild.fullTreeUnitLimit`).
    public var tree: SyntaxTree? { content.tree }
    /// The module summary (larger documents).
    public var summary: ModuleSummary? { content.summary }
}

/// The syntax layer of `DocumentAnalysis` (M17 T17.11a, plan §3 / §8.3).
///
/// - **Gating.** Held only for the four parser languages (`SyntaxDialect`)
///   while both `completion` and `typeInference` are on (the tree serves
///   completion's member hints and is the type inference's input); turning
///   either off, or a language change, releases everything (snapshot,
///   published snapshot, journal, in-flight build, subtree cache).
/// - **Builds** run through the shared `AnalysisScheduler` as their own job
///   (owner: this object), debounced like the declaration rescan, in
///   `stepUnits` steps until each slice's deadline. The version is checked
///   before every slice; an edit drops the in-flight build (it never reads
///   the text after an edit).
/// - **Incremental.** The last published snapshot stays with an
///   `EditJournal` of the edits since; the next build updates it with the
///   single edit covering the journal (`SyntaxEdit.covering`), reusing the
///   unaffected top-level statements. A changed mode (the document crossed
///   `SyntaxBuild.fullTreeUnitLimit`), dialect or an unmappable journal
///   means a fresh build.
/// - **Summary mode.** For a large document a statement's subtree is parsed
///   on demand (`statement(at:)`) into a byte-capped LRU, cleared whenever a
///   new snapshot is published.
@MainActor
final class SyntaxAnalysis {
    /// UTF-16 units per build step inside a slice.
    nonisolated static let stepUnits = 8_192

    struct BuildStats: Equatable {
        var incremental = false
        var slices = 0
        var totalNanoseconds: UInt64 = 0
        var longestSliceNanoseconds: UInt64 = 0
        var reparsedStatements = 0
        var reusedStatements = 0
        var capHits = 0
        var maxStepRatio = 0.0
    }

    weak var host: DocumentAnalysis?
    private let scheduler: AnalysisScheduler

    /// The newest snapshot; current only while its version is the host's.
    private(set) var snapshot: SyntaxSnapshot?
    /// The last published snapshot and the edits since it.
    private(set) var published: SyntaxSnapshot?
    private(set) var journal = EditJournal()
    private var inFlight: SyntaxBuild?
    private var inFlightVersion: UInt64 = 0
    private var inFlightStats = BuildStats()
    private var jobPending = false
    private(set) var cache = SyntaxSubtreeCache()

    /// Builds published so far and the last one's statistics (tests, perf).
    private(set) var buildCount = 0
    private(set) var lastBuildStats = BuildStats()

    init(scheduler: AnalysisScheduler) {
        self.scheduler = scheduler
    }

    // MARK: - State

    var isReleased: Bool { snapshot == nil && published == nil && inFlight == nil && cache.isEmpty }

    /// Bytes held: the published content and the subtree cache.
    var retainedBytes: Int { (published?.content.retainedBytes ?? 0) + cache.bytes }

    private var dialect: SyntaxDialect? {
        host.flatMap { SyntaxDialect(languageIdentifier: $0.languageIdentifier) }
    }

    private var isEnabled: Bool { host?.syntaxModulesEnabled == true && dialect != nil }

    /// The snapshot of the host's current version, if held.
    var current: SyntaxSnapshot? {
        guard let snapshot, let host, snapshot.version == host.version else { return nil }
        return snapshot
    }

    func release() {
        cancel()
        snapshot = nil
        published = nil
        journal.reset()
        cache.removeAll()
    }

    func cancel() {
        scheduler.cancel(owner: ObjectIdentifier(self))
        jobPending = false
        inFlight = nil
    }

    // MARK: - Host events

    /// After `setLanguage` (the version already advanced).
    func languageDidChange() {
        release()
        if isEnabled { schedule() }
    }

    /// After a character edit (the version already advanced).
    func textDidChange(editedRange: NSRange, changeInLength delta: Int) {
        inFlight = nil
        snapshot = nil
        cache.removeAll()
        guard isEnabled else {
            if !isReleased || jobPending { release() }
            return
        }
        if published != nil { journal.record(editedRange: editedRange, changeInLength: delta) }
        schedule()
    }

    /// After an analysis module toggle (the version already advanced; the
    /// text did not change).
    func modulesDidChange() {
        guard isEnabled, let host else {
            release()
            return
        }
        if let held = snapshot {
            // The text is unchanged since `held` was current: carry it.
            let carried = SyntaxSnapshot(version: host.version, content: held.content)
            if published?.version == held.version { published = carried }
            snapshot = carried
        } else {
            // Nothing current: (re)schedule with the new version.
            schedule()
        }
    }

    // MARK: - Building

    private func schedule() {
        guard let host else { return }
        let jobVersion = host.version
        let job = AnalysisJob(
            owner: ObjectIdentifier(self),
            version: jobVersion,
            step: { [weak self] deadline in
                guard let self, let host = self.host else { return true }
                // Stop when stale (never read text after an edit), when a
                // current snapshot exists (built synchronously), or when off.
                guard host.version == jobVersion, self.current == nil, self.isEnabled,
                      host.hasTextView else { return true }
                return self.stepBuild(jobVersion: jobVersion, deadline: deadline)
            },
            completion: { [weak self] in
                self?.jobPending = false
            },
            isInKeyWindow: { [weak host] in host?.isInKeyWindow == true }
        )
        jobPending = true
        scheduler.schedule(job, after: DocumentAnalysis.declarationDebounce)
    }

    /// A build for the host's current text: an update of the published
    /// snapshot when possible, else a fresh one.
    private func makeBuild(_ text: NSString, dialect: SyntaxDialect) -> (SyntaxBuild, incremental: Bool) {
        let mode = SyntaxBuild.mode(forLength: text.length)
        if let base = published, base.dialect == dialect,
           SyntaxBuild.mode(forLength: base.content.textLength) == mode,
           let edit = SyntaxEdit.covering(journal, baseLength: base.content.textLength),
           base.content.textLength - edit.oldLength + edit.newLength == text.length {
            return (SyntaxBuild(updating: base.content, edit: edit, text: text), true)
        }
        return (SyntaxBuild(dialect: dialect, text: text, mode: mode), false)
    }

    /// Advances the in-flight build for `jobVersion` until `deadline`; true
    /// when finished (and published). The caller checked the version.
    private func stepBuild(jobVersion: UInt64, deadline: UInt64) -> Bool {
        guard let host, let dialect else { return true }
        let text = host.currentText
        let sliceStart = DispatchTime.now().uptimeNanoseconds
        if inFlight == nil || inFlightVersion != jobVersion {
            let (build, incremental) = makeBuild(text, dialect: dialect)
            inFlight = build
            inFlightVersion = jobVersion
            inFlightStats = BuildStats(incremental: incremental)
        }
        var done = false
        repeat {
            done = inFlight!.step(text, budgetUnits: Self.stepUnits)
        } while !done && DispatchTime.now().uptimeNanoseconds < deadline
        let sliceTime = DispatchTime.now().uptimeNanoseconds &- sliceStart
        inFlightStats.slices += 1
        inFlightStats.totalNanoseconds &+= sliceTime
        inFlightStats.longestSliceNanoseconds = max(inFlightStats.longestSliceNanoseconds, sliceTime)
        guard done else { return false }
        finishInFlight(version: jobVersion, docLength: text.length, sliced: true)
        return true
    }

    /// Publishes the finished in-flight build's result.
    private func finishInFlight(version: UInt64, docLength: Int, sliced: Bool) {
        guard let build = inFlight else { return }
        inFlight = nil
        guard let content = build.result else { return }
        var stats = inFlightStats
        stats.reparsedStatements = build.reparsedStatements
        stats.reusedStatements = build.reusedStatements
        stats.capHits = build.capHits
        stats.maxStepRatio = build.maxStepRatio
        lastBuildStats = stats
        publish(SyntaxSnapshot(version: version, content: content))
        if PerfLog.isEnabled {
            PerfLog.record("analysis.syntax", durationSeconds: Double(stats.totalNanoseconds) / 1e9,
                           ["docLen": docLength,
                            "lang": content.dialect.languageIdentifier,
                            "version": version,
                            "sliced": sliced ? 1 : 0,
                            "incremental": stats.incremental ? 1 : 0,
                            "slices": stats.slices,
                            "maxSliceUs": Int(stats.longestSliceNanoseconds / 1000),
                            "reparsed": stats.reparsedStatements,
                            "bytes": content.retainedBytes])
        }
    }

    private func publish(_ fresh: SyntaxSnapshot) {
        snapshot = fresh
        published = fresh
        journal.reset()
        cache.removeAll()
        buildCount += 1
    }

    // MARK: - Queries

    /// The current snapshot, building it synchronously when none is held
    /// (finishing the in-flight build when it reads this version). Nil for
    /// a language without a parser. While the modules are off the result is
    /// transient (not kept).
    func ensure() -> SyntaxSnapshot? {
        guard let host, let dialect else { return nil }
        if let current { return current }
        let text = host.currentText
        let start = DispatchTime.now().uptimeNanoseconds
        if inFlight == nil || inFlightVersion != host.version {
            let (build, incremental) = makeBuild(text, dialect: dialect)
            inFlight = build
            inFlightVersion = host.version
            inFlightStats = BuildStats(incremental: incremental)
        }
        _ = inFlight!.finish(text)
        let elapsed = DispatchTime.now().uptimeNanoseconds &- start
        inFlightStats.slices += 1
        inFlightStats.totalNanoseconds &+= elapsed
        inFlightStats.longestSliceNanoseconds = max(inFlightStats.longestSliceNanoseconds, elapsed)
        guard isEnabled else {
            defer { inFlight = nil }
            return inFlight!.result.map { SyntaxSnapshot(version: host.version, content: $0) }
        }
        finishInFlight(version: host.version, docLength: text.length, sliced: false)
        return current
    }

    /// The top-level statement containing `offset` in the current snapshot:
    /// a node of the full tree, or (summary mode) the root's only child of a
    /// statement tree parsed on demand and kept in the LRU. Nil without a
    /// current snapshot.
    func statement(at offset: Int) -> (tree: SyntaxTree, node: Int)? {
        guard let host, let current else { return nil }
        switch current.content {
        case .tree(let tree):
            return tree.topLevelStatement(at: offset).map { (tree, $0) }
        case .summary(let summary):
            guard let index = summary.statementIndex(at: offset) else { return nil }
            let start = summary.statements[index].start
            if let cached = cache.tree(startingAt: start) { return (cached, cached.root - 1) }
            let tree = summary.parseStatement(index, in: host.currentText)
            if isEnabled { cache.insert(tree, startingAt: start) }
            return (tree, tree.root - 1)
        }
    }
}

extension DocumentAnalysis {
    /// The current-version syntax snapshot (M17 T17.11a), or nil when none
    /// is held (not built yet, a language without a parser, or completion /
    /// type inference off).
    public var syntax: SyntaxSnapshot? { syntaxAnalysis.current }

    /// The last published syntax snapshot — current or older — with the
    /// edits made since (offsets map through the journal like
    /// `publishedDeclarations`).
    public var publishedSyntax: (snapshot: SyntaxSnapshot, journal: EditJournal)? {
        syntaxAnalysis.published.map { ($0, syntaxAnalysis.journal) }
    }

    /// The current syntax snapshot, built synchronously when none is held.
    public func ensureSyntax() -> SyntaxSnapshot? { syntaxAnalysis.ensure() }

    /// The top-level statement containing `offset` in the current syntax
    /// snapshot (summary mode: parsed on demand, cached in a byte-capped LRU).
    public func syntaxStatement(at offset: Int) -> (tree: SyntaxTree, node: Int)? {
        syntaxAnalysis.statement(at: offset)
    }

    /// Bytes held by the syntax layer (published content + subtree cache).
    public var syntaxRetainedBytes: Int { syntaxAnalysis.retainedBytes }
}
