import AppKit

// M17 T17.6 — what one row of the completion popup shows (plan §5.5): the
// candidate's name with the typed characters emphasised, and a short, dimmed
// category label in the UI language. Pure presentation; the controller owns
// the panel and the table.
//
// T17.15a: three columns shared by every row of a list — the name, the
// detail (signature summary, its own column, truncated at its end) and the
// category label in a fixed column at the right edge — so the labels line
// up whatever the summaries' lengths.

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
    /// An inferred member's signature summary or type (T17.11b), shown
    /// after the label; nil for other candidates.
    var detail: String?

    init(candidate: Candidate, language: AppLanguage?) {
        name = candidate.name
        matchedRanges = CompletionRowContent.clamped(candidate.matchedRanges, length: (candidate.name as NSString).length)
        category = CompletionCategory.of(candidate)
        label = category.label(language: language)
        detail = candidate.detail
    }

    /// VoiceOver: name, category, detail.
    var accessibilityLabel: String { [name, label, detail].compactMap { $0 }.joined(separator: ", ") }

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
    /// Space between two columns (name, detail, label).
    static let gap: CGFloat = 14
    /// The detail column's widest extent; a longer summary is cut at its end.
    static let maximumDetailWidth: CGFloat = 240
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

    /// Width of a label or a detail (both in the label font).
    static func labelWidth(_ label: String) -> CGFloat {
        ceil((label as NSString).size(withAttributes: [.font: labelFont]).width)
    }

    /// Text-extent widths of the three columns, shared by every row of one
    /// list: the widest name, the widest detail up to `maximumDetailWidth`
    /// (0 when no row has one) and the widest label. A detail is measured
    /// only while the column is below its cap; each label once.
    struct Columns: Equatable {
        var name: CGFloat
        var detail: CGFloat
        var label: CGFloat
    }

    static func columns(rows: [CompletionRowContent]) -> Columns {
        var columns = Columns(name: 0, detail: 0, label: 0)
        var measuredLabels: Set<String> = []
        for row in rows {
            columns.name = max(columns.name, nameWidth(row.name))
            if measuredLabels.insert(row.label).inserted { columns.label = max(columns.label, labelWidth(row.label)) }
            if let detail = row.detail, !detail.isEmpty, columns.detail < maximumDetailWidth {
                columns.detail = max(columns.detail, min(maximumDetailWidth, labelWidth(detail)))
            }
        }
        return columns
    }

    /// The panel width fitting the columns (name + gap + [detail + gap] +
    /// label), clamped to [180, 480] and to the screen's visible width.
    /// `scroller`: width the vertical scroller takes (0 for overlay
    /// scrollers / ≤ 10 rows).
    static func panelWidth(columns: Columns, scroller: CGFloat, screenWidth: CGFloat?) -> CGFloat {
        var content = columns.name + gap + columns.label
        if columns.detail > 0 { content += columns.detail + gap }
        let natural = content + leadingPadding + trailingPadding + border + scroller
        var upper = maximumWidth
        if let screenWidth { upper = min(upper, max(minimumWidth, screenWidth - 2 * screenMargin)) }
        return min(upper, max(minimumWidth, ceil(natural)))
    }

    static func panelWidth(rows: [CompletionRowContent], scroller: CGFloat, screenWidth: CGFloat?) -> CGFloat {
        panelWidth(columns: columns(rows: rows), scroller: scroller, screenWidth: screenWidth)
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

/// One row: the name on the left (truncating in the middle), the detail in
/// its column (truncating at its end), the label in the fixed right-hand
/// column (`columns`, shared by the list's rows). Colours follow the row's
/// selection style. VoiceOver reads the row as one element: name, label,
/// detail.
@MainActor
final class CompletionCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("KaruCompletionCell")

    let nameField = NSTextField(labelWithString: "")
    let detailField = NSTextField(labelWithString: "")
    let labelField = NSTextField(labelWithString: "")
    private(set) var content: CompletionRowContent?
    /// The list's column widths (nil: this row's own).
    private(set) var columns: CompletionListMetrics.Columns?

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        for field in [nameField, detailField, labelField] {
            field.usesSingleLineMode = true
            field.cell?.truncatesLastVisibleLine = true
            field.setAccessibilityElement(false)
            addSubview(field)
        }
        nameField.lineBreakMode = .byTruncatingMiddle
        for field in [detailField, labelField] {
            field.font = CompletionListMetrics.labelFont
            field.lineBreakMode = .byTruncatingTail
            field.alignment = .left
        }
        textField = nameField
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ content: CompletionRowContent, columns: CompletionListMetrics.Columns? = nil) {
        self.content = content
        self.columns = columns
        labelField.stringValue = content.label
        detailField.stringValue = content.detail ?? ""
        detailField.isHidden = content.detail?.isEmpty ?? true
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
        let secondary: NSColor = selected
            ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.8)
            : .secondaryLabelColor
        labelField.textColor = secondary
        detailField.textColor = secondary
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

    /// Text extents, left to right: the name from `leadingPadding`, its
    /// column as wide as the list's widest name (less when the panel is
    /// clamped; the label column always shows whole); the detail from the
    /// end of the name column plus `gap` to `gap` before the label column;
    /// the label column ending `trailingPadding` before the edge. Field
    /// frames add the cell inset around their text.
    private func layoutFields() {
        let bounds = self.bounds
        let inset = CompletionListMetrics.textInset
        let gap = CompletionListMetrics.gap
        let columns = self.columns ?? content.map { CompletionListMetrics.columns(rows: [$0]) }
            ?? CompletionListMetrics.Columns(name: 0, detail: 0, label: 0)
        let inner = max(0, bounds.width - CompletionListMetrics.leadingPadding - CompletionListMetrics.trailingPadding)
        let labelText = min(columns.label, inner)
        let labelTextX = bounds.maxX - CompletionListMetrics.trailingPadding - labelText
        let nameTextX = CompletionListMetrics.leadingPadding
        let nameRoom = max(0, labelTextX - gap - nameTextX)
        let hasDetail = !detailField.isHidden
        // Without a detail the name may use the whole room up to the label.
        let nameText = hasDetail ? min(columns.name, nameRoom) : nameRoom
        let detailTextX = nameTextX + min(columns.name, nameRoom) + gap
        let detailText = max(0, labelTextX - gap - detailTextX)

        func place(_ field: NSTextField, x: CGFloat, width: CGFloat) {
            let height = field.intrinsicContentSize.height
            field.frame = NSRect(x: x - inset, y: floor((bounds.height - height) / 2), width: width + 2 * inset,
                                 height: height)
        }
        place(labelField, x: labelTextX, width: labelText)
        place(nameField, x: nameTextX, width: nameText)
        if hasDetail { place(detailField, x: detailTextX, width: detailText) }
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
