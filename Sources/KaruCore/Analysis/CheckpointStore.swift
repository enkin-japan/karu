import Foundation

/// Lexical state carried across lines, as stored in a checkpoint. One case per
/// tokenizer that keeps cross-line state.
public enum LexicalState: Sendable, Equatable {
    case python(PythonTokenizer.State)
    /// The generic scanner's state for a profiled language (M17 T17.2).
    case generic(LexicalScanState)
}

/// Sparse lexical checkpoints for one document (M17 T17.1, plan §3 "词法检查点").
///
/// Roughly one entry every `spacing` UTF-16 units, each at a **line start**,
/// or at a scanner safe point inside a line longer than `spacing` (generic
/// scanner only; see `LexicalScanner`, long-line slicing), so a pass that
/// begins far into a large file resumes from the nearest checkpoint instead
/// of rescanning from offset 0. A 10 MB document holds about 160 entries of a
/// few dozen bytes each; tokens themselves are never cached.
///
/// **Invalidation** keeps every entry before the edited logical line (they
/// depend only on text that did not change — a safe point's state depends
/// only on its own line up to it) and drops the rest of the verified entries,
/// including every entry inside the edited line — except in a line longer
/// than `2 × editMargin`, where in-line safe points more than `editMargin`
/// before the edit stay (T17.15d-A: a scanner reads at most `embedWindow`
/// units past a stop, so they cannot depend on the edit; a single-line
/// document no longer loses every checkpoint to a keystroke at its end).
///
/// **Pending entries** (T17.15d-A): the dropped entries after the edit are
/// not discarded but kept as `pending` — offsets mapped through the edit,
/// states as recorded before it — beyond `editMargin` of the edit's end. A
/// walk (`walk`) from a verified entry that reaches a pending entry with the
/// same state there has re-synchronised: the text from there on is unchanged
/// (the margin covers every scanner lookback), so that entry and every
/// pending entry up to the next unresolved edit (`boundaries`) become
/// verified again. An edit that does not change the lexical state downstream
/// (almost every keystroke) therefore costs one chunk of rescanning, not the
/// rest of the document. Only verified entries are ever resumed from.
///
/// Invariant: every verified entry lies before the first boundary, every
/// pending entry after it. Pure value type: no AppKit, `Sendable`.
public struct CheckpointStore: Sendable {
    /// UTF-16 units between checkpoints (≈ 64 KB).
    public static let spacing = 65_536

    /// Units around an edit within which in-line safe points (before it) and
    /// pending entries (after it) are not trusted: a scanner looks at most
    /// `LexicalScanner.embedWindow` (16 K) units past a stop and at most
    /// 4 K units back (tag / fence / block-scalar reaches).
    public static let editMargin = 32_768

    /// Verified entries: ascending offsets, each at a line start or an
    /// in-line safe point, with the state the current text gives there.
    public private(set) var entries: [(offset: Int, state: LexicalState)] = []

    /// Entries recorded before an edit, offsets mapped through the edits
    /// since, states not yet confirmed against the current text (ascending).
    public private(set) var pending: [(offset: Int, state: LexicalState)] = []

    /// Offsets (current text) where an edit invalidated entries and no walk
    /// has passed since, ascending. A confirmed pending entry vouches only for
    /// the pending entries before the next boundary.
    private(set) var boundaries: [Int] = []

    public init() {}

    /// No entry of either kind is held.
    public var isEmpty: Bool { entries.isEmpty && pending.isEmpty }

    /// The verified entry with the greatest offset `<= offset`, or `nil` if none.
    public func nearest(atOrBefore offset: Int) -> (offset: Int, state: LexicalState)? {
        // Binary search for the last entry whose offset <= `offset`.
        var low = 0
        var high = entries.count
        while low < high {
            let mid = (low + high) / 2
            if entries[mid].offset <= offset { low = mid + 1 } else { high = mid }
        }
        return low == 0 ? nil : entries[low - 1]
    }

    /// Inserts a verified checkpoint, keeping offsets ascending. Ignored when
    /// an existing neighbour lies within `spacing / 2` (so the store stays
    /// sparse whichever order passes record in) or the offset is negative.
    public mutating func record(offset: Int, state: LexicalState) {
        guard offset >= 0 else { return }
        var low = 0
        var high = entries.count
        while low < high {
            let mid = (low + high) / 2
            if entries[mid].offset < offset { low = mid + 1 } else { high = mid }
        }
        let index = low
        let minimumGap = Self.spacing / 2
        if index > 0, offset - entries[index - 1].offset < minimumGap { return }
        if index < entries.count, entries[index].offset - offset < minimumGap { return }
        entries.insert((offset, state), at: index)
    }

