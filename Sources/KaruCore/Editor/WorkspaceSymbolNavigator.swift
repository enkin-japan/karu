import AppKit

/// ⌘T "Workspace Symbols" (M17 T17.14, plan §10 「工作区符号」): searches the
/// document's project folder through the cross-file index with the
/// completion matcher's tiers (`WorkspaceIndex.searchSymbols`: exact
/// prefix, case-insensitive prefix, word start, fuzzy) and opens the chosen
/// symbol's file at its declaration.
///
/// Like the document symbol navigator it is transient (ARCHITECTURE.md §3.4):
/// the panel, the result list and the navigator itself are released when it
/// closes; nothing is indexed or cached here. Searches run off the main
/// thread on a serial queue (the latest query wins); only the ≤ 100 rows
/// come back.
///
/// Disabled states (`Availability`): the document is not inside a project
/// folder, the `crossFileIndex` module is off, or its folder is still being
/// indexed — the field is disabled and a message row explains why (an
/// indexing folder enables itself once the index reports it up to date).
@MainActor
public final class WorkspaceSymbolNavigator: NSObject {
    public enum Availability: Equatable {
        case available(folder: String)
        case notInProjectFolder
        case indexOff
        case indexing(folder: String)

        var message: L10nKey? {
            switch self {
            case .available: return nil
            case .notInProjectFolder: return .workspaceSymbolNotInFolder
            case .indexOff: return .workspaceSymbolIndexOff
            case .indexing: return .workspaceSymbolIndexing
            }
        }
    }

    /// Whether `documentPath` can search `index`, and why not.
    public static func availability(index: WorkspaceIndex, documentPath: String?) -> Availability {
        guard index.isEnabled else { return .indexOff }
        guard let documentPath, let folder = index.projectFolder(containing: documentPath) else {
            return .notInProjectFolder
        }
        return index.state(ofFolder: folder) == .indexing ? .indexing(folder: folder) : .available(folder: folder)
    }

    nonisolated static let resultLimit = 100

    private weak var textView: NSTextView?
    private let index: WorkspaceIndex
    private let documentPath: String?
    private let open: (WorkspaceSymbol) -> Void
    private let searchQueue = DispatchQueue(label: "dev.enkin.Karu.workspace-symbols", qos: .userInitiated)

    // MARK: Transient runtime state (released on close)
    private var panel: NSPanel?
    private var tableView: NSTableView?
    private var filterField: NSTextField?
    private var results: [WorkspaceSymbolMatch] = []
    private var availability: Availability = .notInProjectFolder
    private var generation = 0
    private var searching = 0
    private var onClose: (() -> Void)?
    private var indexObserver: NSObjectProtocol?
    /// Main-thread wall time from a query to its rows (tests, benchmarks).
    private(set) var lastSearchMilliseconds = 0.0
    var labelLanguageOverride: AppLanguage?

    public init(textView: NSTextView, index: WorkspaceIndex, documentPath: String?,
                open: @escaping (WorkspaceSymbol) -> Void) {
        self.textView = textView
        self.index = index
        self.documentPath = documentPath
        self.open = open
        super.init()
    }

    public var isVisible: Bool { panel?.isVisible == true }

    // MARK: - Presentation

