import AppKit

/// The document title shown in the centre of the window's titlebar (T11.4),
/// replacing the native title text. Saved and untitled documents show their
/// name at the same place in the same font; a leading "●" marks unsaved
/// changes (the native `isDocumentEdited` dot is hidden along with the native
/// title).
///
/// The title is plain text by default. Hovering a saved document's title
/// draws a rounded capsule around it, hinting that a click renames the file;
/// an untitled document's title is static (nothing to rename until it is
/// saved).
///
/// Clicking swaps the label for an inline `NSTextField` pre-selected on the
/// base name (extension excluded); Return commits the rename via `onCommit`,
/// Escape (or losing focus) cancels. The control itself performs no filesystem
/// work — it just reports the requested name to its owner, which drives
/// `DocumentController.rename(to:)`.
///
/// This is a titlebar accessory-style control hosted in the unified toolbar's
/// centre, NOT a `draw(_:)` override on a sibling of the editor's scroll view —
/// so it steers clear of the v0.2.0 blank-window compositing red line
/// (see StatusBarView.swift).
@MainActor
public final class TitleRenameControl: NSView {
    /// Called with the requested new file name (including extension) when the
    /// user commits an edit that actually changed the name.
    public var onCommit: ((String) -> Void)?

    private let label = NSTextField(labelWithString: "")
    private var editorField: NSTextField?

    private var fileName: String = ""
    private var hasFile = false
    private var isDirty = false
    private var isHovered = false

    private static let horizontalPadding: CGFloat = 10
    private static let height: CGFloat = 20

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalPadding),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalPadding),
        ])
    }

    public override var intrinsicContentSize: NSSize {
        let textWidth = label.intrinsicContentSize.width
        return NSSize(width: min(360, textWidth + Self.horizontalPadding * 2),
                      height: Self.height)
    }

    // MARK: - Configuration

    /// Refreshes the displayed name and dirty marker. `hasFile == false` (an
    /// untitled document) shows the same text without the rename interaction.
    public func configure(fileName: String, hasFile: Bool, isDirty: Bool) {
        self.fileName = fileName
        self.hasFile = hasFile
        self.isDirty = isDirty
        if !hasFile { isHovered = false }
        label.attributedStringValue = Self.title(fileName: fileName, isDirty: isDirty, font: label.font)
        toolTip = hasFile ? fileName : nil
        setAccessibilityLabel((isDirty ? "● " : "") + fileName)
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    /// The displayed title: the name in the label colour, preceded by a
    /// quieter "●" while there are unsaved changes.
    static func title(fileName: String, isDirty: Bool, font: NSFont?) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingMiddle
        var base: [NSAttributedString.Key: Any] = [.paragraphStyle: paragraph, .foregroundColor: NSColor.labelColor]
        if let font { base[.font] = font }
        let result = NSMutableAttributedString()
        if isDirty {
            var marker = base
            marker[.foregroundColor] = NSColor.secondaryLabelColor
            result.append(NSAttributedString(string: "● ", attributes: marker))
        }
        result.append(NSAttributedString(string: fileName, attributes: base))
        return result
    }

    /// Whether the rename capsule is currently drawn (saved document, hovered).
    var showsCapsule: Bool { hasFile && isHovered && editorField == nil }

    // MARK: - Appearance

    /// Draws the hover capsule directly (rather than via a layer background) so
    /// it is reliably captured by `cacheDisplay` / offscreen rendering. Fill and
    /// border derive from labelColor (dynamic across light / dark). Nothing is
    /// drawn unless a saved document's title is hovered. This is a small
    /// translucent rounded fill on a titlebar toolbar item — not an opaque cover
    /// on an editor stack sibling — so it is clear of the v0.2.0 blank-window
    /// red line (see StatusBarView.swift).
    public override func draw(_ dirtyRect: NSRect) {
        guard showsCapsule else { return }
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        NSColor.labelColor.withAlphaComponent(0.10).setFill()
        path.fill()
        NSColor.labelColor.withAlphaComponent(0.22).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    // MARK: - Hover

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    public override func mouseEntered(with event: NSEvent) {
        guard hasFile, editorField == nil else { return }
        isHovered = true
        needsDisplay = true
    }

    public override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    // MARK: - Inline editing

    /// An untitled document's title is static text: dragging it moves the
    /// window like any other empty stretch of the titlebar.
    public override var mouseDownCanMoveWindow: Bool { !hasFile }

    public override func mouseDown(with event: NSEvent) {
        guard hasFile else { super.mouseDown(with: event); return }
        guard editorField == nil else { return }
        beginEditing()
    }

    private func beginEditing() {
        let field = NSTextField(string: fileName)
        field.font = .systemFont(ofSize: 13, weight: .medium)
        field.alignment = .center
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor),
            field.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        editorField = field
        label.isHidden = true
        isHovered = false
        needsDisplay = true

        window?.makeFirstResponder(field)
        // Pre-select the base name (extension excluded) so a quick edit only
        // touches the stem, matching Finder's inline rename.
        if let fieldEditor = window?.fieldEditor(true, for: field) {
            let stem = (fileName as NSString).deletingPathExtension
            fieldEditor.selectedRange = NSRange(location: 0, length: (stem as NSString).length)
        }
    }

    private func commitEditing() {
        guard let field = editorField else { return }
        let newName = field.stringValue
        endEditing()
        if newName != fileName {
            onCommit?(newName)
        }
    }

    private func cancelEditing() {
        endEditing()
    }

    private func endEditing() {
        guard let field = editorField else { return }
        editorField = nil
        window?.makeFirstResponder(nil)
        field.removeFromSuperview()
        label.isHidden = false
    }
}

// MARK: - Inline field key handling

extension TitleRenameControl: NSTextFieldDelegate {
    public func control(_ control: NSControl,
                        textView: NSTextView,
                        doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            commitEditing(); return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancelEditing(); return true
        default:
            return false
        }
    }

    /// Losing focus without an explicit Return/Escape cancels the edit rather
    /// than leaving a stuck field.
    public func controlTextDidEndEditing(_ obj: Notification) {
        if editorField != nil { cancelEditing() }
    }
}
