import AppKit

/// The always-available scratchpad panel (T15.1): one keystroke away from any
/// app, plain text, no ceremony — and gone from memory the moment it is hidden.
///
/// Lifecycle is the whole point. Hiding does not merely `orderOut` the panel: it
/// flushes the text to `ScratchpadStore`, drops the panel *and* the text view,
/// and leaves this controller an empty shell holding a store and two closures.
/// Nothing is scheduled (the debounce work item is cancelled before teardown) and
/// no observer survives, so a hidden scratchpad costs the same as a feature the
/// user never opened (ARCHITECTURE.md §3.4). `show()` rebuilds from the file.
///
/// The text view is a plain `NSTextView`, deliberately *not* `EditorTextView`:
/// the pad is for prose fragments and pasted snippets, so it carries no
/// highlighting, completion or folding. Line numbers it does get (user request)
/// — the editor's own `GutterView`, fed by a per-showing `LineIndex`. Text that
/// deserves the rest graduates into a real file with ⌘S.
@MainActor
public final class ScratchpadController: NSObject, NSWindowDelegate {

    /// Frame autosave slot. The pad is a single window, so one slot is enough —
    /// it reopens exactly where the user last left (and sized) it.
    private static let frameAutosaveName = "KaruScratchpad"

    /// Delay between the last keystroke and the text hitting disk. Same reasoning
    /// (and value) as the editor's crash-draft debounce: a burst of typing costs
    /// one write, and a crash costs at most a sentence.
    static let defaultDebounceInterval: TimeInterval = 1.5
    var debounceInterval: TimeInterval = ScratchpadController.defaultDebounceInterval

    /// Where the text lives between sessions. Injected so tests (and the
    /// diagnostics hook) can point at a directory of their own.
    let store: ScratchpadStore

    /// Hands a graduated file to the app delegate, which opens it in a normal
    /// editor window. Injected rather than reached for so this type never needs
    /// to know the document layer exists.
    public var openInEditor: ((URL) -> Void)?

    // MARK: Transient runtime state (all released by `hide()`)
    private var panel: NSPanel?
    private var textView: NSTextView?
    private var pinButton: NSButton?
    private var flushWork: DispatchWorkItem?
    /// Retains the storage-delegate hub for the line-number gutter: the text
    /// storage only holds its delegate weakly, and the gutter (which the scroll
    /// view retains) reads line numbers through the index this hub updates.
    private var observerHub: TextStorageObserverHub?

    /// Guards against a second ⌘S while the save panel is up: `runModal` spins
    /// its own run loop, so the key equivalent can arrive again mid-save.
    private var isGraduating = false

    /// `nonisolated` so the app delegate — which AppKit calls without an actor
    /// annotation — can hold one as a stored property. Construction only fills in
    /// the store; everything that touches AppKit waits for `show()`.
    public nonisolated init(store: ScratchpadStore = ScratchpadStore()) {
        self.store = store
        super.init()
    }

    deinit {
        flushWork?.cancel()
    }

    /// True while the panel is on screen. Also the "is anything built?" test —
    /// hidden means the panel does not exist at all.
    public var isVisible: Bool { panel?.isVisible == true }

    // MARK: - Show / hide

    @objc public func toggle() {
        if isVisible { hide() } else { show() }
    }

    public func show() {
        if let panel {
            presentPanel(panel)
            return
        }
        let panel = makePanel()
        self.panel = panel
        // Restore the remembered frame; a first run has none, so the default
        // 480×360 set at construction time stays and is centred instead.
        if !panel.setFrameUsingName(Self.frameAutosaveName) {
            panel.center()
        }
        presentPanel(panel)
    }

