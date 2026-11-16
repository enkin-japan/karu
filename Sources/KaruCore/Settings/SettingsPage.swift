import AppKit

/// One page of the Settings window. Pages are plain objects owned by
/// `PreferencesWindowController`: created on first selection, cached while the
/// window is open, released with the controller.
@MainActor
protocol SettingsPage: AnyObject {
    /// Root view. Its `fittingSize` is the window's content size for this page.
    var view: NSView { get }
    /// Set by the host; the page calls it when its content changes size after it was shown
    /// (language switch, asynchronous results).
    var onContentSizeChange: (() -> Void)? { get set }
    /// The window lost key, another page is being selected, or the window is closing:
    /// stop any key recording, commit text being edited.
    func pageWillDeactivate()
    /// The window became key again while this page is showing.
    func pageDidBecomeActive()
}

extension SettingsPage {
    func pageWillDeactivate() {}
    func pageDidBecomeActive() {}
}

// MARK: - Form layout

/// Horizontal row of controls placed in one grid cell. Forwards its baselines
/// to the first arranged subview so a grid row aligned on first baseline lines
/// the row label up with the first control's text.
final class SettingsRowStack: NSStackView {
    override var firstBaselineAnchor: NSLayoutYAxisAnchor {
        arrangedSubviews.first?.firstBaselineAnchor ?? super.firstBaselineAnchor
    }

    override var lastBaselineAnchor: NSLayoutYAxisAnchor {
        arrangedSubviews.first?.lastBaselineAnchor ?? super.lastBaselineAnchor
    }
}

/// Shared two-column form for the General, Editing, Code and Scratchpad pages:
/// row labels right-aligned left of one axis, controls left-aligned right of
/// it. The label column has the same width on every form page (the widest row
/// label of all four pages in the current language), so the axis does not
/// jump when switching pages.
@MainActor
final class SettingsForm {
    static let controlColumnWidth: CGFloat = 320
    static let insets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
    static let rowSpacing: CGFloat = 8
    static let columnSpacing: CGFloat = 8
    /// Extra space above and below a separator (on top of the row spacing).
    static let separatorPadding: CGFloat = 6
    static let buttonSpacing: CGFloat = 8

    /// Every row label used on any of the four form pages; the label column is
    /// as wide as the widest of them.
    static let labelKeys: [L10nKey] = [
        .prefLanguageLabel,
        .prefFontSizeLabel,
        .prefIndentWidthLabel,
        .prefModulesLabel,
        .prefScratchpadHotkeyLabel,
    ]

    /// Width of the label column in the current language (system font).
    static func labelColumnWidth() -> CGFloat {
        labelKeys.map { ceil(NSTextField(labelWithString: L10n.t($0)).fittingSize.width) }.max() ?? 0
    }

    /// The page's root view: the grid inset by `insets`.
    let view = NSView()
    let grid = NSGridView(numberOfColumns: 2, rows: 0)
    private var rowLabels: [(NSTextField, L10nKey)] = []

    init() {
        grid.rowSpacing = Self.rowSpacing
        grid.columnSpacing = Self.columnSpacing
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        grid.column(at: 1).width = Self.controlColumnWidth
        grid.column(at: 0).width = Self.labelColumnWidth()
        grid.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: Self.insets.top),
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Self.insets.left),
            grid.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Self.insets.right),
            grid.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -Self.insets.bottom),
        ])
    }

    /// Adds a row; `label` nil leaves the label cell empty (checkboxes and
    /// buttons sit in the control column).
    @discardableResult
    func addRow(label: L10nKey?, control: NSView) -> NSGridRow {
        var labelView: NSView = NSGridCell.emptyContentView
        if let label {
            let field = NSTextField(labelWithString: L10n.t(label))
            field.alignment = .right
            rowLabels.append((field, label))
            labelView = field
        }
        return grid.addRow(with: [labelView, control])
    }

    /// Adds secondary help text under the preceding control, wrapping at the
    /// control column's width. Returns the label so the page can update it.
    @discardableResult
    func addHelp(_ text: String) -> NSTextField {
        let help = Self.helpLabel(text)
        addRow(label: nil, control: help)
        return help
    }

    static func helpLabel(_ text: String) -> NSTextField {
        let help = NSTextField(wrappingLabelWithString: text)
        help.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        help.textColor = .secondaryLabelColor
        help.preferredMaxLayoutWidth = controlColumnWidth
        return help
    }

    /// A separator spanning both columns, with the same padding on every page.
    func addSeparator() {
        let box = NSBox()
        box.boxType = .separator
        let row = grid.addRow(with: [box, NSGridCell.emptyContentView])
        row.mergeCells(in: NSRange(location: 0, length: 2))
        row.rowAlignment = .none
        row.yPlacement = .center
        row.topPadding = Self.separatorPadding
        row.bottomPadding = Self.separatorPadding
        row.cell(at: 0).xPlacement = .fill
    }

    /// Re-pulls the row labels and recomputes the label column (language switch).
    func reloadLabels() {
        for (field, key) in rowLabels { field.stringValue = L10n.t(key) }
        grid.column(at: 0).width = Self.labelColumnWidth()
    }

    /// Horizontal row of controls for one control cell.
    static func row(_ views: [NSView]) -> SettingsRowStack {
        let stack = SettingsRowStack(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = buttonSpacing
        stack.setHuggingPriority(.defaultHigh, for: .horizontal)
        return stack
    }

    /// Buttons on one row with equal widths (the widest title decides). The row
    /// never outgrows the control column: a title that changes later (the
    /// hot-key recorder's prompt) truncates instead.
    static func equalWidthButtons(_ buttons: [NSButton]) -> NSView {
        let stack = row(buttons)
        stack.widthAnchor.constraint(lessThanOrEqualToConstant: controlColumnWidth).isActive = true
        if let first = buttons.first {
            for button in buttons.dropFirst() {
                button.widthAnchor.constraint(equalTo: first.widthAnchor).isActive = true
            }
        }
        return stack
    }

    static func numberField(min: Int, max: Int, unit: String? = nil) -> SettingsNumberField {
        SettingsNumberField(range: min...max, unit: unit)
    }

    static func checkbox(_ identifier: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(checkboxWithTitle: "", target: target, action: action)
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        return button
    }

    static func button(_ identifier: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: "", target: target, action: action)
        button.bezelStyle = .rounded
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        return button
    }
}

