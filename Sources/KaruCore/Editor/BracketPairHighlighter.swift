import AppKit

/// Matched-bracket background tint: when a plain caret sits beside a balanced
/// bracket, the bracket and its match get a faint background.
///
/// Design (ARCHITECTURE.md §3 "viewport-only / 瞬时不常驻"):
/// - The match itself is a transient scan (`BracketMatcher.findMatch`). The
///   retained state is fixed-size: at most the two one-character ranges last
///   painted, plus two flags. It exists only so the next `update()` can
///   clear exactly what was drawn before recomputing.
/// - The tint is an `NSLayoutManager` *temporary* `.backgroundColor`
///   attribute — never stored into text storage. On an edit the layout
///   manager moves temporary attributes with the text after the edit and
///   drops them over the whole reported edited range (inserted or replacing
///   characters arrive without one; inside a batched edit's union even
///   untouched characters lose theirs). The painted ranges follow the same
///   rule in `textStorageWillProcessEditing`: an end after the edit shifts,
///   an end inside the edited range is dropped from the record, since its
///   tint is gone with it.
/// - It shares the `.backgroundColor` key with the find bar and the same-word
///   tint. The key does not stack: the last writer wins, and removing it
///   removes whatever colour is there. Priority is search match > bracket
///   pair > word tint, so every paint and clear is reported through
///   `onBackgroundChanged` (the owner re-applies the find bar's matches on
///   top); when the word tint paints or clears, the owner calls
///   `restore(intersecting:)` and then re-applies the find bar; and when the
///   find bar wipes the whole document's background, the owner calls
///   `backgroundWasReset()`.
@MainActor
final class BracketPairHighlighter: TextStorageObserving {
    private weak var textView: NSTextView?

    /// The one-character ranges last painted (opener and closer), at most two.
    /// Either end can be dropped on its own when an edit touches it.
    private var painted: [NSRange] = []

    /// Set by a character edit, cleared by `update()`: the pair must be
    /// recomputed even if the caret does not move.
    private var needsRefresh = false

    /// Coalesced fallback refresh for edits that never post `textDidChange`
    /// (programmatic storage edits).
    private var pendingRefresh: DispatchWorkItem?

    /// Called with the ranges whose background this object just painted or
    /// removed, so the owner can re-apply backgrounds that must win (the find
    /// bar's search matches) over them.
    var onBackgroundChanged: (([NSRange]) -> Void)?

    /// Low-saturation background tint for the matched bracket pair, resolved
    /// per appearance (mirrors `HighlightTheme`'s dynamic-colour approach).
    private static let color = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.55, green: 0.58, blue: 0.66, alpha: 0.42)
            : NSColor(srgbRed: 0.36, green: 0.42, blue: 0.52, alpha: 0.26)
    }

    init(textView: NSTextView) {
        self.textView = textView
    }

    deinit {
        pendingRefresh?.cancel()
    }

    /// Recomputes the pair for the current caret. Clears the recorded ranges
    /// (the removal takes any colour there, so they are reported for the
    /// find bar's matches to be re-applied), then, for a plain caret beside a
    /// balanced bracket, tints both ends and reports them too.
    func update() {
        needsRefresh = false
        pendingRefresh?.cancel()
        pendingRefresh = nil
        guard let textView, let layoutManager = textView.layoutManager else { return }

        if !painted.isEmpty {
            let length = textView.textStorage?.length ?? 0
            let cleared = painted.filter { NSMaxRange($0) <= length }
            painted = []
            for range in cleared {
                layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
            }
            if !cleared.isEmpty { onBackgroundChanged?(cleared) }
        }

        // Only highlight for a plain caret (no active selection).
        let selection = textView.selectedRange()
        guard selection.length == 0,
              let match = BracketMatcher.findMatch(text: textView.string, caret: selection.location) else {
            return
        }
        let ranges = [match.open, match.close]
        for range in ranges {
            layoutManager.addTemporaryAttribute(.backgroundColor, value: Self.color, forCharacterRange: range)
        }
        painted = ranges
        onBackgroundChanged?(ranges)
    }

    /// Someone else (the find bar) removed the background attribute from the
    /// whole document, the pair's tint included. Forgets the recorded ranges
    /// without touching attributes, then repaints.
    func backgroundWasReset() {
        painted = []
        update()
    }

    /// Someone else (the word tint) painted or cleared `ranges`: re-adds the
    /// pair colour on each recorded end that intersects any of them. Does not
    /// report; the owner re-applies the find bar's matches afterwards.
    func restore(intersecting ranges: [NSRange]) {
        guard !painted.isEmpty, let textView, let layoutManager = textView.layoutManager else { return }
        let length = textView.textStorage?.length ?? 0
        for end in painted where NSMaxRange(end) <= length {
            if ranges.contains(where: { NSIntersectionRange($0, end).length > 0 }) {
                layoutManager.addTemporaryAttribute(.backgroundColor, value: Self.color, forCharacterRange: end)
            }
        }
    }

    /// Runs `update()` if a character edit happened since the last one. Called
    /// from the owner's `textDidChange`, which covers edits that do not move
    /// the caret (a forward delete of the closer).
    func refreshIfNeeded() {
        guard needsRefresh else { return }
        update()
    }

    /// Cancels the pending fallback refresh (call from the owner's teardown).
    func cancel() {
        pendingRefresh?.cancel()
        pendingRefresh = nil
    }

    // MARK: - TextStorageObserving

    /// Shifts the recorded ends with the exact edited range: an end before
    /// the edit stays, one at or after its old end shifts by `delta` (so an
    /// insertion exactly at an end's start shifts it), and one the edit
    /// covered is dropped. Only recorded ranges change here: the layout
    /// manager still has the pre-edit glyph mapping.
    func textStorageWillProcessEditing(editedMask: NSTextStorageEditActions,
                                       editedRange: NSRange,
                                       changeInLength delta: Int,
                                       textStorage: NSTextStorage) {
        guard editedMask.contains(.editedCharacters) else { return }
        let oldEnd = editedRange.location + editedRange.length - delta
        painted = painted.compactMap { range in
            if NSMaxRange(range) <= editedRange.location { return range }
            if range.location >= oldEnd {
                return NSRange(location: range.location + delta, length: range.length)
            }
            return nil
        }
        needsRefresh = true
        guard pendingRefresh == nil else { return }
        let refresh = DispatchWorkItem { [weak self] in
            self?.pendingRefresh = nil
            self?.refreshIfNeeded()
        }
        pendingRefresh = refresh
        DispatchQueue.main.async(execute: refresh)
    }

    func textStorageDidProcessEditing(editedMask: NSTextStorageEditActions,
                                      editedRange: NSRange,
                                      changeInLength delta: Int,
                                      textStorage: NSTextStorage) {}
}
