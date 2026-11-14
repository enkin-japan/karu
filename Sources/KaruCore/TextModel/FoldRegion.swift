import Foundation

/// A collapsible region of the document, expressed purely in 1-based line
/// numbers so it can be computed and unit-tested without any AppKit / layout
/// dependency.
///
/// `startLine` is the *header* line that stays visible and carries the fold
/// control in the gutter. Folding the region hides `startLine + 1 ... endLine`
/// (inclusive). A region is only meaningful when `endLine > startLine` (there is
/// at least one line to hide); `FoldScanner` never emits degenerate regions.
///
/// Line numbers are the single source of truth here: because folding only ever
/// changes *glyph generation* (never the text), the shared `LineIndex` and hence
/// every line number stays valid whether or not anything is folded.
///
/// Stored as two `Int32`s (8 bytes, not 16): a 10 MB source file yields ~10^5
/// regions, and the scan result is kept for the document's lifetime.
public struct FoldRegion: Hashable, Sendable {
    private var start: Int32
    private var end: Int32

    /// 1-based header line; remains visible when folded.
    public var startLine: Int {
        get { Int(start) }
        set { start = Int32(clamping: newValue) }
    }

    /// 1-based last hidden line (inclusive) when folded.
    public var endLine: Int {
        get { Int(end) }
        set { end = Int32(clamping: newValue) }
    }

    public init(startLine: Int, endLine: Int) {
        self.start = Int32(clamping: startLine)
        self.end = Int32(clamping: endLine)
    }

    /// The scanner's output order: by start line, then end line.
    @inline(__always)
    static func precedes(_ a: FoldRegion, _ b: FoldRegion) -> Bool {
        a.start != b.start ? a.start < b.start : a.end < b.end
    }
}

