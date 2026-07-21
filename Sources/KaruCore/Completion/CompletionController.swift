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

/// Prefix-completion module: builds a document word index (debounced), scans
/// lightweight declaration symbols, and drives a floating suggestion popup.
///
/// Gating (ARCHITECTURE.md §2.5), mirroring `HighlightEngine`: gated on
/// `module.completion`. Switching the module off dismisses the popup and drops
/// the word index and symbol set, so a disabled controller's resident cost
/// returns to ≈ 0 (`isRuntimeStateReleased == true`); switching it back on
/// rebuilds from the current document.
@MainActor
public final class CompletionController: NSObject, TextStorageObserving, CompletionKeyHandler {
    private weak var textView: NSTextView?
    private let moduleSettings: ModuleSettings
    private let moduleCenter: NotificationCenter

    /// Releasable runtime state: the document word index. `nil` when the module
    /// is disabled or nothing has been indexed yet.
    private var wordIndex: WordIndex?

    /// Releasable runtime state: the last scanned declaration symbols.
    private var symbols: Set<String> = []

    /// Always-retained, cheap config resolved from the file's language.
    private var languageIdentifier: String = ""
    private var languageKeywords: [String] = []

    private var moduleEnabled: Bool

    /// Debounced full rebuild of the word index / symbols.
    private var pendingRebuild: DispatchWorkItem?
    private let debounceInterval: TimeInterval = 0.15

    /// Minimum prefix length before a popup is offered.
    private let minPrefixLength = 2

    // MARK: Popup UI state

    private var panel: NSPanel?
    private var tableView: NSTableView?
    private var suggestions: [String] = []
    /// Document range of the prefix currently being completed.
    private var prefixRange: NSRange?
    /// Guards our own completion insertion from being treated as a user action.
    private var isApplyingCompletion = false

    // MARK: - Queryable state (tests / diagnostics)

    /// True when no runtime index state is held — guaranteed after the module is
    /// switched off (the acceptance-criteria "released" state).
    public var isRuntimeStateReleased: Bool { wordIndex == nil }

    /// Whether the `completion` module is enabled.
    public var isModuleEnabled: Bool { moduleEnabled }

    // MARK: - Init

    public init(textView: NSTextView,
                moduleSettings: ModuleSettings = ModuleSettings(),
                moduleCenter: NotificationCenter = .default) {
        self.textView = textView
        self.moduleSettings = moduleSettings
        self.moduleCenter = moduleCenter
        self.moduleEnabled = moduleSettings.isEnabled(.completion)
        super.init()

        moduleCenter.addObserver(
            self, selector: #selector(moduleSettingsChanged(_:)),
            name: ModuleSettings.didChangeNotification, object: nil
        )
    }

    deinit {
        moduleCenter.removeObserver(self)
        pendingRebuild?.cancel()
    }

    // MARK: - Language wiring

    /// Points the controller at the language owning `ext` so it can offer that
    /// language's keywords and pick the right symbol-scan dialect. Resolving the
    /// definition also exercises `LanguageDefinition.keywords`.
    public func setLanguage(fileExtension ext: String?) {
        guard let ext, let def = LanguageRegistry.definition(forExtension: ext) else {
            languageIdentifier = ""
            languageKeywords = []
            return
        }
        languageIdentifier = def.identifier
        languageKeywords = def.keywords + def.builtins
    }

    /// Points the controller at the language whose stable `identifier` is `id`
    /// (e.g. `"python"`, chosen from the Language menu / toolbar or inferred by
    /// the content sniffer). An empty / unknown identifier drops back to no
    /// language keywords. This is the menu/sniff-driven counterpart to
    /// `setLanguage(fileExtension:)`; keeping completion in step with the
    /// highlighter was the wiring T6.2's review flagged as outstanding.
    public func setLanguage(identifier id: String?) {
        guard let id, !id.isEmpty,
              let def = LanguageRegistry.definition(forIdentifier: id) else {
            languageIdentifier = ""
            languageKeywords = []
            return
        }
        languageIdentifier = def.identifier
        languageKeywords = def.keywords + def.builtins
    }

    // MARK: - Indexing

