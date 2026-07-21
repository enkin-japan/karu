import AppKit

/// Indent-rainbow colour blocks.
///
/// Split into a pure, testable part (`blocks(forLine:indentWidth:)`) that maps
/// a line's leading whitespace to level-tagged column ranges, and the colour /
/// default-toggle helpers used by the drawing code in `EditorTextView`.
///
/// Following ARCHITECTURE.md §3.2 ("painted, not stored") nothing here retains
/// per-line state; blocks are recomputed for visible lines at draw time.
public enum IndentRainbow {
    /// A contiguous run of leading whitespace assigned to one indent level.
    /// `columnRange` is expressed in character offsets relative to the line
    /// start (each space and each tab counts as one character/column).
    public typealias Block = (level: Int, columnRange: Range<Int>)

    /// Number of distinct colours cycled through.
    public static let colorCount = 5

    /// UserDefaults key backing the on/off toggle.
    public static let enabledKey = "editor.indentRainbow"

    /// Whether the rainbow is enabled by default (reads UserDefaults, defaults
    /// to `true` when unset).
    public static var defaultEnabled: Bool {
        if UserDefaults.standard.object(forKey: enabledKey) != nil {
            return UserDefaults.standard.bool(forKey: enabledKey)
        }
        return true
    }

    /// Splits the leading whitespace of `line` into indent-level colour blocks.
    ///
    /// Rules:
    /// - A tab is always its own single-column block (one indent level).
    /// - Spaces are grouped into chunks of `indentWidth`; each full chunk is one
    ///   level. A trailing partial chunk (fewer than `indentWidth` spaces before
    ///   a tab or the first non-whitespace character) still forms its own block.
    /// - Non-whitespace ends the scan; the returned ranges never overlap the
    ///   line's content.
    public static func blocks(forLine line: String, indentWidth: Int) -> [Block] {
        let width = max(1, indentWidth)
        let ns = line as NSString
        var result: [Block] = []
        var level = 0
        var col = 0

        // Pending run of spaces not yet flushed into blocks.
        var spaceStart = 0
        var spaceCount = 0

        func flushSpaces() {
            guard spaceCount > 0 else { return }
            var start = spaceStart
            var remaining = spaceCount
            while remaining >= width {
                result.append((level, start..<(start + width)))
                level += 1
                start += width
                remaining -= width
            }
            if remaining > 0 {
                result.append((level, start..<(start + remaining)))
                level += 1
            }
            spaceCount = 0
        }

        loop: while col < ns.length {
            let c = ns.character(at: col)
            switch c {
            case 0x20: // space
                if spaceCount == 0 { spaceStart = col }
                spaceCount += 1
            case 0x09: // tab
                flushSpaces()
                result.append((level, col..<(col + 1)))
                level += 1
            default:
                break loop
            }
            col += 1
        }
        flushSpaces()
        return result
    }

    /// Fill colour for `level`, cycling through a rainbow of system colours at
    /// a low alpha so it stays subtle in both light and dark appearances.
    public static func color(forLevel level: Int) -> NSColor {
        let palette: [NSColor] = [
            .systemRed,
            .systemYellow,
            .systemGreen,
            .systemBlue,
            .systemPurple,
        ]
        let base = palette[((level % colorCount) + colorCount) % colorCount]
        return base.withAlphaComponent(0.10)
    }
}
