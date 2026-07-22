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

    /// Multiplexes the single `textStorage.delegate` slot to the gutter (line
    /// index) and the highlight engine. Retained here because the storage holds
    /// its delegate weakly.
    private let observerHub = TextStorageObserverHub()
    private var highlightEngine: HighlightEngine!

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

    /// The document's current line-ending style. Detected on open / reopen and
    /// updated after a manual conversion; deliberately *not* re-detected on every
    /// keystroke (a document-level property, and detection scans the whole buffer),
    /// so the status bar just renders this stored value.
    private var currentLineEnding: LineEnding = .lf

    /// The two one-character ranges most recently painted by the bracket-match
    /// highlight (opener + closer), or `nil` when none is showing. Fixed-size
    /// state (never a growing structure): it exists only so the *next*
    /// `selectionDidChange` can clear exactly what it drew before recomputing.
    private var bracketHighlight: (open: NSRange, close: NSRange)?

    /// Low-saturation background tint for the matched bracket pair, resolved per
    /// appearance (mirrors `HighlightTheme`'s dynamic-colour approach). Bracket
    /// highlighting deliberately uses `.backgroundColor` — the same temporary
    /// attribute the find bar uses — so where a match overlaps a search hit the
    /// two tints visually stack; clearing only ever touches the two ranges this
    /// controller recorded, never the find bar's attributes.
    private static let bracketMatchColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.55, green: 0.58, blue: 0.66, alpha: 0.42)
            : NSColor(srgbRed: 0.36, green: 0.42, blue: 0.52, alpha: 0.26)
    }

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
        let engine = HighlightEngine(textView: textView, scrollView: scrollView)
        observerHub.add(engine)
        self.highlightEngine = engine

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
        let completion = CompletionController(textView: textView)
        observerHub.add(completion)
        (textView as? EditorTextView)?.completionKeyHandler = completion
        self.completionController = completion

        // Code folding: layout-manager delegate + gutter arrow provider.
        // Registered on the hub after the gutter so the shared LineIndex is
        // already updated when folding reacts to an edit.
        let folding = FoldingController(textView: textView, lineIndex: lineIndex)
        textView.layoutManager?.delegate = folding
        observerHub.add(folding)
        gutter.foldProvider = folding
        // The editor paints the collapsed-block background; give it the same
        // fold provider and shared LineIndex (for header-line geometry).
        (textView as? EditorTextView)?.foldProvider = folding
        (textView as? EditorTextView)?.lineIndex = lineIndex
        self.foldingController = folding

        // Cursor-word occurrence highlighter: viewport-only, debounced. Shares
        // the observer hub for edit notifications; pinged from selectionDidChange.
        let wordHighlighter = WordOccurrenceHighlighter(textView: textView)
        observerHub.add(wordHighlighter)
        self.wordHighlighter = wordHighlighter

        // Find bar shares the window's LineIndex; it sits above the editor in a
        // vertical stack and collapses out of layout when hidden.
        let findBar = FindBarController(textView: textView, lineIndex: lineIndex)
        self.findBar = findBar

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [findBar.barView, scrollView, statusBar])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.distribution = .fill

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
            selector: #selector(autoSaveOnResignKey(_:)),
            name: NSWindow.didResignKeyNotification,
            object: window
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
    }

    /// Re-applies the shared editor font size after a change broadcast.
    @objc private func fontSizeDidChange() {
        textView.font = .monospacedSystemFont(ofSize: EditorFontSettings().fontSize, weight: .regular)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        downloadTimer?.invalidate()
        // The word highlighter cancels its own pending work item in its deinit,
        // which runs as this controller (its sole owner) is released.
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

        // Loosen line spacing slightly. Applied via the *default* paragraph style
        // + typing attributes only — never written into the text storage — so the
        // "don't pre-store per-line attributes" rule (ARCHITECTURE.md §3) holds
        // and highlighting's temporary attributes stay untouched.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.15
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes[.paragraphStyle] = paragraph

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

            // Loading a file resets any prior manual override / detection.
            userOverrodeLanguage = false
            didAutoDetectLanguage = false

            // Detect the language by file extension: point the highlight engine
            // at it and reuse the identifier it resolves to drive indent width.
            // If the extension resolves nothing (unknown / no extension), fall
            // back to sniffing the file's content. `setLanguage` builds the
            // definition at most once.
            let ext = url.pathExtension
            var identifier = highlightEngine.setLanguage(fileExtension: ext)
            if identifier == nil, let sniffed = LanguageSniffer.sniff(text) {
                identifier = highlightEngine.setLanguage(identifier: sniffed)
                didAutoDetectLanguage = true
            }
            (textView as? EditorTextView)?.languageIdentifier = identifier ?? ext.lowercased()

            // Point completion at the same language (for its keywords / symbol
            // dialect) and index the freshly loaded document. Prefer the resolved
            // identifier (covers the sniffed case); fall back to the raw
            // extension when nothing resolved.
            if let identifier {
                completionController.setLanguage(identifier: identifier)
            } else {
                completionController.setLanguage(fileExtension: ext)
            }
            completionController.indexDocument()

            // Infer the indent unit from the file's actual content (VS Code's
            // detectIndentation), so the rainbow and Tab match what the file
            // really uses rather than the language's fixed default.
            redetectIndentUnit()

            // Loading fresh content should not go through the undo stack, and
            // the didChange notification only fires for user edits, so we
            // simply refresh window chrome here.
            updateWindowState()
            toolbarController?.refreshAll()
            refreshStatusBar()
        } catch {
            showSaveError(error)
        }
    }

    // MARK: - Text change tracking

    @objc private func textDidChange(_ notification: Notification) {
        let wasDirty = documentController.isDirty
        documentController.markEdited()
        if !wasDirty {
            window?.isDocumentEdited = true
        }
        maybeAutoDetectLanguage()
        refreshStatusBar()
    }

    @objc private func selectionDidChange(_ notification: Notification) {
        refreshStatusBar()
        updateBracketMatchHighlight()
        wordHighlighter.selectionChanged()
    }

    /// Recomputes the matched-bracket background highlight for the current caret.
    /// Clears the previous pair (only the two ranges this controller recorded —
    /// never the find bar's own background attributes), then, when the caret is
    /// adjacent to a balanced bracket, tints both the opener and its match.
    /// Storage-free apart from the two-range `bracketHighlight` marker; the match
    /// itself is a transient scan (`BracketMatcher.findMatch`).
    private func updateBracketMatchHighlight() {
        guard let layoutManager = textView.layoutManager else { return }

        if let previous = bracketHighlight {
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: previous.open)
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: previous.close)
            bracketHighlight = nil
        }

        // Only highlight for a plain caret (no active selection).
        let selection = textView.selectedRange()
        guard selection.length == 0,
              let match = BracketMatcher.findMatch(text: textView.string, caret: selection.location) else {
            return
        }
        let color = Self.bracketMatchColor
        layoutManager.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: match.open)
        layoutManager.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: match.close)
        bracketHighlight = match
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

    /// Sniffs the buffer for a language once it has accumulated enough content,
    /// so an untitled / pasted document highlights itself without the user
    /// picking a language. Runs only while no language is set and the user has
    /// not chosen one manually; stops after a successful classification.
    private func maybeAutoDetectLanguage() {
        guard !userOverrodeLanguage, !didAutoDetectLanguage,
              let editorView = textView as? EditorTextView,
              editorView.languageIdentifier.isEmpty else { return }

        let text = textView.string
        let charCount = (text as NSString).length
        let newlineCount = text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        // Wait for ≥120 characters or ≥3 lines before guessing.
        guard charCount >= 120 || newlineCount >= 2 else { return }

        guard let identifier = LanguageSniffer.sniff(text) else { return }
        applyLanguage(identifier: identifier)
        didAutoDetectLanguage = true
    }

    /// Single choke point for a language change: points the highlighter and the
    /// completion module at `identifier`, records it on the text view (for indent
    /// width / formatting), then refreshes the toolbar popup and status bar so
    /// every entry path (menu / toolbar / sniffer / load) stays in sync.
    private func applyLanguage(identifier: String) {
        highlightEngine.setLanguage(identifier: identifier)
        (textView as? EditorTextView)?.languageIdentifier = identifier
        completionController.setLanguage(identifier: identifier)
        redetectIndentUnit()
        toolbarController?.refreshAll()
        statusBar.updateLanguage(identifier)
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
        // Hide the native title only when a file capsule can replace it; an
        // untitled window keeps its native "Untitled" title (the capsule hides).
        window?.titleVisibility = hasFile ? .hidden : .visible
        toolbarController?.updateTitle(fileName: documentController.displayName,
                                       hasFile: hasFile,
                                       isDirty: documentController.isDirty)
    }

    // MARK: - Rename (titlebar capsule → DocumentController)

    /// Renames the current file in place from the titlebar capsule (T11.4).
    /// Delegates the filesystem work and validation to `DocumentController`,
    /// then re-syncs the window chrome (title / proxy icon / capsule). Validation
    /// failures are surfaced as a localized alert.
    func renameFile(to newName: String) {
        do {
            let newURL = try documentController.rename(to: newName)
            window?.representedURL = newURL
            updateWindowState()
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
        let identifier = highlightEngine.currentLanguageIdentifier ?? currentLanguageIdentifierValue
        navigator.present(languageIdentifier: identifier) { [weak self] in
            self?.symbolNavigator = nil
        }
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

    /// The indent width currently in effect (explicit override → detected unit →
    /// language default), so the toolbar popup shows what the editor actually
    /// uses rather than just the stored default.
    var currentEffectiveIndentWidth: Int {
        (textView as? EditorTextView)?.effectiveIndentWidth
            ?? IndentSettings().width(for: currentLanguageIdentifierValue)
    }

    /// Manual override to a specific language (from the Language menu or the
    /// toolbar popup). Suppresses automatic detection until Auto is chosen again.
    func chooseLanguage(identifier: String) {
        userOverrodeLanguage = true
        didAutoDetectLanguage = true
        applyLanguage(identifier: identifier)
    }

    /// Clears any manual override and re-detects: by extension for a saved file,
    /// otherwise by sniffing the buffer's content.
    func chooseAutoLanguage() {
        userOverrodeLanguage = false
        didAutoDetectLanguage = false

        if let url = documentController.fileURL {
            let ext = url.pathExtension
            var identifier = highlightEngine.setLanguage(fileExtension: ext)
            if identifier == nil, let sniffed = LanguageSniffer.sniff(textView.string) {
                identifier = highlightEngine.setLanguage(identifier: sniffed)
                didAutoDetectLanguage = true
            }
            let resolved = identifier ?? ext.lowercased()
            (textView as? EditorTextView)?.languageIdentifier = resolved
            if let identifier {
                completionController.setLanguage(identifier: identifier)
            } else {
                completionController.setLanguage(fileExtension: ext)
            }
            redetectIndentUnit()
            toolbarController?.refreshAll()
            statusBar.updateLanguage(resolved)
        } else {
            // Untitled: reset to plain, then let the sniffer re-classify if the
            // buffer already holds enough content.
            highlightEngine.setLanguage(identifier: nil)
            (textView as? EditorTextView)?.languageIdentifier = ""
            completionController.setLanguage(identifier: nil)
            redetectIndentUnit()
            toolbarController?.refreshAll()
            statusBar.updateLanguage("")
            maybeAutoDetectLanguage()
        }
    }

    /// Sets the indent width for the current language (from the toolbar popup)
    /// and repaints open editors so the indent rainbow reflects the new width.
    func setIndentWidth(_ width: Int) {
        let language = currentLanguageIdentifierValue
        UserDefaults.standard.set(width, forKey: IndentSettings.widthKey(for: language))
        textView.needsDisplay = true
    }

    // MARK: - Menu validation

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
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

    // MARK: - Focus-loss auto-save (T12.14)

    /// Silently writes the document to its existing file when the window loses
    /// key focus, if the feature is enabled. Deliberately non-modal:
    ///
    /// - Untitled documents (no file URL) are skipped by `AutoSavePolicy` — we
    ///   never pop a storage panel on focus loss.
    /// - On write failure we do **not** show an `NSAlert` (a modal sheet the
    ///   instant focus leaves is exactly the disruption to avoid). The document
    ///   stays dirty and a transient note flashes in the status bar instead.
    @objc private func autoSaveOnResignKey(_ note: Notification) {
        guard AutoSavePolicy.shouldSave(enabled: AutoSavePolicy.defaultEnabled,
                                        isDirty: documentController.isDirty,
                                        hasFileURL: documentController.fileURL != nil) else { return }
        do {
            try documentController.save(text: textView.string)
            updateWindowState()
            refreshStatusBar()
        } catch {
            // Silent degrade: keep the dirty state, surface a transient hint only.
            statusBar.flashMessage(L10n.t(.autosaveFailed))
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
    /// Returns `true` on success, `false` if cancelled or failed.
    @discardableResult
    private func performSave() -> Bool {
        guard documentController.fileURL != nil else { return runSaveAsPanel() }
        do {
            try documentController.save(text: textView.string)
            updateWindowState()
            return true
        } catch {
            showSaveError(error)
            return false
        }
    }

    @discardableResult
    private func runSaveAsPanel() -> Bool {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = displayName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try documentController.save(text: textView.string, to: url)
            updateWindowState()
            return true
        } catch {
            showSaveError(error)
            return false
        }
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

        switch alert.runModal() {
        case .alertFirstButtonReturn:   // Save
            return performSave()
        case .alertSecondButtonReturn:  // Don't Save
            return true
        default:                        // Cancel
            return false
        }
    }

    public func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
