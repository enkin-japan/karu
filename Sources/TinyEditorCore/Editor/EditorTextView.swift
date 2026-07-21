import AppKit

// MARK: - Pure indent logic

/// A single text replacement describing an indent operation.
///
/// `range` and `selection` use UTF-16 offsets (NSString semantics) so the
/// result maps directly onto `NSTextView` ranges.
public struct IndentEdit: Equatable {
    /// Range in the original text to replace.
    public var range: NSRange
    /// Text to substitute for `range`.
    public var replacement: String
    /// Selection to install after the edit is applied.
    public var selection: NSRange

    public init(range: NSRange, replacement: String, selection: NSRange) {
        self.range = range
        self.replacement = replacement
        self.selection = selection
    }
}

/// Pure, NSTextView-independent implementation of the editor's indentation
/// behaviour. Every entry point takes the document string plus the current
/// selection and returns an `IndentEdit`; `EditorTextView` is a thin wrapper
/// that feeds these results through the undo-aware text mutation path.
public enum IndentEngine {
    /// Tab key: with an empty selection, insert one indent unit at the caret;
    /// with a non-empty selection, prepend one indent unit to each affected
    /// line.
    public static func tab(text: String, selection: NSRange, width: Int, usesSpaces: Bool) -> IndentEdit {
        let unit = indentUnit(width: width, usesSpaces: usesSpaces)
        let ns = text as NSString
        if selection.length == 0 {
            let unitLen = (unit as NSString).length
            return IndentEdit(
                range: NSRange(location: selection.location, length: 0),
                replacement: unit,
                selection: NSRange(location: selection.location + unitLen, length: 0)
            )
        }
        return indentLines(ns: ns, selection: selection, unit: unit)
    }

    /// Shift-Tab key: remove up to one indent level from the start of each
    /// affected line (one leading tab, or up to `width` leading spaces).
    public static func shiftTab(text: String, selection: NSRange, width: Int, usesSpaces: Bool) -> IndentEdit {
        let ns = text as NSString
        let block = ns.lineRange(for: selection)
        var result = ""
        for line in splitLines(ns.substring(with: block)) {
            result += removeLeadingIndent(line, width: width)
        }
        let newLen = (result as NSString).length
        return IndentEdit(
            range: block,
            replacement: result,
            selection: NSRange(location: block.location, length: newLen)
        )
    }

    /// Return key: insert a newline that inherits the current line's leading
    /// whitespace, plus one extra indent level when the text before the caret
    /// ends with an opening bracket or colon.
    public static func newline(text: String, selection: NSRange, width: Int, usesSpaces: Bool) -> IndentEdit {
        let ns = text as NSString
        let unit = indentUnit(width: width, usesSpaces: usesSpaces)
        let caretLine = ns.lineRange(for: NSRange(location: selection.location, length: 0))
        let lineString = ns.substring(with: caretLine)
        let leading = leadingWhitespace(of: lineString)

        let beforeLen = selection.location - caretLine.location
        let before = ns.substring(with: NSRange(location: caretLine.location, length: beforeLen))
        let trimmed = trimTrailingWhitespace(before)

        var newIndent = leading
        if let last = trimmed.last, "{[(:".contains(last) {
            newIndent += unit
        }

        let replacement = "\n" + newIndent
        let repLen = (replacement as NSString).length
        return IndentEdit(
            range: selection,
            replacement: replacement,
            selection: NSRange(location: selection.location + repLen, length: 0)
        )
    }

    // MARK: Helpers

    /// One indentation unit: `width` spaces, or a single tab.
    public static func indentUnit(width: Int, usesSpaces: Bool) -> String {
        usesSpaces ? String(repeating: " ", count: max(0, width)) : "\t"
    }

