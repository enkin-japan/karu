import AppKit

/// Settings › Editing: editor font size, per-language indent width, Tab inserts
/// spaces, indent rainbow and auto-closing pairs. Settings that affect open
/// windows are pushed to every live `EditorTextView` so the effect is visible
/// without reopening.
@MainActor
final class EditingSettingsPage: NSObject, SettingsPage {
    let view: NSView
    var onContentSizeChange: (() -> Void)?

    private let form = SettingsForm()
    private let fontSize = SettingsForm.numberField(min: Int(EditorFontSettings.minFontSize),
                                                    max: Int(EditorFontSettings.maxFontSize), unit: "pt")
    private let languagePopup = NSPopUpButton()
    private let indentWidth = SettingsForm.numberField(min: 2, max: 8)
    private var usesSpacesButton: NSButton!
    private var rainbowButton: NSButton!
    private var autoCloseButton: NSButton!

    /// Languages offered in the indent-width popup (identifiers match those the
    /// highlighter resolves and `IndentSettings` keys on).
    private static let languages: [(id: String, title: String)] = [
        ("markdown", "Markdown"),
        ("json", "JSON"),
        ("jsonl", "JSONL"),
        ("xml", "XML / plist"),
        ("html", "HTML"),
        ("css", "CSS"),
        ("javascript", "JavaScript"),
        ("typescript", "TypeScript"),
        ("typescriptreact", "TypeScript JSX"),
        ("python", "Python"),
        ("c", "C"),
        ("cpp", "C++"),
        ("csharp", "C#"),
        ("java", "Java"),
        ("bash", "Bash"),
        ("sql", "SQL"),
    ]

    /// Indent-width languages that are visible in the shared language list
    /// (T16.2 follow-up: the popup used to list every language regardless).
    /// Falls back to the full list if everything offered here is hidden.
    static func indentLanguages(settings: LanguageMenuSettings = LanguageMenuSettings()) -> [(id: String, title: String)] {
        let visible = languages.filter { settings.isVisible($0.id) }
        return visible.isEmpty ? languages : visible
    }

