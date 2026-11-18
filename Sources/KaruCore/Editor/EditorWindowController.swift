import AppKit

public final class EditorWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    var onClose: (() -> Void)?

    let documentController = DocumentController()
    private var textView: NSTextView!

    /// Shared newline index: one instance per window, injected into the gutter
    /// and reused by the find bar (and later by folding).
    let lineIndex = LineIndex(text: "")
    private var gutterView: GutterView!
    private var findBar: FindBarController!

    /// Native unified toolbar (language / indent / Format / modules / settings)
    /// and the bottom status strip (caret position / language / char count).
    private var toolbarController: EditorToolbarController!
    private let statusBar = StatusBarView()
    /// Shown above the editor after auto-save on focus loss failed; stays until
    /// the document is saved by any route (see `updateWindowState`). Like the
    /// title's unsaved marker it follows the dirty flag, so undoing back to the
    /// saved text does not dismiss it. Internal for tests.
    let saveFailureBanner = SaveFailureBanner()
    /// Offers the languages detection found plausible when it could not decide
    /// on its own (see `presentLanguageRanking`). Internal for tests.
    let languageSuggestionBanner = LanguageSuggestionBanner()

    /// Content ranking used for automatic language detection. Tests inject
    /// rankings here; the default is `LanguageSniffer.rank` (or the
    /// `KARU_DEBUG_LANGUAGE_CANDIDATES` diagnostic override).
    var languageRanker: (String) -> LanguageRanking = EditorWindowController.defaultLanguageRanker
    /// The most recent ranking for this document while it is undecided; feeds
    /// the band and the language menus' suggestion section. Cleared when
    /// another document is loaded.
    private(set) var latestLanguageRanking: LanguageRanking?
    /// The user closed the suggestion band for this document: it does not come
    /// back on later edits. Cleared by loading another document and by
    /// choosing Auto.
    private(set) var languageSuggestionDismissed = false
    /// Pending debounced ranking after ordinary typing; cancelled by the next
    /// edit, by an immediate ranking, by a load and at teardown.
    private var languageRankingWork: DispatchWorkItem?
    /// Quiet time after the last keystroke before the buffer is ranked.
    static let defaultLanguageRankingDebounce: TimeInterval = 0.6
    var languageRankingDebounce: TimeInterval = EditorWindowController.defaultLanguageRankingDebounce
    /// A single edit inserting at least this many characters (or any paste)
    /// is ranked at once instead of after the debounce.
    static let immediateRankingInsertion = 40
    /// Largest number of characters inserted by one storage edit since the
    /// last `textDidChange` (fed by `insertionMeter`).
    private var pendingInsertionLength = 0
    private var insertionMeter: InsertionMeter?

    /// `LanguageSniffer.rank`, unless the diagnostic variable
    /// `KARU_DEBUG_LANGUAGE_CANDIDATES=python,swift,go` is set at launch: then
    /// every ranking offers those candidates without a confident answer, so a
    /// snapshot can show the suggestion band before the real detector produces
    /// such rankings. Zero cost when the variable is unset.
    static let defaultLanguageRanker: (String) -> LanguageRanking = {
        if let raw = ProcessInfo.processInfo.environment["KARU_DEBUG_LANGUAGE_CANDIDATES"], !raw.isEmpty {
            let ids = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let guesses = ids.enumerated().map { LanguageGuess(identifier: $1, score: Double(ids.count - $0)) }
            return { _ in LanguageRanking(confident: nil, candidates: guesses) }
        }
        return LanguageSniffer.rank
    }()

    /// Multiplexes the single `textStorage.delegate` slot to the gutter (line
    /// index) and the highlight engine. Retained here because the storage holds
    /// its delegate weakly.
    private let observerHub = TextStorageObserverHub()
    /// Per-window document analysis (M17 T17.1): the single owner of the
    /// language, document version, lexical checkpoints and the declaration
    /// snapshot shared by the highlighter, completion and the navigator.
    /// Registered on the hub before every other observer.
    private(set) var documentAnalysis: DocumentAnalysis!
    private var highlightEngine: HighlightEngine!
    /// Retained here because the hub only holds observers weakly (T15.5).
    private var shrinkRepaint: ShrinkRepaintObserver?

    /// URL underlining + ⌘-click (T15.6). Retained for the same reason; its
    /// decoration lives in temporary attributes only, so nothing it draws can
    /// reach the document.
    private var linkDetector: LinkDetector?

    /// Adapts `allowsNonContiguousLayout` to the document size (eager layout for
    /// small files → smooth scrolling; noncontiguous for large files → memory
    /// budget). Registered on the observer hub so edits that cross the threshold
    /// flip the flag.
    private var layoutModeController: LayoutModeController!

    /// Prefix-completion driver: indexes the document (debounced), scans symbols
    /// and drives the suggestion popup. Module-gated on `module.completion`.
    private var completionController: CompletionController!

    /// Code-folding layer: acts as the layout manager's delegate (glyph
    /// suppression + fragment collapsing) and answers the gutter's arrow /
    /// hidden-line queries. Folding never mutates text, so the shared
    /// `LineIndex` — and thus line numbers / highlighting — stay correct.
    private var foldingController: FoldingController!

    /// Transient "Jump to Symbol" navigator (T8.4). Held only while its panel is
    /// on screen — created on demand by `jumpToSymbol(_:)` and dropped the moment
    /// it closes, so it keeps no resident symbol index (ARCHITECTURE.md §3.4).
    private var symbolNavigator: SymbolNavigator?

    /// Transient "Workspace Symbols" navigator (T17.14, ⌘T), held only while
    /// its panel is on screen.
    private var workspaceSymbolNavigator: WorkspaceSymbolNavigator?
    /// The project-folder index the navigator searches (tests inject one).
    var workspaceIndex: WorkspaceIndex = .shared
    /// Opens a file from the workspace-symbol navigator through the app's
    /// usual open path (de-duplicating against open windows) and returns
    /// its window; installed by `AppDelegate` at launch (nil: unbundled
    /// probes / tests, which then only reveal symbols of this document).
    public static var fileOpener: (@MainActor (URL) -> EditorWindowController?)?

    /// Transient "Go to Line" panel (T11.5). Like the symbol navigator, held only
    /// while its panel is on screen and dropped the moment it closes, so it keeps
    /// no resident state (ARCHITECTURE.md §3.4).
    private var goToLineController: GoToLineController?

    /// Transient "Command Palette" (T12.8, ⌘⇧P). Held only while its panel is on
    /// screen and dropped the moment it closes, so no command index survives the
    /// operation (ARCHITECTURE.md §3.4).
    private var commandPalette: CommandPalette?

    /// Cursor-word occurrence highlighter (T12.9). Viewport-only + debounced;
    /// registered on the observer hub for edit notifications and pinged from
    /// `selectionDidChange`. Retained for the window's lifetime (its resident
    /// cost is one bounded range array), cancelled on teardown.
    private var wordHighlighter: WordOccurrenceHighlighter!
    /// The language whose identifier rules (`$`) the word highlighter was last
    /// given, so an unchanged language builds no definition.
    private var wordHighlighterLanguage = ""

    /// Matched-bracket background tint. Registered on the observer hub (which
    /// holds observers weakly, so this controller retains it) to follow edits;
    /// recomputed from `selectionDidChange` and, for edits that leave the
    /// caret in place, from `textDidChange`. Fixed-size state (at most two
    /// ranges), cancelled on teardown.
    private var bracketHighlighter: BracketPairHighlighter!

    /// Run current buffer (T16.3b, Run/RunSessionController.swift). The session
    /// (runner + output panel) is created on first Run / Show Output and
    /// released on panel close, window close or `run` module off. The other
    /// two are injection points for tests.
    var runSession: RunSessionController?
    var runPrepare: RunSessionController.Prepare = RunSessionController.defaultPrepare
    var runModuleSettings = ModuleSettings()
    /// Output panel height chosen in this window (not persisted).
    var runPanelHeight: CGFloat?
    /// Where the output panel is inserted (below the editor scroll view).
    private weak var contentStack: NSStackView?
    private weak var editorScrollView: NSScrollView?

    /// True once the user has manually picked a language from the Language menu.
    /// Suppresses all automatic detection until they choose Auto again.
    private var userOverrodeLanguage = false

    /// True once automatic content sniffing has landed on a language (or a file
    /// extension resolved one). Prevents re-sniffing an untitled buffer on every
    /// keystroke after it has already been classified.
    private var didAutoDetectLanguage = false

    /// While an iCloud item is being downloaded before it can be shown, this
    /// holds the file's URL and a repeating poll timer. The window is "opened"
    /// for this URL (so a second Finder double-click just fronts it, per T10.4
    /// de-duplication) even though its content hasn't loaded yet. Both are
    /// cleared — and the timer invalidated — when the download finishes or times
    /// out, keeping with the "transient, not resident" rule (no standing service).
    private var pendingDownloadURL: URL?
    private var downloadTimer: Timer?

    /// Poll interval and overall deadline for the iCloud download wait.
    private static let downloadPollInterval: TimeInterval = 0.4
    private static let downloadTimeout: TimeInterval = 120

    /// Session bookkeeping for restore-after-relaunch (T14.8). Injected by
    /// `AppDelegate` so every window shares its store (and tests can point it at
    /// an isolated UserDefaults suite); a standalone window falls back to the
    /// standard domain.
    var sessionStore = SessionStore()

    /// Set at the top of `windowWillClose` and never cleared: the resign-key
    /// notification a closing window still emits must not re-run the focus-loss
    /// bookkeeping (T15.10 — it resurrected the just-removed session entry, so
    /// hand-closed windows returned after a crash restore).
    private var isClosing = false

    /// What a manual save does when the file changed on disk (R01 / F1b).
    enum SaveConflictChoice: Equatable {
        case saveAs, overwrite, cancel
    }
    /// Test seam: answers the save-conflict question instead of the modal
    /// alert. `nil` (production) runs the alert.
    var saveConflictChoiceOverride: (() -> SaveConflictChoice)?
    /// Test seam: picks the Save As destination (given the suggested name)
    /// instead of running `NSSavePanel`; returning `nil` means Cancel. `nil`
    /// (production) runs the panel.
    var saveAsURLOverride: ((String) -> URL?)?
    /// Test seam: sees every status-bar flash this window shows.
    var statusFlashObserver: ((String) -> Void)?
    /// Above zero while one of this window's own modal alerts or panels is up,
    /// so the become-key check does not run underneath it.
    private var modalDepth = 0
    /// The file's `stat` stamp when an external change was last reported to
    /// the user (status note, conflict question or conflict band) while the
    /// buffer had unsaved changes. The become-key check stays quiet while the
    /// file still carries this stamp; any further change reports again.
    private var announcedExternalStamp: DiskState.Stamp?

    /// Crash-draft backup for this window's unsaved content (T14.11). Injected
    /// by `AppDelegate` so every window shares one store (and tests can point it
    /// at a temporary directory); a standalone window falls back to the real
    /// Application Support location.
    var draftStore = DraftStore()

    /// Identity of this window's draft on disk. Freshly minted per window, but
    /// *inherited* from a recovered draft (see `applyRecoveredDraft`) so a
    /// window that came back from a crash keeps updating the same files instead
    /// of orphaning them.
    private(set) var draftID = UUID()

    /// When the next draft checkpoint fires (R05): debounced after the last
    /// keystroke, but at most `draftMaxInterval` after the first unflushed one.
    /// Holds a scheduled item only while an edit is unflushed — nothing is
    /// resident between checkpoints (ARCHITECTURE.md §3.4).
    private lazy var draftCheckpointer = DraftCheckpointer(
        debounce: Self.defaultDraftDebounce,
        maxInterval: Self.defaultDraftMaxInterval
    ) { [weak self] in
        self?.flushDraftNow()
    }

    /// Delay between the last keystroke and the draft hitting disk. Short enough
    /// that a crash costs at most a sentence, long enough that continuous typing
    /// writes rarely. Stored per window (rather than as a global) so a test can
    /// zero it out without mutating shared state.
    static let defaultDraftDebounce: TimeInterval = DraftCheckpointer.defaultDebounce
    var draftDebounceInterval: TimeInterval {
        get { draftCheckpointer.debounce }
        set { draftCheckpointer.debounce = newValue }
    }

    /// Upper bound on how long an edit can stay without a checkpoint while the
    /// user keeps typing (pauses shorter than the debounce never let it fire).
    static let defaultDraftMaxInterval: TimeInterval = DraftCheckpointer.defaultMaxInterval
    var draftMaxInterval: TimeInterval {
        get { draftCheckpointer.maxInterval }
        set { draftCheckpointer.maxInterval = newValue }
    }

    /// Test seam: the clock and timer behind the checkpoint schedule.
    var draftCheckpointScheduler: any CheckpointScheduling {
        get { draftCheckpointer.scheduler }
        set { draftCheckpointer.scheduler = newValue }
    }

    /// Shared serial queue for draft I/O: keeps a multi-megabyte snapshot (and
    /// its baseline hash) off the main thread.
    private static let draftQueue = DispatchQueue(label: "dev.enkin.karu.drafts",
                                                  qos: .utility)

    /// This window's draft I/O: one job in flight, at most one newer snapshot
    /// waiting, removals ordered after everything submitted before them.
    private lazy var draftWriter = DraftWriteQueue(queue: Self.draftQueue) { [weak self] in
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self?.processDraftOutcomes() }
        }
    }

    /// `true` from a failed draft write until the next successful one. The
    /// status-bar note is shown on the transition into this state only.
    private(set) var draftCheckpointFailing = false

    /// Whether the app as a whole is quitting, supplied by `AppDelegate`.
    /// Decides what a window close means for the session list: a *user* close
    /// says "don't reopen this next launch" (entry removed), while a close that
    /// merely rides along with termination must keep the entry so the file comes
    /// back. Defaults to `false` — a window with no delegate behind it (tests,
    /// diagnostics) is always closed "by the user".
    var isAppTerminating: () -> Bool = { false }

    /// The document's current line-ending style. Detected on open / reopen and
    /// updated after a manual conversion; deliberately *not* re-detected on every
    /// keystroke (a document-level property, and detection scans the whole buffer),
    /// so the status bar just renders this stored value.
    private var currentLineEnding: LineEnding = .lf

    public convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.setFrameAutosaveName("EditorWindow")
        // Explicitly opaque titlebar with a separator line: on macOS 26
        // (Liquid Glass) glassy titlebars can show scrolled document text
        // through, overlapping the window title (user bug report). Combined
        // with pinning the content stack to contentLayoutGuide below.
        window.titlebarAppearsTransparent = false
        window.titlebarSeparatorStyle = .line
        self.init(window: window)
        window.delegate = self

        let (scrollView, textView) = Self.makeEditorView()
        self.textView = textView

        // The observer hub owns the storage delegate slot; the gutter and the
        // highlight engine register with it.
        textView.textStorage?.delegate = observerHub

        // Document analysis first: on every edit it bumps the version and
        // invalidates checkpoints before any consumer reacts (M17 T17.1).
        let analysis = DocumentAnalysis(textView: textView)
        observerHub.add(analysis)
        self.documentAnalysis = analysis

        // Measures each edit's inserted length, so a large insertion is ranked
        // for a language at once instead of after the typing debounce.
        let meter = InsertionMeter { [weak self] length in
            guard let self else { return }
            self.pendingInsertionLength = max(self.pendingInsertionLength, length)
        }
        observerHub.add(meter)
        insertionMeter = meter

        // Attach the line-number gutter as the scroll view's vertical ruler.
        let gutter = GutterView(scrollView: scrollView,
                                textView: textView,
                                lineIndex: lineIndex,
                                observerHub: observerHub)
        scrollView.verticalRulerView = gutter
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        self.gutterView = gutter

        // Syntax highlighter: viewport-only, module-gated, foreground-only.
        let engine = HighlightEngine(textView: textView, scrollView: scrollView, analysis: analysis)
        observerHub.add(engine)
        self.highlightEngine = engine

        // Ghost-pixel guard (T15.5): repaint the band below shrinking edits —
        // the compositor does not reliably invalidate the vacated area, leaving
        // deleted lines visible on screen. The hub holds observers weakly, so
        // this controller retains it.
        let shrinkRepaint = ShrinkRepaintObserver(textView: textView)
        observerHub.add(shrinkRepaint)
        self.shrinkRepaint = shrinkRepaint

        // URL recognition (T15.6): debounced, temporary-attribute only, and the
        // ⌘-click target. A freshly built window is empty; `load(url:)` edits the
        // storage, which is what triggers the first scan.
        let linkDetector = LinkDetector(textView: textView)
        observerHub.add(linkDetector)
        (textView as? EditorTextView)?.linkDetector = linkDetector
        self.linkDetector = linkDetector

        // Adaptive layout mode: a fresh window is an empty (small) document, so
        // it starts with eager/contiguous layout. `load(url:)` re-pins it before
        // inserting text; edits that cross the threshold flip it via the hub.
        if let layoutManager = textView.layoutManager {
            let modeController = LayoutModeController(
                layoutManager: layoutManager,
                initialLength: (textView.string as NSString).length)
            observerHub.add(modeController)
            self.layoutModeController = modeController
        }

        // Prefix completion: shares the observer hub for edit notifications and
        // routes keys through the text view's completion hook. Module-gated.
        let completion = CompletionController(textView: textView, analysis: analysis, importService: .shared,
                                              workspaceIndex: .shared, crossFileTypes: .shared)
        // Import resolution (T17.13), other files' names and cross-file types
        // (T17.14) read the document's project folder.
        completion.documentURLProvider = { [weak self] in self?.documentController.fileURL }
        observerHub.add(completion)
        (textView as? EditorTextView)?.completionKeyHandler = completion
        self.completionController = completion

        // Code folding: layout-manager delegate + gutter arrow provider.
        // Registered on the hub after the gutter so the shared LineIndex is
        // already updated when folding reacts to an edit.
        let folding = FoldingController(textView: textView, lineIndex: lineIndex)
        textView.layoutManager?.delegate = folding
        // Folding rules are language-dependent (markdown folds by heading / code
        // fence); read the identifier at scan time rather than mirroring it here.
        folding.languageProvider = { [weak textView] in
            (textView as? EditorTextView)?.languageIdentifier ?? ""
        }
        observerHub.add(folding)
        gutter.foldProvider = folding
        // The editor paints the collapsed-block background; give it the same
        // fold provider and shared LineIndex (for header-line geometry).
        (textView as? EditorTextView)?.foldProvider = folding
        (textView as? EditorTextView)?.lineIndex = lineIndex
        self.foldingController = folding

        // Live selection count: while a mouse drag is extending the selection,
        // AppKit suppresses the did-change-selection notification, so the text
        // view pings us directly. Only the status bar refreshes here — the
        // heavier bracket/word highlights wait for the final selection.
        (textView as? EditorTextView)?.liveSelectionChanged = { [weak self] in
            self?.refreshStatusBar()
        }

        // Cursor-word occurrence highlighter: viewport-only, debounced. Shares
        // the observer hub for edit notifications; pinged from selectionDidChange.
        let wordHighlighter = WordOccurrenceHighlighter(textView: textView)
        observerHub.add(wordHighlighter)
        self.wordHighlighter = wordHighlighter

        let bracketHighlighter = BracketPairHighlighter(textView: textView)
        observerHub.add(bracketHighlighter)
        self.bracketHighlighter = bracketHighlighter

        // Find bar shares the window's LineIndex; it sits above the editor in a
        // vertical stack and collapses out of layout when hidden.
        let findBar = FindBarController(textView: textView, lineIndex: lineIndex)
        self.findBar = findBar

        // The find bar, the bracket pair and the same-word tint share the
        // `.backgroundColor` temporary attribute, which does not stack (last
        // writer wins; a removal removes every colour). Priority is search
        // match > bracket pair > word tint: after the bracket pair paints or
        // clears, the search matches it touched are re-applied on top; after
        // the word tint paints or clears, the pair is restored and then the
        // search matches; when the find bar wipes the document's background
        // (recompute / hide), the bracket pair and the word tint repaint.
        bracketHighlighter.onBackgroundChanged = { [weak findBar] ranges in
            findBar?.reapplyHighlights(intersecting: ranges)
        }
        wordHighlighter.onBackgroundChanged = { [weak findBar, weak bracketHighlighter] ranges in
            bracketHighlighter?.restore(intersecting: ranges)
            findBar?.reapplyHighlights(intersecting: ranges)
        }
        findBar.onHighlightsReset = { [weak self] in
            guard let self else { return }
            self.bracketHighlighter.backgroundWasReset()
            self.wordHighlighter.backgroundWasReset()
        }

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        // The save-failure banner is hidden until needed; a stack view drops
        // hidden views from layout, so it takes no room until then.
        let stack = NSStackView(views: [saveFailureBanner, languageSuggestionBanner,
                                        findBar.barView, scrollView, statusBar])
        saveFailureBanner.onRetry = { [weak self] in self?.saveDocument(nil) }
        saveFailureBanner.onSaveAs = { [weak self] in self?.saveDocumentAs(nil) }
        languageSuggestionBanner.onChoose = { [weak self] identifier in
            self?.chooseSuggestedLanguage(identifier: identifier)
        }
        languageSuggestionBanner.onDismiss = { [weak self] in self?.dismissLanguageSuggestions() }
        stack.orientation = .vertical
        stack.spacing = 0
        stack.distribution = .fill
        contentStack = stack
        editorScrollView = scrollView

        // Pin the stack to the window's contentLayoutGuide, NOT the content
        // view's edges: on macOS 26 (Liquid Glass) the content view extends
        // under the glassy titlebar/toolbar, and a scroll view AppKit can't
        // identify (ours sits inside a stack) gets no scroll-edge blur — so
        // scrolled text showed straight through the titlebar, overlapping the
        // window title. The layout guide excludes the titlebar area.
        let container = NSView()
        window.contentView = container
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        let topAnchor = (window.contentLayoutGuide as? NSLayoutGuide)?.topAnchor
            ?? container.topAnchor
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            saveFailureBanner.widthAnchor.constraint(equalTo: stack.widthAnchor),
            languageSuggestionBanner.widthAnchor.constraint(equalTo: stack.widthAnchor),
            findBar.barView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusBar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 22),
        ])

        // Native unified toolbar with the most-reached-for controls (user
        // feedback #3: settings should be directly above the document).
        let toolbar = EditorToolbarController(windowController: self)
        toolbar.install(in: window)
        self.toolbarController = toolbar

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textDidChange(_:)),
            name: NSText.didChangeNotification,
            object: textView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(selectionDidChange(_:)),
            name: NSTextView.didChangeSelectionNotification,
            object: textView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(languageDidChange),
            name: L10n.didChangeNotification,
            object: nil
        )
        // Font size changes (preferences stepper or View ▸ Zoom) are broadcast so
        // this window re-applies the size live, keeping every window in sync.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(fontSizeDidChange),
            name: EditorFontSettings.didChangeNotification,
            object: nil
        )
        // Focus-loss auto-save (T12.14): scoped to *this* window's resign-key so a
        // sibling window losing focus never triggers a save here.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleResignKey(_:)),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
        // External-change check (F1b): once per activation of *this* window.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
        // `run` module off: stop and release this window's run session (T16.3b).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(runModuleDidChange),
            name: ModuleSettings.didChangeNotification,
            object: nil
        )

        updateWindowState()
        refreshStatusBar()
    }

    /// Re-pulls every string this window owns after a UI-language switch: window
    /// title (Untitled), status bar captions, toolbar tooltips/labels, and the
    /// find bar. The main menu is rebuilt separately by `AppDelegate`.
    @objc private func languageDidChange() {
        updateWindowState()
        refreshStatusBar()
        toolbarController?.reloadStrings()
        findBar.reloadStrings()
        saveFailureBanner.reloadStrings()
        languageSuggestionBanner.reloadStrings()
    }

    /// Re-applies the shared editor font size after a change broadcast.
    @objc private func fontSizeDidChange() {
        textView.font = .monospacedSystemFont(ofSize: EditorFontSettings().fontSize, weight: .regular)
        // The gutter sizes and draws itself from the text view's font, but nothing
        // tells a ruler its client changed — without this the numbers kept the old
        // size until the next click into the text (user report).
        gutterView?.fontDidChange()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        downloadTimer?.invalidate()
        // A pending draft checkpoint holds only a weak reference; the
        // checkpointer cancels it in its own deinit as this controller (its
        // sole owner) is released.
        // The word highlighter is cancelled in `windowWillClose`, and cancels
        // its own pending work and observers again in its deinit, which runs
        // as this controller (its sole owner) is released.
    }

    private static func makeEditorView() -> (NSScrollView, NSTextView) {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = EditorTextView()
        // `allowsNonContiguousLayout` is now set adaptively by `LayoutModeController`
        // from the document length (see LayoutMode.swift): eager layout for small
        // files so fast scrolling never lags, noncontiguous for large files to
        // hold the memory budget. Left at the manager's default here; the
        // controller pins it once the window's length is known.
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: EditorFontSettings().fontSize, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true

        // A little breathing room around the text: left / right padding so the
        // first glyph is not jammed against the gutter, top padding so line 1
        // clears the toolbar seam.
        textView.textContainerInset = NSSize(width: 6, height: 8)

        // Loosen line spacing slightly (shared with the scratchpad).
        EditorTextView.applyLineSpacing(to: textView)

        scrollView.documentView = textView
        return (scrollView, textView)
    }

    // MARK: - Loading

    /// True for a freshly created window: untitled, empty, never edited, and not
    /// currently mid-download. Used by the app delegate to reuse (rather than
    /// orphan) the initial window when a file arrives from Finder right after
    /// launch. A window waiting on an iCloud download is *not* pristine — it is
    /// already committed to a URL — so a second, different open opens elsewhere.
    var isPristineUntitled: Bool {
        pendingDownloadURL == nil
            && documentController.fileURL == nil
            && !documentController.isDirty
            && textView.string.isEmpty
    }

    /// The URL this window is bound to for open/de-duplication purposes: the
    /// in-flight download target while syncing, otherwise the loaded file's URL
    /// (`nil` for an untitled document). Lets the app delegate front an existing
    /// window instead of opening a duplicate for the same file (T10.4).
    var currentFileURL: URL? {
        pendingDownloadURL ?? documentController.fileURL
    }

    // MARK: - iCloud download (open a not-yet-synced ubiquitous file)

    /// Opens a window for a ubiquitous item that is not yet on disk: kicks off
    /// the iCloud download, shows a "(Downloading…)" title, and polls until the
    /// file is readable (then loads it) or the deadline passes (then alerts).
    /// The window counts as "open for `url`" for the whole wait, so repeated
    /// double-clicks just re-front it rather than spawning duplicates.
    public func beginDownloading(url: URL) {
        pendingDownloadURL = url
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)

        window?.title = L10n.t(.downloadingTitle, url.lastPathComponent)
        window?.representedURL = url
        window?.isDocumentEdited = false

        let deadline = Date().addingTimeInterval(Self.downloadTimeout)
        let timer = Timer.scheduledTimer(
            withTimeInterval: Self.downloadPollInterval, repeats: true
        ) { [weak self] timer in
            self?.pollDownload(url: url, timer: timer, deadline: deadline)
        }
        downloadTimer = timer
    }

    private func pollDownload(url: URL, timer: Timer, deadline: Date) {
        let status = (try? url.resourceValues(
            forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus

        if UbiquitousFile.isDownloadComplete(status: status) {
            endDownload(timer: timer)
            load(url: url)
            return
        }
        if Date() >= deadline {
            endDownload(timer: timer)
            updateWindowState()
            showDownloadTimeout(url: url)
        }
    }

    /// Tears down the transient poll timer and download state (no resident
    /// service survives the operation).
    private func endDownload(timer: Timer) {
        timer.invalidate()
        downloadTimer = nil
        pendingDownloadURL = nil
    }

    private func showDownloadTimeout(url: URL) {
        let alert = NSAlert()
        alert.messageText = L10n.t(.downloadTimeoutTitle)
        alert.informativeText = L10n.t(.downloadTimeoutMessage, url.lastPathComponent)
        alert.alertStyle = .warning
        if let window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    /// Loads `url` into this window (used when opening a file in a new window).
    public func load(url: URL) {
        do {
            let text = try documentController.load(from: url)
            // Pin the layout mode from the document size *before* inserting the
            // text, so a large file is never laid out eagerly even momentarily.
            layoutModeController?.setLength((text as NSString).length)
            textView.string = text

            // Detect the file's line-ending style for the status bar.
            currentLineEnding = LineEnding.detect(in: text)

            // Loading a file resets any prior manual override / detection, and
            // the previous document's language suggestions with it.
            userOverrodeLanguage = false
            didAutoDetectLanguage = false
            resetLanguageSuggestions()

            detectFileLanguage(url: url, text: text)

            // Index the freshly loaded document's words (its declarations come
            // from the snapshot the language change just produced).
            completionController.indexDocument()

            // Loading fresh content should not go through the undo stack, and
            // the didChange notification only fires for user edits, so we
            // simply refresh window chrome here.
            updateWindowState()
            toolbarController?.refreshAll()
            refreshStatusBar()

            // The document is now "open" as far as session restore is concerned
            // (T14.8) — recorded here, at open time, so an update relaunch or a
            // crash still finds it in the list.
            recordSessionState()
        } catch {
            showSaveError(error)
        }
    }

    // MARK: - Session restore (T14.8)

    /// Document-space y of the visible area's top edge — what `restoreSession`
    /// scrolls back to.
    private var currentScrollY: Double {
        Double(textView.enclosingScrollView?.contentView.bounds.origin.y ?? 0)
    }

    /// Writes this window's file + caret + scroll position into the session
    /// list. A no-op for an untitled document (plan A restores saved files
    /// only). Called at the few low-frequency moments where the position is
    /// worth persisting: open, rename / Save As, focus loss, close, quit.
    func recordSessionState() {
        guard let url = documentController.fileURL else { return }
        sessionStore.record(path: url.path,
                            caret: textView.selectedRange().location,
                            scrollY: currentScrollY)
    }

    /// Moves the session entry after the document's URL changed (Save As or a
    /// titlebar rename): the old path must not resurrect a file that is no
    /// longer there under that name.
    private func migrateSessionEntry(from previousURL: URL?) {
        let current = documentController.fileURL.map { SessionStore.normalize($0.path) }
        if let previousURL, SessionStore.normalize(previousURL.path) != current {
            sessionStore.remove(path: previousURL.path)
        }
        recordSessionState()
    }

    /// Puts the caret and the scroll offset back where the previous session left
    /// them, after `load(url:)` has filled the window. The caret is clamped to
    /// the document (the file may have shrunk on disk since), and the scroll
    /// offset is best-effort — the clip view clamps it to the laid-out document
    /// height on its own.
    func restoreSession(caret: Int, scrollY: Double) {
        let length = (textView.string as NSString).length
        let selection = NSRange(location: min(max(0, caret), length), length: 0)
        textView.setSelectedRange(selection)
        textView.scrollRangeToVisible(selection)

        if scrollY > 0, let scrollView = textView.enclosingScrollView {
            let clipView = scrollView.contentView
            clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: scrollY))
            scrollView.reflectScrolledClipView(clipView)
        }
        // Keep the stored position in step with what was actually restored, so a
        // crash right after launch reopens the same place rather than the top.
        recordSessionState()
    }

    // MARK: - Crash drafts (T14.11)

    /// Queues a draft checkpoint for a moment after the typing stops — or, if
    /// the typing never stops long enough, for the maximum interval after the
    /// first unflushed edit.
    private func scheduleDraftFlush() {
        draftCheckpointer.noteEdit()
    }

    /// Brings the on-disk draft in line with the buffer right now, skipping the
    /// debounce. The arbitration rule (T14.11): **a draft exists exactly while
    /// the buffer differs from the saved baseline** — the very test the close
    /// prompt uses, so "there is a draft" and "closing would ask to save" can
    /// never disagree. The main thread only takes the snapshot; the background
    /// job hashes it, compares with the baseline digest, and then writes or
    /// removes the draft (R05). Internal so tests can drive it synchronously.
    func flushDraftNow() {
        cancelDraftFlush()
        draftWriter.submit(.checkpoint(makeDraftSnapshot(), draftStore))
    }

    /// The values a checkpoint job needs, taken on the main thread. No hashing
    /// here: the baseline travels as its digest. Internal for tests.
    func makeDraftSnapshot() -> DraftSnapshot {
        DraftSnapshot(id: draftID,
                      content: textView.string,
                      originalPath: documentController.fileURL?.path,
                      base: documentController.diskState,
                      baselineDigest: documentController.baselineSHA256)
    }

    /// Drops this window's draft — the content is back in sync with disk
    /// (saved, undone, reopened) or the user closed the window for good.
    /// Replaces any snapshot still waiting, and runs after the one in flight,
    /// so no older write can bring the draft back.
    private func removeDraft() {
        cancelDraftFlush()
        draftWriter.submit(.remove(draftID, draftStore))
    }

    /// Forgets any queued checkpoint without touching what is already on disk.
    private func cancelDraftFlush() {
        draftCheckpointer.cancel()
    }

    /// Applies what the background job reported: one status note when draft
    /// writes start failing, re-armed by the next successful write.
    private func processDraftOutcomes() {
        for outcome in draftWriter.takeOutcomes() {
            switch outcome {
            case .written:
                draftCheckpointFailing = false
            case .removed:
                break
            case .failed:
                guard !draftCheckpointFailing else { continue }
                draftCheckpointFailing = true
                flashStatus(L10n.t(.draftCheckpointFailed))
            }
        }
    }

    /// Blocks until this window's queued draft I/O has landed, then applies
    /// its outcomes. Test support only: production code never needs to wait
    /// for a best-effort backup.
    func waitForDraftWrites() {
        draftWriter.waitUntilIdle()
        processDraftOutcomes()
    }

    /// Pours recovered draft content into this window and adopts the draft's
    /// identity, so later edits keep updating the same files. The document
    /// baseline is deliberately left alone: against a file it stays the on-disk
    /// text (and against an untitled window it stays ""), so the window reads
    /// as dirty and the close prompt behaves exactly as it did before the crash.
    func applyRecoveredDraft(id: UUID, content: String) {
        draftID = id
        // Pin the layout mode from the size before inserting, as `load` does.
        layoutModeController?.setLength((content as NSString).length)
        textView.string = content
        currentLineEnding = LineEnding.detect(in: content)

        documentController.markEdited()
        completionController.indexDocument()
        redetectIndentUnit()
        // A recovered untitled buffer has no extension to classify it, so let
        // the sniffer have the same look it would get from typing — at once.
        pendingInsertionLength = 0
        if documentController.fileURL == nil {
            rankLanguageNow()
        }
        updateWindowState()
        toolbarController?.refreshAll()
        refreshStatusBar()
    }

    /// Shows a transient note in this window's status strip. Exists because the
    /// status bar is private to the window while the recovery messages are
    /// decided by `AppDelegate` (T14.11).
    func flashStatus(_ message: String) {
        statusBar.flashMessage(message)
        statusFlashObserver?(message)
    }

    // MARK: - Text change tracking

    @objc private func textDidChange(_ notification: Notification) {
        let wasDirty = documentController.isDirty
        documentController.markEdited()
        if !wasDirty {
            // First edit since the last save: refresh the window state so the
            // toolbar title gains its unsaved marker (not only the close
            // button's dot).
            updateWindowState()
        }
        scheduleLanguageRanking()
        refreshStatusBar()
        scheduleDraftFlush()
        // An edit that leaves the caret in place (forward delete of the
        // closer) need not post a selection change; recompute the pair here
        // unless `selectionDidChange` already did since the edit.
        bracketHighlighter.refreshIfNeeded()
    }

    @objc private func selectionDidChange(_ notification: Notification) {
        refreshStatusBar()
        bracketHighlighter.update()
        wordHighlighter.selectionChanged()
    }

    // MARK: - Jump to matching bracket (first-responder target)

    /// Moves the caret to the other end of the bracket pair anchored at the
    /// current caret (⌘⇧\). When the caret sits at the opener, it jumps just past
    /// the closer; from the closer it jumps to just before the opener — so
    /// repeated invocations toggle between the two ends. Beeps when the caret is
    /// not adjacent to a balanced bracket.
    @objc public func jumpToMatchingBracket(_ sender: Any?) {
        let caret = textView.selectedRange().location
        guard let match = BracketMatcher.findMatch(text: textView.string, caret: caret) else {
            NSSound.beep()
            return
        }
        let atOpenSide = caret == match.open.location
            || caret == match.open.location + match.open.length
        let target = atOpenSide
            ? match.close.location + match.close.length
            : match.open.location
        let destination = NSRange(location: target, length: 0)
        textView.setSelectedRange(destination)
        textView.scrollRangeToVisible(destination)
    }

    /// Recomputes the status strip's caret position, language, and char count
    /// (or, while there is an active selection, the selection's character
    /// count and line span).
    private func refreshStatusBar() {
        let selection = textView.selectedRange()
        let caret = selection.location
        let line = lineIndex.lineNumber(forOffset: caret)
        let lineStart = lineIndex.offsetRange(ofLine: line).lowerBound
        statusBar.updateCaret(line: line,
                              column: StatusBarMetrics.column(caretOffset: caret,
                                                              lineStartOffset: lineStart))
        statusBar.updateLanguage(currentLanguageIdentifierValue)
        statusBar.updateLineEnding(currentLineEnding)

        // Keep the full-document count current (also what `clearSelection()`
        // restores) before deciding which caption the right-hand field shows.
        statusBar.updateCharacterCount((textView.string as NSString).length)

        if selection.length > 0 {
            let startLine = lineIndex.lineNumber(forOffset: selection.location)
            let endLine = lineIndex.lineNumber(forOffset: selection.location + selection.length)
            statusBar.updateSelection(length: selection.length, lines: endLine - startLine + 1)
        } else {
            statusBar.clearSelection()
        }
    }

    // MARK: - Automatic language detection and suggestions

    /// Whether the buffer is still waiting for automatic detection: Auto mode,
    /// no language found yet, and no language (nor an unregistered extension's
    /// name) on the text view.
    private var awaitsLanguageRanking: Bool {
        guard !userOverrodeLanguage, !didAutoDetectLanguage,
              let editorView = textView as? EditorTextView else { return false }
        return editorView.languageIdentifier.isEmpty
    }

    /// Called on every edit: a paste or a single edit inserting
    /// `immediateRankingInsertion`+ characters ranks at once; ordinary typing
    /// ranks once the user pauses for `languageRankingDebounce`.
    private func scheduleLanguageRanking() {
        let inserted = pendingInsertionLength
        pendingInsertionLength = 0
        guard awaitsLanguageRanking else {
            cancelLanguageRanking()
            return
        }
        let pasted = (textView as? EditorTextView)?.isPasting ?? false
        if pasted || inserted >= Self.immediateRankingInsertion {
            rankLanguageNow()
            return
        }
        languageRankingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.languageRankingWork = nil
                self?.rankLanguageNow()
            }
        }
        languageRankingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + languageRankingDebounce, execute: work)
    }

    private func cancelLanguageRanking() {
        languageRankingWork?.cancel()
        languageRankingWork = nil
    }

    /// Ranks the buffer for a language once it has accumulated enough content,
    /// so an untitled / pasted document highlights itself without the user
    /// picking a language, or — when detection is unsure — offers candidates.
    /// Runs only while no language is set and the user has not chosen one
    /// manually; stops after a confident classification.
    private func rankLanguageNow() {
        cancelLanguageRanking()
        guard awaitsLanguageRanking else { return }

        let text = textView.string
        let charCount = (text as NSString).length
        let newlineCount = text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        // Wait for ≥120 characters or ≥3 lines before guessing. Below that the
        // buffer is too short to judge, so earlier suggestions are withdrawn.
        guard charCount >= 120 || newlineCount >= 2 else {
            presentLanguageRanking(.none)
            return
        }

        let ranking = languageRanker(text)
        if let identifier = ranking.confident {
            applyLanguage(identifier: identifier)
            didAutoDetectLanguage = true
        }
        presentLanguageRanking(ranking)
    }

    /// Detects a file's language. A file with an extension is decided by that
    /// extension alone: a registered one gives its language, any other leaves
    /// the file Plain Text with no content detection and no suggestions (the
    /// user named the file; guessing over that is not wanted). Only a file
    /// without an extension is ranked by content (no minimum-content gate: the
    /// file is complete): a confident ranking is applied, candidates are offered.
    private func detectFileLanguage(url: URL, text: String) {
        let ext = url.pathExtension
        var identifier = LanguageRegistry.identifier(forExtension: ext)
        var ranking = LanguageRanking.none
        if identifier == nil, ext.isEmpty {
            ranking = languageRanker(text)
            if let confident = ranking.confident {
                identifier = LanguageRegistry.canonicalIdentifier(confident)
                didAutoDetectLanguage = true
            }
        }
        // One `setDocumentLanguage` call points the analysis (and through it
        // the highlighter and completion) at the language, records it on the
        // text view and re-infers the indent unit from the content.
        setDocumentLanguage(identifier, editorIdentifier: identifier ?? ext.lowercased())
        presentLanguageRanking(ranking)
    }

    /// Records `ranking` and brings the band and the toolbar menu in line:
    /// candidates without a confident answer show the band (unless dismissed
    /// for this document); anything else hides it.
    private func presentLanguageRanking(_ ranking: LanguageRanking) {
        latestLanguageRanking = ranking
        let entries = LanguageMenuSettings.suggestionEntries(languageMenuSuggestions)
        if !languageSuggestionDismissed, !entries.isEmpty {
            languageSuggestionBanner.show(candidates: entries)
        } else {
            languageSuggestionBanner.hide()
        }
        toolbarController?.refreshLanguageSelection()
    }

    /// The suggested language identifiers the language menus list in their own
    /// section: the latest ranking's candidates while Auto is on, no language
    /// is applied and detection had no confident answer. Kept after the band
    /// is dismissed.
    var languageMenuSuggestions: [String] {
        guard isLanguageAuto, documentAnalysis.languageIdentifier.isEmpty,
              let ranking = latestLanguageRanking, ranking.confident == nil else { return [] }
        return ranking.candidates.map(\.identifier)
    }

    /// Forgets the previous document's ranking, pending ranking and dismissal.
    private func resetLanguageSuggestions() {
        cancelLanguageRanking()
        pendingInsertionLength = 0
        latestLanguageRanking = nil
        languageSuggestionDismissed = false
        languageSuggestionBanner.hide()
    }

    /// A candidate (or an "Other…" language) picked in the band: the manual
    /// choice path, then keyboard focus back in the text.
    private func chooseSuggestedLanguage(identifier: String) {
        chooseLanguage(identifier: identifier)
        window?.makeFirstResponder(textView)
    }

    /// The band's close button: hide it for the rest of this document.
    private func dismissLanguageSuggestions() {
        languageSuggestionDismissed = true
        languageSuggestionBanner.hide()
        window?.makeFirstResponder(textView)
    }

    /// Whether a debounced ranking is waiting for the typing pause (tests).
    var hasPendingLanguageRanking: Bool { languageRankingWork != nil }

    /// The toolbar language popup's menu (tests).
    var toolbarLanguageMenu: NSMenu? { toolbarController?.languagePopupMenu }

    /// Language change from the menu / toolbar / sniffer / run sniffing.
    private func applyLanguage(identifier: String) {
        setDocumentLanguage(identifier)
    }

    /// The single choke point for every language change (load, revert / Auto,
    /// menu, toolbar, sniffer, recovered drafts via the sniffer). Points the
    /// document analysis at `identifier` — which re-points the highlighter and
    /// completion synchronously and invalidates every analysis — then records
    /// `editorIdentifier` (default: `identifier`, or `""` for plain) on the
    /// text view for indent width / formatting / folding, re-infers the indent
    /// unit and refreshes the toolbar popup and status bar.
    private func setDocumentLanguage(_ identifier: String?, editorIdentifier: String? = nil) {
        documentAnalysis.setLanguage(identifier: identifier)
        updateWordHighlighterIdentifierRules()
        let shown = editorIdentifier ?? identifier ?? ""
        setEditorLanguage(identifier: shown)
        // A language decided by any route (menu, toolbar, Save As, run-time
        // sniffing, detection) needs no suggestions.
        if !documentAnalysis.languageIdentifier.isEmpty {
            cancelLanguageRanking()
            languageSuggestionBanner.hide()
        }
        redetectIndentUnit()
        toolbarController?.refreshAll()
        statusBar.updateLanguage(shown)
    }

    /// Tells the same-word highlighter whether `$` is an identifier character:
    /// exactly when the document language's `IdentifierPolicy` says so (JS /
    /// TS). Reads the policy from a definition built only when the resolved
    /// language actually changed (language changes are rare: load, menu,
    /// sniffer), and none for plain text.
    private func updateWordHighlighterIdentifierRules() {
        let language = documentAnalysis.languageIdentifier
        guard language != wordHighlighterLanguage else { return }
        wordHighlighterLanguage = language
        wordHighlighter.dollarIsWordCharacter = language.isEmpty ? false
            : LanguageRegistry.definition(forIdentifier: language)?.identifierPolicy.dollarIdentifiers ?? false
    }

    /// Records the language on the text view (it drives indent width, formatting
    /// and comment tokens) and tells folding to rescan, since the fold rules
    /// themselves are language-dependent (T13.4). The single writer for
    /// `languageIdentifier`, so no entry path can update one and forget the other.
    private func setEditorLanguage(identifier: String) {
        (textView as? EditorTextView)?.languageIdentifier = identifier
        foldingController?.noteLanguageChanged()
    }

    /// Re-runs `IndentDetector` over the whole buffer and stores the result on
    /// the text view (driving the indent rainbow and Tab width). Called on open
    /// and on every language change — deliberately *not* on each keystroke, so a
    /// half-typed line can't make the rainbow flicker; the file's established
    /// indentation is a document-level property that a single edit shouldn't
    /// redefine.
    private func redetectIndentUnit() {
        guard let editorView = textView as? EditorTextView else { return }
        editorView.detectedIndentUnit = IndentDetector.detect(text: textView.string)?.unit
    }

    /// The window/UI display name. `DocumentController` stays pure Foundation and
    /// yields a neutral "Untitled"; the localized untitled label is substituted
    /// here at the UI layer so the model needs no L10n dependency.
    private var displayName: String {
        documentController.fileURL == nil ? L10n.t(.untitled) : documentController.displayName
    }

    private func updateWindowState() {
        let hasFile = documentController.fileURL != nil
        window?.title = displayName
        window?.representedURL = documentController.fileURL
        window?.isDocumentEdited = documentController.isDirty
        // The toolbar's centre title shows the name for saved and untitled
        // documents alike; `window.title` stays set for the Window menu and
        // Mission Control but is not drawn in the titlebar.
        window?.titleVisibility = .hidden
        toolbarController?.updateTitle(fileName: displayName,
                                       hasFile: hasFile,
                                       isDirty: documentController.isDirty)
        // Buffer and file agree again (saved by any route, or reloaded): the
        // failed auto-save no longer needs attention.
        if !documentController.isDirty { saveFailureBanner.hide() }
    }

    // MARK: - Rename (titlebar capsule → DocumentController)

    /// Renames the current file in place from the titlebar capsule (T11.4).
    /// Delegates the filesystem work and validation to `DocumentController`,
    /// then re-syncs the window chrome (title / proxy icon / capsule). Validation
    /// failures are surfaced as a localized alert.
    func renameFile(to newName: String) {
        do {
            let previousURL = documentController.fileURL
            let previousExtension = previousURL?.pathExtension.lowercased()
            let newURL = try documentController.rename(to: newName)
            window?.representedURL = newURL
            redetectLanguageIfExtensionChanged(from: previousExtension)
            updateWindowState()
            migrateSessionEntry(from: previousURL)
        } catch let error as DocumentController.RenameError {
            presentRenameError(error)
        } catch {
            presentRenameError(.moveFailed(error.localizedDescription))
        }
    }

    private func presentRenameError(_ error: DocumentController.RenameError) {
        let message: String
        switch error {
        case .emptyName:    message = L10n.t(.renameErrorEmpty)
        case .invalidName:  message = L10n.t(.renameErrorInvalid)
        case .targetExists: message = L10n.t(.renameErrorExists)
        case .noFileURL, .moveFailed: message = L10n.t(.renameErrorGeneric)
        }
        let alert = NSAlert()
        alert.messageText = L10n.t(.renameErrorTitle)
        alert.informativeText = message
        alert.alertStyle = .warning
        if let window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    // MARK: - Find actions (first-responder targets)

    @objc public func showFindBar(_ sender: Any?) {
        findBar.show()
    }

    /// Find and Replace… (⌥⌘F): the find bar with its replace row expanded.
    @objc public func showFindAndReplace(_ sender: Any?) {
        findBar.showReplace()
    }

    @objc public func findNext(_ sender: Any?) {
        if !findBar.isShown { findBar.show() }
        findBar.findNext()
    }

    @objc public func findPrevious(_ sender: Any?) {
        if !findBar.isShown { findBar.show() }
        findBar.findPrevious()
    }

    @objc public func useSelectionForFind(_ sender: Any?) {
        findBar.useSelectionForFind()
    }

    // MARK: - Code folding (first-responder targets, T12.12)

    /// Folds the innermost foldable block containing the caret (⌘⌥[).
    @objc public func foldCurrentBlock(_ sender: Any?) {
        foldingController.foldCurrent(atLine: caretLine)
    }

    /// Unfolds the innermost folded block containing the caret (⌘⌥]).
    @objc public func unfoldCurrentBlock(_ sender: Any?) {
        foldingController.unfoldCurrent(atLine: caretLine)
    }

    /// Folds every foldable region in the document (⌘K ⌘0).
    @objc public func foldAll(_ sender: Any?) {
        foldingController.foldAll()
    }

    /// Unfolds every folded region in the document (⌘K ⌘J).
    @objc public func unfoldAllFolds(_ sender: Any?) {
        foldingController.unfoldAll()
    }

    /// 1-based line number of the caret, from the shared line index.
    private var caretLine: Int {
        lineIndex.lineNumber(forOffset: textView.selectedRange().location)
    }

    // MARK: - Jump to Symbol (first-responder target)

    /// Opens the transient symbol navigator (Cmd+Shift+O). Scans the current
    /// document once for the active language's declarations and lets the user
    /// filter / jump. The navigator is released when its panel closes, so no
    /// symbol index survives the operation (ARCHITECTURE.md §3.4).
    @objc public func jumpToSymbol(_ sender: Any?) {
        // Already open: a second invocation is a no-op (avoid stacking panels).
        guard symbolNavigator == nil else { return }
        let navigator = SymbolNavigator(textView: textView)
        symbolNavigator = navigator
        // The current declaration snapshot when highlight / completion hold
        // one (no rescan); otherwise a transient scan, as before T17.1.
        let locations = documentAnalysis.ensureDeclarations().scan.locations
        navigator.present(locations: locations) { [weak self] in
            self?.symbolNavigator = nil
        }
    }

    // MARK: - Workspace Symbols (first-responder target, T17.14)

    /// Opens the workspace-symbol navigator (⌘T). Outside a project folder or
    /// with the index off the menu item is disabled; reached anyway (a
    /// rebound key), the status bar says why.
    @objc public func showWorkspaceSymbols(_ sender: Any?) {
        guard workspaceSymbolNavigator == nil else { return }
        let path = documentController.fileURL?.path
        let availability = WorkspaceSymbolNavigator.availability(index: workspaceIndex, documentPath: path)
        switch availability {
        case .notInProjectFolder, .indexOff:
            statusBar.flashMessage(L10n.t(availability == .indexOff ? .workspaceSymbolIndexOff : .workspaceSymbolNotInFolder))
            NSSound.beep()
            return
        case .available, .indexing:
            break
        }
        let navigator = WorkspaceSymbolNavigator(textView: textView, index: workspaceIndex, documentPath: path) {
            [weak self] symbol in
            self?.openWorkspaceSymbol(symbol)
        }
        workspaceSymbolNavigator = navigator
        navigator.present { [weak self] in self?.workspaceSymbolNavigator = nil }
    }

    /// The navigator and the editor text view (tests).
    var workspaceSymbolNavigatorForTesting: WorkspaceSymbolNavigator? { workspaceSymbolNavigator }
    var textViewForTesting: NSTextView { textView }
    var findBarForTesting: FindBarController { findBar }

    /// Opens `symbol`'s file (this window when it is this document) and
    /// selects its name.
    func openWorkspaceSymbol(_ symbol: WorkspaceSymbol) {
        if let current = documentController.fileURL,
           ProjectFolderStore.standardize(current.path) == ProjectFolderStore.standardize(symbol.path) {
            reveal(symbol)
            return
        }
        guard let opener = Self.fileOpener, let controller = opener(URL(fileURLWithPath: symbol.path)) else {
            NSSound.beep()
            return
        }
        controller.reveal(symbol)
    }

    /// Selects `symbol`'s name: its line from the index, the occurrence of
    /// the name on it nearest the indexed column (the index counts the file
    /// as read from disk, the editor may differ in line endings).
    func reveal(_ symbol: WorkspaceSymbol) {
        let text = textView.string as NSString
        let line = min(max(symbol.line, 1), max(1, lineIndex.lineCount))
        let lineRange = lineIndex.offsetRange(ofLine: line)
        var target = NSRange(location: min(lineRange.lowerBound, text.length), length: 0)
        if lineRange.upperBound <= text.length, lineRange.upperBound > lineRange.lowerBound {
            let searchRange = NSRange(location: lineRange.lowerBound, length: lineRange.upperBound - lineRange.lowerBound)
            var best: NSRange?
            var from = searchRange
            while true {
                let found = text.range(of: symbol.name, options: [.literal], range: from)
                guard found.location != NSNotFound else { break }
                if best == nil || abs(found.location - symbol.location) < abs(best!.location - symbol.location) { best = found }
                let next = NSMaxRange(found)
                guard next < NSMaxRange(searchRange) else { break }
                from = NSRange(location: next, length: NSMaxRange(searchRange) - next)
            }
            if let best { target = best }
        }
        textView.setSelectedRange(target)
        textView.scrollRangeToVisible(target)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(textView)
    }

    // MARK: - Go to Line (first-responder target)

    /// Opens the transient "Go to Line" panel (Ctrl+G). Reuses the window's
    /// shared `LineIndex` to jump; the controller is released when its panel
    /// closes, so nothing survives the operation (ARCHITECTURE.md §3.4).
    @objc public func goToLine(_ sender: Any?) {
        guard goToLineController == nil else { return }
        let controller = GoToLineController(textView: textView, lineIndex: lineIndex)
        goToLineController = controller
        controller.present { [weak self] in
            self?.goToLineController = nil
        }
    }

    // MARK: - Command Palette (first-responder target)

    /// Opens the transient command palette (⌘⇧P). Enumerates the live menu tree
    /// once, then lets the user fuzzy-filter and run any command. The palette is
    /// released when its panel closes, so no command index survives the operation
    /// (ARCHITECTURE.md §3.4).
    @objc public func showCommandPalette(_ sender: Any?) {
        guard commandPalette == nil else { return }
        let palette = CommandPalette(textView: textView)
        commandPalette = palette
        palette.present { [weak self] in
            self?.commandPalette = nil
        }
    }

    // MARK: - Format action (first-responder target)

    /// Pretty-prints the whole document using the built-in formatter for its
    /// language. Gated on the `format` module and on the language being one the
    /// dispatcher supports (JSON / JSONL / XML / plist); `validateMenuItem`
    /// greys the item out otherwise, so this is a belt-and-suspenders beep.
    @objc public func formatDocument(_ sender: Any?) {
        guard ModuleSettings().isEnabled(.format) else { NSSound.beep(); return }
        let language = (textView as? EditorTextView)?.languageIdentifier ?? ""
        guard FormatDispatch.supports(languageIdentifier: language) else { NSSound.beep(); return }

        let width = IndentSettings().width(for: language)
        switch FormatDispatch.format(text: textView.string,
                                     languageIdentifier: language,
                                     indentWidth: width) {
        case .success(let formatted):
            guard formatted != textView.string else { return }
            // Whole-document replacement as a single undo step (mirrors the
            // find bar's Replace All path).
            let full = NSRange(location: 0, length: (textView.string as NSString).length)
            if textView.shouldChangeText(in: full, replacementString: formatted) {
                textView.textStorage?.replaceCharacters(in: full, with: formatted)
                textView.didChangeText()
            }
        case .failure(let error):
            handleFormatError(error)
        }
    }

    private func handleFormatError(_ error: FormatDispatchError) {
        switch error {
        case .unsupportedLanguage:
            NSSound.beep()
        case .syntax(let line, let message):
            // Move the caret to the offending line using the window's shared
            // line index, then scroll it into view.
            let range = lineIndex.offsetRange(ofLine: line)
            let caret = NSRange(location: range.lowerBound, length: 0)
            textView.setSelectedRange(caret)
            textView.scrollRangeToVisible(caret)

            let alert = NSAlert()
            alert.messageText = L10n.t(.formatFailedTitle)
            alert.informativeText = L10n.t(.formatErrorLine, line, message)
            alert.alertStyle = .warning
            if let window {
                alert.beginSheetModal(for: window, completionHandler: nil)
            } else {
                alert.runModal()
            }
        }
    }

    // MARK: - Comment toggle (first-responder target)

    /// Toggles line/block comments over the selected lines (⌘/, VS Code
    /// semantics). Beeps for languages with no comment syntax (JSON / plain).
    @objc public func toggleComment(_ sender: Any?) {
        let language = (textView as? EditorTextView)?.languageIdentifier ?? ""
        guard let result = CommentToggle.toggle(text: textView.string,
                                                selection: textView.selectedRange(),
                                                languageIdentifier: language) else {
            NSSound.beep()
            return
        }
        applyTextEdit(replacement: result.replacement,
                      range: result.range,
                      newSelection: result.newSelection)
    }

    // MARK: - Line operations (first-responder targets)

    @objc public func moveLinesUp(_ sender: Any?) {
        applyLineOperation(LineOperations.moveLinesUp)
    }

    @objc public func moveLinesDown(_ sender: Any?) {
        applyLineOperation(LineOperations.moveLinesDown)
    }

    @objc public func copyLinesUp(_ sender: Any?) {
        applyLineOperation(LineOperations.copyLinesUp)
    }

    @objc public func copyLinesDown(_ sender: Any?) {
        applyLineOperation(LineOperations.copyLinesDown)
    }

    @objc public func deleteLines(_ sender: Any?) {
        applyLineOperation(LineOperations.deleteLines)
    }

    /// ⌘⏎ — open a fresh empty line below the caret's line (keyDown chord in
    /// EditorTextView; no menu item, mirroring VS Code).
    @objc public func insertLineBelow(_ sender: Any?) {
        applyLineOperation(LineOperations.insertLineBelow)
    }

    /// Runs a pure line operation over the current text/selection and applies the
    /// result through the undo channel. A `nil` result (document boundary) is a
    /// silent no-op, matching VS Code.
    private func applyLineOperation(
        _ operation: (_ text: String, _ selection: NSRange)
            -> (replacement: String, range: NSRange, newSelection: NSRange)?
    ) {
        guard let result = operation(textView.string, textView.selectedRange()) else { return }
        applyTextEdit(replacement: result.replacement,
                      range: result.range,
                      newSelection: result.newSelection)
    }

    /// Applies a single replacement through the text view's undo-aware channel
    /// (`shouldChangeText` → `replaceCharacters` → `didChangeText`), then installs
    /// the new selection. Mirrors the `formatDocument` mutation path.
    private func applyTextEdit(replacement: String, range: NSRange, newSelection: NSRange) {
        guard textView.shouldChangeText(in: range, replacementString: replacement) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: replacement)
        textView.didChangeText()
        textView.setSelectedRange(newSelection)
    }

    // MARK: - Reopen with Encoding (first-responder target)

    /// Re-reads the file from disk and force-decodes it with the user-chosen
    /// encoding (File ▸ Reopen with Encoding), the fallback when auto-detection
    /// guessed wrong. Confirms first if there are unsaved changes (reopening
    /// discards them); reports a decode failure with an alert. Saving is
    /// unaffected — the document is still written back as UTF-8.
    @objc public func reopenWithEncoding(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let raw = item.representedObject as? String,
              let encoding = TextEncoding(rawValue: raw),
              let url = documentController.fileURL else { NSSound.beep(); return }

        // Warn before discarding unsaved edits (only when the text actually
        // diverges from the saved contents).
        if documentController.isDirty,
           !documentController.matchesBaseline(textView.string),
           !confirmReopenDiscardingChanges() { return }

        do {
            let text = try documentController.reload(from: url, encoding: encoding)
            layoutModeController?.setLength((text as NSString).length)
            textView.string = text
            currentLineEnding = LineEnding.detect(in: text)

            // Re-index / re-detect exactly as a fresh load would; the reopen
            // clears the dirty flag (the on-disk bytes are now authoritative).
            completionController.indexDocument()
            redetectIndentUnit()
            updateWindowState()
            toolbarController?.refreshAll()
            refreshStatusBar()
            // The on-disk bytes are authoritative again — no draft to keep.
            removeDraft()
        } catch {
            let alert = NSAlert()
            alert.messageText = L10n.t(.encodingDecodeFailedTitle)
            alert.informativeText = L10n.t(.encodingDecodeFailedMessage)
            alert.alertStyle = .warning
            if let window {
                alert.beginSheetModal(for: window, completionHandler: nil)
            } else {
                alert.runModal()
            }
        }
    }

    /// Modal confirmation shown before a reopen throws away unsaved edits.
    /// Returns `true` if the user chose to proceed.
    private func confirmReopenDiscardingChanges() -> Bool {
        let alert = NSAlert()
        alert.messageText = L10n.t(.reopenConfirmMessage, displayName)
        alert.informativeText = L10n.t(.reopenConfirmInfo)
        alert.addButton(withTitle: L10n.t(.reopenDiscardButton))
        alert.addButton(withTitle: L10n.t(.cancel))
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Convert Line Endings (first-responder target)

    /// Rewrites every line ending in the document to the chosen style
    /// (Format ▸ Convert Line Endings). The replacement flows through the text
    /// view's `shouldChangeText` / `didChangeText` channel so it lands as one
    /// undoable step; the status bar and dirty flag then reflect the new style.
    @objc public func convertLineEndings(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let raw = item.representedObject as? String,
              let target = LineEnding(rawValue: raw) else { NSSound.beep(); return }

        let converted = LineEnding.convert(textView.string, to: target)
        guard converted != textView.string else {
            // Nothing changed (already this style) — just refresh the caption.
            currentLineEnding = target
            refreshStatusBar()
            return
        }
        let full = NSRange(location: 0, length: (textView.string as NSString).length)
        if textView.shouldChangeText(in: full, replacementString: converted) {
            textView.textStorage?.replaceCharacters(in: full, with: converted)
            textView.didChangeText()
            currentLineEnding = target
        }
        refreshStatusBar()
    }

    // MARK: - Language selection (first-responder targets)

    /// Manual language override from the Language menu. The item's
    /// `representedObject` is the language identifier (empty ⇒ Plain Text).
    @objc public func selectLanguage(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let identifier = item.representedObject as? String else { return }
        chooseLanguage(identifier: identifier)
    }

    /// Clears any manual override and re-runs automatic detection immediately:
    /// by file extension when the document has a URL, otherwise by content.
    @objc public func selectAutoLanguage(_ sender: Any?) {
        chooseAutoLanguage()
    }

    // MARK: - Language selection (shared by menu + toolbar)

    /// True while automatic detection is in charge (no manual override).
    var isLanguageAuto: Bool { !userOverrodeLanguage }

    /// The language identifier currently applied to the document (`""` = Plain).
    var currentLanguageIdentifierValue: String {
        (textView as? EditorTextView)?.languageIdentifier ?? ""
    }

    /// Manual override to a specific language (from the Language menu or the
    /// toolbar popup). Suppresses automatic detection until Auto is chosen again.
    func chooseLanguage(identifier: String) {
        userOverrodeLanguage = true
        didAutoDetectLanguage = true
        // A manual choice (Plain Text included) ends the suggestions.
        cancelLanguageRanking()
        languageSuggestionBanner.hide()
        applyLanguage(identifier: identifier)
    }

    /// Menu-bar Language menu: one of the suggested languages listed above the
    /// full list (a separate action so a shortcut bound to that language does
    /// not show on both items).
    @objc public func selectSuggestedLanguage(_ sender: Any?) {
        selectLanguage(sender)
    }

    /// Clears any manual override and re-detects: by extension for a saved file,
    /// otherwise by sniffing the buffer's content. Picking Auto also lets a
    /// dismissed suggestion band come back.
    func chooseAutoLanguage() {
        languageSuggestionDismissed = false
        redetectLanguageAutomatically()
    }

    /// `chooseAutoLanguage` without clearing the band's dismissal: also used
    /// when Save As / rename changes the extension.
    private func redetectLanguageAutomatically() {
        userOverrodeLanguage = false
        didAutoDetectLanguage = false

        if let url = documentController.fileURL {
            detectFileLanguage(url: url, text: textView.string)
        } else {
            // Untitled: reset to plain, then let the sniffer re-classify if the
            // buffer already holds enough content.
            setDocumentLanguage(nil, editorIdentifier: "")
            rankLanguageNow()
        }
    }

    // MARK: - Menu validation

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if let verdict = validateRunMenuItem(menuItem) { return verdict }
        if menuItem.action == #selector(showWorkspaceSymbols(_:)) {
            switch WorkspaceSymbolNavigator.availability(index: workspaceIndex,
                                                          documentPath: documentController.fileURL?.path) {
            case .available, .indexing: return true
            case .notInProjectFolder, .indexOff: return false
            }
        }
        if menuItem.action == #selector(reopenWithEncoding(_:)) {
            // Reopening reads from disk, so an untitled (never-saved) document
            // has nothing to reopen — grey the whole submenu out.
            return documentController.fileURL != nil
        }
        if menuItem.action == #selector(convertLineEndings(_:)) {
            let raw = (menuItem.representedObject as? String) ?? ""
            menuItem.state = (raw == currentLineEnding.rawValue) ? .on : .off
            return true
        }
        if menuItem.action == #selector(formatDocument(_:)) {
            guard ModuleSettings().isEnabled(.format) else { return false }
            let language = (textView as? EditorTextView)?.languageIdentifier ?? ""
            return FormatDispatch.supports(languageIdentifier: language)
        }
        if menuItem.action == #selector(selectAutoLanguage(_:)) {
            menuItem.state = userOverrodeLanguage ? .off : .on
            return true
        }
        if menuItem.action == #selector(selectLanguage(_:)) {
            let identifier = (menuItem.representedObject as? String) ?? ""
            let current = (textView as? EditorTextView)?.languageIdentifier ?? ""
            menuItem.state = (userOverrodeLanguage && identifier == current) ? .on : .off
            return true
        }
        return true
    }

    // MARK: - Focus loss (T12.14 auto-save + T14.8 session position)

    /// Single handler for this window losing key focus. Focus loss is a natural,
    /// low-frequency checkpoint, so the session position rides along with the
    /// auto-save on the same notification (no extra observer). Deliberately
    /// *not* named `windowDidResignKey` — that is an `NSWindowDelegate`
    /// requirement, and AppKit would then call it a second time.
    @objc private func handleResignKey(_ note: Notification) {
        // A closing window also resigns key — after `windowWillClose` has done
        // its bookkeeping. Recording here would undo the close's session-entry
        // removal, and auto-saving here would betray a "Don't Save" (T15.10).
        guard !isClosing else { return }
        recordSessionState()
        autoSaveOnFocusLoss()
    }

    /// This window became key. Deliberately *not* named `windowDidBecomeKey`
    /// (an `NSWindowDelegate` requirement AppKit would call a second time).
    @objc private func handleBecomeKey(_ note: Notification) {
        checkForExternalChange()
    }

    /// Looks once at whether the file changed on disk (D2). A clean buffer
    /// takes the new contents; a buffer with unsaved changes is left alone and
    /// the change is reported once per external state. The common case costs
    /// a single `stat` (`DocumentController.externalChange`); no watcher, no
    /// timer. Internal so tests can drive it without real focus changes.
    func checkForExternalChange() {
        guard !isClosing, modalDepth == 0,
              let url = documentController.fileURL else { return }
        let isClean = !documentController.isDirty
            || documentController.matchesBaseline(textView.string)
        // Already reported and the file has not moved since: stay quiet.
        if !isClean, let announced = announcedExternalStamp,
           DiskState.Stamp.of(url) == announced { return }
        switch documentController.externalChange() {
        case .none, .removed:
            announcedExternalStamp = nil
        case .modified:
            if isClean {
                reloadFromDisk(url)
            } else {
                noteExternalChangeAnnounced()
                flashStatus(L10n.t(.externalChangeKeptEdits))
            }
        }
    }

    /// Records the file's current stamp as already reported to the user.
    private func noteExternalChangeAnnounced() {
        announcedExternalStamp = documentController.fileURL.flatMap { DiskState.Stamp.of($0) }
    }

    /// Replaces a clean buffer with the file's new contents, as `load(url:)` /
    /// `reopenWithEncoding` do, but keeping the language (a manual choice
    /// included), the caret and the scroll position (clamped). The undo stack
    /// is cleared: its steps describe the old text.
    private func reloadFromDisk(_ url: URL) {
        let caret = textView.selectedRange().location
        let scrollOrigin = textView.enclosingScrollView?.contentView.bounds.origin
        let text: String
        do {
            text = try documentController.load(from: url)
        } catch {
            flashStatus(L10n.t(.externalChangeReloadFailed))
            return
        }
        announcedExternalStamp = nil
        let length = (text as NSString).length
        layoutModeController?.setLength(length)
        textView.string = text
        currentLineEnding = LineEnding.detect(in: text)
        textView.undoManager?.removeAllActions()

        completionController.indexDocument()
        redetectIndentUnit()
        updateWindowState()
        toolbarController?.refreshAll()
        refreshStatusBar()

        let selection = NSRange(location: min(max(0, caret), length), length: 0)
        textView.setSelectedRange(selection)
        if let scrollOrigin, let scrollView = textView.enclosingScrollView {
            let clipView = scrollView.contentView
            clipView.scroll(to: clipView.constrainBoundsRect(
                NSRect(origin: scrollOrigin, size: clipView.bounds.size)).origin)
            scrollView.reflectScrolledClipView(clipView)
        }
        // The on-disk bytes are authoritative again — no draft to keep.
        removeDraft()
        flashStatus(L10n.t(.externalChangeReloaded))
    }

    /// Silently writes the document to its existing file when the window loses
    /// key focus, if the feature is enabled. Deliberately non-modal:
    ///
    /// - Untitled documents (no file URL) are skipped by `AutoSavePolicy` — we
    ///   never pop a storage panel on focus loss.
    /// - On write failure we do **not** show an `NSAlert` (a modal sheet the
    ///   instant focus leaves is exactly the disruption to avoid). The document
    ///   stays dirty and a banner above the editor says so until the document
    ///   is saved; it replaces a three-second status-bar note the user, already
    ///   in another app, rarely saw.
    /// - If another program changed the file, nothing is written (D1): the
    ///   band switches to its conflict mode and the next manual save asks.
    func autoSaveOnFocusLoss(enabled: Bool = AutoSavePolicy.defaultEnabled) {
        guard AutoSavePolicy.shouldSave(enabled: enabled,
                                        isDirty: documentController.isDirty,
                                        hasFileURL: documentController.fileURL != nil) else { return }
        do {
            try documentController.save(text: textView.string)
            updateWindowState()
            refreshStatusBar()
            // Buffer and disk agree again, so the crash draft has nothing left
            // to protect (T14.11).
            removeDraft()
        } catch DocumentController.DocumentError.changedOnDisk {
            // Never overwrite on focus loss. The band reports the change, so
            // the become-key check need not report it again.
            noteExternalChangeAnnounced()
            saveFailureBanner.show(reason: nil, mode: .conflict)
        } catch {
            // Keep the dirty state; no modal. Failing again while the banner
            // is up changes nothing visible.
            saveFailureBanner.show(reason: error.localizedDescription)
        }
    }

    // MARK: - Save actions (first-responder targets)

    @objc public func saveDocument(_ sender: Any?) {
        _ = performSave()
    }

    @objc public func saveDocumentAs(_ sender: Any?) {
        _ = runSaveAsPanel()
    }

    /// Saves to the existing URL, or prompts for one if untitled.
    /// Returns `true` on success, `false` if cancelled or failed. If another
    /// program changed the file, asks first (Save As… / Overwrite / Cancel).
    @discardableResult
    private func performSave() -> Bool {
        guard documentController.fileURL != nil else { return runSaveAsPanel() }
        do {
            try documentController.save(text: textView.string)
            updateWindowState()
            removeDraft()
            return true
        } catch DocumentController.DocumentError.changedOnDisk {
            return resolveSaveConflict()
        } catch {
            showSaveError(error)
            return false
        }
    }

    /// The manual-save branch for a file changed on disk (D1). Cancel leaves
    /// buffer, dirty flag, draft and disk exactly as they were.
    private func resolveSaveConflict() -> Bool {
        // The question itself tells the user; no status note for this state.
        noteExternalChangeAnnounced()
        switch saveConflictChoice() {
        case .overwrite:
            do {
                try documentController.save(text: textView.string, overwritingExternalChanges: true)
            } catch {
                showSaveError(error)
                return false
            }
            updateWindowState()
            removeDraft()
            return true
        case .saveAs:
            return runSaveAsPanel()
        case .cancel:
            return false
        }
    }

    /// Asks how to save over an external change, in the close-confirmation
    /// alert's style: Save As… (default), Overwrite (destructive), Cancel (Esc).
    private func saveConflictChoice() -> SaveConflictChoice {
        if let saveConflictChoiceOverride { return saveConflictChoiceOverride() }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.t(.saveConflictMessage, displayName)
        alert.informativeText = L10n.t(.saveConflictInfo)
        alert.addButton(withTitle: L10n.t(.menuSaveAs))
        let overwrite = alert.addButton(withTitle: L10n.t(.saveConflictOverwrite))
        overwrite.hasDestructiveAction = true
        // Esc cancels whatever the localized title is.
        alert.addButton(withTitle: L10n.t(.cancel)).keyEquivalent = "\u{1b}"
        switch runModalGuarded({ alert.runModal() }) {
        case .alertFirstButtonReturn: return .saveAs
        case .alertSecondButtonReturn: return .overwrite
        default: return .cancel
        }
    }

    /// Runs one of this window's modal sessions with the become-key check
    /// suspended.
    private func runModalGuarded<T>(_ body: () -> T) -> T {
        modalDepth += 1
        defer { modalDepth -= 1 }
        return body()
    }

    @discardableResult
    private func runSaveAsPanel() -> Bool {
        let chosen: URL?
        if let saveAsURLOverride {
            chosen = saveAsURLOverride(displayName)
        } else {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = displayName
            panel.canCreateDirectories = true
            chosen = runModalGuarded { panel.runModal() == .OK ? panel.url : nil }
        }
        guard let url = chosen else { return false }
        do {
            let previousURL = documentController.fileURL
            let previousExtension = previousURL?.pathExtension.lowercased()
            try documentController.save(text: textView.string, to: url)
            redetectLanguageIfExtensionChanged(from: previousExtension)
            updateWindowState()
            migrateSessionEntry(from: previousURL)
            removeDraft()
            return true
        } catch {
            showSaveError(error)
            return false
        }
    }

    /// Re-runs language detection (extension first, content fallback) after a
    /// Save As / titlebar rename gave the document a *different* extension —
    /// an untitled buffer saved as `notes.py` should highlight as Python
    /// immediately. A same-extension operation (Save As a copy, renaming only
    /// the stem) changes nothing, so a manual language choice survives it.
    private func redetectLanguageIfExtensionChanged(from previousExtension: String?) {
        guard documentController.fileURL?.pathExtension.lowercased() != previousExtension else { return }
        redetectLanguageAutomatically()
    }

    private func showSaveError(_ error: Error) {
        let alert = NSAlert(error: error)
        if let window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    // MARK: - Close confirmation

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Prompt only when the flag is dirty *and* the current text truly
        // differs from the saved contents. Editing then undoing back to the
        // baseline (or emptying a fresh untitled doc — its baseline is "")
        // hashes equal, so we close silently.
        guard documentController.isDirty,
              !documentController.matchesBaseline(textView.string) else { return true }

        let alert = NSAlert()
        alert.messageText = L10n.t(.closeConfirmMessage, displayName)
        alert.informativeText = L10n.t(.closeConfirmInfo)
        alert.addButton(withTitle: L10n.t(.menuSave))
        alert.addButton(withTitle: L10n.t(.dontSave))
        alert.addButton(withTitle: L10n.t(.cancel))

        switch runModalGuarded({ alert.runModal() }) {
        case .alertFirstButtonReturn:   // Save
            return performSave()
        case .alertSecondButtonReturn:  // Don't Save
            return true
        default:                        // Cancel
            return false
        }
    }

    public func windowWillClose(_ notification: Notification) {
        // From here on the window is going away: the resign-key notification
        // that fires as it leaves the screen must not run the focus-loss
        // bookkeeping (T15.10) — `recordSessionState` would resurrect the
        // session entry removed below (invisible after a clean quit's clear(),
        // but every hand-closed window came back after a crash), and the
        // focus-loss auto-save would silently write out changes the user just
        // answered "Don't Save" about.
        isClosing = true
        // Pending analysis work never outlives its window (M17 T17.1).
        documentAnalysis?.cancelPendingWork()
        // Nor does a pending same-word scan, nor its viewport observers.
        wordHighlighter?.cancel()
        // Nor a pending bracket-pair refresh, nor a pending language ranking.
        bracketHighlighter?.cancel()
        cancelLanguageRanking()
        // A run never outlives its window (T16.3b).
        tearDownRunSession()
        // Session bookkeeping (T14.8). Closing a window *by hand* is the user
        // saying "I'm done with this file" — it drops out of the restore list.
        // A close that is only a side effect of quitting keeps its entry, with
        // a final caret/scroll update, so the next launch brings the file back.
        if isAppTerminating() {
            recordSessionState()
            // Crash drafts (T14.11): a close that merely rides along with the
            // quit leaves the draft file alone — `AppDelegate` wipes the whole
            // directory once termination is approved, and only then, so an
            // interrupted quit still has every draft. Just drop the pending
            // checkpoint so no work item outlives the window.
            cancelDraftFlush()
        } else {
            if let url = documentController.fileURL {
                sessionStore.remove(path: url.path)
            }
            // The user closed this window, having already answered the unsaved-
            // changes prompt: whatever is unsaved was discarded on purpose.
            removeDraft()
        }
        onClose?()
    }
}

