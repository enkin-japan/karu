import AppKit

/// Fold state a gutter cell can be in, so the ruler can draw the right control
/// without knowing anything about how folding is implemented.
public enum FoldArrow {
    /// The line is not a fold header — no control.
    case none
    /// A fold header that is currently expanded (draw ▾).
    case foldable
    /// A fold header that is currently folded (draw ▸).
    case folded
}

/// What the gutter needs to ask the folding layer while drawing / handling
/// clicks. Keeps `GutterView` decoupled from `FoldingController`.
@MainActor
public protocol FoldStatusProviding: AnyObject {
    /// True when `line` (1-based) is hidden inside a currently-folded region and
    /// therefore must not have its number drawn.
    func isLineHidden(_ line: Int) -> Bool
    /// The control to draw next to `line`.
    func foldState(atLine line: Int) -> FoldArrow
    /// Toggles the fold whose header is `line`, if any.
    func toggleFold(atLine line: Int)
    /// Header lines (1-based) of every region currently folded, so the editor
    /// can paint their collapsed-block background. Empty when nothing is folded.
    func foldedHeaderLines() -> [Int]
    /// Number of lines hidden beneath the folded header `line` (0 when `line` is
    /// not a folded header), used for the "⋯ N" collapsed-block indicator.
    func hiddenLineCount(forHeader line: Int) -> Int
}

/// Owns code-folding state and implements it as an `NSLayoutManagerDelegate`.
///
/// Implementation notes (matches the T3.4 brief):
/// - **Folding never mutates the text.** It only suppresses *glyph generation*
///   for the hidden character ranges (`shouldGenerateGlyphs` → `.null`) and
///   collapses those line fragments to zero height
///   (`shouldSetLineFragmentRect`). Because the text and therefore the shared
///   `LineIndex` are untouched, line numbers and syntax highlight stay correct
///   whether or not anything is folded.
/// - **Transient, not resident** (ARCHITECTURE.md §3.4): foldable regions are
///   scanned on demand via `FoldScanner` and cached only until the next edit;
///   the active-fold set is tiny.
/// - It registers on the shared `TextStorageObserverHub` purely to notice
///   *character* edits and drop stale fold state; it never writes to storage, so
///   it does not perturb the gutter or highlighter (both ignore
///   attribute-only edits anyway).
@MainActor
public final class FoldingController: NSObject, NSLayoutManagerDelegate, TextStorageObserving, FoldStatusProviding {
    private weak var textView: NSTextView?
    private let lineIndex: LineIndex

    /// Regions currently folded, keyed by their (1-based) header line.
    private var activeFolds: [Int: FoldRegion] = [:]

    /// The hidden UTF-16 character range each active fold occupied at the time of
    /// the last `recomputeDerived()`, keyed by header line. Kept so that when a
    /// character edit arrives (after which the shared `LineIndex` already reflects
    /// the *new* text) we still know each fold's *pre-edit* extent and can decide
    /// whether it shifts, stays, or must be dropped (T12.13).
    private var foldCharRanges: [Int: NSRange] = [:]

    /// Non-overlapping, sorted hidden character ranges derived from `activeFolds`
    /// (nested / overlapping folds merged). Empty in the common (nothing folded)
    /// case, which lets the hot layout callbacks bail out immediately, and binary-
    /// searchable so `isHidden(characterIndex:)` stays O(log n) even after
    /// `foldAll()` produces thousands of folds.
    private var mergedHiddenRanges: [NSRange] = []

    /// Non-overlapping, sorted *hidden line* intervals (1-based, inclusive)
    /// derived from `activeFolds`, so `isLineHidden(_:)` — called per gutter line
    /// on every draw — is a binary search rather than a scan of every fold.
    private var hiddenLineIntervals: [(lower: Int, upper: Int)] = []

    /// Cached foldable regions for the current text (`nil` = needs rescanning).
    private var cachedRegions: [FoldRegion]?

    /// Cached set of the header (start) lines of `cachedRegions`, so
    /// `foldState(atLine:)` — called per gutter line on every draw — is an O(1)
    /// membership test. Invalidated together with `cachedRegions`.
    private var cachedStartLines: Set<Int>?

    public init(textView: NSTextView, lineIndex: LineIndex) {
        self.textView = textView
        self.lineIndex = lineIndex
        super.init()
    }

    // MARK: - Foldable-region cache