    /// Flushes, remembers the frame and then tears the panel down completely.
    ///
    /// The undo stack dies with the text view. That is a deliberate trade: an
    /// undo history that survives hiding would mean keeping the text view (and
    /// its layout manager and text storage) resident for a panel nobody is
    /// looking at, which is exactly the cost this design refuses to pay.
    public func hide() {
        guard let panel else { return }
        cancelFlush()
        flushNow()
        panel.saveFrame(usingName: Self.frameAutosaveName)
        // Detach and forget *before* ordering out: an unpinned panel losing key
        // status would otherwise call straight back into `hide()` from inside
        // `orderOut`, and a half-torn-down panel would be dismantled twice.
        NotificationCenter.default.removeObserver(self, name: NSText.didChangeNotification, object: textView)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: panel)
        panel.delegate = nil
        self.panel = nil
        textView = nil
        pinButton = nil
        observerHub = nil
        panel.orderOut(nil)
    }

    /// Writes the current text right now if the panel is up. Called while the
    /// app is being torn down, where a debounced write would never fire.
    public func flushIfVisible() {
        guard panel != nil else { return }
        cancelFlush()
        flushNow()
    }

    /// A non-activating panel can become key *without* activating Karu, which is
    /// what makes the pad feel like an overlay: type into it, hide it, and the
    /// app you were in still has focus. `orderFrontRegardless` is needed because
    /// an inactive app's `orderFront` is otherwise deferred until it activates.
    private func presentPanel(_ panel: NSPanel) {
        panel.orderFrontRegardless()
        panel.makeKey()
        if let textView { panel.makeFirstResponder(textView) }
    }

    // MARK: - Construction

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = L10n.t(.scratchpadTitle)
        panel.level = .floating
        // Follow the user across Spaces and survive another app going full
        // screen — a pad that only exists on the Space it was opened on is not
        // "always available".
        panel.collectionBehavior.insert([.moveToActiveSpace, .fullScreenAuxiliary])
        // Focus loss is handled by the pin toggle below, not by AppKit's
        // hide-on-deactivate, which would ignore the setting.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = ScratchpadTextView()
        textView.controller = self
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = .monospacedSystemFont(ofSize: EditorFontSettings().fontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        let content = store.read()
        textView.string = content
        scrollView.documentView = textView
        self.textView = textView

        // Line numbers (user request, T15.2): the editor's own gutter, reused
        // verbatim — a fresh LineIndex and observer hub are built per showing
        // and die with the panel, so the pad still costs nothing while hidden.
        let hub = TextStorageObserverHub()
        textView.textStorage?.delegate = hub
        observerHub = hub
        let gutter = GutterView(scrollView: scrollView,
                                textView: textView,
                                lineIndex: LineIndex(text: content),
                                observerHub: hub)
        scrollView.verticalRulerView = gutter
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        // The pin lives *inside* the content, overlaid top-right above the text.
        // It was born as a titlebar accessory, which a utility panel's compact
        // title bar registers but never renders (user report: "no pin visible",
        // confirmed by pixel capture) — so it moved somewhere that provably draws.
        let container = NSView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)
        let button = makePinButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(button)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            button.topAnchor.constraint(equalTo: container.topAnchor, constant: 5),
            button.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            button.widthAnchor.constraint(equalToConstant: 24),
            button.heightAnchor.constraint(equalToConstant: 20),
        ])
        panel.contentView = container

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textDidChange(_:)),
            name: NSText.didChangeNotification,
            object: textView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelDidResignKey(_:)),
            name: NSWindow.didResignKeyNotification,
            object: panel
        )
        return panel
    }

    /// Pin toggle: on (the default) the pad stays put when it loses focus, off
    /// it disappears the moment you click away — "jot and go".
    private func makePinButton() -> NSButton {
        let button = NSButton(image: NSImage(), target: self, action: #selector(togglePinned(_:)))
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.setButtonType(.momentaryChange)
        pinButton = button
        updatePinButton()
        return button
    }

    private func updatePinButton() {
        let pinned = ScratchpadStore.isPinned()
        pinButton?.image = NSImage(systemSymbolName: pinned ? "pin.fill" : "pin",
                                   accessibilityDescription: nil)
        pinButton?.contentTintColor = pinned ? .controlAccentColor : .secondaryLabelColor
    }

    @objc private func togglePinned(_ sender: Any?) {
        UserDefaults.standard.set(!ScratchpadStore.isPinned(), forKey: ScratchpadStore.pinnedKey)
        updatePinButton()
    }

    // MARK: - Persistence

    @objc private func textDidChange(_ notification: Notification) {
        scheduleFlush()
    }

    /// Queues a write for a moment after the typing stops; each new edit replaces
    /// the pending one. Cancelled — never left dangling — by `hide()`.
    private func scheduleFlush() {
        flushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.flushNow() }
        }
        flushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    private func cancelFlush() {
        flushWork?.cancel()
        flushWork = nil
    }

    /// Writes the buffer straight from the main thread: the pad holds notes, not
    /// megabytes, and writes at most once per 1.5 s, so a background queue would
    /// buy nothing but a race with teardown.
    private func flushNow() {
        guard let textView else { return }
        store.write(textView.string)
    }

    // MARK: - Graduation (⌘S)

    /// Moves the pad's contents into a real file and opens it in the editor.
    ///
    /// Graduating *is* the confirmation — no extra "are you sure": the text does
    /// not vanish, it becomes a document. A cancelled save panel changes nothing.
    func graduate() {
        guard !isGraduating, let textView else { return }
        isGraduating = true
        defer { isGraduating = false }
        cancelFlush()
        flushNow()

        let content = textView.string
        // The save panel is modal and needs a real activation to come forward;
        // a non-activating panel's sheet would be stranded behind other apps,
        // so it runs application-modal instead of attached to the pad.
        NSApp.activate(ignoringOtherApps: true)
        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = Self.suggestedFileName(for: content)
        guard savePanel.runModal() == .OK, let url = savePanel.url else { return }

        do {
            try Data(content.utf8).write(to: url, options: .atomic)
        } catch {
            // Keep the text: a failed save must not be the moment the pad is
            // emptied. The user can retry or copy it out.
            let alert = NSAlert(error: error)
            alert.runModal()
            return
        }

        // The content has left the pad for good.
        store.clear()
        textView.string = ""
        hide()
        openInEditor?(url)
    }

    /// Suggests a file name from the first non-empty line, the way a note's first
    /// line is its title. Capped at 40 characters so a pasted paragraph does not
    /// become the name; falls back to "Draft.txt" for an empty pad.
    nonisolated static func suggestedFileName(for content: String) -> String {
        let firstLine = content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        // "/" and ":" are the two characters a macOS file name cannot carry.
        let sanitized = firstLine
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        guard !sanitized.isEmpty else { return "Draft.txt" }
        return String(sanitized.prefix(40)) + ".txt"
    }

    // MARK: - Diagnostics support

    /// The live panel and text view, for `AppDelegate`'s `KARU_SCRATCHTEST` hook.
    /// Both are `nil` exactly when the pad is hidden, which is the property that
    /// hook exists to prove.
    var diagnosticPanel: NSPanel? { panel }
    var diagnosticTextView: NSTextView? { textView }

    // MARK: - Window delegate

    /// The close button and ⌘W hide the pad rather than destroying it — closing
    /// a notebook is not throwing it away.
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    @objc private func panelDidResignKey(_ notification: Notification) {
        guard !isGraduating, !ScratchpadStore.isPinned() else { return }
        hide()
    }
}

// MARK: - Text view

/// The pad's text view. Adds exactly two behaviours to a plain `NSTextView`:
/// Esc hides the panel and ⌘S graduates the text into a file.
private final class ScratchpadTextView: NSTextView {
    weak var controller: ScratchpadController?

    /// Esc has to be caught here rather than in the panel's `keyDown`: the text
    /// view sees the key first and turns it into `cancelOperation(_:)`, so a
    /// window-level interception would never run.
    override func cancelOperation(_ sender: Any?) {
        controller?.hide()
    }

    /// ⌘S never reaches the pad through the main menu (File ▸ Save targets the
    /// editor window controller), so the key equivalent is claimed here. Only a
    /// bare ⌘S — ⌘⇧S and friends stay available to the menu.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "s" {
            controller?.graduate()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
