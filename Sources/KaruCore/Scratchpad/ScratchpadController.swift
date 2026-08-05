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
    private var todoButton: NSButton?
    private var gutterView: GutterView?
    /// Find / replace over the pad's text (T15.3), the editor's own bar reused:
    /// it needs nothing but an `NSTextView` and a `LineIndex`, both of which the
    /// pad already builds. Dies with the panel like everything else here.
    private var findBar: FindBarController?
    private var flushWork: DispatchWorkItem?
    /// Retains the storage-delegate hub for the line-number gutter: the text
    /// storage only holds its delegate weakly, and the gutter (which the scroll
    /// view retains) reads line numbers through the index this hub updates.
    private var observerHub: TextStorageObserverHub?
    /// Ghost-pixel guard, same as the editor's (T15.5) — retained because the
    /// hub holds observers weakly. Dies with the panel like everything here.
    private var shrinkRepaint: ShrinkRepaintObserver?
    /// URL underlining + ⌘-click (T15.6), the editor's own detector reused.
    /// Retained for the same reason as the guard above; its pending scan is
    /// cancelled by `hide()` so a hidden pad schedules nothing.
    private var linkDetector: LinkDetector?

    /// True while the save sheet is up. Guards against a second ⌘S, against the
    /// unpinned pad hiding itself when the sheet takes key status, and against
    /// the hot key tearing the panel down under an open sheet.
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

    /// True when the pad is the key window — the state in which the zoom keys
    /// must resize the pad and not the shared editor size (see the app
    /// delegate's `zoomTargetsScratchpad`).
    var isKeyPanel: Bool { panel?.isKeyWindow == true }

    // MARK: - Show / hide

    @objc public func toggle() {
        // The hot key must not tear the panel down under an open save sheet —
        // half a modal session outliving its parent window is a crash waiting.
        guard !isGraduating else { return }
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
        NotificationCenter.default.removeObserver(self, name: ScratchpadStore.fontDidChangeNotification, object: nil)
        panel.delegate = nil
        self.panel = nil
        textView = nil
        pinButton = nil
        todoButton = nil
        gutterView = nil
        findBar = nil
        observerHub = nil
        shrinkRepaint = nil
        linkDetector?.cancel()
        linkDetector = nil
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
        // A *standard* titled panel, not `.utilityWindow` (T15.4, user verdict:
        // the self-drawn 20 pt header looked worse than the system title bar).
        // Dropping the utility style is what lets the pin live in the title bar:
        // a utility panel registers titlebar accessories but never renders them
        // (the T15.2 pixel finding), while the standard bar draws them fine —
        // re-proven by pixel capture after this change.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = Self.spacedTitle(L10n.t(.scratchpadTitle))
        panel.level = .floating
        // Present on *every* Space at once (Tot's behaviour, user request:
        // "moves along with the desktop"), and alive over another app's full
        // screen — a pad that only exists on the Space it was opened on is not
        // "always available". `.canJoinAllSpaces` rather than `.moveToActiveSpace`:
        // the latter only relocates the panel when it is re-shown, so switching
        // desktop left it behind on the old one. Suspected fix for the second
        // T15.5 report as well (input-method candidate bar vanishing in a
        // full-screen Space): the candidate window follows the active Space,
        // while the panel used to stay pinned to the one that raised it.
        panel.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
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
        // The pad's own size (T15.3), which starts out inheriting the editor's and
        // parts ways with it the first time ⌘+ / ⌘- is pressed in here.
        textView.font = .monospacedSystemFont(ofSize: ScratchpadStore.fontSize(), weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        let content = store.read()
        textView.string = content
        scrollView.documentView = textView
        self.textView = textView

        // One index, reused (ARCHITECTURE.md §3.3): the gutter and the find bar
        // share a single LineIndex. Like the observer hub it is built per showing
        // and dies with the panel, so the pad still costs nothing while hidden.
        let lineIndex = LineIndex(text: content)
        let hub = TextStorageObserverHub()
        textView.textStorage?.delegate = hub
        observerHub = hub
        // Ghost-pixel guard (T15.5): the pad deletes text like any editor.
        let repaint = ShrinkRepaintObserver(textView: textView)
        hub.add(repaint)
        shrinkRepaint = repaint
        // URL underlining (T15.6). The restored content was assigned before the
        // hub took the delegate slot, so nothing would notify the detector about
        // it — the first scan is kicked off by hand.
        let links = LinkDetector(textView: textView)
        hub.add(links)
        textView.linkDetector = links
        linkDetector = links
        links.scan()
        let gutter = GutterView(scrollView: scrollView,
                                textView: textView,
                                lineIndex: lineIndex,
                                observerHub: hub)
        scrollView.verticalRulerView = gutter
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        gutterView = gutter

        // Two rows, not one (T15.5): a single-row bar cannot show its buttons in
        // a pad-sized window, whatever the layout does with it.
        let findBar = FindBarController(textView: textView, lineIndex: lineIndex, compact: true)
        self.findBar = findBar

        // The bar *joins* the layout — while shown it pushes the text down
        // instead of covering the first line (T15.5 user report) — but by hand,
        // never through an NSStackView. A stack chains its arranged views'
        // ~660 pt required minimum width up through its own fitting constraints
        // onto the window, and the pad could then not be made narrow at all
        // (T15.4 user report), hidden or not. Here the bar's only horizontal
        // pins are a required leading edge and a *breakable* trailing one, so
        // its minimum width never reaches the window: the window minimum is
        // whatever `contentMinSize` says, nothing else.
        //
        // The trailing pin's priority must sit *below* 500: NSWindow resizes
        // itself to satisfy content constraints above `windowSizeStayPut`, so a
        // 900 pin plus the bar's minimum actively grew the window back to 682 pt
        // (measured) instead of breaking — the same bug through a second door.
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.clipsToBounds = true
        container.addSubview(scrollView)
        container.addSubview(findBar.barView)
        let barTrailing = findBar.barView.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        barTrailing.priority = NSLayoutConstraint.Priority(480)
        // Exactly one of these is active at a time: the text starts at the top
        // edge while the bar is hidden, and below the bar while it is shown.
        let textBelowContainerTop = scrollView.topAnchor.constraint(equalTo: container.topAnchor)
        let textBelowFindBar = scrollView.topAnchor.constraint(equalTo: findBar.barView.bottomAnchor)
        NSLayoutConstraint.activate([
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            findBar.barView.topAnchor.constraint(equalTo: container.topAnchor),
            findBar.barView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            barTrailing,
        ])
        // No `self` in the closure: it is owned by the find bar, which this
        // controller owns — capturing self would be a cycle that outlives
        // `hide()`. The constraints hold their views weakly, as AppKit does.
        let applyBarVisibility: (Bool) -> Void = { [weak container] shown in
            textBelowContainerTop.isActive = false
            textBelowFindBar.isActive = false
            if shown { textBelowFindBar.isActive = true } else { textBelowContainerTop.isActive = true }
            container?.needsLayout = true
            container?.layoutSubtreeIfNeeded()
        }
        applyBarVisibility(findBar.isShown)
        findBar.onVisibilityChanged = applyBarVisibility

        panel.contentView = container
        // Wide enough for the compact bar's own controls, measured rather than
        // guessed: below this the buttons would be clipped by `clipsToBounds`.
        panel.contentMinSize = NSSize(width: max(340, ceil(findBar.barView.fittingSize.width)),
                                      height: 160)

        // The to-do toggle and the pin ride in the (standard) title bar's
        // trailing corner, in that order — the pin stays where users already
        // reach for it, and the new button grows the strip leftward.
        let accessory = NSTitlebarAccessoryViewController()
        // 62 pt, not 58: the pin keeps its original 7 pt gap to the window edge,
        // so widening the strip moves the new button in beside it rather than
        // shifting the pin the user already knows the position of.
        let buttons = NSView(frame: NSRect(x: 0, y: 0, width: 62, height: 24))
        let todo = makeTodoButton()
        todo.frame = NSRect(x: 3, y: 2, width: 24, height: 20)
        buttons.addSubview(todo)
        let pin = makePinButton()
        pin.frame = NSRect(x: 31, y: 2, width: 24, height: 20)
        buttons.addSubview(pin)
        accessory.view = buttons
        accessory.layoutAttribute = .trailing
        panel.addTitlebarAccessoryViewController(accessory)

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
        // Live font size. Installed here — i.e. on `show()`, the only caller — and
        // removed by `hide()`, so a hidden pad leaves no observer behind
        // (ARCHITECTURE.md §3.4).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(fontSizeDidChange),
            name: ScratchpadStore.fontDidChangeNotification,
            object: nil
        )
        return panel
    }

    /// Loosens a short CJK title with ideographic spaces — "草稿本" becomes
    /// "草　稿　本" (user request: the three characters sat too tight in the
    /// title bar). Longer titles (the English "Scratchpad", the Japanese
    /// katakana) are left alone: spacing every letter of those would stretch
    /// them past the point of readability.
    nonisolated static func spacedTitle(_ title: String) -> String {
        let characters = Array(title)
        guard characters.count <= 4, characters.count > 1 else { return title }
        return characters.map(String.init).joined(separator: "\u{3000}")
    }

    /// Pin toggle: on (the default) the pad stays put when it loses focus, off
    /// it disappears the moment you click away — "jot and go".
    private func makePinButton() -> NSButton {
        let button = ScratchpadTitlebarButton(image: NSImage(), target: self, action: #selector(togglePinned(_:)))
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.setButtonType(.momentaryChange)
        button.toolTip = L10n.t(.scratchpadPinTooltip)
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

    /// Pin toggle action. `fileprivate` rather than `private` so ⇧⌘P — which the
    /// text view claims, the pad having no menu of its own — runs exactly the
    /// same code path as the button.
    @objc fileprivate func togglePinned(_ sender: Any?) {
        UserDefaults.standard.set(!ScratchpadStore.isPinned(), forKey: ScratchpadStore.pinnedKey)
        updatePinButton()
    }

    /// To-do toggle: the same three-state cycle ⇧⌘L performs, for people who
    /// would rather click. The glyph falls back to a literal ballot box on a
    /// system that has no "checklist" symbol.
    private func makeTodoButton() -> NSButton {
        let button = ScratchpadTitlebarButton(image: NSImage(), target: self, action: #selector(toggleTodo(_:)))
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.toolTip = L10n.t(.scratchpadTodoTooltip)
        button.contentTintColor = .secondaryLabelColor
        if let symbol = NSImage(systemSymbolName: "checklist", accessibilityDescription: nil) {
            button.imagePosition = .imageOnly
            button.image = symbol
        } else {
            button.imagePosition = .noImage
            button.title = "☑"
        }
        todoButton = button
        return button
    }

    /// Cycles the selected lines through the three to-do states. Routed into the
    /// text view so the edit goes through the same undo-aware path the keyboard
    /// shortcut uses (and so a click on the button cannot bypass the undo group).
    @objc private func toggleTodo(_ sender: Any?) {
        (textView as? ScratchpadTextView)?.cycleTodoList()
    }

    // MARK: - Font size (T15.3)

    /// Re-applies the pad's own size after ⌘+ / ⌘- here or the preferences
    /// stepper. The gutter has to be told separately — nothing informs a ruler
    /// that its client's font changed.
    @objc private func fontSizeDidChange() {
        guard let textView else { return }
        textView.font = .monospacedSystemFont(ofSize: ScratchpadStore.fontSize(), weight: .regular)
        gutterView?.fontDidChange()
    }

    /// Applies a zoom key to the *pad's* size only. Same semantics as View ▸ Zoom
    /// (same step, same clamp, same "actual size"), but the editor windows behind
    /// the pad are left alone — the shared setting used to move under them.
    func zoom(_ command: ZoomCommand) {
        let current = ScratchpadStore.fontSize()
        switch command {
        case .zoomIn:
            ScratchpadStore.setFontSize(FontZoom.step(current: current, direction: .increase))
        case .zoomOut:
            ScratchpadStore.setFontSize(FontZoom.step(current: current, direction: .decrease))
        case .actualSize:
            ScratchpadStore.setFontSize(FontZoom.defaultSize)
        }
    }

    /// The three zoom keys the pad claims for itself.
    enum ZoomCommand {
        case zoomIn, zoomOut, actualSize
    }

    /// Maps a key equivalent to a zoom command, or `nil` when it is not one.
    /// Pure and `nonisolated` so the routing can be unit tested without a panel.
    ///
    /// `⌘=` is included because that is the key US keyboards actually press for
    /// ⌘+ (the main menu carries the same alternate); ⇧ is tolerated so the
    /// literal ⌘⇧+ works too, while every other modifier combination is left to
    /// the responder chain.
    nonisolated static func zoomCommand(modifiers: NSEvent.ModifierFlags,
                                        charactersIgnoringModifiers: String?) -> ZoomCommand? {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        guard flags.subtracting(.shift) == .command else { return nil }
        switch charactersIgnoringModifiers {
        case "+", "=": return .zoomIn
        case "-":      return .zoomOut
        case "0":      return .actualSize
        default:       return nil
        }
    }

    // MARK: - Find bar (T15.3)

    func showFindBar() {
        findBar?.show()
    }

    /// Esc, in layers: it closes the find bar first and only hides the pad on a
    /// second press. (Esc *inside* the search field is the find bar's own
    /// business and never reaches here.)
    func escapePressed() {
        if let findBar, findBar.isShown {
            findBar.hide()
            return
        }
        hide()
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
    ///
    /// The save panel runs as a **sheet on the pad**, not application-modal
    /// (T15.8, two user reports): activation on macOS 14+ is cooperative, so an
    /// inactive Karu's `runModal` window could end up *behind* the active app's
    /// windows; and over another app's full-screen Space a modal window opened
    /// on the normal Space with no automatic switch to it. A sheet is a child of
    /// the panel — same Space (full screen included), always above the pad, and
    /// key without activating anything, exactly like the pad itself.
    func graduate() {
        guard !isGraduating, let panel, let textView else { return }
        isGraduating = true
        cancelFlush()
        flushNow()

        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = Self.suggestedFileName(for: textView.string)
        savePanel.beginSheetModal(for: panel) { [weak self] response in
            self?.finishGraduation(savePanel: savePanel, response: response)
        }
    }

    /// Completion of the save sheet. Reads the text *now*, not at ⌘S time — the
    /// buffer is authoritative right up to the moment it leaves the pad.
    private func finishGraduation(savePanel: NSSavePanel, response: NSApplication.ModalResponse) {
        isGraduating = false
        guard response == .OK, let url = savePanel.url, let textView else { return }
        let content = textView.string
        do {
            try Data(content.utf8).write(to: url, options: .atomic)
        } catch {
            // Keep the text: a failed save must not be the moment the pad is
            // emptied. The user can retry or copy it out. The alert is a sheet
            // for the same reason the save panel is.
            let alert = NSAlert(error: error)
            if let panel {
                alert.beginSheetModal(for: panel)
            } else {
                alert.runModal()
            }
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

/// The pad's text view. Adds a handful of behaviours to a plain `NSTextView`:
/// Esc closes the find bar or hides the panel, ⌘S graduates the text into a
/// file, ⌘F opens find / replace, the zoom keys resize the pad alone, and
/// (T15.6) ⇧⌘L cycles to-do markers, ⏎ continues a list, a click on a check box
/// ticks it and ⌘-click opens a URL.
private final class ScratchpadTextView: NSTextView {
    weak var controller: ScratchpadController?

    /// URL cache for ⌘-click. Weak: owned by the controller, gone with the panel.
    weak var linkDetector: LinkDetector?

    /// Esc has to be caught here rather than in the panel's `keyDown`: the text
    /// view sees the key first and turns it into `cancelOperation(_:)`, so a
    /// window-level interception would never run.
    override func cancelOperation(_ sender: Any?) {
        controller?.escapePressed()
    }

    // MARK: Logical line start / end (⌘← / ⌘→)

    // Same four overrides as `EditorTextView` (T14.2), calling the same pure
    // targets: ⌘←/⌘→ default to the *visual* line ends, so a soft-wrapped line
    // — which the pad, being narrow and always wrapping, is full of — sends the
    // caret mid-content depending on the panel's width. VS Code's Home toggle
    // (first non-whitespace ⇄ column 0) comes along inside `smartLineStart`.

    override func moveToLeftEndOfLine(_ sender: Any?) {
        let target = EditorTextView.smartLineStart(text: string, caret: selectedRange().location)
        setSelectedRange(NSRange(location: target, length: 0))
        scrollRangeToVisible(NSRange(location: target, length: 0))
    }

    override func moveToRightEndOfLine(_ sender: Any?) {
        let caret = selectedRange()
        let target = EditorTextView.smartLineEnd(text: string, caret: caret.location + caret.length)
        setSelectedRange(NSRange(location: target, length: 0))
        scrollRangeToVisible(NSRange(location: target, length: 0))
    }

    override func moveToLeftEndOfLineAndModifySelection(_ sender: Any?) {
        let selection = selectedRange()
        let target = EditorTextView.smartLineStart(text: string, caret: selection.location)
        let upper = selection.location + selection.length
        setSelectedRange(NSRange(location: min(target, upper), length: max(0, upper - target)))
    }

    override func moveToRightEndOfLineAndModifySelection(_ sender: Any?) {
        let selection = selectedRange()
        let target = EditorTextView.smartLineEnd(text: string, caret: selection.location + selection.length)
        setSelectedRange(NSRange(location: selection.location,
                                 length: max(0, target - selection.location)))
    }

    /// The pad's key equivalents. None of them arrive through the main menu —
    /// File ▸ Save and Edit ▸ Find target the editor window controller, and
    /// View ▸ Zoom writes the *shared* editor size — so they are claimed here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "s":
                // Only a bare ⌘S — ⌘⇧S and friends stay available to the menu.
                controller?.graduate()
                return true
            case "f":
                controller?.showFindBar()
                return true
            default:
                break
            }
        }
        // ⇧⌘L / ⇧⌘P — the two title-bar buttons' actions. Claimed here for the
        // same reason as the pair above: the pad has no menu of its own, and the
        // main menu's ⇧⌘P (the editor's command palette) must not win while the
        // pad is key.
        if modifiers == [.command, .shift] {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "l":
                cycleTodoList()
                return true
            case "p":
                controller?.togglePinned(nil)
                return true
            default:
                break
            }
        }
        if let zoom = ScratchpadController.zoomCommand(
            modifiers: event.modifierFlags,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers) {
            controller?.zoom(zoom)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: To-do lists (T15.6)

    /// ⇧⌘L / the title-bar button: cycles every line the selection touches
    /// through plain → `- [ ] ` → `- [x] ` (moved to the bottom) → plain.
    func cycleTodoList() {
        apply(TodoEngine.cycleTodo(text: string, selection: selectedRange()))
    }

    /// A click inside a check box ticks it (and moves the line where its new
    /// state belongs); anything else is an ordinary click. ⌘-click on a URL
    /// opens it and never moves the caret.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           let url = linkDetector?.url(atPoint: point) {
            NSWorkspace.shared.open(url)
            return
        }
        if let index = checkBoxCharacterIndex(at: point),
           let result = TodoEngine.flipChecked(text: string,
                                               lineAt: index,
                                               selection: selectedRange()) {
            apply(result)
            return
        }
        super.mouseDown(with: event)
    }

    /// The character index of a check box hit by `point`, or `nil` when the
    /// click landed anywhere else. The three box characters (`[`, the state,
    /// `]`) are the hit target; the index alone is not enough (a click past the
    /// end of a line maps to its last character), so the box's own glyph rect
    /// has to contain the point.
    private func checkBoxCharacterIndex(at point: NSPoint) -> Int? {
        guard let layoutManager, let container = textContainer else { return nil }
        let origin = textContainerOrigin
        let inContainer = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(for: inContainer, in: container,
                                             fractionOfDistanceThroughGlyph: &fraction)
        let index = layoutManager.characterIndexForGlyph(at: glyph)

        let ns = string as NSString
        guard ns.length > 0 else { return nil }
        let lineRange = ns.lineRange(for: NSRange(location: min(index, ns.length - 1), length: 0))
        var contentsEnd = 0
        ns.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: lineRange)
        let content = ns.substring(with: NSRange(location: lineRange.location,
                                                 length: contentsEnd - lineRange.location))
        guard let box = TodoEngine.boxRange(inLine: content) else { return nil }

        let absolute = NSRange(location: lineRange.location + box.location, length: box.length)
        guard NSLocationInRange(index, absolute) else { return nil }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: absolute, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
        guard rect.offsetBy(dx: origin.x, dy: origin.y).contains(point) else { return nil }
        return absolute.location
    }

    /// ⏎ continues the list the caret is on (see `TodoEngine.continuation`).
    /// Anything else — a caret inside the prefix, a non-list line, an active
    /// selection, a half-typed input-method composition — falls straight through
    /// to AppKit's own newline.
    override func insertNewline(_ sender: Any?) {
        let selection = selectedRange()
        let ns = string as NSString
        guard selection.length == 0, !hasMarkedText(), ns.length > 0,
              selection.location <= ns.length else {
            super.insertNewline(sender)
            return
        }
        let lineRange = ns.lineRange(for: NSRange(location: min(selection.location, ns.length - 1),
                                                  length: 0))
        var contentsEnd = 0
        ns.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: lineRange)
        let content = ns.substring(with: NSRange(location: lineRange.location,
                                                 length: contentsEnd - lineRange.location))
        let caretInLine = selection.location - lineRange.location
        guard caretInLine >= 0, caretInLine <= (content as NSString).length,
              let continuation = TodoEngine.continuation(line: content,
                                                         caretOffsetInLine: caretInLine) else {
            super.insertNewline(sender)
            return
        }

        switch continuation {
        case .insert(let prefix):
            let inserted = "\n" + prefix
            replace(range: selection, with: inserted,
                    selection: NSRange(location: selection.location + (inserted as NSString).length,
                                       length: 0))
        case .exit(let lineRelative):
            let target = NSRange(location: lineRange.location + lineRelative.location,
                                 length: lineRelative.length)
            replace(range: target, with: "",
                    selection: NSRange(location: target.location, length: 0))
        }
    }

    /// Applies a whole-document result from `TodoEngine` as **one** edit: the
    /// marker change and the line move differ from the current text in a single
    /// span, so `minimalEdit` narrows the rewrite to it and ⌘Z restores both the
    /// marker and the position in one go. The explicit undo group makes that
    /// atomicity independent of AppKit's typing coalescing.
    private func apply(_ result: (text: String, selection: NSRange)) {
        guard let edit = TodoEngine.minimalEdit(from: string, to: result.text) else {
            setSelectedRange(result.selection)
            return
        }
        undoManager?.beginUndoGrouping()
        defer { undoManager?.endUndoGrouping() }
        replace(range: edit.range, with: edit.replacement, selection: result.selection)
    }

    /// The one mutation channel: undo-aware, notification-emitting (so the
    /// controller's debounced write to disk still fires), and carrying the
    /// typing attributes so an edit at the start of an empty pad keeps the pad's
    /// font instead of the layout manager's default.
    private func replace(range: NSRange, with text: String, selection: NSRange) {
        guard shouldChangeText(in: range, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: range,
                                       with: NSAttributedString(string: text,
                                                                attributes: typingAttributes))
        didChangeText()
        setSelectedRange(selection)
        scrollRangeToVisible(selection)
    }
}

/// Title-bar button with a pointing-hand cursor: these sit in the title bar,
/// which is otherwise a drag handle, so the cursor is the only thing that says
/// "button". Shared by the to-do toggle and the pin.
private final class ScratchpadTitlebarButton: NSButton {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
