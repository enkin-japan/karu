import AppKit

/// Thin find / replace bar shown at the top of the editor window and the
/// scratchpad panel.
///
/// Progressive disclosure: a search row that is always shown, plus a replace
/// row that only appears when the bar is expanded (the disclosure triangle,
/// or Find and Replace… ⌥⌘F). The expansion state is remembered per instance
/// — that is, per window — across hide / show, and never persisted.
///
/// The bar is pure UI glue: all matching and replacement text is computed by
/// the AppKit-independent `SearchEngine`. It reuses the window's shared
/// `LineIndex` (never building its own) to report the current match's line
/// number, per the "one index, reused everywhere" rule (ARCHITECTURE.md §3.3).
///
/// Highlighting uses `NSLayoutManager` temporary attributes so it never writes
/// into the text storage — that keeps the storage delegate slot (owned by the
/// gutter) untouched. Every text mutation goes through the view's undo-aware
/// path so find/replace edits are undoable.
@MainActor
public final class FindBarController: NSObject, NSSearchFieldDelegate {
    /// The bar view, inserted into the window's layout by the window controller.
    public let barView = NSView()

    /// Whether the bar is currently visible.
    public private(set) var isShown = false

    /// Whether the replace row is expanded. Survives `hide()` / `show()`; a new
    /// controller (a new window) starts collapsed.
    public private(set) var isReplaceShown = false

    /// Fires on every visibility change (both `show()` and `hide()`, including
    /// the close button and Esc, which route through them). The scratchpad uses
    /// it to push its text down instead of letting the bar cover the first line.
    public var onVisibilityChanged: ((Bool) -> Void)?

    /// Fires after the bar has removed the `.backgroundColor` temporary
    /// attribute from the whole document — on `hide()` and on every recompute —
    /// and has re-added its own matches. Other painters sharing that key (the
    /// editor's bracket matcher and same-word tint) use it to repaint what the
    /// wipe took. Unset (the scratchpad), the bar behaves as it always did.
    public var onHighlightsReset: (() -> Void)?

    private weak var textView: NSTextView?
    private let lineIndex: LineIndex
    /// Narrow hosts (the scratchpad panel). Both hosts share one structure;
    /// this only lowers the minimum widths so the bar fits a ~340 pt window.
    private let compact: Bool

    // Controls. Internal (not private) so tests can inspect them.
    let disclosureButton = NSButton()
    let searchField = NSSearchField()
    let replaceField = NSTextField()
    let regexToggle = NSButton()
    let caseToggle = NSButton()
    let prevButton = NSButton()
    let nextButton = NSButton()
    let replaceButton = NSButton()
    let replaceAllButton = NSButton()
    /// The status slot: "i / n", "No results", "Replaced N" or a regex error.
    let countLabel = NSTextField(labelWithString: "")
    let closeButton = NSButton()
    /// The second row; `isHidden` collapses it (and the bar's height) away.
    let replaceRow = NSStackView()

    // Search state (recomputed on every text / option change).
    private var matches: [NSRange] = []
    private var currentIndex: Int = -1

    private let matchHighlight = NSColor.systemYellow.withAlphaComponent(0.35)

