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
public struct FoldRegion: Equatable {
    /// 1-based header line; remains visible when folded.
    public var startLine: Int
    /// 1-based last hidden line (inclusive) when folded.
    public var endLine: Int

    public init(startLine: Int, endLine: Int) {
        self.startLine = startLine
        self.endLine = endLine
    }
}

/// One-shot foldable-region scanner. Runs on demand (document open, or after a
/// debounced edit / a gutter click) and returns a small array; nothing here is
/// retained or incrementally maintained, matching the architecture's
/// "transient, not resident" rule (ARCHITECTURE.md §3.4). The returned array is
/// itself tiny and may be cached by the caller.
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
///   back.
///
/// v1 trade-off: brackets and colons inside string literals or comments are
/// **not** excluded (that needs the tokenizer / precise lexing which folding
/// deliberately avoids). In practice mismatches are rare and merely offer an
/// extra fold handle; correctness of the text is never affected.
public enum FoldScanner {
    /// Bracket / indentation characters treated as openers and closers.
    private static let openers: Set<UInt16> = [0x7B, 0x5B]   // '{' '['
    private static let closers: [UInt16: UInt16] = [0x7D: 0x7B, 0x5D: 0x5B] // '}'->'{', ']'->'['

    /// Computes every foldable region in `text`. `lineIndex` supplies line
    /// boundaries (the "one index, reused everywhere" structure) so we never
    /// recount newlines.
    public static func regions(text: String, lineIndex: LineIndex) -> [FoldRegion] {
        let ns = text as NSString
        let lineCount = lineIndex.lineCount

        var result = bracketRegions(ns: ns, lineIndex: lineIndex, lineCount: lineCount)
        result += indentRegions(ns: ns, lineIndex: lineIndex, lineCount: lineCount)

        // Deduplicate exact matches (a brace and an indent rule can agree) and
        // sort for stable, predictable output.
        var seen = Set<[Int]>()
        var unique: [FoldRegion] = []
        for r in result where seen.insert([r.startLine, r.endLine]).inserted {
            unique.append(r)
        }
        unique.sort { $0.startLine != $1.startLine ? $0.startLine < $1.startLine
                                                   : $0.endLine < $1.endLine }
        return unique
    }

    // MARK: - Bracket pairing

    private static func bracketRegions(ns: NSString, lineIndex: LineIndex, lineCount: Int) -> [FoldRegion] {
        // Stack of (opener character, line where it appeared).
        var stack: [(open: UInt16, line: Int)] = []
        var regions: [FoldRegion] = []

        for line in 1...lineCount {
            let range = lineIndex.offsetRange(ofLine: line)
            var i = range.lowerBound
            let end = range.upperBound
            while i < end {
                let c = ns.character(at: i)
                if openers.contains(c) {
                    stack.append((c, line))
                } else if let expectedOpen = closers[c] {
                    // Match against the top of the stack only when the opener
                    // type agrees; otherwise ignore this closer (v1: no error
                    // recovery for unbalanced / string-embedded brackets).
                    if let top = stack.last, top.open == expectedOpen {
                        stack.removeLast()
                        let openLine = top.line
                        let closeLine = line
                        // Keep both delimiter lines visible: hide the interior
                        // only, so a region needs at least one interior line.
                        if closeLine - 1 > openLine {
                            regions.append(FoldRegion(startLine: openLine, endLine: closeLine - 1))
                        }
                    }
                }
                i += 1
            }
        }
        return regions
    }

    // MARK: - Indentation

    private static func indentRegions(ns: NSString, lineIndex: LineIndex, lineCount: Int) -> [FoldRegion] {
        var regions: [FoldRegion] = []

        for line in 1...lineCount {
            let content = lineContent(ns: ns, lineIndex: lineIndex, line: line)
            guard trimmedEndsWithColon(content) else { continue }

            let headerIndent = indentWidth(content)
            var j = line + 1
            var lastDeep = line
            while j <= lineCount {
                let s = lineContent(ns: ns, lineIndex: lineIndex, line: j)
                if isBlank(s) {
                    // Blank lines don't terminate a block (Python allows them);
                    // they just aren't counted as the block's last line.
                    j += 1
                    continue
                }
                if indentWidth(s) > headerIndent {
                    lastDeep = j
                    j += 1
                } else {
                    break
                }
            }
            if lastDeep > line {
                regions.append(FoldRegion(startLine: line, endLine: lastDeep))
            }
        }
        return regions
    }

    // MARK: - Line helpers

    /// Line content *including* its terminator (matching `LineIndex` ranges).
    private static func lineContent(ns: NSString, lineIndex: LineIndex, line: Int) -> String {
        let r = lineIndex.offsetRange(ofLine: line)
        return ns.substring(with: NSRange(location: r.lowerBound, length: r.upperBound - r.lowerBound))
    }

    /// Leading-whitespace width. Each space and each tab counts as one column;
    /// this is intentionally simple (v1) and consistent for well-indented files.
    private static func indentWidth(_ line: String) -> Int {
        var n = 0
        for ch in line {
            if ch == " " || ch == "\t" { n += 1 } else { break }
        }
        return n
    }

    /// True when the line has no non-whitespace character (terminator aside).
    private static func isBlank(_ line: String) -> Bool {
        for ch in line where ch != " " && ch != "\t" && ch != "\n" && ch != "\r" {
            return false
        }
        return true
    }

    /// True when the line's content, ignoring trailing whitespace / terminator,
    /// ends with a colon.
    private static func trimmedEndsWithColon(_ line: String) -> Bool {
        var chars = Array(line)
        while let last = chars.last, last == " " || last == "\t" || last == "\n" || last == "\r" {
            chars.removeLast()
        }
        return chars.last == ":"
    }
}
