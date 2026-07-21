import AppKit

/// Cursor-word occurrence highlighter (T12.9) — a lightweight, non-LSP same-word
/// matcher: when the caret rests inside (or just past) an identifier, every
/// other whole-word occurrence *in the current viewport* gets a faint background
/// tint.
///
/// Design (ARCHITECTURE.md §3 "viewport-only / 瞬时不常驻"):
/// - The word lookup and occurrence scan are **pure functions** over the string
///   (`wordRange` / `occurrences`), so they are unit-testable without a live
///   view and hold no state.
/// - The controller only ever scans the **visible character range**, debounced
///   200 ms, and paints `NSLayoutManager` *temporary* `.backgroundColor`
///   attributes — never stored into text storage. The only retained state is the
///   bounded array of ranges last painted (so the next change can clear exactly
///   what it drew), which is capped by the viewport's occurrence count.
/// - It shares the `.backgroundColor` temporary-attribute channel with the
///   bracket matcher / find bar; overlap simply stacks and clearing only ever
///   touches the ranges this object recorded.
@MainActor
public final class WordOccurrenceHighlighter: NSObject, TextStorageObserving {
    private weak var textView: NSTextView?

    /// Ranges last painted, so a selection change / edit can clear precisely
    /// before repainting. Bounded by the viewport occurrence count.
    private var paintedRanges: [NSRange] = []

    /// Pending debounced scan, if any.
    private var pending: DispatchWorkItem?

    /// Debounce interval for the occurrence scan.
    private let debounceInterval: TimeInterval = 0.2

    /// Safety cap: files where a word occurs more than this many times get no
    /// highlight (a degenerate-file guard — see `occurrences`).
    private static let occurrenceCap = 500

