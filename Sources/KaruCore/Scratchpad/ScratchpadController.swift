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

    /// True when the pad is the key window — the state in which the zoom keys
    /// must resize the pad and not the shared editor size (see the app
    /// delegate's `zoomTargetsScratchpad`).
    var isKeyPanel: Bool { panel?.isKeyWindow == true }

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
        NotificationCenter.default.removeObserver(self, name: ScratchpadStore.fontDidChangeNotification, object: nil)
        panel.delegate = nil
        self.panel = nil
        textView = nil
        pinButton = nil
        gutterView = nil
        findBar = nil
        observerHub = nil
        shrinkRepaint = nil
        panel.orderOut(nil)
        restorePreviousAppIfNeeded()
    }

    /// Writes the current text right now if the panel is up. Called while the
    /// app is being torn down, where a debounced write would never fire.
    public func flushIfVisible() {
        guard panel != nil else { return }
        cancelFlush()
        flushNow()
    }

    /// Experiment flag (T15.6): when set, summoning the pad *activates* Karu
    /// (and hiding it hands focus back to the previous app).
    ///
    /// Why it exists: over another app's full-screen Space the input method's
    /// candidate bar never appears in the pad — the candidate window attaches
    /// to the *active* app's input focus, and a non-activating panel keeps Karu
    /// inactive by design. Whether a programmatic activate fixes the candidates
    /// without yanking the user off the full-screen Space (the way ⌘Tab does —
    /// an app *switch* follows the app's windows to their Space, an in-place
    /// activate should not, since the key panel is already on every Space) can
    /// only be answered with a real input method on a real full-screen Space,
    /// so it ships as a flag for that field test before becoming behaviour.
    public static let activateOnShowKey = "scratchpad.activateOnShow"

    /// The app that was frontmost before the pad activated Karu (experiment
    /// flag above); focus is handed back to it on hide.
    private var previousApp: NSRunningApplication?

    /// A non-activating panel can become key *without* activating Karu, which is
    /// what makes the pad feel like an overlay: type into it, hide it, and the
    /// app you were in still has focus. `orderFrontRegardless` is needed because
    /// an inactive app's `orderFront` is otherwise deferred until it activates.
    private func presentPanel(_ panel: NSPanel) {
        if UserDefaults.standard.bool(forKey: Self.activateOnShowKey), !NSApp.isActive {
            previousApp = NSWorkspace.shared.frontmostApplication
            NSApp.activate(ignoringOtherApps: true)
        }
        panel.orderFrontRegardless()
        panel.makeKey()
        if let textView { panel.makeFirstResponder(textView) }
    }

    /// Undoes the experiment's activation: Karu got focus only to host the pad,
    /// so hiding the pad returns focus to where the user actually was.
    private func restorePreviousAppIfNeeded() {
        guard let previousApp else { return }
        self.previousApp = nil
        if NSApp.isActive {
            previousApp.activate()
        }
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

        // The pin rides in the (standard) title bar's trailing corner.
        let accessory = NSTitlebarAccessoryViewController()
        let pinContainer = NSView(frame: NSRect(x: 0, y: 0, width: 34, height: 24))
        let pin = makePinButton()
        pin.frame = NSRect(x: 3, y: 2, width: 24, height: 20)
        pinContainer.addSubview(pin)
        accessory.view = pinContainer
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
        let button = ScratchpadPinButton(image: NSImage(), target: self, action: #selector(togglePinned(_:)))
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

/// The pad's text view. Adds a handful of behaviours to a plain `NSTextView`:
/// Esc closes the find bar or hides the panel, ⌘S graduates the text into a
/// file, ⌘F opens find / replace, and the zoom keys resize the pad alone.
private final class ScratchpadTextView: NSTextView {
    weak var controller: ScratchpadController?

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
        if let zoom = ScratchpadController.zoomCommand(
            modifiers: event.modifierFlags,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers) {
            controller?.zoom(zoom)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Pin toggle with a pointing-hand cursor: it sits in the title bar, which is
/// otherwise a drag handle, so the cursor is the only thing that says "button".
private final class ScratchpadPinButton: NSButton {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
