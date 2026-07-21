import Foundation

/// The three newline conventions a text file can use. Kept as a pure,
/// AppKit-independent value type so both detection and conversion are trivially
/// unit-testable and reusable by the status bar and the Format menu.
///
/// `rawValue` (`lf` / `crlf` / `cr`) is stable and used as a menu item's
/// `representedObject`; `displayName` is the universal short caption shown in the
/// status bar (deliberately *not* localized — "LF" / "CRLF" / "CR" are the
/// conventional labels every editor uses, like language names and the "pt" unit).
public enum LineEnding: String, CaseIterable, Sendable {
    case lf
    case crlf
    case cr

    /// Short caption for the status bar / menu ("LF", "CRLF", "CR").
    public var displayName: String {
        switch self {
        case .lf: return "LF"
        case .crlf: return "CRLF"
        case .cr: return "CR"
        }
    }

    /// The literal character sequence this ending inserts.
    public var rawString: String {
        switch self {
        case .lf: return "\n"
        case .crlf: return "\r\n"
        case .cr: return "\r"
        }
    }

    /// Detects the dominant line ending in `text`. When the file mixes styles the
    /// most frequent one wins; a file with no line breaks defaults to `.lf`.
    ///
    /// Counting is done on the CRLF pairs first so a `\r\n` is never double-counted
    /// as a lone `\r` plus a lone `\n`. Ties resolve in `lf` → `crlf` → `cr` order
    /// (LF being the modern default), which keeps the result deterministic.
    public static func detect(in text: String) -> LineEnding {
        // Single streaming pass with one scalar of lookbehind state — never
        // materializes the scalar sequence (an `Array(text.unicodeScalars)` here
        // cost ~4 bytes × document length, +40 MB resident on a 10 MB file).
        var lf = 0, crlf = 0, cr = 0
        var previousWasCR = false
        for s in text.unicodeScalars {
            if s == "\r" {
                if previousWasCR { cr += 1 }  // the previous \r was a lone CR
                previousWasCR = true
            } else if s == "\n" {
                if previousWasCR { crlf += 1; previousWasCR = false }
                else { lf += 1 }
            } else if previousWasCR {
                cr += 1
                previousWasCR = false
            }
        }
        if previousWasCR { cr += 1 }

        // Deterministic tie-break: prefer lf, then crlf, then cr.
        var best: LineEnding = .lf
        var bestCount = lf
        if crlf > bestCount { best = .crlf; bestCount = crlf }
        if cr > bestCount { best = .cr; bestCount = cr }
        return best
    }

    /// Rewrites every line ending in `text` to `target`. Idempotent: converting a
    /// string that already uses `target` returns it unchanged.
    ///
    /// Normalizes to LF first (collapsing `\r\n` and lone `\r`), then expands to
    /// the target sequence — so mixed input comes out uniform regardless of the
    /// styles it started with.
    public static func convert(_ text: String, to target: LineEnding) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        switch target {
        case .lf:
            return normalized
        case .crlf:
            return normalized.replacingOccurrences(of: "\n", with: "\r\n")
        case .cr:
            return normalized.replacingOccurrences(of: "\n", with: "\r")
        }
    }
}
