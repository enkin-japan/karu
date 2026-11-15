import AppKit

/// Receives `DocumentAnalysis` changes (highlighter, completion).
@MainActor public protocol DocumentAnalysisConsumer: AnyObject {
    /// Called synchronously after a language change and whenever a new
    /// declaration snapshot is published.
    func documentAnalysisDidChange(_ analysis: DocumentAnalysis, reason: DocumentAnalysis.ChangeReason)
}

/// Per-window document analysis (M17 T17.1, plan §3): the single owner of the
/// document version, the language, the sparse lexical checkpoints and the
/// declaration snapshot that the highlighter, completion and the symbol
/// navigator share.
///
/// - **Version** advances on every character edit, language change and
///   analysis-relevant module toggle; stale work is recognised by it.
/// - **Declarations** are scanned once per version (`DeclarationScan`) and
///   published as an immutable snapshot. An edit drops the snapshot and
///   schedules one debounced rescan through `AnalysisScheduler`, which runs
///   the resumable `DeclarationScanner` in ~4 ms slices (T17.4a) and
///   publishes only when it completes; the version is checked before every
///   slice, so the scanner never reads text after an edit (a stale scanner is
///   dropped). A language change rescans synchronously so the very next
///   request sees the new language — up to `synchronousScanLimit` units;
///   a longer document is scanned through the same sliced job without the
///   debounce (T17.15d-A), so opening a large file does not wait for its
///   declarations: the first paint goes without names and the highlighter
///   repaints when the snapshot lands. A synchronous request
///   (`ensureDeclarations`) finishes the in-flight scanner instead of
///   starting over; `declarationsUnlessPending` does not.
/// - **Published snapshot** (T17.5): the last published snapshot stays
///   readable through edits together with an `EditJournal` of the edits since
///   (`publishedDeclarations`), so completion can still query scopes while a
///   rescan is pending; `declarations` keeps returning only a current one.
/// - **Checkpoints** are invalidated from the edited line on and cleared on a
///   language change. `contextCheckpoints` (T17.5) hold the analysis
///   scanner's states for completion's caret context, separately from the
///   highlighter's (Python highlights with `PythonTokenizer` but analyses
///   with `PythonLanguage.analysisProfile`).
/// - **Checkpoint catch-up** (T17.15d-A): the highlighter and completion
///   register how their tokenizer advances its store
///   (`highlightCheckpointAdvancer`, `contextCheckpointAdvancer`); after a
///   language change, an edit (debounced like the rescan) or a module
///   switch, a job of its own owner walks both stores to the document end
///   in ~4 ms slices (`CheckpointStore.walk`, which re-confirms the entries
///   an edit left pending). A keystroke, a jump or a completion request far
///   from the last edit then resumes from a nearby checkpoint instead of
///   advancing from the edit (or offset 0) in one synchronous pass.
/// - **Release**: with `highlight`, `completion`, `typeInference` and
///   `crossFileIndex` all off, the snapshot and checkpoints are dropped
///   (`isRuntimeStateReleased`). Nothing is rebuilt eagerly when one comes back.
/// - **Syntax** (T17.11a): the parser languages' syntax tree / module summary
///   lives in `syntaxAnalysis` (`SyntaxAnalysis`), held only while completion
///   and type inference are both on; see `syntax`.
/// - **Query index** (T17.15a): completion's `DeclarationQueryIndex` for the
///   published snapshot (`publishedQueryIndex()`). Once completion has
///   queried an index, the indexes of the next `prebuildGenerations`
///   published snapshots are built right after publishing, in their own
///   ~4 ms slices (a job of its own owner, so edits do not cancel it),
///   instead of on the keystroke that first needs them; a request arriving
///   before one is done finishes it synchronously. Without queries (a paste
///   or undo publishes without a keystroke request; completion unused) the
///   prebuilding stops and the first request builds it, as before. Dropped
///   with the snapshots and when completion is turned off.
///
/// Register it on the window's `TextStorageObserverHub` **before** the
/// highlighter, completion and folding so the version bump and checkpoint
/// invalidation happen before they react to the same edit.
@MainActor
public final class DocumentAnalysis: NSObject, TextStorageObserving {
    public enum ChangeReason: Equatable { case language, declarations, released }

