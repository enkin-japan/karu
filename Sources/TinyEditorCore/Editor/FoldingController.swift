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

    /// Character ranges hidden by `activeFolds`, recomputed whenever the fold
    /// set changes. Sorted by location. Empty in the common (nothing folded)
    /// case, which lets the hot layout callbacks bail out immediately.
    private var hiddenRanges: [NSRange] = []

    /// Cached foldable regions for the current text (`nil` = needs rescanning).
    private var cachedRegions: [FoldRegion]?

    public init(textView: NSTextView, lineIndex: LineIndex) {
        self.textView = textView
        self.lineIndex = lineIndex
        super.init()
    }

    // MARK: - Foldable-region cache

    /// All foldable regions for the current text, scanned lazily and cached
    /// until the next character edit.
    private func regions() -> [FoldRegion] {
        if let cachedRegions { return cachedRegions }
        guard let textView else { return [] }
        let scanned = FoldScanner.regions(text: textView.string, lineIndex: lineIndex)
        cachedRegions = scanned
        return scanned
    }

    // MARK: - FoldStatusProviding

    public func isLineHidden(_ line: Int) -> Bool {
        for region in activeFolds.values where line > region.startLine && line <= region.endLine {
            return true
        }
        return false
    }

    public func foldState(atLine line: Int) -> FoldArrow {
        guard regions().contains(where: { $0.startLine == line }) else { return .none }
        return activeFolds[line] != nil ? .folded : .foldable
    }

    public func toggleFold(atLine line: Int) {
        if activeFolds[line] != nil {
            activeFolds[line] = nil
        } else if let region = regions().first(where: { $0.startLine == line }) {
            activeFolds[line] = region
        } else {
            return
        }
        applyFolds()
    }

    // MARK: - Applying folds

    /// Recomputes hidden character ranges from the active folds (always using
    /// the up-to-date `LineIndex`) and forces the layout manager to regenerate
    /// glyphs / relayout so the change is reflected.
    private func applyFolds() {
        hiddenRanges = activeFolds.values
            .map { hiddenCharRange(for: $0) }
            .filter { $0.length > 0 }
            .sorted { $0.location < $1.location }

        guard let layoutManager = textView?.layoutManager,
              let container = textView?.textContainer else { return }
        let full = NSRange(location: 0, length: (textView?.string as NSString?)?.length ?? 0)
        layoutManager.invalidateGlyphs(forCharacterRange: full, changeInLength: 0, actualCharacterRange: nil)
        layoutManager.invalidateLayout(forCharacterRange: full, actualCharacterRange: nil)
        layoutManager.ensureLayout(for: container)
        textView?.needsDisplay = true
        // The ruler tracks fold state for its arrows / hidden-line skipping.
        textView?.enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }

    /// UTF-16 character range hidden when `region` is folded: from the start of
    /// the first hidden line through the end (terminator included) of the last
    /// hidden line, so the collapsed block leaves no residual blank line.
    private func hiddenCharRange(for region: FoldRegion) -> NSRange {
        let lower = lineIndex.offsetRange(ofLine: region.startLine + 1).lowerBound
        let upper = lineIndex.offsetRange(ofLine: region.endLine).upperBound
        return NSRange(location: lower, length: max(0, upper - lower))
    }

    private func isHidden(characterIndex i: Int) -> Bool {
        for r in hiddenRanges where i >= r.location && i < r.location + r.length {
            return true
        }
        return false
    }

    // MARK: - TextStorageObserving

    /// On any character edit the scanned regions become stale and the active
    /// folds' character offsets shift, so we drop the region cache and unfold
    /// everything. This is the conservative v1 behaviour: it guarantees no stale
    /// hidden range can survive an edit (line numbers / highlight can never be
    /// corrupted), at the cost of not preserving folds across edits. Attribute-
    /// only edits (highlighting) are ignored.
    public func textStorageDidProcessEditing(editedMask: NSTextStorageEditActions,
                                             editedRange: NSRange,
                                             changeInLength delta: Int,
                                             textStorage: NSTextStorage) {
        guard editedMask.contains(.editedCharacters) else { return }
        cachedRegions = nil
        guard !activeFolds.isEmpty else { return }
        activeFolds.removeAll()
        applyFolds()
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
            guard !hiddenRanges.isEmpty else { return 0 }

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
            guard !hiddenRanges.isEmpty else { return false }
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