extension Array where Element == FoldRegion {
    /// Index of the first region whose start line is `>= line`, in an array
    /// sorted by `FoldRegion.precedes` (binary search).
    func firstIndex(startingAtOrAfter line: Int) -> Int {
        var lo = 0, hi = count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if self[mid].startLine < line { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// The narrowest region headed by `line` (the first in scanner order), or
    /// `nil` when `line` heads none. Requires scanner order.
    func firstRegion(startingAt line: Int) -> FoldRegion? {
        let i = firstIndex(startingAtOrAfter: line)
        return i < count && self[i].startLine == line ? self[i] : nil
    }

    /// Exact-match membership by binary search. Requires scanner order.
    func containsSorted(_ region: FoldRegion) -> Bool {
        var i = firstIndex(startingAtOrAfter: region.startLine)
        while i < count, self[i].startLine == region.startLine {
            if self[i].endLine == region.endLine { return true }
            i += 1
        }
        return false
    }
}

/// Fold regions headed inside a window of lines, computed by a bounded scan
/// (`FoldScanner.window`) so the gutter can show markers for the visible lines
/// before — or without — a whole-document scan.
///
/// For every *resolved* line of `lines` the window holds exactly the regions a
/// full `FoldScanner.regions` scan reports for that header line. A line is
/// unresolved when the work budget ran out before its regions could be settled
/// (an opener whose match lies far below, a long indented block, or a window
/// the scan never reached); callers treat it as "unknown for now".
public struct FoldWindow {
    /// The 1-based header lines this window covers.
    public let lines: ClosedRange<Int>
    /// Regions headed on resolved lines of `lines`, in scanner order.
    public let regions: [FoldRegion]
    /// Lines of `lines` with fold candidates the budget could not settle (sorted).
    let pendingLines: [Int]
    /// First line of `lines` the scan never reached (`lines.upperBound + 1`
    /// when it processed them all).
    let unreachedFrom: Int

    /// True when every line of `lines` is resolved.
    public var isComplete: Bool { pendingLines.isEmpty && unreachedFrom > lines.upperBound }

    /// True when `line`'s regions are known exactly.
    public func isResolved(_ line: Int) -> Bool {
        guard lines.contains(line), line < unreachedFrom else { return false }
        var lo = 0, hi = pendingLines.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if pendingLines[mid] < line { lo = mid + 1 } else { hi = mid }
        }
        return !(lo < pendingLines.count && pendingLines[lo] == line)
    }
}

/// Foldable-region scanner.
///
/// The strategy is deliberately mixed so it covers both brace-delimited and
/// indentation-delimited languages without an AST (ARCHITECTURE.md §2 "code
/// folding: indent level + bracket pairing, no AST"):
///
/// - **Bracket pairing** for `{}` and `[]`: a cross-line matched pair whose body
///   contains at least one interior line produces a region spanning the interior
///   (both delimiter lines stay visible).
/// - **Indentation** for colon-led blocks (Python / YAML style): a line whose
///   trimmed content ends with `:` followed by more-deeply-indented lines
///   produces a region down to the last such line before the indentation falls
///   back, pulled back over pure closing-bracket lines and blank lines.
///
/// Markdown is the one language that opts out of both (T13.4): its `[]` links
/// and its prose colons produce nothing but noise, while the structure a reader
/// actually wants to collapse — heading sections and fenced code blocks — is
/// invisible to the generic rules. `"markdown"` therefore routes to a dedicated
/// pair of rules; every other language keeps the generic behaviour unchanged.
///
/// Implementation (first-paint / memory fix): one forward pass over the
/// document's UTF-16 read through a fixed chunk buffer — no per-line `String`,
/// `Character` array or dedup set — run either to completion (`regions`), in
/// deadline-bounded slices (`FoldScan.advance`, driven by the analysis
/// scheduler), or over a window of header lines with a work budget (`window`).
/// The rules are evaluated on code units with an explicit grapheme check where
/// a combining mark could glue onto a structural character, so the output is
/// identical to the original `Character`-based scanner.
///
/// v1 trade-off: brackets and colons inside string literals or comments are
/// **not** excluded (that needs the tokenizer / precise lexing which folding
/// deliberately avoids). In practice mismatches are rare and merely offer an
/// extra fold handle; correctness of the text is never affected.
public enum FoldScanner {
    /// Computes every foldable region in `text`, sorted by start then end line
    /// and free of duplicates. `lineIndex` supplies line boundaries (the "one
    /// index, reused everywhere" structure) so we never recount newlines.
    ///
    /// `language` is the editor's language identifier (`""` = plain / unknown).
    /// Only `"markdown"` changes the outcome today: it swaps the bracket +
    /// indentation rules for the markdown-specific ones.
    public static func regions(text: String,
                               lineIndex: LineIndex,
                               language: String = "") -> [FoldRegion] {
        regions(in: text as NSString, lineIndex: lineIndex, language: language)
    }

    /// `regions(text:lineIndex:language:)` over an `NSString` (for example a
    /// text storage's backing string), read in place without copying.
    public static func regions(in ns: NSString,
                               lineIndex: LineIndex,
                               language: String = "") -> [FoldRegion] {
        // Consistency guard: the scanner trusts `lineIndex` offsets when reading
        // `ns`, and the two can transiently disagree (a gutter draw interleaved
        // with an edit transaction crashed exactly here on macOS 26 beta —
        // `characterAtIndex:` out of range, user crash report 2026-07-22).
        // Folding is cosmetic: skipping one scan and letting the next pass see
        // the re-synced pair is always safe; crashing never is.
        guard let scan = FoldScan(ns: ns, lineIndex: lineIndex, language: language) else { return [] }
        _ = scan.advance()
        return scan.isAborted ? [] : scan.regions
    }

