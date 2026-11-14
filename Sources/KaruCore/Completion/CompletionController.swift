import AppKit

/// Hook the editor text view uses to route keys to an active completion popup.
///
/// The text view holds this weakly and consults it only inside `keyDown` /
/// `mouseDown`; when no completion controller is attached (or none is active),
/// the cost is a single nil / bool check, so an unused completion module adds
/// no per-keystroke overhead.
@MainActor
public protocol CompletionKeyHandler: AnyObject {
    /// Whether a completion popup is currently on screen.
    var isCompletionActive: Bool { get }

    /// Handle a navigation key (arrows / Return / Tab / Esc) while the popup is
    /// open. Returns `true` if the event was consumed and must not reach the
    /// normal text-input path.
    func handleCompletionKeyDown(_ event: NSEvent) -> Bool

    /// Called after a normal keystroke has been inserted, so the controller can
    /// open, refilter, or dismiss the popup based on the new caret prefix.
    func textViewDidInsertKey(_ event: NSEvent)

    /// Dismiss the popup (e.g. the user clicked elsewhere in the text).
    func dismissCompletion()
}

/// Completion module: drives the candidate engine and the floating
/// suggestion popup for one editor window.
///
/// - **Candidates** (M17 T17.5) come from `CandidateEngine`: scope bindings,
///   class members, receiver usage and module-level declarations from the
///   shared `DocumentAnalysis` snapshot (the last *published* one, mapped
///   through its edit journal while a rescan is pending), the language's
///   keywords / builtins, and the document word index. A language change
///   reaches this controller synchronously through the analysis, so the
///   very next request already ranks the new language's declarations.
///   Constructed without an analysis (unit tests, probes) it owns a private
///   one and forwards its edits to it.
/// - **Word index**: built synchronously on first use / `indexDocument()`,
///   and after an edit pause (0.15 s) rebuilt by a sliced `AnalysisScheduler`
///   job (4 ms slices, dropped on the next edit); words typed since are found
///   by the engine's nearby-line scan.
/// - **Requests**: a typed letter / `_` / (JS / TS) `$` or `.` opens the
///   popup when the engine's trigger rules allow it (plan §5.1);
///   `requestCompletion(manual:)` is the manual entry for T17.6. While open,
///   every keystroke refilters or dismisses — an automatic popup closes when
///   the caret moves into a string or comment.
/// - **Accept** re-checks that the caret, the document version and the
///   identifier around the caret are unchanged (else it recomputes and does
///   not insert), then replaces the **whole identifier** through
///   `insertText(_:replacementRange:)` as its own undo step and records the
///   candidate in the window's recent-accept list.
///
/// Gating (ARCHITECTURE.md §2.5), mirroring `HighlightEngine`: gated on
/// `module.completion`. Switching the module off dismisses the popup and drops
/// the word index, the engine caches and the recent accepts, so a disabled
/// controller's resident cost returns to ≈ 0 (`isRuntimeStateReleased ==
/// true`); switching it back on rebuilds from the current document.
@MainActor
public final class CompletionController: NSObject, TextStorageObserving, CompletionKeyHandler,
                                          DocumentAnalysisConsumer {
    private weak var textView: NSTextView?
    private let moduleSettings: ModuleSettings
    private let moduleCenter: NotificationCenter
    private let scheduler: AnalysisScheduler

    /// The document analysis owning the language and declaration snapshot.
    let analysis: DocumentAnalysis
    /// True when this controller created `analysis` and must feed it edits.
    private let ownsAnalysis: Bool

    /// Releasable runtime state: the document word index. `nil` when the module
    /// is disabled or nothing has been indexed yet.
    private var wordIndex: WordIndex?
    private var wordsGeneration: UInt64 = 0
    /// Edits since `wordIndex` was built.
    private var wordsJournal = EditJournal()
    /// Character edits seen (word-index jobs are dropped when it moves).
    private var editCount: UInt64 = 0
    private var wordJobPending = false

    /// Releasable runtime state: the candidate engine's caches.
    private var engine = CandidateEngine()
    /// Recently accepted candidates (this window only, ≤ 32).
    private var recent = RecentAccepts()

    /// Always-retained, cheap config resolved from the file's language.
    private var languageIdentifier: String = ""
    private var languageKeywords: [String] = []
    private var languageBuiltins: [String] = []
    private var contextScanner: LexicalScanner?

    private var moduleEnabled: Bool

    /// Debounce before the word index is rebuilt after an edit.
    private let debounceInterval: TimeInterval = 0.15
    /// UTF-16 units the word-index builder reads per step inside a slice.
    private static let wordStepUnits = 4_096

    // MARK: Popup UI state

    private var panel: NSPanel?
    private var tableView: NSTableView?
    private var suggestions: [Candidate] = []
    /// The context the shown suggestions were computed for.
    private var shownContext: CompletionContext?
    /// `analysis.version` / `editCount` when they were computed.
    private var shownVersion: UInt64 = 0
    private var shownEditCount: UInt64 = 0
    /// The popup was opened by a manual request.
    private var shownManual = false
    /// Guards our own completion insertion from being treated as a user action.
    private var isApplyingCompletion = false

    // MARK: - Queryable state (tests / diagnostics)

    /// True when no runtime index state is held — guaranteed after the module is
    /// switched off (the acceptance-criteria "released" state).
    public var isRuntimeStateReleased: Bool { wordIndex == nil && !engine.holdsState && recent.entries.isEmpty }

    /// Whether the `completion` module is enabled.
    public var isModuleEnabled: Bool { moduleEnabled }

    /// The suggestion list the popup is currently showing (empty when no popup
    /// is up). Read-only window for the M17 baseline capture suite.
    var currentSuggestionsForTesting: [String] { panel == nil ? [] : suggestions.map(\.name) }

    /// The candidates the popup is showing (tests).
    var currentCandidatesForTesting: [Candidate] { panel == nil ? [] : suggestions }

    /// The context of the shown popup (tests).
    var currentContextForTesting: CompletionContext? { panel == nil ? nil : shownContext }

    /// The declaration names of the snapshot the next request reads (tests).
    var currentSymbolsForTesting: Set<String> {
        guard moduleEnabled, wordIndex != nil else { return [] }
        return analysis.publishedDeclarations?.snapshot.scan.completionSymbols ?? []
    }

    /// The recent-accept list (tests).
    var recentAcceptsForTesting: RecentAccepts { recent }

    /// The word index (tests, benchmarks).
    var wordIndexForTesting: WordIndex? { wordIndex }

    // MARK: - Init

    /// `analysis`: the window's shared document analysis; `nil` creates a
    /// private one on the same text view and settings.
    public init(textView: NSTextView,
                moduleSettings: ModuleSettings = ModuleSettings(),
                moduleCenter: NotificationCenter = .default,
                analysis: DocumentAnalysis? = nil,
                scheduler: AnalysisScheduler = .shared) {
        self.textView = textView
        self.moduleSettings = moduleSettings
        self.moduleCenter = moduleCenter
        self.scheduler = scheduler
        self.moduleEnabled = moduleSettings.isEnabled(.completion)
        self.analysis = analysis ?? DocumentAnalysis(textView: textView,
                                                     moduleSettings: moduleSettings,
                                                     moduleCenter: moduleCenter,
                                                     scheduler: scheduler)
        self.ownsAnalysis = analysis == nil
        super.init()
        self.analysis.addConsumer(self)
        applyLanguageKeywords()

        moduleCenter.addObserver(
            self, selector: #selector(moduleSettingsChanged(_:)),
            name: ModuleSettings.didChangeNotification, object: nil
        )
    }

    deinit {
        moduleCenter.removeObserver(self)
    }

    // MARK: - Language wiring

    /// Points the document at the language owning `ext` via the analysis (in
    /// an editor window that also re-points the highlighter). The analysis
    /// calls back synchronously, which loads the keywords.
    public func setLanguage(fileExtension ext: String?) {
        analysis.setLanguage(identifier: ext.flatMap { LanguageRegistry.identifier(forExtension: $0) })
    }

    /// Points the document at the language whose stable `identifier` is `id`
    /// (e.g. `"python"`) via the analysis. An empty / unknown identifier drops
    /// back to plain text.
    public func setLanguage(identifier id: String?) {
        analysis.setLanguage(identifier: id)
    }

    /// Loads the keywords, builtins and context scanner of the analysis's
    /// language (always-retained cheap config, independent of module state).
    private func applyLanguageKeywords() {
        let id = analysis.languageIdentifier
        guard !id.isEmpty, let def = LanguageRegistry.definition(forIdentifier: id) else {
            languageIdentifier = ""
            languageKeywords = []
            languageBuiltins = []
            contextScanner = nil
            return
        }
        languageIdentifier = def.identifier
        languageKeywords = def.keywords
        languageBuiltins = def.builtins
        contextScanner = CandidateEngine.contextScanner(for: def.identifier, definition: def)
    }

    // MARK: - DocumentAnalysisConsumer

    public func documentAnalysisDidChange(_ analysis: DocumentAnalysis,
                                          reason: DocumentAnalysis.ChangeReason) {
        switch reason {
        case .language:
            let dollar = wordIndex?.allowsDollar
            applyLanguageKeywords()
            engine.reset()
            // `$` is a word character in JS / TS only: re-tokenize when that flips.
            if moduleEnabled, let dollar, dollar != IdentifierText.allowsDollar(languageIdentifier) {
                scheduleWordIndexBuild(after: 0)
            }
        case .declarations:
            engine.dropIndex(unlessVersion: analysis.publishedDeclarations?.snapshot.version)
        case .released:
            engine.reset()
        }
    }

    // MARK: - Indexing

    /// Synchronously (re)builds the word index from the current document and
    /// makes sure the analysis holds a declaration snapshot (scanning only if
    /// it has none) — but only while the module is enabled. Safe to call
    /// after a file loads.
    public func indexDocument() {
        guard moduleEnabled, let textView else { return }
        let text = textView.textStorage?.mutableString ?? (textView.string as NSString)
        let start = PerfLog.isEnabled ? PerfLog.now() : 0
        scheduler.cancel(owner: ObjectIdentifier(self))
        wordJobPending = false
        var builder = WordIndexBuilder(dollar: IdentifierText.allowsDollar(languageIdentifier))
        installWordIndex(builder.finish(text))
        if analysis.publishedDeclarations == nil { _ = analysis.ensureDeclarations() }
        if PerfLog.isEnabled {
            PerfLog.record("completion.index", since: start,
                           ["docLen": text.length, "lang": languageIdentifier, "sliced": 0])
        }
    }

    private func installWordIndex(_ index: WordIndex) {
        wordIndex = index
        wordsGeneration &+= 1
        wordsJournal.reset()
    }

    /// Schedules the sliced word-index rebuild for the current text.
    private func scheduleWordIndexBuild(after delay: TimeInterval) {
        guard moduleEnabled else { return }
        let jobEdits = editCount
        let dollar = IdentifierText.allowsDollar(languageIdentifier)
        var builder: WordIndexBuilder?
        var elapsed: UInt64 = 0
        var slices = 0
        var longest: UInt64 = 0
        let job = AnalysisJob(
            owner: ObjectIdentifier(self),
            version: jobEdits,
            step: { [weak self] deadline in
                guard let self, self.moduleEnabled, self.editCount == jobEdits,
                      let text = self.textView?.textStorage?.mutableString else { return true }
                if builder == nil { builder = WordIndexBuilder(dollar: dollar) }
                let sliceStart = DispatchTime.now().uptimeNanoseconds
                var done = false
                repeat {
                    done = builder!.step(text, budgetUnits: Self.wordStepUnits)
                } while !done && DispatchTime.now().uptimeNanoseconds < deadline
                let sliceTime = DispatchTime.now().uptimeNanoseconds &- sliceStart
                elapsed &+= sliceTime
                longest = max(longest, sliceTime)
                slices += 1
                return done
            },
            completion: { [weak self] in
                guard let self else { return }
                self.wordJobPending = false
                guard self.moduleEnabled, self.editCount == jobEdits, let index = builder?.index else { return }
                self.installWordIndex(index)
                if PerfLog.isEnabled {
                    PerfLog.record("completion.index", durationSeconds: Double(elapsed) / 1e9,
                                   ["docLen": self.textView?.textStorage?.length ?? 0,
                                    "lang": self.languageIdentifier, "sliced": 1, "slices": slices,
                                    "maxSliceUs": Int(longest / 1000)])
                }
            },
            isInKeyWindow: { [weak textView] in textView?.window?.isKeyWindow == true }
        )
        wordJobPending = true
        scheduler.schedule(job, after: delay)
    }

    // MARK: - Module gating

    @objc private func moduleSettingsChanged(_ note: Notification) {
        guard (note.object as? String) == FeatureModule.completion.rawValue else { return }
        let nowEnabled = moduleSettings.isEnabled(.completion)
        guard nowEnabled != moduleEnabled else { return }
        moduleEnabled = nowEnabled
        if nowEnabled {
            indexDocument()
        } else {
            tearDown()
        }
    }

    /// Releases all runtime state and closes the popup.
    private func tearDown() {
        scheduler.cancel(owner: ObjectIdentifier(self))
        wordJobPending = false
        wordIndex = nil
        wordsJournal.reset()
        engine.reset()
        recent.removeAll()
        dismiss()
    }

    // MARK: - TextStorageObserving

    public func textStorageDidProcessEditing(editedMask: NSTextStorageEditActions,
                                             editedRange: NSRange,
                                             changeInLength delta: Int,
                                             textStorage: NSTextStorage) {
        guard editedMask.contains(.editedCharacters) else { return }
        if ownsAnalysis {
            analysis.textStorageDidProcessEditing(editedMask: editedMask, editedRange: editedRange,
                                                  changeInLength: delta, textStorage: textStorage)
        }
        editCount &+= 1
        guard moduleEnabled, wordIndex != nil else { return }
        wordsJournal.record(editedRange: editedRange, changeInLength: delta)
        scheduleWordIndexBuild(after: debounceInterval)
    }

    // MARK: - CompletionKeyHandler

    public var isCompletionActive: Bool { panel?.isVisible == true }

    public func handleCompletionKeyDown(_ event: NSEvent) -> Bool {
        guard isCompletionActive else { return false }
        // Modified arrows (Cmd+↑/↓ jump to document start/end, Option+↑/↓ move
        // by paragraph) belong to the text view: dismiss and let them through.
        if [125, 126].contains(event.keyCode),
           !event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            dismiss()
            return false
        }
        switch event.keyCode {
        case 126: moveSelection(-1); return true   // up
        case 125: moveSelection(1);  return true   // down
        case 36, 76: acceptSelection(); return true // return / keypad enter
        case 48: acceptSelection(); return true     // tab
        case 53: dismiss(); return true             // esc
        default: return false
        }
    }

    public func textViewDidInsertKey(_ event: NSEvent) {
        guard moduleEnabled else { return }
        // First real use allocates the index lazily rather than waiting for the
        // debounce to fire, so the very first popup is not delayed.
        let lazyIndex = wordIndex == nil
        if lazyIndex { indexDocument() }

        if isCompletionActive {
            updatePopup(manual: shownManual)
        } else {
            guard let chars = event.charactersIgnoringModifiers,
                  let first = chars.first,
                  first.isLetter || first == "_" || first == "."
                    || (first == "$" && IdentifierText.allowsDollar(languageIdentifier)) else { return }
            updatePopup(manual: false)
        }
        if PerfLog.isEnabled { logRequest(event, lazyIndex: lazyIndex) }
    }

    /// Opens (or refreshes) the popup at the caret. `manual`: the user asked
    /// for it (T17.6 `complete(_:)`): any position, empty prefix allowed.
    public func requestCompletion(manual: Bool) {
        guard moduleEnabled else { return }
        if wordIndex == nil { indexDocument() }
        updatePopup(manual: manual)
    }

    /// `completion.request`: from the triggering key event to the popup being
    /// shown / refiltered or dismissed. Only called while `KARU_PERFLOG` is on.
    private func logRequest(_ event: NSEvent, lazyIndex: Bool) {
        let shown = panel != nil && !suggestions.isEmpty
        PerfLog.record("completion.request",
                       durationSeconds: ProcessInfo.processInfo.systemUptime - event.timestamp,
                       ["result": shown ? "shown" : "dismissed",
                        "count": shown ? suggestions.count : 0,
                        "prefixLen": shownContext?.prefixRange.length ?? 0,
                        "lazyIndex": lazyIndex ? 1 : 0,
                        "reused": engine.lastReusedMatches ? 1 : 0])
    }

    public func dismissCompletion() { dismiss() }

    // MARK: - Popup driving

    /// The engine request for the current caret, or nil without a plain caret.
    private func makeRequest(manual: Bool) -> CompletionRequest? {
        guard let textView else { return nil }
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return nil }
        let text: NSString = textView.textStorage?.mutableString ?? (textView.string as NSString)
        var request = CompletionRequest(text: text, caret: selection.location,
                                        languageIdentifier: languageIdentifier)
        request.manual = manual
        request.keywords = languageKeywords
        request.builtins = languageBuiltins
        if let published = analysis.publishedDeclarations {
            request.snapshot = published.snapshot.scan
            request.snapshotVersion = published.snapshot.version
            request.snapshotJournal = published.journal
        }
        request.words = wordIndex
        request.wordsGeneration = wordsGeneration
        request.wordsJournal = wordsJournal
        request.recent = recent
        request.scanner = contextScanner
        return request
    }

    /// Recomputes the candidates at the caret, then shows / refilters /
    /// dismisses the popup accordingly.
    private func updatePopup(manual: Bool) {
        guard let request = makeRequest(manual: manual),
              let result = engine.complete(request, checkpoints: &analysis.contextCheckpoints) else {
            dismiss()
            return
        }
        // Keep the selected candidate selected (by identity) across refreshes.
        let selected = tableView.flatMap { table in
            table.selectedRow >= 0 && table.selectedRow < suggestions.count ? suggestions[table.selectedRow].identity : nil
        }
        suggestions = result.candidates
        shownContext = result.context
        shownVersion = analysis.version
        shownEditCount = editCount
        shownManual = manual
        showOrUpdatePanel(anchorRange: result.context.prefixRange, keeping: selected)
    }

    private func moveSelection(_ delta: Int) {
        guard let table = tableView, !suggestions.isEmpty else { return }
        let current = table.selectedRow < 0 ? 0 : table.selectedRow
        let next = max(0, min(suggestions.count - 1, current + delta))
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    private func acceptSelection() {
        guard let table = tableView, let textView, let context = shownContext,
              table.selectedRow >= 0, table.selectedRow < suggestions.count else {
            dismiss()
            return
        }
        let candidate = suggestions[table.selectedRow]
        // The popup may be stale (an edit, a caret move or a programmatic
        // change since it was computed): never write into a moved range.
        let text = textView.textStorage?.mutableString ?? (textView.string as NSString)
        let selection = textView.selectedRange()
        let range = context.replacementRange
        guard selection == NSRange(location: context.caret, length: 0),
              analysis.version == shownVersion, editCount == shownEditCount,
              NSMaxRange(range) <= text.length, text.substring(with: range) == context.identifier else {
            updatePopup(manual: shownManual)
            return
        }
        isApplyingCompletion = true
        // Its own undo step (not merged with the preceding typing), through
        // the standard input path so the change notifications fire.
        textView.breakUndoCoalescing()
        textView.insertText(candidate.insertText, replacementRange: range)
        textView.breakUndoCoalescing()
        isApplyingCompletion = false
        recent.record(candidate.identity)
        dismiss()
    }

    // MARK: - Panel construction / placement

    private func showOrUpdatePanel(anchorRange: NSRange, keeping selected: CandidateIdentity?) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        tableView?.reloadData()
        let row = selected.flatMap { identity in suggestions.firstIndex { $0.identity == identity } } ?? 0
        tableView?.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        positionPanel(panel, anchorRange: anchorRange)
        if !panel.isVisible {
            panel.orderFront(nil)
            observeDismissTriggers()
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 160),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.backgroundColor = .clear
        panel.isMovable = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .lineBorder
        scroll.drawsBackground = true

        let table = NSTableView()
        table.headerView = nil
        table.rowHeight = 18
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.backgroundColor = .controlBackgroundColor
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("word"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(tableDoubleClicked)
        table.allowsEmptySelection = false

        scroll.documentView = table
        panel.contentView = scroll
        self.tableView = table
        return panel
    }

    private func positionPanel(_ panel: NSPanel, anchorRange: NSRange) {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer,
              let window = textView.window else { return }

        let glyphRange = layoutManager.glyphRange(forCharacterRange: anchorRange,
                                                  actualCharacterRange: nil)
        var caretRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
        let origin = textView.textContainerOrigin
        caretRect.origin.x += origin.x
        caretRect.origin.y += origin.y

        let rectInWindow = textView.convert(caretRect, to: nil)
        let rectOnScreen = window.convertToScreen(rectInWindow)

        let rowCount = min(suggestions.count, 10)
        let height = CGFloat(rowCount) * 19 + 4
        let width: CGFloat = 240
        // Above the caret line (screen coords: y grows upward): the IME
        // candidate window sits *below* the caret during Chinese / Japanese
        // composition, and a below-the-caret popup covered it (user feedback).
        // Falls back to below only when there is no room above.
        var originPoint = NSPoint(x: rectOnScreen.minX, y: rectOnScreen.maxY + 2)
        if let screen = window.screen, originPoint.y + height > screen.visibleFrame.maxY {
            originPoint.y = rectOnScreen.minY - height - 2
        }
        panel.setFrame(NSRect(x: originPoint.x, y: originPoint.y, width: width, height: height),
                       display: true)
    }

    // MARK: - Dismissal wiring

    private func observeDismissTriggers() {
        guard let window = textView?.window else { return }
        NotificationCenter.default.addObserver(
            self, selector: #selector(hostWindowResignedKey),
            name: NSWindow.didResignKeyNotification, object: window
        )
    }

    @objc private func hostWindowResignedKey() { dismiss() }

    private func dismiss() {
        guard let panel else { return }
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        panel.orderOut(nil)
        self.panel = nil
        tableView = nil
        suggestions = []
        shownContext = nil
        shownManual = false
    }

    @objc private func tableDoubleClicked() { acceptSelection() }
}

// MARK: - Table data source / delegate

extension CompletionController: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int { suggestions.count }

    public func tableView(_ tableView: NSTableView,
                          viewFor tableColumn: NSTableColumn?,
                          row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let field: NSTextField
        if let reused = tableView.makeView(withIdentifier: id, owner: self) as? NSTextField {
            field = reused
        } else {
            field = NSTextField(labelWithString: "")
            field.identifier = id
            field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            field.lineBreakMode = .byTruncatingTail
        }
        field.stringValue = row < suggestions.count ? suggestions[row].name : ""
        return field
    }
}