    public struct DeclarationSnapshot: Sendable {
        public let version: UInt64
        public let scan: DeclarationScan
    }

    /// Edit debounce before a declaration rescan (the highlighter's interval).
    nonisolated static let declarationDebounce: TimeInterval = 0.07

    /// UTF-16 units the declaration scanner lexes per `step` inside a slice
    /// (the slice repeats steps until its deadline).
    nonisolated static let declarationStepUnits = 8_192

    /// Longest document (UTF-16 units) whose declarations a language change
    /// scans synchronously; longer ones publish through the sliced job
    /// (T17.15d-A). About 5 ms of release scanning, so small and medium
    /// files keep coloured names on their first paint.
    nonisolated static let synchronousScanLimit = 262_144

    /// How a consumer's tokenizer advances one checkpoint store (T17.15d-A):
    /// the same closures its own passes give `resumeLexicalState`, so the
    /// catch-up records exactly the states those passes would.
    public enum CheckpointAdvancer {
        /// A profiled language's generic scanner.
        case generic(LexicalScanner)
        /// Python's highlight tokenizer (line starts only).
        case python(LanguageDefinition)

        /// Walks `store` toward `target` until `deadline` (at least one
        /// chunk); true once `target` is within one chunk of a checkpoint.
        func extend(_ store: inout CheckpointStore, in ns: NSString, to target: Int, deadline: UInt64) -> Bool {
            switch self {
            case .generic(let scanner):
                return store.walk(toward: target, in: ns, stepEnd: target, initial: LexicalScanState(),
                                  unwrap: { if case .generic(let s) = $0 { return s } else { return nil } },
                                  wrap: { .generic($0) },
                                  advance: { from, to, state in scanner.advance(ns, from: from, to: to, state: &state) },
                                  advanceToSafePoint: { from, to, stop, state in
                                      scanner.advance(ns, from: from, to: to, stoppingAtSafePointFrom: stop, state: &state)
                                  },
                                  deadline: deadline).finished
            case .python(let language):
                return store.walk(toward: target, in: ns, stepEnd: target, initial: PythonTokenizer.State(),
                                  unwrap: { if case .python(let s) = $0 { return s } else { return nil } },
                                  wrap: { .python($0) },
                                  advance: { from, to, state in
                                      state = PythonTokenizer.state(in: ns, before: to, language: language,
                                                                    from: from, initial: state)
                                  },
                                  advanceToSafePoint: nil,
                                  deadline: deadline).finished
            }
        }
    }

    /// Modules whose state lives (or will live) here; all off ⇒ release.
    static let analysisModules: [FeatureModule] = [.highlight, .completion, .typeInference, .crossFileIndex]

    private weak var textView: NSTextView?
    private let moduleSettings: ModuleSettings
    private let moduleCenter: NotificationCenter
    private let scheduler: AnalysisScheduler
    /// The syntax tree layer (T17.11a).
    let syntaxAnalysis: SyntaxAnalysis

    public private(set) var version: UInt64 = 0
    public private(set) var languageIdentifier: String = ""
    public var checkpoints = CheckpointStore()
    /// Generic-scanner states of the analysis profile at line starts / safe
    /// points, for completion's caret context (T17.5).
    public var contextCheckpoints = CheckpointStore()

    private var snapshot: DeclarationSnapshot?
    /// The last published snapshot (possibly older than `version`) and the
    /// edits applied since it was published.
    private var published: DeclarationSnapshot?
    private var publishedJournal = EditJournal()
    private var declarationJobPending = false
    private var consumers: [WeakConsumer] = []
    /// Last observed on/off state of `analysisModules`, to ignore broadcasts
    /// that change nothing (a settings import posts for every module).
    private var moduleStates: [FeatureModule: Bool] = [:]

    /// Number of declaration scans performed (tests).
    private(set) var declarationScanCount = 0
    /// Declaration scans published through the sliced job, and the slices
    /// of the last one (tests).
    private(set) var slicedDeclarationScans = 0
    private(set) var lastScanSlices = 0

