import AppKit

/// Cursor-word occurrence highlighter (T12.9) — a lightweight, non-LSP same-word
/// matcher: when the caret rests inside (or just past) an identifier, every
/// other whole-word occurrence *in the current viewport* gets a faint background
/// tint.
///
/// Design (ARCHITECTURE.md §3 "viewport-only / 瞬时不常驻"):
/// - The word lookup and occurrence scan are **pure functions** over the string
///   (`wordRange` / `occurrences`), so they are unit-testable without a live
///   view and hold no state. Word boundaries are judged by whole characters:
///   surrogate pairs are decoded, a combining mark belongs to the character
///   before it, and `$` is a word character only where the language says so
///   (`dollarIsWordCharacter`, set by the editor from the language's
///   `IdentifierPolicy`).
/// - The controller only ever scans the **visible character range** of the
///   text storage's own string (never a copy of the document): debounced
///   200 ms after a selection change or an edit, and 100 ms after the viewport
///   moves while the caret rests in a word. It paints `NSLayoutManager`
///   *temporary* `.backgroundColor` attributes — never stored into text
///   storage. The retained state is the bounded array of ranges last painted
///   (capped by the viewport's occurrence count) plus a few flags.
/// - It shares the `.backgroundColor` temporary-attribute key with the bracket
///   matcher and the find bar. The key does not stack: the last writer wins,
///   and removing it removes whatever colour is there. So every paint and clear
///   is reported through `onBackgroundChanged`, after which the editor re-adds
///   the find bar's search matches on top; and when the find bar wipes the
///   whole document's background, the editor calls `backgroundWasReset()`.
@MainActor
public final class WordOccurrenceHighlighter: NSObject, TextStorageObserving {
    private weak var textView: NSTextView?

    /// Ranges last painted, so a selection change / edit can clear precisely
    /// before repainting. Bounded by the viewport occurrence count.
    private var paintedRanges: [NSRange] = []

    /// True when the last scan found a plain caret inside a word: the only case
    /// in which a viewport change (scroll / resize) triggers a rescan.
    private var caretInWord = false

    /// Pending debounced scan, if any.
    private var pending: DispatchWorkItem?
    private var pendingClear: DispatchWorkItem?
    /// Pending viewport-change rescan (trailing debounce), if any.
    private var pendingViewport: DispatchWorkItem?

    /// Debounce interval for the occurrence scan.
    private let debounceInterval: TimeInterval = 0.2
    /// Trailing debounce for a rescan after the viewport moved.
    private let viewportDebounceInterval: TimeInterval = 0.1

    /// Whether `$` is an identifier character (JS / TS, per the language's
    /// `IdentifierPolicy.dollarIdentifiers`). Changing it rescans.
    public var dollarIsWordCharacter = false {
        didSet {
            if dollarIsWordCharacter != oldValue { scheduleScan() }
        }
    }

    /// Called with the affected ranges after this object painted or cleared its
    /// background tint, so the owner can re-apply backgrounds that must win
    /// (the find bar's search matches) over them.
    public var onBackgroundChanged: (([NSRange]) -> Void)?

    /// Safety cap: files where a word occurs more than this many times get no
    /// highlight (a degenerate-file guard — see `occurrences`).
    private static let occurrenceCap = 500

