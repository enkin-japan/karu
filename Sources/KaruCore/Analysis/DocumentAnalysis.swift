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
///   schedules one debounced rescan through `AnalysisScheduler`; a language
///   change rescans synchronously so the very next request sees the new
///   language.
/// - **Checkpoints** are invalidated from the edited line on and cleared on a
///   language change.
/// - **Release**: with `highlight`, `completion`, `typeInference` and
///   `crossFileIndex` all off, the snapshot and checkpoints are dropped
///   (`isRuntimeStateReleased`). Nothing is rebuilt eagerly when one comes back.
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

    /// Modules whose state lives (or will live) here; all off ⇒ release.
    static let analysisModules: [FeatureModule] = [.highlight, .completion, .typeInference, .crossFileIndex]

    private weak var textView: NSTextView?
    private let moduleSettings: ModuleSettings
    private let moduleCenter: NotificationCenter
    private let scheduler: AnalysisScheduler

    public private(set) var version: UInt64 = 0
    public private(set) var languageIdentifier: String = ""
    public var checkpoints = CheckpointStore()

    private var snapshot: DeclarationSnapshot?
    private var declarationJobPending = false
    private var consumers: [WeakConsumer] = []
    /// Last observed on/off state of `analysisModules`, to ignore broadcasts
    /// that change nothing (a settings import posts for every module).
    private var moduleStates: [FeatureModule: Bool] = [:]

    /// Number of declaration scans performed (tests).
    private(set) var declarationScanCount = 0

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
        super.init()
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

    /// True when neither a declaration snapshot nor any checkpoint is held.
    public var isRuntimeStateReleased: Bool { snapshot == nil && checkpoints.entries.isEmpty }

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
        snapshot = nil
        if hasDeclarationConsumerModule {
            snapshot = DeclarationSnapshot(version: version, scan: scanDeclarations())
        }
        notify(.language)
    }

    // MARK: - Declarations

    /// The current snapshot, scanning synchronously when none is held. The
    /// result is cached only while highlight or completion is on; otherwise
    /// (navigator-only use) it is transient, as before T17.1.
    public func ensureDeclarations() -> DeclarationSnapshot {
        if let current = declarations { return current }
        let fresh = DeclarationSnapshot(version: version, scan: scanDeclarations())
        if hasDeclarationConsumerModule { snapshot = fresh }
        return fresh
    }

    private func scanDeclarations() -> DeclarationScan {
        let text = textView?.string ?? ""
        let start = PerfLog.isEnabled ? PerfLog.now() : 0
        let scan = DeclarationScan.scan(text: text, languageIdentifier: languageIdentifier)
        declarationScanCount += 1
        if PerfLog.isEnabled {
            PerfLog.record("analysis.declarations", since: start,
                           ["docLen": (text as NSString).length,
                            "lang": languageIdentifier,
                            "version": version])
        }
        return scan
    }

    /// Schedules the debounced rescan for the current version. In T17.1 the
    /// scan is a single step: the regex pass cannot be split into chunks yet.
    /// T17.4 replaces it with the token-based declaration scanner, which will
    /// advance in chunks up to each slice deadline.
    private func scheduleDeclarationScan() {
        let jobVersion = version
        var result: DeclarationScan?
        let job = AnalysisJob(
            owner: ObjectIdentifier(self),
            version: jobVersion,
            step: { [weak self] _ in
                guard let self else { return true }
                // Skip the scan when the job is already stale or a current
                // snapshot exists (e.g. completion asked for it synchronously).
                if self.version == jobVersion, self.declarations == nil, self.hasDeclarationConsumerModule {
                    result = self.scanDeclarations()
                }
                return true
            },
            completion: { [weak self] in
                guard let self else { return }
                self.declarationJobPending = false
                // A completed job for a superseded version is discarded.
                guard self.version == jobVersion else { return }
                if let result, self.declarations == nil {
                    self.snapshot = DeclarationSnapshot(version: jobVersion, scan: result)
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
    }

    private func cancelDeclarationJob() {
        scheduler.cancel(owner: ObjectIdentifier(self))
        declarationJobPending = false
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
        snapshot = nil
        if hasDeclarationConsumerModule { scheduleDeclarationScan() }
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

        if Self.analysisModules.allSatisfy({ !moduleSettings.isEnabled($0) }) {
            cancelDeclarationJob()
            snapshot = nil
            checkpoints.removeAll()
            notify(.released)
            return
        }
        if !moduleSettings.isEnabled(.highlight) {
            // The highlighter is the only checkpoint user so far.
            checkpoints.removeAll()
        }
        guard hasDeclarationConsumerModule else {
            // Nobody reads declarations: drop them (navigator use stays transient).
            cancelDeclarationJob()
            snapshot = nil
            return
        }
        if let held = snapshot {
            // The text did not change, so the held scan is still exact; carry
            // it to the new version instead of rescanning.
            snapshot = DeclarationSnapshot(version: version, scan: held.scan)
        } else if declarationJobPending {
            // The pending job now carries a stale version; replace it.
            scheduleDeclarationScan()
        }
    }
}
