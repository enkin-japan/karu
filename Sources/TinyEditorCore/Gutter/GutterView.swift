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

    /// Sizes the ruler to fit the widest line number plus padding.
    private func updateThickness() {
        let digits = max(2, String(lineIndex.lineCount).count)
        let sample = String(repeating: "8", count: digits) as NSString
        let width = sample.size(withAttributes: [.font: numberFont]).width
        let thickness = max(40, ceil(width) + horizontalPadding * 2)
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
            drawNumber(lineNumber,
                       atY: y,
                       height: fragmentRect.height,
                       isCurrent: lineNumber == currentLine)

            if lineStart > endChar { break }
            lineNumber += 1
        }
    }

    private func drawNumber(_ number: Int, atY y: CGFloat, height: CGFloat, isCurrent: Bool) {
        let color: NSColor = isCurrent ? .labelColor : .secondaryLabelColor
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
