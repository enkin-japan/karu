import AppKit

/// One compiled data detector, reused by every scan (mirrors
/// `HighlightEngine.identifierRegex`). A file-scope constant rather than a
/// static member: the pure entry points below are `nonisolated`, while a static
/// property of a `@MainActor` type would inherit that isolation.
// swiftlint:disable:next force_try
private let sharedLinkDetector = try! NSDataDetector(
    types: NSTextCheckingResult.CheckingType.link.rawValue)

/// URL recognition with ⌘-click opening (T15.6), shared by the editor windows
/// and the scratchpad.
///
/// Design, in the same shape as `WordOccurrenceHighlighter` / `HighlightEngine`:
/// - The scan and the scheme filter are **pure static functions** over a string
///   (`detect(in:)` / `url(forLinkText:)`), so they are unit-testable without a
///   live view and hold nothing.
/// - Detection is **debounced** (0.3 s after the last edit) and skipped outright
///   for documents above `maxScanLength`, so a huge log file never pays for a
///   full-text `NSDataDetector` pass on every keystroke.
/// - The underline is painted with `NSLayoutManager` **temporary attributes**:
///   nothing is ever written into the text storage, so links cost no undo
///   entries, survive no save, and the file on disk stays the plain character
///   stream the user typed ("draw it, don't store it").
/// - It takes the `.underlineStyle` / `.underlineColor` temporary-attribute
///   channel and *only* that. `.foregroundColor` belongs exclusively to
///   `HighlightEngine` (which clears the whole attribute across the document on
///   a module toggle) and `.backgroundColor` to the find bar / bracket matcher —
///   writing either here would mean the two layers erasing each other. The
///   underline is drawn in the system link colour instead, which reads as a link
///   without fighting the syntax colours underneath.
///
/// The only retained state is the array of link ranges last painted — bounded by
/// `maxLinks` and by the 1 MB scan cap, and cleared on every edit.
@MainActor
public final class LinkDetector: NSObject, TextStorageObserving {
    private weak var textView: NSTextView?

    /// Ranges last detected *and* painted; the ⌘-click hit test reads them.
    private var links: [NSRange] = []

    /// Tool-tip regions registered on the text view — one per enclosing rect of
    /// each *visible* link, so hovering a link says "⌘-click to open" (T15.8,
    /// user request: the modifier is otherwise undiscoverable). Tracked by tag
    /// so removal never touches a tip someone else registered.
    private var toolTipTags: [NSView.ToolTipTag] = []

    /// Pending coalesced tool-tip refresh, if any.
    private var toolTipRefresh: DispatchWorkItem?

    /// Pending debounced scan, if any.
    private var pending: DispatchWorkItem?

    /// Pending coalesced decoration clear, if any (see
    /// `textStorageDidProcessEditing` for why clearing must be deferred).
    private var decorationClear: DispatchWorkItem?

    /// Diagnostics for the KARU_LINKTEST hook: what the last scan produced.
    public var diagnosticCounts: (links: Int, toolTipRegions: Int) {
        (links.count, toolTipTags.count)
    }

    /// Delay between the last edit and the rescan. Long enough that a burst of
    /// typing scans once, short enough that a pasted URL underlines itself
    /// before the user reaches for ⌘.
    private let debounceInterval: TimeInterval = 0.3

    /// Documents longer than this (UTF-16 units, ~1 MB) are not scanned at all.
    /// Link detection is a convenience; it must never become the reason a large
    /// file feels slow.
    nonisolated public static let maxScanLength = 1_000_000

    /// Degenerate-file guard: a document that somehow contains more links than
    /// this gets none, rather than a five-figure array of ranges.
    nonisolated public static let maxLinks = 2_000