    /// Low-saturation background tint, resolved per appearance (mirrors
    /// `HighlightTheme`'s dynamic-colour approach; distinct from the bracket
    /// matcher's blue-grey so the two read apart side by side).
    private static let highlightColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.42, green: 0.45, blue: 0.30, alpha: 0.40)
            : NSColor(srgbRed: 0.62, green: 0.66, blue: 0.28, alpha: 0.28)
    }

    public init(textView: NSTextView) {
        self.textView = textView
        super.init()
        // Follow scrolling and resizing (AppKit view notifications: always
        // `.default`), the same pair `HighlightEngine` observes.
        if let clip = textView.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(viewportChanged),
                name: NSView.boundsDidChangeNotification, object: clip)
        }
        textView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(viewportChanged),
            name: NSView.frameDidChangeNotification, object: textView)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        pending?.cancel()
        pendingClear?.cancel()
        pendingViewport?.cancel()
    }

    // MARK: - Pure helpers (unit-testable)

    /// The Unicode scalar starting at UTF-16 offset `i` and its length in
    /// units. A lone surrogate yields `nil` (never a word character).
    nonisolated private static func scalar(in ns: NSString, at i: Int) -> (UnicodeScalar?, Int) {
        let u = ns.character(at: i)
        if UTF16.isLeadSurrogate(u), i + 1 < ns.length {
            let low = ns.character(at: i + 1)
            if UTF16.isTrailSurrogate(low) {
                let value = 0x10000 + ((UInt32(u) - 0xD800) << 10) + (UInt32(low) - 0xDC00)
                return (UnicodeScalar(value), 2)
            }
        }
        return (UnicodeScalar(u), 1)
    }

    /// Offset of the scalar that ends at `i` (`i > 0`): `i - 2` for a
    /// surrogate pair, else `i - 1`.
    nonisolated private static func scalarStart(in ns: NSString, before i: Int) -> Int {
        if i >= 2, UTF16.isTrailSurrogate(ns.character(at: i - 1)),
           UTF16.isLeadSurrogate(ns.character(at: i - 2)) {
            return i - 2
        }
        return i - 1
    }

    /// Combining marks (general category Mn / Mc / Me) attach to the character
    /// before them.
    nonisolated private static func isMark(_ scalar: UnicodeScalar?) -> Bool {
        guard let scalar else { return false }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    /// True for a character that starts or continues an identifier on its own:
    /// ASCII letters, digits, `_`, `$` when `dollar`, and any other alphabetic
    /// scalar (accented / CJK / non-BMP letters). Combining marks are judged
    /// by their base instead (see `isMark`).
    nonisolated private static func isWordBase(_ scalar: UnicodeScalar?, dollar: Bool) -> Bool {
        guard let scalar else { return false }
        let v = scalar.value
        if (v >= 48 && v <= 57)          // 0-9
            || (v >= 65 && v <= 90)      // A-Z
            || (v >= 97 && v <= 122)     // a-z
            || v == 95 {                 // _
            return true
        }
        if v == 36 { return dollar }     // $
        if v < 128 { return false }
        return !isMark(scalar) && scalar.properties.isAlphabetic
    }

    /// Whether the character ending at offset `i` (`i > 0`) is part of a word:
    /// a word base, or a combining mark (run) whose base is one.
    nonisolated private static func wordCharacterEnds(in ns: NSString, at i: Int, dollar: Bool) -> Bool {
        var p = scalarStart(in: ns, before: i)
        while true {
            let (s, _) = scalar(in: ns, at: p)
            if !isMark(s) { return isWordBase(s, dollar: dollar) }
            guard p > 0 else { return false }
            p = scalarStart(in: ns, before: p)
        }
    }

    /// The identifier range the caret sits in, in UTF-16 / NSString terms. The
    /// caret counts as "in" a word when it is inside it or immediately past its
    /// last character. Words shorter than 2 characters (combining marks not
    /// counted) and a caret in whitespace return `nil`.
    nonisolated public static func wordRange(in text: String, at caret: Int,
                                             dollarIsWordCharacter: Bool = false) -> NSRange? {
        wordRange(in: text as NSString, at: caret, dollarIsWordCharacter: dollarIsWordCharacter)
    }

    /// `wordRange(in:at:)` over an `NSString` (the text storage's own string,
    /// so a scan never copies the document).
    nonisolated public static func wordRange(in ns: NSString, at caret: Int,
                                             dollarIsWordCharacter dollar: Bool = false) -> NSRange? {
        let length = ns.length
        guard length > 0, caret >= 0, caret <= length else { return nil }

        // A caret between the halves of a surrogate pair stands before the pair.
        var caret = caret
        if caret > 0, caret < length, UTF16.isTrailSurrogate(ns.character(at: caret)),
           UTF16.isLeadSurrogate(ns.character(at: caret - 1)) {
            caret -= 1
        }

        // Extend left over whole word characters (a base plus its marks).
        var start = caret
        while start > 0 {
            var p = scalarStart(in: ns, before: start)
            while p > 0, isMark(scalar(in: ns, at: p).0) { p = scalarStart(in: ns, before: p) }
            guard isWordBase(scalar(in: ns, at: p).0, dollar: dollar) else { break }
            start = p
        }
        // Extend right: word bases, and marks once inside a word.
        var end = caret
        var characters = 0
        while end < length {
            let (s, len) = scalar(in: ns, at: end)
            if isWordBase(s, dollar: dollar) {
                characters += 1
            } else if !(isMark(s) && end > start) {
                break
            }
            end += len
        }
        guard end > start else { return nil }

        // Count the characters left of the caret, up to the 2 needed.
        var p = start
        while p < caret, characters < 2 {
            let (s, len) = scalar(in: ns, at: p)
            if !isMark(s) { characters += 1 }
            p += len
        }
        guard characters >= 2 else { return nil }
        return NSRange(location: start, length: end - start)
    }

    /// Whole-word occurrences of `word` inside `range` of `text` (UTF-16 terms).
    /// "Whole word" means neither neighbour is part of a word: the character
    /// before is no word character, and the one after is neither a word
    /// character nor a combining mark (which would attach to the match's last
    /// character). If the number of hits exceeds `cap`, returns an empty array
    /// (degenerate-file protection).
    nonisolated public static func occurrences(of word: String, in text: String,
                                               range: NSRange, cap: Int,
                                               dollarIsWordCharacter: Bool = false) -> [NSRange] {
        occurrences(of: word, in: text as NSString, range: range, cap: cap,
                    dollarIsWordCharacter: dollarIsWordCharacter)
    }

    /// `occurrences(of:in:range:cap:)` over an `NSString`.
    nonisolated public static func occurrences(of word: String, in ns: NSString,
                                               range: NSRange, cap: Int,
                                               dollarIsWordCharacter dollar: Bool = false) -> [NSRange] {
        let wordLen = (word as NSString).length
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
            let after = found.location + found.length
            let boundedLeft = found.location == 0
                || !wordCharacterEnds(in: ns, at: found.location, dollar: dollar)
            var boundedRight = true
            if after < ns.length {
                let next = scalar(in: ns, at: after).0
                boundedRight = !isWordBase(next, dollar: dollar) && !isMark(next)
            }
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

    /// Someone else (the find bar) removed the background attribute from the
    /// whole document, this object's tint included. Forgets the painted ranges
    /// without touching attributes and, when the caret rests in a word and no
    /// scan is already on its way, repaints at once (same runloop turn, so
    /// there is no visible gap).
    public func backgroundWasReset() {
        paintedRanges = []
        guard pending == nil, caretInWord else { return }
        scanAndPaint()
    }

    /// TextStorageObserving: on a character edit the painted ranges are stale, so
    /// defer cleanup until storage finishes processing, then reschedule. Attribute-only edits are ignored.
    public func textStorageDidProcessEditing(editedMask: NSTextStorageEditActions,
                                             editedRange: NSRange,
                                             changeInLength delta: Int,
                                             textStorage: NSTextStorage) {
        guard editedMask.contains(.editedCharacters) else { return }
        // Track the ranges as storage shifts them; never mutate layout while
        // it still has the pre-edit glyph mapping.
        let oldEnd = editedRange.location + editedRange.length - delta
        paintedRanges = paintedRanges.map { range in
            let end = NSMaxRange(range)
            if end <= editedRange.location { return range }
            if range.location >= oldEnd {
                return NSRange(location: range.location + delta, length: range.length)
            }
            let start = min(range.location, editedRange.location)
            return NSRange(location: start, length: max(NSMaxRange(editedRange), end + delta) - start)
        }
        pendingClear?.cancel()
        let clear = DispatchWorkItem { [weak self] in
            self?.pendingClear = nil
            self?.clearHighlights()
        }
        pendingClear = clear
        DispatchQueue.main.async(execute: clear)
        scheduleScan()
    }

    /// Cancels any pending work and stops following the viewport (call from
    /// the owner's teardown).
    public func cancel() {
        NotificationCenter.default.removeObserver(self)
        pending?.cancel()
        pending = nil
        pendingClear?.cancel()
        pendingClear = nil
        pendingViewport?.cancel()
        pendingViewport = nil
    }

    private func scheduleScan() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.scanAndPaint() }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: item)
    }

    /// Scroll / resize: when the caret rests in a word, rescan the new
    /// viewport after a short trailing debounce. A scan already scheduled by a
    /// selection change or an edit covers it.
    @objc private func viewportChanged() {
        guard caretInWord, pending == nil else { return }
        pendingViewport?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.scanAndPaint() }
        pendingViewport = item
        DispatchQueue.main.asyncAfter(deadline: .now() + viewportDebounceInterval, execute: item)
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
    /// word — repaints its whole-word occurrences in the viewport.
    private func scanAndPaint() {
        pending?.cancel()
        pending = nil
        pendingViewport?.cancel()
        pendingViewport = nil
        clearHighlights()
        caretInWord = false
        guard let textView, let storage = textView.textStorage else { return }

        // Only a plain caret (empty selection) triggers the highlight; any active
        // selection (which may span multiple words) just clears.
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return }

        let ns = storage.mutableString
        guard let wordRange = Self.wordRange(in: ns, at: selection.location,
                                             dollarIsWordCharacter: dollarIsWordCharacter) else { return }
        caretInWord = true
        let word = ns.substring(with: wordRange)

        guard let visible = visibleCharRange(), visible.length > 0 else { return }
        let hits = Self.occurrences(of: word, in: ns, range: visible, cap: Self.occurrenceCap,
                                    dollarIsWordCharacter: dollarIsWordCharacter)
        // A lone hit is worth a tint only when it is not the caret's own word
        // (the caret's occurrence is scrolled out of the viewport).
        guard hits.count > 1 || (hits.count == 1 && hits[0] != wordRange) else { return }

        guard let layoutManager = textView.layoutManager else { return }
        let color = Self.highlightColor
        for hit in hits {
            layoutManager.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: hit)
        }
        paintedRanges = hits
        onBackgroundChanged?(hits)
    }

    /// Removes the background attribute from exactly the ranges this object
    /// last painted, then reports them so the owner can restore what must win
    /// there (the find bar's matches).
    private func clearHighlights() {
        let cleared = paintedRanges
        paintedRanges = []
        guard !cleared.isEmpty, let textView, let layoutManager = textView.layoutManager else { return }
        let length = textView.textStorage?.length ?? 0
        let valid = cleared.filter { NSMaxRange($0) <= length }
        for range in valid {
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
        }
        if !valid.isEmpty { onBackgroundChanged?(valid) }
    }
}
