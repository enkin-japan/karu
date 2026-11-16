import AppKit

/// Settings › Run page (T16.3b): the Run module toggle, then a list of the
/// runnable languages (those visible in Settings › Language List) on the left
/// and the selected language's detail on the right: the last Detect verdict,
/// where its tool comes from (Auto / Karu installed / System PATH / Custom
/// path), the custom path (Custom only), a Detect button that runs the locator
/// in the background, and the managed-toolchain section. The C / C++ extra
/// flags sit below. Built when the page is first selected and released with
/// the Settings window. Edits apply immediately through `RunSettings`
/// (machine-specific, not part of the settings archive).
///
/// T16.5: each pane's `managedSlot` shows the Karu-managed toolchain
/// (status, Install / Update / Cancel, Uninstall) through a `ToolchainManager`
/// held only while the page exists (an install keeps the manager alive by
/// itself); Swift / Rust panes show whether Apple's Command Line Tools exist.
///
/// The page has a fixed width and the list / detail row a fixed height, so its
/// size never depends on asynchronous results: it only changes with the UI
/// language (help text) and the C / C++ flags rows' visibility.
@MainActor
final class RunPreferencesController: NSObject, SettingsPage, NSTextFieldDelegate,
                                      NSTableViewDataSource, NSTableViewDelegate {
    var view: NSView { content }
    var onContentSizeChange: (() -> Void)?
    private let content = NSStackView()
    /// Toggle for `FeatureModule.run`.
    let moduleButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let modules: ModuleSettings

    /// Controls for one language, all inside its detail pane. `managedSlot`
    /// is the pane's managed section holding the `ManagedControls` (empty for
    /// Bash).
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

    /// Managed-toolchain / Command Line Tools controls inside a pane's slot.
    struct ManagedControls {
        let statusLabel: NSTextField
        /// Install / Update / Cancel for managed toolchains; "Install Apple
        /// Command Line Tools…" for Swift / Rust.
        let actionButton: NSButton
        /// Uninstall (managed toolchains only).
        let uninstallButton: NSButton?
        /// Rust only: rustup hint.
        let hintLabel: NSTextField?
        /// Toolchains shared by several languages: "Provided by …".
        let providedByLabel: NSTextField?
        /// The action and uninstall buttons; hidden when both are.
        let buttonRow: NSStackView
    }

    /// Languages whose panes show the Apple Command Line Tools state.
    static let commandLineToolsLanguages: Set<RunnableLanguage> = [.swift, .rust]

    // MARK: Layout

    static let pageWidth: CGFloat = 660
    static let insets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
    static let innerWidth = pageWidth - insets.left - insets.right
    static let listWidth: CGFloat = 170
    static let listDetailSpacing: CGFloat = 16
    /// Height of the list / detail row.
    static let middleHeight: CGFloat = 290
    /// Width of a language's detail pane.
    static let detailWidth = innerWidth - listWidth - listDetailSpacing
    private static let symbolSize: CGFloat = 16
    private static let symbolSpacing: CGFloat = 4

    /// SF Symbols of the list's per-language state.
    static let resolvedSymbol = "checkmark.circle"
    static let failedSymbol = "exclamationmark.triangle"
    static let busySymbol = "arrow.triangle.2.circlepath"

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
    /// The list follows the shared language list (hidden languages are not listed).
    private let languageMenu: LanguageMenuSettings

    private let languageTable = NSTableView()
    private let listScroll = NSScrollView()
    /// Holds the selected language's pane.
    let detailContainer = NSView()
    /// One detail pane per language, built up front.
    private(set) var panes: [RunnableLanguage: NSStackView] = [:]
    /// The warning symbol in front of a failed verdict.
    private(set) var verdictSymbols: [RunnableLanguage: NSImageView] = [:]
    /// Custom path field + Choose…, shown only for the Custom source.
    private(set) var pathRows: [RunnableLanguage: NSStackView] = [:]
    private var sourceLabels: [NSTextField] = []
    /// Runnable languages shown in the list, in `RunnableLanguage.allCases` order.
    private(set) var listedLanguages: [RunnableLanguage] = []
    private(set) var selectedLanguage: RunnableLanguage?
    /// Set while the table's selection is changed in code.
    private var syncingSelection = false
    private let flagsSeparator = NSBox()
    private let flagsStack = NSStackView()
    private var flagsRows: [RunnableLanguage: NSStackView] = [:]
    private var flagsLabelWidths: [NSLayoutConstraint] = []

    private static let sources = ToolchainSource.allCases
    private static let cFlagsTag = 1000
    private static let cppFlagsTag = 1001
    private static let cellIdentifier = NSUserInterfaceItemIdentifier("run.languageCell")

    /// - Parameters:
    ///   - manager: defaults to the live (or a new) `ToolchainManager`.
    ///   - makeLocator: defaults to a locator over `manager`'s store.
    ///   - probes: only `developerToolsInstalled` is used here (Swift / Rust panes).
    ///   - installCommandLineTools: launches the system CLT installer.
    init(settings: RunSettings? = nil, center: NotificationCenter = .default,
         makeLocator: (@Sendable () -> ToolchainLocator)? = nil,
         manager: ToolchainManager? = nil,
         probes: ToolchainProbes = .system,
         languageMenu: LanguageMenuSettings = LanguageMenuSettings(),
         installCommandLineTools: @escaping () -> Void = RunPreferencesController.launchCommandLineToolsInstaller,
         modules: ModuleSettings = ModuleSettings()) {
        let manager = manager ?? ToolchainManager.acquire()
        self.modules = modules
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
        super.init()

        moduleButton.target = self
        moduleButton.action = #selector(moduleToggled(_:))
        moduleButton.identifier = NSUserInterfaceItemIdentifier("settings.module.run")

        for (index, language) in RunnableLanguage.allCases.enumerated() {
            let row = makeRow(language, tag: index)
            rows.append(row)
            panes[language] = makePane(row)
        }

        help.textColor = .secondaryLabelColor
        help.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        // A wrapping label's frame is 2 pt wider than its text on each side;
        // keep the frame itself inside the trailing inset.
        help.preferredMaxLayoutWidth = Self.innerWidth - 4

        let middle = makeListAndDetail()
        makeFlagsSection()
        flagsSeparator.boxType = .separator

        content.setViews([moduleButton, help, middle, flagsSeparator, flagsStack], in: .top)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.edgeInsets = Self.insets
        var constraints = [content.widthAnchor.constraint(equalToConstant: Self.pageWidth),
                           flagsSeparator.heightAnchor.constraint(equalToConstant: 1)]
        constraints.append(help.widthAnchor.constraint(equalToConstant: help.preferredMaxLayoutWidth))
        for view in [middle, flagsSeparator, flagsStack] as [NSView] {
            constraints.append(view.widthAnchor.constraint(equalToConstant: Self.innerWidth))
        }
        NSLayoutConstraint.activate(constraints)

        center.addObserver(self, selector: #selector(reloadState),
                           name: RunSettings.didChangeNotification, object: nil)
        // Toggles made from the editor toolbar's module menu show up live.
        NotificationCenter.default.addObserver(self, selector: #selector(reloadModuleState),
                                               name: ModuleSettings.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reloadModuleState),
                                               name: SettingsArchive.didImport, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(languageListChanged),
                                               name: LanguageMenuSettings.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reloadStrings),
                                               name: L10n.didChangeNotification, object: nil)
        manager.center.addObserver(self, selector: #selector(toolchainsChanged(_:)),
                                   name: ToolchainManager.didChangeNotification, object: manager)
        reloadStrings()
        reloadState()
        reloadModuleState()
        applyLanguageVisibility()
        manager.refresh()
        probeCommandLineTools()
    }

    /// Whether `language` is listed (follows the shared language list).
    func isRowVisible(_ language: RunnableLanguage) -> Bool {
        listedLanguages.contains(language)
    }

    /// Lists the languages checked in Settings › Language List (keeping the
    /// selection when it is still listed), shows or hides the C / C++ flags
    /// rows, and reports the new size. Toolchains stay installed; hiding is
    /// display only.
    func applyLanguageVisibility() {
        listedLanguages = RunnableLanguage.allCases.filter { languageMenu.isVisible($0.identifier) }
        syncingSelection = true
        languageTable.reloadData()
        syncingSelection = false
        if let keep = selectedLanguage.flatMap({ listedLanguages.contains($0) ? $0 : nil }) ?? listedLanguages.first {
            select(keep)
        } else {
            selectedLanguage = nil
            showPane(for: nil)
        }

        for (language, row) in flagsRows {
            row.isHidden = !languageMenu.isVisible(language.identifier)
        }
        let anyFlags = flagsRows.values.contains { !$0.isHidden }
        flagsStack.isHidden = !anyFlags
        flagsSeparator.isHidden = !anyFlags
        contentSizeChanged()
    }

    /// Lays the page out and tells the host its size may have changed (UI
    /// language, flags rows shown / hidden).
    func contentSizeChanged() {
        // Only once hosted: a detached page still has its zero autoresizing
        // frame. `fittingSize` does not need a layout pass.
        if content.window != nil { content.layoutSubtreeIfNeeded() }
        onContentSizeChange?()
    }

    @objc private func reloadModuleState() {
        moduleButton.state = modules.isEnabled(.run) ? .on : .off
    }

    @objc private func moduleToggled(_ sender: NSButton) {
        modules.setEnabled(sender.state == .on, for: .run)
    }

    @objc private func languageListChanged() {
        applyLanguageVisibility()
    }

    deinit {
        center.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        manager.center.removeObserver(self)
    }

    // MARK: Building

    private static func smallWrappingLabel(color: NSColor = .secondaryLabelColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = color
        label.isSelectable = false
        label.preferredMaxLayoutWidth = detailWidth
        return label
    }

    private func makeRow(_ language: RunnableLanguage, tag: Int) -> Row {
        let name = NSTextField(labelWithString: RunMessages.languageName(language.identifier))
        name.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
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
        path.setContentHuggingPriority(.defaultLow, for: .horizontal)
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let choose = NSButton(title: "", target: self, action: #selector(chooseTapped(_:)))
        choose.bezelStyle = .rounded
        choose.tag = tag
        choose.setContentHuggingPriority(.required, for: .horizontal)
        choose.setContentCompressionResistancePriority(.required, for: .horizontal)
        let detect = NSButton(title: "", target: self, action: #selector(detectTapped(_:)))
        detect.bezelStyle = .rounded
        detect.tag = tag
        let result = Self.smallWrappingLabel()
        result.isSelectable = true
        let slot = NSStackView()
        slot.orientation = .vertical
        slot.alignment = .leading
        slot.spacing = 6
        slot.identifier = NSUserInterfaceItemIdentifier("run.managedSlot." + language.rawValue)
        if let controls = makeManagedControls(language, tag: tag) {
            managedControls[language] = controls
            slot.addArrangedSubview(controls.statusLabel)
            if let provided = controls.providedByLabel { slot.addArrangedSubview(provided) }
            slot.addArrangedSubview(controls.buttonRow)
            if let hint = controls.hintLabel { slot.addArrangedSubview(hint) }
            for label in [controls.statusLabel, controls.providedByLabel, controls.hintLabel].compactMap({ $0 }) {
                label.widthAnchor.constraint(equalToConstant: Self.detailWidth).isActive = true
            }
        }
        return Row(language: language, nameLabel: name, sourcePopup: popup, pathField: path,
                   chooseButton: choose, detectButton: detect, resultLabel: result, managedSlot: slot)
    }

    /// Slot controls for languages with a managed toolchain or the CLT
    /// state; `nil` (empty slot) for Bash.
    private func makeManagedControls(_ language: RunnableLanguage, tag: Int) -> ManagedControls? {
        let entry = manager.entry(for: language)
        let clt = Self.commandLineToolsLanguages.contains(language)
        guard entry != nil || clt else { return nil }
        let status = Self.smallWrappingLabel()
        status.identifier = NSUserInterfaceItemIdentifier("run.managedStatus." + language.rawValue)
        let action = NSButton(title: "", target: self,
                              action: entry != nil ? #selector(toolchainActionTapped(_:)) : #selector(installCommandLineToolsTapped(_:)))
        action.bezelStyle = .rounded
        action.controlSize = .small
        action.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        action.tag = tag
        var uninstall: NSButton?
        if entry != nil {
            let button = NSButton(title: "", target: self, action: #selector(uninstallTapped(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            button.tag = tag
            uninstall = button
        }
        let buttonRow = NSStackView(views: [action] + (uninstall.map { [$0] } ?? []))
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        var provided: NSTextField?
        if let entry, entry.languages.count > 1 {
            provided = Self.smallWrappingLabel()
        }
        var hint: NSTextField?
        if language == .rust {
            hint = Self.smallWrappingLabel(color: .tertiaryLabelColor)
        }
        return ManagedControls(statusLabel: status, actionButton: action, uninstallButton: uninstall,
                               hintLabel: hint, providedByLabel: provided, buttonRow: buttonRow)
    }

    /// The detail pane of one language: name, verdict, source, custom path,
    /// Detect, then the managed section (none for Bash).
    private func makePane(_ row: Row) -> NSStackView {
        let symbol = NSImageView()
        symbol.image = NSImage(systemSymbolName: Self.failedSymbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: NSFont.smallSystemFontSize, weight: .regular))
        symbol.contentTintColor = .systemRed
        symbol.isHidden = true
        // The verdict text next to it says the same in words.
        symbol.setAccessibilityElement(false)
        verdictSymbols[row.language] = symbol
        let verdict = NSStackView(views: [symbol, row.resultLabel])
        verdict.orientation = .horizontal
        verdict.alignment = .top
        verdict.spacing = Self.symbolSpacing

        let sourceLabel = NSTextField(labelWithString: "")
        sourceLabels.append(sourceLabel)
        let sourceRow = NSStackView(views: [sourceLabel, row.sourcePopup])
        sourceRow.orientation = .horizontal
        sourceRow.alignment = .firstBaseline
        sourceRow.spacing = 8

        let pathRow = NSStackView(views: [row.pathField, row.chooseButton])
        pathRow.orientation = .horizontal
        pathRow.alignment = .firstBaseline
        pathRow.spacing = 8
        pathRows[row.language] = pathRow

        let pane = NSStackView(views: [row.nameLabel, verdict, sourceRow, pathRow, row.detectButton])
        pane.orientation = .vertical
        pane.alignment = .leading
        pane.spacing = 10
        pane.setHuggingPriority(.defaultHigh, for: .vertical)
        pane.identifier = NSUserInterfaceItemIdentifier("run.pane." + row.language.rawValue)
        var constraints = [
            symbol.widthAnchor.constraint(equalToConstant: Self.symbolSize),
            symbol.heightAnchor.constraint(equalToConstant: Self.symbolSize),
            verdict.widthAnchor.constraint(equalToConstant: Self.detailWidth),
            pathRow.widthAnchor.constraint(equalToConstant: Self.detailWidth),
        ]
        if !row.managedSlot.arrangedSubviews.isEmpty {
            let separator = NSBox()
            separator.boxType = .separator
            pane.addArrangedSubview(separator)
            pane.addArrangedSubview(row.managedSlot)
            constraints += [separator.widthAnchor.constraint(equalToConstant: Self.detailWidth),
                            separator.heightAnchor.constraint(equalToConstant: 1),
                            row.managedSlot.widthAnchor.constraint(equalToConstant: Self.detailWidth)]
        }
        NSLayoutConstraint.activate(constraints)
        return pane
    }

    /// The fixed-height row: language list on the left, detail on the right.
    private func makeListAndDetail() -> NSView {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("language"))
        column.resizingMask = .autoresizingMask
        column.width = Self.listWidth - 4
        languageTable.addTableColumn(column)
        languageTable.headerView = nil
        languageTable.rowHeight = 24
        languageTable.style = .fullWidth
        languageTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        languageTable.allowsMultipleSelection = false
        languageTable.allowsEmptySelection = false
        languageTable.dataSource = self
        languageTable.delegate = self
        languageTable.identifier = NSUserInterfaceItemIdentifier("run.languageList")

        listScroll.documentView = languageTable
        listScroll.borderType = .bezelBorder
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true

        detailContainer.identifier = NSUserInterfaceItemIdentifier("run.detail")

        let middle = NSView()
        for view in [listScroll, detailContainer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            middle.addSubview(view)
        }
        NSLayoutConstraint.activate([
            middle.heightAnchor.constraint(equalToConstant: Self.middleHeight),
            listScroll.leadingAnchor.constraint(equalTo: middle.leadingAnchor),
            listScroll.topAnchor.constraint(equalTo: middle.topAnchor),
            listScroll.bottomAnchor.constraint(equalTo: middle.bottomAnchor),
            listScroll.widthAnchor.constraint(equalToConstant: Self.listWidth),
            detailContainer.leadingAnchor.constraint(equalTo: listScroll.trailingAnchor,
                                                     constant: Self.listDetailSpacing),
            detailContainer.trailingAnchor.constraint(equalTo: middle.trailingAnchor),
            detailContainer.topAnchor.constraint(equalTo: middle.topAnchor),
            detailContainer.bottomAnchor.constraint(equalTo: middle.bottomAnchor),
        ])
        return middle
    }

    /// C / C++ flags: labels right-aligned to a common width, fields filling the rest.
    private func makeFlagsSection() {
        flagsStack.orientation = .vertical
        flagsStack.alignment = .leading
        flagsStack.spacing = 8
        for (label, field, tag, language) in [(cFlagsLabel, cFlagsField, Self.cFlagsTag, RunnableLanguage.c),
                                              (cppFlagsLabel, cppFlagsField, Self.cppFlagsTag, .cpp)] {
            field.tag = tag
            field.delegate = self
            field.target = self
            field.action = #selector(fieldCommitted(_:))
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            label.alignment = .right
            let width = label.widthAnchor.constraint(equalToConstant: 0)
            flagsLabelWidths.append(width)
            let row = NSStackView(views: [label, field])
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 8
            flagsRows[language] = row
            flagsStack.addArrangedSubview(row)
            NSLayoutConstraint.activate([width, row.widthAnchor.constraint(equalToConstant: Self.innerWidth)])
        }
    }

    func row(for language: RunnableLanguage) -> Row? {
        rows.first { $0.language == language }
    }

    // MARK: List and selection

    /// Selects `language` in the list and shows its pane (no-op when it is not
    /// listed). Launches nothing.
    func select(_ language: RunnableLanguage) {
        guard let index = listedLanguages.firstIndex(of: language) else { return }
        selectedLanguage = language
        if languageTable.selectedRow != index {
            syncingSelection = true
            languageTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            syncingSelection = false
        }
        showPane(for: language)
    }

    /// Puts `language`'s pane (or nothing) into the detail container.
    private func showPane(for language: RunnableLanguage?) {
        let pane = language.flatMap { panes[$0] }
        if let pane, detailContainer.subviews == [pane] { return }
        // A field of the outgoing pane being edited commits first.
        if let window = view.window, let editor = window.firstResponder as? NSText,
           let field = editor.delegate as? NSView, field.isDescendant(of: detailContainer) {
            window.makeFirstResponder(nil)
        }
        detailContainer.subviews.forEach { $0.removeFromSuperview() }
        guard let pane else { return }
        pane.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(pane)
        // Top-aligned; the pane never stretches the fixed-height row.
        let bottom = pane.bottomAnchor.constraint(lessThanOrEqualTo: detailContainer.bottomAnchor)
        bottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            pane.topAnchor.constraint(equalTo: detailContainer.topAnchor),
            pane.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),
            bottom,
        ])
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        listedLanguages.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard listedLanguages.indices.contains(row) else { return nil }
        let cell = tableView.makeView(withIdentifier: Self.cellIdentifier, owner: nil) as? LanguageCell
            ?? LanguageCell(identifier: Self.cellIdentifier)
        configure(cell, for: listedLanguages[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncingSelection else { return }
        let index = languageTable.selectedRow
        guard listedLanguages.indices.contains(index) else { return }
        select(listedLanguages[index])
    }

    private func toolchainBusy(_ language: RunnableLanguage) -> Bool {
        guard let entry = manager.entry(for: language) else { return false }
        return manager.state(for: entry.id).activity != nil
    }

    /// The list's state symbol for `language`: work in progress (detecting,
    /// toolchain installing / uninstalling), else the Detect outcome, else none.
    func listStatusSymbol(for language: RunnableLanguage) -> String? {
        if case .detecting? = detections[language] { return Self.busySymbol }
        if toolchainBusy(language) { return Self.busySymbol }
        switch detections[language] {
        case .resolved?: return Self.resolvedSymbol
        case .failed?: return Self.failedSymbol
        default: return nil
        }
    }

    /// The list row's tooltip / accessibility label: the language name and the
    /// same state in words (the verdict, or the toolchain status when that is
    /// what is going on or nothing was detected).
    func listStatusText(for language: RunnableLanguage) -> String {
        let name = RunMessages.languageName(language.identifier)
        let verdict = row(for: language)?.resultLabel.stringValue ?? ""
        var detail = verdict
        if case .detecting? = detections[language] {
            detail = verdict
        } else if toolchainBusy(language) || detections[language] == nil,
                  let status = managedControls[language]?.statusLabel.stringValue, !status.isEmpty {
            detail = status
        }
        return detail.isEmpty ? name : name + " · " + detail
    }

    private func configure(_ cell: LanguageCell, for language: RunnableLanguage) {
        cell.textField?.stringValue = RunMessages.languageName(language.identifier)
        let symbol = listStatusSymbol(for: language)
        cell.imageView?.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        cell.imageView?.contentTintColor = symbol == Self.failedSymbol ? .systemRed : .secondaryLabelColor
        cell.imageView?.isHidden = symbol == nil
        let text = listStatusText(for: language)
        cell.toolTip = text
        cell.setAccessibilityLabel(text)
    }

    /// Re-renders the state of the list's rows that exist.
    private func refreshListStatus() {
        for (index, language) in listedLanguages.enumerated() where index < languageTable.numberOfRows {
            guard let cell = languageTable.view(atColumn: 0, row: index, makeIfNecessary: false) as? LanguageCell
            else { continue }
            configure(cell, for: language)
        }
    }

    // MARK: State

    @objc private func reloadStrings() {
        moduleButton.title = FeatureModule.run.displayName
        help.stringValue = L10n.t(.runSettingsHelp)
        cFlagsLabel.stringValue = L10n.t(.runCFlags)
        cppFlagsLabel.stringValue = L10n.t(.runCppFlags)
        cFlagsField.placeholderString = L10n.t(.runFlagsPlaceholder)
        cppFlagsField.placeholderString = L10n.t(.runFlagsPlaceholder)
        let labelWidth = [cFlagsLabel, cppFlagsLabel].map { ceil($0.fittingSize.width) }.max() ?? 0
        flagsLabelWidths.forEach { $0.constant = labelWidth }
        sourceLabels.forEach { $0.stringValue = L10n.t(.runSourceLabel) }
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
        contentSizeChanged()
    }

    /// Re-reads `RunSettings` (also after a change made elsewhere). A field
    /// being edited keeps its in-progress text.
    @objc func reloadState() {
        let editing = view.window?.firstResponder as? NSText
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
            pathRows[row.language]?.isHidden = !custom
        }
        if !isEditing(cFlagsField) { cFlagsField.stringValue = settings.flagsString(for: .c) }
        if !isEditing(cppFlagsField) { cppFlagsField.stringValue = settings.flagsString(for: .cpp) }
    }

    private func renderDetection(for row: Row) {
        var failed = false
        switch detections[row.language] {
        case nil:
            row.resultLabel.stringValue = L10n.t(.runNotDetected)
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
            failed = true
        }
        verdictSymbols[row.language]?.isHidden = !failed
        row.resultLabel.preferredMaxLayoutWidth = failed
            ? Self.detailWidth - Self.symbolSize - Self.symbolSpacing : Self.detailWidth
        row.resultLabel.toolTip = row.resultLabel.stringValue.isEmpty ? nil : row.resultLabel.stringValue
        refreshListStatus()
    }

    // MARK: Managed toolchains / Command Line Tools

    /// Re-renders every pane's slot from the manager / CLT state.
    func renderManaged() {
        for (language, controls) in managedControls {
            if let entry = manager.entry(for: language) {
                renderToolchain(entry, language: language, controls: controls)
            } else {
                renderCommandLineTools(language: language, controls: controls)
            }
            controls.buttonRow.isHidden = controls.actionButton.isHidden
                && (controls.uninstallButton?.isHidden ?? true)
        }
        refreshListStatus()
    }

    private func renderToolchain(_ entry: ToolchainManifestEntry, language: RunnableLanguage, controls: ManagedControls) {
        let state = manager.state(for: entry.id)
        let status = RunMessages.toolchainStatus(entry, state)
        let shared = entry.languages.count > 1
        controls.statusLabel.stringValue = shared ? entry.displayName + " · " + status : status
        controls.statusLabel.toolTip = shared ? L10n.t(.runToolchainProvidedBy, entry.displayName) + "\n" + status : status
        controls.statusLabel.textColor = state.activity == nil && state.lastError != nil ? .systemRed : .secondaryLabelColor
        controls.providedByLabel?.stringValue = L10n.t(.runToolchainProvidedBy, entry.displayName)

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
        // The installed toolchain changed: refresh the affected languages' Detect result.
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
        guard let window = view.window else { return }
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
    nonisolated static func launchCommandLineToolsInstaller() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["--install"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    func pageDidBecomeActive() {
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
        guard let language = language(forTag: sender.tag), let window = view.window else { return }
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

    /// Leaving the page, losing key or closing the window: end editing so an
    /// uncommitted path / flags edit is saved.
    func pageWillDeactivate() {
        view.window?.makeFirstResponder(nil)
    }
}

/// One row of the Run page's language list: the name and, trailing, a small
/// state symbol.
private final class LanguageCell: NSTableCellView {
    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        let name = NSTextField(labelWithString: "")
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let symbol = NSImageView()
        symbol.setAccessibilityElement(false)
        for view in [name, symbol] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        textField = name
        imageView = symbol
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbol.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 4),
            symbol.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            symbol.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbol.widthAnchor.constraint(equalToConstant: 16),
            symbol.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
