import AppKit

/// Line-number gutter, implemented as an `NSRulerView` attached as the vertical
/// ruler of the editor's scroll view.
///
/// Design (ARCHITECTURE.md §3):
/// - Viewport-only: only line numbers for the visible glyph range are drawn.
/// - Painted, not stored: no per-line data is retained; line numbers come from
///   the shared `LineIndex`, the only persistent structure involved.
/// - One index, reused: the same `LineIndex` instance is injected here and
///   (later) shared with search / folding.
///
/// The view drives incremental `LineIndex` updates from the storage layer so it
/// has an accurate edited range + length delta. Because `NSTextStorage` has a
/// single delegate slot (also wanted by the highlight engine), it registers as
/// a `TextStorageObserving` observer on the shared `TextStorageObserverHub`
/// rather than being the delegate directly.
public final class GutterView: NSRulerView, TextStorageObserving {
    /// Shared newline index (owned by the window controller).
    private let lineIndex: LineIndex

    /// Font used for the line numbers.
    private let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    /// Horizontal padding inside the ruler.
    private let horizontalPadding: CGFloat = 6

    /// Width reserved on the left for fold arrows. Widened (12 → 16) so the
    /// solid-triangle controls read clearly at a glance.
    private let arrowColumnWidth: CGFloat = 16

    /// Folding layer queried for arrow state and hidden lines. Weak: owned by
    /// the window controller. When `nil` the gutter behaves exactly as before
    /// (no arrows, no reserved column).
    public weak var foldProvider: FoldStatusProviding? {
        didSet {
            updateThickness()
            needsDisplay = true
        }
    }

