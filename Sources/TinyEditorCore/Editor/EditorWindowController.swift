import AppKit

public final class EditorWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    let documentController = DocumentController()
    private var textView: NSTextView!

    /// Shared newline index: one instance per window, injected into the gutter
    /// and (later) reused by search / folding.
    let lineIndex = LineIndex(text: "")
    private var gutterView: GutterView!

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
        window.contentView = scrollView

        // Attach the line-number gutter as the scroll view's vertical ruler.
        let gutter = GutterView(scrollView: scrollView, textView: textView, lineIndex: lineIndex)
        scrollView.verticalRulerView = gutter
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        self.gutterView = gutter

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
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
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