    /// Synchronously (re)builds the word index and symbol set from the current
    /// document — but only while the module is enabled. Safe to call after a
    /// file loads and used by the debounced edit path.
    public func indexDocument() {
        guard moduleEnabled, let text = textView?.string else { return }
        wordIndex = WordIndex(text: text)
        symbols = WordIndex.symbols(text: text, languageIdentifier: languageIdentifier)
    }

    private func scheduleRebuild() {
        guard moduleEnabled else { return }
        pendingRebuild?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.indexDocument() }
        pendingRebuild = item
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: item)
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
        pendingRebuild?.cancel()
        pendingRebuild = nil
        wordIndex = nil
        symbols = []
        dismiss()
    }

    // MARK: - TextStorageObserving

    public func textStorageDidProcessEditing(editedMask: NSTextStorageEditActions,
                                             editedRange: NSRange,
                                             changeInLength delta: Int,
                                             textStorage: NSTextStorage) {
        guard editedMask.contains(.editedCharacters) else { return }
        scheduleRebuild()
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
        if wordIndex == nil { indexDocument() }

        if isCompletionActive {
            updatePopup()
        } else {
            guard let chars = event.charactersIgnoringModifiers,
                  let first = chars.first,
                  first.isLetter || first == "_" else { return }
            updatePopup()
        }
    }

    public func dismissCompletion() { dismiss() }

    // MARK: - Popup driving

    /// Recomputes the current prefix and suggestions, then shows / refilters /
    /// dismisses the popup accordingly.
    private func updatePopup() {
        guard let index = wordIndex, let prefix = currentPrefix() else {
            dismiss()
            return
        }
        let lowerPrefix = prefix.text.lowercased()
        let hits = index.suggestions(prefix: prefix.text,
                                     language: languageKeywords,
                                     symbols: symbols)
            // Drop the token the user is literally typing (it matches its own
            // prefix once the index catches up).
            .filter { $0.lowercased() != lowerPrefix }

        guard !hits.isEmpty else {
            dismiss()
            return
        }

        suggestions = hits
        prefixRange = prefix.range
        showOrUpdatePanel(anchorRange: prefix.range)
    }

    /// The `\w+`-run immediately before the caret, if it is at least
    /// `minPrefixLength` long and the selection is a plain caret.
    private func currentPrefix() -> (text: String, range: NSRange)? {
        guard let textView else { return nil }
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return nil }

        let ns = textView.string as NSString
        var start = selection.location
        while start > 0 {
            let ch = ns.substring(with: NSRange(location: start - 1, length: 1))
            if isWordCharacter(ch) { start -= 1 } else { break }
        }
        let length = selection.location - start
        guard length >= minPrefixLength else { return nil }
        let range = NSRange(location: start, length: length)
        return (ns.substring(with: range), range)
    }

    private func isWordCharacter(_ ch: String) -> Bool {
        guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || ch == "_"
    }

    private func moveSelection(_ delta: Int) {
        guard let table = tableView, !suggestions.isEmpty else { return }
        let current = table.selectedRow < 0 ? 0 : table.selectedRow
        let next = max(0, min(suggestions.count - 1, current + delta))
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    private func acceptSelection() {
        guard let table = tableView,
              let range = prefixRange,
              table.selectedRow >= 0, table.selectedRow < suggestions.count else {
            dismiss()
            return
        }
        let word = suggestions[table.selectedRow]
        isApplyingCompletion = true
        // Route through the standard input path so the replacement joins the
        // undo stack and fires the usual change notifications.
        textView?.insertText(word, replacementRange: range)
        isApplyingCompletion = false
        dismiss()
    }

    // MARK: - Panel construction / placement

    private func showOrUpdatePanel(anchorRange: NSRange) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        tableView?.reloadData()
        if tableView?.selectedRow ?? -1 < 0 || tableView?.selectedRow ?? 0 >= suggestions.count {
            tableView?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
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
        // Below the caret line (screen coords: y grows upward).
        let originPoint = NSPoint(x: rectOnScreen.minX,
                                  y: rectOnScreen.minY - height - 2)
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
        prefixRange = nil
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
        field.stringValue = row < suggestions.count ? suggestions[row] : ""
        return field
    }
}
