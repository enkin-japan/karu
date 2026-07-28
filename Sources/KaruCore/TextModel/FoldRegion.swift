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
/// Markdown is the one language that opts out of both (T13.4): its `[]` links
/// and its prose colons produce nothing but noise, while the structure a reader
/// actually wants to collapse — heading sections and fenced code blocks — is
/// invisible to the generic rules. `regions(text:lineIndex:language:)` therefore
/// routes `"markdown"` to a dedicated pair of rules; every other language keeps
/// the generic behaviour unchanged.
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
    ///
    /// `language` is the editor's language identifier (`""` = plain / unknown).
    /// Only `"markdown"` changes the outcome today: it swaps the bracket +
    /// indentation rules for the markdown-specific ones. Every other value keeps
    /// the language-agnostic behaviour, so callers that have no language handy
    /// can simply omit the argument.
    public static func regions(text: String,
                               lineIndex: LineIndex,
                               language: String = "") -> [FoldRegion] {
        let ns = text as NSString
        // Consistency guard: the scanner trusts `lineIndex` offsets when reading
        // `ns`, and the two can transiently disagree (a gutter draw interleaved
        // with an edit transaction crashed exactly here on macOS 26 beta —
        // `characterAtIndex:` out of range, user crash report 2026-07-22).
        // Folding is cosmetic: skipping one scan and letting the next pass see
        // the re-synced pair is always safe; crashing never is.
        guard lineIndex.length == ns.length else { return [] }
        let lineCount = lineIndex.lineCount

        var result: [FoldRegion]
        if language.lowercased() == "markdown" {
            result = markdownRegions(ns: ns, lineIndex: lineIndex, lineCount: lineCount)
        } else {
            result = bracketRegions(ns: ns, lineIndex: lineIndex, lineCount: lineCount)
            result += indentRegions(ns: ns, lineIndex: lineIndex, lineCount: lineCount)
        }

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
            // Pull the tail back over pure closing lines (`]`, `},`, `});`): the
            // bracket rule deliberately keeps such a line visible
            // (`endLine = closeLine - 1`), so swallowing it here would make a
            // fold-all hide a closer that folding the bracket region alone keeps
            // on screen. Blank lines uncovered on the way aren't the block's last
            // line either.
            while lastDeep > line,
                  isPureCloser(lineContent(ns: ns, lineIndex: lineIndex, line: lastDeep))
                    || isBlank(lineContent(ns: ns, lineIndex: lineIndex, line: lastDeep)) {
                lastDeep -= 1
            }
            if lastDeep > line {
                regions.append(FoldRegion(startLine: line, endLine: lastDeep))
            }
        }
        return regions
    }

    // MARK: - Markdown (T13.4)

    /// The two rules VS Code's markdown folding offers, and nothing else:
    ///
    /// - **Heading sections**: an ATX heading (`#` … `######`) folds down to the
    ///   line before the next heading of the *same or lower* level, or to the end
    ///   of the document. Sub-headings nest naturally because a deeper level
    ///   stops only at an equally deep (or shallower) one.
    /// - **Fenced code blocks**: ``` ``` ``` or `~~~` opens a fence; the matching
    ///   closing fence line stays visible (`endLine = closeLine - 1`), the same
    ///   "delimiters stay on screen" shape the bracket rule uses.
    ///
    /// Setext headings (`===` / `---` underlines) are deliberately not detected:
    /// they need a look-ahead that also has to exclude `---` front-matter fences,
    /// thematic breaks and table separators, for a form that is rare in practice.
    private static func markdownRegions(ns: NSString, lineIndex: LineIndex, lineCount: Int) -> [FoldRegion] {
        var regions: [FoldRegion] = []
        // Lines belonging to a fenced code block (fence lines included). Headings
        // are looked for outside these only, so a `# comment` in a shell snippet
        // never starts a section.
        var fenced = [Bool](repeating: false, count: lineCount + 1) // 1-based

        var line = 1
        while line <= lineCount {
            guard let fence = fenceOpener(lineContent(ns: ns, lineIndex: lineIndex, line: line)) else {
                line += 1
                continue
            }
            // Inside a fence only the *same* character can close it, so a `~~~`
            // inside a ``` block is ordinary content.
            var close = line + 1
            var closed = false
            while close <= lineCount {
                if fenceCloses(lineContent(ns: ns, lineIndex: lineIndex, line: close), fence: fence) {
                    closed = true
                    break
                }
                close += 1
            }
            let last = closed ? close : lineCount
            for l in line...last { fenced[l] = true }
            // Closed: hide the body only. Unclosed: run to the document's last
            // content line (a trailing blank line is not worth hiding).
            let end = closed ? close - 1 : trimmingTrailingBlanks(lastLine: lineCount, notBelow: line,
                                                                 ns: ns, lineIndex: lineIndex)
            if end > line { regions.append(FoldRegion(startLine: line, endLine: end)) }
            line = last + 1
        }

        // Heading sections: collect the headings first, then close each one at the
        // next same-or-shallower heading. Walking backwards keeps that lookup O(1)
        // — `nextLine[level]` holds the nearest *following* heading of each level,
        // so a section ends just before the closest of levels 1…N.
        var headings: [(line: Int, level: Int)] = []
        for l in 1...lineCount where !fenced[l] {
            if let level = headingLevel(lineContent(ns: ns, lineIndex: lineIndex, line: l)) {
                headings.append((l, level))
            }
        }
        var nextLine = [Int](repeating: lineCount + 1, count: 7) // index = heading level
        for heading in headings.reversed() {
            var end = lineCount
            for level in 1...heading.level where nextLine[level] <= lineCount {
                end = min(end, nextLine[level] - 1)
            }
            // Blank lines before the next heading (or at EOF) separate sections
            // rather than belong to one, exactly as the indent rule treats them.
            end = trimmingTrailingBlanks(lastLine: end, notBelow: heading.line, ns: ns, lineIndex: lineIndex)
            if end > heading.line { regions.append(FoldRegion(startLine: heading.line, endLine: end)) }
            nextLine[heading.level] = heading.line
        }
        return regions
    }

    /// ATX heading level (1…6) of `line`, or `nil` when it is not a heading.
    /// Up to three leading spaces are allowed (CommonMark; a fourth makes it an
    /// indented code block) and the hashes must be followed by a space or tab.
    private static func headingLevel(_ line: String) -> Int? {
        var chars = Array(line)
        var indent = 0
        while indent < chars.count, chars[indent] == " " { indent += 1 }
        guard indent <= 3 else { return nil }
        chars.removeFirst(indent)
        var level = 0
        while level < chars.count, chars[level] == "#" { level += 1 }
        guard (1...6).contains(level), level < chars.count,
              chars[level] == " " || chars[level] == "\t" else { return nil }
        return level
    }

    /// Opening fence of `line`: at least three backticks or tildes, indented by at
    /// most three spaces. An info string (```` ```swift ````) may follow, but a
    /// backtick fence's info string must not contain another backtick (CommonMark),
    /// which keeps inline code spans like `` `a` `` from opening a fence.
    private static func fenceOpener(_ line: String) -> (char: Character, count: Int)? {
        var chars = Array(line)
        var indent = 0
        while indent < chars.count, chars[indent] == " " { indent += 1 }
        guard indent <= 3 else { return nil }
        chars.removeFirst(indent)
        guard let marker = chars.first, marker == "`" || marker == "~" else { return nil }
        var count = 0
        while count < chars.count, chars[count] == marker { count += 1 }
        guard count >= 3 else { return nil }
        let info = chars.dropFirst(count)
        if marker == "`", info.contains("`") { return nil }
        return (marker, count)
    }

    /// True when `line` closes `fence`: nothing but the same fence character, at
    /// least as many of them as the opener had (leading / trailing whitespace and
    /// the terminator ignored).
    private static func fenceCloses(_ line: String, fence: (char: Character, count: Int)) -> Bool {
        var chars = Array(line)
        while let last = chars.last, last == " " || last == "\t" || last == "\n" || last == "\r" {
            chars.removeLast()
        }
        while let first = chars.first, first == " " || first == "\t" { chars.removeFirst() }
        guard chars.count >= fence.count else { return false }
        return chars.allSatisfy { $0 == fence.char }
    }

    /// Walks `lastLine` back over blank lines, never past `notBelow`.
    private static func trimmingTrailingBlanks(lastLine: Int, notBelow floor: Int,
                                               ns: NSString, lineIndex: LineIndex) -> Int {
        var end = lastLine
        while end > floor, isBlank(lineContent(ns: ns, lineIndex: lineIndex, line: end)) { end -= 1 }
        return end
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

    /// True when the line carries nothing but closing brackets, optionally
    /// followed by `,` / `;` (`]`, `],`, `});`). Such a line closes the block
    /// rather than belonging to its body, so an indent region stops before it.
    private static func isPureCloser(_ line: String) -> Bool {
        var chars = Array(line)
        while let last = chars.last,
              last == " " || last == "\t" || last == "\n" || last == "\r" || last == "," || last == ";" {
            chars.removeLast()
        }
        while let first = chars.first, first == " " || first == "\t" {
            chars.removeFirst()
        }
        guard !chars.isEmpty else { return false }
        return chars.allSatisfy { $0 == ")" || $0 == "]" || $0 == "}" }
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
