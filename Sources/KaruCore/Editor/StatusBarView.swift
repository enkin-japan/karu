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

    /// The caption shown on the right while there is an active selection:
    /// selected character count, plus the number of lines it spans (omitted
    /// when the selection sits on a single line).
    public static func selectionDescription(length: Int, lines: Int,
                                            language: AppLanguage = L10n.current) -> String {
        if lines <= 1 {
            return L10n.string(.statusSelectionSingleLine, language: language, length)
        }
        return L10n.string(.statusSelection, language: language, length, lines)
    }

    /// Which of the two optional fields fit in a bar `width` points wide. The
    /// caret position and the count always show; in a narrow window the
    /// line-ending caption goes first, then the language. Widths are the
    /// fields' natural text widths; `inset` is the bar's side margin and
    /// `spacing` the gap between neighbouring fields.
    public static func optionalFields(width: CGFloat, position: CGFloat, language: CGFloat,
                                      lineEnding: CGFloat, count: CGFloat,
                                      inset: CGFloat, spacing: CGFloat)
        -> (language: Bool, lineEnding: Bool) {
        let base = inset * 2 + position + spacing + count
        let withLanguage = base + language + spacing
        let showLanguage = withLanguage <= width
        let showLineEnding = showLanguage && withLanguage + lineEnding + spacing <= width
        return (showLanguage, showLineEnding)
    }
}

/// A slim (22 pt) read-only footer strip: caret position on the left (transient
/// notes borrow that spot), and one group on the right — language, line
/// ending, then the character count (or the selection while there is one). In
/// a window too narrow for all of them the line ending hides first, then the
/// language; position and count always stay. All labels use
/// `secondaryLabelColor` at a small size, so they read as chrome and adapt to
/// light / dark automatically. A hairline `separatorColor` line tops the strip.
@MainActor
public final class StatusBarView: NSView {
    private let positionLabel = NSTextField(labelWithString: "")
    private let lineEndingLabel = NSTextField(labelWithString: "")
    private let languageLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let separator = NSBox()

    /// The full-document character count last reported via
    /// `updateCharacterCount(_:)`, kept so `clearSelection()` can restore the
    /// count label without the caller having to re-supply it.
    private var lastCharacterCount = 0

    /// The position label's normal caret caption, kept so a transient
    /// `flashMessage(_:)` can restore it after the flash expires (the caret may
    /// have moved meanwhile — this always holds the latest).
    private var lastPositionText = ""

    /// Live while a `flashMessage(_:)` note occupies the position label; fires
    /// once to restore the caret caption, then clears. Transient by design — no
    /// standing timer survives the 3-second note.
    private var flashTimer: Timer?

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

        for label in [positionLabel, lineEndingLabel, languageLabel, countLabel] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
        }
        positionLabel.alignment = .left
        languageLabel.alignment = .right
        lineEndingLabel.alignment = .right
        countLabel.alignment = .right

        // The right-hand group hugs its content; the position label takes the
        // slack on the left, and is the one to truncate when a long transient
        // note does not fit.
        for label in [languageLabel, lineEndingLabel, countLabel] {
            label.setContentHuggingPriority(.required, for: .horizontal)
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        positionLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        positionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [positionLabel, languageLabel, lineEndingLabel, countLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = Self.spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),

            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            stack.topAnchor.constraint(equalTo: separator.bottomAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private static let inset: CGFloat = 10
    private static let spacing: CGFloat = 12

    /// Hides the line ending, then the language, when the bar is too narrow
    /// for them (a stack view drops hidden views from layout).
    public override func layout() {
        updateOptionalFields()
        super.layout()
    }

    private func updateOptionalFields() {
        func width(_ label: NSTextField) -> CGFloat { ceil(label.intrinsicContentSize.width) }
        // Measured against the caret caption, not a transient note borrowing
        // its place: a note truncates rather than pushing fields out.
        let font = positionLabel.font ?? .systemFont(ofSize: 11)
        let position = ceil((lastPositionText as NSString).size(withAttributes: [.font: font]).width) + 4
        let fits = StatusBarMetrics.optionalFields(
            width: bounds.width, position: position, language: width(languageLabel),
            lineEnding: width(lineEndingLabel), count: width(countLabel),
            inset: Self.inset, spacing: Self.spacing)
        if languageLabel.isHidden == fits.language { languageLabel.isHidden = !fits.language }
        if lineEndingLabel.isHidden == fits.lineEnding { lineEndingLabel.isHidden = !fits.lineEnding }
    }

    /// Whether the language / line-ending fields currently show (for tests).
    var showsLanguage: Bool { !languageLabel.isHidden }
    var showsLineEnding: Bool { !lineEndingLabel.isHidden }

    // Deliberately NO draw(_:) override here. Overriding draw with an opaque
    // fill on a stack sibling of the editor's scroll view switches the whole
    // window onto a compositing path (macOS 26 beta) where NSTextView /
    // NSRulerView classic drawing never reaches the screen — the "completely
    // blank editor" bug shipped in v0.2.0. The window background showing
    // through is exactly the look we want anyway.

    // MARK: - Updates

    public func updateCaret(line: Int, column: Int) {
        let text = StatusBarMetrics.caretDescription(line: line, column: column)
        if text != lastPositionText { needsLayout = true }
        lastPositionText = text
        // Don't stomp an in-flight flash note; it restores `lastPositionText`
        // (kept current above) when it expires.
        if flashTimer == nil {
            positionLabel.stringValue = text
        }
    }

    /// Briefly replaces the caret caption with `text` (e.g. a silent auto-save
    /// failure), restoring the caret caption after 3 seconds. Used for
    /// non-modal, transient feedback that must never interrupt the user.
    public func flashMessage(_ text: String) {
        positionLabel.stringValue = text
        flashTimer?.invalidate()
        // Timer callbacks are nonisolated; the timer is scheduled on the main
        // run loop, so hopping back onto the main actor is a formality that
        // keeps this valid under Swift 6 isolation checking.
        flashTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.endFlash()
            }
        }
    }

    private func endFlash() {
        flashTimer = nil
        positionLabel.stringValue = lastPositionText
    }

    public func updateLanguage(_ identifier: String) {
        languageLabel.stringValue = SupportedLanguage.title(forIdentifier: identifier)
        needsLayout = true
    }

    public func updateLineEnding(_ lineEnding: LineEnding) {
        lineEndingLabel.stringValue = lineEnding.displayName
        needsLayout = true
    }

    public func updateCharacterCount(_ count: Int) {
        lastCharacterCount = count
        countLabel.stringValue = StatusBarMetrics.characterCountDescription(count)
        needsLayout = true
    }

    /// Switches the count field to the selection caption ("N selected · M
    /// lines") while there is an active, non-empty selection.
    public func updateSelection(length: Int, lines: Int) {
        countLabel.stringValue = StatusBarMetrics.selectionDescription(length: length, lines: lines)
        needsLayout = true
    }

    /// Restores the count field to the plain full-document character count
    /// (as last reported via `updateCharacterCount(_:)`) once the selection
    /// collapses back to a caret.
    public func clearSelection() {
        countLabel.stringValue = StatusBarMetrics.characterCountDescription(lastCharacterCount)
        needsLayout = true
    }

    /// The count field's current text (exposed for tests / diagnostics).
    var characterCountText: String { countLabel.stringValue }
}