    /// The regions headed inside `lines` (clamped to the document), computed by
    /// a scan that starts at the window (markdown: at the document start, since
    /// fence state depends on everything above) and stops as soon as every
    /// header in the window is settled, or after roughly `budget` UTF-16 code
    /// units of work. Resolved lines match `regions` exactly.
    public static func window(in ns: NSString,
                              lineIndex: LineIndex,
                              language: String = "",
                              lines: ClosedRange<Int>,
                              budget: Int) -> FoldWindow {
        let lineCount = lineIndex.lineCount
        let clamped = max(1, min(lines.lowerBound, lineCount))...max(1, min(lines.upperBound, lineCount))
        guard let scan = FoldScan(ns: ns, lineIndex: lineIndex, language: language, window: clamped) else {
            return FoldWindow(lines: clamped, regions: [], pendingLines: [], unreachedFrom: clamped.lowerBound)
        }
        _ = scan.advance(maxWork: max(1, budget))
        return scan.windowResult()
    }
}

// MARK: - Resumable scan

/// One fold scan as a resumable state machine (allocation-free per line).
///
/// `advance` processes UTF-16 code units until the document is done, a
/// deadline passes or a work budget is spent, and can be called again to
/// resume — the unit of resumption is a code unit for the generic rules (so
/// even a single multi-megabyte line is sliced) and a line for markdown.
///
/// The scan reads the live string and `LineIndex`; it must be discarded on
/// any character edit. As a safety net every `advance` re-checks the
/// string/index lengths and aborts (`isAborted`, empty result) on a mismatch.
final class FoldScan {
    private let ns: NSString
    private let lineIndex: LineIndex
    private let length: Int
    private let lineCount: Int
    private let markdown: Bool
    /// Header lines whose regions are wanted (the whole document for a full scan).
    private let window: ClosedRange<Int>
    private let isFullScan: Bool
    private var reader: UTF16Reader

    private(set) var isFinished = false
    private(set) var isAborted = false
    /// Output, in discovery order until `finish()` sorts and dedups it.
    private(set) var regions: [FoldRegion] = []

    // Current line and unit cursor.
    private var line: Int
    private var lineStart = 0
    private var lineEnd = 0
    private var pos = 0

    // Generic rules — per-line accumulators (reset by `beginLine`).
    private var inLeading = true
    private var indent = 0
    private var lastSig = -1           // position of the last unit that is not whitespace / terminator
    private var lastSigUnit: unichar = 0
    private var closerState: UInt8 = 0  // pure-closer automaton: 0 none, 1 closers, 2 trailing, 3 no

    // Generic rules — cross-line state.
    /// Open brackets, packed as `line << 1 | (brace ? 1 : 0)`.
    private var bracketStack: [Int] = []
    /// How many entries of `bracketStack` were opened on a `window` line.
    private var windowOpeners = 0
    /// Open colon headers (each pushed only for `window` lines), indents strictly increasing.
    private var indentStack: [(line: Int32, indent: Int32)] = []
    /// Last line so far that is neither blank nor a pure closing-bracket line.
    private var lastSubstantive = 0

    // Markdown — cross-line state.
    private var fence: (line: Int, marker: unichar, count: Int)?
    private var headingStack: [(line: Int32, level: Int8)] = []
    private var lastNonBlank = 0

    init?(ns: NSString, lineIndex: LineIndex, language: String, window: ClosedRange<Int>? = nil) {
        let length = ns.length
        guard lineIndex.length == length else { return nil }
        self.ns = ns
        self.lineIndex = lineIndex
        self.length = length
        self.lineCount = lineIndex.lineCount
        self.markdown = language.lowercased() == "markdown"
        self.window = window ?? 1...lineIndex.lineCount
        self.isFullScan = window == nil
        self.reader = UTF16Reader(ns, length: length)
        // Brackets and colon headers depend only on the text *below* them, so a
        // window scan starts at the window; markdown fence state depends on
        // everything above, so it always starts at the top.
        self.line = markdown ? 1 : self.window.lowerBound
        beginLine()
    }