    override init() {
        view = form.view
        super.init()

        fontSize.field.identifier = NSUserInterfaceItemIdentifier("settings.fontSize")
        fontSize.stepper.identifier = NSUserInterfaceItemIdentifier("settings.fontSizeStepper")
        fontSize.onChange = { size in
            // `setFontSize` broadcasts `EditorFontSettings.didChangeNotification`, which
            // every open editor window observes to re-apply the size live (new windows
            // read the value at creation time).
            EditorFontSettings().setFontSize(CGFloat(size))
        }
        form.addRow(label: .prefFontSizeLabel, control: SettingsForm.row(fontSize.views))

        form.addSeparator()
        rebuildIndentLanguagePopup()
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged(_:))
        languagePopup.identifier = NSUserInterfaceItemIdentifier("settings.indentLanguage")
        indentWidth.field.identifier = NSUserInterfaceItemIdentifier("settings.indentWidth")
        indentWidth.stepper.identifier = NSUserInterfaceItemIdentifier("settings.indentWidthStepper")
        indentWidth.onChange = { [weak self] width in self?.indentWidthChanged(width) }
        form.addRow(label: .prefIndentWidthLabel, control: SettingsForm.row([languagePopup] + indentWidth.views))
        usesSpacesButton = SettingsForm.checkbox("settings.usesSpaces", target: self, action: #selector(usesSpacesToggled(_:)))
        form.addRow(label: nil, control: usesSpacesButton)
        rainbowButton = SettingsForm.checkbox("settings.indentRainbow", target: self, action: #selector(rainbowToggled(_:)))
        form.addRow(label: nil, control: rainbowButton)

        form.addSeparator()
        autoCloseButton = SettingsForm.checkbox("settings.autoClosePairs", target: self, action: #selector(autoCloseToggled(_:)))
        form.addRow(label: nil, control: autoCloseButton)

        reloadStrings()
        loadState()

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(languageDidChange), name: L10n.didChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(settingsImported), name: SettingsArchive.didImport, object: nil)
        center.addObserver(self, selector: #selector(indentLanguagesChanged),
                           name: LanguageMenuSettings.didChangeNotification, object: nil)
        // A View ▸ Zoom command changes the font size behind this window's back;
        // refresh the field so the page never shows a stale value.
        center.addObserver(self, selector: #selector(fontSizeDidChangeExternally),
                           name: EditorFontSettings.didChangeNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func reloadStrings() {
        usesSpacesButton.title = L10n.t(.prefInsertSpaces)
        rainbowButton.title = L10n.t(.prefIndentRainbow)
        autoCloseButton.title = L10n.t(.prefAutoClosePairs)
    }

    private func loadState() {
        usesSpacesButton.state = IndentSettings().usesSpaces ? .on : .off
        rainbowButton.state = IndentRainbow.defaultEnabled ? .on : .off
        autoCloseButton.state = AutoClosePairs.defaultEnabled ? .on : .off
        reloadIndentWidth()
        fontSizeDidChangeExternally()
    }

    func pageWillDeactivate() {
        // Commit a number being typed.
        if fontSize.field.currentEditor() != nil || indentWidth.field.currentEditor() != nil {
            view.window?.makeFirstResponder(nil)
        }
    }

    @objc func languageDidChange() {
        form.reloadLabels()
        reloadStrings()
        onContentSizeChange?()
    }

    @objc private func settingsImported() {
        let language = selectedLanguage
        rebuildIndentLanguagePopup(selecting: language)
        loadState()
    }

    // MARK: - Indent width

    private var selectedLanguage: String {
        languagePopup.selectedItem?.representedObject as? String ?? Self.languages[0].id
    }

    /// Rebuilds the indent-width popup from the language list, keeping
    /// `selecting` (default: the current choice) when it is still offered.
    private func rebuildIndentLanguagePopup(selecting language: String? = nil) {
        let keep = language ?? (languagePopup.numberOfItems > 0 ? selectedLanguage : nil)
        languagePopup.removeAllItems()
        for lang in Self.indentLanguages() {
            languagePopup.addItem(withTitle: lang.title)
            languagePopup.lastItem?.representedObject = lang.id
        }
        if let keep, let item = languagePopup.itemArray.first(where: { $0.representedObject as? String == keep }) {
            languagePopup.select(item)
        } else {
            languagePopup.selectItem(at: 0)
        }
    }

    @objc private func indentLanguagesChanged() {
        rebuildIndentLanguagePopup()
        reloadIndentWidth()
        onContentSizeChange?()
    }

    private func reloadIndentWidth() {
        indentWidth.setValue(IndentSettings().width(for: selectedLanguage))
    }

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        reloadIndentWidth()
    }

    private func indentWidthChanged(_ width: Int) {
        UserDefaults.standard.set(width, forKey: IndentSettings.widthKey(for: selectedLanguage))
        // Indent width feeds the rainbow block computation; repaint open editors.
        forEachEditorTextView { $0.needsDisplay = true }
    }

    // MARK: - Toggles

    @objc private func usesSpacesToggled(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: IndentSettings.usesSpacesKey)
    }

    @objc private func rainbowToggled(_ sender: NSButton) {
        let enabled = sender.state == .on
        UserDefaults.standard.set(enabled, forKey: IndentRainbow.enabledKey)
        // Push to open editors so the toggle is visible immediately.
        forEachEditorTextView { $0.indentRainbowEnabled = enabled }
    }

    @objc private func autoCloseToggled(_ sender: NSButton) {
        let enabled = sender.state == .on
        UserDefaults.standard.set(enabled, forKey: AutoClosePairs.enabledKey)
        // Push to open editors so the toggle takes effect without reopening.
        forEachEditorTextView { $0.autoClosePairsEnabled = enabled }
    }

    /// Re-reads the shared font size after a zoom command changed it outside this window.
    @objc private func fontSizeDidChangeExternally() {
        fontSize.setValue(Int(EditorFontSettings().fontSize.rounded()))
    }
}