    /// The highlighter's tokenizer for `checkpoints` (nil: its language
    /// keeps no cross-line state, or highlighting is off).
    public var highlightCheckpointAdvancer: CheckpointAdvancer? {
        didSet { scheduleCheckpointCatchUp() }
    }
    /// Completion's analysis scanner for `contextCheckpoints`.
    public var contextCheckpointAdvancer: CheckpointAdvancer? {
        didSet { scheduleCheckpointCatchUp() }
    }
    /// Owner of the checkpoint catch-up job.
    private final class CheckpointJobOwner {}
    private let checkpointOwner = CheckpointJobOwner()
    /// Catch-ups completed and the slices of the last one (tests).
    private(set) var checkpointCatchUps = 0
    private(set) var lastCatchUpSlices = 0

    /// The sliced scan in progress and the version it reads.
    private var inFlightScanner: DeclarationScanner?
    private var inFlightVersion: UInt64 = 0
    /// Main-thread time spent in the in-flight scan and its longest slice (ns).
    private var inFlightElapsed: UInt64 = 0
    private var inFlightLongestSlice: UInt64 = 0
    private var inFlightSlices = 0

    private struct WeakConsumer {
        weak var consumer: DocumentAnalysisConsumer?
    }

    /// The published snapshot's query index: in progress (`builder`) or built.
    private struct QueryIndexState {
        var version: UInt64
        var builder: DeclarationQueryIndex.Builder?
        var index: DeclarationQueryIndex?
    }

    private var queryIndexState: QueryIndexState?
    /// Published snapshots whose index is still prebuilt without a query.
    static let prebuildGenerations = 2
    private var prebuildCredit = 0
    /// Owner of the query-index jobs (distinct from the declaration job's).
    private final class QueryIndexJobOwner {}
    private let queryIndexOwner = QueryIndexJobOwner()

    /// Query indexes finished or built synchronously by a request, and the
    /// last one's time (ns; tests, benchmarks).
    private(set) var queryIndexSynchronousBuilds = 0
    private(set) var lastQueryIndexSynchronousNanoseconds: UInt64 = 0
    /// Query indexes completed in background slices (tests, benchmarks).
    private(set) var queryIndexSlicedBuilds = 0

    public init(textView: NSTextView,
                moduleSettings: ModuleSettings = ModuleSettings(),
                moduleCenter: NotificationCenter = .default,
                scheduler: AnalysisScheduler = .shared) {
        self.textView = textView
        self.moduleSettings = moduleSettings
        self.moduleCenter = moduleCenter
        self.scheduler = scheduler
        syntaxAnalysis = SyntaxAnalysis(scheduler: scheduler)
        super.init()
        syntaxAnalysis.host = self
        for module in Self.analysisModules { moduleStates[module] = moduleSettings.isEnabled(module) }
        moduleCenter.addObserver(self, selector: #selector(moduleSettingsChanged(_:)),
                                 name: ModuleSettings.didChangeNotification, object: nil)
    }

    deinit {
        moduleCenter.removeObserver(self)
    }

    // MARK: - Queryable state

    /// The current-version declaration snapshot, or `nil` when none is held.
    public var declarations: DeclarationSnapshot? {
        guard let snapshot, snapshot.version == version else { return nil }
        return snapshot
    }

    /// The last published snapshot — current or older — with the edits made
    /// since it was published (T17.5). Offsets in the snapshot map to the
    /// live text through the journal; an unmappable journal means only
    /// offset-free data (names) may be used. Nil when none is held.
    public var publishedDeclarations: (snapshot: DeclarationSnapshot, journal: EditJournal)? {
        published.map { ($0, publishedJournal) }
    }

    /// The published snapshot's offset of live offset `offset` (nil: no
    /// snapshot, or the journal is unmappable).
    public func mapToSnapshot(offset: Int) -> Int? {
        published == nil ? nil : publishedJournal.mapToBase(offset)
    }

    /// The live offset of the published snapshot's offset `offset`.
    public func mapFromSnapshot(offset: Int) -> Int? {
        published == nil ? nil : publishedJournal.mapFromBase(offset)
    }