    /// Runs until the scan finishes (returns `true`), the uptime `deadline`
    /// (nanoseconds, `DispatchTime` clock) passes, or `maxWork` code units have
    /// been examined (returns `false`; call again to resume).
    @discardableResult
    func advance(deadline: UInt64 = .max, maxWork: Int = .max) -> Bool {
        guard !isFinished else { return true }
        guard ns.length == length, lineIndex.length == length, lineIndex.lineCount == lineCount else {
            abort()
            return true
        }
        // Reserved on first use rather than at creation: an edit creates a scan
        // that the next keystroke usually cancels before it ever runs.
        if isFullScan, regions.capacity == 0 { regions.reserveCapacity(min(lineCount / 4, 1 << 20)) }
        return markdown ? advanceMarkdown(deadline: deadline, maxWork: maxWork)
                        : advanceGeneric(deadline: deadline, maxWork: maxWork)
    }

    private func abort() {
        isAborted = true
        isFinished = true
        regions = []
        bracketStack = []
        indentStack = []
        headingStack = []
    }

    /// Work units between deadline checks (~a few µs of scanning).
    private static let checkInterval = 4096

    private func beginLine() {
        let r = lineIndex.offsetRange(ofLine: line)
        lineStart = r.lowerBound
        lineEnd = r.upperBound
        pos = lineStart
        inLeading = true
        indent = 0
        lastSig = -1
        lastSigUnit = 0
        closerState = 0
    }

    // MARK: Generic (brackets + indentation)

    private func advanceGeneric(deadline: UInt64, maxWork: Int) -> Bool {
        var work = 0
        var nextCheck = min(Self.checkInterval, maxWork)
        while true {
            while pos < lineEnd {
                genericUnit(reader.unit(at: pos))
                pos += 1
                work += 1
                if work >= nextCheck {
                    if work >= maxWork { return false }
                    if deadline != .max, DispatchTime.now().uptimeNanoseconds >= deadline { return false }
                    nextCheck = min(work + Self.checkInterval, maxWork)
                }
            }
            endGenericLine()
            line += 1
            if line > lineCount || (line > window.upperBound && windowOpeners == 0 && indentStack.isEmpty) {
                finishGeneric()
                return true
            }
            beginLine()
            work += 8 // per-line overhead, so blank-line runs still yield
            if work >= nextCheck {
                if work >= maxWork { return false }
                if deadline != .max, DispatchTime.now().uptimeNanoseconds >= deadline { return false }
                nextCheck = min(work + Self.checkInterval, maxWork)
            }
        }
    }

    @inline(__always)
    private func genericUnit(_ c: unichar) {
        // Bracket pairing.
        switch c {
        case 0x7B, 0x5B: // '{' '['
            bracketStack.append(line << 1 | (c == 0x7B ? 1 : 0))
            if window.contains(line) { windowOpeners += 1 }
        case 0x7D, 0x5D: // '}' ']'
            // Match against the top of the stack only when the opener type
            // agrees; otherwise ignore this closer (v1: no error recovery for
            // unbalanced / string-embedded brackets).
            if let top = bracketStack.last, (top & 1 == 1) == (c == 0x7D) {
                bracketStack.removeLast()
                let openLine = top >> 1
                if window.contains(openLine) {
                    windowOpeners -= 1
                    // Keep both delimiter lines visible: hide the interior only,
                    // so a region needs at least one interior line.
                    if line - 1 > openLine {
                        regions.append(FoldRegion(startLine: openLine, endLine: line - 1))
                    }
                }
            }
        default:
            break
        }

        // Line shape for the indentation rule.
        if inLeading {
            if c == 0x20 || c == 0x09 {
                indent += 1
                return
            }
            inLeading = false
            // A space glued to a following combining mark is not a " "
            // character, so it is not indentation either.
            if c >= 0x300, indent > 0, pos > lineStart, reader.unit(at: pos - 1) == 0x20,
               FoldText.joins(" ", FoldText.scalar(startingAt: pos, end: lineEnd, &reader)) {
                indent -= 1
            }
        }
        let isSpace = c == 0x20 || c == 0x09
        let isTerminator = c == 0x0A || c == 0x0D
        if !isSpace && !isTerminator {
            lastSig = pos
            lastSigUnit = c
        }
        // Pure closer: closers, then only whitespace / terminators / ',' / ';'.
        if closerState != 3 {
            if c == 0x29 || c == 0x5D || c == 0x7D {        // ')' ']' '}'
                closerState = closerState <= 1 ? 1 : 3
            } else if isSpace || isTerminator || c == 0x2C || c == 0x3B { // ',' ';'
                closerState = closerState == 1 || closerState == 2 ? 2 : 3
            } else {
                closerState = 3
            }
        }
    }

