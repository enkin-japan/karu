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

    /// True once the user has manually picked a language from the Language menu.
    /// Suppresses all automatic detection until they choose Auto again.
    private var userOverrodeLanguage = false

    /// True once automatic content sniffing has landed on a language (or a file
    /// extension resolved one). Prevents re-sniffing an untitled buffer on every
    /// keystroke after it has already been classified.
    private var didAutoDetectLanguage = false

    public convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.setFrameAutosaveName("EditorWindow")
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

        // Find bar shares the window's LineIndex; it sits above the editor in a
        // vertical stack and collapses out of layout when hidden.
        let findBar = FindBarController(textView: textView, lineIndex: lineIndex)
        self.findBar = findBar

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [findBar.barView, scrollView, statusBar])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.distribution = .fill
        window.contentView = stack
        NSLayoutConstraint.activate([
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

    deinit {
        NotificationCenter.default.removeObserver(self)
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

    /// True for a freshly created window: untitled, empty, never edited.
    /// Used by the app delegate to reuse (rather than orphan) the initial
    /// window when a file arrives from Finder right after launch.
    var isPristineUntitled: Bool {
        documentController.fileURL == nil && !documentController.isDirty && textView.string.isEmpty
    }

    /// Loads `url` into this window (used when opening a file in a new window).
    public func load(url: URL) {
        do {
            let text = try documentController.load(from: url)
            // Pin the layout mode from the document size *before* inserting the
            // text, so a large file is never laid out eagerly even momentarily.
            layoutModeController?.setLength((text as NSString).length)
            textView.string = text

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
    }

    /// Recomputes the status strip's caret position, language, and char count.
    private func refreshStatusBar() {
        let caret = textView.selectedRange().location
        let line = lineIndex.lineNumber(forOffset: caret)
        let lineStart = lineIndex.offsetRange(ofLine: line).lowerBound
        statusBar.updateCaret(line: line,
                              column: StatusBarMetrics.column(caretOffset: caret,
                                                              lineStartOffset: lineStart))
        statusBar.updateLanguage(currentLanguageIdentifierValue)
        statusBar.updateCharacterCount((textView.string as NSString).length)
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
        window?.title = displayName
        window?.representedURL = documentController.fileURL
        window?.isDocumentEdited = documentController.isDirty
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
        guard documentController.isDirty else { return true }
        // An untitled document whose text is empty has nothing worth saving
        // (e.g. the user typed and deleted everything) — close silently.
        if documentController.fileURL == nil && textView.string.isEmpty { return true }

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