    /// True when neither a declaration snapshot, any checkpoint nor syntax
    /// state is held.
    public var isRuntimeStateReleased: Bool {
        snapshot == nil && published == nil && checkpoints.isEmpty && contextCheckpoints.isEmpty
            && syntaxAnalysis.isReleased && queryIndexState == nil
    }

    /// Makes `fresh` the current and the published snapshot.
    private func publish(_ fresh: DeclarationSnapshot) {
        snapshot = fresh
        published = fresh
        publishedJournal.reset()
        // A recent snapshot's index was used: prebuild this one's.
        let prebuild = prebuildCredit > 0 && moduleSettings.isEnabled(.completion)
        prebuildCredit = max(0, prebuildCredit - 1)
        dropQueryIndex()
        if prebuild {
            queryIndexState = QueryIndexState(version: fresh.version,
                                              builder: DeclarationQueryIndex.Builder(scan: fresh.scan))
            scheduleQueryIndexBuild(version: fresh.version)
        }
    }

    /// Drops the current and the published snapshot.
    private func dropSnapshots() {
        snapshot = nil
        published = nil
        publishedJournal.reset()
        dropQueryIndex()
        prebuildCredit = 0
    }

    // MARK: - Query index (T17.15a)

    /// The published snapshot's query index and its version: the one built
    /// in the background, finishing an in-flight build, or built now when
    /// none is held. Nil without a published snapshot. Marks the index as
    /// used, so the next published snapshots' are prebuilt.
    public func publishedQueryIndex() -> (version: UInt64, index: DeclarationQueryIndex)? {
        guard let published else { return nil }
        if queryIndexState?.version != published.version {
            dropQueryIndex()
            queryIndexState = QueryIndexState(version: published.version,
                                              builder: DeclarationQueryIndex.Builder(scan: published.scan))
        }
        prebuildCredit = Self.prebuildGenerations
        if let index = queryIndexState?.index { return (published.version, index) }
        let start = DispatchTime.now().uptimeNanoseconds
        // In place: the builder's buffers are uniquely referenced.
        while queryIndexState?.builder?.step(deadline: .max) == false {}
        guard let index = queryIndexState?.builder?.finish() else { return nil }
        queryIndexState?.builder = nil
        queryIndexState?.index = index
        scheduler.cancel(owner: ObjectIdentifier(queryIndexOwner))
        lastQueryIndexSynchronousNanoseconds = DispatchTime.now().uptimeNanoseconds &- start
        queryIndexSynchronousBuilds += 1
        if PerfLog.isEnabled {
            PerfLog.record("analysis.queryIndex", durationSeconds: Double(lastQueryIndexSynchronousNanoseconds) / 1e9,
                           ["docLen": published.scan.documentLength, "version": published.version, "sliced": 0])
        }
        return (published.version, index)
    }

    /// Whether a query index (built or in progress) is held (tests).
    var holdsQueryIndex: Bool { queryIndexState != nil }

    private func dropQueryIndex() {
        guard queryIndexState != nil else { return }
        queryIndexState = nil
        scheduler.cancel(owner: ObjectIdentifier(queryIndexOwner))
    }

    /// Steps the in-flight builder of `version` in analysis slices.
    private func scheduleQueryIndexBuild(version jobVersion: UInt64) {
        var elapsed: UInt64 = 0
        var slices = 0
        var longest: UInt64 = 0
        let job = AnalysisJob(
            owner: ObjectIdentifier(queryIndexOwner),
            version: jobVersion,
            step: { [weak self] deadline in
                guard let self, self.queryIndexState?.version == jobVersion,
                      self.queryIndexState?.builder != nil else { return true }
                let start = DispatchTime.now().uptimeNanoseconds
                let done = self.queryIndexState?.builder?.step(deadline: deadline) ?? true
                let time = DispatchTime.now().uptimeNanoseconds &- start
                elapsed &+= time
                longest = max(longest, time)
                slices += 1
                return done
            },
            completion: { [weak self] in
                guard let self, self.queryIndexState?.version == jobVersion,
                      let builder = self.queryIndexState?.builder, builder.isFinished else { return }
                self.queryIndexState?.index = builder.finish()
                self.queryIndexState?.builder = nil
                self.queryIndexSlicedBuilds += 1
                if PerfLog.isEnabled {
                    PerfLog.record("analysis.queryIndex", durationSeconds: Double(elapsed) / 1e9,
                                   ["docLen": builder.scan.documentLength, "version": jobVersion, "sliced": 1,
                                    "slices": slices, "maxSliceUs": Int(longest / 1000)])
                }
            },
            isInKeyWindow: { [weak textView] in textView?.window?.isKeyWindow == true }
        )
        scheduler.schedule(job)
    }

