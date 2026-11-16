import AppKit

/// Settings › Code: the feature-module toggles (Run has its own page) and the
/// Language List / Project Folders sheets.
@MainActor
final class CodeSettingsPage: NSObject, SettingsPage {
    let view: NSView
    var onContentSizeChange: (() -> Void)?

    /// Modules toggled here; `.run` sits on the Run page.
    static let modules: [FeatureModule] = FeatureModule.allCases.filter { $0 != .run }

    private let form = SettingsForm()
    private let moduleSettings: ModuleSettings
    private var moduleButtons: [NSButton] = []
    private var languageListButton: NSButton!
    private var projectFoldersButton: NSButton!
    /// Held only while their sheets are up.
    private var languageListController: LanguageListPreferencesController?
    private var projectFoldersController: ProjectFoldersPreferencesController?

    init(modules: ModuleSettings = ModuleSettings()) {
        moduleSettings = modules
        view = form.view
        super.init()

        for (index, module) in Self.modules.enumerated() {
            let button = SettingsForm.checkbox("settings.module." + module.rawValue,
                                               target: self, action: #selector(moduleToggled(_:)))
            button.tag = index
            moduleButtons.append(button)
            form.addRow(label: index == 0 ? .prefModulesLabel : nil, control: button)
        }

        form.addSeparator()
        languageListButton = SettingsForm.button("settings.languageList", target: self, action: #selector(showLanguageList))
        projectFoldersButton = SettingsForm.button("settings.projectFolders", target: self, action: #selector(showProjectFolders))
        form.addRow(label: nil, control: SettingsForm.equalWidthButtons([languageListButton, projectFoldersButton]))

        reloadStrings()
        loadState()

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(languageDidChange), name: L10n.didChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(loadState), name: SettingsArchive.didImport, object: nil)
        // Toggles made from the editor toolbar's module menu show up live.
        center.addObserver(self, selector: #selector(loadState), name: ModuleSettings.didChangeNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func reloadStrings() {
        for (index, module) in Self.modules.enumerated() {
            moduleButtons[index].title = module.displayName
        }
        languageListButton.title = L10n.t(.languageListTitle)
        projectFoldersButton.title = L10n.t(.projectFoldersTitle)
    }

    @objc private func loadState() {
        for (index, module) in Self.modules.enumerated() {
            moduleButtons[index].state = moduleSettings.isEnabled(module) ? .on : .off
        }
    }

    @objc func languageDidChange() {
        form.reloadLabels()
        reloadStrings()
        onContentSizeChange?()
    }

    @objc private func moduleToggled(_ sender: NSButton) {
        guard Self.modules.indices.contains(sender.tag) else { return }
        // ModuleSettings broadcasts a change notification; the engines already
        // listen and attach or release state live.
        moduleSettings.setEnabled(sender.state == .on, for: Self.modules[sender.tag])
    }

    @objc private func showLanguageList() {
        guard languageListController == nil else { return }
        let controller = LanguageListPreferencesController()
        controller.onClose = { [weak self] in self?.languageListController = nil }
        languageListController = controller
        SettingsSheet.present(controller, on: view.window) { [weak self] in self?.languageListController = nil }
    }

    @objc private func showProjectFolders() {
        guard projectFoldersController == nil else { return }
        let controller = ProjectFoldersPreferencesController()
        controller.onClose = { [weak self] in self?.projectFoldersController = nil }
        projectFoldersController = controller
        SettingsSheet.present(controller, on: view.window) { [weak self] in self?.projectFoldersController = nil }
    }
}
