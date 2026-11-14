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
    /// not a folded header). The collapsed-block indicator no longer shows this
    /// count ("⋯" only, VS Code style); this stays as the fold-extent query.
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
/// - **Never a whole-document scan on the draw path** (first-paint fix): the
///   gutter asks `foldState(atLine:)` per visible line. Until the full scan for
///   the current text is published, those answers come from small *windows*
///   (128 header lines, `FoldScanner.window`) computed on demand with a fixed
///   work budget — exact for every line they resolve, "no marker yet" for the
///   rest. The full scan runs as a resumable `FoldScan` in ~4 ms main-thread
///   slices on `AnalysisScheduler` (decision D), started on first use and
///   restarted (debounced) after each character edit; a completed scan is
///   published only for the text version it started on, then serves every
///   query by binary search. Operations that need the whole set (fold all,
///   fold current) finish the in-flight scan synchronously.
/// - **Transient, not resident** (ARCHITECTURE.md §3.4): the scanned regions
///   (8 bytes each) are kept only until the next edit; the active-fold set is
///   tiny.
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

    /// Foldable regions of the current text in scanner order (sorted by start,
    /// then end line), or `nil` while the full scan for this text version has
    /// not been published. Binary-searched by `foldState(atLine:)`.
    private var cachedRegions: [FoldRegion]?

    /// The published full-scan regions (`nil` while none is current). Tests /
    /// diagnostics.
    var publishedRegions: [FoldRegion]? { cachedRegions }

    /// Called after each scheduler slice of the full scan (tests: lets an edit
    /// land deterministically mid-scan).
    var scanSliceObserver: (() -> Void)?

    /// Bumped on every character edit and language change; a scan publishes
    /// only if the version it started on is still current.
    private var textVersion: UInt64 = 0

    /// The in-flight full scan and its scheduler job (both `nil` when idle).
    private var pendingScan: (scan: FoldScan, version: UInt64)?
    private var scanJob: AnalysisJob?

    /// Bounded per-window results serving `foldState` until the full scan is
    /// published. A handful of recent windows; cleared on edits and on publish.
    private var windows: [FoldWindow] = []

    /// Header lines per window, and the work budget (UTF-16 units examined)
    /// one window computation may spend — roughly a millisecond or two.
    static let windowLineCount = 128
    static let windowBudget = 1_000_000
    private static let maxCachedWindows = 8

    /// Debounce before rescanning after an edit (typing restarts it).
    static let rescanDelay: TimeInterval = 0.25

    private let scheduler: AnalysisScheduler

    /// Scan statistics for PerfLog (`fold.scan`).
    private var scanStats = (start: UInt64(0), busy: UInt64(0), slices: 0, maxSlice: UInt64(0))

    /// Supplies the document's current language identifier (`""` = plain), read
    /// lazily at scan time so folding never caches a language that a manual
    /// switch or a late auto-detection has already changed. The scanner uses it
    /// to pick its rule set (markdown folds by heading / code fence, T13.4).
    public var languageProvider: (() -> String)?

    public init(textView: NSTextView, lineIndex: LineIndex,
                scheduler: AnalysisScheduler = .shared) {
        self.textView = textView
        self.lineIndex = lineIndex
        self.scheduler = scheduler
        super.init()
    }

    /// The text storage's backing string as an `NSString`, read in place by
    /// the scanner (no bridging through a Swift `String`).
    private var storageString: NSString? {
        textView?.textStorage?.mutableString
    }

    // MARK: - Foldable-region cache

    /// All foldable regions for the current text, in scanner order. Returns the
    /// published scan, or finishes the in-flight scan (or a fresh one)
    /// synchronously — only user commands that need the whole set call this,
    /// never the draw path.
    ///
    /// Publishing a scan is also the trigger for the T12.13 **lazy validation**
    /// pass: any active fold whose header line is no longer the start of a
    /// scanned region with the same end line has become stale (typically because
    /// an edit to the header line itself destroyed its foldability without
    /// touching the hidden body, which the offset-shift maintenance in
    /// `textStorageDidProcessEditing` cannot notice) and is dropped, with a
    /// targeted invalidation of just its range.
    private func regions() -> [FoldRegion] {
        if let cachedRegions { return cachedRegions }
        guard let ns = storageString else { return [] }
        let scan: FoldScan
        if let pending = pendingScan, pending.version == textVersion, !pending.scan.isAborted {
            scan = pending.scan
        } else if let fresh = FoldScan(ns: ns, lineIndex: lineIndex, language: languageProvider?() ?? "") {
            scan = fresh
            beginScanStats()
        } else {
            return [] // string / index transiently out of sync: try again later
        }
        let begin = PerfLog.isEnabled ? PerfLog.now() : 0
        scan.advance()
        if PerfLog.isEnabled { noteSlice(PerfLog.now() &- begin) }
        cancelScan() // finished here; the queued job has nothing left to do
        publish(scan, version: textVersion)
        return cachedRegions ?? []
    }

    /// Starts the sliced full scan for the current text unless it is already
    /// published or in flight.
    private func ensureScanScheduled(after delay: TimeInterval = 0) {
        guard cachedRegions == nil else { return }
        if let pending = pendingScan, pending.version == textVersion,
           let job = scanJob, !job.isCancelled { return }
        guard let ns = storageString,
              let scan = FoldScan(ns: ns, lineIndex: lineIndex, language: languageProvider?() ?? "") else { return }
        let version = textVersion
        pendingScan = (scan, version)
        beginScanStats()
        let job = AnalysisJob(owner: ObjectIdentifier(self), version: version,
                              step: { [weak self] deadline in
                                  // Captures only the scan: a stale or orphaned
                                  // job just finishes (a mismatch aborts it).
                                  let begin = DispatchTime.now().uptimeNanoseconds
                                  let done = scan.advance(deadline: deadline)
                                  if PerfLog.isEnabled {
                                      self?.noteSlice(DispatchTime.now().uptimeNanoseconds &- begin)
                                  }
                                  self?.scanSliceObserver?()
                                  return done
                              },
                              completion: { [weak self] in
                                  self?.publish(scan, version: version)
                              },
                              isInKeyWindow: { [weak self] in self?.textView?.window?.isKeyWindow ?? false })
        scanJob = job
        scheduler.schedule(job, after: delay)
    }

    /// Cancels the in-flight scan (its results would describe stale text).
    private func cancelScan() {
        if scanJob != nil { scheduler.cancel(owner: ObjectIdentifier(self)) }
        scanJob = nil
        pendingScan = nil
    }

    /// Adopts a finished scan if it still describes the current text, then
    /// validates the active folds against it and repaints the markers.
    private func publish(_ scan: FoldScan, version: UInt64) {
        if pendingScan?.scan === scan {
            pendingScan = nil
            scanJob = nil
        }
        guard version == textVersion, scan.isFinished, !scan.isAborted, cachedRegions == nil else { return }
        let regions = scan.regions
        cachedRegions = regions
        windows = []
        if PerfLog.isEnabled {
            let s = scanStats
            PerfLog.record("fold.scan", durationSeconds: Double(s.busy) / 1e9,
                           ["lines": lineIndex.lineCount, "regions": regions.count, "slices": s.slices,
                            "maxSliceMs": String(format: "%.2f", Double(s.maxSlice) / 1e6),
                            "wallMs": String(format: "%.1f", Double(PerfLog.now() &- s.start) / 1e6)])
        }
        validateActiveFolds(against: regions)
        textView?.enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }

    private func beginScanStats() {
        scanStats = (PerfLog.isEnabled ? PerfLog.now() : 0, 0, 0, 0)
    }

    private func noteSlice(_ ns: UInt64) {
        scanStats.busy &+= ns
        scanStats.slices += 1
        scanStats.maxSlice = max(scanStats.maxSlice, ns)
    }

    /// The bounded window holding `line`'s fold state, computed on demand and
    /// cached until the next edit or publish. `nil` when the string and index
    /// are transiently out of sync.
    private func window(containing line: Int) -> FoldWindow? {
        let size = Self.windowLineCount
        let first = (line - 1) / size * size + 1
        if let hit = windows.first(where: { $0.lines.lowerBound == first }) { return hit }
        guard let ns = storageString, ns.length == lineIndex.length else { return nil }
        let last = min(lineIndex.lineCount, first + size - 1)
        guard first <= last else { return nil }
        let begin = PerfLog.isEnabled ? PerfLog.now() : 0
        let computed = FoldScanner.window(in: ns, lineIndex: lineIndex, language: languageProvider?() ?? "",
                                          lines: first...last, budget: Self.windowBudget)
        if PerfLog.isEnabled {
            PerfLog.record("fold.window", since: begin,
                           ["first": first, "complete": computed.isComplete, "regions": computed.regions.count])
        }
        windows.append(computed)
        if windows.count > Self.maxCachedWindows { windows.removeFirst() }
        // A window is exact for the lines it resolves, so it can already run
        // the lazy validation for folds headed there (an edit that broke a
        // folded header is noticed at the next draw, not only at publish).
        validateActiveFolds { header, region in
            !computed.isResolved(header) || computed.regions.containsSorted(region)
        }
        return computed
    }

    /// Drops any active fold that no longer corresponds to a scanned region
    /// (same header line *and* end line). Runs when a scan is published or a
    /// window is computed, which can happen inside a gutter draw — so state is
    /// corrected immediately, but the layout invalidation is pushed to the next
    /// runloop turn (mutating the layout manager mid-draw is the same hazard
    /// class as doing it inside processEditing; see the crash-hardening note in
    /// `textStorageDidProcessEditing`).
    private func validateActiveFolds(against scanned: [FoldRegion]) {
        validateActiveFolds { _, region in scanned.containsSorted(region) }
    }

    /// Drops every active fold for which `isValid(header, region)` is false.
    private func validateActiveFolds(_ isValid: (_ header: Int, _ region: FoldRegion) -> Bool) {
        guard !activeFolds.isEmpty else { return }
        var dirty: [NSRange] = []
        for (header, region) in activeFolds where !isValid(header, region) {
            dirty.append(hiddenCharRange(for: region))
            activeFolds[header] = nil
        }
        guard !dirty.isEmpty else { return }
        recomputeDerived()
        let ranges = dirty
        DispatchQueue.main.async { [weak self] in
            self?.applyInvalidation(ranges, ensureLayout: false)
        }
    }

    /// Drops the scanned regions, the windows and any in-flight scan. Called on
    /// every character edit (the regions and their line numbers may both have
    /// moved) and on a language change.
    private func invalidateRegionCache() {
        textVersion &+= 1
        cachedRegions = nil
        windows = []
        cancelScan()
    }

    /// Tells folding the document's language changed (open, manual pick, or
    /// auto-detection), so the cached regions — scanned under the *old* rule set —
    /// are dropped and the gutter redraws with the new arrows. Nothing else needs
    /// invalidating: a language switch leaves the text, and therefore the layout,
    /// untouched. Active folds are kept as they are; the lazy `validateActiveFolds`
    /// pass on the next published scan discards any that the new rules no longer
    /// produce.
    public func noteLanguageChanged() {
        invalidateRegionCache()
        ensureScanScheduled()
        textView?.needsDisplay = true
        textView?.enclosingScrollView?.verticalRulerView?.needsDisplay = true
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

    /// Called per visible line on every gutter draw, so it never scans the
    /// whole document: the published scan answers by binary search; before
    /// that, a bounded window does (unresolved lines draw no marker until the
    /// sliced scan lands, which repaints the ruler).
    public func foldState(atLine line: Int) -> FoldArrow {
        let folded = activeFolds[line] != nil
        if let cachedRegions {
            guard cachedRegions.firstRegion(startingAt: line) != nil else { return .none }
            return folded ? .folded : .foldable
        }
        ensureScanScheduled()
        guard let window = window(containing: line), window.isResolved(line) else {
            // Unknown yet: keep showing an existing fold's control (validation
            // on publish drops it if it went stale).
            return folded ? .folded : .none
        }
        guard window.regions.firstRegion(startingAt: line) != nil else { return .none }
        return folded ? .folded : .foldable
    }

    /// The narrowest region headed by `line`, without forcing a full scan:
    /// from the published scan, else from `line`'s window when it resolves it.
    private func region(startingAt line: Int) -> FoldRegion? {
        if let cachedRegions { return cachedRegions.firstRegion(startingAt: line) }
        ensureScanScheduled()
        if let window = window(containing: line), window.isResolved(line) {
            return window.regions.firstRegion(startingAt: line)
        }
        return regions().firstRegion(startingAt: line)
    }

    public func toggleFold(atLine line: Int) {
        let region: FoldRegion
        if let folded = activeFolds[line] {
            region = folded
            activeFolds[line] = nil
        } else if let scanned = self.region(startingAt: line) {
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

    /// Folds the innermost *not-yet-folded* foldable region that contains `line`
    /// (the caret line; a caret sitting on the header line counts as contained).
    /// Skipping the already-folded ones makes repeated invocations walk outward
    /// one level at a time (VS Code's ⌥⌘[). No-op when `line` is inside no
    /// foldable region, or every containing region is already folded.
    public func foldCurrent(atLine line: Int) {
        let containing = regions().filter {
            $0.startLine <= line && line <= $0.endLine
                && activeFolds[$0.startLine]?.endLine != $0.endLine
        }
        guard let region = containing.min(by: { span($0) < span($1) }) else { return }
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

    /// Invalidates glyphs for each range (clamped to the document) and layout
    /// from the earliest affected character through the end of the document,
    /// optionally forcing synchronous layout, then schedules the editor and
    /// ruler to repaint. Passing an empty `ranges` still refreshes the ruler
    /// (fold arrows / hidden-line numbers may have moved with the text).
    ///
    /// Layout must extend to the document end: invalidating only the hidden
    /// ranges leaves the typesetter free to keep stale fragments *around* them,
    /// and the regenerated null glyphs then land in fragments that straddle the
    /// hidden/visible boundary — the zero-height collapse (which rightly touches
    /// only fully-hidden fragments) can't fire, producing a ghost blank row and
    /// a closing line rendered displaced or not at all (user bug, 2026-07-28,
    /// debug/test.json). Glyph invalidation stays per-range (cheap and precise);
    /// the tail relayout is user-initiated-fold cost, not a per-edit cost.
    private func applyInvalidation(_ ranges: [NSRange], ensureLayout: Bool) {
        guard let layoutManager = textView?.layoutManager,
              let container = textView?.textContainer else { return }
        let docLen = textView?.textStorage?.length ?? 0
        var earliest = Int.max
        for r in ranges {
            let lo = max(0, r.location)
            let hi = min(docLen, r.location + r.length)
            guard hi > lo else { continue }
            let clamped = NSRange(location: lo, length: hi - lo)
            layoutManager.invalidateGlyphs(forCharacterRange: clamped, changeInLength: 0, actualCharacterRange: nil)
            earliest = min(earliest, lo)
        }
        if earliest < docLen {
            layoutManager.invalidateLayout(forCharacterRange: NSRange(location: earliest, length: docLen - earliest),
                                           actualCharacterRange: nil)
            if ensureLayout {
                layoutManager.ensureLayout(for: container)
            }
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
        // Queueing a job is not a layout / display mutation, so it is safe
        // inside processEditing; the debounce keeps typing from rescanning.
        ensureScanScheduled(after: Self.rescanDelay)
        guard !activeFolds.isEmpty else { return }

        let editStart = editedRange.location
        let newEditEnd = editedRange.location + editedRange.length
        let oldEditEnd = editStart + (editedRange.length - delta) // edit end in PRE-edit coords
        let newLen = textStorage.length

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
        // This callback runs *inside* the storage's processEditing pass.
        // Invalidating layout synchronously here can interleave a ruler/content
        // redraw with the half-settled edit transaction (TextKit hygiene; the
        // macOS 26 beta display-link flush made that interleaving real). Update
        // our state now, but push the visual invalidation to the next runloop
        // turn, after the edit transaction has fully settled.
        if !dirty.isEmpty {
            let ranges = dirty
            DispatchQueue.main.async { [weak self] in
                self?.applyInvalidation(ranges, ensureLayout: true)
            }
        } else {
            applyInvalidation([], ensureLayout: false)
        }
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

            // Hidden *newlines* must keep their original (control) property: a
            // `.null` glyph is skipped by the typesetter entirely — including
            // its line-break action — so nulling them fuses paragraphs into
            // fragments that straddle the hidden/visible boundary. Straddling
            // fragments defeat the fully-hidden zero-height collapse below and
            // rendered as a ghost blank row / a displaced or missing closing
            // line (user bug, 2026-07-28, debug/test.json). Keeping the breaks
            // preserves one fragment per hidden line, each fully hidden and
            // safely collapsible.
            // The backing string as an `NSString`, without a `String` bridge.
            guard let ns = layoutManager.textStorage?.mutableString else { return 0 }
            let count = glyphRange.length
            var modified = false
            let newProps = UnsafeMutablePointer<NSLayoutManager.GlyphProperty>.allocate(capacity: count)
            defer { newProps.deallocate() }
            for i in 0..<count {
                let charIndex = charIndexes[i]
                if isHidden(characterIndex: charIndex), charIndex < ns.length,
                   !Self.isNewline(ns.character(at: charIndex)) {
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

    /// UTF-16 line terminators (LF, CR; NEL/LS/PS for completeness — the
    /// document model normalizes to LF, but glyph generation sees raw storage).
    private nonisolated static func isNewline(_ c: unichar) -> Bool {
        c == 0x0A || c == 0x0D || c == 0x85 || c == 0x2028 || c == 0x2029
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