    /// Whether a module that consumes declarations is on (highlight or
    /// completion). Read live so it is right regardless of the order in which
    /// module-change observers run.
    private var hasDeclarationConsumerModule: Bool {
        moduleSettings.isEnabled(.highlight) || moduleSettings.isEnabled(.completion)
    }

    // MARK: - Consumers

    public func addConsumer(_ consumer: DocumentAnalysisConsumer) {
        consumers.removeAll { $0.consumer == nil }
        guard !consumers.contains(where: { $0.consumer === consumer }) else { return }
        consumers.append(WeakConsumer(consumer: consumer))
    }

    private func notify(_ reason: ChangeReason) {
        for box in consumers {
            box.consumer?.documentAnalysisDidChange(self, reason: reason)
        }
    }

    // MARK: - Language

    /// The single language entry point. `identifier` is resolved to its
    /// registered form; `nil`, empty or unknown means plain text (`""`).
    /// Bumps the version, clears checkpoints and the snapshot, cancels pending
    /// work, rescans declarations synchronously when highlight or completion
    /// is on, then notifies consumers with `.language` — so every consumer
    /// has the new language before this returns.
    ///
    /// A document longer than `synchronousScanLimit` is scanned through the
    /// sliced job instead (no debounce); consumers get `.declarations` when
    /// it publishes. The checkpoint advancers are cleared before consumers
    /// hear `.language` (they register their new tokenizers then).
    public func setLanguage(identifier: String?) {
        languageIdentifier = identifier.flatMap { $0.isEmpty ? nil : LanguageRegistry.canonicalIdentifier($0) } ?? ""
        version &+= 1
        cancelDeclarationJob()
        checkpoints.removeAll()
        contextCheckpoints.removeAll()
        highlightCheckpointAdvancer = nil
        contextCheckpointAdvancer = nil
        dropSnapshots()
        if hasDeclarationConsumerModule {
            if currentText.length <= Self.synchronousScanLimit {
                publish(DeclarationSnapshot(version: version, scan: scanDeclarations()))
            } else {
                scheduleDeclarationScan(after: 0)
            }
        }
        syntaxAnalysis.languageDidChange()
        notify(.language)
    }

    // MARK: - Declarations

    /// The current snapshot, scanning synchronously when none is held. The
    /// result is cached only while highlight or completion is on; otherwise
    /// (navigator-only use) it is transient, as before T17.1.
    public func ensureDeclarations() -> DeclarationSnapshot {
        if let current = declarations { return current }
        let fresh = DeclarationSnapshot(version: version, scan: scanDeclarations())
        if hasDeclarationConsumerModule { publish(fresh) }
        return fresh
    }

    /// The current snapshot; nil while a sliced scan for it is scheduled or
    /// running (consumers hear `.declarations` when it publishes); otherwise
    /// `ensureDeclarations()` (T17.15d-A: what the first paint and the word
    /// index use, so they never finish a large scan synchronously).
    public func declarationsUnlessPending() -> DeclarationSnapshot? {
        if let current = declarations { return current }
        if isDeclarationScanPending { return nil }
        return ensureDeclarations()
    }

    /// A sliced (or debounced) declaration scan for the current version is
    /// scheduled or running.
    public var isDeclarationScanPending: Bool { declarationJobPending && declarations == nil }

    /// Finishes a pending declaration scan now and notifies `.declarations`
    /// — what a language change did for every document before T17.15d-A.
    /// Tests that paint a large document right after `setLanguage` and
    /// compare it with an engine whose scan already landed.
    func finishPendingDeclarationScanForTesting() {
        guard isDeclarationScanPending, hasDeclarationConsumerModule else { return }
        publish(DeclarationSnapshot(version: version, scan: scanDeclarations()))
        cancelDeclarationJob()
        notify(.declarations)
    }

