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
///   request sees the new language; a synchronous request
///   (`ensureDeclarations`) finishes the in-flight scanner instead of
///   starting over.
/// - **Published snapshot** (T17.5): the last published snapshot stays
///   readable through edits together with an `EditJournal` of the edits since
///   (`publishedDeclarations`), so completion can still query scopes while a
///   rescan is pending; `declarations` keeps returning only a current one.
/// - **Checkpoints** are invalidated from the edited line on and cleared on a
///   language change. `contextCheckpoints` (T17.5) hold the analysis
///   scanner's states for completion's caret context, separately from the
///   highlighter's (Python highlights with `PythonTokenizer` but analyses
///   with `PythonLanguage.analysisProfile`).
/// - **Release**: with `highlight`, `completion`, `typeInference` and
///   `crossFileIndex` all off, the snapshot and checkpoints are dropped
///   (`isRuntimeStateReleased`). Nothing is rebuilt eagerly when one comes back.
/// - **Syntax** (T17.11a): the parser languages' syntax tree / module summary
///   lives in `syntaxAnalysis` (`SyntaxAnalysis`), held only while completion
///   and type inference are both on; see `syntax`.
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
    static let declarationDebounce: TimeInterval = 0.07

    /// UTF-16 units the declaration scanner lexes per `step` inside a slice
    /// (the slice repeats steps until its deadline).
    nonisolated static let declarationStepUnits = 8_192

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
        snapshot == nil && published == nil && checkpoints.entries.isEmpty && contextCheckpoints.entries.isEmpty
            && syntaxAnalysis.isReleased
    }

    /// Makes `fresh` the current and the published snapshot.
    private func publish(_ fresh: DeclarationSnapshot) {
        snapshot = fresh
        published = fresh
        publishedJournal.reset()
    }

    /// Drops the current and the published snapshot.
    private func dropSnapshots() {
        snapshot = nil
        published = nil
        publishedJournal.reset()
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
    public func setLanguage(identifier: String?) {
        languageIdentifier = identifier.flatMap { $0.isEmpty ? nil : LanguageRegistry.canonicalIdentifier($0) } ?? ""
        version &+= 1
        cancelDeclarationJob()
        checkpoints.removeAll()
        contextCheckpoints.removeAll()
        dropSnapshots()
        if hasDeclarationConsumerModule {
            publish(DeclarationSnapshot(version: version, scan: scanDeclarations()))
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

    /// Schedules the debounced rescan for the current version: the resumable
    /// `DeclarationScanner` advances in steps until each slice deadline.
    private func scheduleDeclarationScan() {
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
        scheduler.schedule(job, after: Self.declarationDebounce)
    }

    /// Cancels every scheduled job of this document (window close). Held
    /// results stay until the analysis is released with its window.
    public func cancelPendingWork() {
        cancelDeclarationJob()
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

    public func textStorageDidProcessEditing(editedMask: NSTextStorageEditActions,
                                             editedRange: NSRange,
                                             changeInLength delta: Int,
                                             textStorage: NSTextStorage) {
        guard editedMask.contains(.editedCharacters) else { return }
        version &+= 1
        if !checkpoints.entries.isEmpty {
            // `mutableString` reads the storage in place (no bridged copy).
            checkpoints.invalidate(editedRange: editedRange, changeInLength: delta,
                                   in: textStorage.mutableString)
        }
        if !contextCheckpoints.entries.isEmpty {
            contextCheckpoints.invalidate(editedRange: editedRange, changeInLength: delta,
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
            // Completion is the only user of the context checkpoints.
            contextCheckpoints.removeAll()
        }
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
            if published?.version == held.version { published = carried }
        } else if declarationJobPending {
            // The pending job now carries a stale version; replace it.
            scheduleDeclarationScan()
        }
    }
}
