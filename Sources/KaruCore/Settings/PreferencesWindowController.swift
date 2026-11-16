import AppKit

/// The pages of the Settings window, in toolbar order.
enum SettingsPageID: String, CaseIterable {
    case general, editing, code, run, scratchpad, shortcuts

    var title: String {
        switch self {
        case .general: return L10n.t(.settingsTabGeneral)
        case .editing: return L10n.t(.settingsTabEditing)
        case .code: return L10n.t(.settingsTabCode)
        case .run: return L10n.t(.settingsTabRun)
        case .scratchpad: return L10n.t(.scratchpadTitle)
        case .shortcuts: return L10n.t(.settingsTabShortcuts)
        }
    }

    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .editing: return "pencil"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .run: return "play"
        case .scratchpad: return "note.text"
        case .shortcuts: return "keyboard"
        }
    }

    var toolbarIdentifier: NSToolbarItem.Identifier {
        NSToolbarItem.Identifier("settings." + rawValue)
    }

    init?(toolbarIdentifier: NSToolbarItem.Identifier) {
        guard let id = Self.allCases.first(where: { $0.toolbarIdentifier == toolbarIdentifier }) else { return nil }
        self = id
    }
}

/// The settings window itself: closes on Esc (checkboxes / steppers / popups
/// never consume that key, so it always reaches the window's `keyDown`).
private final class PreferencesWindow: NSWindow {
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            performClose(nil)
            return
        }
        super.keyDown(with: event)
    }
}

/// Settings: one preference-style window whose toolbar switches between pages
/// (General, Editing, Code, Run, Scratchpad, Shortcuts). Pages are built on
/// first selection and cached until the window closes; the window resizes to
/// each page's fitting size, keeping its top edge and horizontal centre.
///
/// All changes persist immediately through `UserDefaults`; each page writes its
/// own settings and pushes live changes to open editors.
public final class PreferencesWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {

    /// The page shown last, remembered for the app session only.
    static var lastSelected: SettingsPageID = .general

    /// Called from `windowWillClose`, after the current page was deactivated.
    public var onClose: (() -> Void)?

    /// Builds a page on first selection. Tests inject stubs.
    var makePage: (SettingsPageID) -> SettingsPage

    private(set) var selectedPage: SettingsPageID
    private var pages: [SettingsPageID: SettingsPage] = [:]
    private let container = NSView()

    public convenience init() {
        self.init(makePage: nil)
    }

    init(makePage: ((SettingsPageID) -> SettingsPage)?) {
        self.makePage = makePage ?? Self.makeDefaultPage
        selectedPage = Self.lastSelected
        let window = PreferencesWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .preference
        window.contentView = container
        super.init(window: window)
        window.delegate = self

        let toolbar = NSToolbar(identifier: "KaruSettingsToolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.displayMode = .iconAndLabel
        window.toolbar = toolbar

        showPage(selectedPage)
        window.center()

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(languageDidChange), name: L10n.didChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(settingsImported), name: SettingsArchive.didImport, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    static func makeDefaultPage(_ id: SettingsPageID) -> SettingsPage {
        switch id {
        case .general: return GeneralSettingsPage()
        case .editing: return EditingSettingsPage()
        case .code: return CodeSettingsPage()
        case .run: return RunPreferencesController()
        case .scratchpad: return ScratchpadSettingsPage()
        case .shortcuts: return ShortcutPreferencesController()
        }
    }

    // MARK: - Pages

    /// The page `id` if it was built (selected at least once since the window opened).
    func loadedPage(_ id: SettingsPageID) -> SettingsPage? { pages[id] }

    /// Shows page `id` (a no-op when it already shows).
    func select(_ id: SettingsPageID) {
        if id == selectedPage, let page = pages[id], page.view.superview === container { return }
        showPage(id)
    }

    private func showPage(_ id: SettingsPageID) {
        if let current = pages[selectedPage], current.view.superview === container {
            current.pageWillDeactivate()
            current.view.removeFromSuperview()
        }
        let page = pages[id] ?? loadPage(id)
        selectedPage = id
        Self.lastSelected = id
        window?.toolbar?.selectedItemIdentifier = id.toolbarIdentifier
        window?.title = id.title
        // Resize first (animated when visible), then install the new view, so
        // the old page never stretches and the new one never squeezes.
        fitWindow(to: page)
        install(page.view)
    }

    private func loadPage(_ id: SettingsPageID) -> SettingsPage {
        let page = makePage(id)
        page.onContentSizeChange = { [weak self, weak page] in
            guard let self, let page, self.pages[self.selectedPage] === page else { return }
            self.fitWindow(to: page)
        }
        pages[id] = page
        return page
    }

    /// Pins `view` to the container's edges. Trailing / bottom sit below
    /// required priority: the page's own required constraints decide its size
    /// and `fitWindow` sizes the window to match, so a resize in flight never
    /// fights the page's layout.
    private func install(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        let trailing = view.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        let bottom = view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        trailing.priority = .defaultHigh
        bottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            trailing,
            bottom,
        ])
    }

