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

    /// Whether completion can run at all (the `completion` module is on);
    /// drives Edit ▸ Show Completions' enabled state.
    var isCompletionAvailable: Bool { get }

    /// The manual request (⌥⎋ / `complete(_:)`, Edit ▸ Show Completions):
    /// opens the popup at the caret, empty prefix allowed (plan §5.1).
    func requestManualCompletion()
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
/// - **Embedded languages** (T17.8c): in an HTML `<script>` / `<style>` or a
///   Markdown fence the language at the caret decides the request (the
///   engine reads it from the host scanner's state; the `$` trigger asks
///   `caretLanguageIdentifier()`); the child's keywords are cached by the
///   engine and released with it. The document language never changes.
/// - **Word index**: built synchronously on first use / `indexDocument()`,
///   and after an edit pause (0.15 s) rebuilt by a sliced `AnalysisScheduler`
///   job (4 ms slices, dropped on the next edit); words typed since are found
///   by the engine's nearby-line scan.
/// - **Requests**: a typed letter / `_` / (JS / TS at the caret) `$` or `.`
///   opens the popup when the engine's trigger rules allow it (plan §5.1);
///   `requestCompletion(manual:)` is the manual entry (T17.6: ⌥⎋ through
///   `EditorTextView.complete(_:)` and Edit ▸ Show Completions). While open,
///   every keystroke refilters or dismisses — an automatic popup closes when
///   the caret moves into a string or comment; a manual one stays manual
///   only while the caret stays in the same identifier.
/// - **List** (T17.6, plan §5.5): each row shows the name with the matched
///   ranges in bold and a dimmed category label in the UI language; the
///   panel width fits the widest row within 180–480 pt (and the screen); the
///   selection survives refreshes by candidate identity.
/// - **Input methods** (plan §5.6): no popup opens or refreshes while the
///   text view has marked text; the text view closes it when a composition
///   starts and passes every key to the input method meanwhile.
/// - **Dismissal**: accept, Esc, a click in the text, a caret move without an
///   edit (arrows, mouse, programmatic), an edit that no keystroke refreshed
///   (paste, undo, menu commands — checked on the next run-loop turn), the
///   editor losing focus or its window resigning key / moving / resizing, a
///   scroll that takes the anchor out of view, a language switch and the
///   module switching off. A dismissed popup can never write.
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
    /// The rows shown for `suggestions` (labels resolved once per refresh).
    private var rows: [CompletionRowContent] = []
    /// Guards our own completion insertion from being treated as a user action.
    private var isApplyingCompletion = false
    /// An edit-without-refresh check is queued for the next run-loop turn.
    private var staleCheck: DispatchWorkItem?
    /// Notifications observed while the popup is up (removed on dismiss).
    private var dismissObservations: [(NSNotification.Name, AnyObject?)] = []

    /// Tests / screenshots: label language instead of the UI language.
    var labelLanguageOverride: AppLanguage?

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

    /// Whether the shown popup came from a manual request (tests).
    var isShowingManualForTesting: Bool { panel != nil && shownManual }

    /// The popup panel and its table (tests, screenshots).
    var panelForTesting: NSPanel? { panel }
    var tableViewForTesting: NSTableView? { tableView }

    /// The selected candidate (tests).
    var selectedCandidateForTesting: Candidate? {
        guard let table = tableView, table.selectedRow >= 0, table.selectedRow < suggestions.count else { return nil }
        return suggestions[table.selectedRow]
    }

    /// Selects `row` as ↑ / ↓ would (tests).
    func selectRowForTesting(_ row: Int) {
        tableView?.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    /// The table's double-click action, as a double click on the selected row
    /// sends it (tests).
    func sendDoubleClickForTesting() {
        guard let table = tableView, let action = table.doubleAction else { return }
        NSApp.sendAction(action, to: table.target, from: table)
    }

    /// The row cell AppKit shows for `row` (tests).
    func cellForTesting(row: Int) -> CompletionCellView? {
        tableView?.view(atColumn: 0, row: row, makeIfNecessary: true) as? CompletionCellView
    }

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
            // A popup computed for the old language is stale (plan §5.6).
            dismiss()
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
        if panel != nil { scheduleStaleCheck() }
        guard moduleEnabled, wordIndex != nil else { return }
        wordsJournal.record(editedRange: editedRange, changeInLength: delta)
        scheduleWordIndexBuild(after: debounceInterval)
    }

    // MARK: - CompletionKeyHandler

    public var isCompletionActive: Bool { panel?.isVisible == true }

    public var isCompletionAvailable: Bool { moduleEnabled }

    public func requestManualCompletion() { requestCompletion(manual: true) }

    public func handleCompletionKeyDown(_ event: NSEvent) -> Bool {
        guard isCompletionActive else { return false }
        // An input method owns every key mid-composition (the text view
        // already checks; this guards other callers).
        if textView?.hasMarkedText() == true {
            dismiss()
            return false
        }
        let modified = !event.modifierFlags.intersection([.command, .option, .control]).isEmpty
        let shifted = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 125, 126, 36, 76, 48:
            // Modified arrows (⌘↑/↓ jump to document start/end, ⌥↑/↓ move by
            // paragraph or lines), ⇧⏎, ⇧⇥ (outdent), ⌘⏎ (insert line below)
            // belong to the text view: dismiss and let them through.
            if modified || shifted {
                dismiss()
                return false
            }
        case 53:
            // ⌥⎋ (and other modified Esc) reaches `complete(_:)` / the menu
            // and refreshes the list as a manual request.
            if modified { return false }
        default:
            break
        }
        switch event.keyCode {
        case 126: moveSelection(-1); return true    // up
        case 125: moveSelection(1);  return true    // down
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
            updatePopup(manual: shownManual && caretIsInShownIdentifier())
        } else {
            guard let chars = event.charactersIgnoringModifiers,
                  let first = chars.first,
                  first.isLetter || first == "_" || first == "."
                    || (first == "$" && IdentifierText.allowsDollar(caretLanguageIdentifier())) else { return }
            updatePopup(manual: false)
        }
        if PerfLog.isEnabled { logRequest(event, lazyIndex: lazyIndex) }
    }

    /// Opens (or refreshes) the popup at the caret. `manual`: the user asked
    /// for it (T17.6 `complete(_:)`): any position, empty prefix allowed.
    public func requestCompletion(manual: Bool) {
        guard moduleEnabled else { return }
        guard textView?.hasMarkedText() != true else { dismiss(); return }
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

    /// The caret still edits the identifier the shown popup was computed for
    /// (a manual popup stays manual only there: typing a space or moving to
    /// another word re-applies the automatic rules).
    private func caretIsInShownIdentifier() -> Bool {
        guard let textView, let shown = shownContext else { return false }
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return false }
        let text = textView.textStorage?.mutableString ?? (textView.string as NSString)
        guard selection.location <= text.length,
              let start = IdentifierText.runStart(before: selection.location, in: text,
                                                  dollar: IdentifierText.allowsDollar(shown.languageIdentifier))
        else { return false }
        return start == shown.prefixRange.location
    }

    /// The language at the caret (T17.8c): the document's, or inside an
    /// embedded body (HTML `<script>` / `<style>`, a Markdown fence) the
    /// child's — the engine's helper over the analysis's context
    /// checkpoints. Only an embedding host scans for it.
    func caretLanguageIdentifier() -> String {
        guard let textView, let scanner = contextScanner, scanner.hasEmbeddedLanguages else {
            return languageIdentifier
        }
        let selection = textView.selectedRange()
        let text: NSString = textView.textStorage?.mutableString ?? (textView.string as NSString)
        return WindowScan.caretLanguage(text: text, caret: selection.location, hostIdentifier: languageIdentifier,
                                        scanner: scanner, checkpoints: &analysis.contextCheckpoints).identifier
    }

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
        // No popup over an input method's composition (plan §5.6).
        guard textView?.hasMarkedText() != true,
              let request = makeRequest(manual: manual),
              let result = engine.complete(request, checkpoints: &analysis.contextCheckpoints) else {
            dismiss()
            return
        }
        // Keep the selected candidate selected (by identity) across refreshes.
        let selected = tableView.flatMap { table in
            table.selectedRow >= 0 && table.selectedRow < suggestions.count ? suggestions[table.selectedRow].identity : nil
        }
        suggestions = result.candidates
        let language = labelLanguageOverride ?? L10n.current
        rows = result.candidates.map { CompletionRowContent(candidate: $0, language: language) }
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
        acceptRow(tableView?.selectedRow ?? -1)
    }

    /// Accepts the candidate in `row` (Tab / Return / Enter: the selected
    /// row; a double click: the clicked row).
    private func acceptRow(_ row: Int) {
        guard let textView, let context = shownContext, row >= 0, row < suggestions.count else {
            dismiss()
            return
        }
        let candidate = suggestions[row]
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
        tableView?.scrollRowToVisible(row)
        positionPanel(panel, anchorRange: anchorRange)
        if !panel.isVisible {
            panel.orderFront(nil)
            observeDismissTriggers()
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: CompletionListMetrics.minimumWidth, height: 160),
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
        table.style = .plain
        table.rowHeight = CompletionListMetrics.rowHeight
        table.intercellSpacing = NSSize(width: 0, height: CompletionListMetrics.rowPitch - CompletionListMetrics.rowHeight)
        table.backgroundColor = .controlBackgroundColor
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("word"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(tableDoubleClicked)
        table.allowsEmptySelection = false
        table.setAccessibilityLabel(L10n.t(.menuShowCompletions))

        scroll.documentView = table
        panel.contentView = scroll
        self.tableView = table
        return panel
    }

    /// Screen rect of `range` (an empty range: the caret), as the input
    /// method sees it.
    private func screenRect(of range: NSRange) -> NSRect? {
        guard let textView, textView.window != nil else { return nil }
        let rect = textView.firstRect(forCharacterRange: range, actualRange: nil)
        return rect == .zero ? nil : rect
    }

    private func positionPanel(_ panel: NSPanel, anchorRange: NSRange) {
        guard let textView, let window = textView.window,
              let anchor = screenRect(of: anchorRange) else { return }

        let rowCount = min(suggestions.count, CompletionListMetrics.visibleRows)
        let height = CGFloat(rowCount) * CompletionListMetrics.rowPitch + 4
        let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame
        let scroller: CGFloat = suggestions.count > CompletionListMetrics.visibleRows
            && NSScroller.preferredScrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        let width = CompletionListMetrics.panelWidth(rows: rows, scroller: scroller,
                                                     screenWidth: visibleFrame?.width)
        // Names line up with the typed prefix. Above the caret line (screen
        // coords: y grows upward): the IME candidate window sits *below* the
        // caret during Chinese / Japanese composition, and a below-the-caret
        // popup covered it (user feedback). Falls back to below only when
        // there is no room above.
        var origin = NSPoint(x: anchor.minX - CompletionListMetrics.leadingPadding - 1, y: anchor.maxY + 2)
        if let visibleFrame {
            if origin.y + height > visibleFrame.maxY {
                origin.y = anchor.minY - height - 2
            }
            let margin = CompletionListMetrics.screenMargin
            origin.x = max(visibleFrame.minX + margin, min(origin.x, visibleFrame.maxX - margin - width))
        }
        // Only a changed frame is applied; the run loop's display pass draws
        // it (and the reloaded rows) — no extra synchronous draw per key.
        let frame = NSRect(x: origin.x, y: origin.y, width: width, height: height)
        guard frame != panel.frame else { return }
        let widthChanged = frame.width != panel.frame.width
        panel.setFrame(frame, display: false)
        if widthChanged { tableView?.sizeLastColumnToFit() }
    }

    // MARK: - Dismissal wiring

    private func observeDismissTriggers() {
        guard let textView, let window = textView.window else { return }
        var observations: [(NSNotification.Name, AnyObject?, Selector)] = [
            (NSWindow.didResignKeyNotification, window, #selector(hostWindowResignedKey)),
            (NSWindow.didMoveNotification, window, #selector(hostWindowMoved)),
            (NSWindow.didResizeNotification, window, #selector(hostWindowMoved)),
            (NSTextView.didChangeSelectionNotification, textView, #selector(textViewSelectionChanged)),
        ]
        if let clip = textView.enclosingScrollView?.contentView {
            observations.append((NSView.boundsDidChangeNotification, clip, #selector(textViewScrolled)))
        }
        for (name, object, selector) in observations {
            NotificationCenter.default.addObserver(self, selector: selector, name: name, object: object)
        }
        dismissObservations = observations.map { ($0.0, $0.1) }
    }

    private func removeDismissObservers() {
        for (name, object) in dismissObservations {
            NotificationCenter.default.removeObserver(self, name: name, object: object)
        }
        dismissObservations = []
    }

    @objc private func hostWindowResignedKey() { dismiss() }

    @objc private func hostWindowMoved() { dismiss() }

    /// A caret move without an edit (arrows, mouse, programmatic: find, go to
    /// line…) closes the popup. A typed key moves the caret *with* an edit;
    /// its refresh follows synchronously in `textViewDidInsertKey`.
    @objc private func textViewSelectionChanged() {
        guard panel != nil, !isApplyingCompletion, let textView, let shown = shownContext else { return }
        guard editCount == shownEditCount else { return }
        if textView.selectedRange() != NSRange(location: shown.caret, length: 0) { dismiss() }
    }

    /// Scrolling keeps the popup on its anchor, and closes it once the anchor
    /// leaves the visible rect.
    @objc private func textViewScrolled() {
        guard let panel, let textView, let window = textView.window, let shown = shownContext,
              let anchor = screenRect(of: shown.prefixRange) else {
            dismiss()
            return
        }
        let inView = textView.convert(window.convertFromScreen(anchor), from: nil)
        let probe = NSPoint(x: min(inView.minX, max(textView.visibleRect.minX, inView.maxX - 1)), y: inView.midY)
        guard textView.visibleRect.contains(probe) else {
            dismiss()
            return
        }
        positionPanel(panel, anchorRange: shown.prefixRange)
    }

    /// An edit that no keystroke refreshed (paste, undo, menu commands, line
    /// operations) leaves the popup stale: close it on the next run-loop turn
    /// (never during `didProcessEditing`).
    private func scheduleStaleCheck() {
        guard staleCheck == nil, !isApplyingCompletion else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.staleCheck = nil
            if self.panel != nil, self.shownEditCount != self.editCount { self.dismiss() }
        }
        staleCheck = item
        DispatchQueue.main.async(execute: item)
    }

    private func dismiss() {
        staleCheck?.cancel()
        staleCheck = nil
        guard let panel else { return }
        removeDismissObservers()
        panel.orderOut(nil)
        self.panel = nil
        tableView = nil
        suggestions = []
        rows = []
        shownContext = nil
        shownManual = false
    }

    /// A double click accepts the clicked row (the selected one when the
    /// action did not come from a click).
    @objc private func tableDoubleClicked() {
        guard let table = tableView else { return }
        acceptRow(table.clickedRow >= 0 ? table.clickedRow : table.selectedRow)
    }
}

// MARK: - Table data source / delegate

extension CompletionController: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    public func tableView(_ tableView: NSTableView,
                          viewFor tableColumn: NSTableColumn?,
                          row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: CompletionCellView.identifier, owner: self) as? CompletionCellView
            ?? CompletionCellView(frame: .zero)
        if row < rows.count { cell.configure(rows[row]) }
        return cell
    }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        CompletionRowView()
    }
}
