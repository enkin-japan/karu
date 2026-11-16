import AppKit
import UniformTypeIdentifiers

/// Settings › General: UI language, auto-save on focus loss, default file
/// applications (sheet) and settings export / import.
@MainActor
final class GeneralSettingsPage: NSObject, SettingsPage {
    let view: NSView
    var onContentSizeChange: (() -> Void)?

    private let form = SettingsForm()
    private let uiLanguagePopup = NSPopUpButton()
    private var autoSaveButton: NSButton!
    private var fileDefaultsButton: NSButton!
    private var exportButton: NSButton!
    private var importButton: NSButton!
    private let settingsResult = SettingsForm.helpLabel("")
    /// Held only while its sheet is up.
    private var fileDefaultsController: DefaultApplicationPreferencesController?

    override init() {
        view = form.view
        super.init()

        uiLanguagePopup.addItem(withTitle: L10n.t(.prefLanguageSystem))
        for language in AppLanguage.allCases {
            uiLanguagePopup.addItem(withTitle: language.displayName)
        }
        uiLanguagePopup.target = self
        uiLanguagePopup.action = #selector(uiLanguageChanged(_:))
        uiLanguagePopup.identifier = NSUserInterfaceItemIdentifier("settings.uiLanguage")
        form.addRow(label: .prefLanguageLabel, control: uiLanguagePopup)

        form.addSeparator()
        autoSaveButton = SettingsForm.checkbox("settings.autoSave", target: self, action: #selector(autoSaveToggled(_:)))
        form.addRow(label: nil, control: autoSaveButton)

        form.addSeparator()
        fileDefaultsButton = SettingsForm.button("settings.fileDefaults", target: self, action: #selector(showFileDefaults))
        form.addRow(label: nil, control: fileDefaultsButton)

        form.addSeparator()
        exportButton = SettingsForm.button("settings.export", target: self, action: #selector(exportSettings))
        importButton = SettingsForm.button("settings.import", target: self, action: #selector(importSettings))
        form.addRow(label: nil, control: SettingsForm.equalWidthButtons([exportButton, importButton]))
        settingsResult.identifier = NSUserInterfaceItemIdentifier("settings.backupResult")
        form.addRow(label: nil, control: settingsResult)

        reloadStrings()
        loadState()

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(languageDidChange), name: L10n.didChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(settingsImported), name: SettingsArchive.didImport, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func reloadStrings() {
        autoSaveButton.title = L10n.t(.prefAutoSaveOnFocusLoss)
        fileDefaultsButton.title = L10n.t(.fileDefaultsTitle)
        exportButton.title = L10n.t(.settingsExport)
        importButton.title = L10n.t(.settingsImport)
        // Language names stay in their own tongue; only "System" follows the UI.
        let selected = uiLanguagePopup.indexOfSelectedItem
        uiLanguagePopup.item(at: 0)?.title = L10n.t(.prefLanguageSystem)
        uiLanguagePopup.selectItem(at: selected)
    }

    private func loadState() {
        selectCurrentUILanguage()
        autoSaveButton.state = AutoSavePolicy.defaultEnabled ? .on : .off
    }

    /// Selects the popup row matching the stored UI-language override, or "System"
    /// (row 0) when no override is set.
    private func selectCurrentUILanguage() {
        if let raw = UserDefaults.standard.string(forKey: L10n.defaultsKey),
           let language = AppLanguage(rawValue: raw),
           let index = AppLanguage.allCases.firstIndex(of: language) {
            uiLanguagePopup.selectItem(at: index + 1)   // +1 for the System row
        } else {
            uiLanguagePopup.selectItem(at: 0)
        }
    }

    @objc func languageDidChange() {
        settingsResult.stringValue = ""
        form.reloadLabels()
        reloadStrings()
        onContentSizeChange?()
    }

    @objc private func settingsImported() {
        setResult(L10n.t(.settingsImported))
        loadState()
    }

    private func setResult(_ text: String) {
        settingsResult.stringValue = text
        onContentSizeChange?()
    }

    // MARK: - Actions

    /// Row 0 is "System" (clears the override); rows 1… map to
    /// `AppLanguage.allCases`. `L10n.set` persists and broadcasts, driving the
    /// live relayout of this window and every open editor.
    @objc private func uiLanguageChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        if index <= 0 {
            L10n.set(nil)
        } else {
            L10n.set(AppLanguage.allCases[index - 1])
        }
    }

    @objc private func autoSaveToggled(_ sender: NSButton) {
        // Read live from UserDefaults by each window's focus-loss handler, so no
        // per-editor push is needed — just persist the flag.
        UserDefaults.standard.set(sender.state == .on, forKey: AutoSavePolicy.enabledKey)
    }

    @objc private func showFileDefaults() {
        guard fileDefaultsController == nil else { return }
        let controller = DefaultApplicationPreferencesController()
        controller.onClose = { [weak self] in self?.fileDefaultsController = nil }
        fileDefaultsController = controller
        SettingsSheet.present(controller, on: view.window) { [weak self] in self?.fileDefaultsController = nil }
    }

    @objc private func exportSettings() {
        guard let window = view.window else { return }
        do {
            let data = try SettingsArchive.export()
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "Karu-settings.json"
            panel.beginSheetModal(for: window) { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                do {
                    try data.write(to: url, options: .atomic)
                    self?.setResult(L10n.t(.settingsExported))
                }
                catch { self?.presentSettingsError(error) }
            }
        } catch { presentSettingsError(error) }
    }

    @objc private func importSettings() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                let document = try SettingsArchive.read(from: url)
                let alert = NSAlert()
                alert.messageText = L10n.t(.settingsImport)
                alert.informativeText = L10n.t(.settingsImportConfirm)
                alert.addButton(withTitle: L10n.t(.settingsImportAction))
                alert.addButton(withTitle: L10n.t(.shortcutCancel))
                alert.beginSheetModal(for: window) { [weak self] result in
                    guard result == .alertFirstButtonReturn else { return }
                    do { try SettingsArchive.apply(document) }
                    catch { self?.presentSettingsError(error) }
                }
            } catch { self.presentSettingsError(error) }
        }
    }

    private func presentSettingsError(_ error: Error) {
        setResult("")
        guard let window = view.window else { return }
        NSAlert(error: error).beginSheetModal(for: window)
    }
}