    /// All foldable regions for the current text, scanned lazily and cached
    /// until the next character edit.
    ///
    /// A rescan is also the trigger for the T12.13 **lazy validation** pass: any
    /// active fold whose header line is no longer the start of a scanned region
    /// with the same end line has become stale (typically because an edit to the
    /// header line itself destroyed its foldability without touching the hidden
    /// body, which the offset-shift maintenance in `textStorageDidProcessEditing`
    /// cannot notice) and is dropped, with a targeted invalidation of just its
    /// range.
    private func regions() -> [FoldRegion] {
        if let cachedRegions { return cachedRegions }
        guard let textView else { return [] }
        let scanned = FoldScanner.regions(text: textView.string, lineIndex: lineIndex)
        cachedRegions = scanned
        cachedStartLines = Set(scanned.map { $0.startLine })
        validateActiveFolds(against: scanned)
        return scanned
    }

    /// Drops any active fold that no longer corresponds to a scanned region
    /// (same header line *and* end line), invalidating just the discarded
    /// ranges. Runs during a rescan, which can happen inside a gutter draw, so it
    /// deliberately avoids forcing synchronous layout (`ensureLayout: false`) —
    /// `needsDisplay` schedules the repaint for the next cycle instead.
    private func validateActiveFolds(against scanned: [FoldRegion]) {
        guard !activeFolds.isEmpty else { return }
        let valid = Set(scanned.map { [$0.startLine, $0.endLine] })
        var dirty: [NSRange] = []
        for (header, region) in activeFolds where !valid.contains([region.startLine, region.endLine]) {
            dirty.append(hiddenCharRange(for: region))
            activeFolds[header] = nil
        }
        guard !dirty.isEmpty else { return }
        recomputeDerived()
        applyInvalidation(dirty, ensureLayout: false)
    }

    /// Invalidates both region caches. Called on every character edit (the
    /// scanned regions and their line numbers may both have moved).
    private func invalidateRegionCache() {
        cachedRegions = nil
        cachedStartLines = nil
    }

    // MARK: - FoldStatusProviding

