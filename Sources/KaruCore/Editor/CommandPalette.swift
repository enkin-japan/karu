import AppKit

/// ⌘⇧P "Command Palette" (T12.8).
///
/// A transient, floating panel that lists every actionable menu command reached
/// from `NSApp.mainMenu`, with a fuzzy filter field, ↑↓ selection, ⏎ to run and
/// Esc to close. Modelled directly on `SymbolNavigator`: the command list is
/// built by a single recursive walk of the live menu tree at open time — **no**
/// cached command index, **no** observer. Closing the panel drops the list, the
/// table and the panel itself, so a closed palette's resident cost is ≈ 0. The
/// owning `EditorWindowController` also releases its reference on close (via
/// `onClose`), so the whole object is deallocated between uses (ARCHITECTURE.md
/// §3.4 "瞬时不常驻").
@MainActor
public final class CommandPalette: NSObject {
    private weak var textView: NSTextView?

    /// A single runnable menu command captured from the menu tree at open time.
    /// Holds the owning `NSMenu` weakly and the item's index within it, so
    /// execution routes through `NSMenu.performActionForItem(at:)` — exactly
    /// equivalent to the user clicking the item (respects the first responder /
    /// validate chain).
    struct Command {
        /// Display label, e.g. "Edit ▸ Copy" (top-level app menus omit the parent).
        let title: String
        /// Rendered keyboard shortcut (e.g. "⌘⇧P"), or "" when the item has none.
        let shortcut: String
        weak var menu: NSMenu?
        let index: Int
    }

    // MARK: Transient runtime state (all released on close)
    private var panel: NSPanel?
    private var tableView: NSTableView?
    private var filterField: NSTextField?
    private var allCommands: [Command] = []
    private var filtered: [Command] = []
    private var onClose: (() -> Void)?