    /// Low-saturation background tint, resolved per appearance (mirrors
    /// `HighlightTheme`'s dynamic-colour approach; distinct from the bracket
    /// matcher's blue-grey so the two reads apart when they overlap).
    private static let highlightColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.42, green: 0.45, blue: 0.30, alpha: 0.40)
            : NSColor(srgbRed: 0.62, green: 0.66, blue: 0.28, alpha: 0.28)
    }

    public init(textView: NSTextView) {
        self.textView = textView
        super.init()
    }

    deinit {
        pending?.cancel()
    }

    // MARK: - Pure helpers (unit-testable)

    /// True for identifier characters: ASCII letters, digits, and `_`. Uses the
    /// UTF-16 code-unit value so it matches the NSString / `NSRange` world the
    /// text view lives in.
    nonisolated private static func isWordUnit(_ u: unichar) -> Bool {
        if (u >= 48 && u <= 57)          // 0-9
            || (u >= 65 && u <= 90)      // A-Z
            || (u >= 97 && u <= 122)     // a-z
            || u == 95 {                 // _
            return true
        }
        // Non-ASCII letters (accented / CJK). Surrogate halves have no scalar and
        // are treated as non-word.
        guard let scalar = UnicodeScalar(u) else { return false }
        return scalar.properties.isAlphabetic
    }

    /// The identifier range the caret sits in, in UTF-16 / NSString terms. The
    /// caret counts as "in" a word when it is inside it or immediately past its
    /// last character. Words shorter than 2 units (and a caret in whitespace)
    /// return `nil`.
    nonisolated public static func wordRange(in text: String, at caret: Int) -> NSRange? {
        let ns = text as NSString
        let length = ns.length
        guard length > 0, caret >= 0, caret <= length else { return nil }

        // The caret touches a word if the unit to its right (inside the word) or
        // to its left (a trailing caret) is an identifier character.
        let touchesRight = caret < length && isWordUnit(ns.character(at: caret))
        let touchesLeft = caret > 0 && isWordUnit(ns.character(at: caret - 1))
        guard touchesRight || touchesLeft else { return nil }

        var start = caret
        while start > 0, isWordUnit(ns.character(at: start - 1)) { start -= 1 }
        var end = caret
        while end < length, isWordUnit(ns.character(at: end)) { end += 1 }

        guard end - start >= 2 else { return nil }
        return NSRange(location: start, length: end - start)
    }

    /// Whole-word occurrences of `word` inside `range` of `text` (UTF-16 terms).
    /// "Whole word" means neither neighbour is an identifier character. If the
    /// number of hits exceeds `cap`, returns an empty array (degenerate-file
    /// protection).
    nonisolated public static func occurrences(of word: String, in text: String,
                                               range: NSRange, cap: Int) -> [NSRange] {
        let ns = text as NSString
        let wordNS = word as NSString
        let wordLen = wordNS.length
        guard wordLen >= 2 else { return [] }

        let clamped = NSRange(location: max(0, range.location),
                              length: min(range.length, ns.length - max(0, range.location)))
        guard clamped.length >= wordLen else { return [] }

        var result: [NSRange] = []
        var searchStart = clamped.location
        let searchEnd = clamped.location + clamped.length
        while searchStart < searchEnd {
            let scan = NSRange(location: searchStart, length: searchEnd - searchStart)
            let found = ns.range(of: word, options: [.literal], range: scan)
            guard found.location != NSNotFound else { break }
            let before = found.location - 1
            let after = found.location + found.length
            let boundedLeft = found.location == 0 || !isWordUnit(ns.character(at: before))
            let boundedRight = after >= ns.length || !isWordUnit(ns.character(at: after))
            if boundedLeft && boundedRight {
                result.append(found)
                if result.count > cap { return [] }
            }
            searchStart = found.location + found.length
        }
        return result
    }

    // MARK: - Controller entry points

    /// Called from the owner's `selectionDidChange`. Debounces a viewport scan.
    public func selectionChanged() {
        scheduleScan()
    }

    /// TextStorageObserving: on a character edit the painted ranges are stale, so
    /// clear immediately and reschedule. Attribute-only edits are ignored.
    public func textStorageDidProcessEditing(editedMask: NSTextStorageEditActions,
                                             editedRange: NSRange,
                                             changeInLength delta: Int,
                                             textStorage: NSTextStorage) {
        guard editedMask.contains(.editedCharacters) else { return }
        clearHighlights()
        scheduleScan()
    }

    /// Cancels any pending scan (call from the owner's teardown).
    public func cancel() {
        pending?.cancel()
        pending = nil
    }

    private func scheduleScan() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.scanAndPaint() }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: item)
    }

    /// The current viewport as a character range, or `nil` if geometry is
    /// unavailable. Mirrors `HighlightEngine`'s viewport computation.
    private func visibleCharRange() -> NSRange? {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer,
              let scrollView = textView.enclosingScrollView else { return nil }
        let visibleRect = scrollView.contentView.bounds
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
        return layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
    }

    /// Clears the previous highlight, then — when the caret rests on a single
    /// word — repaints every whole-word occurrence in the viewport.
    private func scanAndPaint() {
        pending = nil
        clearHighlights()
        guard let textView else { return }

        // Only a plain caret (empty selection) triggers the highlight; any active
        // selection (which may span multiple words) just clears.
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return }

        let text = textView.string
        guard let wordRange = Self.wordRange(in: text, at: selection.location) else { return }
        let word = (text as NSString).substring(with: wordRange)

        guard let visible = visibleCharRange(), visible.length > 0 else { return }
        let hits = Self.occurrences(of: word, in: text, range: visible, cap: Self.occurrenceCap)
        guard hits.count > 1 else { return }   // no point highlighting a lone caret word

        guard let layoutManager = textView.layoutManager else { return }
        let color = Self.highlightColor
        for hit in hits {
            layoutManager.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: hit)
        }
        paintedRanges = hits
    }

    /// Removes exactly the ranges this object last painted (never the find bar's
    /// or bracket matcher's own attributes elsewhere).
    private func clearHighlights() {
        guard !paintedRanges.isEmpty, let layoutManager = textView?.layoutManager else {
            paintedRanges = []
            return
        }
        let length = (textView?.string as NSString?)?.length ?? 0
        for range in paintedRanges where range.location + range.length <= length {
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
        }
        paintedRanges = []
    }
}
