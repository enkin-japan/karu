import AppKit

/// Builds and drives the main window's native `NSToolbar` (unified style).
///
/// The toolbar puts the settings users reach for most — language, indent width,
/// Format, the three feature-module switches, and a shortcut to full
/// Preferences — directly above the document instead of buried in the menu /
/// Settings window (user feedback #3, #5). It owns only lightweight AppKit
/// controls and forwards every real action to the `EditorWindowController`,
/// which remains the single place language / indent state actually changes.
@MainActor
final class EditorToolbarController: NSObject, NSToolbarDelegate, NSMenuDelegate {
    private weak var windowController: EditorWindowController?

    private let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let indentPopup = NSPopUpButton(frame: .zero, pullsDown: false)
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
    private static let indent = NSToolbarItem.Identifier("dev.enkin.toolbar.indent")
    private static let format = NSToolbarItem.Identifier("dev.enkin.toolbar.format")
    static let run = NSToolbarItem.Identifier("dev.enkin.toolbar.run")
    private static let title = NSToolbarItem.Identifier("dev.enkin.toolbar.title")
    private static let modules = NSToolbarItem.Identifier("dev.enkin.toolbar.modules")
    private static let settings = NSToolbarItem.Identifier("dev.enkin.toolbar.settings")

    private let moduleCenter: NotificationCenter

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
        LanguageMenuSettings(center: moduleCenter).menuLayout(current: nil)
            .populate(langMenu, autoTitle: L10n.t(.languageAuto), autoAction: nil,
                      autoTag: Self.autoLanguageTag, languageAction: nil)
        languagePopup.menu = langMenu
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged)
        languagePopup.toolTip = L10n.t(.menuLanguage)

        // Indent-width popup: 2 / 4 / 8 columns.
        for width in [2, 4, 8] {
            let item = NSMenuItem(title: "\(width)", action: nil, keyEquivalent: "")
            item.tag = width
            indentPopup.menu?.addItem(item)
        }
        indentPopup.target = self
        indentPopup.action = #selector(indentChanged)
        indentPopup.toolTip = L10n.t(.toolbarIndentTooltip)

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

    /// Refreshes the centre title capsule (name / dirty marker / visibility).
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
        indentPopup.toolTip = L10n.t(.toolbarIndentTooltip)
        formatButton.title = L10n.t(.formatAction)
        formatButton.toolTip = L10n.t(.menuFormatDocument)
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
        case indent: return L10n.t(.toolbarIndentLabel)
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

    @objc private func indentChanged(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem else { return }
        windowController?.setIndentWidth(item.tag)
        refreshIndent()
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
        refreshIndent()
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
    private func rebuildLanguageItemsIfNeeded(for wc: EditorWindowController) {
        guard let menu = languagePopup.menu else { return }
        let current: String? = wc.isLanguageAuto ? nil : wc.currentLanguageIdentifierValue
        let layout = LanguageMenuSettings(center: moduleCenter).menuLayout(current: current)
        guard LanguageMenuLayout.signature(of: menu) != layout.signature else { return }
        layout.populate(menu, autoTitle: L10n.t(.languageAuto), autoAction: nil,
                        autoTag: Self.autoLanguageTag, languageAction: nil)
    }

    func refreshIndent() {
        guard let wc = windowController else { return }
        let width = wc.currentEffectiveIndentWidth
        if indentPopup.menu?.items.contains(where: { $0.tag == width }) == true {
            indentPopup.selectItem(withTag: width)
        } else {
            indentPopup.select(nil)
        }
    }

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
                toolbar.insertItem(withItemIdentifier: Self.run, at: (formatIndex ?? 2) + 1)
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
        case Self.language: return viewItem(itemIdentifier, label: L10n.t(.menuLanguage), view: languagePopup)
        case Self.indent:   return viewItem(itemIdentifier, label: L10n.t(.toolbarIndentLabel), view: indentPopup)
        case Self.format:   return viewItem(itemIdentifier, label: L10n.t(.formatAction), view: formatButton)
        case Self.run:      return viewItem(itemIdentifier, label: L10n.t(.menuRunCode), view: runButton)
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
        return [Self.language, Self.indent, Self.format] + (runEnabled ? [Self.run] : []) +
            [.flexibleSpace, Self.title, .flexibleSpace, Self.modules, Self.settings]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.language, Self.indent, Self.format, Self.run,
         .flexibleSpace, Self.title, Self.modules, Self.settings]
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
