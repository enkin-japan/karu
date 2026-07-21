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

    /// Indent unit inferred from the document's actual content by
    /// `IndentDetector`, or `nil` when detection was inconclusive. Set by
    /// `EditorWindowController` on open / language change (never per keystroke).
    /// Takes precedence over the language default but yields to an explicit
    /// UserDefaults width override.
    public var detectedIndentUnit: Int? {
        didSet {
            guard oldValue != detectedIndentUnit else { return }
            needsDisplay = true
        }
    }

    /// Indent width to use for rainbow drawing and the Tab key, honouring the
    /// VS Code-style precedence: explicit UserDefaults override →
    /// content-detected unit → built-in language default.
    public var effectiveIndentWidth: Int {
        if !indentSettings.hasExplicitWidth(for: languageIdentifier),
           let detected = detectedIndentUnit {
            return detected
        }
        return indentSettings.width(for: languageIdentifier)
    }

    /// Optional completion popup hook. Held weakly and consulted only in
    /// `keyDown` / `mouseDown`; when unset (or inactive) it adds no per-keystroke
    /// cost beyond a nil / bool check.
    public weak var completionKeyHandler: CompletionKeyHandler?

    /// Folding layer queried while drawing the collapsed-block background
    /// highlight. Weak: owned by the window controller. When `nil` the editor
    /// draws no fold decorations. Nothing is stored per line — the folded header
    /// set is re-queried each draw (it is tiny), keeping to the "painted, not
    /// resident" rule.
    public weak var foldProvider: FoldStatusProviding?

    /// Shared newline index, used only to map a folded header's 1-based line
    /// number to its character offset so the background bar can be placed.
    /// Weak: owned by the window controller / gutter.
    public weak var lineIndex: LineIndex?

    /// Whether indent-rainbow blocks are drawn. Defaults from UserDefaults key
    /// `editor.indentRainbow` (on when unset). Toggling triggers a redraw.
    public var indentRainbowEnabled: Bool = IndentRainbow.defaultEnabled {
        didSet {
            guard oldValue != indentRainbowEnabled else { return }
            needsDisplay = true
        }
    }

    /// Whether auto-closing brackets / quotes and selection-wrapping are active.
    /// Defaults from UserDefaults key `editor.autoClosePairs` (on when unset).
    /// Pure state flag — no redraw needed, it only gates the input overrides.
    public var autoClosePairsEnabled: Bool = AutoClosePairs.defaultEnabled

    // MARK: Indent rainbow drawing

    /// Draws indent-rainbow blocks behind the visible text. Viewport-only: only
    /// the lines intersecting `rect` are recomputed and painted (nothing is
    /// stored per line).
    public override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        // Fold highlights draw independently of the indent rainbow toggle.
        drawFoldedHeaders(in: rect)
        guard indentRainbowEnabled,
              let layoutManager,
              let container = textContainer else { return }

        let ns = string as NSString
        guard ns.length > 0 else { return }

        let width = effectiveIndentWidth
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

            // VS Code-style indent dots: a small dot at the centre of each
            // leading space so the number of spaces is countable at a glance.
            // Tabs get none. Painted live over the rainbow fill for visible
            // lines only — nothing is stored per line.
            let spaceColumns = IndentRainbow.leadingSpaceColumns(forLine: lineString)
            if !spaceColumns.isEmpty {
                let diameter = IndentRainbow.dotDiameter
                IndentRainbow.dotColor().setFill()
                for column in spaceColumns {
                    let charRange = NSRange(location: loc + column, length: 1)
                    let gRange = layoutManager.glyphRange(forCharacterRange: charRange,
                                                          actualCharacterRange: nil)
                    var charRect = layoutManager.boundingRect(forGlyphRange: gRange, in: container)
                    charRect.origin.x += origin.x
                    charRect.origin.y += origin.y
                    let dotRect = NSRect(x: charRect.midX - diameter / 2,
                                         y: charRect.midY - diameter / 2,
                                         width: diameter, height: diameter)
                    NSBezierPath(ovalIn: dotRect).fill()
                }
            }

            let next = lineRange.location + lineRange.length
            if next <= loc { break } // guard against zero-length final line
            loc = next
        }
    }

    /// Paints a faint accent-coloured bar across every currently-folded header
    /// line intersecting `rect`, with a trailing "⋯ N" indicator (N = hidden
    /// line count) just past the end of the header text. Viewport-only and
    /// storage-free: the (tiny) folded-header set is re-queried each draw and
    /// each bar is positioned from the shared `LineIndex` + layout manager;
    /// nothing is retained. Same safe path as the indent rainbow — this is the
    /// text view's own `drawBackground`, never a sibling view's `draw` override.
    private func drawFoldedHeaders(in rect: NSRect) {
        guard let provider = foldProvider,
              let lineIndex,
              let layoutManager,
              textContainer != nil else { return }
        let headers = provider.foldedHeaderLines()
        guard !headers.isEmpty else { return }

        let ns = string as NSString
        guard ns.length > 0 else { return }
        let origin = textContainerOrigin
        let barColor = NSColor.controlAccentColor.withAlphaComponent(0.08)
        let hintAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        for header in headers where header >= 1 && header <= lineIndex.lineCount {
            let lineStart = lineIndex.offsetRange(ofLine: header).lowerBound
            // A folded header always has hidden lines below it, so it is never
            // the final empty line; still guard defensively.
            guard lineStart < ns.length else { continue }

            let glyphIndex = layoutManager.glyphIndexForCharacter(at: lineStart)
            let fragRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            var barRect = fragRect
            barRect.origin.x = origin.x
            barRect.origin.y += origin.y
            guard barRect.intersects(rect) else { continue }

            // Full-width bar.
            barRect.origin.x = bounds.minX
            barRect.size.width = bounds.width
            barColor.setFill()
            barRect.fill()

            // "⋯ N" hint just past the header text.
            let hidden = provider.hiddenLineCount(forHeader: header)
            let usedRect = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            let hint = "\u{22EF} \(hidden)" as NSString  // ⋯
            let hintSize = hint.size(withAttributes: hintAttrs)
            let hintX = usedRect.maxX + origin.x + 12
            let hintY = fragRect.midY + origin.y - hintSize.height / 2
            hint.draw(at: NSPoint(x: hintX, y: hintY), withAttributes: hintAttrs)
        }
    }

    // MARK: Format Document chord

    /// Pure predicate for the Format Document chord (⌥⇧F). Factored out so it
    /// can be unit-tested without a live event.
    ///
    /// AppKit's menu matching for Option-bearing key equivalents is unreliable
    /// (the event's `characters` are already remapped by Option, e.g. "Ï"), so
    /// the chord can slip past the menu and land in `keyDown` as literal text.
    /// We match on `charactersIgnoringModifiers`, which still reflects Shift —
    /// hence the `lowercased()` comparison against "f".
    static func isFormatDocumentChord(
        modifiers: NSEvent.ModifierFlags,
        charactersIgnoringModifiers: String?
    ) -> Bool {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.option), flags.contains(.shift),
              !flags.contains(.command), !flags.contains(.control) else {
            return false
        }
        return charactersIgnoringModifiers?.lowercased() == "f"
    }

    // MARK: Line-operation chords

    /// Pure predicate mapping an Option-bearing arrow chord to the matching line
    /// operation, or `nil` when it is not one. Like the Format Document chord,
    /// Option-without-Command equivalents are unreliable through AppKit's menu
    /// matching (T12.1), so these are intercepted in `keyDown` instead — the menu
    /// items exist only for discoverability.
    ///
    /// `⌥↑` / `⌥↓` move lines; `⌥⇧↑` / `⌥⇧↓` copy lines. Any chord carrying
    /// Command or Control returns `nil` (⌘⇧K, Delete Line, is a reliable menu
    /// equivalent and needs no interception). Arrow keys arrive with the
    /// function-key scalars U+F700 (up) / U+F701 (down) in
    /// `charactersIgnoringModifiers`.
    static func lineOperationChord(
        modifiers: NSEvent.ModifierFlags,
        charactersIgnoringModifiers chars: String?
    ) -> Selector? {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.option),
              !flags.contains(.command), !flags.contains(.control) else {
            return nil
        }
        guard let scalar = chars?.unicodeScalars.first else { return nil }
        let shift = flags.contains(.shift)
        switch scalar {
        case UnicodeScalar(NSUpArrowFunctionKey)!:
            return shift ? #selector(EditorWindowController.copyLinesUp(_:))
                         : #selector(EditorWindowController.moveLinesUp(_:))
        case UnicodeScalar(NSDownArrowFunctionKey)!:
            return shift ? #selector(EditorWindowController.copyLinesDown(_:))
                         : #selector(EditorWindowController.moveLinesDown(_:))
        default:
            return nil
        }
    }

    // MARK: Completion key routing

    /// Give an active completion popup first refusal on navigation keys, then
    /// let the normal input path run and notify the popup of the keystroke so it
    /// can open / refilter / dismiss. Zero overhead when no handler is attached.
    public override func keyDown(with event: NSEvent) {
        // Intercept ⌥⇧F before it can be inserted as a literal "Ï": route it to
        // the Format Document action (which self-gates on module/language).
        if Self.isFormatDocumentChord(modifiers: event.modifierFlags,
                                      charactersIgnoringModifiers: event.charactersIgnoringModifiers) {
            NSApp.sendAction(#selector(EditorWindowController.formatDocument(_:)), to: nil, from: self)
            return
        }
        if let handler = completionKeyHandler,
           handler.isCompletionActive,
           handler.handleCompletionKeyDown(event) {
            return
        }
        // Line-operation chords (⌥↑ / ⌥↓ / ⌥⇧↑ / ⌥⇧↓). Skipped while a completion
        // popup is open so the keystroke dismisses the popup (via super.keyDown)
        // rather than moving lines underneath it.
        if completionKeyHandler?.isCompletionActive != true,
           let selector = Self.lineOperationChord(
               modifiers: event.modifierFlags,
               charactersIgnoringModifiers: event.charactersIgnoringModifiers) {
            NSApp.sendAction(selector, to: nil, from: self)
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

    // MARK: Auto-close pairs (T12.6)

    /// Intercepts single-character insertion to auto-close brackets / quotes,
    /// wrap a selection, or step over an existing closer.
    ///
    /// Guards first (falling straight through to `super`) when: auto-close is
    /// off, an input method is mid-composition (`hasMarkedText()` — CJK input
    /// must never be disturbed), the payload is not exactly one character, or the
    /// character is not one we pair. Every mutation goes through the undo-aware
    /// `shouldChangeText` → `replaceCharacters` → `didChangeText` channel so the
    /// change coalesces into the undo stack and fires the usual notifications.
    public override func insertText(_ string: Any, replacementRange: NSRange) {
        // Extract the committed plain string from either payload form.
        let typed: String
        if let s = string as? String {
            typed = s
        } else if let attributed = string as? NSAttributedString {
            typed = attributed.string
        } else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }

        guard autoClosePairsEnabled, !hasMarkedText(), typed.count == 1 else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }

        // The range this insertion targets: an explicit replacement range if the
        // caller gave one, otherwise the current selection.
        let ns = self.string as NSString
        let target = (replacementRange.location != NSNotFound) ? replacementRange : selectedRange()
        let hasSelection = target.length > 0
        let before = character(at: target.location - 1, in: ns)
        let after = character(at: target.location + target.length, in: ns)

        let decision = AutoClosePairs.decide(typed: typed,
                                             charBefore: before,
                                             charAfter: after,
                                             hasSelection: hasSelection)
        switch decision {
        case .passthrough:
            super.insertText(string, replacementRange: replacementRange)

        case .insertPair(let text, let caretOffset):
            guard shouldChangeText(in: target, replacementString: text) else { return }
            textStorage?.replaceCharacters(in: target, with: text)
            didChangeText()
            setSelectedRange(NSRange(location: target.location + caretOffset, length: 0))

        case .wrap(let prefix, let suffix):
            let selected = ns.substring(with: target)
            let replacement = prefix + selected + suffix
            guard shouldChangeText(in: target, replacementString: replacement) else { return }
            textStorage?.replaceCharacters(in: target, with: replacement)
            didChangeText()
            // Keep the original text selected, now sitting inside the delimiters.
            let inner = NSRange(location: target.location + (prefix as NSString).length,
                                length: (selected as NSString).length)
            setSelectedRange(inner)

        case .stepOver:
            // The closer is already there — just advance the caret past it.
            setSelectedRange(NSRange(location: target.location + 1, length: 0))
        }
    }

    /// Deletes both halves of an empty auto-inserted pair when backspacing with
    /// the caret between them (e.g. `(|)` → `|`). Guards identically to
    /// `insertText` (off / composing / non-caret selection) before consulting the
    /// pure `AutoClosePairs.shouldDeletePair` predicate.
    public override func deleteBackward(_ sender: Any?) {
        guard autoClosePairsEnabled, !hasMarkedText() else {
            super.deleteBackward(sender)
            return
        }
        let selection = selectedRange()
        guard selection.length == 0, selection.location > 0 else {
            super.deleteBackward(sender)
            return
        }
        let ns = self.string as NSString
        let before = character(at: selection.location - 1, in: ns)
        let after = character(at: selection.location, in: ns)
        guard AutoClosePairs.shouldDeletePair(charBefore: before, charAfter: after) else {
            super.deleteBackward(sender)
            return
        }
        let pairRange = NSRange(location: selection.location - 1, length: 2)
        guard shouldChangeText(in: pairRange, replacementString: "") else { return }
        textStorage?.replaceCharacters(in: pairRange, with: "")
        didChangeText()
        setSelectedRange(NSRange(location: pairRange.location, length: 0))
    }

    /// The `Character` at UTF-16 `index`, or `nil` when out of bounds. Used only
    /// to compare against ASCII brackets / quotes, so a lone surrogate half
    /// (decoded to U+FFFD) simply never matches.
    private func character(at index: Int, in ns: NSString) -> Character? {
        guard index >= 0, index < ns.length else { return nil }
        return Character(ns.substring(with: NSRange(location: index, length: 1)))
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
        effectiveIndentWidth
    }

    /// Applies an `IndentEdit` through the standard input path so the change is
    /// coalesced into the undo stack and fires the usual change notifications.
    private func apply(_ edit: IndentEdit) {
        insertText(edit.replacement, replacementRange: edit.range)
        setSelectedRange(edit.selection)
    }
}