    public func isLineHidden(_ line: Int) -> Bool {
        // Binary search the merged hidden-line intervals.
        var lo = 0, hi = hiddenLineIntervals.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let iv = hiddenLineIntervals[mid]
            if line < iv.lower { hi = mid - 1 }
            else if line > iv.upper { lo = mid + 1 }
            else { return true }
        }
        return false
    }

    public func foldState(atLine line: Int) -> FoldArrow {
        guard startLineSet().contains(line) else { return .none }
        return activeFolds[line] != nil ? .folded : .foldable
    }

    /// Header lines of the current foldable regions, cached alongside the scan.
    private func startLineSet() -> Set<Int> {
        if let cachedStartLines { return cachedStartLines }
        _ = regions() // populates cachedStartLines (and runs lazy validation)
        return cachedStartLines ?? []
    }

    public func toggleFold(atLine line: Int) {
        let region: FoldRegion
        if let folded = activeFolds[line] {
            region = folded
            activeFolds[line] = nil
        } else if let scanned = regions().first(where: { $0.startLine == line }) {
            region = scanned
            activeFolds[line] = scanned
        } else {
            return
        }
        applyFolds(invalidating: [hiddenCharRange(for: region)])
    }

    // MARK: - Fold-all / current (T12.12)

    /// Folds every foldable region in the document. Nested regions fold together
    /// (their hidden ranges merge); when two regions share a header line the wider
    /// one wins (regions are sorted by start then end, so the last write per
    /// header keeps the larger span).
    public func foldAll() {
        let all = regions()
        guard !all.isEmpty else { return }
        var dirty: [NSRange] = []
        for region in all where activeFolds[region.startLine]?.endLine != region.endLine {
            activeFolds[region.startLine] = region
        }
        for region in activeFolds.values {
            dirty.append(hiddenCharRange(for: region))
        }
        applyFolds(invalidating: dirty)
    }

    /// Unfolds everything.
    public func unfoldAll() {
        guard !activeFolds.isEmpty else { return }
        let dirty = activeFolds.values.map { hiddenCharRange(for: $0) }
        activeFolds.removeAll()
        applyFolds(invalidating: dirty)
    }

    /// Folds the innermost foldable region that contains `line` (the caret line;
    /// a caret sitting on the header line counts as contained). No-op when `line`
    /// is inside no foldable region, or the innermost one is already folded.
    public func foldCurrent(atLine line: Int) {
        let containing = regions().filter { $0.startLine <= line && line <= $0.endLine }
        guard let region = containing.min(by: { span($0) < span($1) }),
              activeFolds[region.startLine]?.endLine != region.endLine else { return }
        activeFolds[region.startLine] = region
        applyFolds(invalidating: [hiddenCharRange(for: region)])
    }

    /// Unfolds the innermost *currently folded* region that contains `line`.
    public func unfoldCurrent(atLine line: Int) {
        let containing = activeFolds.values.filter { $0.startLine <= line && line <= $0.endLine }
        guard let region = containing.min(by: { span($0) < span($1) }) else { return }
        activeFolds[region.startLine] = nil
        applyFolds(invalidating: [hiddenCharRange(for: region)])
    }

    /// Line span of a region (larger = outer), used to pick the innermost one.
    private func span(_ region: FoldRegion) -> Int { region.endLine - region.startLine }

    public func foldedHeaderLines() -> [Int] {
        activeFolds.keys.sorted()
    }

    public func hiddenLineCount(forHeader line: Int) -> Int {
        // A folded region hides `startLine + 1 ... endLine` (inclusive), so the
        // count is simply the header-to-end line span.
        guard let region = activeFolds[line] else { return 0 }
        return region.endLine - region.startLine
    }

    // MARK: - Applying folds

    /// Recomputes the derived hidden-range / hidden-line structures from the
    /// active folds, then invalidates *only* the given character ranges (not the
    /// whole document — that was the old, O(document) behaviour). Used by every
    /// manual fold action; `ranges` is the union of the ranges whose visibility
    /// just flipped.
    private func applyFolds(invalidating ranges: [NSRange]) {
        recomputeDerived()
        applyInvalidation(ranges, ensureLayout: true)
    }

    /// Rebuilds `foldCharRanges`, `mergedHiddenRanges` and `hiddenLineIntervals`
    /// from `activeFolds`, always using the up-to-date `LineIndex`. Performs no
    /// layout invalidation (callers decide what to invalidate).
    private func recomputeDerived() {
        var charRanges: [Int: NSRange] = [:]
        var raw: [NSRange] = []
        var lineIntervals: [(Int, Int)] = []
        for (header, region) in activeFolds {
            let r = hiddenCharRange(for: region)
            charRanges[header] = r
            if r.length > 0 { raw.append(r) }
            if region.endLine >= region.startLine + 1 {
                lineIntervals.append((region.startLine + 1, region.endLine))
            }
        }
        foldCharRanges = charRanges
        mergedHiddenRanges = Self.mergeRanges(raw)
        hiddenLineIntervals = Self.mergeLineIntervals(lineIntervals)
    }

    /// Invalidates glyphs + layout for each range (clamped to the document),
    /// optionally forcing synchronous layout, then schedules the editor and ruler
    /// to repaint. Passing an empty `ranges` still refreshes the ruler (fold
    /// arrows / hidden-line numbers may have moved with the text).
    private func applyInvalidation(_ ranges: [NSRange], ensureLayout: Bool) {
        guard let layoutManager = textView?.layoutManager,
              let container = textView?.textContainer else { return }
        let docLen = (textView?.string as NSString?)?.length ?? 0
        var didInvalidate = false
        for r in ranges {
            let lo = max(0, r.location)
            let hi = min(docLen, r.location + r.length)
            guard hi > lo else { continue }
            let clamped = NSRange(location: lo, length: hi - lo)
            layoutManager.invalidateGlyphs(forCharacterRange: clamped, changeInLength: 0, actualCharacterRange: nil)
            layoutManager.invalidateLayout(forCharacterRange: clamped, actualCharacterRange: nil)
            didInvalidate = true
        }
        if didInvalidate && ensureLayout {
            layoutManager.ensureLayout(for: container)
        }
        textView?.needsDisplay = true
        // The ruler tracks fold state for its arrows / hidden-line skipping.
        textView?.enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }

    /// Merges a set of possibly-overlapping character ranges into a sorted,
    /// non-overlapping array (adjacent ranges coalesce), for binary search.
    private static func mergeRanges(_ ranges: [NSRange]) -> [NSRange] {
        guard !ranges.isEmpty else { return [] }
        let sorted = ranges.sorted { $0.location < $1.location }
        var result: [NSRange] = [sorted[0]]
        for r in sorted.dropFirst() {
            let last = result[result.count - 1]
            let lastEnd = last.location + last.length
            if r.location <= lastEnd {
                let newEnd = max(lastEnd, r.location + r.length)
                result[result.count - 1] = NSRange(location: last.location, length: newEnd - last.location)
            } else {
                result.append(r)
            }
        }
        return result
    }

    /// Merges 1-based inclusive line intervals into a sorted, non-overlapping
    /// array (intervals touching or one line apart coalesce), for binary search.
    private static func mergeLineIntervals(_ intervals: [(Int, Int)]) -> [(lower: Int, upper: Int)] {
        let valid = intervals.filter { $0.1 >= $0.0 }.sorted { $0.0 < $1.0 }
        guard let first = valid.first else { return [] }
        var result: [(lower: Int, upper: Int)] = [(first.0, first.1)]
        for iv in valid.dropFirst() {
            let last = result[result.count - 1]
            if iv.0 <= last.upper + 1 {
                result[result.count - 1] = (last.lower, max(last.upper, iv.1))
            } else {
                result.append((iv.0, iv.1))
            }
        }
        return result
    }

    /// UTF-16 character range hidden when `region` is folded: from the start of
    /// the first hidden line through the end (terminator included) of the last
    /// hidden line, so the collapsed block leaves no residual blank line.
    private func hiddenCharRange(for region: FoldRegion) -> NSRange {
        let lower = lineIndex.offsetRange(ofLine: region.startLine + 1).lowerBound
        let upper = lineIndex.offsetRange(ofLine: region.endLine).upperBound
        return NSRange(location: lower, length: max(0, upper - lower))
    }

    /// Binary search over the merged hidden character ranges. O(log n) so that a
    /// document with thousands of folds (post `foldAll()`) still generates glyphs
    /// at speed.
    private func isHidden(characterIndex i: Int) -> Bool {
        var lo = 0, hi = mergedHiddenRanges.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let r = mergedHiddenRanges[mid]
            if i < r.location { hi = mid - 1 }
            else if i >= r.location + r.length { lo = mid + 1 }
            else { return true }
        }
        return false
    }

    // MARK: - TextStorageObserving

    /// Keeps folds alive across character edits (T12.13).
    ///
    /// This callback runs *after* `GutterView` (registered on the hub before us)
    /// has already applied the incremental `LineIndex` update, so `lineIndex`
    /// here reflects the **post-edit** text. We therefore cannot recompute a
    /// fold's *pre-edit* extent from it — instead each fold's pre-edit hidden
    /// range is read from `foldCharRanges` (recorded at the last apply) and
    /// classified against the edit:
    ///
    /// - entirely before the edit → unchanged;
    /// - entirely after the edit → shifted by `delta`;
    /// - overlapping the edit → dropped (correctness first).
    ///
    /// Surviving folds have their new line numbers reconstructed from the shifted
    /// character range via the post-edit `LineIndex`. Surviving folds need *no*
    /// layout invalidation (TextKit reflows the edited range and shifts the glyph
    /// mapping — including the already-suppressed `.null` glyphs — automatically);
    /// only dropped folds get a targeted invalidation of their range.
    ///
    /// A dropped fold does not "come back" if the edit is later undone; that is an
    /// accepted trade-off (the undo restores the text, not the transient fold).
    /// Attribute-only edits (highlighting) are ignored.
    public func textStorageDidProcessEditing(editedMask: NSTextStorageEditActions,
                                             editedRange: NSRange,
                                             changeInLength delta: Int,
                                             textStorage: NSTextStorage) {
        guard editedMask.contains(.editedCharacters) else { return }
        invalidateRegionCache()
        guard !activeFolds.isEmpty else { return }

        let editStart = editedRange.location
        let newEditEnd = editedRange.location + editedRange.length
        let oldEditEnd = editStart + (editedRange.length - delta) // edit end in PRE-edit coords
        let newLen = (textStorage.string as NSString).length

        var newActive: [Int: FoldRegion] = [:]
        var dirty: [NSRange] = []

        for (header, region) in activeFolds {
            guard let oldRange = foldCharRanges[header] else {
                // No recorded extent (shouldn't happen) — drop conservatively.
                dirty.append(hiddenCharRange(for: region))
                continue
            }
            let rStart = oldRange.location
            let rEnd = oldRange.location + oldRange.length

            let shifted: NSRange?
            if rEnd <= editStart {
                shifted = oldRange                                   // before the edit
            } else if rStart >= oldEditEnd {
                shifted = NSRange(location: rStart + delta, length: oldRange.length) // after
            } else {
                shifted = nil                                        // overlaps → drop
            }

            if let nr = shifted, nr.length > 0, nr.location >= 0, nr.location + nr.length <= newLen,
               let rebuilt = reconstructRegion(fromHiddenRange: nr) {
                newActive[rebuilt.startLine] = rebuilt
            } else {
                // Dropped: invalidate the post-edit span it used to occupy.
                let lower = min(oldRange.location, editStart)
                let upper = max(oldRange.location + oldRange.length + delta, newEditEnd)
                dirty.append(NSRange(location: lower, length: max(0, upper - lower)))
            }
        }

        activeFolds = newActive
        recomputeDerived() // re-snaps hidden ranges to whole lines via post-edit LineIndex
        applyInvalidation(dirty, ensureLayout: !dirty.isEmpty)
    }

    /// Rebuilds a `FoldRegion` from a post-edit hidden character range using the
    /// current `LineIndex`: the range spans the first-hidden line's start through
    /// the last-hidden line's end, so the header is `firstHiddenLine - 1`. Returns
    /// `nil` when the range no longer maps to a valid header + body.
    private func reconstructRegion(fromHiddenRange range: NSRange) -> FoldRegion? {
        let firstHidden = lineIndex.lineNumber(forOffset: range.location)
        let endLine = lineIndex.lineNumber(forOffset: range.location + range.length - 1)
        let header = firstHidden - 1
        guard header >= 1, endLine >= header + 1 else { return nil }
        return FoldRegion(startLine: header, endLine: endLine)
    }

    // MARK: - NSLayoutManagerDelegate

    /// Suppresses visible glyphs for hidden characters by tagging them `.null`.
    ///
    /// The `NSLayoutManagerDelegate` requirements are `nonisolated`, but glyph
    /// generation runs on the main thread as part of layout, so we hop onto the
    /// main actor to read fold state (same pattern as `TextStorageObserverHub`).
    public nonisolated func layoutManager(_ layoutManager: NSLayoutManager,
                                          shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                                          properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                                          characterIndexes charIndexes: UnsafePointer<Int>,
                                          font: NSFont,
                                          forGlyphRange glyphRange: NSRange) -> Int {
        MainActor.assumeIsolated {
            guard !mergedHiddenRanges.isEmpty else { return 0 }

            let count = glyphRange.length
            var modified = false
            let newProps = UnsafeMutablePointer<NSLayoutManager.GlyphProperty>.allocate(capacity: count)
            defer { newProps.deallocate() }
            for i in 0..<count {
                if isHidden(characterIndex: charIndexes[i]) {
                    newProps[i] = .null
                    modified = true
                } else {
                    newProps[i] = props[i]
                }
            }
            // Returning 0 tells the layout manager to keep its default glyphs.
            guard modified else { return 0 }
            layoutManager.setGlyphs(glyphs,
                                    properties: newProps,
                                    characterIndexes: charIndexes,
                                    font: font,
                                    forGlyphRange: glyphRange)
            return count
        }
    }

    /// Collapses a fully-hidden line fragment to zero height so the folded block
    /// occupies no vertical space.
    public nonisolated func layoutManager(_ layoutManager: NSLayoutManager,
                                          shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                                          lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
                                          baselineOffset: UnsafeMutablePointer<CGFloat>,
                                          in textContainer: NSTextContainer,
                                          forGlyphRange glyphRange: NSRange) -> Bool {
        MainActor.assumeIsolated {
            guard !mergedHiddenRanges.isEmpty else { return false }
            let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            // Collapse only when the whole fragment is inside a hidden range.
            guard charRange.length > 0,
                  isHidden(characterIndex: charRange.location),
                  isHidden(characterIndex: charRange.location + charRange.length - 1) else { return false }

            var frag = lineFragmentRect.pointee
            frag.size.height = 0
            lineFragmentRect.pointee = frag

            var used = lineFragmentUsedRect.pointee
            used.size.height = 0
            lineFragmentUsedRect.pointee = used

            baselineOffset.pointee = 0
            return true
        }
    }
}
