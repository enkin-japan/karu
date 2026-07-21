import Foundation

/// Newline offset index: the single shared "one index, reused everywhere"
/// structure mandated by the architecture (see ARCHITECTURE.md §3.3).
///
/// It stores, for every logical line, the UTF-16 (NSString) offset at which
/// that line begins. A line boundary is created immediately after each `\n`.
/// A trailing `\n` therefore produces a final empty line, matching how editors
/// present `"a\n"` as line 1 (`a`) plus an empty line 2.
///
/// The index is a reference type so a single instance can be shared by the
/// gutter, folding, and search without copying (10^5 lines ≈ 800 KB).
public final class LineIndex {
    /// Start offset (UTF-16) of each line. `starts[0]` is always 0.
    /// `internal` so tests can assert against it under `@testable import`.
    private(set) var starts: [Int]

    /// Total length of the indexed text in UTF-16 code units.
    private(set) var length: Int

    /// Builds the index for `text` in one pass.
    public init(text: String) {
        self.starts = [0]
        self.length = 0
        rebuild(text as NSString)
    }

    // MARK: - Queries

    /// Number of logical lines (always ≥ 1).
    public var lineCount: Int { starts.count }

    /// 1-based line number containing `offset` (binary search).
    /// `offset` is clamped to `0...length`, so out-of-range values return the
    /// first / last line rather than trapping.
    public func lineNumber(forOffset offset: Int) -> Int {
        let clamped = min(max(offset, 0), length)
        return Self.lastIndex(in: starts, lessThanOrEqualTo: clamped) + 1
    }

    /// UTF-16 offset range of the 1-based line `line`, terminator included.
    /// Returns `0..<0` for out-of-range line numbers.
    public func offsetRange(ofLine line: Int) -> Range<Int> {
        guard line >= 1, line <= starts.count else { return 0..<0 }
        let lower = starts[line - 1]
        let upper = line < starts.count ? starts[line] : length
        return lower..<upper
    }

    // MARK: - Mutation

    /// Incrementally updates the index after an edit.
    ///
    /// - Parameters:
    ///   - text: the *new* full text after the edit.
    ///   - editedRange: the affected range in the *new* text coordinates
    ///     (as delivered by `NSTextStorage.editedRange`).
    ///   - changeInLength: length delta (new − old); negative for deletions.
    ///
    /// Only the line span touched by the edit is rescanned; every boundary
    /// after it is kept and shifted by `changeInLength`.
    public func update(text: String, editedRange: NSRange, changeInLength delta: Int) {
        let ns = text as NSString
        let newLen = ns.length
        let a = editedRange.location
        let oldEnd = a + (editedRange.length - delta) // end of edit in OLD coords

        // Defend against inconsistent inputs by falling back to a full rebuild.
        // The pre-edit length implied by the delta must match what we hold, and
        // the edit must sit within bounds.
        guard editedRange.location >= 0,
              editedRange.length >= 0,
              a <= newLen,
              oldEnd >= a,
              oldEnd <= length,
              newLen - delta == length
        else {
            rebuild(ns)
            return
        }

        let first = Self.lastIndex(in: starts, lessThanOrEqualTo: a)
        let regionStart = starts[first]

        // First existing boundary strictly after the edited region; it and
        // everything past it survive unchanged (only shifted by `delta`).
        let afterIdx = Self.lastIndex(in: starts, lessThanOrEqualTo: oldEnd) + 1
        let hasTail = afterIdx < starts.count
        let regionEndNew = hasTail ? starts[afterIdx] + delta : newLen

        // Prefix: boundaries at/before the region start are untouched.
        var newStarts = Array(starts[0...first])

        // Middle: rescan the affected span in the new text. When a tail exists,
        // stop before its terminator (regionEndNew - 1) so we don't duplicate
        // the boundary the tail already provides.
        let scanEnd = hasTail ? regionEndNew - 1 : regionEndNew
        var i = regionStart
        while i < scanEnd {
            if ns.character(at: i) == 0x0A {
                newStarts.append(i + 1)
            }
            i += 1
        }

        // Tail: shift surviving boundaries.
        if hasTail {
            for k in afterIdx..<starts.count {
                newStarts.append(starts[k] + delta)
            }
        }

        starts = newStarts
        length = newLen
    }

    // MARK: - Internals

    private func rebuild(_ ns: NSString) {
        var s = [0]
        let len = ns.length
        var i = 0
        while i < len {
            if ns.character(at: i) == 0x0A {
                s.append(i + 1)
            }
            i += 1
        }
        starts = s
        length = len
    }

    /// Index of the last element `<= value` in the ascending array `arr`.
    /// `arr` is non-empty and `arr[0] == 0 <= value` (value is clamped ≥ 0),
    /// so the result is always valid.
    private static func lastIndex(in arr: [Int], lessThanOrEqualTo value: Int) -> Int {
        var lo = 0
        var hi = arr.count - 1
        var ans = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if arr[mid] <= value {
                ans = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return ans
    }
}
