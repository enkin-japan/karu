import AppKit

/// Thin find / replace bar shown at the top of the editor window.
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

    private weak var textView: NSTextView?
    private let lineIndex: LineIndex

    // Controls
    private let searchField = NSSearchField()
    private let replaceField = NSTextField()
    private let regexToggle = NSButton()
    private let caseToggle = NSButton()
    private let prevButton = NSButton()
    private let nextButton = NSButton()
    private let replaceButton = NSButton()
    private let replaceAllButton = NSButton()
    private let countLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()

    // Search state (recomputed on every text / option change).
    private var matches: [NSRange] = []
    private var currentIndex: Int = -1

    private let matchHighlight = NSColor.systemYellow.withAlphaComponent(0.35)

    public init(textView: NSTextView, lineIndex: LineIndex) {
        self.textView = textView
        self.lineIndex = lineIndex
        super.init()
        buildBar()
        barView.isHidden = true
    }

    // MARK: - Bar construction

    private func buildBar() {
        barView.wantsLayer = true
        barView.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = "Find"
        searchField.delegate = self
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = true

        replaceField.placeholderString = "Replace"
        replaceField.isBezeled = true
        replaceField.bezelStyle = .roundedBezel
        replaceField.isEditable = true
        replaceField.cell?.wraps = false
        replaceField.cell?.isScrollable = true

        configureToggle(regexToggle, title: ".*", tooltip: "Regular expression", action: #selector(optionChanged))
        configureToggle(caseToggle, title: "Aa", tooltip: "Match case", action: #selector(optionChanged))

        configureButton(prevButton, title: "<", tooltip: "Previous match", action: #selector(findPreviousTapped))
        configureButton(nextButton, title: ">", tooltip: "Next match", action: #selector(findNextTapped))
        configureButton(replaceButton, title: "Replace", tooltip: "Replace current match", action: #selector(replaceTapped))
        configureButton(replaceAllButton, title: "All", tooltip: "Replace all matches", action: #selector(replaceAllTapped))
        configureButton(closeButton, title: "Done", tooltip: "Close find bar", action: #selector(closeTapped))

        countLabel.textColor = .secondaryLabelColor
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.alignment = .right
        countLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Let the two text inputs absorb slack, everything else stays compact.
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        replaceField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [
            searchField, regexToggle, caseToggle,
            prevButton, nextButton,
            replaceField, replaceButton, replaceAllButton,
            countLabel, closeButton,
        ])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        barView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: barView.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: barView.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: barView.topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: barView.bottomAnchor, constant: -5),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
            replaceField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
        ])
    }

    private func configureToggle(_ button: NSButton, title: String, tooltip: String, action: Selector) {
        button.title = title
        button.toolTip = tooltip
        button.bezelStyle = .roundRect
        button.setButtonType(.pushOnPushOff)
        button.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        button.target = self
        button.action = action
        button.setContentHuggingPriority(.required, for: .horizontal)
    }

    private func configureButton(_ button: NSButton, title: String, tooltip: String, action: Selector) {
        button.title = title
        button.toolTip = tooltip
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.target = self
        button.action = action
        button.setContentHuggingPriority(.required, for: .horizontal)
    }

    // MARK: - Show / hide

    /// Reveals the bar and focuses the search field. If the editor has a
    /// non-empty selection it is used to seed the query (Xcode-like behavior).
    public func show() {
        if let selected = selectedEditorText(), !selected.isEmpty {
            searchField.stringValue = selected
        }
        isShown = true
        barView.isHidden = false
        recomputeMatches(moveToFirst: true)
        barView.window?.makeFirstResponder(searchField)
        searchField.selectText(nil)
    }

    /// Hides the bar, clears highlights, and returns focus to the editor.
    public func hide() {
        isShown = false
        barView.isHidden = true
        clearHighlights()
        matches = []
        currentIndex = -1
        if let textView { textView.window?.makeFirstResponder(textView) }
    }

    /// Copies the editor's current selection into the search field and searches.
    public func useSelectionForFind() {
        guard let selected = selectedEditorText(), !selected.isEmpty else { return }
        searchField.stringValue = selected
        if !isShown { show() } else { recomputeMatches(moveToFirst: true) }
    }

    // MARK: - Navigation (also reachable from the menu)

    public func findNext() {
        guard !matches.isEmpty else { NSSound.beep(); return }
        currentIndex = (currentIndex + 1) % matches.count
        focusCurrentMatch()
    }

    public func findPrevious() {
        guard !matches.isEmpty else { NSSound.beep(); return }
        currentIndex = (currentIndex - 1 + matches.count) % matches.count
        focusCurrentMatch()
    }

    // MARK: - Actions

    @objc private func optionChanged() { recomputeMatches(moveToFirst: true) }
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
        guard control === searchField else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            findNext()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
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
                textView.insertText(replacement, replacementRange: range)
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
            countLabel.textColor = .secondaryLabelColor
            countLabel.stringValue = "Replaced \(replacedCount)"
        }
    }

    // MARK: - Highlighting

    private func applyHighlights() {
        guard let layoutManager = textView?.layoutManager else { return }
        clearHighlights()
        for range in matches {
            layoutManager.addTemporaryAttributes([.backgroundColor: matchHighlight],
                                                 forCharacterRange: range)
        }
    }

    private func clearHighlights() {
        guard let textView, let layoutManager = textView.layoutManager else { return }
        let full = NSRange(location: 0, length: (textView.string as NSString).length)
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
    }

    // MARK: - Count / error display

    private func updateCount() {
        countLabel.textColor = .secondaryLabelColor
        if searchField.stringValue.isEmpty {
            countLabel.stringValue = ""
        } else if matches.isEmpty {
            countLabel.stringValue = "No results"
        } else if matches.indices.contains(currentIndex) {
            let line = lineIndex.lineNumber(forOffset: matches[currentIndex].location)
            countLabel.stringValue = "\(currentIndex + 1)/\(matches.count) · L\(line)"
        } else {
            countLabel.stringValue = "\(matches.count) found"
        }
    }

    private func showError(_ message: String) {
        countLabel.textColor = .systemRed
        countLabel.stringValue = message
    }

    // MARK: - Helpers

    private func selectedEditorText() -> String? {
        guard let textView else { return nil }
        let range = textView.selectedRange()
        guard range.length > 0 else { return nil }
        return (textView.string as NSString).substring(with: range)
    }
}
