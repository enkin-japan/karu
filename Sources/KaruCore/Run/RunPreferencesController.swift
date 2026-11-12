import AppKit

/// "Run…" sub-window of Settings (T16.3b): per runnable language, where its
/// tool comes from (Auto / Karu installed / System PATH / Custom path), the
/// custom path, and a Detect button that runs the locator in the background.
/// Plus the C / C++ extra flags. Built when opened from Settings and released
/// through `onClose`, like the language-list window. Edits apply immediately
/// through `RunSettings` (machine-specific, not part of the settings archive).
///
/// T16.5: each row's trailing `managedSlot` shows the Karu-managed toolchain
/// (status, Install / Update / Cancel, Uninstall) through a `ToolchainManager`
/// held only while the window is open (an install keeps the manager alive by
/// itself); Swift / Rust rows show whether Apple's Command Line Tools exist.
final class RunPreferencesController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    var onClose: (() -> Void)?

    /// Controls for one language. `managedSlot` is the trailing column holding
    /// the row's `ManagedControls` (empty for Bash).
    struct Row {
        let language: RunnableLanguage
        let nameLabel: NSTextField
        let sourcePopup: NSPopUpButton
        let pathField: NSTextField
        let chooseButton: NSButton
        let detectButton: NSButton
        let resultLabel: NSTextField
        let managedSlot: NSStackView
    }

    enum Detection {
        case detecting
        case resolved(ResolvedTool)
        case failed(RunFailure)
    }

    /// Managed-toolchain / Command Line Tools controls inside a row's slot.
    struct ManagedControls {
        let statusLabel: NSTextField
        /// Install / Update / Cancel for managed toolchains; "Install Apple
        /// Command Line Tools…" for Swift / Rust.
        let actionButton: NSButton
        /// Uninstall (managed toolchains only).
        let uninstallButton: NSButton?
        /// Rust only: rustup hint.
        let hintLabel: NSTextField?
    }

    /// Languages whose rows show the Apple Command Line Tools state.
    static let commandLineToolsLanguages: Set<RunnableLanguage> = [.swift, .rust]

    private let settings: RunSettings
    private let center: NotificationCenter
    private let makeLocator: @Sendable () -> ToolchainLocator
    let manager: ToolchainManager
    private let probes: ToolchainProbes
    private let installCommandLineTools: () -> Void
    /// Uninstall confirmation; the default shows a sheet. Tests replace it.
    var confirmUninstall: ((ToolchainManifestEntry, Int64?, @escaping (Bool) -> Void) -> Void)?
    private let help = NSTextField(wrappingLabelWithString: "")
    private(set) var rows: [Row] = []
    private(set) var managedControls: [RunnableLanguage: ManagedControls] = [:]
    private(set) var detections: [RunnableLanguage: Detection] = [:]
    /// Apple Command Line Tools present; `nil` while probing.
    private(set) var commandLineToolsInstalled: Bool?
    private var commandLineToolsProbeRunning = false
    let cFlagsLabel = NSTextField(labelWithString: "")
    let cFlagsField = NSTextField()
    let cppFlagsLabel = NSTextField(labelWithString: "")
    let cppFlagsField = NSTextField()
    /// Rows follow the shared language list (hidden languages' rows are hidden).
    private let languageMenu: LanguageMenuSettings
    /// Grid rows per language (main row + Detect result row, plus the flags
    /// row for C / C++), toggled together.
    private var gridRows: [RunnableLanguage: [NSGridRow]] = [:]

    private static let sources = ToolchainSource.allCases
    private static let cFlagsTag = 1000
    private static let cppFlagsTag = 1001

    /// - Parameters:
    ///   - manager: defaults to the live (or a new) `ToolchainManager`.
    ///   - makeLocator: defaults to a locator over `manager`'s store.
    ///   - probes: only `developerToolsInstalled` is used here (Swift / Rust rows).
    ///   - installCommandLineTools: launches the system CLT installer.
    init(settings: RunSettings? = nil, center: NotificationCenter = .default,
         makeLocator: (@Sendable () -> ToolchainLocator)? = nil,
         manager: ToolchainManager? = nil,
         probes: ToolchainProbes = .system,
         languageMenu: LanguageMenuSettings = LanguageMenuSettings(),
         installCommandLineTools: @escaping () -> Void = RunPreferencesController.launchCommandLineToolsInstaller) {
        let manager = manager ?? ToolchainManager.acquire()
        self.languageMenu = languageMenu
        self.settings = settings ?? RunSettings(center: center)
        self.center = center
        let store = manager.store
        let manifest = manager.manifest
        self.makeLocator = makeLocator ?? {
            ToolchainLocator(managed: KaruManagedToolchains(store: store, manifest: manifest))
        }
        self.manager = manager
        self.probes = probes
        self.installCommandLineTools = installCommandLineTools
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        let grid = NSGridView()
        grid.rowSpacing = 6
        grid.columnSpacing = 8
        for (index, language) in RunnableLanguage.allCases.enumerated() {
            let row = makeRow(language, tag: index)
            rows.append(row)
            let main = grid.addRow(with: [row.nameLabel, row.sourcePopup, row.pathField, row.chooseButton,
                                          row.detectButton, row.managedSlot])
            let result = grid.addRow(with: [NSGridCell.emptyContentView, row.resultLabel])
            result.mergeCells(in: NSRange(location: 1, length: 4))
            result.bottomPadding = 4
            gridRows[language] = [main, result]
        }
        for (label, field, tag, language) in [(cFlagsLabel, cFlagsField, Self.cFlagsTag, RunnableLanguage.c),
                                              (cppFlagsLabel, cppFlagsField, Self.cppFlagsTag, .cpp)] {
            field.tag = tag
            field.delegate = self
            field.target = self
            field.action = #selector(fieldCommitted(_:))
            let flagsRow = grid.addRow(with: [label, field])
            flagsRow.mergeCells(in: NSRange(location: 1, length: 4))
            gridRows[language, default: []].append(flagsRow)
        }
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 2).width = 240
        grid.rowAlignment = .firstBaseline

        help.textColor = .secondaryLabelColor
        help.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        help.preferredMaxLayoutWidth = 700

        let content = NSStackView(views: [help, grid])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        window.contentView = content

        center.addObserver(self, selector: #selector(reloadState),
                           name: RunSettings.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(languageListChanged),
                                               name: LanguageMenuSettings.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reloadStrings),
                                               name: L10n.didChangeNotification, object: nil)
        manager.center.addObserver(self, selector: #selector(toolchainsChanged(_:)),
                                   name: ToolchainManager.didChangeNotification, object: manager)
        reloadStrings()
        reloadState()
        // Size after the strings are in, so the fit matches the visible rows.
        applyLanguageVisibility()
        window.center()
        manager.refresh()
        probeCommandLineTools()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Whether `language`'s row is shown (follows the shared language list).
    func isRowVisible(_ language: RunnableLanguage) -> Bool {
        !(gridRows[language]?.first?.isHidden ?? true)
    }

    /// Hides the rows of languages unchecked in Settings › Language List and
    /// refits the window. Toolchains stay installed; hiding is display only.
    func applyLanguageVisibility() {
        for (language, rowsForLanguage) in gridRows {
            let hidden = !languageMenu.isVisible(language.identifier)
            rowsForLanguage.forEach { $0.isHidden = hidden }
        }
        refitWindow()
    }

    /// Resizes the window to its content, keeping the top edge in place. Row
    /// contents (Detect results, toolchain / CLT status) arrive asynchronously
    /// and can change the fitting height after the window was first sized.
    func refitWindow() {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        let current = window.contentRect(forFrameRect: window.frame).size
        guard abs(size.height - current.height) > 0.5 || abs(size.width - current.width) > 0.5 else { return }
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true)
    }

    private var refitScheduled = false
    /// Coalesces refits from several label updates into one per runloop turn.
    private func scheduleRefit() {
        guard !refitScheduled else { return }
        refitScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refitScheduled = false
            self.refitWindow()
        }
    }

    @objc private func languageListChanged() {
        applyLanguageVisibility()
    }

    deinit {
        center.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        manager.center.removeObserver(self)
    }

    private func makeRow(_ language: RunnableLanguage, tag: Int) -> Row {
        let name = NSTextField(labelWithString: RunMessages.languageName(language.identifier))
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: Self.sources.map { RunMessages.sourceTitle($0) })
        popup.tag = tag
        popup.target = self
        popup.action = #selector(sourceChanged(_:))
        let path = NSTextField()
        path.tag = tag
        path.delegate = self
        path.target = self
        path.action = #selector(fieldCommitted(_:))
        path.lineBreakMode = .byTruncatingMiddle
        path.usesSingleLineMode = true
        path.cell?.isScrollable = true
        path.cell?.wraps = false
        let choose = NSButton(title: "", target: self, action: #selector(chooseTapped(_:)))
        choose.bezelStyle = .rounded
        choose.tag = tag
        let detect = NSButton(title: "", target: self, action: #selector(detectTapped(_:)))
        detect.bezelStyle = .rounded
        detect.tag = tag
        let result = NSTextField(labelWithString: "")
        result.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        result.textColor = .secondaryLabelColor
        result.lineBreakMode = .byTruncatingMiddle
        result.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let slot = NSStackView()
        slot.orientation = .horizontal
        slot.spacing = 6
        slot.identifier = NSUserInterfaceItemIdentifier("run.managedSlot." + language.rawValue)
        if let controls = makeManagedControls(language, tag: tag) {
            managedControls[language] = controls
            slot.addArrangedSubview(controls.statusLabel)
            slot.addArrangedSubview(controls.actionButton)
            if let uninstall = controls.uninstallButton { slot.addArrangedSubview(uninstall) }
            if let hint = controls.hintLabel { slot.addArrangedSubview(hint) }
        }
        return Row(language: language, nameLabel: name, sourcePopup: popup, pathField: path,
                   chooseButton: choose, detectButton: detect, resultLabel: result, managedSlot: slot)
    }

    /// Slot controls for languages with a managed toolchain or the CLT
    /// state; `nil` (empty slot) for Bash.
    private func makeManagedControls(_ language: RunnableLanguage, tag: Int) -> ManagedControls? {
        let managed = manager.entry(for: language) != nil
        let clt = Self.commandLineToolsLanguages.contains(language)
        guard managed || clt else { return nil }
        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.widthAnchor.constraint(equalToConstant: 240).isActive = true
        status.identifier = NSUserInterfaceItemIdentifier("run.managedStatus." + language.rawValue)
        let action = NSButton(title: "", target: self,
                              action: managed ? #selector(toolchainActionTapped(_:)) : #selector(installCommandLineToolsTapped(_:)))
        action.bezelStyle = .rounded
        action.controlSize = .small
        action.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        action.tag = tag
        var uninstall: NSButton?
        if managed {
            let button = NSButton(title: "", target: self, action: #selector(uninstallTapped(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            button.tag = tag
            uninstall = button
        }
        var hint: NSTextField?
        if language == .rust {
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .tertiaryLabelColor
            hint = label
        }
        return ManagedControls(statusLabel: status, actionButton: action, uninstallButton: uninstall, hintLabel: hint)
    }

    func row(for language: RunnableLanguage) -> Row? {
        rows.first { $0.language == language }
    }

    // MARK: State

    @objc private func reloadStrings() {
        window?.title = L10n.t(.runSettingsTitle).replacingOccurrences(of: "…", with: "")
        help.stringValue = L10n.t(.runSettingsHelp)
        cFlagsLabel.stringValue = L10n.t(.runCFlags)
        cppFlagsLabel.stringValue = L10n.t(.runCppFlags)
        cFlagsField.placeholderString = L10n.t(.runFlagsPlaceholder)
        cppFlagsField.placeholderString = L10n.t(.runFlagsPlaceholder)
        for row in rows {
            for (index, source) in Self.sources.enumerated() {
                row.sourcePopup.item(at: index)?.title = RunMessages.sourceTitle(source)
            }
            row.pathField.placeholderString = L10n.t(.runPathPlaceholder)
            row.chooseButton.title = L10n.t(.runChoose)
            row.detectButton.title = L10n.t(.runDetect)
            renderDetection(for: row)
        }
        renderManaged()
    }

    /// Re-reads `RunSettings` (also after a change made elsewhere). A field
    /// being edited keeps its in-progress text.
    @objc func reloadState() {
        let editing = window?.firstResponder as? NSText
        func isEditing(_ field: NSTextField) -> Bool {
            editing != nil && field.currentEditor() === editing
        }
        for row in rows {
            let source = settings.source(for: row.language)
            row.sourcePopup.selectItem(at: Self.sources.firstIndex(of: source) ?? 0)
            if !isEditing(row.pathField) {
                row.pathField.stringValue = settings.customPath(for: row.language) ?? ""
            }
            let custom = source == .custom
            row.pathField.isEnabled = custom
            row.chooseButton.isEnabled = custom
        }
        if !isEditing(cFlagsField) { cFlagsField.stringValue = settings.flagsString(for: .c) }
        if !isEditing(cppFlagsField) { cppFlagsField.stringValue = settings.flagsString(for: .cpp) }
    }

    private func renderDetection(for row: Row) {
        switch detections[row.language] {
        case nil:
            row.resultLabel.stringValue = ""
            row.resultLabel.textColor = .secondaryLabelColor
        case .detecting:
            row.resultLabel.stringValue = L10n.t(.runDetecting)
            row.resultLabel.textColor = .secondaryLabelColor
        case .resolved(let tool):
            let command = ([tool.executable] + tool.leadingArguments).joined(separator: " ")
            row.resultLabel.stringValue = command + " · " + RunMessages.origin(tool.origin)
            row.resultLabel.textColor = .secondaryLabelColor
        case .failed(let failure):
            row.resultLabel.stringValue = RunMessages.failure(failure)
            row.resultLabel.textColor = .systemRed
        }
        row.resultLabel.toolTip = row.resultLabel.stringValue.isEmpty ? nil : row.resultLabel.stringValue
        scheduleRefit()
    }

    // MARK: Managed toolchains / Command Line Tools

    /// Re-renders every row's slot from the manager / CLT state.
    func renderManaged() {
        for (language, controls) in managedControls {
            if let entry = manager.entry(for: language) {
                renderToolchain(entry, language: language, controls: controls)
            } else {
                renderCommandLineTools(language: language, controls: controls)
            }
        }
        scheduleRefit()
    }

    private func renderToolchain(_ entry: ToolchainManifestEntry, language: RunnableLanguage, controls: ManagedControls) {
        let state = manager.state(for: entry.id)
        let status = RunMessages.toolchainStatus(entry, state)
        let shared = entry.languages.count > 1
        controls.statusLabel.stringValue = shared ? entry.displayName + " · " + status : status
        controls.statusLabel.toolTip = shared ? L10n.t(.runToolchainProvidedBy, entry.displayName) + "\n" + status : status
        controls.statusLabel.textColor = state.activity == nil && state.lastError != nil ? .systemRed : .secondaryLabelColor

        let action = controls.actionButton
        if state.isInstalling {
            action.title = L10n.t(.runToolchainCancel)
            action.isHidden = false
            action.isEnabled = true
        } else if state.activity == .uninstalling {
            action.isHidden = true
        } else if let installed = state.installedVersion {
            action.title = L10n.t(.runToolchainUpdate, entry.version)
            action.isHidden = installed == entry.version
            action.isEnabled = true
        } else {
            action.title = L10n.t(.runToolchainInstall)
            action.isHidden = false
            action.isEnabled = true
        }
        if let uninstall = controls.uninstallButton {
            uninstall.title = L10n.t(.runToolchainUninstall)
            uninstall.isHidden = state.installedVersion == nil || state.isInstalling
            uninstall.isEnabled = state.activity == nil
        }
    }

    private func renderCommandLineTools(language: RunnableLanguage, controls: ManagedControls) {
        switch commandLineToolsInstalled {
        case nil:
            controls.statusLabel.stringValue = L10n.t(.runCLTChecking)
            controls.actionButton.isHidden = true
        case true?:
            controls.statusLabel.stringValue = L10n.t(.runCLTInstalled)
            controls.actionButton.isHidden = true
        case false?:
            controls.statusLabel.stringValue = L10n.t(.runCLTMissing)
            controls.actionButton.isHidden = false
        }
        controls.statusLabel.textColor = .secondaryLabelColor
        controls.statusLabel.toolTip = controls.statusLabel.stringValue
        controls.actionButton.title = L10n.t(.runCLTInstall)
        if let hint = controls.hintLabel {
            hint.stringValue = L10n.t(.runRustHint)
            hint.toolTip = L10n.t(.runRustHintDetail)
        }
    }

    /// Probes for the Command Line Tools off the main thread (`xcode-select -p`).
    func probeCommandLineTools() {
        guard !commandLineToolsProbeRunning else { return }
        commandLineToolsProbeRunning = true
        let probe = probes.developerToolsInstalled
        Task.detached(priority: .utility) { [weak self] in
            let installed = probe()
            await self?.commandLineToolsProbed(installed)
        }
    }

    private func commandLineToolsProbed(_ installed: Bool) {
        commandLineToolsProbeRunning = false
        let changed = commandLineToolsInstalled != nil && commandLineToolsInstalled != installed
        commandLineToolsInstalled = installed
        renderManaged()
        if changed {
            for language in Self.commandLineToolsLanguages where detections[language] != nil { detect(language) }
        }
    }

    @objc private func toolchainsChanged(_ notification: Notification) {
        renderManaged()
        guard notification.userInfo?[ToolchainManager.finishedKey] as? Bool == true,
              let id = notification.userInfo?[ToolchainManager.idKey] as? String,
              let entry = manager.entry(id: id) else { return }
        // The installed toolchain changed: refresh the affected rows' Detect result.
        for language in entry.languages { detect(language) }
    }

    @objc private func toolchainActionTapped(_ sender: NSButton) {
        guard let language = language(forTag: sender.tag), let entry = manager.entry(for: language) else { return }
        if manager.state(for: entry.id).isInstalling {
            manager.cancel(entry.id)
        } else {
            manager.install(entry)
        }
    }

    @objc private func uninstallTapped(_ sender: NSButton) {
        guard let language = language(forTag: sender.tag), let entry = manager.entry(for: language),
              manager.state(for: entry.id).installedVersion != nil else { return }
        let usage = manager.state(for: entry.id).diskUsage
        let confirm = confirmUninstall ?? { [weak self] entry, usage, completion in
            self?.showUninstallAlert(entry, usage: usage, completion: completion)
        }
        confirm(entry, usage) { [weak self] confirmed in
            guard confirmed else { return }
            self?.manager.uninstall(entry.id)
        }
    }

    private func showUninstallAlert(_ entry: ToolchainManifestEntry, usage: Int64?,
                                    completion: @escaping (Bool) -> Void) {
        guard let window else { return }
        let version = manager.state(for: entry.id).installedVersion ?? entry.version
        let store = manager.store
        let paths = [store.toolchainDirectory(entry.id).path, store.cacheDirectory(entry.id).path]
            .map { ($0 as NSString).abbreviatingWithTildeInPath }
            .joined(separator: "\n")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.t(.runToolchainUninstallTitle, entry.displayName, version)
        alert.informativeText = L10n.t(.runToolchainUninstallInfo, usage.map(RunMessages.megabytes) ?? "—", paths)
        alert.addButton(withTitle: L10n.t(.runToolchainUninstall))
        alert.addButton(withTitle: L10n.t(.runToolchainCancel))
        alert.beginSheetModal(for: window) { response in
            completion(response == .alertFirstButtonReturn)
        }
    }

    @objc private func installCommandLineToolsTapped(_ sender: NSButton) {
        installCommandLineTools()
    }

    /// Opens the system "install Command Line Tools" dialog.
    static func launchCommandLineToolsInstaller() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["--install"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Returning from the system CLT installer: re-check.
        if commandLineToolsInstalled == false { probeCommandLineTools() }
    }

    private func language(forTag tag: Int) -> RunnableLanguage? {
        RunnableLanguage.allCases.indices.contains(tag) ? RunnableLanguage.allCases[tag] : nil
    }

    // MARK: Actions

    @objc private func sourceChanged(_ sender: NSPopUpButton) {
        guard let language = language(forTag: sender.tag),
              Self.sources.indices.contains(sender.indexOfSelectedItem) else { return }
        settings.setSource(Self.sources[sender.indexOfSelectedItem], for: language)
        reloadState()
    }

    /// Commits a path / flags field (Return or end of editing).
    @objc private func fieldCommitted(_ sender: NSTextField) {
        commit(sender)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        commit(field)
    }

    private func commit(_ field: NSTextField) {
        switch field.tag {
        case Self.cFlagsTag:
            guard field.stringValue != settings.flagsString(for: .c) else { return }
            settings.setFlagsString(field.stringValue, for: .c)
        case Self.cppFlagsTag:
            guard field.stringValue != settings.flagsString(for: .cpp) else { return }
            settings.setFlagsString(field.stringValue, for: .cpp)
        default:
            guard let language = language(forTag: field.tag) else { return }
            let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed != (settings.customPath(for: language) ?? "") else { return }
            settings.setCustomPath(trimmed, for: language)
        }
    }

    @objc private func chooseTapped(_ sender: NSButton) {
        guard let language = language(forTag: sender.tag), let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        if let current = settings.customPath(for: language) {
            panel.directoryURL = URL(fileURLWithPath: current).deletingLastPathComponent()
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                self?.settings.setCustomPath(url.path, for: language)
                self?.reloadState()
            }
        }
    }

    @objc private func detectTapped(_ sender: NSButton) {
        guard let language = language(forTag: sender.tag) else { return }
        // Commit a path still being typed so Detect checks what is on screen.
        if let row = row(for: language), row.pathField.currentEditor() != nil { commit(row.pathField) }
        detect(language)
    }

    /// Resolves `language`'s tool off the main thread and shows the result.
    func detect(_ language: RunnableLanguage) {
        let preference = settings.preference(for: language)
        let makeLocator = self.makeLocator
        detections[language] = .detecting
        if let row = row(for: language) { renderDetection(for: row) }
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = makeLocator().resolve(language, preference: preference, text: "")
            await self?.detectionFinished(language, result)
        }
    }

    private func detectionFinished(_ language: RunnableLanguage, _ result: Result<ResolvedTool, RunFailure>) {
        switch result {
        case .success(let tool): detections[language] = .resolved(tool)
        case .failure(let failure): detections[language] = .failed(failure)
        }
        if let row = row(for: language) { renderDetection(for: row) }
    }

    func windowWillClose(_ notification: Notification) {
        // End editing so an uncommitted path / flags edit is saved.
        window?.makeFirstResponder(nil)
        onClose?()
    }
}
