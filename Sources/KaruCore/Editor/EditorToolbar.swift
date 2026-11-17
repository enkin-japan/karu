import AppKit

/// Builds and drives the main window's native `NSToolbar` (unified style).
///
/// The toolbar puts the settings users reach for most — language, Format, Run,
/// the feature-module switches, and a shortcut to full Preferences — directly
/// above the document instead of buried in the menu / Settings window (user
/// feedback #3, #5). Indent width is set per language in Settings › Editing
/// only. It owns only lightweight AppKit controls and forwards every real
/// action to the `EditorWindowController`, which remains the single place
/// language state actually changes.
@MainActor
final class EditorToolbarController: NSObject, NSToolbarDelegate, NSMenuDelegate {
    private weak var windowController: EditorWindowController?

    private let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let formatButton = NSButton()
    /// Run / Stop (T16.3b). Present only while the `run` module is on.
    private let runButton = NSButton()
    private let modulePopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private let settingsButton = NSButton()

    /// Centre-of-titlebar filename capsule (T11.4). Owned here so it can be a
    /// toolbar item; its rename requests are forwarded to the window controller.
    let titleControl = TitleRenameControl()

    /// Sentinel tag marking the "Auto" language item (identifiers are strings on
    /// `representedObject`, so a tag keeps Auto unambiguous).
    private static let autoLanguageTag = -1

    private static let language = NSToolbarItem.Identifier("dev.enkin.toolbar.language")
    private static let format = NSToolbarItem.Identifier("dev.enkin.toolbar.format")
    static let run = NSToolbarItem.Identifier("dev.enkin.toolbar.run")
    private static let title = NSToolbarItem.Identifier("dev.enkin.toolbar.title")
    private static let modules = NSToolbarItem.Identifier("dev.enkin.toolbar.modules")
    private static let settings = NSToolbarItem.Identifier("dev.enkin.toolbar.settings")

    private let moduleCenter: NotificationCenter

    /// The left-hand configuration items (language, Format, Run) are drawn at
    /// 90% of the system toolbar size, each followed by a small gap, so the
    /// group reads as three separate controls instead of one crowded strip
    /// (user feedback, 2026-11-16). The toolbar fixes its controls' bezel
    /// height and resets their control size and font, so the reduction is a
    /// drawing scale on a container (`ScaledToolbarItemView`), not a smaller
    /// control.
    static let compactScale: CGFloat = 0.9
    /// Frame height at which a `.toolbar` bezel button matches the system
    /// toolbar's own controls (macOS 26+), before scaling.
    static let toolbarButtonHeight: CGFloat = 28
    /// Added after each compact item; with what is left of the bezels' own
    /// margins the visible gap comes to roughly 6–7 pt.
    static let compactGap: CGFloat = 4
    /// The padded containers of the compact items, by identifier (the toolbar
    /// asks for an item's view again whenever Run is re-inserted).
    private var compactContainers: [NSToolbarItem.Identifier: ScaledToolbarItemView] = [:]

    init(windowController: EditorWindowController,
         moduleCenter: NotificationCenter = .default) {
        self.windowController = windowController
        self.moduleCenter = moduleCenter
        super.init()
        buildControls()
        moduleCenter.addObserver(self, selector: #selector(moduleSettingsChanged),
                                 name: ModuleSettings.didChangeNotification, object: nil)
        moduleCenter.addObserver(self, selector: #selector(languageListChanged),
                                 name: LanguageMenuSettings.didChangeNotification, object: nil)
    }

    deinit {
        moduleCenter.removeObserver(self)
    }

