import Foundation

/// Invisible / dangerous-character scanner (T12.10).
///
/// A pure, stateless scanner that finds Unicode scalars which are invisible or
/// carry hidden semantics — the sort a reviewer needs flagged because they can
/// silently change how source reads or is interpreted. The editor draws a warning
/// box around each hit **live, every frame** (`EditorTextView.drawBackground`);
/// nothing is ever stored ("画出来不存起来", ARCHITECTURE.md §3).
///
/// v1 deliberately does **not** ship a confusable / homoglyph table (e.g. Cyrillic
/// 'а' vs Latin 'a'): a useful table is ~100 KB of data, which violates the
/// project's lightweight-bundle discipline. Only the fixed, tiny set of
/// zero-width / bidi / abnormal-line-terminator / soft-hyphen scalars is checked.
public enum UnicodeAlert {
    /// One flagged occurrence: its (UTF-16) range in the text and the raw scalar.
    public typealias Hit = (range: NSRange, scalar: UInt32)

    /// Scans `range` of `text` for flagged scalars and returns each hit in
    /// document order. All flagged scalars are in the BMP (one UTF-16 unit), so
    /// each hit is a length-1 range.
    ///
    /// `U+FEFF` (ZWNBSP / BOM) is exempt when it is the very first unit of the
    /// document (a legitimate byte-order mark), but flagged anywhere else.
    public static func scan(text: String, range: NSRange) -> [Hit] {
        let ns = text as NSString
        let length = ns.length
        guard length > 0 else { return [] }

        let start = max(0, range.location)
        let end = min(range.location + range.length, length)
        guard start < end else { return [] }

        var hits: [Hit] = []
        var i = start
        while i < end {
            let scalar = UInt32(ns.character(at: i))
            if isFlagged(scalar) {
                // A leading BOM is legitimate; flag FEFF only when not at index 0.
                if !(scalar == 0xFEFF && i == 0) {
                    hits.append((range: NSRange(location: i, length: 1), scalar: scalar))
                }
            }
            i += 1
        }
        return hits
    }

    /// Whether `scalar` is one of the flagged invisible / dangerous characters.
    public static func isFlagged(_ scalar: UInt32) -> Bool {
        switch scalar {
        // Zero-width family: ZWSP, ZWNJ, ZWJ, word joiner, ZWNBSP/BOM.
        case 0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF:
            return true
        // Bidirectional controls: LRE/RLE/PDF/LRO/RLO and the isolates LRI/RLI/FSI/PDI.
        case 0x202A...0x202E, 0x2066...0x2069:
            return true
        // Abnormal line terminators: line separator, paragraph separator, NEL.
        case 0x2028, 0x2029, 0x0085:
            return true
        // Soft hyphen (invisible unless a line breaks at it).
        case 0x00AD:
            return true
        default:
            return false
        }
    }
}
