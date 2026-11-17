import AppKit

/// A narrow band above the editor offering the languages detection found
/// plausible for a document it could not classify on its own: "Might be",
/// one button per candidate, "Other…" (the full language list) and a close
/// button. It is a suggestion, not an error — no warning symbol, no
/// announcement — and it never takes keyboard focus, so it can appear while
/// the user types without interrupting them.
///
/// Like `SaveFailureBanner` it sits in the editor's content stack, so it
/// follows the same rule as the find bar and the status bar: no `draw(_:)`
/// override and no opaque fill of its own (the v0.2.0 blank-window red line,
/// see StatusBarView.swift). Its background is the system header material.
///
/// In a window too narrow for every button, candidates drop from the last
/// one; the label, "Other…" and the close button stay
/// (`LanguageSuggestionBanner.visibleCandidateCount`).
@MainActor
final class LanguageSuggestionBanner: NSView {
    /// A language was picked, from a candidate button or the "Other…" menu.
    var onChoose: ((String) -> Void)?
    /// The close button was clicked.
    var onDismiss: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let row = NSStackView()
    let otherButton = NSButton(title: "", target: nil, action: nil)
    let closeButton = NSButton(title: "", target: nil, action: nil)
    /// One button per candidate, in candidate order (some may be hidden in a
    /// narrow window).
    private(set) var candidateButtons: [NSButton] = []
    /// The candidates the band offers, best first.
    private(set) var candidates: [LanguageMenuEntry] = []

    static let height: CGFloat = 30
    private static let inset: CGFloat = 12
    private static let spacing: CGFloat = 8
    private static let closeGap: CGFloat = 8

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

        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .horizontal)

        configure(otherButton, action: #selector(otherClicked))
        otherButton.identifier = NSUserInterfaceItemIdentifier("languageSuggestion.other")

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        closeButton.imagePosition = .imageOnly
        closeButton.isBordered = false
        closeButton.bezelStyle = .regularSquare
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.refusesFirstResponder = true
        closeButton.identifier = NSUserInterfaceItemIdentifier("languageSuggestion.close")
        closeButton.setContentHuggingPriority(.required, for: .horizontal)
        closeButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Self.spacing
        // Hidden (dropped) candidate buttons take no room.
        row.detachesHiddenViews = true
        row.setViews([label, otherButton], in: .leading)

        for view in [background, separator, row, closeButton] as [NSView] {
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
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.leadingAnchor.constraint(greaterThanOrEqualTo: row.trailingAnchor,
                                                 constant: Self.closeGap),
        ])
        // Just below required: in a window narrower than even the label,
        // "Other…" and the close button, the row clips at the trailing edge
        // instead of making the content stack's constraints unsatisfiable.
        let trailing = closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset)
        trailing.priority = NSLayoutConstraint.Priority(999)
        trailing.isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        reloadStrings()
    }

    private func configure(_ button: NSButton, action: Selector) {
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.target = self
        button.action = action
        // Clicking must not pull keyboard focus out of the text (this also
        // keeps the buttons out of the Tab order; every choice stays reachable
        // from the Language menu and the toolbar).
        button.refusesFirstResponder = true
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .horizontal)
    }

    /// Whether the band is showing.
    var isShowing: Bool { !isHidden }

    /// Identifiers of the candidate buttons currently on screen, in order.
    var visibleCandidateIdentifiers: [String] {
        zip(candidates, candidateButtons).filter { !$0.1.isHidden }.map(\.0.identifier)
    }

    /// Shows the band offering `candidates` (best first). Showing it again
    /// with the same candidates changes nothing; different candidates replace
    /// the buttons in place.
    func show(candidates newCandidates: [LanguageMenuEntry]) {
        guard !newCandidates.isEmpty else { hide(); return }
        if newCandidates != candidates { rebuildCandidateButtons(newCandidates) }
        if isHidden { isHidden = false }
    }

    func hide() {
        guard !isHidden else { return }
        isHidden = true
    }

    private func rebuildCandidateButtons(_ newCandidates: [LanguageMenuEntry]) {
        for button in candidateButtons {
            row.removeView(button)
        }
        candidates = newCandidates
        candidateButtons = newCandidates.enumerated().map { index, entry in
            let button = NSButton(title: entry.title, target: nil, action: nil)
            configure(button, action: #selector(candidateClicked(_:)))
            button.tag = index
            button.identifier = NSUserInterfaceItemIdentifier("languageSuggestion.\(entry.identifier)")
            return button
        }
        for (offset, button) in candidateButtons.enumerated() {
            row.insertView(button, at: 1 + offset, in: .leading)
        }
        needsLayout = true
    }

    /// Re-pulls the localized label, "Other…" title and close tooltip.
    func reloadStrings() {
        label.stringValue = L10n.t(.languageSuggestionLabel)
        otherButton.title = L10n.t(.languageSuggestionOther)
        let dismiss = L10n.t(.languageSuggestionDismiss)
        closeButton.toolTip = dismiss
        closeButton.setAccessibilityLabel(dismiss)
        setAccessibilityLabel(L10n.t(.languageSuggestionAccessibility))
        needsLayout = true
    }

    // MARK: - Narrow widths

    /// How many candidates fit in a band `width` points wide, dropping from
    /// the last one. `fixed` is the natural width of everything that always
    /// stays (label, "Other…", close button) including insets and the gaps
    /// between them; each candidate costs its width plus one `spacing`.
    nonisolated static func visibleCandidateCount(width: CGFloat, fixed: CGFloat,
                                                  candidateWidths: [CGFloat], spacing: CGFloat) -> Int {
        var used = fixed
        var count = 0
        for candidate in candidateWidths {
            used += candidate + spacing
            guard used <= width else { break }
            count += 1
        }
        return count
    }

    override func layout() {
        fitCandidates()
        super.layout()
    }

    /// Hides the trailing candidate buttons that do not fit the current width
    /// (and shows them again once they do). Only touches buttons whose state
    /// changes, so a steady width costs no extra layout pass.
    private func fitCandidates() {
        guard !candidateButtons.isEmpty, bounds.width > 0 else { return }
        let fixed = Self.inset + label.fittingSize.width + Self.spacing + otherButton.fittingSize.width
            + Self.closeGap + closeButton.fittingSize.width + Self.inset
        let count = Self.visibleCandidateCount(width: bounds.width, fixed: fixed,
                                               candidateWidths: candidateButtons.map(\.fittingSize.width),
                                               spacing: Self.spacing)
        for (index, button) in candidateButtons.enumerated() {
            let hidden = index >= count
            if button.isHidden != hidden { button.isHidden = hidden }
        }
    }

    // MARK: - Actions

    @objc private func candidateClicked(_ sender: NSButton) {
        guard candidates.indices.contains(sender.tag) else { return }
        onChoose?(candidates[sender.tag].identifier)
    }

    @objc private func closeClicked() { onDismiss?() }

    /// The "Other…" menu: the languages the toolbar popup lists (visible
    /// languages, Plain Text included), without Auto. Built on demand and
    /// dropped after use.
    func makeOtherMenu(settings: LanguageMenuSettings = LanguageMenuSettings()) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in settings.visibleLanguages {
            let item = NSMenuItem(title: entry.title, action: #selector(otherLanguageChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.identifier
            menu.addItem(item)
        }
        return menu
    }

    @objc private func otherClicked() {
        let menu = makeOtherMenu()
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: otherButton.bounds.maxY + 4),
                   in: otherButton)
    }

    @objc private func otherLanguageChosen(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else { return }
        onChoose?(identifier)
    }
}