    /// Attaches a fresh unified toolbar to `window` and syncs its controls.
    func install(in window: NSWindow) {
        let toolbar = NSToolbar(identifier: "dev.enkin.EditorToolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        refreshAll()
    }

    // MARK: - Control construction

    private func buildControls() {
        // Language popup: Auto, then one entry per visible language (T16.2).
        // Items are (re)built by `refreshLanguageSelection` from the shared
        // `LanguageMenuSettings`; populated here once so the popup has its
        // natural size before the toolbar item is created.
        let langMenu = NSMenu()
        // Items are enabled as built: the suggestion header must stay disabled,
        // everything else is always choosable.
        langMenu.autoenablesItems = false
        LanguageMenuSettings(center: moduleCenter).menuLayout(current: nil)
            .populate(langMenu, autoTitle: L10n.t(.languageAuto), autoAction: nil,
                      autoTag: Self.autoLanguageTag, languageAction: nil)
        languagePopup.menu = langMenu
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged)
        languagePopup.toolTip = L10n.t(.menuLanguage)

        formatButton.title = L10n.t(.formatAction)
        formatButton.image = NSImage(systemSymbolName: "wand.and.stars",
                                     accessibilityDescription: L10n.t(.formatAction))
        formatButton.imagePosition = .imageLeading
        formatButton.bezelStyle = .toolbar
        formatButton.target = self
        formatButton.action = #selector(formatTapped)
        formatButton.toolTip = L10n.t(.menuFormatDocument)

        runButton.imagePosition = .imageLeading
        runButton.bezelStyle = .toolbar
        runButton.target = self
        runButton.action = #selector(runTapped)
        applyRunButtonState(active: false)

        // Modules: a compact pull-down whose items toggle each feature module.
        let modMenu = NSMenu()
        modMenu.delegate = self
        let modTitle = NSMenuItem(title: L10n.t(.prefModules), action: nil, keyEquivalent: "")
        modMenu.addItem(modTitle)  // pull-down title row (not selectable as toggle)
        for module in FeatureModule.allCases {
            let item = NSMenuItem(title: module.displayName,
                                  action: #selector(moduleToggled), keyEquivalent: "")
            item.target = self
            item.representedObject = module.rawValue
            modMenu.addItem(item)
        }
        modulePopup.menu = modMenu
        modulePopup.toolTip = L10n.t(.toolbarFeatureModulesTooltip)

        settingsButton.image = NSImage(systemSymbolName: "gearshape",
                                       accessibilityDescription: L10n.t(.toolbarSettingsLabel))
        settingsButton.title = ""
        settingsButton.bezelStyle = .toolbar
        settingsButton.target = self
        settingsButton.action = #selector(settingsTapped)
        settingsButton.toolTip = L10n.t(.appSettings)

        // Filename capsule: rename requests flow back to the window controller,
        // the single place the document's URL actually changes.
        titleControl.onCommit = { [weak self] newName in
            self?.windowController?.renameFile(to: newName)
        }
    }

    /// Refreshes the centre title (name / dirty marker / rename availability).
    func updateTitle(fileName: String, hasFile: Bool, isDirty: Bool) {
        titleControl.configure(fileName: fileName, hasFile: hasFile, isDirty: isDirty)
    }

    /// Re-pulls tooltips, the Format button title, the module pull-down title, and
    /// the toolbar item labels after a UI-language switch. Language / module item
    /// titles themselves are refreshed on next open (language names stay in their
    /// own tongue; module names re-read via `menuNeedsUpdate` / rebuild).
    func reloadStrings() {
        languagePopup.toolTip = L10n.t(.menuLanguage)
        if let auto = languagePopup.menu?.items.first(where: { $0.tag == Self.autoLanguageTag }) {
            auto.title = L10n.t(.languageAuto)
        }
        // A suggestion section's header is localized; its signature carries
        // the title, so this rebuilds it when present.
        refreshLanguageSelection()
        formatButton.title = L10n.t(.formatAction)
        formatButton.toolTip = L10n.t(.menuFormatDocument)
        compactContainers[Self.format]?.controlDidChange()
        applyRunButtonState(active: windowController?.isRunActive ?? false)
        modulePopup.toolTip = L10n.t(.toolbarFeatureModulesTooltip)
        modulePopup.menu?.items.first?.title = L10n.t(.prefModules)
        for item in modulePopup.menu?.items ?? [] {
            guard let raw = item.representedObject as? String,
                  let module = FeatureModule(rawValue: raw) else { continue }
            item.title = module.displayName
        }
        settingsButton.toolTip = L10n.t(.appSettings)

        for item in windowController?.window?.toolbar?.items ?? [] {
            let label = Self.itemLabel(for: item.itemIdentifier)
            if let label { item.label = label; item.paletteLabel = label }
        }
    }

    private static func itemLabel(for identifier: NSToolbarItem.Identifier) -> String? {
        switch identifier {
        case language: return L10n.t(.menuLanguage)
        case format: return L10n.t(.formatAction)
        case run: return L10n.t(.menuRunCode)
        case modules: return L10n.t(.prefModules)
        case settings: return L10n.t(.toolbarSettingsLabel)
        default: return nil
        }
    }

    // MARK: - Actions

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem else { return }
        if item.tag == Self.autoLanguageTag {
            windowController?.chooseAutoLanguage()
        } else if let identifier = item.representedObject as? String {
            windowController?.chooseLanguage(identifier: identifier)
        }
    }

    @objc private func formatTapped() {
        windowController?.formatDocument(nil)
    }

    @objc private func runTapped() {
        guard let wc = windowController else { return }
        if wc.isRunActive { wc.stopRun(nil) } else { wc.runCode(nil) }
    }

