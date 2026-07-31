import AppKit

/// Single preferences window with two groups:
///
/// 1. **Modules** — on/off checkboxes for the toggleable feature modules
///    (`highlight` / `completion` / `format`), written through `ModuleSettings`.
///    The existing change-notification mechanism lets the engines attach / tear
///    down their runtime state live, so no extra wiring is needed here.
/// 2. **Editor** — per-language indent width, "Insert spaces for Tab", the
///    indent-rainbow toggle, and the editor font size.
///
/// All changes persist immediately through `UserDefaults`. Settings that affect
/// already-open windows (indent rainbow, indent width, font size) are pushed to
/// every live `EditorTextView` so the effect is visible without reopening.
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

public final class PreferencesWindowController: NSWindowController, NSWindowDelegate {

    // Module toggles, ordered to match `FeatureModule.allCases`.
    private var moduleButtons: [NSButton] = []

    // Editor controls.
    private let languagePopup = NSPopUpButton()
    private let indentStepper = NSStepper()
    private let indentValueLabel = NSTextField(labelWithString: "")
    private let usesSpacesButton = NSButton()
    private let rainbowButton = NSButton()
    private let autoCloseButton = NSButton()
    private let autoSaveButton = NSButton()
    private let fontStepper = NSStepper()
    private let fontValueLabel = NSTextField(labelWithString: "")

    // UI-language picker (System + the three app languages).
    private let uiLanguagePopup = NSPopUpButton()

    // Scratchpad hot-key recorder (T15.1).
    private let hotkeyButton = NSButton()
    private let hotkeyResetButton = NSButton()

    /// The local key monitor installed while recording, or `nil`. Removing it is
    /// mandatory on *every* exit from the recording state (captured, cancelled,
    /// window closed) — a leaked monitor would swallow keystrokes app-wide.
    private var hotkeyMonitor: Any?

