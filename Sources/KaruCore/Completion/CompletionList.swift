import AppKit

// M17 T17.6 — what one row of the completion popup shows (plan §5.5): the
// candidate's name with the typed characters emphasised, and a short, dimmed
// category label in the UI language. Pure presentation; the controller owns
// the panel and the table.

/// The category label shown on the right of a completion row.
public enum CompletionCategory: CaseIterable, Sendable {
    case parameter, local, member, function, type, variable, keyword, builtin, module, file, word

    /// The label category of a candidate. A workspace candidate (T17.14) is
    /// labelled by its source ("file"); everything else by its kind.
    public static func of(_ candidate: Candidate) -> CompletionCategory {
        if candidate.source == .workspace { return .file }
        switch candidate.kind {
        case .parameter: return .parameter
        case .local: return .local
        case .member, .method, .property: return .member
        case .function: return .function
        case .type: return .type
        case .variable: return .variable
        case .keyword: return .keyword
        case .builtin: return .builtin
        case .module: return .module
        case .word: return .word
        }
    }

    var key: L10nKey {
        switch self {
        case .parameter: return .completionKindParameter
        case .local: return .completionKindLocal
        case .member: return .completionKindMember
        case .function: return .completionKindFunction
        case .type: return .completionKindType
        case .variable: return .completionKindVariable
        case .keyword: return .completionKindKeyword
        case .builtin: return .completionKindBuiltin
        case .module: return .completionKindModule
        case .file: return .completionKindFile
        case .word: return .completionKindWord
        }
    }

    /// The localized label (`language` nil: the current UI language).
    public func label(language: AppLanguage? = nil) -> String {
        language.map { L10n.string(key, language: $0) } ?? L10n.t(key)
    }
}

/// The content of one completion row.
struct CompletionRowContent: Equatable {
    let name: String
    /// UTF-16 ranges of `name` to emphasise (clamped to `name`).
    let matchedRanges: [NSRange]
    let category: CompletionCategory
    let label: String
    /// Seam: members and functions append an inferred type or signature
    /// summary here (T17.11+); nothing fills it yet.
    var detail: String?

    init(candidate: Candidate, language: AppLanguage?) {
        name = candidate.name
        matchedRanges = CompletionRowContent.clamped(candidate.matchedRanges, length: (candidate.name as NSString).length)
        category = CompletionCategory.of(candidate)
        label = category.label(language: language)
        detail = nil
    }

    /// The right-hand text: the label, then the detail when there is one.
    var trailingText: String { detail.map { label + "  " + $0 } ?? label }

    /// VoiceOver: name, category (and detail).
    var accessibilityLabel: String { name + ", " + trailingText }

    static func clamped(_ ranges: [NSRange], length: Int) -> [NSRange] {
        ranges.compactMap { range in
            guard range.location != NSNotFound, range.location < length, range.length > 0 else { return nil }
            return NSRange(location: range.location, length: min(range.length, length - range.location))
        }
    }
}

/// Fonts, metrics and the adaptive panel width of the completion list.
@MainActor
enum CompletionListMetrics {
    static let rowHeight: CGFloat = 18
    static let rowPitch: CGFloat = 19          // rowHeight + intercell spacing
    static let visibleRows = 10
    static let leadingPadding: CGFloat = 6
    static let trailingPadding: CGFloat = 6
    /// Space between the name and the label.
    static let gap: CGFloat = 14
    /// The scroll view's line border, both sides.
    static let border: CGFloat = 2
    static let minimumWidth: CGFloat = 180
    static let maximumWidth: CGFloat = 480
    /// Kept clear of the screen's visible frame on each side.
    static let screenMargin: CGFloat = 4
    /// An `NSTextField` cell draws its text inset by this much on each side;
    /// the paddings and the gap above are measured between text extents.
    static let textInset: CGFloat = 2

    static let nameFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let matchFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
    static let labelFont = NSFont.systemFont(ofSize: 11)

    /// Name width; the bold match font has the same advances in SF Mono, so
    /// the regular font measures the emphasised string as well.
    static func nameWidth(_ name: String) -> CGFloat {
        ceil((name as NSString).size(withAttributes: [.font: nameFont]).width)
    }

    static func labelWidth(_ label: String) -> CGFloat {
        ceil((label as NSString).size(withAttributes: [.font: labelFont]).width)
    }