    @objc private func moduleToggled(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let module = FeatureModule(rawValue: raw) else { return }
        let settings = ModuleSettings()
        settings.setEnabled(!settings.isEnabled(module), for: module)
        // Format availability tracks the `format` module.
        refreshFormatEnabled()
    }

    @objc private func settingsTapped() {
        NSApp.sendAction(#selector(AppDelegate.showPreferences(_:)), to: nil, from: self)
    }

    @objc private func moduleSettingsChanged() {
        refreshFormatEnabled()
        refreshRunButton()
    }

    @objc private func languageListChanged() {
        refreshLanguageSelection()
    }

    // MARK: - State sync

    /// Refreshes every toolbar control from current window / defaults state.
    /// Called on install and whenever the language changes.
    func refreshAll() {
        refreshLanguageSelection()
        refreshFormatEnabled()
        refreshRunButton()
    }

    func refreshLanguageSelection() {
        guard let wc = windowController else { return }
        rebuildLanguageItemsIfNeeded(for: wc)
        if wc.isLanguageAuto {
            languagePopup.selectItem(withTag: Self.autoLanguageTag)
        } else {
            let id = wc.currentLanguageIdentifierValue
            if let match = languagePopup.menu?.items.first(where: {
                ($0.representedObject as? String) == id
            }) {
                languagePopup.select(match)
            } else {
                languagePopup.selectItem(withTag: Self.autoLanguageTag)
            }
        }
    }

    /// Rebuilds the popup's items when the visible-language list (or a hidden
    /// manually chosen language that must stay selectable) changed. The hidden
    /// current language is appended after a separator so the popup never shows
    /// a wrong or blank title; it disappears again once the window moves on.
    /// While detection has suggestions for an undecided Auto document, they
    /// head the list in their own section (`LanguageMenuLayout.suggestions`).
    private func rebuildLanguageItemsIfNeeded(for wc: EditorWindowController) {
        guard let menu = languagePopup.menu else { return }
        let current: String? = wc.isLanguageAuto ? nil : wc.currentLanguageIdentifierValue
        let layout = LanguageMenuSettings(center: moduleCenter)
            .menuLayout(current: current, suggestions: wc.languageMenuSuggestions)
        let header = L10n.t(.languageSuggestionLabel)
        guard LanguageMenuLayout.signature(of: menu) != layout.signature(suggestionHeader: header) else { return }
        layout.populate(menu, autoTitle: L10n.t(.languageAuto), autoAction: nil,
                        autoTag: Self.autoLanguageTag, languageAction: nil,
                        suggestionHeader: header)
    }

    /// The language popup's menu (test support).
    var languagePopupMenu: NSMenu? { languagePopup.menu }

    func refreshFormatEnabled() {
        guard let wc = windowController else { return }
        let formatOn = ModuleSettings().isEnabled(.format)
        formatButton.isEnabled = formatOn &&
            FormatDispatch.supports(languageIdentifier: wc.currentLanguageIdentifierValue)
    }

    /// Inserts / removes the Run item with the `run` module and flips it
    /// between Run (▶) and Stop (■) with the window's run state.
    func refreshRunButton() {
        guard let wc = windowController else { return }
        if let toolbar = wc.window?.toolbar {
            let index = toolbar.items.firstIndex { $0.itemIdentifier == Self.run }
            if wc.isRunModuleEnabled, index == nil {
                let formatIndex = toolbar.items.firstIndex { $0.itemIdentifier == Self.format }
                toolbar.insertItem(withItemIdentifier: Self.run, at: (formatIndex ?? 1) + 1)
            } else if !wc.isRunModuleEnabled, let index {
                toolbar.removeItem(at: index)
            }
        }
        applyRunButtonState(active: wc.isRunActive)
    }

    private func applyRunButtonState(active: Bool) {
        let title = active ? L10n.t(.menuRunStop) : L10n.t(.menuRunCode)
        runButton.title = title
        runButton.image = NSImage(systemSymbolName: active ? "stop.fill" : "play.fill",
                                  accessibilityDescription: title)
        runButton.toolTip = title
        compactContainers[Self.run]?.controlDidChange()
    }

    // MARK: - NSMenuDelegate (module pull-down checkmarks)

    func menuNeedsUpdate(_ menu: NSMenu) {
        let settings = ModuleSettings()
        for item in menu.items {
            guard let raw = item.representedObject as? String,
                  let module = FeatureModule(rawValue: raw) else { continue }
            item.state = settings.isEnabled(module) ? .on : .off
        }
    }

    // MARK: - NSToolbarDelegate

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.language:
            return viewItem(itemIdentifier, label: L10n.t(.menuLanguage), view: compact(languagePopup, itemIdentifier))
        case Self.format:
            return viewItem(itemIdentifier, label: L10n.t(.formatAction), view: compact(formatButton, itemIdentifier))
        case Self.run:
            return viewItem(itemIdentifier, label: L10n.t(.menuRunCode), view: compact(runButton, itemIdentifier))
        case Self.title:    return viewItem(itemIdentifier, label: "", view: titleControl)
        case Self.modules:  return viewItem(itemIdentifier, label: L10n.t(.prefModules), view: modulePopup)
        case Self.settings: return viewItem(itemIdentifier, label: L10n.t(.toolbarSettingsLabel), view: settingsButton)
        default: return nil
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // The filename capsule is centred between two flexible spaces so it sits
        // roughly at the middle of the titlebar, VS Code style.
        let runEnabled = windowController?.isRunModuleEnabled ?? ModuleSettings().isEnabled(.run)
        return [Self.language, Self.format] + (runEnabled ? [Self.run] : []) +
            [.flexibleSpace, Self.title, .flexibleSpace, Self.modules, Self.settings]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.language, Self.format, Self.run,
         .flexibleSpace, Self.title, Self.modules, Self.settings]
    }

    /// Wraps a left-hand control in its scaled container. Built once per control.
    private func compact(_ control: NSControl, _ identifier: NSToolbarItem.Identifier) -> NSView {
        if let existing = compactContainers[identifier] { return existing }
        // Nested in a container, a control no longer gets the toolbar's own
        // metrics, so they are restated here: macOS 26+ toolbars put controls
        // at `.extraLarge` and stretch button bezels to the item height. At
        // that size a control's frame carries empty margin around the bezel
        // (about 8 pt a side on a button, 3 on a popup); the container trims
        // it so the visible gap between bezels is small and even.
        var minimumHeight: CGFloat = 0
        var inset: CGFloat = 0
        if #available(macOS 26.0, *) {
            control.controlSize = .extraLarge
            if control is NSPopUpButton {
                inset = 3
            } else {
                inset = 6
                minimumHeight = Self.toolbarButtonHeight
            }
        }
        let container = ScaledToolbarItemView(control: control, scale: Self.compactScale,
                                              trailingGap: Self.compactGap,
                                              minimumControlHeight: minimumHeight,
                                              horizontalInset: inset)
        compactContainers[identifier] = container
        return container
    }

    private func viewItem(_ identifier: NSToolbarItem.Identifier,
                          label: String, view: NSView) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.view = view
        return item
    }
}

