import AppKit

/// Settings › Shortcuts page. Built when the page is first selected; leaving the
/// page, losing key or closing the window disarms the recorder. Command
/// definitions come from the same catalog used by menus and text-view routing.
@MainActor
final class ShortcutPreferencesController: NSObject, SettingsPage, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    /// Fixed page size.
    static let pageSize = NSSize(width: 720, height: 480)

    let view = NSView()
    var onContentSizeChange: (() -> Void)?
    private let settings: ShortcutSettings
    private let search = NSSearchField()
    private let table = NSTableView()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let record = NSButton()
    private let clear = NSButton()
    private let reset = NSButton()
    private let resetAll = NSButton()
    private let sequence = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var rows: [ShortcutCommand] = []
    private var monitor: Any?
    private var recordingID: String?
    private var captured: [ShortcutStroke] = []

    init(settings: ShortcutSettings? = nil) {
        self.settings = settings ?? .shared
        super.init()
        search.delegate = self
        let command = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
        command.width = 430
        let binding = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("binding"))
        binding.width = 230
        table.addTableColumn(command); table.addTableColumn(binding)
        table.delegate = self; table.dataSource = self
        table.target = self; table.doubleAction = #selector(startRecording)
        table.rowHeight = 28
        table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        for (button, action) in [(record, #selector(startRecording)), (clear, #selector(clearSelected)),
                                 (reset, #selector(resetSelected)), (resetAll, #selector(restoreAll))] {
            button.bezelStyle = .rounded; button.target = self; button.action = action
        }
        let actions = NSStackView(views: [record, sequence, clear, reset, resetAll])
        actions.spacing = 8
        message.textColor = .secondaryLabelColor
        message.preferredMaxLayoutWidth = Self.pageSize.width - 36
        let content = view
        content.translatesAutoresizingMaskIntoConstraints = false
        content.widthAnchor.constraint(equalToConstant: Self.pageSize.width).isActive = true
        content.heightAnchor.constraint(equalToConstant: Self.pageSize.height).isActive = true
        for view in [search, scroll, actions, message] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            search.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            search.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: search.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: search.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -12),
            actions.leadingAnchor.constraint(equalTo: search.leadingAnchor),
            actions.trailingAnchor.constraint(lessThanOrEqualTo: search.trailingAnchor),
            actions.bottomAnchor.constraint(equalTo: message.topAnchor, constant: -10),
            message.leadingAnchor.constraint(equalTo: search.leadingAnchor),
            message.trailingAnchor.constraint(equalTo: search.trailingAnchor),
            message.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            message.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(refreshLanguage), name: L10n.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: ShortcutSettings.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: HotKeyCenter.didChangeNotification, object: nil)
        refreshLanguage()
    }
    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            NotificationCenter.default.post(name: HotKeyCenter.recordingDidChange, object: false)
        }
        NotificationCenter.default.removeObserver(self)
    }
    @objc private func refreshLanguage() {
        stopRecording()
        settings.reloadTitles()
        search.placeholderString = L10n.t(.shortcutSearch)
        table.tableColumns[0].title = L10n.t(.shortcutCommand)
        table.tableColumns[1].title = L10n.t(.shortcutBinding)
        record.title = L10n.t(.shortcutRecord)
        clear.title = L10n.t(.shortcutClear)
        reset.title = L10n.t(.prefHotkeyReset)
        resetAll.title = L10n.t(.shortcutResetAll)
        sequence.title = L10n.t(.shortcutSequence)
        message.stringValue = L10n.t(.shortcutHelp)
        reload()
        onContentSizeChange?()
    }
    @objc private func reload() {
        let selectedID = selected?.id
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        rows = settings.commands.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || settings.binding(for: $0).map(\.display).joined(separator: " ").localizedCaseInsensitiveContains(query) }
        table.reloadData()
        if let selectedID, let index = rows.firstIndex(where: { $0.id == selectedID }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        updateButtons()
    }
    private var selected: ShortcutCommand? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let command = rows[row]
        let binding = settings.binding(for: command).map(\.display).joined(separator: " ")
        let label = NSTextField(labelWithString: tableColumn?.identifier.rawValue == "command"
            ? command.title : (binding.isEmpty ? L10n.t(.shortcutNone) : binding))
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = label.stringValue
        return label
    }
    func controlTextDidChange(_ obj: Notification) { stopRecording(); reload() }
    func tableViewSelectionDidChange(_ notification: Notification) { stopRecording(); updateButtons() }
    private func updateButtons() {
        let enabled = selected != nil
        record.isEnabled = enabled; clear.isEnabled = enabled; reset.isEnabled = enabled
        sequence.isEnabled = selected?.scope != .global
        if !sequence.isEnabled { sequence.state = .off }
    }
    @objc private func startRecording() {
        guard let selected else { return }
        if recordingID != nil { stopRecording(); return }
        recordingID = selected.id; captured = []
        NotificationCenter.default.post(name: HotKeyCenter.recordingDidChange, object: true)
        record.title = L10n.t(.prefHotkeyRecording)
        message.stringValue = L10n.t(.shortcutRecordingHelp)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.view.window, event.window === window, window.isKeyWindow else { return event }
            if event.keyCode == 53 { self.stopRecording(); return nil }
            guard let stroke = ShortcutStroke(event: event), stroke.valid else { return nil }
            self.captured.append(stroke)
            if self.sequence.state == .on, self.captured.count == 1 {
                self.message.stringValue = stroke.display + " — " + L10n.t(.shortcutSecondKey)
                return nil
            }
            let binding = self.captured
            self.stopRecording()
            self.report(self.settings.set(binding, for: selected))
            self.reload()
            return nil
        }
    }
    private func stopRecording() {
        if recordingID != nil { NotificationCenter.default.post(name: HotKeyCenter.recordingDidChange, object: false) }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil; recordingID = nil; captured = []
        record.title = L10n.t(.shortcutRecord)
    }
    private func report(_ conflicts: [ShortcutCommand]) {
        message.textColor = conflicts.isEmpty ? .secondaryLabelColor : .systemRed
        message.stringValue = conflicts.isEmpty ? L10n.t(.shortcutSaved)
            : L10n.t(.shortcutConflict, conflicts.map(\.title).joined(separator: ", "))
    }
    @objc private func clearSelected() {
        guard let selected else { return }; stopRecording(); report(settings.set([], for: selected)); reload()
    }
    @objc private func resetSelected() {
        guard let selected else { return }; stopRecording(); report(settings.reset(selected)); reload()
    }
    @objc private func restoreAll() {
        stopRecording()
        let alert = NSAlert()
        alert.messageText = L10n.t(.shortcutResetAll)
        alert.informativeText = L10n.t(.shortcutResetConfirm)
        alert.addButton(withTitle: L10n.t(.prefHotkeyReset))
        alert.addButton(withTitle: L10n.t(.shortcutCancel))
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.settings.resetAll(); self?.reload()
        }
    }
    /// Leaving the page, losing key or closing the window disarms the recorder.
    func pageWillDeactivate() { stopRecording() }
}