    public func present(onClose: (() -> Void)? = nil) {
        guard textView != nil else { return }
        self.onClose = onClose
        availability = Self.availability(index: index, documentPath: documentPath)
        let panel = makePanel()
        self.panel = panel
        applyAvailability()
        positionPanel(panel)
        panel.makeKeyAndOrderFront(nil)
        if let filterField { panel.makeFirstResponder(filterField) }
        NotificationCenter.default.addObserver(self, selector: #selector(panelResignedKey),
                                               name: NSWindow.didResignKeyNotification, object: panel)
        if case .indexing = availability {
            indexObserver = NotificationCenter.default.addObserver(
                forName: WorkspaceIndex.didChangeNotification, object: index, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.recheckAvailability() }
            }
        }
    }

    private func recheckAvailability() {
        guard panel != nil else { return }
        availability = Self.availability(index: index, documentPath: documentPath)
        applyAvailability()
    }

    private func applyAvailability() {
        let enabled: Bool
        if case .available = availability { enabled = true } else { enabled = false }
        filterField?.isEnabled = enabled
        if enabled, let field = filterField, !field.stringValue.isEmpty { search(field.stringValue) }
        tableView?.reloadData()
    }

    // MARK: - Search

    /// Runs `query` on the search queue; the latest query's rows win.
    private func search(_ query: String) {
        guard case .available(let folder) = availability else { return }
        generation += 1
        let mine = generation
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            tableView?.reloadData()
            return
        }
        let index = self.index
        let start = DispatchTime.now().uptimeNanoseconds
        searching += 1
        lastQuery = (trimmed, folder, mine, start)
        searchQueue.async { [weak self] in
            let found = index.searchSymbols(trimmed, inFolder: folder, limit: Self.resultLimit)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.deliver(found, generation: mine, start: start) }
            }
        }
    }

    /// The rows of query `generation` (dropped when a newer query was typed).
    private func deliver(_ found: [WorkspaceSymbolMatch], generation mine: Int, start: UInt64) {
        searching -= 1
        guard mine == generation, panel != nil else { return }
        results = found
        lastSearchMilliseconds = Double(DispatchTime.now().uptimeNanoseconds &- start) / 1e6
        tableView?.reloadData()
        selectFirstRow()
    }

    private var lastQuery: (query: String, folder: String, generation: Int, start: UInt64)?

    // MARK: - Rows

    /// The trailing text of a row: kind, file and line (`function · src/a.py:12`).
    static func detail(of symbol: WorkspaceSymbol, language: AppLanguage? = nil) -> String {
        let category: CompletionCategory
        switch symbol.kind {
        case .function: category = symbol.container == nil ? .function : .member
        case .method, .property: category = .member
        case .class, .type: category = .type
        default: category = symbol.container == nil ? .variable : .member
        }
        let owner = symbol.container.map { $0 + " · " } ?? ""
        return category.label(language: language) + " · " + owner + symbol.relativePath + ":" + String(symbol.line)
    }

    private var hasMessageRow: Bool {
        if availability.message != nil { return true }
        guard let field = filterField else { return false }
        return results.isEmpty && searching == 0 && !field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var messageText: String {
        let language = labelLanguageOverride
        if let key = availability.message { return language.map { L10n.string(key, language: $0) } ?? L10n.t(key) }
        return language.map { L10n.string(.workspaceSymbolNone, language: $0) } ?? L10n.t(.workspaceSymbolNone)
    }

    // MARK: - Selection / acceptance

    private func moveSelection(_ delta: Int) {
        guard let table = tableView, !results.isEmpty else { return }
        let current = table.selectedRow < 0 ? 0 : table.selectedRow
        let next = max(0, min(results.count - 1, current + delta))
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    private func selectFirstRow() {
        guard let table = tableView, !results.isEmpty else { return }
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    }

    private func acceptSelection() {
        guard let table = tableView, table.selectedRow >= 0, table.selectedRow < results.count,
              !hasMessageRow || !results.isEmpty else { return }
        let symbol = results[table.selectedRow].symbol
        close()
        open(symbol)
    }

    // MARK: - Panel

    private func makePanel() -> NSPanel {
        let panel = WorkspaceNavigatorPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
                                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.backgroundColor = .windowBackgroundColor
        panel.isMovable = false

        let container = NSView(frame: panel.contentView?.bounds ?? .zero)
        let field = NSTextField()
        field.translatesAutoresizingMaskIntoConstraints = false
        field.placeholderString = labelLanguageOverride.map { L10n.string(.workspaceSymbolPlaceholder, language: $0) }
            ?? L10n.t(.workspaceSymbolPlaceholder)
        field.font = .systemFont(ofSize: 13)
        field.focusRingType = .none
        field.delegate = self
        filterField = field

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let table = NSTableView()
        table.headerView = nil
        table.style = .plain
        table.rowHeight = 20
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.backgroundColor = .clear
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("workspaceSymbol"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(tableClicked)
        table.doubleAction = #selector(tableClicked)
        table.allowsEmptySelection = true
        table.setAccessibilityLabel(L10n.t(.menuWorkspaceSymbols))
        scroll.documentView = table
        tableView = table

        container.addSubview(field)
        container.addSubview(scroll)
        panel.contentView = container
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            field.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
        ])
        return panel
    }

    private func positionPanel(_ panel: NSPanel) {
        guard let window = textView?.window else { return }
        let frame = window.frame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.minX + (frame.width - size.width) / 2, y: frame.minY + frame.height * 0.62))
    }

    @objc private func panelResignedKey() { close() }

    @objc private func tableClicked() { acceptSelection() }

    /// Tears down the panel and releases every piece of runtime state.
    private func close() {
        guard let panel else { return }
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: panel)
        if let indexObserver { NotificationCenter.default.removeObserver(indexObserver) }
        indexObserver = nil
        panel.orderOut(nil)
        self.panel = nil
        tableView = nil
        filterField = nil
        results = []
        generation += 1
        let callback = onClose
        onClose = nil
        callback?()
    }

    // MARK: - Tests

    var panelForTesting: NSPanel? { panel }
    var tableViewForTesting: NSTableView? { tableView }
    var availabilityForTesting: Availability { availability }
    var resultsForTesting: [WorkspaceSymbolMatch] { results }
    var isFieldEnabledForTesting: Bool { filterField?.isEnabled ?? false }
    /// The message row's text (nil: none shown).
    var messageForTesting: String? { hasMessageRow && results.isEmpty ? messageText : nil }

    /// Types `query` into the field (as typing would) and delivers its rows
    /// (the search runs on the queue; the main-queue hop is replaced by a
    /// direct delivery — a test on the main queue cannot drain it).
    func searchForTesting(_ query: String) {
        filterField?.stringValue = query
        search(query)
        guard let pending = lastQuery, pending.generation == generation else { return }
        var found: [WorkspaceSymbolMatch] = []
        searchQueue.sync { found = index.searchSymbols(pending.query, inFolder: pending.folder, limit: Self.resultLimit) }
        deliver(found, generation: pending.generation, start: pending.start)
        searching = 0
    }

    func acceptForTesting(row: Int) {
        tableView?.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        acceptSelection()
    }

    func closeForTesting() { close() }
}