/// Draws one control at `scale` and reserves `trailingGap` after it.
///
/// The view's bounds are scaled (`setBoundsSize`), so the control keeps its
/// natural frame in the container's coordinates and AppKit maps drawing, hit
/// testing and popup-menu placement through the scale. The control is laid
/// out by frame, not constraints: its natural size changes whenever the
/// toolbar assigns a control size or a title changes, and `layout()` picks
/// that up and re-announces the container's own size.
final class ScaledToolbarItemView: NSView {
    let control: NSControl
    private let scale: CGFloat
    private let trailingGap: CGFloat
    private let minimumControlHeight: CGFloat
    /// Empty margin trimmed from each side of the control's frame (the
    /// control is positioned that far outside the container's bounds).
    let horizontalInset: CGFloat
    private var measured = NSSize.zero

    /// The control's own size, never shorter than `minimumControlHeight`.
    var naturalSize: NSSize {
        let fitting = control.fittingSize
        return NSSize(width: fitting.width, height: max(fitting.height, minimumControlHeight))
    }

    init(control: NSControl, scale: CGFloat, trailingGap: CGFloat, minimumControlHeight: CGFloat = 0,
         horizontalInset: CGFloat = 0) {
        self.control = control
        self.scale = scale
        self.trailingGap = trailingGap
        self.minimumControlHeight = minimumControlHeight
        self.horizontalInset = horizontalInset
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = true
        control.autoresizingMask = []
        addSubview(control)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize {
        let natural = naturalSize
        return NSSize(width: ceil((natural.width - 2 * horizontalInset) * scale) + trailingGap,
                      height: ceil(natural.height * scale))
    }

    /// Call after changing the control's title or image.
    func controlDidChange() {
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let natural = naturalSize
        if natural != measured {
            measured = natural
            invalidateIntrinsicContentSize()
        }
        let scaled = NSSize(width: frame.width / scale, height: frame.height / scale)
        if abs(bounds.width - scaled.width) > 0.01 || abs(bounds.height - scaled.height) > 0.01 {
            setBoundsSize(scaled)
        }
        control.frame = NSRect(x: -horizontalInset, y: ((bounds.height - natural.height) / 2).rounded(),
                               width: natural.width, height: natural.height)
    }
}