    private func endGenericLine() {
        guard lastSig >= 0 else { return } // blank: neither ends a block nor counts as its last line
        let lineIndent = indent
        // A non-blank line at or left of a header's indentation closes it. The
        // block runs to the last substantive line before here — blank lines and
        // pure closing lines (`]`, `},`, `});`) are pulled back over, matching the
        // bracket rule, which keeps such a closer visible.
        while let top = indentStack.last, Int(top.indent) >= lineIndent {
            indentStack.removeLast()
            if lastSubstantive > Int(top.line) {
                regions.append(FoldRegion(startLine: Int(top.line), endLine: lastSubstantive))
            }
        }
        let pureCloser = closerState == 1 || closerState == 2
        if !pureCloser { lastSubstantive = line }
        if lastSigUnit == 0x3A, window.contains(line), standsAlone(colonAt: lastSig) {
            indentStack.append((Int32(clamping: line), Int32(clamping: lineIndent)))
        }
    }

    /// The `:` at `p` is a character of its own (not glued to a preceding
    /// prepend mark); trailing whitespace never glues to it.
    private func standsAlone(colonAt p: Int) -> Bool {
        guard p > lineStart else { return true }
        let prev = reader.unit(at: p - 1)
        guard prev >= 0x300 else { return true }
        return !FoldText.joins(FoldText.scalar(endingAt: p - 1, start: lineStart, &reader), ":")
    }

    private func finishGeneric() {
        // Blocks still open at the end of the document run to its last
        // substantive line; unmatched openers produce nothing.
        while let top = indentStack.popLast() {
            if lastSubstantive > Int(top.line) {
                regions.append(FoldRegion(startLine: Int(top.line), endLine: lastSubstantive))
            }
        }
        finish()
    }

    // MARK: Markdown (T13.4)

    /// The two rules VS Code's markdown folding offers, and nothing else:
    ///
    /// - **Heading sections**: an ATX heading (`#` … `######`) folds down to the
    ///   line before the next heading of the *same or lower* level, or to the end
    ///   of the document. Sub-headings nest naturally because a deeper level
    ///   stops only at an equally deep (or shallower) one. Blank lines before
    ///   the next heading (or at EOF) separate sections rather than belong to one.
    /// - **Fenced code blocks**: ``` ``` ``` or `~~~` opens a fence; the matching
    ///   closing fence line stays visible (`endLine = closeLine - 1`). Inside a
    ///   fence only the same character closes it and no heading is recognised.
    ///   An unclosed fence runs to the document's last non-blank line.
    ///
    /// Setext headings (`===` / `---` underlines) are deliberately not detected:
    /// they need a look-ahead that also has to exclude `---` front-matter fences,
    /// thematic breaks and table separators, for a form that is rare in practice.
    private func advanceMarkdown(deadline: UInt64, maxWork: Int) -> Bool {
        var work = 0
        var nextCheck = min(Self.checkInterval, maxWork)
        while true {
            markdownLine()
            work += (lineEnd - lineStart) + 8
            line += 1
            if line > lineCount || (line > window.upperBound && headingStack.isEmpty
                                    && !(fence.map { window.contains($0.line) } ?? false)) {
                finishMarkdown()
                return true
            }
            beginLine()
            if work >= nextCheck {
                if work >= maxWork { return false }
                if deadline != .max, DispatchTime.now().uptimeNanoseconds >= deadline { return false }
                nextCheck = min(work + Self.checkInterval, maxWork)
            }
        }
    }

