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

    // MARK: - Indent space dots (VS Code style)

    /// Diameter, in points, of the small dot drawn at the centre of each leading
    /// space so the space count is countable at a glance.
    public static let dotDiameter: CGFloat = 2.5

    /// Column offsets (relative to the line start) of every leading *space*
    /// character. Tabs are deliberately excluded — they carry no dot — and the
    /// scan stops at the first non-whitespace character, so the returned columns
    /// never fall on the line's content. Pure and storage-free: recomputed for
    /// visible lines at draw time (ARCHITECTURE.md §3.2).
    public static func leadingSpaceColumns(forLine line: String) -> [Int] {
        let ns = line as NSString
        var columns: [Int] = []
        var col = 0
        loop: while col < ns.length {
            switch ns.character(at: col) {
            case 0x20: columns.append(col) // space → dot
            case 0x09: break               // tab → no dot, keep scanning
            default: break loop            // content → stop
            }
            col += 1
        }
        return columns
    }

    /// Colour of the indent space dots: a low-contrast label colour that stays
    /// legible — but unobtrusive — in both light and dark appearances.
    public static func dotColor() -> NSColor {
        NSColor.secondaryLabelColor.withAlphaComponent(0.45)
    }

    /// Base alpha used for the fill of each indent block.
    private static let fillAlpha: CGFloat = 0.16

    /// Alpha used for the 1px separator line drawn at the right edge of each
    /// indent unit — roughly double the fill alpha so the boundary between
    /// consecutive indent levels reads clearly at a glance.
    private static let separatorAlpha: CGFloat = 0.32

    /// The underlying hue for `level`, cycling through a high-discrimination
    /// 5-colour ramp (yellow -> green -> cyan -> blue -> purple, in the style
    /// of VS Code's indent-rainbow) so adjacent levels never look alike.
    private static func baseColor(forLevel level: Int) -> NSColor {
        let palette: [NSColor] = [
            .systemYellow,
            .systemGreen,
            .systemTeal,
            .systemBlue,
            .systemPurple,
        ]
        return palette[((level % colorCount) + colorCount) % colorCount]
    }

    /// Fill colour for `level`, cycling through a rainbow of system colours at
    /// a low alpha so it stays legible (but not overwhelming) in both light
    /// and dark appearances.
    public static func color(forLevel level: Int) -> NSColor {
        baseColor(forLevel: level).withAlphaComponent(fillAlpha)
    }

    /// Separator colour for the 1px boundary line drawn at the right edge of
    /// `level`'s indent unit. Same hue as `color(forLevel:)` but at roughly
    /// double the alpha, so the width of "one indent" is easy to count even
    /// when several levels share a similar column width.
    public static func separatorColor(forLevel level: Int) -> NSColor {
        baseColor(forLevel: level).withAlphaComponent(separatorAlpha)
    }
}
