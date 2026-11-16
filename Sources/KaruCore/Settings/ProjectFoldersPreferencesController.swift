import AppKit

/// "Project Folders…" sub-window of Settings (M17 T17.12, plan §10): the
/// folders whose declarations feed the cross-file index, each with its
/// indexed file count, index size on disk and status, plus Clear Index and
/// Remove; Add Folder… opens a directory-only panel (injectable for tests).
/// A notice explains the file cap when a folder hit it. Built when opened from
/// Settings › Code, presented as a sheet on the Settings window and released
/// when it ends (or through `onClose`).
/// Folder paths are machine-local (`ProjectFolderStore`), never exported.
final class ProjectFoldersPreferencesController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    private let titleLabel = SettingsSheet.titleLabel()
    private(set) var doneButton: NSButton!

    struct Row {
        let path: String
        let pathLabel: NSTextField
        let filesLabel: NSTextField
        let diskLabel: NSTextField
        let statusLabel: NSTextField
        let clearButton: NSButton
        let removeButton: NSButton
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
    let grid = NSGridView()
    private var headerLabels: [NSTextField] = []
    private(set) var rows: [Row] = []

    private static let pathWidth: CGFloat = 280

    /// - Parameters:
    ///   - index: the app's index by default.
    ///   - center: where `index` posts `didChangeNotification`.
    ///   - chooseFolder: nil presents an `NSOpenPanel` sheet (directories only).
    init(index: WorkspaceIndex = .shared, center: NotificationCenter = .default,
         chooseFolder: FolderChooser? = nil) {
        self.index = index
        self.center = center
        let window = SettingsSheetWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 260),
                                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.onCancel = { [weak self] in self?.dismissSheet() }
        doneButton = SettingsSheet.doneButton(target: self, action: #selector(doneClicked(_:)))
        self.chooseFolder = chooseFolder ?? { [weak self] reply in self?.presentOpenPanel(reply) }

        help.textColor = .secondaryLabelColor
        help.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        help.preferredMaxLayoutWidth = 600
        emptyLabel.textColor = .secondaryLabelColor
        limitNotice.textColor = .systemOrange
        limitNotice.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        limitNotice.preferredMaxLayoutWidth = 600
        addButton.bezelStyle = .rounded
        addButton.target = self
        addButton.action = #selector(addFolderClicked(_:))

        headerLabels = (0..<4).map { _ in
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            label.textColor = .secondaryLabelColor
            return label
        }
        grid.rowSpacing = 6
        grid.columnSpacing = 12
        grid.rowAlignment = .firstBaseline

        let doneRow = SettingsSheet.trailingRow(doneButton)
        let content = NSStackView(views: [titleLabel, help, grid, emptyLabel, limitNotice, addButton, doneRow])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        // A leading-aligned stack does not reserve its trailing inset for its
        // widest view; without this the grid ran to the window's right edge.
        for wide in [help, grid] as [NSView] {
            content.trailingAnchor.constraint(greaterThanOrEqualTo: wide.trailingAnchor,
                                              constant: content.edgeInsets.right).isActive = true
        }
        doneRow.widthAnchor.constraint(equalTo: content.widthAnchor,
                                       constant: -(content.edgeInsets.left + content.edgeInsets.right)).isActive = true
        window.contentView = content
        // At least the help text's wrapping width: the fitted window followed
        // the grid, and in Chinese (short column titles and buttons) it came
        // out narrower than the 600 pt the help lines wrap at, clipping them
        // at the right edge (T17.15c).
        content.widthAnchor.constraint(
            greaterThanOrEqualToConstant: help.preferredMaxLayoutWidth + content.edgeInsets.left + content.edgeInsets.right
        ).isActive = true

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
        for (label, key) in zip(headerLabels, [L10nKey.projectFoldersColumnFolder, .projectFoldersColumnFiles,
                                               .projectFoldersColumnDisk, .projectFoldersColumnStatus]) {
            label.stringValue = L10n.t(key)
        }
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

    static func sizeTitle(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Rebuilds the rows from the index's statuses and refits the window.
    func reload() {
        let statuses = index.statuses()
        // `removeRow(at:)` drops the row but leaves its content views in the
        // grid's subviews, where they kept drawing under the new row (stale
        // counts, sizes and states overlapping; T17.15c).
        while grid.numberOfRows > 0 {
            let row = grid.row(at: 0)
            for column in 0..<row.numberOfCells {
                if let view = row.cell(at: column).contentView, view !== NSGridCell.emptyContentView {
                    view.removeFromSuperview()
                }
            }
            grid.removeRow(at: 0)
        }
        rows = []
        if !statuses.isEmpty {
            grid.addRow(with: headerLabels + [NSGridCell.emptyContentView, NSGridCell.emptyContentView])
        }
        for (position, status) in statuses.enumerated() {
            let row = makeRow(status, tag: position)
            rows.append(row)
            grid.addRow(with: [row.pathLabel, row.filesLabel, row.diskLabel, row.statusLabel,
                               row.clearButton, row.removeButton])
        }
        if grid.numberOfColumns > 2 {
            grid.column(at: 1).xPlacement = .trailing
            grid.column(at: 2).xPlacement = .trailing
        }
        grid.isHidden = statuses.isEmpty
        emptyLabel.isHidden = !statuses.isEmpty
        if statuses.contains(where: { $0.state == .overLimit }) {
            limitNotice.stringValue = L10n.t(.projectFoldersLimitNotice, index.scope.maxFiles)
            limitNotice.isHidden = false
        } else {
            limitNotice.isHidden = true
        }
        refitWindow()
    }

    private func makeRow(_ status: WorkspaceIndex.FolderStatus, tag: Int) -> Row {
        let pathLabel = NSTextField(labelWithString: (status.path as NSString).abbreviatingWithTildeInPath)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.toolTip = status.path
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.widthAnchor.constraint(equalToConstant: Self.pathWidth).isActive = true
        let filesLabel = NSTextField(labelWithString: "\(status.indexedFiles)")
        filesLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let diskLabel = NSTextField(labelWithString: Self.sizeTitle(status.diskBytes))
        diskLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let statusLabel = NSTextField(labelWithString: Self.stateTitle(status.state))
        if status.state == .overLimit || status.state == .unreadable { statusLabel.textColor = .systemOrange }
        let clearButton = NSButton(title: L10n.t(.projectFoldersClear), target: self, action: #selector(clearClicked(_:)))
        clearButton.tag = tag
        clearButton.isEnabled = index.isEnabled
        let removeButton = NSButton(title: L10n.t(.projectFoldersRemove), target: self, action: #selector(removeClicked(_:)))
        removeButton.tag = tag
        for button in [clearButton, removeButton] { button.bezelStyle = .rounded; button.controlSize = .small }
        return Row(path: status.path, pathLabel: pathLabel, filesLabel: filesLabel, diskLabel: diskLabel,
                   statusLabel: statusLabel, clearButton: clearButton, removeButton: removeButton)
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