    private func markdownLine() {
        let s = lineStart, e = lineEnd
        if let open = fence {
            if FoldText.fenceCloses(s, e, marker: open.marker, count: open.count, &reader) {
                if window.contains(open.line), line - 1 > open.line {
                    regions.append(FoldRegion(startLine: open.line, endLine: line - 1))
                }
                fence = nil
            }
        } else if let opener = FoldText.fenceOpener(s, e, &reader) {
            fence = (line, opener.marker, opener.count)
        } else if let level = FoldText.headingLevel(s, e, &reader) {
            while let top = headingStack.last, Int(top.level) >= level {
                headingStack.removeLast()
                let end = max(Int(top.line), lastNonBlank)
                if end > Int(top.line) { regions.append(FoldRegion(startLine: Int(top.line), endLine: end)) }
            }
            if window.contains(line) { headingStack.append((Int32(clamping: line), Int8(level))) }
        }
        if !FoldText.isBlank(s, e, &reader) { lastNonBlank = line }
    }

    private func finishMarkdown() {
        if let open = fence, window.contains(open.line) {
            let end = max(open.line, lastNonBlank)
            if end > open.line { regions.append(FoldRegion(startLine: open.line, endLine: end)) }
        }
        while let top = headingStack.popLast() {
            let end = max(Int(top.line), lastNonBlank)
            if end > Int(top.line) { regions.append(FoldRegion(startLine: Int(top.line), endLine: end)) }
        }
        finish()
    }

    // MARK: Result

    /// Sorts and dedups `regions` in place (a brace and an indent rule can
    /// agree), then drops a full scan's spare capacity.
    private func finish() {
        isFinished = true
        regions.sort(by: FoldRegion.precedes)
        var kept = 0
        for i in regions.indices where kept == 0 || regions[kept - 1] != regions[i] {
            regions[kept] = regions[i]
            kept += 1
        }
        regions.removeLast(regions.count - kept)
        if isFullScan, regions.capacity > regions.count + regions.count / 4 + 64 {
            regions = regions.withUnsafeBufferPointer { Array($0) }
        }
        bracketStack = []
        indentStack = []
        headingStack = []
    }

    /// The window outcome. Before the scan finished, header lines with an
    /// unsettled candidate (an open bracket, colon block, heading or fence)
    /// and the lines never reached are unresolved, and any region already
    /// found for an unresolved line is withheld, so a resolved line always
    /// carries its complete set.
    func windowResult() -> FoldWindow {
        if isAborted {
            return FoldWindow(lines: window, regions: [], pendingLines: [], unreachedFrom: window.lowerBound)
        }
        if isFinished {
            return FoldWindow(lines: window, regions: regions, pendingLines: [], unreachedFrom: window.upperBound + 1)
        }
        var pending: [Int] = []
        for packed in bracketStack where window.contains(packed >> 1) { pending.append(packed >> 1) }
        for header in indentStack { pending.append(Int(header.line)) }
        for heading in headingStack { pending.append(Int(heading.line)) }
        if let open = fence, window.contains(open.line) { pending.append(open.line) }
        // The current line is only partly processed (generic) or not yet
        // processed (markdown: `line` is the next line to read).
        let unreachedFrom = max(window.lowerBound, min(line, window.upperBound + 1))
        pending.sort()
        var found = regions.filter { region in
            region.startLine < unreachedFrom && pending.binarySearchContains(region.startLine) == false
        }
        found.sort(by: FoldRegion.precedes)
        var kept = 0
        for i in found.indices where kept == 0 || found[kept - 1] != found[i] {
            found[kept] = found[i]
            kept += 1
        }
        found.removeLast(found.count - kept)
        return FoldWindow(lines: window, regions: found, pendingLines: pending, unreachedFrom: unreachedFrom)
    }
}

private extension Array where Element == Int {
    func binarySearchContains(_ value: Int) -> Bool {
        var lo = 0, hi = count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if self[mid] < value { lo = mid + 1 } else { hi = mid }
        }
        return lo < count && self[lo] == value
    }
}

