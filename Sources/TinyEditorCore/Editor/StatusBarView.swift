import AppKit

/// Pure, AppKit-independent helpers for the status bar. Kept separate from the
/// view so the numeric logic (which the view merely renders) is unit-testable.
public enum StatusBarMetrics {
    /// 1-based column for a caret at UTF-16 `caretOffset`, given the UTF-16
    /// `lineStartOffset` of the line the caret sits on. Column 1 is the start of
    /// the line. Clamped to ≥ 1 so a malformed input never underflows.
    public static func column(caretOffset: Int, lineStartOffset: Int) -> Int {
        max(1, caretOffset - lineStartOffset + 1)
    }

    /// The "Ln N, Col M" caption shown on the left of the status bar. `language`
    /// defaults to the active UI language; tests pass it explicitly to stay
    /// deterministic without touching global state.
    public static func caretDescription(line: Int, column: Int,
                                        language: AppLanguage = L10n.current) -> String {
        L10n.string(.statusLnCol, language: language, line, column)
    }

    /// The character-count caption shown on the right. `count` is the document's
    /// UTF-16 length (what `NSTextView` reports and what the caret offsets share).
    public static func characterCountDescription(_ count: Int,
                                                 language: AppLanguage = L10n.current) -> String {
        L10n.string(count == 1 ? .statusCharOne : .statusCharMany, language: language, count)
    }
}

/// A slim (22 pt) footer strip: caret position on the left, current language in
/// the middle, and the document character count on the right. All labels use
/// `secondaryLabelColor` at a small size, so they read as chrome and adapt to
/// light / dark automatically. A hairline `separatorColor` line tops the strip.
@MainActor
public final class StatusBarView: NSView {
    private let positionLabel = NSTextField(labelWithString: "")
    private let languageLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let separator = NSBox()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 22)
    }

    private func build() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)

        for label in [positionLabel, languageLabel, countLabel] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
        }
        positionLabel.alignment = .left
        languageLabel.alignment = .center
        countLabel.alignment = .right

        // Position hugs its content on the left; language stays centered; count
        // hugs on the right. Letting the language label absorb the slack keeps it
        // visually centered between the two fixed-width ends.
        positionLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        languageLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [positionLabel, languageLabel, countLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),

            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: separator.bottomAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            // Give the centered language label a stable width so it does not
            // dance as the two ends grow / shrink.
            languageLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ])
    }

    public override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        super.draw(dirtyRect)
    }

    // MARK: - Updates

    public func updateCaret(line: Int, column: Int) {
        positionLabel.stringValue = StatusBarMetrics.caretDescription(line: line, column: column)
    }

    public func updateLanguage(_ identifier: String) {
        languageLabel.stringValue = SupportedLanguage.title(forIdentifier: identifier)
    }

    public func updateCharacterCount(_ count: Int) {
        countLabel.stringValue = StatusBarMetrics.characterCountDescription(count)
    }
}