    // Text labels re-pulled on a live language switch.
    private let modulesHeader = NSTextField(labelWithString: "")
    private let editorHeader = NSTextField(labelWithString: "")
    private let indentRowLabel = NSTextField(labelWithString: "")
    private let fontRowLabel = NSTextField(labelWithString: "")
    private let uiLanguageRowLabel = NSTextField(labelWithString: "")
    private let hotkeyRowLabel = NSTextField(labelWithString: "")

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
        ("python", "Python"),
        ("c", "C"),
        ("cpp", "C++"),
        ("csharp", "C#"),
        ("java", "Java"),
        ("bash", "Bash"),
        ("sql", "SQL"),
    ]

    public convenience init() {
        let window = PreferencesWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.t(.prefTitle)
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        // Only so a close can disarm the hot-key recorder (see windowWillClose);
        // everything else about the window's behaviour stays AppKit's default.
        window.delegate = self
        buildUI()
        loadState()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(languageDidChange),
            name: L10n.didChangeNotification,
            object: nil
        )
        // A View ▸ Zoom command changes the font size behind this window's back;
        // refresh the stepper / label so the panel never shows a stale value.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(fontSizeDidChangeExternally),
            name: EditorFontSettings.didChangeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        // A local monitor outlives its installer, so it must never be left behind.
        if let hotkeyMonitor { NSEvent.removeMonitor(hotkeyMonitor) }
    }

    // MARK: - UI construction

    private func buildUI() {
        // UI-language picker (System + three languages). Sits at the top with its
        // own "Language:" row label — no section header (the window title already
        // says Settings).
        uiLanguagePopup.removeAllItems()
        uiLanguagePopup.addItem(withTitle: L10n.t(.prefLanguageSystem))
        for language in AppLanguage.allCases {
            uiLanguagePopup.addItem(withTitle: language.displayName)
        }
        uiLanguagePopup.target = self
        uiLanguagePopup.action = #selector(uiLanguageChanged(_:))
        uiLanguageRowLabel.stringValue = L10n.t(.prefLanguageLabel)
        let languageRow = NSStackView(views: [uiLanguageRowLabel, uiLanguagePopup])
        languageRow.orientation = .horizontal
        languageRow.spacing = 8
        languageRow.alignment = .centerY

        styleSectionLabel(modulesHeader, text: L10n.t(.prefModules))
        let moduleStack = NSStackView()
        moduleStack.orientation = .vertical
        moduleStack.alignment = .leading
        moduleStack.spacing = 6
        for module in FeatureModule.allCases {
            let button = NSButton(checkboxWithTitle: module.displayName,
                                  target: self,
                                  action: #selector(moduleToggled(_:)))
            button.tag = moduleButtons.count
            moduleButtons.append(button)
            moduleStack.addArrangedSubview(button)
        }

        styleSectionLabel(editorHeader, text: L10n.t(.prefEditor))

        // Indent width row: language popup + stepper + value.
        for lang in Self.languages {
            languagePopup.addItem(withTitle: lang.title)
        }
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged(_:))

        indentStepper.minValue = 2
        indentStepper.maxValue = 8
        indentStepper.increment = 1
        indentStepper.valueWraps = false
        indentStepper.target = self
        indentStepper.action = #selector(indentWidthChanged(_:))
        indentValueLabel.alignment = .right
        indentValueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        indentValueLabel.setContentHuggingPriority(.required, for: .horizontal)

        indentRowLabel.stringValue = L10n.t(.prefIndentWidthLabel)
        let indentRow = NSStackView(views: [
            indentRowLabel,
            languagePopup, indentStepper, indentValueLabel,
        ])
        indentRow.orientation = .horizontal
        indentRow.spacing = 8
        indentRow.alignment = .centerY

        // Tab → spaces + indent rainbow checkboxes.
        usesSpacesButton.setButtonType(.switch)
        usesSpacesButton.title = L10n.t(.prefInsertSpaces)
        usesSpacesButton.target = self
        usesSpacesButton.action = #selector(usesSpacesToggled(_:))

        rainbowButton.setButtonType(.switch)
        rainbowButton.title = L10n.t(.prefIndentRainbow)
        rainbowButton.target = self
        rainbowButton.action = #selector(rainbowToggled(_:))

        autoCloseButton.setButtonType(.switch)
        autoCloseButton.title = L10n.t(.prefAutoClosePairs)
        autoCloseButton.target = self
        autoCloseButton.action = #selector(autoCloseToggled(_:))

        autoSaveButton.setButtonType(.switch)
        autoSaveButton.title = L10n.t(.prefAutoSaveOnFocusLoss)
        autoSaveButton.target = self
        autoSaveButton.action = #selector(autoSaveToggled(_:))

        // Font size row.
        fontStepper.minValue = Double(EditorFontSettings.minFontSize)
        fontStepper.maxValue = Double(EditorFontSettings.maxFontSize)
        fontStepper.increment = 1
        fontStepper.valueWraps = false
        fontStepper.target = self
        fontStepper.action = #selector(fontSizeChanged(_:))
        fontValueLabel.alignment = .right
        fontValueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        fontValueLabel.setContentHuggingPriority(.required, for: .horizontal)

        fontRowLabel.stringValue = L10n.t(.prefFontSizeLabel)
        let fontRow = NSStackView(views: [
            fontRowLabel,
            fontStepper, fontValueLabel,
        ])
        fontRow.orientation = .horizontal
        fontRow.spacing = 8
        fontRow.alignment = .centerY

        // Scratchpad hot-key row: the recorder button shows the current binding
        // and turns into a "press the keys" prompt while armed.
        hotkeyButton.bezelStyle = .rounded
        hotkeyButton.target = self
        hotkeyButton.action = #selector(hotkeyButtonClicked(_:))
        hotkeyResetButton.bezelStyle = .rounded
        hotkeyResetButton.title = L10n.t(.prefHotkeyReset)
        hotkeyResetButton.target = self
        hotkeyResetButton.action = #selector(hotkeyResetClicked(_:))
        hotkeyRowLabel.stringValue = L10n.t(.prefScratchpadHotkeyLabel)
        updateHotkeyButtonTitle()
        let hotkeyRow = NSStackView(views: [hotkeyRowLabel, hotkeyButton, hotkeyResetButton])
        hotkeyRow.orientation = .horizontal
        hotkeyRow.spacing = 8
        hotkeyRow.alignment = .centerY

        let content = NSStackView(views: [
            languageRow,
            separator(),
            modulesHeader, moduleStack,
            separator(),
            editorHeader, indentRow, usesSpacesButton, rainbowButton, autoCloseButton, autoSaveButton, fontRow,
            hotkeyRow,
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        content.translatesAutoresizingMaskIntoConstraints = false

        window?.contentView = content
    }

    private func styleSectionLabel(_ label: NSTextField, text: String) {
        label.stringValue = text
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 360).isActive = true
        return box
    }

    // MARK: - Loading current state

    private func loadState() {
        selectCurrentUILanguage()

        let modules = ModuleSettings()
        for (i, module) in FeatureModule.allCases.enumerated() {
            moduleButtons[i].state = modules.isEnabled(module) ? .on : .off
        }

        let indent = IndentSettings()
        usesSpacesButton.state = indent.usesSpaces ? .on : .off
        rainbowButton.state = IndentRainbow.defaultEnabled ? .on : .off
        autoCloseButton.state = AutoClosePairs.defaultEnabled ? .on : .off
        autoSaveButton.state = AutoSavePolicy.defaultEnabled ? .on : .off

        languagePopup.selectItem(at: 0)
        reloadIndentWidth()

        let size = EditorFontSettings().fontSize
        fontStepper.doubleValue = Double(size)
        updateFontLabel()
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

    private var selectedLanguage: String {
        let index = max(0, languagePopup.indexOfSelectedItem)
        return Self.languages[index].id
    }

    private func reloadIndentWidth() {
        let width = IndentSettings().width(for: selectedLanguage)
        indentStepper.integerValue = width
        indentValueLabel.stringValue = "\(width)"
    }

    private func updateFontLabel() {
        fontValueLabel.stringValue = "\(Int(fontStepper.doubleValue.rounded())) pt"
    }

    // MARK: - Actions

    @objc private func moduleToggled(_ sender: NSButton) {
        let module = FeatureModule.allCases[sender.tag]
        // ModuleSettings broadcasts a change notification; the highlight /
        // completion engines already listen and attach or release state live.
        ModuleSettings().setEnabled(sender.state == .on, for: module)
    }

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        reloadIndentWidth()
    }

    /// UI-language row: row 0 is "System" (clears the override); rows 1… map to
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

    /// Re-pulls every localized string after a language switch. Called from the
    /// `L10n.didChangeNotification` observer so the window updates in place.
    @objc private func languageDidChange() {
        window?.title = L10n.t(.prefTitle)
        styleSectionLabel(modulesHeader, text: L10n.t(.prefModules))
        styleSectionLabel(editorHeader, text: L10n.t(.prefEditor))
        uiLanguageRowLabel.stringValue = L10n.t(.prefLanguageLabel)
        indentRowLabel.stringValue = L10n.t(.prefIndentWidthLabel)
        fontRowLabel.stringValue = L10n.t(.prefFontSizeLabel)
        hotkeyRowLabel.stringValue = L10n.t(.prefScratchpadHotkeyLabel)
        hotkeyResetButton.title = L10n.t(.prefHotkeyReset)
        // Keep the "press new shortcut…" prompt when the switch happened mid-record.
        if hotkeyMonitor != nil { hotkeyButton.title = L10n.t(.prefHotkeyRecording) }
        usesSpacesButton.title = L10n.t(.prefInsertSpaces)
        rainbowButton.title = L10n.t(.prefIndentRainbow)
        autoCloseButton.title = L10n.t(.prefAutoClosePairs)
        autoSaveButton.title = L10n.t(.prefAutoSaveOnFocusLoss)
        for (i, module) in FeatureModule.allCases.enumerated() {
            moduleButtons[i].title = module.displayName
        }
        // Rebuild the language popup's "System" row (its language names stay in
        // their own tongue); keep the current selection.
        let selected = uiLanguagePopup.indexOfSelectedItem
        uiLanguagePopup.item(at: 0)?.title = L10n.t(.prefLanguageSystem)
        uiLanguagePopup.selectItem(at: selected)
    }

    @objc private func indentWidthChanged(_ sender: NSStepper) {
        let width = sender.integerValue
        UserDefaults.standard.set(width, forKey: IndentSettings.widthKey(for: selectedLanguage))
        indentValueLabel.stringValue = "\(width)"
        // Indent width feeds the rainbow block computation; repaint open editors.
        redrawOpenEditors()
    }

    @objc private func usesSpacesToggled(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: IndentSettings.usesSpacesKey)
    }

    @objc private func rainbowToggled(_ sender: NSButton) {
        let enabled = sender.state == .on
        UserDefaults.standard.set(enabled, forKey: IndentRainbow.enabledKey)
        // Push to open editors so the toggle is visible immediately.
        Self.forEachEditorTextView { $0.indentRainbowEnabled = enabled }
    }

    @objc private func autoCloseToggled(_ sender: NSButton) {
        let enabled = sender.state == .on
        UserDefaults.standard.set(enabled, forKey: AutoClosePairs.enabledKey)
        // Push to open editors so the toggle takes effect without reopening.
        Self.forEachEditorTextView { $0.autoClosePairsEnabled = enabled }
    }

    @objc private func autoSaveToggled(_ sender: NSButton) {
        // Read live from UserDefaults by each window's focus-loss handler, so no
        // per-editor push is needed — just persist the flag.
        UserDefaults.standard.set(sender.state == .on, forKey: AutoSavePolicy.enabledKey)
    }

    @objc private func fontSizeChanged(_ sender: NSStepper) {
        // `setFontSize` broadcasts `EditorFontSettings.didChangeNotification`, which
        // every open editor window observes to re-apply the size live (new windows
        // read the value at creation time). This panel updates its own label here.
        EditorFontSettings().setFontSize(CGFloat(sender.doubleValue))
        updateFontLabel()
    }

    /// Re-reads the shared font size into the stepper / label after a zoom command
    /// changed it outside this window.
    @objc private func fontSizeDidChangeExternally() {
        let size = EditorFontSettings().fontSize
        fontStepper.doubleValue = Double(size)
        updateFontLabel()
    }

    // MARK: - Scratchpad hot-key recorder (T15.1)

    /// Click once to arm, click again to give up. While armed a local key monitor
    /// takes over the keyboard for this window.
    @objc private func hotkeyButtonClicked(_ sender: NSButton) {
        if hotkeyMonitor != nil {
            endHotkeyRecording()
        } else {
            beginHotkeyRecording()
        }
    }

    private func beginHotkeyRecording() {
        hotkeyButton.title = L10n.t(.prefHotkeyRecording)
        hotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.captureHotkey(event) ? nil : event
        }
    }

    /// Returns true when the event was consumed by the recorder. Everything typed
    /// while armed is swallowed — including keys that are *not* a valid binding,
    /// which simply leave the recorder waiting rather than committing a shortcut
    /// the system would never deliver.
    private func captureHotkey(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 {   // Esc — give up, keep the old binding
            endHotkeyRecording()
            return true
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // A global hot key needs at least one of ⌘ / ⌥ / ⌃; ⇧ alone would make
        // every capital letter unusable everywhere else on the system.
        guard flags.contains(.command) || flags.contains(.option) || flags.contains(.control) else {
            return true
        }
        HotKeyCenter.store(keyCode: UInt32(event.keyCode),
                           carbonModifiers: HotKeyCenter.carbonModifiers(from: flags))
        NotificationCenter.default.post(name: HotKeyCenter.didChangeNotification, object: nil)
        endHotkeyRecording()
        return true
    }

    /// The single exit from the recording state: removes the monitor (always) and
    /// puts the current binding back on the button.
    private func endHotkeyRecording() {
        if let hotkeyMonitor { NSEvent.removeMonitor(hotkeyMonitor) }
        hotkeyMonitor = nil
        updateHotkeyButtonTitle()
    }

    private func updateHotkeyButtonTitle() {
        hotkeyButton.title = HotKeyCenter.displayString(
            keyCode: HotKeyCenter.storedKeyCode(),
            carbonModifiers: HotKeyCenter.storedModifiers())
    }

    @objc private func hotkeyResetClicked(_ sender: NSButton) {
        endHotkeyRecording()
        HotKeyCenter.resetToDefault()
        NotificationCenter.default.post(name: HotKeyCenter.didChangeNotification, object: nil)
        updateHotkeyButtonTitle()
    }

    /// Closing the window while the recorder is armed must not leave its monitor
    /// eating keystrokes for the rest of the session.
    public func windowWillClose(_ notification: Notification) {
        endHotkeyRecording()
    }

    // MARK: - Live application helpers

    private func redrawOpenEditors() {
        Self.forEachEditorTextView { $0.needsDisplay = true }
    }

    /// Walks every window's view tree and applies `body` to each `EditorTextView`.
    private static func forEachEditorTextView(_ body: (EditorTextView) -> Void) {
        for window in NSApp.windows {
            guard let content = window.contentView else { continue }
            for textView in editorTextViews(in: content) {
                body(textView)
            }
        }
    }

    private static func editorTextViews(in view: NSView) -> [EditorTextView] {
        var result: [EditorTextView] = []
        if let textView = view as? EditorTextView {
            result.append(textView)
        }
        for subview in view.subviews {
            result += editorTextViews(in: subview)
        }
        return result
    }
}