// MARK: - UTF-16 access

/// Chunked, copy-in reader over an `NSString`'s UTF-16: one fixed buffer, filled
/// with `getCharacters(_:range:)`, so a scan costs no per-line allocation and no
/// per-unit Objective-C message. Moves forward by default; a read before the
/// buffer refills the chunk that *ends* at it, so short backward walks stay cheap.
struct UTF16Reader {
    private let ns: NSString
    private let length: Int
    private var buffer: [unichar]
    private var bufferStart = 0
    private var bufferCount = 0
    private static let chunk = 8192

    init(_ ns: NSString, length: Int) {
        self.ns = ns
        self.length = length
        self.buffer = [unichar](repeating: 0, count: min(Self.chunk, max(length, 1)))
    }

    @inline(__always)
    mutating func unit(at i: Int) -> unichar {
        let k = i &- bufferStart
        if k >= 0, k < bufferCount { return buffer[k] }
        return refill(at: i)
    }

    private mutating func refill(at i: Int) -> unichar {
        // Out of range only if the caller's bounds are stale; folding is
        // cosmetic, so answer a newline rather than trap.
        guard i >= 0, i < length else { return 0x0A }
        let capacity = buffer.count
        let start = i < bufferStart ? max(0, i - capacity + 1) : i
        let count = min(capacity, length - start)
        let ns = self.ns
        buffer.withUnsafeMutableBufferPointer { p in
            ns.getCharacters(p.baseAddress!, range: NSRange(location: start, length: count))
        }
        bufferStart = start
        bufferCount = count
        return buffer[i - start]
    }
}

/// Per-line predicates of the markdown rules plus the grapheme helpers, all on
/// a line's UTF-16 range `[s, e)` (terminator included).
///
/// The original scanner compared `Character`s; a combining mark (or a prepend
/// mark) glued to a structural ASCII character made that character compare
/// unequal. The code-unit versions reproduce that with `joins`, which is only
/// consulted when a neighbouring unit is `>= U+0300` (no combining, prepend or
/// joiner mark is lower), so ASCII and CJK text never pay for it.
enum FoldText {
    /// True when `a` followed by `b` forms a single extended grapheme cluster.
    /// Both fit in a small (inline) string, so this does not allocate.
    static func joins(_ a: Unicode.Scalar, _ b: Unicode.Scalar) -> Bool {
        var scalars = String.UnicodeScalarView()
        scalars.append(a)
        scalars.append(b)
        return String(scalars).count == 1
    }

    /// The scalar whose first code unit is at `p` (surrogate pairs decoded; a
    /// lone surrogate reads as U+FFFD, as it does once bridged to `String`).
    static func scalar(startingAt p: Int, end: Int, _ reader: inout UTF16Reader) -> Unicode.Scalar {
        let u = reader.unit(at: p)
        if UTF16.isLeadSurrogate(u), p + 1 < end {
            let v = reader.unit(at: p + 1)
            if UTF16.isTrailSurrogate(v) { return surrogatePair(u, v) }
        }
        return Unicode.Scalar(u) ?? "\u{FFFD}"
    }

    /// The scalar whose last code unit is at `p`.
    static func scalar(endingAt p: Int, start: Int, _ reader: inout UTF16Reader) -> Unicode.Scalar {
        let v = reader.unit(at: p)
        if UTF16.isTrailSurrogate(v), p - 1 >= start {
            let u = reader.unit(at: p - 1)
            if UTF16.isLeadSurrogate(u) { return surrogatePair(u, v) }
        }
        return Unicode.Scalar(v) ?? "\u{FFFD}"
    }

    private static func surrogatePair(_ lead: unichar, _ trail: unichar) -> Unicode.Scalar {
        let value = 0x10000 + ((UInt32(lead) - 0xD800) << 10) + (UInt32(trail) - 0xDC00)
        return Unicode.Scalar(value) ?? "\u{FFFD}"
    }

