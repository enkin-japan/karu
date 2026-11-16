import AppKit

/// Settings › Scratchpad: the global hot-key recorder (T15.1) and the pad's
/// own font size (T15.3).
@MainActor
final class ScratchpadSettingsPage: NSObject, SettingsPage {
    let view: NSView
    var onContentSizeChange: (() -> Void)?

    private let form = SettingsForm()
    private var hotkeyButton: NSButton!
    private var hotkeyResetButton: NSButton!
    private let fontSize = SettingsForm.numberField(min: Int(EditorFontSettings.minFontSize),
                                                    max: Int(EditorFontSettings.maxFontSize), unit: "pt")

    /// The local key monitor installed while recording, or `nil`. Removing it is
    /// mandatory on *every* exit from the recording state (captured, cancelled,
    /// page left, window closed) — a leaked monitor would swallow keystrokes app-wide.
    private var hotkeyMonitor: Any?

    override init() {
        view = form.view
        super.init()

        // The recorder button shows the current binding and turns into a
        // "press the keys" prompt while armed.
        hotkeyButton = SettingsForm.button("settings.scratchpadHotkey", target: self, action: #selector(hotkeyButtonClicked(_:)))
        hotkeyResetButton = SettingsForm.button("settings.scratchpadHotkeyReset", target: self, action: #selector(hotkeyResetClicked(_:)))
        form.addRow(label: .prefScratchpadHotkeyLabel,
                    control: SettingsForm.equalWidthButtons([hotkeyButton, hotkeyResetButton]))

        // Writes through `ScratchpadStore` so the pad's size stays independent (T15.3).
        fontSize.field.identifier = NSUserInterfaceItemIdentifier("settings.scratchpadFontSize")
        fontSize.stepper.identifier = NSUserInterfaceItemIdentifier("settings.scratchpadFontSizeStepper")
        fontSize.onChange = { size in
            // Broadcasts `ScratchpadStore.fontDidChangeNotification`; a visible pad
            // re-applies the size live, a hidden one picks it up when next shown.
            ScratchpadStore.setFontSize(CGFloat(size))
        }
        form.addRow(label: .prefFontSizeLabel, control: SettingsForm.row(fontSize.views))

        hotkeyResetButton.title = L10n.t(.prefHotkeyReset)
        updateHotkeyButtonTitle()
        fontSizeDidChangeExternally()

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(languageDidChange), name: L10n.didChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(settingsImported), name: SettingsArchive.didImport, object: nil)
        center.addObserver(self, selector: #selector(updateHotkeyButtonTitle), name: HotKeyCenter.didChangeNotification, object: nil)
        // ⌘+ / ⌘- inside the scratchpad changes the pad's size; while the pad has
        // no size of its own it mirrors the editor's, so follow that too.
        center.addObserver(self, selector: #selector(fontSizeDidChangeExternally),
                           name: ScratchpadStore.fontDidChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(fontSizeDidChangeExternally),
                           name: EditorFontSettings.didChangeNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        // A local monitor outlives its installer, so it must never be left behind.
        if let hotkeyMonitor {
            NSEvent.removeMonitor(hotkeyMonitor)
            NotificationCenter.default.post(name: HotKeyCenter.recordingDidChange, object: false)
        }
    }

    /// Leaving the page, losing key or closing the window must not leave the
    /// recorder's monitor eating keystrokes.
    func pageWillDeactivate() {
        endHotkeyRecording()
        if fontSize.field.currentEditor() != nil { view.window?.makeFirstResponder(nil) }
    }

    @objc func languageDidChange() {
        form.reloadLabels()
        hotkeyResetButton.title = L10n.t(.prefHotkeyReset)
        // Keep the "press new shortcut…" prompt when the switch happened mid-record.
        if hotkeyMonitor != nil {
            hotkeyButton.title = L10n.t(.prefHotkeyRecording)
            hotkeyButton.toolTip = hotkeyButton.title
        } else {
            updateHotkeyButtonTitle()
        }
        onContentSizeChange?()
    }

    @objc private func settingsImported() {
        updateHotkeyButtonTitle()
        fontSizeDidChangeExternally()
    }

    @objc private func fontSizeDidChangeExternally() {
        fontSize.setValue(Int(ScratchpadStore.fontSize().rounded()))
    }

    // MARK: - Hot-key recorder (T15.1)

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
        NotificationCenter.default.post(name: HotKeyCenter.recordingDidChange, object: true)
        hotkeyButton.title = L10n.t(.prefHotkeyRecording)
        // The prompt can be longer than the button in some languages.
        hotkeyButton.toolTip = hotkeyButton.title
        hotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.view.window, event.window === window else { return event }
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
        guard let stroke = ShortcutStroke(event: event),
              let command = ShortcutSettings.shared.commands.first(where: { $0.id == ShortcutSettings.globalID }) else { return true }
        let conflicts = ShortcutSettings.shared.set([stroke], for: command)
        endHotkeyRecording()
        showShortcutConflicts(conflicts)
        return true
    }

    /// The single exit from the recording state: removes the monitor (always) and
    /// puts the current binding back on the button.
    private func endHotkeyRecording() {
        if let hotkeyMonitor {
            NSEvent.removeMonitor(hotkeyMonitor)
            NotificationCenter.default.post(name: HotKeyCenter.recordingDidChange, object: false)
        }
        hotkeyMonitor = nil
        updateHotkeyButtonTitle()
    }

    @objc private func updateHotkeyButtonTitle() {
        hotkeyButton.toolTip = nil
        guard let command = ShortcutSettings.shared.commands.first(where: { $0.id == ShortcutSettings.globalID }) else { return }
        let binding = ShortcutSettings.shared.binding(for: command)
        hotkeyButton.title = binding.isEmpty ? L10n.t(.shortcutNone) : binding.map(\.display).joined(separator: " ")
    }

    private func showShortcutConflicts(_ conflicts: [ShortcutCommand]) {
        guard !conflicts.isEmpty, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = L10n.t(.shortcutConflict, conflicts.map(\.title).joined(separator: ", "))
        alert.beginSheetModal(for: window)
    }

    @objc private func hotkeyResetClicked(_ sender: NSButton) {
        endHotkeyRecording()
        guard let command = ShortcutSettings.shared.commands.first(where: { $0.id == ShortcutSettings.globalID }) else { return }
        showShortcutConflicts(ShortcutSettings.shared.reset(command))
        updateHotkeyButtonTitle()
    }
}