    /// The panel width fitting the widest row (name + gap + label), clamped to
    /// [180, 480] and to the screen's visible width. `scroller`: width the
    /// vertical scroller takes (0 for overlay scrollers / ≤ 10 rows).
    static func panelWidth(rows: [CompletionRowContent], scroller: CGFloat, screenWidth: CGFloat?) -> CGFloat {
        var labelWidths: [String: CGFloat] = [:]
        var widest: CGFloat = 0
        for row in rows {
            let trailing = row.trailingText
            let label: CGFloat
            if let cached = labelWidths[trailing] {
                label = cached
            } else {
                label = labelWidth(trailing)
                labelWidths[trailing] = label
            }
            widest = max(widest, nameWidth(row.name) + gap + label)
        }
        let natural = widest + leadingPadding + trailingPadding + border + scroller
        var upper = maximumWidth
        if let screenWidth { upper = min(upper, max(minimumWidth, screenWidth - 2 * screenMargin)) }
        return min(upper, max(minimumWidth, ceil(natural)))
    }

    /// The name as shown: matched ranges in the bold font; middle truncation.
    static func attributedName(_ row: CompletionRowContent, color: NSColor = .labelColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let text = NSMutableAttributedString(string: row.name, attributes: [
            .font: nameFont, .foregroundColor: color, .paragraphStyle: paragraph,
        ])
        for range in row.matchedRanges { text.addAttribute(.font, value: matchFont, range: range) }
        return text
    }
}

/// One row: the name on the left (truncating in the middle), the label on the
/// right. Colours follow the row's selection style.
@MainActor
final class CompletionCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("KaruCompletionCell")

    let nameField = NSTextField(labelWithString: "")
    let labelField = NSTextField(labelWithString: "")
    private(set) var content: CompletionRowContent?

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        for field in [nameField, labelField] {
            field.usesSingleLineMode = true
            field.cell?.truncatesLastVisibleLine = true
            field.setAccessibilityElement(false)
            addSubview(field)
        }
        nameField.lineBreakMode = .byTruncatingMiddle
        labelField.font = CompletionListMetrics.labelFont
        labelField.lineBreakMode = .byClipping
        labelField.alignment = .right
        textField = nameField
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ content: CompletionRowContent) {
        self.content = content
        labelField.stringValue = content.trailingText
        setAccessibilityLabel(content.accessibilityLabel)
        applyColors()
        needsLayout = true
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { if oldValue != backgroundStyle { applyColors() } }
    }

    private func applyColors() {
        let selected = backgroundStyle == .emphasized
        let nameColor: NSColor = selected ? .alternateSelectedControlTextColor : .labelColor
        if let content { nameField.attributedStringValue = CompletionListMetrics.attributedName(content, color: nameColor) }
        labelField.textColor = selected
            ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.8)
            : .secondaryLabelColor
    }

    override func layout() {
        super.layout()
        layoutFields()
    }

    /// The table resizes cells through autoresizing (no constraints), which
    /// does not run `layout()`: re-place the fields on every resize too.
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutFields()
    }

    private func layoutFields() {
        let bounds = self.bounds
        let inset = CompletionListMetrics.textInset
        let labelText = content.map { _ in CompletionListMetrics.labelWidth(labelField.stringValue) } ?? 0
        let labelHeight = labelField.intrinsicContentSize.height
        let nameHeight = nameField.intrinsicContentSize.height
        // Text extents: the label's text ends `trailingPadding` before the
        // edge; the name's text starts `leadingPadding` in and ends `gap`
        // before the label's text. Field frames add the cell inset around them.
        let labelTextX = bounds.maxX - CompletionListMetrics.trailingPadding - labelText
        labelField.frame = NSRect(x: labelTextX - inset, y: floor((bounds.height - labelHeight) / 2),
                                  width: labelText + 2 * inset, height: labelHeight)
        let nameTextX = CompletionListMetrics.leadingPadding
        let nameText = max(0, labelTextX - CompletionListMetrics.gap - nameTextX)
        nameField.frame = NSRect(x: nameTextX - inset, y: floor((bounds.height - nameHeight) / 2),
                                 width: nameText + 2 * inset, height: nameHeight)
    }
}

/// The selected row is drawn emphasised (accent colour) although the
/// non-activating panel never becomes key, as the system completion list does.
final class CompletionRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        bounds.fill()
    }
}