/// A small integer field paired with a stepper. Typed input commits on Return
/// and on end of editing, is clamped to `range`, and non-numeric input reverts
/// to the previous value. Changing either control updates the other.
@MainActor
final class SettingsNumberField: NSObject, NSTextFieldDelegate {
    let field = NSTextField()
    let stepper = NSStepper()
    let unitLabel: NSTextField?
    let range: ClosedRange<Int>
    private(set) var value: Int
    /// Called after the user changed the value (field or stepper), not after `setValue`.
    var onChange: ((Int) -> Void)?
    private let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        formatter.usesGroupingSeparator = false
        formatter.isLenient = true
        return formatter
    }()

    static let fieldWidth: CGFloat = 44

    init(range: ClosedRange<Int>, unit: String?) {
        self.range = range
        value = range.lowerBound
        unitLabel = unit.map { NSTextField(labelWithString: $0) }
        super.init()
        field.alignment = .right
        field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.usesSingleLineMode = true
        field.delegate = self
        field.target = self
        field.action = #selector(fieldCommitted(_:))
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: Self.fieldWidth).isActive = true
        stepper.minValue = Double(range.lowerBound)
        stepper.maxValue = Double(range.upperBound)
        stepper.increment = 1
        stepper.valueWraps = false
        stepper.target = self
        stepper.action = #selector(stepped(_:))
        setValue(range.lowerBound)
    }

    /// Field, stepper and unit label, for placing into a row.
    var views: [NSView] { [field, stepper] + (unitLabel.map { [$0] } ?? []) }

    /// Shows `newValue` (clamped) without calling `onChange`.
    func setValue(_ newValue: Int) {
        value = min(max(newValue, range.lowerBound), range.upperBound)
        field.stringValue = formatter.string(from: NSNumber(value: value)) ?? "\(value)"
        stepper.integerValue = value
    }

    /// Commits the field's text: clamps numbers, reverts anything else.
    func commitText() {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let number = formatter.number(from: text) else {
            setValue(value)
            return
        }
        let old = value
        setValue(number.intValue)
        if value != old { onChange?(value) }
    }

    @objc private func fieldCommitted(_ sender: NSTextField) { commitText() }

    func controlTextDidEndEditing(_ obj: Notification) { commitText() }

    @objc private func stepped(_ sender: NSStepper) {
        let old = value
        setValue(sender.integerValue)
        if value != old { onChange?(value) }
    }
}

// MARK: - Sheets

/// Window class for the Settings sub-controllers presented as sheets: Esc
/// (or Cancel) runs `onCancel`, which dismisses through the controller's own
/// rules (e.g. not while busy).
final class SettingsSheetWindow: NSWindow {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        if let onCancel { onCancel() } else { super.cancelOperation(sender) }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, let onCancel { // Esc
            onCancel()
            return
        }
        super.keyDown(with: event)
    }
}

/// Presenting the Settings sub-controllers as sheets on the Settings window.
@MainActor
enum SettingsSheet {
    /// Presents `controller`'s window as a sheet on `parent`; `onEnd` runs when
    /// the sheet ends. Without a parent the window is simply shown (and the
    /// controller's own `onClose` covers its release).
    static func present(_ controller: NSWindowController, on parent: NSWindow?, onEnd: @escaping () -> Void) {
        guard let sheet = controller.window else { return }
        guard let parent else {
            controller.showWindow(nil)
            return
        }
        parent.beginSheet(sheet) { _ in onEnd() }
    }

    /// Ends `window`'s sheet, or closes it when it is not attached as a sheet.
    static func dismiss(_ window: NSWindow?) {
        guard let window else { return }
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.close()
        }
    }

    /// Bold title shown at the top of a sheet (a sheet has no title bar).
    static func titleLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        return label
    }

    /// The title string for a sheet: the window title without its ellipsis.
    static func title(_ key: L10nKey) -> String {
        L10n.t(key).replacingOccurrences(of: "…", with: "")
    }

    /// Trailing Done button (Return).
    static func doneButton(target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: L10n.t(.findDone), target: target, action: action)
        button.bezelStyle = .rounded
        button.keyEquivalent = "\r"
        button.identifier = NSUserInterfaceItemIdentifier("settings.sheetDone")
        return button
    }

    /// A full-width row holding `button` at its trailing edge.
    static func trailingRow(_ button: NSButton) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.setViews([button], in: .trailing)
        return row
    }
}

// MARK: - Open editors

/// Walks every window's view tree and applies `body` to each `EditorTextView`.
@MainActor
func forEachEditorTextView(_ body: (EditorTextView) -> Void) {
    func visit(_ view: NSView) {
        if let textView = view as? EditorTextView { body(textView) }
        for subview in view.subviews { visit(subview) }
    }
    for window in NSApp.windows {
        if let content = window.contentView { visit(content) }
    }
}