    /// The ASCII character at `p` is a grapheme of its own (no combining mark
    /// after it, no prepend mark before it).
    static func standsAlone(_ p: Int, _ s: Int, _ e: Int, _ reader: inout UTF16Reader) -> Bool {
        let c = Unicode.Scalar(reader.unit(at: p)) ?? "\u{FFFD}"
        if p + 1 < e, reader.unit(at: p + 1) >= 0x300, joins(c, scalar(startingAt: p + 1, end: e, &reader)) {
            return false
        }
        if p - 1 >= s, reader.unit(at: p - 1) >= 0x300, joins(scalar(endingAt: p - 1, start: s, &reader), c) {
            return false
        }
        return true
    }

    /// True when the line has no non-whitespace character (terminator aside).
    static func isBlank(_ s: Int, _ e: Int, _ reader: inout UTF16Reader) -> Bool {
        var p = s
        while p < e {
            let c = reader.unit(at: p)
            if c != 0x20, c != 0x09, c != 0x0A, c != 0x0D { return false }
            p += 1
        }
        return true
    }

    /// ATX heading level (1…6), or `nil` when the line is not a heading. Up to
    /// three leading spaces are allowed (CommonMark; a fourth makes it an
    /// indented code block) and the hashes must be followed by a space or tab.
    static func headingLevel(_ s: Int, _ e: Int, _ reader: inout UTF16Reader) -> Int? {
        var p = s
        while p < e, reader.unit(at: p) == 0x20 { p += 1 }
        guard p - s <= 3 else { return nil }
        var level = 0
        while p < e, reader.unit(at: p) == 0x23 { level += 1; p += 1 } // '#'
        guard (1...6).contains(level), p < e else { return nil }
        let c = reader.unit(at: p)
        guard c == 0x20 || c == 0x09 else { return nil }
        if c == 0x20, !standsAlone(p, s, e, &reader) { return nil }
        return level
    }

    /// Opening fence: at least three backticks or tildes, indented by at most
    /// three spaces. An info string (```` ```swift ````) may follow, but a
    /// backtick fence's info string must not contain another backtick
    /// (CommonMark), which keeps inline code spans like `` `a` `` from opening a fence.
    static func fenceOpener(_ s: Int, _ e: Int, _ reader: inout UTF16Reader) -> (marker: unichar, count: Int)? {
        var p = s
        while p < e, reader.unit(at: p) == 0x20 { p += 1 }
        guard p - s <= 3, p < e else { return nil }
        let marker = reader.unit(at: p)
        guard marker == 0x60 || marker == 0x7E else { return nil } // '`' '~'
        var q = p
        while q < e, reader.unit(at: q) == marker { q += 1 }
        var count = q - p
        // The last marker glued to a combining mark is not a marker character.
        if !standsAlone(q - 1, s, e, &reader) { count -= 1 }
        guard count >= 3 else { return nil }
        if marker == 0x60 {
            var r = p + count
            while r < e {
                if reader.unit(at: r) == 0x60, standsAlone(r, s, e, &reader) { return nil }
                r += 1
            }
        }
        return (marker, count)
    }

    /// True when the line closes a fence of `marker` × `count`: nothing but the
    /// marker, at least `count` of them (surrounding whitespace / terminator
    /// ignored).
    static func fenceCloses(_ s: Int, _ e: Int, marker: unichar, count: Int, _ reader: inout UTF16Reader) -> Bool {
        var b = e
        while b > s {
            let c = reader.unit(at: b - 1)
            guard c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D else { break }
            b -= 1
        }
        var a = s
        while a < b {
            let c = reader.unit(at: a)
            guard c == 0x20 || c == 0x09 else { break }
            a += 1
        }
        guard b - a >= count else { return false }
        for p in a..<b where reader.unit(at: p) != marker { return false }
        return true
    }
}