// MARK: - Run session host (T16.3b)

extension EditorWindowController: RunSessionHost {
    var runSourceText: String { textView.string }
    var runDocumentURL: URL? { documentController.fileURL }

    var runPanelHost: (stack: NSStackView, editor: NSView)? {
        guard let contentStack, let editorScrollView else { return nil }
        return (contentStack, editorScrollView)
    }

    /// A language found by "run" sniffing an Auto + Plain Text buffer: applied
    /// exactly like `rankLanguageNow` does, so Auto mode stays on.
    func applyAutoDetectedLanguage(identifier: String) {
        applyLanguage(identifier: identifier)
        didAutoDetectLanguage = true
    }

    func runSessionStateDidChange() {
        toolbarController?.refreshRunButton()
    }

    func runSessionDidClose() {
        runSession = nil
        runSessionStateDidChange()
    }

    @objc func runModuleDidChange() {
        if !isRunModuleEnabled { tearDownRunSession() }
        runSessionStateDidChange()
    }
}

// MARK: - Edit size for language ranking

/// Reports how many characters each storage edit inserted (its exact extent,
/// read before attribute fixing widens the range to whole paragraphs). Lets
/// the window rank a paste-sized insertion for a language at once.
@MainActor
private final class InsertionMeter: TextStorageObserving {
    private let report: (Int) -> Void

    init(report: @escaping (Int) -> Void) {
        self.report = report
    }

    func textStorageWillProcessEditing(editedMask: NSTextStorageEditActions,
                                       editedRange: NSRange,
                                       changeInLength delta: Int,
                                       textStorage: NSTextStorage) {
        guard editedMask.contains(.editedCharacters) else { return }
        report(editedRange.length)
    }

    func textStorageDidProcessEditing(editedMask: NSTextStorageEditActions,
                                      editedRange: NSRange,
                                      changeInLength delta: Int,
                                      textStorage: NSTextStorage) {}
}