    public init(scrollView: NSScrollView,
                textView: NSTextView,
                lineIndex: LineIndex,
                observerHub: TextStorageObserverHub) {
        self.lineIndex = lineIndex
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 40
        reservedThicknessForMarkers = 0

        // Share the single storage-delegate slot via the multiplexer.
        observerHub.add(self)

        // Redraw on scroll.
        if let contentView = scrollView.contentView as NSClipView? {
            contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(viewportChanged),
                name: NSView.boundsDidChangeNotification,
                object: contentView
            )
        }
        // Redraw the current-line highlight on selection change, and refresh
        // width after user edits.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(viewportChanged),
            name: NSTextView.didChangeSelectionNotification,
            object: textView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textChanged),
            name: NSText.didChangeNotification,
            object: textView
        )

        updateThickness()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Notifications

    @objc private func viewportChanged() {
        needsDisplay = true
    }

    @objc private func textChanged() {
        updateThickness()
        needsDisplay = true
    }

    /// Incremental `LineIndex` update, driven from the storage layer (via the
    /// observer hub) so we have the precise edited range and length delta.
    /// Attribute-only edits (e.g. syntax highlighting) are ignored.
    public func textStorageDidProcessEditing(editedMask: NSTextStorageEditActions,
                                             editedRange: NSRange,
                                             changeInLength delta: Int,
                                             textStorage: NSTextStorage) {
        guard editedMask.contains(.editedCharacters) else { return }
        lineIndex.update(text: textStorage.string,
                         editedRange: editedRange,
                         changeInLength: delta)
    }

    // MARK: - Width

    /// Sizes the ruler to fit the widest line number plus padding, plus the
    /// fold-arrow column when a fold provider is attached.
    private func updateThickness() {
        let digits = max(2, String(lineIndex.lineCount).count)
        let sample = String(repeating: "8", count: digits) as NSString
        let width = sample.size(withAttributes: [.font: numberFont]).width
        let arrowColumn = foldProvider != nil ? arrowColumnWidth : 0
        let thickness = max(40, ceil(width) + horizontalPadding * 2 + arrowColumn)
        if abs(thickness - ruleThickness) > 0.5 {
            ruleThickness = thickness
        }
    }

    // MARK: - Drawing

    public override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer,
              let scrollView else { return }

        // Background matching the text area, with a hairline separator.
        NSColor.textBackgroundColor.setFill()
        bounds.fill()

        let content = textView.string as NSString
        let visibleRect = scrollView.contentView.bounds
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        let currentLine = lineIndex.lineNumber(forOffset: textView.selectedRange().location)

        enumerateVisibleLines(textView: textView,
                              layoutManager: layoutManager,
                              content: content,
                              charRange: charRange) { lineNumber, rect in
            // Hidden (folded-away) lines produce zero-height fragments; don't
            // draw their numbers.
            if foldProvider?.isLineHidden(lineNumber) == true { return }
            let state = foldProvider?.foldState(atLine: lineNumber) ?? .none
            drawNumber(lineNumber,
                       atY: rect.minY,
                       height: rect.height,
                       isCurrent: lineNumber == currentLine,
                       isFoldedHeader: state == .folded)
            if foldProvider != nil {
                drawArrow(state, atY: rect.minY, height: rect.height)
            }
        }
    }

    /// Walks the visible line numbers, invoking `body` with each line's rect in
    /// this ruler's coordinate space. Shared by drawing and click hit-testing so
    /// the geometry stays in one place.
    private func enumerateVisibleLines(textView: NSTextView,
                                       layoutManager: NSLayoutManager,
                                       content: NSString,
                                       charRange: NSRange,
                                       _ body: (_ line: Int, _ rect: NSRect) -> Void) {
        let inset = textView.textContainerOrigin
        let relativePoint = convert(NSPoint.zero, from: textView)

        var lineNumber = lineIndex.lineNumber(forOffset: charRange.location)
        let endChar = charRange.location + charRange.length

        while lineNumber <= lineIndex.lineCount {
            let lineStart = lineIndex.offsetRange(ofLine: lineNumber).lowerBound

            let fragmentRect: NSRect
            if lineStart < content.length {
                let glyphIndex = layoutManager.glyphIndexForCharacter(at: lineStart)
                fragmentRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            } else {
                // Final empty line (empty document, or text ending in newline).
                fragmentRect = layoutManager.extraLineFragmentRect
            }

            let y = fragmentRect.minY + inset.y + relativePoint.y
            body(lineNumber, NSRect(x: 0, y: y, width: ruleThickness, height: fragmentRect.height))

            if lineStart > endChar { break }
            lineNumber += 1
        }
    }

    /// Draws the fold control as a solid ~8 pt triangle in the left arrow
    /// column: a down-pointing ▼ for an expanded header (muted), a right-pointing
    /// ▶ for a folded header (accent-coloured so the collapsed state stands out).
    ///
    /// Trade-off: the control is always shown for foldable lines rather than only
    /// on hover. Hover-reveal would need a tracking area and per-line hit state;
    /// the always-on control is simpler and, at this size, unobtrusive.
    private func drawArrow(_ state: FoldArrow, atY y: CGFloat, height: CGFloat) {
        let color: NSColor
        switch state {
        case .none:     return
        case .foldable: color = .secondaryLabelColor
        case .folded:   color = .controlAccentColor
        }

        let cx = arrowColumnWidth / 2
        let cy = y + height / 2
        // In a flipped ruler +y is downward; keep the visual orientation correct
        // regardless of the view's flip state.
        let down: CGFloat = isFlipped ? 1 : -1
        let path = NSBezierPath()
        switch state {
        case .none:
            return
        case .foldable:
            // ▼ apex pointing down, base on top.
            let w: CGFloat = 8, h: CGFloat = 5
            path.move(to: NSPoint(x: cx - w / 2, y: cy - h / 2 * down))
            path.line(to: NSPoint(x: cx + w / 2, y: cy - h / 2 * down))
            path.line(to: NSPoint(x: cx, y: cy + h / 2 * down))
        case .folded:
            // ▶ apex pointing right, base on the left.
            let w: CGFloat = 5, h: CGFloat = 8
            path.move(to: NSPoint(x: cx - w / 2, y: cy - h / 2))
            path.line(to: NSPoint(x: cx - w / 2, y: cy + h / 2))
            path.line(to: NSPoint(x: cx + w / 2, y: cy))
        }
        path.close()
        color.setFill()
        path.fill()
    }

    // MARK: - Click handling

    public override func mouseDown(with event: NSEvent) {
        guard let provider = foldProvider,
              let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer,
              let scrollView else {
            super.mouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard point.x <= arrowColumnWidth else {
            super.mouseDown(with: event)
            return
        }

        let content = textView.string as NSString
        let visibleRect = scrollView.contentView.bounds
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        var hitLine: Int?
        enumerateVisibleLines(textView: textView,
                              layoutManager: layoutManager,
                              content: content,
                              charRange: charRange) { lineNumber, rect in
            if hitLine == nil, rect.height > 0, rect.contains(point),
               provider.foldState(atLine: lineNumber) != .none {
                hitLine = lineNumber
            }
        }
        if let hitLine {
            provider.toggleFold(atLine: hitLine)
        }
    }

    private func drawNumber(_ number: Int, atY y: CGFloat, height: CGFloat, isCurrent: Bool, isFoldedHeader: Bool = false) {
        // A folded header's number is accent-coloured so the collapsed block is
        // easy to spot; otherwise the current line is emphasised over the rest.
        let color: NSColor
        if isFoldedHeader {
            color = .controlAccentColor
        } else {
            color = isCurrent ? .labelColor : .secondaryLabelColor
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: numberFont,
            .foregroundColor: color,
        ]
        let text = String(number) as NSString
        let size = text.size(withAttributes: attrs)
        let x = ruleThickness - size.width - horizontalPadding
        let drawRect = NSRect(x: x,
                              y: y + (height - size.height) / 2,
                              width: size.width,
                              height: size.height)
        text.draw(in: drawRect, withAttributes: attrs)
    }
}