// MARK: - Filter field

extension WorkspaceSymbolNavigator: NSTextFieldDelegate {
    public func controlTextDidChange(_ obj: Notification) {
        guard let field = filterField else { return }
        search(field.stringValue)
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)): moveSelection(-1); return true
        case #selector(NSResponder.moveDown(_:)): moveSelection(1); return true
        case #selector(NSResponder.insertNewline(_:)): acceptSelection(); return true
        case #selector(NSResponder.cancelOperation(_:)): close(); return true
        default: return false
        }
    }
}

// MARK: - Table

extension WorkspaceSymbolNavigator: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        results.isEmpty ? (hasMessageRow ? 1 : 0) : results.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("workspaceSymbolCell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? WorkspaceSymbolCell ?? WorkspaceSymbolCell()
        cell.identifier = id
        if results.isEmpty {
            cell.configure(name: messageText, nameColor: .secondaryLabelColor, matched: [], detail: "")
        } else if row < results.count {
            let match = results[row]
            cell.configure(name: match.symbol.name, nameColor: .labelColor, matched: match.ranges,
                           detail: Self.detail(of: match.symbol, language: labelLanguageOverride))
        }
        return cell
    }

    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { !results.isEmpty }
}

/// One row: the name (matched characters bold) and a dimmed trailing
/// "kind · file:line".
private final class WorkspaceSymbolCell: NSTableCellView {
    private let nameField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        for field in [nameField, detailField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.lineBreakMode = .byTruncatingTail
            addSubview(field)
        }
        nameField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        detailField.font = .systemFont(ofSize: 11)
        detailField.textColor = .secondaryLabelColor
        detailField.alignment = .right
        nameField.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        detailField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            nameField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            nameField.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailField.leadingAnchor.constraint(greaterThanOrEqualTo: nameField.trailingAnchor, constant: 12),
            detailField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            detailField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(name: String, nameColor: NSColor, matched: [NSRange], detail: String) {
        let attributed = NSMutableAttributedString(string: name, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: nameColor,
        ])
        let length = (name as NSString).length
        for range in matched where range.location != NSNotFound && NSMaxRange(range) <= length {
            attributed.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold), range: range)
        }
        nameField.attributedStringValue = attributed
        detailField.stringValue = detail
        setAccessibilityLabel([name, detail].filter { !$0.isEmpty }.joined(separator: ", "))
    }
}

/// A borderless panel that still becomes key, so its field receives keys.
private final class WorkspaceNavigatorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
