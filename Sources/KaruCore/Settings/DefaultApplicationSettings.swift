import AppKit
import UniformTypeIdentifiers

struct DefaultFileType {
    let type: UTType
    let extensions: [String]
    var title: String { extensions.map { "." + $0 }.joined(separator: ", ") }
}

@MainActor
protocol DefaultApplicationManaging {
    var applicationURL: URL? { get }
    func currentApplication(for type: UTType) -> URL?
    func setDefault(for type: UTType) async throws
}

@MainActor
final class DefaultApplicationSettings: DefaultApplicationManaging {
    nonisolated static let extensions = ["txt", "log", "md", "markdown", "json", "jsonl", "ndjson", "py", "pyw",
        "js", "mjs", "cjs", "ts", "html", "htm", "css", "c", "h", "cpp", "cc", "cxx", "hpp", "hh",
        "cs", "java", "sh", "bash", "zsh", "sql", "xml", "plist", "svg", "cfg", "ini", "yaml", "yml",
        "toml", "go", "rs", "swift"]

    /// Group aliases before offering a change: Launch Services works by UTI,
    /// not independently by extension. Never assign a generic data/media type.
    static func fileTypes(extensions: [String] = extensions,
                          resolve: (String) -> UTType? = { UTType(filenameExtension: $0) }) -> [DefaultFileType] {
        var groups: [String: (UTType, Set<String>)] = [:]
        for ext in extensions {
            guard let type = resolve(ext), ![UTType.data, .item, .content, .text, .sourceCode].contains(type),
                  type.isDynamic || type.conforms(to: .text) || type.conforms(to: .json)
                    || type.conforms(to: .xml) || type.conforms(to: .propertyList) else { continue }
            var value = groups[type.identifier] ?? (type, [])
            value.1.insert(ext)
            groups[type.identifier] = value
        }
        return groups.values.map { DefaultFileType(type: $0.0, extensions: $0.1.sorted()) }.sorted { $0.title < $1.title }
    }
    var applicationURL: URL? {
        let bundle = Bundle.main
        guard bundle.bundleIdentifier == "dev.enkin.TinyEditor", bundle.bundleURL.pathExtension == "app" else { return nil }
        return bundle.bundleURL
    }
    func currentApplication(for type: UTType) -> URL? { NSWorkspace.shared.urlForApplication(toOpen: type) }
    func setDefault(for type: UTType) async throws {
        guard let applicationURL else { throw SettingsArchive.Failure.value(L10n.t(.fileDefaultsInstalledOnly)) }
        try await NSWorkspace.shared.setDefaultApplication(at: applicationURL, toOpen: type)
        guard currentApplication(for: type)?.standardizedFileURL == applicationURL.standardizedFileURL else {
            throw NSError(domain: "Karu.DefaultApplication", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: L10n.t(.fileDefaultsNotChanged)])
        }
    }
    static func appName(_ url: URL?) -> String {
        guard let url else { return L10n.t(.fileDefaultsUnknown) }
        let bundle = Bundle(url: url)
        return bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
    }
}

