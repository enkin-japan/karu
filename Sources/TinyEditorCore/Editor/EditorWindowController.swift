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

    /// Multiplexes the single `textStorage.delegate` slot to the gutter (line
    /// index) and the highlight engine. Retained here because the storage holds
    /// its delegate weakly.
    private let observerHub = TextStorageObserverHub()
    private var highlightEngine: HighlightEngine!

    /// Prefix-completion driver: indexes the document (debounced), scans symbols
    /// and drives the suggestion popup. Module-gated on `module.completion`.
    private var completionController: CompletionController!

    /// Code-folding layer: acts as the layout manager's delegate (glyph
    /// suppression + fragment collapsing) and answers the gutter's arrow /
    /// hidden-line queries. Folding never mutates text, so the shared
    /// `LineIndex` — and thus line numbers / highlighting — stay correct.
    private var foldingController: FoldingController!

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
        self.foldingController = folding

        // Find bar shares the window's LineIndex; it sits above the editor in a
        // vertical stack and collapses out of layout when hidden.
        let findBar = FindBarController(textView: textView, lineIndex: lineIndex)
        self.findBar = findBar

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [findBar.barView, scrollView])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.distribution = .fill
        window.contentView = stack
        NSLayoutConstraint.activate([
            findBar.barView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textDidChange(_:)),
            name: NSText.didChangeNotification,
            object: textView
        )

        updateWindowState()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private static func makeEditorView() -> (NSScrollView, NSTextView) {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = EditorTextView()
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

        scrollView.documentView = textView
        return (scrollView, textView)
    }

    // MARK: - Loading

    /// Loads `url` into this window (used when opening a file in a new window).
    public func load(url: URL) {
        do {
            let text = try documentController.load(from: url)
            textView.string = text

            // Detect the language by file extension: point the highlight engine
            // at it and reuse the identifier it resolves to drive indent width.
            // Falls back to the lowercased extension when the language is
            // unregistered. `setLanguage` builds the definition at most once.
            let ext = url.pathExtension
            let identifier = highlightEngine.setLanguage(fileExtension: ext)
            (textView as? EditorTextView)?.languageIdentifier = identifier ?? ext.lowercased()

            // Point completion at the same language (for its keywords / symbol
            // dialect) and index the freshly loaded document.
            completionController.setLanguage(fileExtension: ext)
            completionController.indexDocument()

            // Loading fresh content should not go through the undo stack, and
            // the didChange notification only fires for user edits, so we
            // simply refresh window chrome here.
            updateWindowState()
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
    }

    private func updateWindowState() {
        window?.title = documentController.displayName
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
            alert.messageText = "Formatting failed"
            alert.informativeText = "Line \(line): \(message)"
            alert.alertStyle = .warning
            if let window {
                alert.beginSheetModal(for: window, completionHandler: nil)
            } else {
                alert.runModal()
            }
        }
    }

    // MARK: - Menu validation

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(formatDocument(_:)) {
            guard ModuleSettings().isEnabled(.format) else { return false }
            let language = (textView as? EditorTextView)?.languageIdentifier ?? ""
            return FormatDispatch.supports(languageIdentifier: language)
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
        panel.nameFieldStringValue = documentController.displayName
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

        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes made to \(documentController.displayName)?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")

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
