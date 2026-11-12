import AppKit

/// "Language List…" sub-window (T16.2): one checkbox per supported language,
/// deciding which ones the toolbar popup and the main Language menu list.
/// Built only when opened from Settings and released through `onClose`, like
/// the shortcuts window. Changes apply immediately via `LanguageMenuSettings`.
final class LanguageListPreferencesController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    private let settings: LanguageMenuSettings
    private let center: NotificationCenter
    private let help = NSTextField(wrappingLabelWithString: "")
    private let showAllButton = NSButton()
    /// Checkboxes in `SupportedLanguage.all` order; Plain Text is first,
    /// permanently checked and disabled (it can never be hidden).
    private var checkboxes: [NSButton] = []

    private static let columns = 3

    init(settings: LanguageMenuSettings? = nil, center: NotificationCenter = .default) {
        self.settings = settings ?? LanguageMenuSettings(center: center)
        self.center = center
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        checkboxes = SupportedLanguage.all.enumerated().map { index, language in
            let box = NSButton(checkboxWithTitle: language.title, target: self, action: #selector(toggled(_:)))
            box.tag = index
            box.isEnabled = !language.identifier.isEmpty
            return box
        }
        var rows: [[NSView]] = []
        for start in stride(from: 0, to: checkboxes.count, by: Self.columns) {
            var row: [NSView] = Array(checkboxes[start..<min(start + Self.columns, checkboxes.count)])
            while row.count < Self.columns { row.append(NSGridCell.emptyContentView) }
            rows.append(row)
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.columnSpacing = 24

        help.textColor = .secondaryLabelColor
        help.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        help.preferredMaxLayoutWidth = 380
        showAllButton.bezelStyle = .rounded
        showAllButton.target = self
        showAllButton.action = #selector(showAll)

        let content = NSStackView(views: [help, grid, showAllButton])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        window.contentView = content
        window.setContentSize(content.fittingSize)
        window.center()

        center.addObserver(self, selector: #selector(reloadState),
                           name: LanguageMenuSettings.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reloadStrings),
                                               name: L10n.didChangeNotification, object: nil)
        reloadStrings()
        reloadState()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        center.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func reloadStrings() {
        window?.title = L10n.t(.languageListTitle).replacingOccurrences(of: "…", with: "")
        help.stringValue = L10n.t(.languageListHelp)
        showAllButton.title = L10n.t(.languageListShowAll)
    }

    /// Re-reads visibility (also after a settings import or "Show All").
    @objc private func reloadState() {
        let hidden = settings.hiddenIdentifiers
        for box in checkboxes {
            let id = Self.identifier(for: box)
            box.state = id.isEmpty || !hidden.contains(id) ? .on : .off
        }
        showAllButton.isEnabled = !hidden.isEmpty
    }

    @objc private func toggled(_ sender: NSButton) {
        settings.setVisible(sender.state == .on, for: Self.identifier(for: sender))
        reloadState()
    }

    private static func identifier(for box: NSButton) -> String {
        SupportedLanguage.all.indices.contains(box.tag) ? SupportedLanguage.all[box.tag].identifier : ""
    }

    @objc private func showAll() {
        settings.showAll()
        reloadState()
    }

    func windowWillClose(_ notification: Notification) { onClose?() }
}