    /// Resizes the window to `page`'s fitting size, keeping the top edge and the
    /// horizontal centre, clamped into the screen's visible frame. Animated only
    /// while the window is visible.
    private func fitWindow(to page: SettingsPage) {
        guard let window else { return }
        // A page about to be installed is still detached (zero frame); only an
        // installed one needs a layout pass, `fittingSize` works either way.
        if page.view.window != nil { page.view.layoutSubtreeIfNeeded() }
        let size = page.view.fittingSize
        let current = window.frame
        let layout = window.contentLayoutRect
        var frame = NSRect(x: 0, y: 0,
                           width: size.width + (current.width - layout.width),
                           height: size.height + (current.height - layout.height))
        frame.origin = NSPoint(x: (current.midX - frame.width / 2).rounded(), y: current.maxY - frame.height)
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            if frame.maxX > visible.maxX { frame.origin.x = visible.maxX - frame.width }
            if frame.minX < visible.minX { frame.origin.x = visible.minX }
            if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.height }
            if frame.minY < visible.minY { frame.origin.y = min(visible.minY, visible.maxY - frame.height) }
        }
        guard frame != current else { return }
        window.setFrame(frame, display: window.isVisible, animate: window.isVisible)
    }

    public override func showWindow(_ sender: Any?) {
        // Reopened after a close released the pages: rebuild the current one.
        if pages.isEmpty { showPage(selectedPage) }
        super.showWindow(sender)
    }

    // MARK: - Toolbar

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsPageID.allCases.map(\.toolbarIdentifier)
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsPageID.allCases.map(\.toolbarIdentifier)
    }

    public func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsPageID.allCases.map(\.toolbarIdentifier)
    }

    public func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                        willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let id = SettingsPageID(toolbarIdentifier: itemIdentifier) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = id.title
        item.paletteLabel = id.title
        item.image = NSImage(systemSymbolName: id.symbolName, accessibilityDescription: id.title)
        item.target = self
        item.action = #selector(toolbarItemSelected(_:))
        return item
    }

    @objc private func toolbarItemSelected(_ sender: NSToolbarItem) {
        guard let id = SettingsPageID(toolbarIdentifier: sender.itemIdentifier) else { return }
        select(id)
    }

    // MARK: - Notifications

    /// Toolbar labels and the window title; each loaded page re-pulls its own
    /// strings and reports its new size.
    @objc func languageDidChange() {
        for item in window?.toolbar?.items ?? [] {
            guard let id = SettingsPageID(toolbarIdentifier: item.itemIdentifier) else { continue }
            item.label = id.title
            item.paletteLabel = id.title
        }
        window?.title = selectedPage.title
    }

    /// Pushes the imported editor flags to every open editor. Done here, not by
    /// the Editing page, which may not exist when an import happens.
    @objc private func settingsImported() {
        forEachEditorTextView {
            $0.indentRainbowEnabled = IndentRainbow.defaultEnabled
            $0.autoClosePairsEnabled = AutoClosePairs.defaultEnabled
            $0.needsDisplay = true
        }
    }

    // MARK: - Window delegate

    public func windowDidResignKey(_ notification: Notification) {
        pages[selectedPage]?.pageWillDeactivate()
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        pages[selectedPage]?.pageDidBecomeActive()
    }

    /// Deactivates the current page (stops key recording, commits edits), then
    /// releases every page so nothing (sheets, the toolchain manager) outlives
    /// the window.
    public func windowWillClose(_ notification: Notification) {
        if let page = pages[selectedPage] {
            page.pageWillDeactivate()
            page.view.removeFromSuperview()
        }
        pages.removeAll()
        onClose?()
    }
}
