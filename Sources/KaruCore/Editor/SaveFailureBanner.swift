import AppKit

/// A narrow band above the editor shown after auto-save on focus loss did not
/// write the document. It says why in words (plus a warning symbol), stays
/// until the document is saved by any route or the window closes, and offers
/// a manual save and Save As. It is not modal and never takes keyboard focus.
///
/// Two modes: `.failure` (the write failed; the first button retries) and
/// `.conflict` (another program changed the file, so auto-save left it alone;
/// the first button runs the manual save, which asks what to do).
///
/// The band sits in the editor's content stack, next to the scroll view, so it
/// follows the same rule as the find bar and the status bar: no `draw(_:)`
/// override and no opaque fill of its own (the v0.2.0 blank-window red line,
/// see StatusBarView.swift). Its background is the system header material.
@MainActor
final class SaveFailureBanner: NSView {
    enum Mode: Equatable {
        /// The auto-save write failed.
        case failure
        /// The file changed on disk, so auto-save did not overwrite it.
        case conflict
    }

    /// Retry through the manual save path (in `.conflict` mode the same path,
    /// which then asks whether to overwrite).
    var onRetry: (() -> Void)?
    /// Save under a new name / location.
    var onSaveAs: (() -> Void)?

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    let retryButton = NSButton(title: "", target: nil, action: nil)
    let saveAsButton = NSButton(title: "", target: nil, action: nil)
    /// The failure's own description, shown as the tooltip.
    private var reason: String?
    /// What the band is currently reporting.
    private(set) var mode: Mode = .failure

    static let height: CGFloat = 30

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)

        let background = NSVisualEffectView()
        background.material = .headerView
        background.blendingMode = .withinWindow
        background.state = .followsWindowActiveState
        let separator = NSBox()
        separator.boxType = .separator

        icon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        icon.contentTintColor = .systemYellow
        icon.setContentHuggingPriority(.required, for: .horizontal)
        // The group's label already says what the symbol means.
        icon.setAccessibilityElement(false)

        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        // The message gives way in a narrow window; the buttons never do.
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // Read once, through the group's label.
        label.setAccessibilityElement(false)

        for (button, action) in [(retryButton, #selector(retryClicked)), (saveAsButton, #selector(saveAsClicked))] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            button.target = self
            button.action = action
            // Clicking must not pull keyboard focus out of the text. (This also
            // keeps the buttons out of the Tab order; Save and Save As stay
            // reachable from the File menu and their shortcuts.)
            button.refusesFirstResponder = true
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            button.setContentHuggingPriority(.required, for: .horizontal)
        }
        retryButton.identifier = NSUserInterfaceItemIdentifier("saveFailure.retry")
        saveAsButton.identifier = NSUserInterfaceItemIdentifier("saveFailure.saveAs")

        for view in [background, separator, icon, label, retryButton, saveAsButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            retryButton.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 12),
            retryButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            saveAsButton.leadingAnchor.constraint(equalTo: retryButton.trailingAnchor, constant: 8),
            saveAsButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        // Just below required: in a window dragged narrower than the icon and
        // the two buttons, the row clips at the trailing edge instead of
        // making the content stack's constraints unsatisfiable.
        let trailing = saveAsButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12)
        trailing.priority = NSLayoutConstraint.Priority(999)
        trailing.isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        reloadStrings()
    }

    /// Whether the band is showing.
    var isShowing: Bool { !isHidden }

    /// The message currently shown (tests).
    var message: String { label.stringValue }

    /// Shows the band. Showing it again in the same mode while it is up only
    /// refreshes the reason: nothing is re-added, moved or flashed. A change of
    /// mode re-pulls the text and announces it again.
    func show(reason: String?, mode: Mode = .failure) {
        self.reason = reason
        let modeChanged = mode != self.mode
        if modeChanged {
            self.mode = mode
            reloadStrings()
        }
        updateToolTip()
        guard isHidden || modeChanged else { return }
        isHidden = false
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: label.stringValue,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    func hide() {
        guard !isHidden else { return }
        isHidden = true
        reason = nil
        updateToolTip()
    }

    /// Re-pulls the localized message and button titles.
    func reloadStrings() {
        switch mode {
        case .failure:
            label.stringValue = L10n.t(.saveFailedBanner)
            retryButton.title = L10n.t(.saveFailedRetry)
        case .conflict:
            label.stringValue = L10n.t(.saveConflictBanner)
            retryButton.title = L10n.t(.saveConflictBannerSave)
        }
        saveAsButton.title = L10n.t(.menuSaveAs)
        setAccessibilityLabel(label.stringValue)
        updateToolTip()
    }

    private func updateToolTip() {
        // The message can be cut short in a narrow window; the tooltip always
        // carries it in full, followed by the failure's own description.
        label.toolTip = [label.stringValue, reason].compactMap { $0 }.joined(separator: "\n")
    }

    @objc private func retryClicked() { onRetry?() }
    @objc private func saveAsClicked() { onSaveAs?() }
}