    /// Invalidates for an edit that replaced `editedRange.length -
    /// changeInLength` units at `editedRange.location` with
    /// `editedRange.length` units; `text` is the **post-edit** text.
    ///
    /// The cut is the start of the logical line containing
    /// `max(0, editedRange.location - 1)` — the `- 1` reaches back over the
    /// previous line terminator, which covers a CR and an LF merging into
    /// CRLF (or a CRLF being split) at the edit boundary — or, in a line
    /// longer than `2 × editMargin`, `editMargin` units before the edit.
    /// Verified entries before the cut stay; those after the edit's end
    /// become pending (mapped through the edit) when they lie at least
    /// `editMargin` past it; the rest are dropped. Pending entries are mapped
    /// the same way.
    public mutating func invalidate(editedRange: NSRange, changeInLength: Int, in text: NSString) {
        guard !isEmpty else { return }
        let location = editedRange.location
        let newEnd = NSMaxRange(editedRange)
        let oldEnd = location + editedRange.length - changeInLength
        let probe = max(0, location - 1)
        var cut: Int
        if text.length == 0 || probe >= text.length {
            // Clamp: an edit at (or a deletion through) the end. The last
            // line's start is still the right boundary.
            cut = text.length == 0
                ? 0
                : text.lineRange(for: NSRange(location: text.length - 1, length: 0)).location
        } else {
            cut = text.lineRange(for: NSRange(location: probe, length: 0)).location
        }
        // A long edited line: its in-line safe points well before the edit
        // depend only on text before them (plus a bounded look-ahead).
        if probe - cut > 2 * Self.editMargin { cut = probe - Self.editMargin }

        let keep = Self.lowerBound(cut, in: entries)
        let pendingKeep = Self.lowerBound(cut, in: pending)
        let trusted = newEnd + Self.editMargin
        var moved: [(offset: Int, state: LexicalState)] = []
        for entry in entries[keep...] where entry.offset >= oldEnd {
            let mapped = entry.offset + changeInLength
            if mapped >= trusted { moved.append((mapped, entry.state)) }
        }
        for entry in pending[pendingKeep...] where entry.offset >= oldEnd {
            let mapped = entry.offset + changeInLength
            if mapped >= trusted { moved.append((mapped, entry.state)) }
        }
        if keep < entries.count { entries.removeSubrange(keep...) }
        pending.removeSubrange(pendingKeep...)
        // Verified entries precede every pending one, so `moved` is ascending.
        pending += moved

        var mappedBoundaries = boundaries.filter { $0 < cut }
        mappedBoundaries.append(cut)
        for boundary in boundaries where boundary > oldEnd {
            mappedBoundaries.append(boundary + changeInLength)
        }
        boundaries = mappedBoundaries
        if pending.isEmpty { boundaries.removeAll() }
    }

    public mutating func removeAll() {
        entries.removeAll()
        pending.removeAll()
        boundaries.removeAll()
    }

    // MARK: - Walking (T17.15d-A)