    private static func indentLines(ns: NSString, selection: NSRange, unit: String) -> IndentEdit {
        let block = ns.lineRange(for: selection)
        var result = ""
        for line in splitLines(ns.substring(with: block)) {
            result += lineHasContent(line) ? unit + line : line
        }
        let newLen = (result as NSString).length
        return IndentEdit(
            range: block,
            replacement: result,
            selection: NSRange(location: block.location, length: newLen)
        )
    }

    /// Splits a block of text into lines, each retaining its line terminator.
    private static func splitLines(_ text: String) -> [String] {
        let ns = text as NSString
        var lines: [String] = []
        var index = 0
        while index < ns.length {
            let range = ns.lineRange(for: NSRange(location: index, length: 0))
            lines.append(ns.substring(with: range))
            index = range.location + range.length
        }
        return lines
    }

    /// Removes at most one indent level from the front of `line`.
    private static func removeLeadingIndent(_ line: String, width: Int) -> String {
        let ns = line as NSString
        if ns.length > 0, ns.substring(to: 1) == "\t" {
            return ns.substring(from: 1)
        }
        var removed = 0
        while removed < ns.length && removed < width {
            if ns.substring(with: NSRange(location: removed, length: 1)) == " " {
                removed += 1
            } else {
                break
            }
        }
        return ns.substring(from: removed)
    }

    /// True when the line contains any character other than its terminator.
    private static func lineHasContent(_ line: String) -> Bool {
        let ns = line as NSString
        var length = ns.length
        while length > 0 {
            let c = ns.substring(with: NSRange(location: length - 1, length: 1))
            if c == "\n" || c == "\r" { length -= 1 } else { break }
        }
        return length > 0
    }

    /// Leading run of spaces / tabs in `line`.
    private static func leadingWhitespace(of line: String) -> String {
        let ns = line as NSString
        var end = 0
        while end < ns.length {
            let c = ns.substring(with: NSRange(location: end, length: 1))
            if c == " " || c == "\t" { end += 1 } else { break }
        }
        return ns.substring(to: end)
    }

    private static func trimTrailingWhitespace(_ text: String) -> String {
        let ns = text as NSString
        var end = ns.length
        while end > 0 {
            let c = ns.substring(with: NSRange(location: end - 1, length: 1))
            if c == " " || c == "\t" || c == "\n" || c == "\r" { end -= 1 } else { break }
        }
        return ns.substring(to: end)
    }
}

// MARK: - NSTextView subclass

/// Editor text view enforcing the "plain text is the only truth" rule and the
/// project's Tab / Shift-Tab / auto-indent behaviour. All text mutation goes
/// through the undo-aware `insertText(_:replacementRange:)` path; the view
/// itself holds no indent logic beyond dispatching to `IndentEngine`.
public final class EditorTextView: NSTextView {
    /// Indentation configuration source (per-language widths, spaces vs tabs).
    public var indentSettings = IndentSettings()

    /// Language identifier used to look up the indent width (e.g. "html").
    public var languageIdentifier: String = ""

    /// Optional completion popup hook. Held weakly and consulted only in
    /// `keyDown` / `mouseDown`; when unset (or inactive) it adds no per-keystroke
    /// cost beyond a nil / bool check.
    public weak var completionKeyHandler: CompletionKeyHandler?

    /// Whether indent-rainbow blocks are drawn. Defaults from UserDefaults key
    /// `editor.indentRainbow` (on when unset). Toggling triggers a redraw.
    public var indentRainbowEnabled: Bool = IndentRainbow.defaultEnabled {
        didSet {
            guard oldValue != indentRainbowEnabled else { return }
            needsDisplay = true
        }
    }

    // MARK: Indent rainbow drawing

    /// Draws indent-rainbow blocks behind the visible text. Viewport-only: only
    /// the lines intersecting `rect` are recomputed and painted (nothing is
    /// stored per line).
    public override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard indentRainbowEnabled,
              let layoutManager,
              let container = textContainer else { return }

        let ns = string as NSString
        guard ns.length > 0 else { return }

        let width = indentSettings.width(for: languageIdentifier)
        let origin = textContainerOrigin