    /// The only schemes Karu will hand to the workspace. A ⌘-click must never
    /// be able to launch `file:`, `ftp:` or a custom app scheme picked up from
    /// text the user merely pasted.
    nonisolated public static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    public init(textView: NSTextView) {
        self.textView = textView
        super.init()
        // Re-place the tool-tip rects when the geometry changes: a width change
        // re-wraps the text (frame notification, already on — the gutter needs
        // it), and a scroll brings different links into view (bounds
        // notification on the clip view). Both handlers only *schedule* — see
        // `scheduleToolTipRefresh` for why they must never work synchronously.
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(viewGeometryDidChange(_:)),
                                               name: NSView.frameDidChangeNotification,
                                               object: textView)
        if let clipView = textView.enclosingScrollView?.contentView {
            clipView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self,
                                                   selector: #selector(viewGeometryDidChange(_:)),
                                                   name: NSView.boundsDidChangeNotification,
                                                   object: clipView)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        pending?.cancel()
        toolTipRefresh?.cancel()
        decorationClear?.cancel()
    }

    // MARK: - Pure helpers (unit-testable)

    /// Every http / https / mailto link in `text`, as UTF-16 ranges. Returns an
    /// empty array for a document above `limit` or with more than `maxLinks`
    /// hits — both "no decoration" rather than "slow decoration".
    nonisolated public static func detect(in text: String,
                                          limit: Int = LinkDetector.maxScanLength) -> [NSRange] {
        let ns = text as NSString
        guard ns.length > 0, ns.length <= limit else { return [] }

        var ranges: [NSRange] = []
        var overflowed = false
        sharedLinkDetector.enumerateMatches(in: text,
                                            range: NSRange(location: 0, length: ns.length)) { match, _, stop in
            guard let match, let url = match.url, isAllowed(url) else { return }
            ranges.append(match.range)
            if ranges.count > maxLinks {
                overflowed = true
                stop.pointee = true
            }
        }
        return overflowed ? [] : ranges
    }

    /// The URL a detected fragment stands for, re-derived from the text itself
    /// (so nothing but the ranges has to be kept resident). The whole fragment
    /// must be the link, and its scheme must be one of `allowedSchemes` — a bare
    /// `user@host` correctly yields `mailto:user@host`.
    nonisolated public static func url(forLinkText text: String) -> URL? {
        let ns = text as NSString
        guard ns.length > 0 else { return nil }
        guard let match = sharedLinkDetector.firstMatch(in: text,
                                                       range: NSRange(location: 0, length: ns.length)),
              match.range.location == 0, match.range.length == ns.length,
              let url = match.url, isAllowed(url) else { return nil }
        return url
    }

    nonisolated private static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return allowedSchemes.contains(scheme)
    }

    // MARK: - Entry points

    /// Schedules a scan. Called after the panel / window is built with text
    /// already in place (where no edit notification will ever arrive).
    public func scan() {
        scheduleScan()
    }

    /// Cancels any pending scan and tool-tip refresh (owner's teardown).
    public func cancel() {
        pending?.cancel()
        pending = nil
        toolTipRefresh?.cancel()
        toolTipRefresh = nil
        decorationClear?.cancel()
        decorationClear = nil
    }

    /// TextStorageObserving: a character edit shifts every range after it, so
    /// the painted decoration is dropped and recomputed on the debounce.
    /// Attribute-only edits change no text and are ignored.
    ///
    /// The drop is deferred to the next run-loop turn, never done here: this
    /// observer runs inside `processEditing`, *before* the layout manager has
    /// been told about the edit, so the storage holds the new text while the
    /// layout manager still maps glyphs against the old one. Removing a
    /// temporary attribute in that window makes the display-invalidation path
    /// resolve paragraph bounds through the stale mapping and throw
    /// `NSRangeException` — an in-bounds range check on our side cannot
    /// prevent it (deterministic crash: backspace right after links painted).
    public func textStorageDidProcessEditing(editedMask: NSTextStorageEditActions,
                                             editedRange: NSRange,
                                             changeInLength delta: Int,
                                             textStorage: NSTextStorage) {
        guard editedMask.contains(.editedCharacters) else { return }
        scheduleDecorationClear()
        scheduleScan()
    }

    /// The URL under `point` (in the text view's coordinates), or `nil` when the
    /// click did not land on a link's glyphs. Used by the ⌘-click handlers; a
    /// point past the end of a line maps to the nearest character, so the hit is
    /// confirmed against the link's actual enclosing rects before it counts.
    public func url(atPoint point: NSPoint) -> URL? {
        guard !links.isEmpty,
              let textView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return nil }

        let origin = textView.textContainerOrigin
        let inContainer = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(for: inContainer, in: container,
                                             fractionOfDistanceThroughGlyph: &fraction)
        let index = layoutManager.characterIndexForGlyph(at: glyph)

        let ns = textView.string as NSString
        guard let hit = links.first(where: { NSLocationInRange(index, $0) }),
              hit.location + hit.length <= ns.length else { return nil }

        let glyphRange = layoutManager.glyphRange(forCharacterRange: hit, actualCharacterRange: nil)
        var onGlyphs = false
        layoutManager.enumerateEnclosingRects(
            forGlyphRange: glyphRange,
            withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
            in: container
        ) { rect, stop in
            if rect.offsetBy(dx: origin.x, dy: origin.y).contains(point) {
                onGlyphs = true
                stop.pointee = true
            }
        }
        guard onGlyphs else { return nil }
        return Self.url(forLinkText: ns.substring(with: hit))
    }

    // MARK: - Scanning / painting

    private func scheduleScan() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.scanAndPaint() }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: item)
    }

    /// Coalesces the post-edit decoration drop onto the next run-loop turn,
    /// where storage and layout manager agree again. Runs before the debounced
    /// rescan by construction (async now vs. +0.3 s).
    private func scheduleDecorationClear() {
        guard decorationClear == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.decorationClear = nil
            self.clearDecoration()
        }
        decorationClear = item
        DispatchQueue.main.async(execute: item)
    }

    private func scanAndPaint() {
        pending = nil
        clearDecoration()
        guard let textView, let layoutManager = textView.layoutManager else { return }

        let ranges = Self.detect(in: textView.string)
        guard !ranges.isEmpty else { return }
        for range in ranges {
            layoutManager.addTemporaryAttribute(.underlineStyle,
                                                value: NSUnderlineStyle.single.rawValue,
                                                forCharacterRange: range)
            layoutManager.addTemporaryAttribute(.underlineColor,
                                                value: NSColor.linkColor,
                                                forCharacterRange: range)
        }
        links = ranges
        scheduleToolTipRefresh()
    }

    // MARK: - Hover tool tips

    /// Coalesces a tool-tip refresh onto the *next* run-loop turn.
    ///
    /// This deferral is load-bearing, not a nicety (T15.10 crash): the
    /// frame-change notification arrives **synchronously inside a layout pass**
    /// (`_resizeTextViewForTextContainer` → `setFrameSize`), and the refresh
    /// asks the layout manager for glyph rects, which forces more layout, which
    /// grows the text view again, which posts the notification again —
    /// re-entrant recursion until the stack overflows, deterministically, on any
    /// link-bearing file still holding layout holes when the scan lands. Working
    /// only from a fresh dispatch breaks the cycle by construction.
    private func scheduleToolTipRefresh() {
        guard toolTipRefresh == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.toolTipRefresh = nil
            self.refreshToolTips()
        }
        toolTipRefresh = item
        DispatchQueue.main.async(execute: item)
    }

    /// Registers one tool-tip region per enclosing rect of every **visible**
    /// link (wrapped links get one region per fragment). Restricting to the
    /// viewport keeps this from forcing layout of the whole document — the
    /// visible range is laid out already, so asking for its rects is free; a
    /// scroll or resize simply schedules another pass for the new viewport.
    private func refreshToolTips() {
        removeToolTips()
        guard !links.isEmpty,
              let textView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }

        let origin = textView.textContainerOrigin
        let visible = textView.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        guard !visible.isEmpty else { return }
        let visibleGlyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let visibleChars = layoutManager.characterRange(forGlyphRange: visibleGlyphs,
                                                        actualGlyphRange: nil)

        for range in links where NSIntersectionRange(range, visibleChars).length > 0 {
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(
                forGlyphRange: glyphRange,
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: container
            ) { rect, _ in
                let tag = textView.addToolTip(rect.offsetBy(dx: origin.x, dy: origin.y),
                                              owner: self, userData: nil)
                self.toolTipTags.append(tag)
            }
        }
    }

    private func removeToolTips() {
        guard let textView else { toolTipTags = []; return }
        for tag in toolTipTags { textView.removeToolTip(tag) }
        toolTipTags = []
    }

    /// A resize re-wraps without an edit and a scroll changes which links are
    /// on screen; either way the regions are re-registered — next turn, never
    /// from inside the notification (see `scheduleToolTipRefresh`).
    @objc private func viewGeometryDidChange(_ notification: Notification) {
        guard !links.isEmpty else { return }
        scheduleToolTipRefresh()
    }

    /// Informal `NSToolTipOwner` method — every registered region shows the same
    /// hint: the modifier is the discoverable part, not the URL (which is right
    /// there in the text).
    @objc public func view(_ view: NSView,
                           stringForToolTip tag: NSView.ToolTipTag,
                           point: NSPoint,
                           userData data: UnsafeMutableRawPointer?) -> String {
        L10n.t(.linkOpenTooltip)
    }

    /// Removes exactly what this object painted, never a whole-document sweep:
    /// the underline channel is ours, but the ranges we hold may already be
    /// stale after an edit, so anything reaching past the end is skipped.
    private func clearDecoration() {
        removeToolTips()
        defer { links = [] }
        guard !links.isEmpty, let layoutManager = textView?.layoutManager else { return }
        let length = (textView?.string as NSString?)?.length ?? 0
        for range in links where range.location + range.length <= length {
            layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: range)
            layoutManager.removeTemporaryAttribute(.underlineColor, forCharacterRange: range)
        }
    }
}
