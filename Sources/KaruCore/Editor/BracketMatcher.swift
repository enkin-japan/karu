import Foundation

/// Pure bracket-matching for the pairing highlight and the ⌘⇧\ "jump to
/// matching bracket" command (T12.7).
///
/// Storage-free and NSTextView-independent: `findMatch` scans the string on
/// demand and returns the two one-character ranges, so nothing about the
/// document's bracket structure is ever retained (the project's "transient
/// computation, no resident data structures" rule).
///
/// All indexing is done in UTF-16 units via `NSString` so the returned ranges
/// drop straight onto `NSLayoutManager` / `NSTextView` without any
/// `String.Index` conversion cost.
///
/// v1 does **not** skip brackets that appear inside strings or comments — a
/// bracket in `")"` still counts. That is acceptable for a first cut and can be
/// layered on later; the tests note it explicitly.
public enum BracketMatcher {
    /// Opener → closer, in UTF-16 code units.
    private static let openClose: [unichar: unichar] = [
        0x28: 0x29, // ( )
        0x5B: 0x5D, // [ ]
        0x7B: 0x7D, // { }
    ]

    /// Closer → opener, in UTF-16 code units.
    private static let closeOpen: [unichar: unichar] = [
        0x29: 0x28,
        0x5D: 0x5B,
        0x7D: 0x7B,
    ]

    /// Maximum number of UTF-16 units scanned in either direction from the
    /// starting bracket. Bounds the per-invocation cost so a caret next to an
    /// unbalanced bracket in a huge file can never walk the whole document; the
    /// scan simply gives up (returns `nil`) past this window.
    public static let scanLimit = 100_000

    /// Finds the bracket pair anchored at the caret. The character *before* the
    /// caret is preferred (VS Code behaviour), falling back to the character
    /// *after* it. Returns the opener's and closer's one-character ranges, or
    /// `nil` when the caret is not adjacent to a bracket, the bracket is
    /// unbalanced, or the match lies beyond `scanLimit`.
    public static func findMatch(text: String, caret: Int) -> (open: NSRange, close: NSRange)? {
        let ns = text as NSString
        let length = ns.length
        guard length > 0 else { return nil }

        // Prefer the bracket immediately before the caret.
        if caret >= 1, caret - 1 < length,
           let match = matchAt(index: caret - 1, ns: ns, length: length) {
            return match
        }
        // Otherwise the bracket immediately after the caret.
        if caret >= 0, caret < length,
           let match = matchAt(index: caret, ns: ns, length: length) {
            return match
        }
        return nil
    }

    /// Attempts to match the bracket at `index`, scanning forward for an opener
    /// or backward for a closer. Returns `nil` when the character is not a
    /// bracket.
    private static func matchAt(index: Int, ns: NSString, length: Int) -> (open: NSRange, close: NSRange)? {
        let ch = ns.character(at: index)
        if let close = openClose[ch] {
            return scanForward(from: index, open: ch, close: close, ns: ns, length: length)
        }
        if let open = closeOpen[ch] {
            return scanBackward(from: index, open: open, close: ch, ns: ns, length: length)
        }
        return nil
    }

    /// Scans forward from an opener at `openIndex` for its balanced closer.
    private static func scanForward(from openIndex: Int, open: unichar, close: unichar,
                                    ns: NSString, length: Int) -> (open: NSRange, close: NSRange)? {
        let end = min(length, openIndex + 1 + scanLimit)
        var depth = 1
        var i = openIndex + 1
        while i < end {
            let c = ns.character(at: i)
            if c == open {
                depth += 1
            } else if c == close {
                depth -= 1
                if depth == 0 {
                    return (NSRange(location: openIndex, length: 1),
                            NSRange(location: i, length: 1))
                }
            }
            i += 1
        }
        return nil
    }

    /// Scans backward from a closer at `closeIndex` for its balanced opener.
    private static func scanBackward(from closeIndex: Int, open: unichar, close: unichar,
                                     ns: NSString, length: Int) -> (open: NSRange, close: NSRange)? {
        let lowerBound = max(0, closeIndex - scanLimit)
        var depth = 1
        var i = closeIndex - 1
        while i >= lowerBound {
            let c = ns.character(at: i)
            if c == close {
                depth += 1
            } else if c == open {
                depth -= 1
                if depth == 0 {
                    return (NSRange(location: i, length: 1),
                            NSRange(location: closeIndex, length: 1))
                }
            }
            i -= 1
        }
        return nil
    }
}