    /// - Parameter compact: lowers the minimum widths of the search field,
    ///   replace field and status slot, so the whole bar (both rows, buttons
    ///   included) fits a ~340 pt wide window.
    public init(textView: NSTextView, lineIndex: LineIndex, compact: Bool = false) {
        self.textView = textView
        self.lineIndex = lineIndex
        self.compact = compact
        super.init()
        buildBar()
        barView.isHidden = true
        NotificationCenter.default.addObserver(self, selector: #selector(editorTextChanged),
                                               name: NSText.didChangeNotification, object: textView)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func editorTextChanged() {
        // NSTextView's notification runs after storage processing has finished.
        recomputeMatches(moveToFirst: false)
    }

    // MARK: - Bar construction

    private func buildBar() {
        barView.wantsLayer = true
        barView.translatesAutoresizingMaskIntoConstraints = false

        // Chrome background that follows light / dark automatically, with a
        // hairline separator along the bottom edge so the bar reads as a distinct
        // band above the editor. No `draw(_:)` fill anywhere (v0.2.0 blank
        // window bug): the effect view is the whole background.
        let background = NSVisualEffectView()
        background.material = .headerView
        background.blendingMode = .withinWindow
        background.state = .followsWindowActiveState
        background.translatesAutoresizingMaskIntoConstraints = false
        barView.addSubview(background)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        barView.addSubview(separator)

        disclosureButton.bezelStyle = .disclosure
        disclosureButton.setButtonType(.pushOnPushOff)
        disclosureButton.title = ""
        disclosureButton.state = .off
        disclosureButton.target = self
        disclosureButton.action = #selector(disclosureToggled)
        disclosureButton.setContentHuggingPriority(.required, for: .horizontal)

        searchField.delegate = self
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = true

        replaceField.delegate = self
        replaceField.isBezeled = true
        replaceField.bezelStyle = .roundedBezel
        replaceField.isEditable = true
        replaceField.cell?.wraps = false
        replaceField.cell?.isScrollable = true

        configureToggle(regexToggle, title: ".*", action: #selector(optionChanged))
        configureToggle(caseToggle, title: "Aa", action: #selector(optionChanged))

        configureIconButton(prevButton, symbol: "chevron.left", action: #selector(findPreviousTapped))
        configureIconButton(nextButton, symbol: "chevron.right", action: #selector(findNextTapped))
        configureIconButton(closeButton, symbol: "xmark", action: #selector(closeTapped))
        configureButton(replaceButton, action: #selector(replaceTapped))
        configureButton(replaceAllButton, action: #selector(replaceAllTapped))

        countLabel.textColor = .secondaryLabelColor
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.alignment = .left
        countLabel.lineBreakMode = .byTruncatingTail
        countLabel.cell?.truncatesLastVisibleLine = true
        // The search field takes the slack (hugging 250); the status slot only
        // grows into it when its text needs the room (compression 251), and
        // truncates — never widening the window — when there is none: 251 is
        // far below the 500 at which a window resizes itself for its content.
        countLabel.setContentHuggingPriority(NSLayoutConstraint.Priority(260), for: .horizontal)
        countLabel.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(251), for: .horizontal)

        // Let the two text inputs absorb slack, everything else stays compact.
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        replaceField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let searchRow = NSStackView(views: [
            disclosureButton, searchField, countLabel,
            regexToggle, caseToggle,
            prevButton, nextButton, closeButton,
        ])
        searchRow.orientation = .horizontal
        // Tighter than the 8 pt grid between groups (6), tighter still inside a
        // group (the option toggles, the navigation chevrons): the compact bar
        // has to fit 340 pt with both rows in all three languages.
        searchRow.spacing = 8
        searchRow.setCustomSpacing(Self.disclosureGap, after: disclosureButton)
        searchRow.setCustomSpacing(6, after: searchField)
        searchRow.setCustomSpacing(6, after: countLabel)
        searchRow.setCustomSpacing(4, after: regexToggle)
        searchRow.setCustomSpacing(6, after: caseToggle)
        searchRow.setCustomSpacing(0, after: prevButton)
        searchRow.setCustomSpacing(2, after: nextButton)
        searchRow.alignment = .centerY

        // The replace row starts with an empty indent as wide as the disclosure
        // triangle, so the replace field lines up under the search field.
        let indent = NSView()
        indent.translatesAutoresizingMaskIntoConstraints = false
        replaceRow.setViews([indent, replaceField, replaceButton, replaceAllButton], in: .leading)
        replaceRow.orientation = .horizontal
        replaceRow.spacing = 8
        replaceRow.setCustomSpacing(Self.disclosureGap, after: indent)
        replaceRow.alignment = .centerY
        replaceRow.isHidden = true

        let column = NSStackView(views: [searchRow, replaceRow])
        column.orientation = .vertical
        column.spacing = 6
        column.alignment = .leading
        column.translatesAutoresizingMaskIntoConstraints = false
        barView.addSubview(column)

        // Same width as the search field while there is room for it; below
        // that, the replace buttons win (740 < their 750 compression) and the
        // replace field gives way first.
        let sameWidth = replaceField.widthAnchor.constraint(equalTo: searchField.widthAnchor)
        sameWidth.priority = NSLayoutConstraint.Priority(740)

        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: barView.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: barView.trailingAnchor),
            background.topAnchor.constraint(equalTo: barView.topAnchor),
            background.bottomAnchor.constraint(equalTo: barView.bottomAnchor),

            separator.leadingAnchor.constraint(equalTo: barView.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: barView.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: barView.bottomAnchor),

            column.leadingAnchor.constraint(equalTo: barView.leadingAnchor, constant: 8),
            column.trailingAnchor.constraint(equalTo: barView.trailingAnchor, constant: -8),
            column.topAnchor.constraint(equalTo: barView.topAnchor, constant: 6),
            column.bottomAnchor.constraint(equalTo: barView.bottomAnchor, constant: -6),
            // The search row spans the bar; the replace row may be shorter.
            searchRow.widthAnchor.constraint(equalTo: column.widthAnchor),
            replaceRow.trailingAnchor.constraint(lessThanOrEqualTo: column.trailingAnchor),

            indent.widthAnchor.constraint(equalTo: disclosureButton.widthAnchor),
            indent.heightAnchor.constraint(equalToConstant: 1),
            sameWidth,

            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: compact ? 84 : 140),
            replaceField.widthAnchor.constraint(greaterThanOrEqualToConstant: compact ? 84 : 120),
            countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: compact ? 48 : 90),
        ])

        // Tab order: the search field leads straight to the replace field (a
        // hidden replace row drops out — hidden views cannot become key), then
        // round the buttons, which Full Keyboard Access users reach.
        let loop: [NSView] = [
            disclosureButton, searchField, replaceField, replaceButton, replaceAllButton,
            regexToggle, caseToggle, prevButton, nextButton, closeButton,
        ]
        for (i, view) in loop.enumerated() {
            view.nextKeyView = loop[(i + 1) % loop.count]
        }

        applyStrings()
    }

    /// Gap between the disclosure triangle (or the replace row's matching
    /// indent) and the field to its right.
    private static let disclosureGap: CGFloat = 6

    private func configureToggle(_ button: NSButton, title: String, action: Selector) {
        button.title = title
        // Bordered on/off toggle: bezels in when active so regex / case state is
        // legible at a glance.
        button.bezelStyle = .roundRect
        button.isBordered = true
        button.setButtonType(.pushOnPushOff)
        button.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        button.target = self
        button.action = action
        button.setContentHuggingPriority(.required, for: .horizontal)
    }

    /// Previous / Next / Close: borderless SF Symbol buttons with a fixed hit
    /// area. Bordered ones would not fit the compact bar's 340 pt.
    private func configureIconButton(_ button: NSButton, symbol: String, action: Selector) {
        button.title = ""
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.setButtonType(.momentaryPushIn)
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 24),
            button.heightAnchor.constraint(equalToConstant: 22),
        ])
        button.setContentHuggingPriority(.required, for: .horizontal)
    }

    private func configureButton(_ button: NSButton, action: Selector) {
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.target = self
        button.action = action
        button.setContentHuggingPriority(.required, for: .horizontal)
    }

    /// Every user-visible string the bar owns (titles, placeholders, tooltips,
    /// accessibility labels). Shared by construction and `reloadStrings()`.
    private func applyStrings() {
        searchField.placeholderString = L10n.t(.findPlaceholder)
        replaceField.placeholderString = L10n.t(.replacePlaceholder)
        regexToggle.toolTip = L10n.t(.findRegexTooltip)
        regexToggle.setAccessibilityLabel(L10n.t(.findRegexTooltip))
        caseToggle.toolTip = L10n.t(.findCaseTooltip)
        caseToggle.setAccessibilityLabel(L10n.t(.findCaseTooltip))
        for (button, key) in [(prevButton, L10nKey.findPrevTooltip),
                              (nextButton, .findNextTooltip),
                              (closeButton, .findDoneTooltip)] {
            button.toolTip = L10n.t(key)
            button.setAccessibilityLabel(L10n.t(key))
        }
        replaceButton.title = L10n.t(.replacePlaceholder)
        replaceButton.toolTip = L10n.t(.findReplaceTooltip)
        replaceAllButton.title = L10n.t(.findReplaceAll)
        replaceAllButton.toolTip = L10n.t(.findReplaceAllTooltip)
        updateDisclosureStrings()
    }

    private func updateDisclosureStrings() {
        let label = L10n.t(isReplaceShown ? .findHideReplace : .findShowReplace)
        disclosureButton.toolTip = label
        disclosureButton.setAccessibilityLabel(label)
    }

    // MARK: - Show / hide

    /// Reveals the bar and focuses the search field. If the editor has a
    /// non-empty selection it is used to seed the query (Xcode-like behavior).
    /// The replace row keeps whatever expansion state it last had.
    public func show() {
        if let selected = selectedEditorText(), !selected.isEmpty {
            searchField.stringValue = selected
        }
        isShown = true
        barView.isHidden = false
        recomputeMatches(moveToFirst: true)
        barView.window?.makeFirstResponder(searchField)
        searchField.selectText(nil)
        onVisibilityChanged?(true)
    }

    /// Find and Replace… (⌥⌘F): shows the bar with the replace row expanded.
    /// A hidden bar opens like `show()` (focus in the search field); an already
    /// visible one expands and moves focus to the replace field.
    public func showReplace() {
        setReplaceShown(true)
        if isShown {
            barView.window?.makeFirstResponder(replaceField)
            replaceField.selectText(nil)
        } else {
            show()
        }
    }

    /// The bar's minimum width over both states — collapsed and expanded —
    /// so a host that sizes its window from it (the scratchpad's
    /// `contentMinSize`) never clips either row. Measured, not guessed.
    public var minimumWidth: CGFloat {
        let wasHidden = replaceRow.isHidden
        defer { replaceRow.isHidden = wasHidden }
        replaceRow.isHidden = true
        let collapsed = barView.fittingSize.width
        replaceRow.isHidden = false
        let expanded = barView.fittingSize.width
        return ceil(max(collapsed, expanded))
    }

    /// Expands or collapses the replace row (the disclosure triangle's action).
    /// Collapsing while the replace row holds focus hands it to the search field.
    public func setReplaceShown(_ shown: Bool) {
        isReplaceShown = shown
        disclosureButton.state = shown ? .on : .off
        updateDisclosureStrings()
        guard replaceRow.isHidden == shown else { return }
        if !shown, replaceRowHasFocus() {
            barView.window?.makeFirstResponder(searchField)
        }
        replaceRow.isHidden = !shown
        barView.needsLayout = true
    }

    /// Hides the bar, clears highlights, and returns focus to the editor.
    public func hide() {
        isShown = false
        barView.isHidden = true
        clearHighlights()
        matches = []
        currentIndex = -1
        onHighlightsReset?()
        if let textView { textView.window?.makeFirstResponder(textView) }
        onVisibilityChanged?(false)
    }

    /// Re-pulls every string after a UI-language change. Refreshes placeholders,
    /// tooltips, accessibility labels, button titles, and the status slot.
    public func reloadStrings() {
        applyStrings()
        updateCount()
    }

    /// Copies the editor's current selection into the search field and searches.
    public func useSelectionForFind() {
        guard let selected = selectedEditorText(), !selected.isEmpty else { return }
        searchField.stringValue = selected
        if !isShown { show() } else { recomputeMatches(moveToFirst: true) }
    }

    // MARK: - Navigation (also reachable from the menu)

    public func findNext() {
        recomputeMatches(moveToFirst: false)
        guard !matches.isEmpty else { NSSound.beep(); return }
        currentIndex = (currentIndex + 1) % matches.count
        focusCurrentMatch()
    }

    public func findPrevious() {
        recomputeMatches(moveToFirst: false)
        guard !matches.isEmpty else { NSSound.beep(); return }
        currentIndex = (currentIndex - 1 + matches.count) % matches.count
        focusCurrentMatch()
    }

    // MARK: - Actions

    @objc private func optionChanged() { recomputeMatches(moveToFirst: true) }
    @objc private func disclosureToggled() { setReplaceShown(disclosureButton.state == .on) }
    @objc private func findNextTapped() { findNext() }
    @objc private func findPreviousTapped() { findPrevious() }
    @objc private func closeTapped() { hide() }
    @objc private func replaceTapped() { replaceCurrent() }
    @objc private func replaceAllTapped() { replaceAll() }

    // MARK: - NSSearchFieldDelegate / editing

    public func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as AnyObject) === searchField else { return }
        recomputeMatches(moveToFirst: true)
    }

    public func control(_ control: NSControl,
                        textView: NSTextView,
                        doCommandBy commandSelector: Selector) -> Bool {
        // Esc closes the bar from either field (in the replace field it used
        // to fall through to AppKit's completion list). Return is the search
        // field's alone: in the replace field it keeps AppKit's default.
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)) where control === searchField:
            findNext()
            return true
        case #selector(NSResponder.cancelOperation(_:)) where control === searchField || control === replaceField:
            hide()
            return true
        default:
            return false
        }
    }

    // MARK: - Search core

    private var options: SearchOptions {
        SearchOptions(regex: regexToggle.state == .on, caseSensitive: caseToggle.state == .on)
    }

    private func recomputeMatches(moveToFirst: Bool) {
        guard isShown, let textView else { return }
        let pattern = searchField.stringValue
        let text = textView.string

        switch SearchEngine.matches(in: text, pattern: pattern, options: options) {
        case .failure(let error):
            matches = []
            currentIndex = -1
            clearHighlights()
            onHighlightsReset?()
            showError(error.description)
        case .success(let ranges):
            matches = ranges
            applyHighlights()
            if ranges.isEmpty {
                currentIndex = -1
                updateCount()
            } else {
                if moveToFirst {
                    currentIndex = indexOfFirstMatch(atOrAfter: textView.selectedRange().location)
                    focusCurrentMatch()
                } else {
                    currentIndex = min(max(currentIndex, 0), ranges.count - 1)
                    updateCount()
                }
            }
        }
    }

    /// First match starting at or after `location`, wrapping to 0 if none.
    private func indexOfFirstMatch(atOrAfter location: Int) -> Int {
        for (i, range) in matches.enumerated() where range.location >= location {
            return i
        }
        return 0
    }

    private func focusCurrentMatch() {
        guard let textView, matches.indices.contains(currentIndex) else {
            updateCount()
            return
        }
        let range = matches[currentIndex]
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        textView.showFindIndicator(for: range)
        updateCount()
    }

    // MARK: - Replacement

    private func replaceCurrent() {
        recomputeMatches(moveToFirst: false)
        guard let textView, matches.indices.contains(currentIndex) else { NSSound.beep(); return }
        let range = matches[currentIndex]
        let template = replaceField.stringValue
        switch SearchEngine.replacementText(for: range, in: textView.string,
                                            pattern: searchField.stringValue,
                                            options: options, template: template) {
        case .failure(let error):
            showError(error.description)
        case .success(let replacement):
            // Undo-aware insertion at the match range.
            if textView.shouldChangeText(in: range, replacementString: replacement) {
                textView.textStorage?.replaceCharacters(in: range, with: replacement)
                textView.didChangeText()
            }
            // The document shifted; recompute and land on the next match near
            // where the replacement ended.
            let caret = range.location + (replacement as NSString).length
            recomputeMatches(moveToFirst: false)
            if !matches.isEmpty {
                currentIndex = indexOfFirstMatch(atOrAfter: caret)
                focusCurrentMatch()
            } else {
                updateCount()
            }
        }
    }

    private func replaceAll() {
        recomputeMatches(moveToFirst: false)
        guard let textView else { return }
        let template = replaceField.stringValue
        switch SearchEngine.replaceAll(in: textView.string,
                                       pattern: searchField.stringValue,
                                       options: options, template: template) {
        case .failure(let error):
            showError(error.description)
        case .success(let newText):
            let replacedCount = matches.count
            let full = NSRange(location: 0, length: (textView.string as NSString).length)
            // Single whole-document replacement keeps Replace All as one undo step.
            if textView.shouldChangeText(in: full, replacementString: newText) {
                textView.textStorage?.replaceCharacters(in: full, with: newText)
                textView.didChangeText()
            }
            recomputeMatches(moveToFirst: false)
            setStatus(L10n.t(.findReplacedCount, replacedCount))
        }
    }

    // MARK: - Highlighting

    /// Replaces every `.backgroundColor` temporary attribute in the document
    /// with the match colour on each match. The key is shared with the
    /// editor's bracket matcher and same-word tint and does not stack, so this
    /// wipes theirs too; `onHighlightsReset` lets them repaint.
    private func applyHighlights() {
        guard let layoutManager = textView?.layoutManager else { return }
        clearHighlights()
        for range in matches {
            layoutManager.addTemporaryAttributes([.backgroundColor: matchHighlight],
                                                 forCharacterRange: range)
        }
        onHighlightsReset?()
    }

    private func clearHighlights() {
        guard let textView, let layoutManager = textView.layoutManager else { return }
        let full = NSRange(location: 0, length: textView.textStorage?.length ?? 0)
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
    }

    /// Re-adds the match colour on every match intersecting `ranges` (whole
    /// match ranges). Other painters sharing the `.backgroundColor` key call
    /// this after painting or clearing theirs, so that while the bar is shown
    /// a character inside a search match always shows the search colour. A
    /// no-op while hidden or without matches.
    public func reapplyHighlights(intersecting ranges: [NSRange]) {
        guard isShown, !matches.isEmpty, let textView,
              let layoutManager = textView.layoutManager else { return }
        // Matches can be momentarily stale after a programmatic edit.
        let length = textView.textStorage?.length ?? 0
        for range in ranges where range.length > 0 {
            // `matches` comes from NSRegularExpression: ascending and
            // non-overlapping, so their ends ascend too. First match ending
            // after the range's start:
            var low = 0
            var high = matches.count
            while low < high {
                let mid = (low + high) / 2
                if NSMaxRange(matches[mid]) <= range.location { low = mid + 1 } else { high = mid }
            }
            var i = low
            while i < matches.count, matches[i].location < NSMaxRange(range) {
                let match = matches[i]
                if match.length > 0, NSMaxRange(match) <= length {
                    layoutManager.addTemporaryAttributes([.backgroundColor: matchHighlight],
                                                         forCharacterRange: match)
                }
                i += 1
            }
        }
    }

    // MARK: - Count / error display

    private func updateCount() {
        if searchField.stringValue.isEmpty {
            setStatus("")
        } else if matches.isEmpty {
            setStatus(L10n.t(.findNoResults))
        } else if matches.indices.contains(currentIndex) {
            let line = lineIndex.lineNumber(forOffset: matches[currentIndex].location)
            setStatus(L10n.t(.findMatchPosition, currentIndex + 1, matches.count),
                      tooltip: L10n.t(.findMatchLineTooltip, line))
        } else {
            setStatus(L10n.t(.findFoundCount, matches.count))
        }
    }

    private func showError(_ message: String) {
        setStatus(message, color: .systemRed)
    }

    /// The slot can truncate, so its tooltip always carries the full text —
    /// except for a match position, whose tooltip is the match's line.
    private func setStatus(_ text: String, tooltip: String? = nil,
                           color: NSColor = .secondaryLabelColor) {
        countLabel.textColor = color
        countLabel.stringValue = text
        countLabel.toolTip = tooltip ?? (text.isEmpty ? nil : text)
    }

    // MARK: - Helpers

    /// True while the replace field (via its field editor) or one of the
    /// replace row's buttons is the window's first responder.
    private func replaceRowHasFocus() -> Bool {
        guard let responder = barView.window?.firstResponder else { return false }
        if let editor = responder as? NSText, (editor.delegate as AnyObject?) === replaceField { return true }
        return (responder as? NSView)?.isDescendant(of: replaceRow) ?? false
    }

    private func selectedEditorText() -> String? {
        guard let textView else { return nil }
        let range = textView.selectedRange()
        guard range.length > 0 else { return nil }
        return (textView.string as NSString).substring(with: range)
    }
}