        // Character range covering the dirty rect, expanded to whole lines.
        let glyphRange = layoutManager.glyphRange(forBoundingRect: rect, in: container)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let endChar = min(charRange.location + charRange.length, ns.length)

        var loc = ns.lineRange(for: NSRange(location: min(charRange.location, ns.length - 1), length: 0)).location
        while loc <= endChar {
            let lineRange = ns.lineRange(for: NSRange(location: loc, length: 0))
            let lineString = ns.substring(with: lineRange)
            let blocks = IndentRainbow.blocks(forLine: lineString, indentWidth: width)
            for block in blocks {
                let absolute = NSRange(location: loc + block.columnRange.lowerBound,
                                       length: block.columnRange.count)
                let gRange = layoutManager.glyphRange(forCharacterRange: absolute, actualCharacterRange: nil)
                var blockRect = layoutManager.boundingRect(forGlyphRange: gRange, in: container)
                blockRect.origin.x += origin.x
                blockRect.origin.y += origin.y
                IndentRainbow.color(forLevel: block.level).setFill()
                blockRect.fill()

                // Draw a 1px separator at the right edge of full indent units
                // so the width of "one indent" is easy to count at a glance.
                // Partial (remainder) blocks keep their existing fill-only
                // treatment.
                if block.columnRange.count == width {
                    let scale = window?.backingScaleFactor ?? 1
                    let lineWidth = max(1, scale) / scale
                    var separatorRect = blockRect
                    separatorRect.origin.x = blockRect.maxX - lineWidth
                    separatorRect.size.width = lineWidth
                    IndentRainbow.separatorColor(forLevel: block.level).setFill()
                    separatorRect.fill()
                }
            }
            let next = lineRange.location + lineRange.length
            if next <= loc { break } // guard against zero-length final line
            loc = next
        }
    }

    // MARK: Completion key routing

    /// Give an active completion popup first refusal on navigation keys, then
    /// let the normal input path run and notify the popup of the keystroke so it
    /// can open / refilter / dismiss. Zero overhead when no handler is attached.
    public override func keyDown(with event: NSEvent) {
        if let handler = completionKeyHandler,
           handler.isCompletionActive,
           handler.handleCompletionKeyDown(event) {
            return
        }
        super.keyDown(with: event)
        completionKeyHandler?.textViewDidInsertKey(event)
    }

    /// Clicking in the text dismisses an open completion popup.
    public override func mouseDown(with event: NSEvent) {
        completionKeyHandler?.dismissCompletion()
        super.mouseDown(with: event)
    }

    // MARK: Plain-text paste & drop

    /// Always coerce pasted content to plain text, discarding rich attributes.
    public override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }

    /// Restrict paste *and* drag-and-drop reads to plain strings so rich text
    /// can never enter the storage.
    public override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.string]
    }

    // MARK: Indentation key handling

    public override func insertTab(_ sender: Any?) {
        apply(IndentEngine.tab(
            text: string,
            selection: selectedRange(),
            width: currentWidth,
            usesSpaces: indentSettings.usesSpaces
        ))
    }

    public override func insertBacktab(_ sender: Any?) {
        apply(IndentEngine.shiftTab(
            text: string,
            selection: selectedRange(),
            width: currentWidth,
            usesSpaces: indentSettings.usesSpaces
        ))
    }

    public override func insertNewline(_ sender: Any?) {
        apply(IndentEngine.newline(
            text: string,
            selection: selectedRange(),
            width: currentWidth,
            usesSpaces: indentSettings.usesSpaces
        ))
    }

    // MARK: Applying edits

    private var currentWidth: Int {
        indentSettings.width(for: languageIdentifier)
    }

    /// Applies an `IndentEdit` through the standard input path so the change is
    /// coalesced into the undo stack and fires the usual change notifications.
    private func apply(_ edit: IndentEdit) {
        insertText(edit.replacement, replacementRange: edit.range)
        setSelectedRange(edit.selection)
    }
}
