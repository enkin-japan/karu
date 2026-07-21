import AppKit

/// Cmd+Shift+O "Jump to Symbol" navigator (T8.4).
///
/// A transient, floating panel that lists the document's declared symbols
/// (functions / types / variables) with a case-insensitive filter field, and
/// jumps the editor's selection to the chosen symbol's name.
///
/// Design (ARCHITECTURE.md §3.4 "瞬时不常驻"): the symbol list is produced by a
/// single `WordIndex.scanSymbolLocations` call at open time — **no** resident
/// index, **no** `textStorage` observer. Closing the panel drops the list, the
/// table, and the panel itself, so a closed navigator's resident cost is ≈ 0.
/// The owning `EditorWindowController` also releases its reference on close (via
/// `onClose`), so the whole object is deallocated between uses.
@MainActor
public final class SymbolNavigator: NSObject {
    private weak var textView: NSTextView?

    // MARK: Transient runtime state (all released on close)
    private var panel: NSPanel?
    private var tableView: NSTableView?
    private var filterField: NSTextField?
    private var allLocations: [WordIndex.SymbolLocation] = []
    private var filtered: [WordIndex.SymbolLocation] = []
    private var onClose: (() -> Void)?

    private static let theme = HighlightTheme()

    public init(textView: NSTextView) {
        self.textView = textView
        super.init()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// True while the navigator panel is on screen.
    public var isVisible: Bool { panel?.isVisible == true }

    // MARK: - Filtering (pure, unit-testable)

    /// Case-insensitive substring match on the symbol name. An empty / whitespace
    /// query returns every location unchanged (the document-order list).
    public static func filter(_ locations: [WordIndex.SymbolLocation],
                              query: String) -> [WordIndex.SymbolLocation] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return locations }
        return locations.filter { $0.name.lowercased().contains(needle) }
    }

    // MARK: - Presentation

    /// Scans `languageIdentifier`'s symbols in the text view's current content
    /// (once) and shows the navigator. `onClose` lets the owner drop its strong
    /// reference so the navigator is fully released when the panel goes away.
    public func present(languageIdentifier: String, onClose: (() -> Void)? = nil) {
        guard let textView else { return }
        self.onClose = onClose

        allLocations = WordIndex.scanSymbolLocations(text: textView.string,
                                                     languageIdentifier: languageIdentifier)
        filtered = allLocations

        let panel = makePanel()
        self.panel = panel
        tableView?.reloadData()
        selectFirstRow()
        positionPanel(panel)
        panel.makeKeyAndOrderFront(nil)
        if let filterField { panel.makeFirstResponder(filterField) }
        observeDismissTriggers(panel)
    }

    /// Whether the list is the empty-document / no-symbol placeholder state.
    private var isEmptyState: Bool { allLocations.isEmpty }

    // MARK: - Selection movement / acceptance

    private func moveSelection(_ delta: Int) {
        guard let table = tableView, !filtered.isEmpty else { return }
        let current = table.selectedRow < 0 ? 0 : table.selectedRow
        let next = max(0, min(filtered.count - 1, current + delta))
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    private func selectFirstRow() {
        guard let table = tableView, !filtered.isEmpty else { return }
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    }

    private func acceptSelection() {
        guard !isEmptyState, let table = tableView,
              table.selectedRow >= 0, table.selectedRow < filtered.count else { return }
        jump(to: filtered[table.selectedRow])
    }

    /// Moves the editor selection onto the symbol's name range, scrolls it into
    /// view, then closes and returns focus to the editor.
    private func jump(to location: WordIndex.SymbolLocation) {
        guard let textView else { close(); return }
        textView.setSelectedRange(location.range)
        textView.scrollRangeToVisible(location.range)
        let window = textView.window
        close()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(textView)
    }

    // MARK: - Panel lifecycle

    private func makePanel() -> NSPanel {
        let panel = NavigatorPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 300),
                                   styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered,
                                   defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.backgroundColor = .windowBackgroundColor
        panel.isMovable = false

        let container = NSView(frame: panel.contentView?.bounds ?? .zero)

        let field = NSTextField()
        field.translatesAutoresizingMaskIntoConstraints = false
        field.placeholderString = L10n.t(.symbolFilterPlaceholder)
        field.font = .systemFont(ofSize: 13)
        field.focusRingType = .none
        field.delegate = self
        field.isEnabled = !isEmptyState
        self.filterField = field

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let table = NSTableView()
        table.headerView = nil
        table.rowHeight = 20
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.backgroundColor = .clear
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("symbol"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(tableClicked)
        table.action = #selector(tableClicked)
        table.allowsEmptySelection = true
        scroll.documentView = table
        self.tableView = table

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
        // Centred horizontally, in the upper third of the host window.
        let x = frame.minX + (frame.width - size.width) / 2
        let y = frame.minY + frame.height * 0.62
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func observeDismissTriggers(_ panel: NSPanel) {
        NotificationCenter.default.addObserver(
            self, selector: #selector(panelResignedKey),
            name: NSWindow.didResignKeyNotification, object: panel
        )
    }

    @objc private func panelResignedKey() { close() }

    @objc private func tableClicked() { acceptSelection() }

    /// Tears down the panel and releases every piece of runtime state.
    private func close() {
        guard let panel else { return }
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: panel)
        panel.orderOut(nil)
        self.panel = nil
        tableView = nil
        filterField = nil
        allLocations = []
        filtered = []
        let callback = onClose
        onClose = nil
        callback?()
    }

    private func color(for kind: WordIndex.SymbolKind) -> NSColor {
        switch kind {
        case .function: return Self.theme.color(for: .symbolFunction) ?? .labelColor
        case .type:     return Self.theme.color(for: .type) ?? .labelColor
        case .variable: return Self.theme.color(for: .symbolVariable) ?? .labelColor
        }
    }
}

// MARK: - Filter field delegate (typing + navigation keys)

extension SymbolNavigator: NSTextFieldDelegate {
    public func controlTextDidChange(_ obj: Notification) {
        guard let field = filterField else { return }
        filtered = Self.filter(allLocations, query: field.stringValue)
        tableView?.reloadData()
        selectFirstRow()
    }

    public func control(_ control: NSControl,
                        textView: NSTextView,
                        doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(-1); return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(1); return true
        case #selector(NSResponder.insertNewline(_:)):
            acceptSelection(); return true
        case #selector(NSResponder.cancelOperation(_:)):
            close(); return true
        default:
            return false
        }
    }
}

// MARK: - Table data source / delegate

extension SymbolNavigator: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        isEmptyState ? 1 : filtered.count
    }

    public func tableView(_ tableView: NSTableView,
                          viewFor tableColumn: NSTableColumn?,
                          row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let field: NSTextField
        if let reused = tableView.makeView(withIdentifier: id, owner: self) as? NSTextField {
            field = reused
        } else {
            field = NSTextField(labelWithString: "")
            field.identifier = id
            field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            field.lineBreakMode = .byTruncatingTail
        }

        if isEmptyState {
            field.stringValue = L10n.t(.symbolNone)
            field.textColor = .secondaryLabelColor
        } else if row < filtered.count {
            let location = filtered[row]
            field.stringValue = location.name
            field.textColor = color(for: location.kind)
        } else {
            field.stringValue = ""
        }
        return field
    }

    /// The placeholder row is not a selectable target.
    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        !isEmptyState
    }
}

// MARK: - Panel that can take key focus for the filter field

/// A borderless panel that still becomes key, so its filter field receives
/// keystrokes. A plain borderless `NSPanel` cannot, which would leave the field
/// unresponsive.
private final class NavigatorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