    /// The document text read in place (no bridged copy). Only read while
    /// the version is unchanged since the read started.
    var currentText: NSString {
        textView?.textStorage?.mutableString ?? ((textView?.string ?? "") as NSString)
    }

    /// Scans the current version to completion, finishing the in-flight
    /// sliced scanner when it reads this version.
    private func scanDeclarations() -> DeclarationScan {
        let text = currentText
        let start = PerfLog.isEnabled ? PerfLog.now() : 0
        var scanner: DeclarationScanner
        if let inFlight = inFlightScanner, inFlightVersion == version,
           inFlight.languageIdentifier == languageIdentifier {
            scanner = inFlight
        } else {
            scanner = DeclarationScanner(languageIdentifier: languageIdentifier)
        }
        inFlightScanner = nil
        let scan = scanner.finish(text)
        declarationScanCount += 1
        if PerfLog.isEnabled {
            PerfLog.record("analysis.declarations", since: start,
                           ["docLen": text.length,
                            "lang": languageIdentifier,
                            "version": version,
                            "sliced": 0])
        }
        return scan
    }

    /// Advances the sliced scan for `jobVersion` until `deadline`; returns
    /// the scan once complete. The caller has checked the version.
    private func stepDeclarationScan(jobVersion: UInt64, deadline: UInt64) -> DeclarationScan? {
        if inFlightScanner == nil || inFlightVersion != jobVersion {
            inFlightScanner = DeclarationScanner(languageIdentifier: languageIdentifier)
            inFlightVersion = jobVersion
            inFlightElapsed = 0
            inFlightLongestSlice = 0
            inFlightSlices = 0
        }
        let text = currentText
        let sliceStart = DispatchTime.now().uptimeNanoseconds
        var done = false
        repeat {
            done = inFlightScanner!.step(text, budgetUnits: Self.declarationStepUnits)
        } while !done && DispatchTime.now().uptimeNanoseconds < deadline
        let sliceTime = DispatchTime.now().uptimeNanoseconds &- sliceStart
        inFlightElapsed &+= sliceTime
        inFlightLongestSlice = max(inFlightLongestSlice, sliceTime)
        inFlightSlices += 1
        guard done, let scan = inFlightScanner?.scan else { return nil }
        inFlightScanner = nil
        declarationScanCount += 1
        slicedDeclarationScans += 1
        lastScanSlices = inFlightSlices
        if PerfLog.isEnabled {
            PerfLog.record("analysis.declarations", durationSeconds: Double(inFlightElapsed) / 1e9,
                           ["docLen": text.length,
                            "lang": languageIdentifier,
                            "version": jobVersion,
                            "sliced": 1,
                            "slices": inFlightSlices,
                            "maxSliceUs": Int(inFlightLongestSlice / 1000)])
        }
        return scan
    }

    /// Schedules the rescan for the current version after `delay` (the edit
    /// debounce, or 0 for a language change): the resumable
    /// `DeclarationScanner` advances in steps until each slice deadline.
    private func scheduleDeclarationScan(after delay: TimeInterval = DocumentAnalysis.declarationDebounce) {
        let jobVersion = version
        var result: DeclarationScan?
        let job = AnalysisJob(
            owner: ObjectIdentifier(self),
            version: jobVersion,
            step: { [weak self] deadline in
                guard let self else { return true }
                // Stop when the job is stale (never read text after an edit)
                // or a current snapshot exists (e.g. completion asked for it
                // synchronously).
                guard self.version == jobVersion, self.declarations == nil,
                      self.hasDeclarationConsumerModule, self.textView != nil else { return true }
                result = self.stepDeclarationScan(jobVersion: jobVersion, deadline: deadline)
                return result != nil
            },
            completion: { [weak self] in
                guard let self else { return }
                self.declarationJobPending = false
                // A completed job for a superseded version is discarded.
                guard self.version == jobVersion else { return }
                if let result, self.declarations == nil {
                    self.publish(DeclarationSnapshot(version: jobVersion, scan: result))
                }
                guard self.declarations != nil else { return }
                self.notify(.declarations)
            },
            isInKeyWindow: { [weak textView] in textView?.window?.isKeyWindow == true }
        )
        declarationJobPending = true
        scheduler.schedule(job, after: delay)
    }