    public init(textView: NSTextView) {
        self.textView = textView
        super.init()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// True while the palette panel is on screen.
    public var isVisible: Bool { panel?.isVisible == true }

    // MARK: - Fuzzy matching (pure, unit-testable)

    /// Case-insensitive subsequence score of `query` against `candidate`, or
    /// `nil` when `query` is not a subsequence of `candidate`. Larger is better.
    ///
    /// The scoring rewards, in decreasing weight: a whole-string prefix hit, a
    /// match at a word boundary (start / after a non-alphanumeric), and
    /// consecutive matched characters — so ranking is *prefix hit > word-start
    /// hit > scattered hit*. An empty query scores 0 (matches everything).
    nonisolated public static func fuzzyScore(query: String, candidate: String) -> Int? {
        let q = Array(query.lowercased())
        guard !q.isEmpty else { return 0 }
        let c = Array(candidate.lowercased())

        var qi = 0
        var score = 0
        var prevMatch = -2
        for (ci, ch) in c.enumerated() {
            guard qi < q.count else { break }
            guard ch == q[qi] else { continue }
            var bonus = 1
            if ci == prevMatch + 1 { bonus += 5 }          // consecutive run
            let boundary = ci == 0 || !isWordChar(c[ci - 1])
            if boundary { bonus += 10 }                    // word-start
            score += bonus
            prevMatch = ci
            qi += 1
        }
        guard qi == q.count else { return nil }
        if c.starts(with: q) { score += 100 }              // whole-string prefix
        return score
    }

    nonisolated private static func isWordChar(_ ch: Character) -> Bool {
        ch.isLetter || ch.isNumber
    }

    /// Filters `commands` by fuzzy-matching `query` against each title and
    /// returns the survivors ordered by score (descending), ties broken by the
    /// original document order (stable). An empty / whitespace query returns the
    /// list unchanged (menu order).
    static func filter(_ commands: [Command], query: String) -> [Command] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return commands }
        let scored: [(index: Int, command: Command, score: Int)] = commands.enumerated().compactMap {
            guard let score = fuzzyScore(query: needle, candidate: $0.element.title) else { return nil }
            return (index: $0.offset, command: $0.element, score: score)
        }
        return scored.sorted {
            $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index
        }.map(\.command)
    }

    // MARK: - Menu enumeration (transient — never cached)

    /// Recursively walks `NSApp.mainMenu` and collects every actionable leaf
    /// item that is currently enabled, as a `Command`. Separators and items with
    /// no action are skipped; submenu parents are recursed into but not listed.
    ///
    /// Each visited submenu is `update()`d first so `validateMenuItem` runs
    /// against the *current* first responder (the editor, while this executes
    /// before the panel takes key) — greyed-out items are therefore excluded.
    static func collectCommands(from menu: NSMenu, parentTitle: String?) -> [Command] {
        menu.update()
        var result: [Command] = []
        for (index, item) in menu.items.enumerated() {
            if item.isSeparatorItem { continue }
            if let submenu = item.submenu {
                // Top-level app menus contribute their title as the parent; nested
                // submenus prepend "Parent ▸ ".
                let childParent: String
                if let parentTitle {
                    childParent = "\(parentTitle) ▸ \(item.title)"
                } else {
                    childParent = item.title
                }
                result.append(contentsOf: collectCommands(from: submenu, parentTitle: childParent))
                continue
            }
            guard item.action != nil, item.isEnabled, !item.title.isEmpty else { continue }
            let label = parentTitle.map { "\($0) ▸ \(item.title)" } ?? item.title
            result.append(Command(title: label,
                                  shortcut: shortcutString(for: item),
                                  menu: menu,
                                  index: index))
        }
        return result
    }

    /// Renders an item's key equivalent as its macOS symbol string (e.g. "⌘⇧P"),
    /// or "" when the item has no shortcut.
    static func shortcutString(for item: NSMenuItem) -> String {
        guard !item.keyEquivalent.isEmpty else { return "" }
        var out = ""
        let mask = item.keyEquivalentModifierMask
        if mask.contains(.control) { out += "⌃" }
        if mask.contains(.option) { out += "⌥" }
        if mask.contains(.shift) { out += "⇧" }
        if mask.contains(.command) { out += "⌘" }
        out += displayKey(item.keyEquivalent)
        return out
    }

    private static func displayKey(_ key: String) -> String {
        switch key {
        case "\r": return "⏎"
        case "\t": return "⇥"
        case " ": return "␣"
        case String(UnicodeScalar(NSUpArrowFunctionKey)!): return "↑"
        case String(UnicodeScalar(NSDownArrowFunctionKey)!): return "↓"
        case String(UnicodeScalar(NSLeftArrowFunctionKey)!): return "←"
        case String(UnicodeScalar(NSRightArrowFunctionKey)!): return "→"
        default: return key.uppercased()
        }
    }

    // MARK: - Presentation

    /// Enumerates the live menu tree once and shows the palette. `onClose` lets
    /// the owner drop its strong reference so the palette is fully released when
    /// the panel goes away.
    public func present(onClose: (() -> Void)? = nil) {
        self.onClose = onClose

        if let mainMenu = NSApp.mainMenu {
            allCommands = Self.collectCommands(from: mainMenu, parentTitle: nil)
        } else {
            allCommands = []
        }
        filtered = allCommands

        let panel = makePanel()
        self.panel = panel
        tableView?.reloadData()
        selectFirstRow()
        positionPanel(panel)
        panel.makeKeyAndOrderFront(nil)
        if let filterField { panel.makeFirstResponder(filterField) }
        observeDismissTriggers(panel)
    }

    private var isEmptyState: Bool { allCommands.isEmpty }

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
        guard let table = tableView,
              table.selectedRow >= 0, table.selectedRow < filtered.count else { return }
        run(filtered[table.selectedRow])
    }

    /// Closes the palette (restoring the editor as key / first responder) and
    /// then performs the command exactly as a menu click would — so validation
    /// runs against the editor context, not the (now-gone) palette field.
    private func run(_ command: Command) {
        let window = textView?.window
        let textView = self.textView
        let menu = command.menu
        let index = command.index
        close()
        window?.makeKeyAndOrderFront(nil)
        if let textView { window?.makeFirstResponder(textView) }
        guard let menu, index >= 0, index < menu.numberOfItems else { return }
        menu.performActionForItem(at: index)
    }

    // MARK: - Panel lifecycle

    private func makePanel() -> NSPanel {
        let panel = PalettePanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
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
        field.placeholderString = L10n.t(.commandPalettePlaceholder)
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
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.backgroundColor = .clear
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
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
        allCommands = []
        filtered = []
        let callback = onClose
        onClose = nil
        callback?()
    }
}

// MARK: - Filter field delegate (typing + navigation keys)

extension CommandPalette: NSTextFieldDelegate {
    public func controlTextDidChange(_ obj: Notification) {
        guard let field = filterField else { return }
        filtered = Self.filter(allCommands, query: field.stringValue)
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

extension CommandPalette: NSTableViewDataSource, NSTableViewDelegate {
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
            field.lineBreakMode = .byTruncatingTail
        }

        if isEmptyState {
            field.attributedStringValue = NSAttributedString(
                string: L10n.t(.commandPaletteEmpty),
                attributes: [.foregroundColor: NSColor.secondaryLabelColor,
                             .font: NSFont.systemFont(ofSize: 12)])
        } else if row < filtered.count {
            field.attributedStringValue = Self.rowText(filtered[row])
        } else {
            field.stringValue = ""
        }
        return field
    }

    /// Builds the row label: the command title, then its shortcut (if any) in a
    /// dimmer colour trailing the title.
    static func rowText(_ command: Command) -> NSAttributedString {
        let out = NSMutableAttributedString(
            string: command.title,
            attributes: [.foregroundColor: NSColor.labelColor,
                         .font: NSFont.systemFont(ofSize: 13)])
        if !command.shortcut.isEmpty {
            out.append(NSAttributedString(
                string: "  " + command.shortcut,
                attributes: [.foregroundColor: NSColor.secondaryLabelColor,
                             .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]))
        }
        return out
    }

    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        !isEmptyState
    }
}

// MARK: - Panel that can take key focus for the filter field

/// A borderless panel that still becomes key, so its filter field receives
/// keystrokes (mirrors `SymbolNavigator`'s `NavigatorPanel`).
private final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