    /// Resumes from the nearest verified checkpoint at or before `start`
    /// whose state is of this tokenizer's kind (else from offset 0 with
    /// `initial`) and walks forward in line-aligned chunks of about
    /// `spacing`, recording a checkpoint at each chunk boundary, until `start`
    /// is within one chunk. A pending entry inside the next chunk is walked to
    /// exactly; the same state there confirms it and the pending entries up
    /// to the next boundary, and the walk continues from the last verified
    /// entry at or before `start`.
    ///
    /// Inside a line longer than the spacing, a tokenizer that can stop at a
    /// safe point steps to the safe point at or after `offset + spacing`
    /// (bounded by `stepEnd`) and records a checkpoint there; without it
    /// (Python) the chunk runs to the line end.
    ///
    /// `advance(from, to, &state)` advances over `[from, to)` (to a line
    /// start or a safe point); `advanceToSafePoint(from, to, target, &state)`
    /// advances to the first safe point at or after `target` (not past `to`)
    /// and returns it — nil for a tokenizer without safe points (Python).
    /// With a `deadline` (uptime ns) the walk stops (`finished` false) once
    /// the next chunk, taken to last as long as the previous one, would end
    /// past it — always after at least one chunk. Returns the offset and state reached
    /// and the offset the walk resumed at.
    // swiftlint:disable:next function_parameter_count function_body_length cyclomatic_complexity
    mutating func walk<State>(toward start: Int, in ns: NSString, stepEnd: Int, initial: State,
                              unwrap: (LexicalState) -> State?,
                              wrap: (State) -> LexicalState,
                              advance: (Int, Int, inout State) -> Void,
                              advanceToSafePoint: ((Int, Int, Int, inout State) -> Int)?,
                              deadline: UInt64? = nil)
        -> (offset: Int, state: State, resumedAt: Int, finished: Bool) {
        let spacing = Self.spacing
        var offset = 0
        var state = initial
        if let checkpoint = nearest(atOrBefore: start), let saved = unwrap(checkpoint.state) {
            offset = checkpoint.offset
            state = saved
        }
        let resumedAt = offset
        var steps = 0
        var stepStart: UInt64 = 0
        var lastStep: UInt64 = 0
        while start - offset > spacing {
            // At least one step per call, so a late slice still progresses;
            // after that, stop when the next step (assumed as long as the
            // last) would end past the deadline, so a slice of slow chunks
            // (a long JSON line) does not overshoot by a whole chunk.
            if let deadline {
                let now = DispatchTime.now().uptimeNanoseconds
                if steps > 0 {
                    lastStep = now &- stepStart
                    if now &+ lastStep >= deadline { return (offset, state, resumedAt, false) }
                }
                stepStart = now
            }
            steps += 1
            // A pending entry within this chunk: walk to it and compare.
            let candidateIndex = Self.lowerBound(offset + 1, in: pending)
            if candidateIndex < pending.count, pending[candidateIndex].offset < start,
               pending[candidateIndex].offset <= offset + spacing {
                let candidate = pending[candidateIndex]
                var probe = state
                var reached = candidate.offset
                if Self.isLineStart(candidate.offset, in: ns) {
                    advance(offset, candidate.offset, &probe)
                } else if let advanceToSafePoint = advanceToSafePoint {
                    reached = advanceToSafePoint(offset, stepEnd, candidate.offset, &probe)
                } else {
                    // Unreachable exactly without safe points: forget it.
                    pending.remove(at: candidateIndex)
                    continue
                }
                guard reached > offset else { break }
                if reached == candidate.offset, wrap(probe) == candidate.state {
                    confirm(from: candidateIndex)
                    if let checkpoint = nearest(atOrBefore: start), checkpoint.offset >= reached,
                       let saved = unwrap(checkpoint.state) {
                        offset = checkpoint.offset
                        state = saved
                    } else {
                        offset = reached
                        state = probe
                    }
                    continue
                }
                // Diverged: the walked state is the true one there.
                passed(reached)
                if reached < start { record(offset: reached, state: wrap(probe)) }
                offset = reached
                state = probe
                continue
            }
            // The line start at or before `offset + spacing` (found by a
            // bounded backward search, so a long line is not walked).
            var next: Int
            if let lineBreak = HighlightEngine.lastLineBreak(in: ns, from: offset, to: offset + spacing) {
                next = HighlightEngine.lineEnd(afterTerminatorAt: lineBreak, in: ns)
            } else if let advanceToSafePoint = advanceToSafePoint {
                // Inside a line longer than the spacing: the first safe point
                // after `offset + spacing` — half that under a deadline, so a
                // slice of a slow long line (minified JSON) overshoots by at
                // most half a chunk (checkpoints there sit `spacing / 2`
                // apart, which `record` accepts).
                let reach = deadline == nil ? spacing : spacing / 2
                next = advanceToSafePoint(offset, stepEnd, offset + reach, &state)
                guard next > offset else { break }
                passed(next)
                if next < start { record(offset: next, state: wrap(state)) }
                offset = next
                continue
            } else {
                // No safe points: the end of that line instead.
                next = NSMaxRange(ns.lineRange(for: NSRange(location: offset, length: 0)))
            }
            guard next > offset, next < start else { break }
            advance(offset, next, &state)
            passed(next)
            record(offset: next, state: wrap(state))
            offset = next
        }
        return (offset, state, resumedAt, true)
    }

    /// The pending entry at `index` matched: it and the pending entries up to
    /// the next boundary after it become verified; boundaries at or before it
    /// are resolved.
    private mutating func confirm(from index: Int) {
        let offset = pending[index].offset
        let limit = boundaries.first { $0 > offset } ?? Int.max
        boundaries.removeAll { $0 <= offset }
        var end = index
        while end < pending.count, pending[end].offset < limit { end += 1 }
        for entry in pending[index..<end] { record(offset: entry.offset, state: entry.state) }
        pending.removeSubrange(..<end)
        if pending.isEmpty { boundaries.removeAll() }
    }

    /// A walk reached `offset` with the true state: pending entries and
    /// boundaries at or before it are superseded.
    private mutating func passed(_ offset: Int) {
        guard !pending.isEmpty || !boundaries.isEmpty else { return }
        let drop = Self.lowerBound(offset + 1, in: pending)
        if drop > 0 { pending.removeSubrange(..<drop) }
        boundaries.removeAll { $0 <= offset }
        if pending.isEmpty { boundaries.removeAll() }
    }

    /// First index whose offset is `>= offset`.
    private static func lowerBound(_ offset: Int, in list: [(offset: Int, state: LexicalState)]) -> Int {
        var low = 0
        var high = list.count
        while low < high {
            let mid = (low + high) / 2
            if list[mid].offset < offset { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Whether `offset` starts a line (after LF, or after a CR not followed
    /// by LF there).
    static func isLineStart(_ offset: Int, in ns: NSString) -> Bool {
        guard offset > 0, offset <= ns.length else { return offset == 0 }
        let previous = ns.character(at: offset - 1)
        if previous == 13 { return offset == ns.length || ns.character(at: offset) != 10 }
        return HighlightEngine.isLineBreak(previous)
    }
}