    // MARK: - Checkpoint catch-up (T17.15d-A)

    /// Schedules the sliced walk of the registered checkpoint stores to the
    /// document end after `delay`, replacing a pending one; cancels it when
    /// no registered store's module is on.
    private func scheduleCheckpointCatchUp(after delay: TimeInterval = DocumentAnalysis.declarationDebounce) {
        let owner = ObjectIdentifier(checkpointOwner)
        guard textView != nil, highlightCatchUpEnabled || contextCatchUpEnabled else {
            scheduler.cancel(owner: owner)
            return
        }
        let jobVersion = version
        var elapsed: UInt64 = 0
        var slices = 0
        var longest: UInt64 = 0
        let job = AnalysisJob(
            owner: owner,
            version: jobVersion,
            step: { [weak self] deadline in
                guard let self, self.version == jobVersion, self.textView != nil else { return true }
                let start = DispatchTime.now().uptimeNanoseconds
                let text = self.currentText
                var done = true
                if self.highlightCatchUpEnabled, let advancer = self.highlightCheckpointAdvancer {
                    done = advancer.extend(&self.checkpoints, in: text, to: text.length, deadline: deadline)
                }
                if done, self.contextCatchUpEnabled, let advancer = self.contextCheckpointAdvancer {
                    done = advancer.extend(&self.contextCheckpoints, in: text, to: text.length, deadline: deadline)
                }
                let time = DispatchTime.now().uptimeNanoseconds &- start
                elapsed &+= time
                longest = max(longest, time)
                slices += 1
                return done
            },
            completion: { [weak self] in
                guard let self, self.version == jobVersion else { return }
                self.checkpointCatchUps += 1
                self.lastCatchUpSlices = slices
                if PerfLog.isEnabled {
                    PerfLog.record("lexical.catchUp", durationSeconds: Double(elapsed) / 1e9,
                                   ["docLen": self.currentText.length, "lang": self.languageIdentifier,
                                    "version": jobVersion, "slices": slices, "maxSliceUs": Int(longest / 1000),
                                    "checkpoints": self.checkpoints.entries.count,
                                    "contextCheckpoints": self.contextCheckpoints.entries.count])
                }
            },
            isInKeyWindow: { [weak textView] in textView?.window?.isKeyWindow == true }
        )
        scheduler.schedule(job, after: delay)
    }

    private var highlightCatchUpEnabled: Bool {
        highlightCheckpointAdvancer != nil && moduleSettings.isEnabled(.highlight)
    }

    private var contextCatchUpEnabled: Bool {
        contextCheckpointAdvancer != nil && moduleSettings.isEnabled(.completion)
    }

    /// Cancels every scheduled job of this document (window close). Held
    /// results stay until the analysis is released with its window.
    public func cancelPendingWork() {
        cancelDeclarationJob()
        scheduler.cancel(owner: ObjectIdentifier(checkpointOwner))
        syntaxAnalysis.cancel()
    }

    /// Completion and type inference are both on: the syntax layer is kept.
    var syntaxModulesEnabled: Bool {
        moduleSettings.isEnabled(.completion) && moduleSettings.isEnabled(.typeInference)
    }

    var hasTextView: Bool { textView != nil }

    var isInKeyWindow: Bool { textView?.window?.isKeyWindow == true }

    private func cancelDeclarationJob() {
        scheduler.cancel(owner: ObjectIdentifier(self))
        declarationJobPending = false
        inFlightScanner = nil
    }

    // MARK: - TextStorageObserving

    /// The exact edited range of the edit being processed (T17.15d-A): the
    /// `didProcessEditing` range covers whole paragraphs, which would drop
    /// every checkpoint of a long line on each keystroke in it.
    private var exactEdit: (range: NSRange, delta: Int)?