final class DefaultApplicationPreferencesController: NSWindowController, NSWindowDelegate,
    NSTableViewDelegate, NSTableViewDataSource, NSSearchFieldDelegate {
    var onClose: (() -> Void)?
    private let service: DefaultApplicationManaging
    private let types: [DefaultFileType]
    private var filtered: [DefaultFileType] = []
    private var current: [String: URL] = [:]
    private let search = NSSearchField()
    private let table = NSTableView()
    private let applyButton = NSButton()
    private let refreshButton = NSButton()
    private let message = NSTextField(wrappingLabelWithString: "")
    private var busy = false

    init(service: DefaultApplicationManaging? = nil, types: [DefaultFileType]? = nil) {
        self.service = service ?? DefaultApplicationSettings()
        self.types = types ?? DefaultApplicationSettings.fileTypes()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 510),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 620, height: 430)
        super.init(window: window)
        window.delegate = self; window.center()
        window.title = L10n.t(.fileDefaultsTitle)
        search.placeholderString = L10n.t(.fileDefaultsSearch); search.delegate = self
        for (id, title, width) in [("format", L10n.t(.fileDefaultsFormat), 360.0), ("app", L10n.t(.fileDefaultsCurrent), 270.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width
            table.addTableColumn(column)
        }
        table.delegate = self; table.dataSource = self; table.allowsMultipleSelection = true
        table.rowHeight = 28; table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        applyButton.title = L10n.t(.fileDefaultsApply); applyButton.bezelStyle = .rounded
        applyButton.target = self; applyButton.action = #selector(applySelected)
        refreshButton.title = L10n.t(.fileDefaultsRefresh); refreshButton.bezelStyle = .rounded
        refreshButton.target = self; refreshButton.action = #selector(refresh)
        let buttons = NSStackView(views: [applyButton, refreshButton]); buttons.spacing = 8
        let content = NSView(); window.contentView = content
        for view in [search, scroll, buttons, message] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            search.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            search.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: search.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: search.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),
            buttons.leadingAnchor.constraint(equalTo: search.leadingAnchor),
            buttons.bottomAnchor.constraint(equalTo: message.topAnchor, constant: -10),
            message.leadingAnchor.constraint(equalTo: search.leadingAnchor), message.trailingAnchor.constraint(equalTo: search.trailingAnchor),
            message.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            message.heightAnchor.constraint(greaterThanOrEqualToConstant: 70),
        ])
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func refresh() {
        guard !busy else { return }
        window?.title = L10n.t(.fileDefaultsTitle).replacingOccurrences(of: "…", with: "")
        search.placeholderString = L10n.t(.fileDefaultsSearch)
        table.tableColumns[0].title = L10n.t(.fileDefaultsFormat)
        table.tableColumns[1].title = L10n.t(.fileDefaultsCurrent)
        applyButton.title = L10n.t(.fileDefaultsApply)
        refreshButton.title = L10n.t(.fileDefaultsRefresh)
        current = [:]
        for row in types { current[row.type.identifier] = service.currentApplication(for: row.type) }
        filter()
        message.textColor = .secondaryLabelColor
        message.stringValue = service.applicationURL == nil ? L10n.t(.fileDefaultsInstalledOnly) : L10n.t(.fileDefaultsHelp)
    }
    private func filter() {
        let q = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        filtered = types.filter { q.isEmpty || $0.title.localizedCaseInsensitiveContains(q) || ($0.type.localizedDescription ?? "").localizedCaseInsensitiveContains(q) }
        table.deselectAll(nil); table.reloadData(); updateButtons()
    }
    private func updateButtons() { applyButton.isEnabled = !busy && table.selectedRow >= 0 && service.applicationURL != nil }
    func controlTextDidChange(_ obj: Notification) { if !busy { filter() } }
    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = filtered[row]
        let text = tableColumn?.identifier.rawValue == "format" ? entry.title : DefaultApplicationSettings.appName(current[entry.type.identifier])
        let label = NSTextField(labelWithString: text); label.lineBreakMode = .byTruncatingTail
        label.toolTip = tableColumn?.identifier.rawValue == "format" ? text + " — " + (entry.type.localizedDescription ?? entry.type.identifier) : current[entry.type.identifier]?.path
        return label
    }
    @objc private func applySelected() {
        guard !busy, service.applicationURL != nil else { return }
        let selected = table.selectedRowIndexes.compactMap { filtered.indices.contains($0) ? filtered[$0] : nil }
        guard !selected.isEmpty else { return }
        busy = true; updateButtons(); search.isEnabled = false; refreshButton.isEnabled = false
        message.stringValue = L10n.t(.fileDefaultsWorking)
        Task { @MainActor [self] in
            var failures: [String] = []
            for row in selected {
                do { try await service.setDefault(for: row.type) }
                catch { failures.append(row.title + ": " + error.localizedDescription) }
            }
            busy = false; search.isEnabled = true; refreshButton.isEnabled = true
            refresh()
            message.textColor = failures.isEmpty ? .secondaryLabelColor : .systemRed
            message.stringValue = L10n.t(.fileDefaultsResult, selected.count - failures.count, failures.count)
            if !failures.isEmpty { message.stringValue += "\n" + failures.prefix(2).joined(separator: "\n") }
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !busy }
    func windowDidBecomeKey(_ notification: Notification) { if !busy { refresh() } }
    func windowWillClose(_ notification: Notification) { onClose?() }
}
