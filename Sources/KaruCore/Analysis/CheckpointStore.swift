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
/// Invalidation keeps every entry before the edited logical line (they depend
/// only on text that did not change — a safe point's state depends only on
/// its own line up to it) and drops the rest, including every entry inside
/// the edited line. Pure value type: no AppKit, `Sendable`.
public struct CheckpointStore: Sendable {
    /// UTF-16 units between checkpoints (≈ 64 KB).
    public static let spacing = 65_536

    /// Ascending offsets, each at a line start or an in-line safe point.
    public private(set) var entries: [(offset: Int, state: LexicalState)] = []

    public init() {}

    /// The entry with the greatest offset `<= offset`, or `nil` if none.
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

    /// Inserts a checkpoint, keeping offsets ascending. Ignored when an
    /// existing neighbour lies within `spacing / 2` (so the store stays sparse
    /// whichever order passes record in) or the offset is negative.
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

    /// Drops every entry at or after the start of the logical line containing
    /// `max(0, editedRange.location - 1)` in the **post-edit** `text`. The `- 1`
    /// reaches back over the previous line terminator, which covers a CR and an
    /// LF merging into CRLF (or a CRLF being split) at the edit boundary.
    /// Entries before that line precede the edit, so they need no shifting.
    public mutating func invalidate(editedRange: NSRange, changeInLength: Int, in text: NSString) {
        guard !entries.isEmpty else { return }
        let probe = max(0, editedRange.location - 1)
        let lineStart: Int
        if text.length == 0 || probe >= text.length {
            // Clamp: an edit at (or a deletion through) the end. The last
            // line's start is still the right boundary.
            lineStart = text.length == 0
                ? 0
                : text.lineRange(for: NSRange(location: text.length - 1, length: 0)).location
        } else {
            lineStart = text.lineRange(for: NSRange(location: probe, length: 0)).location
        }
        // Keep the prefix strictly before `lineStart`.
        var keep = 0
        var high = entries.count
        while keep < high {
            let mid = (keep + high) / 2
            if entries[mid].offset < lineStart { keep = mid + 1 } else { high = mid }
        }
        if keep < entries.count { entries.removeSubrange(keep...) }
    }

    public mutating func removeAll() {
        entries.removeAll()
    }
}