    public func textStorageWillProcessEditing(editedMask: NSTextStorageEditActions,
                                              editedRange: NSRange,
                                              changeInLength delta: Int,
                                              textStorage: NSTextStorage) {
        exactEdit = editedMask.contains(.editedCharacters) ? (editedRange, delta) : nil
    }

    public func textStorageDidProcessEditing(editedMask: NSTextStorageEditActions,
                                             editedRange: NSRange,
                                             changeInLength delta: Int,
                                             textStorage: NSTextStorage) {
        // The checkpoints use the exact range when it is this edit's (same
        // delta, inside the widened range); otherwise the widened one.
        let checkpointRange: NSRange
        if let exact = exactEdit, exact.delta == delta, exact.range.location >= editedRange.location,
           NSMaxRange(exact.range) <= NSMaxRange(editedRange) {
            checkpointRange = exact.range
        } else {
            checkpointRange = editedRange
        }
        exactEdit = nil
        guard editedMask.contains(.editedCharacters) else { return }
        version &+= 1
        if !checkpoints.isEmpty {
            // `mutableString` reads the storage in place (no bridged copy).
            checkpoints.invalidate(editedRange: checkpointRange, changeInLength: delta,
                                   in: textStorage.mutableString)
        }
        if !contextCheckpoints.isEmpty {
            contextCheckpoints.invalidate(editedRange: checkpointRange, changeInLength: delta,
                                          in: textStorage.mutableString)
        }
        if published != nil {
            // Only completion reads a superseded snapshot; without it the old
            // one is released at once, as before T17.5.
            if moduleSettings.isEnabled(.completion) {
                publishedJournal.record(editedRange: editedRange, changeInLength: delta)
            } else {
                published = nil
                publishedJournal.reset()
            }
        }
        snapshot = nil
        inFlightScanner = nil
        if hasDeclarationConsumerModule { scheduleDeclarationScan() }
        scheduleCheckpointCatchUp()
        syntaxAnalysis.textDidChange(editedRange: editedRange, changeInLength: delta)
    }

    // MARK: - Module gating

    @objc private func moduleSettingsChanged(_ note: Notification) {
        guard let raw = note.object as? String,
              let module = FeatureModule(rawValue: raw),
              Self.analysisModules.contains(module) else { return }
        let enabled = moduleSettings.isEnabled(module)
        guard moduleStates[module] != enabled else { return }
        moduleStates[module] = enabled
        version &+= 1
        syntaxAnalysis.modulesDidChange()

        if Self.analysisModules.allSatisfy({ !moduleSettings.isEnabled($0) }) {
            cancelDeclarationJob()
            scheduler.cancel(owner: ObjectIdentifier(checkpointOwner))
            dropSnapshots()
            checkpoints.removeAll()
            contextCheckpoints.removeAll()
            notify(.released)
            return
        }
        if !moduleSettings.isEnabled(.highlight) {
            // The highlighter is the only user of these checkpoints.
            checkpoints.removeAll()
        }
        if !moduleSettings.isEnabled(.completion) {
            // Completion is the only user of the context checkpoints and
            // of the query index.
            contextCheckpoints.removeAll()
            dropQueryIndex()
            prebuildCredit = 0
        }
        // A store switched on (or off) since: catch up what is registered.
        scheduleCheckpointCatchUp()
        guard hasDeclarationConsumerModule else {
            // Nobody reads declarations: drop them (navigator use stays transient).
            cancelDeclarationJob()
            dropSnapshots()
            return
        }
        if let held = snapshot {
            // The text did not change, so the held scan is still exact; carry
            // it to the new version instead of rescanning.
            let carried = DeclarationSnapshot(version: version, scan: held.scan)
            snapshot = carried
            if published?.version == held.version {
                published = carried
                // Same scan: its query index stays valid.
                if queryIndexState?.version == held.version {
                    queryIndexState?.version = version
                    if queryIndexState?.builder != nil {
                        scheduler.cancel(owner: ObjectIdentifier(queryIndexOwner))
                        scheduleQueryIndexBuild(version: version)
                    }
                }
            }
        } else if declarationJobPending {
            // The pending job now carries a stale version; replace it.
            scheduleDeclarationScan()
        }
    }
}
