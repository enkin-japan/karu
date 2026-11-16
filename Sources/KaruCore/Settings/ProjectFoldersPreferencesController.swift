import AppKit

/// "Project Folders…" sub-window of Settings (M17 T17.12, plan §10): the
/// folders whose declarations feed the cross-file index, shown as a table
/// (folder name and path, indexed file count, index size on disk, status with
/// a symbol, and Clear Index / Remove per row); Add Folder… opens a
/// directory-only panel (injectable for tests). A notice explains the file
/// cap when a folder hit it. Built when opened from Settings › Code, presented
/// as a sheet on the Settings window and released when it ends (or through
/// `onClose`).
/// Folder paths are machine-local (`ProjectFolderStore`), never exported.
final class ProjectFoldersPreferencesController: NSWindowController, NSWindowDelegate,
    NSTableViewDataSource, NSTableViewDelegate {
    var onClose: (() -> Void)?
    private let titleLabel = SettingsSheet.titleLabel()
    private(set) var doneButton: NSButton!

    /// What one table row shows for a folder.
    struct Row: Equatable {
        let path: String
        /// The folder's own name (`lastPathComponent`).
        let name: String
        /// The tilde-abbreviated path.
        let displayPath: String
        let filesText: String
        let sizeText: String
        let statusText: String
        let symbolName: String
        let state: WorkspaceIndex.State

        init(_ status: WorkspaceIndex.FolderStatus) {
            path = status.path
            name = (status.path as NSString).lastPathComponent
            displayPath = (status.path as NSString).abbreviatingWithTildeInPath
            filesText = "\(status.indexedFiles)"
            sizeText = ProjectFoldersPreferencesController.sizeTitle(status.diskBytes)
            statusText = ProjectFoldersPreferencesController.stateTitle(status.state)
            symbolName = ProjectFoldersPreferencesController.symbolName(status.state)
            state = status.state
        }

        /// Over limit and unreadable are drawn in orange (symbol and text).
        var isWarning: Bool { state == .overLimit || state == .unreadable }
    }

    enum Column: String, CaseIterable {
        case folder, files, disk, status, actions
        var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier("projectFolders." + rawValue) }
    }

    /// Presents a folder chooser and replies with the chosen URL (nil: cancelled).
    typealias FolderChooser = (@escaping (URL?) -> Void) -> Void

    let index: WorkspaceIndex
    private let center: NotificationCenter
    private var chooseFolder: FolderChooser!
    private let help = NSTextField(wrappingLabelWithString: "")
    let emptyLabel = NSTextField(labelWithString: "")
    let limitNotice = NSTextField(wrappingLabelWithString: "")
    private let addButton = NSButton()
    let table = NSTableView()
    let scrollView = NSScrollView()
    private var scrollHeight: NSLayoutConstraint!
    private(set) var rows: [Row] = []
    /// Set by `layoutColumns()` when the status column is too narrow for one
    /// line of regular text: the status then wraps in the small font.
    private(set) var compactStatus = false
    /// Whether Clear Index and Remove share one width (see `layoutColumns()`).
    private(set) var equalActionWidths = true

    /// The sheet's fixed width and insets.
    /// Wide enough for the Japanese column and button titles to leave the
    /// Folder column a readable width.
    static let sheetWidth: CGFloat = 760
    static let insets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
    static var innerWidth: CGFloat { sheetWidth - insets.left - insets.right }
    static let rowHeight: CGFloat = 36
    /// Rows visible before the table scrolls.
    static let maxVisibleRows = 6
    private static let intercell = NSSize(width: 6, height: 0)
    private static let cellInset: CGFloat = 2
    private static let symbolWidth: CGFloat = 16
    private static let symbolGap: CGFloat = 5
    private static let buttonGap: CGFloat = 6
    /// The folder column keeps at least this much before the status column
    /// gives up its single-line width (see `layoutColumns()`).
    private static let folderMinWidth: CGFloat = 170
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

    /// - Parameters:
    ///   - index: the app's index by default.
    ///   - center: where `index` posts `didChangeNotification`.
    ///   - chooseFolder: nil presents an `NSOpenPanel` sheet (directories only).
    init(index: WorkspaceIndex = .shared, center: NotificationCenter = .default,
         chooseFolder: FolderChooser? = nil) {
        self.index = index
        self.center = center
        let window = SettingsSheetWindow(contentRect: NSRect(x: 0, y: 0, width: Self.sheetWidth, height: 260),
                                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.onCancel = { [weak self] in self?.dismissSheet() }
        doneButton = SettingsSheet.doneButton(target: self, action: #selector(doneClicked(_:)))
        self.chooseFolder = chooseFolder ?? { [weak self] reply in self?.presentOpenPanel(reply) }

        help.textColor = .secondaryLabelColor
        help.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        help.preferredMaxLayoutWidth = Self.innerWidth
        emptyLabel.textColor = .secondaryLabelColor
        limitNotice.textColor = .systemOrange
        limitNotice.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        limitNotice.preferredMaxLayoutWidth = Self.innerWidth
        addButton.bezelStyle = .rounded
        addButton.target = self
        addButton.action = #selector(addFolderClicked(_:))

        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: column.identifier)
            tableColumn.resizingMask = column == .folder ? .autoresizingMask : []
            tableColumn.headerCell.alignment = column == .files || column == .disk ? .right : .left
            table.addTableColumn(tableColumn)
        }
        table.style = .fullWidth
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = Self.intercell
        table.selectionHighlightStyle = .none
        table.usesAlternatingRowBackgroundColors = false
        table.allowsColumnReordering = false
        table.allowsColumnResizing = false
        table.focusRingType = .none
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        scrollView.documentView = table
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollHeight = scrollView.heightAnchor.constraint(equalToConstant: 100)
        scrollHeight.isActive = true

        let bottomRow = NSStackView()
        bottomRow.orientation = .horizontal
        bottomRow.setViews([addButton], in: .leading)
        bottomRow.setViews([doneButton], in: .trailing)
        let content = NSStackView(views: [titleLabel, help, scrollView, emptyLabel, limitNotice, bottomRow])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.edgeInsets = Self.insets
        for wide in [help, scrollView, bottomRow] as [NSView] {
            wide.widthAnchor.constraint(equalToConstant: Self.innerWidth).isActive = true
        }
        window.contentView = content
        // A fixed width: long paths truncate inside the table instead of
        // widening the sheet, and the help text always wraps at the inner
        // width (T17.15c: Chinese once clipped it at the right edge).
        content.widthAnchor.constraint(equalToConstant: Self.sheetWidth).isActive = true

        center.addObserver(self, selector: #selector(indexChanged),
                           name: WorkspaceIndex.didChangeNotification, object: index)
        NotificationCenter.default.addObserver(self, selector: #selector(reloadStrings),
                                               name: L10n.didChangeNotification, object: nil)
        reloadStrings()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        center.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Content

    @objc private func reloadStrings() {
        window?.title = SettingsSheet.title(.projectFoldersTitle)
        titleLabel.stringValue = SettingsSheet.title(.projectFoldersTitle)
        doneButton.title = L10n.t(.findDone)
        help.stringValue = L10n.t(.projectFoldersHelp)
        emptyLabel.stringValue = L10n.t(.projectFoldersEmpty)
        addButton.title = L10n.t(.projectFoldersAdd)
        let titles: [Column: L10nKey] = [.folder: .projectFoldersColumnFolder, .files: .projectFoldersColumnFiles,
                                         .disk: .projectFoldersColumnDisk, .status: .projectFoldersColumnStatus]
        for column in Column.allCases {
            tableColumn(column).title = titles[column].map { L10n.t($0) } ?? ""
        }
        table.headerView?.needsDisplay = true
        reload()
    }

    @objc private func indexChanged() { reload() }

    static func stateTitle(_ state: WorkspaceIndex.State) -> String {
        switch state {
        case .indexing: return L10n.t(.projectFolderStateIndexing)
        case .upToDate: return L10n.t(.projectFolderStateUpToDate)
        case .overLimit: return L10n.t(.projectFolderStateOverLimit)
        case .unreadable: return L10n.t(.projectFolderStateUnreadable)
        case .paused: return L10n.t(.projectFolderStatePaused)
        }
    }

    /// The SF Symbol shown before a state's text (the text carries the
    /// meaning; the symbol and colour only reinforce it).
    static func symbolName(_ state: WorkspaceIndex.State) -> String {
        switch state {
        case .indexing: return "arrow.triangle.2.circlepath"
        case .upToDate: return "checkmark.circle"
        case .overLimit: return "exclamationmark.triangle"
        case .unreadable: return "xmark.octagon"
        case .paused: return "pause.circle"
        }
    }

    static func sizeTitle(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Rebuilds the rows from the index's statuses and refits the window.
    /// The table builds fresh cell views on every reload, so no stale
    /// content survives (T17.15c: the old grid kept drawing replaced labels).
    func reload() {
        let statuses = index.statuses()
        rows = statuses.map(Row.init)
        layoutColumns()
        table.reloadData()
        scrollHeight.constant = Self.scrollHeight(rows: rows.count, header: table.headerView?.frame.height ?? 0)
        scrollView.isHidden = rows.isEmpty
        emptyLabel.isHidden = !rows.isEmpty
        if rows.contains(where: { $0.state == .overLimit }) {
            limitNotice.stringValue = L10n.t(.projectFoldersLimitNotice, index.scope.maxFiles)
            limitNotice.isHidden = false
        } else {
            limitNotice.isHidden = true
        }
        refitWindow()
    }

    /// Header plus up to `maxVisibleRows` rows; more rows scroll.
    private static func scrollHeight(rows: Int, header: CGFloat) -> CGFloat {
        let visible = CGFloat(min(max(rows, 1), maxVisibleRows))
        let content = NSSize(width: innerWidth, height: header + visible * (rowHeight + intercell.height))
        return NSScrollView.frameSize(forContentSize: content, horizontalScrollerClass: nil,
                                      verticalScrollerClass: nil, borderType: .bezelBorder,
                                      controlSize: .regular, scrollerStyle: .overlay).height.rounded(.up)
    }

    // MARK: - Columns

    private func tableColumn(_ column: Column) -> NSTableColumn {
        table.tableColumns.first { $0.identifier == column.identifier }!
    }

    private static func textWidth(_ text: String, _ font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
    }

    /// The narrowest width at which `text` wraps to at most two lines in `font`.
    private static func twoLineWidth(_ text: String, _ font: NSFont) -> CGFloat {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = font
        let full = textWidth(text, font) + 4
        let line = field.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: full + 100, height: 1000)).height
        var width = (full / 2).rounded(.up)
        while width < full,
              field.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 1000)).height > 2 * line + 0.5 {
            width += 2
        }
        return width
    }

    /// Sizes the columns to the current language and rows. Files and size fit
    /// their header and content; the folder column takes what is left. While
    /// the folder column keeps `folderMinWidth`, the status text stays on one
    /// line in the regular font and the action buttons share one width; when
    /// it would not (long translations, e.g. the Japanese paused state), the
    /// status first wraps to two lines in the small font, then the buttons
    /// fall back to their own widths.
    private func layoutColumns() {
        let pad = 2 * Self.cellInset
        func header(_ column: Column) -> CGFloat { tableColumn(column).headerCell.cellSize.width.rounded(.up) + pad }
        let files = max(header(.files), (rows.map { Self.textWidth($0.filesText, Self.valueFont) }.max() ?? 0) + pad + 4)
        let disk = max(header(.disk), (rows.map { Self.textWidth($0.sizeText, Self.valueFont) }.max() ?? 0) + pad + 4)
        let buttonWidths = actionButtons(tag: 0).map { $0.fittingSize.width.rounded(.up) }
        let equalActions = 2 * (buttonWidths.max() ?? 0) + Self.buttonGap + pad
        let ownActions = buttonWidths.reduce(0, +) + Self.buttonGap + pad
        let symbol = Self.symbolWidth + Self.symbolGap + pad + 2
        let regular = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let lineStatus = max(header(.status), symbol + (rows.map { Self.textWidth($0.statusText, regular) }.max() ?? 0))
        let wrappedStatus = max(header(.status), symbol + (rows.map { Self.twoLineWidth($0.statusText, small) }.max() ?? 0))

        let available = NSScrollView.contentSize(forFrameSize: NSSize(width: Self.innerWidth, height: 200),
                                                 horizontalScrollerClass: nil, verticalScrollerClass: nil,
                                                 borderType: .bezelBorder, controlSize: .regular, scrollerStyle: .overlay)
            .width - CGFloat(Column.allCases.count) * Self.intercell.width
        let options: [(actions: CGFloat, status: CGFloat, compact: Bool, equal: Bool)] = [
            (equalActions, lineStatus, false, true),
            (equalActions, wrappedStatus, true, true),
            (ownActions, wrappedStatus, true, false),
        ]
        let chosen = options.first { available - files - disk - $0.actions - $0.status >= Self.folderMinWidth }
            ?? options[options.count - 1]
        compactStatus = chosen.compact
        equalActionWidths = chosen.equal
        let widths: [Column: CGFloat] = [
            .files: files, .disk: disk, .actions: chosen.actions, .status: chosen.status,
            .folder: max(available - files - disk - chosen.actions - chosen.status, 40),
        ]
        for column in Column.allCases {
            let tableColumn = tableColumn(column)
            tableColumn.minWidth = min(widths[column]!, 40)
            tableColumn.width = widths[column]!
        }
    }

    // MARK: - Cells

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier else { return nil }
        return cellView(row: row, column: identifier)
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    /// The configured cell for `row` and the column `identifier` (the same
    /// path the table delegate uses; tests call it without a visible window).
    func cellView(row: Int, column identifier: NSUserInterfaceItemIdentifier) -> NSView? {
        guard rows.indices.contains(row),
              let column = Column.allCases.first(where: { $0.identifier == identifier }) else { return nil }
        return makeCell(rows[row], row: row, column: column)
    }

    /// The status cell for any row model (tests: every state without indexing).
    func statusCell(for model: Row) -> NSTableCellView? {
        makeCell(model, row: 0, column: .status)
    }

    private func makeCell(_ model: Row, row: Int, column: Column) -> NSTableCellView {
        let identifier = column.identifier
        let cell = NSTableCellView()
        cell.identifier = identifier
        switch column {
        case .folder:
            let name = Self.label(model.name, font: .systemFont(ofSize: NSFont.systemFontSize))
            name.lineBreakMode = .byTruncatingTail
            name.identifier = NSUserInterfaceItemIdentifier("projectFolders.name")
            let path = Self.label(model.displayPath, font: .systemFont(ofSize: NSFont.smallSystemFontSize))
            path.textColor = .secondaryLabelColor
            path.lineBreakMode = .byTruncatingMiddle
            path.identifier = NSUserInterfaceItemIdentifier("projectFolders.path")
            let stack = NSStackView(views: [name, path])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 1
            for label in [name, path] {
                label.toolTip = model.path
                label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            cell.toolTip = model.path
            cell.textField = name
            fill(cell, with: stack)
        case .files, .disk:
            let label = Self.label(column == .files ? model.filesText : model.sizeText, font: Self.valueFont)
            label.alignment = .right
            cell.textField = label
            fill(cell, with: label)
        case .status:
            let symbol = NSImageView()
            symbol.image = NSImage(systemSymbolName: model.symbolName, accessibilityDescription: nil)
            symbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: NSFont.systemFontSize, weight: .regular)
            symbol.contentTintColor = model.isWarning ? .systemOrange : .secondaryLabelColor
            symbol.setAccessibilityElement(false)
            symbol.identifier = NSUserInterfaceItemIdentifier("projectFolders.statusSymbol")
            symbol.translatesAutoresizingMaskIntoConstraints = false
            symbol.widthAnchor.constraint(equalToConstant: Self.symbolWidth).isActive = true
            let font = compactStatus ? NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
                : NSFont.systemFont(ofSize: NSFont.systemFontSize)
            let text = NSTextField(wrappingLabelWithString: model.statusText)
            text.font = font
            text.textColor = model.isWarning ? .systemOrange : .labelColor
            text.maximumNumberOfLines = 2
            text.cell?.truncatesLastVisibleLine = true
            text.lineBreakMode = .byWordWrapping
            text.toolTip = model.statusText
            text.preferredMaxLayoutWidth = max(tableColumn(.status).width - 2 * Self.cellInset
                                               - Self.symbolWidth - Self.symbolGap, 10)
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            text.identifier = NSUserInterfaceItemIdentifier("projectFolders.statusText")
            let stack = NSStackView(views: [symbol, text])
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = Self.symbolGap
            cell.imageView = symbol
            cell.textField = text
            fill(cell, with: stack)
        case .actions:
            let buttons = actionButtons(tag: row)
            let width = buttons.map { $0.fittingSize.width.rounded(.up) }.max() ?? 0
            for button in buttons where equalActionWidths {
                button.translatesAutoresizingMaskIntoConstraints = false
                button.widthAnchor.constraint(equalToConstant: width).isActive = true
            }
            let stack = NSStackView(views: buttons)
            stack.orientation = .horizontal
            stack.spacing = Self.buttonGap
            fill(cell, with: stack, leadingOnly: true)
        }
        return cell
    }

    /// The Clear Index and Remove buttons for row `tag`.
    private func actionButtons(tag: Int) -> [NSButton] {
        let clearButton = NSButton(title: L10n.t(.projectFoldersClear), target: self, action: #selector(clearClicked(_:)))
        clearButton.identifier = NSUserInterfaceItemIdentifier("projectFolders.clear")
        clearButton.isEnabled = index.isEnabled
        let removeButton = NSButton(title: L10n.t(.projectFoldersRemove), target: self, action: #selector(removeClicked(_:)))
        removeButton.identifier = NSUserInterfaceItemIdentifier("projectFolders.remove")
        for button in [clearButton, removeButton] {
            button.tag = tag
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        }
        return [clearButton, removeButton]
    }

    private static func label(_ text: String, font: NSFont) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    /// Pins `view` inside `cell`, vertically centred.
    private func fill(_ cell: NSTableCellView, with view: NSView, leadingOnly: Bool = false) {
        view.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(view)
        let trailing = leadingOnly
            ? view.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -Self.cellInset)
            : view.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -Self.cellInset)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: Self.cellInset),
            trailing,
            view.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
    }

    /// Resizes the window to its content, keeping the top edge in place. As a
    /// sheet it also stays centred on its parent (a sheet hangs from the
    /// parent's title bar, so the top edge must not move).
    private func refitWindow() {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        let x = window.sheetParent.map { $0.frame.midX - frame.width / 2 } ?? window.frame.minX
        frame.origin = NSPoint(x: x.rounded(), y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: window.isVisible)
    }

    /// Done / Esc: ends the sheet (closes the window when it is not a sheet).
    func dismissSheet() {
        SettingsSheet.dismiss(window)
    }

    @objc private func doneClicked(_ sender: Any?) { dismissSheet() }

    // MARK: - Actions

    @objc func addFolderClicked(_ sender: Any?) {
        chooseFolder { [weak self] url in
            guard let self, let url else { return }
            self.index.addFolder(url)
            self.reload()
        }
    }

    private func presentOpenPanel(_ reply: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.t(.projectFoldersAdd).replacingOccurrences(of: "…", with: "")
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            reply(response == .OK ? panel.url : nil)
        }
        if let window, window.isVisible { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    @objc private func clearClicked(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag) else { return }
        index.clearIndex(rows[sender.tag].path) { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    @objc private func removeClicked(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag) else { return }
        let path = rows[sender.tag].path
        index.removeFolder(path) { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    /// Clear Index for row `position`; returns once the rebuild is queued.
    func clearIndex(at position: Int) async {
        guard rows.indices.contains(position) else { return }
        let path = rows[position].path
        await withCheckedContinuation { continuation in
            index.clearIndex(path) { continuation.resume() }
        }
        reload()
    }

    /// Remove for row `position`; returns once its database is deleted.
    func removeFolder(at position: Int) async {
        guard rows.indices.contains(position) else { return }
        let path = rows[position].path
        await withCheckedContinuation { continuation in
            index.removeFolder(path) { continuation.resume() }
        }
        reload()
    }

    func windowWillClose(_ notification: Notification) { onClose?() }
}
