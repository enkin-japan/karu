import Foundation

/// VS Code-style indentation auto-detection.
///
/// Infers a document's indent unit from its actual content, so the indent
/// rainbow (and Tab width) match what the file really uses rather than a fixed
/// per-language default. This exists because a Markdown file authored with
/// 4-space indentation was being rendered against Markdown's 2-space default,
/// splitting one visual indent level into two rainbow bands ("参差不齐").
///
/// Pure and `NSTextView`-independent so it is trivially testable; the wiring in
/// `EditorWindowController` runs it on open and on language changes (never per
/// keystroke) and stores the result on `EditorTextView.detectedIndentUnit`.
public enum IndentDetector {
    /// The inferred indentation of a document.
    public struct Detection: Equatable {
        /// Columns per indent level (for tab-indented files this is `1`).
        public let unit: Int
        /// Whether the document indents with tabs rather than spaces.
        public let usesTabs: Bool

        public init(unit: Int, usesTabs: Bool) {
            self.unit = unit
            self.usesTabs = usesTabs
        }
    }

    /// Candidate space-indent units, in preference order for ties.
    private static let candidateUnits = [2, 4, 8]

    /// Detects the indentation used by `text`, scanning at most `maxLines`
    /// lines from the top.
    ///
    /// Algorithm (a simplified take on VS Code's `guessIndentation`):
    /// 1. Count how many non-blank lines begin with a tab vs. a space. If tabs
    ///    win outright, report `usesTabs` with a unit of 1.
    /// 2. Otherwise, build a histogram of the positive indentation *increments*
    ///    between consecutive non-blank lines (how much deeper a line is than
    ///    the previous one) and pick whichever of 2 / 4 / 8 gathered the most
    ///    votes.
    /// 3. With fewer than three increment samples — or no indentation at all —
    ///    return `nil`, signalling the caller to fall back to the language
    ///    default.
    public static func detect(text: String, maxLines: Int = 400) -> Detection? {
        let ns = text as NSString
        guard ns.length > 0 else { return nil }

        var tabLines = 0
        var spaceLines = 0
        var histogram: [Int: Int] = [:]
        var incrementSamples = 0
        // Leading-space count of the previous non-blank, space-or-unindented
        // line. `nil` after a tab-indented line so tab / space worlds never mix.
        var previousSpaces: Int? = nil

        var index = 0
        var scanned = 0
        while index < ns.length && scanned < maxLines {
            let lineRange = ns.lineRange(for: NSRange(location: index, length: 0))
            index = lineRange.location + lineRange.length
            scanned += 1

            let start = lineRange.location
            let end = lineRange.location + lineRange.length

            // Measure the leading whitespace run and whether the line has any
            // content at all.
            var leadingSpaces = 0
            var firstIsTab = false
            var firstIsSpace = false
            var hasContent = false
            var col = start
            var countingLeading = true
            while col < end {
                let c = ns.character(at: col)
                switch c {
                case 0x20: // space
                    if col == start { firstIsSpace = true }
                    if countingLeading { leadingSpaces += 1 }
                case 0x09: // tab
                    if col == start { firstIsTab = true }
                    countingLeading = false
                case 0x0A, 0x0D: // line terminators — ignore
                    break
                default:
                    hasContent = true
                    countingLeading = false
                }
                col += 1
            }

            // Blank lines carry no indentation signal and must not break the
            // increment chain across them.
            guard hasContent else { continue }

            if firstIsTab {
                tabLines += 1
                previousSpaces = nil
                continue
            }

            if firstIsSpace { spaceLines += 1 }

            if let prev = previousSpaces, leadingSpaces > prev {
                let diff = leadingSpaces - prev
                histogram[diff, default: 0] += 1
                incrementSamples += 1
            }
            previousSpaces = leadingSpaces
        }

        // Tab-dominant document: one tab is one indent level.
        if tabLines > spaceLines {
            return Detection(unit: 1, usesTabs: true)
        }

        guard incrementSamples >= 3 else { return nil }

        var best = (unit: 0, votes: 0)
        for unit in candidateUnits {
            let votes = histogram[unit] ?? 0
            if votes > best.votes {
                best = (unit, votes)
            }
        }
        guard best.votes > 0 else { return nil }
        return Detection(unit: best.unit, usesTabs: false)
    }
}
