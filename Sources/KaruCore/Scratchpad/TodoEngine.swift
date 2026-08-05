import Foundation

/// To-do lists for the scratchpad (T15.6), as pure logic.
///
/// The feature is **two orthogonal switches**, not one cycle: ⇧⌘L answers "is
/// this line a to-do?" and never moves anything, ⇧⌘U answers "is it done?" and
/// moves the line where its new state belongs. Pressing the same key twice
/// always undoes itself; neither key can turn a finished item back into prose
/// behind the user's back.
///
/// Every entry point takes the document string plus the current selection and
/// returns the whole new text together with the selection that must follow it;
/// `ScratchpadTextView` is a thin wrapper that feeds the result through the
/// undo-aware mutation path (`shouldChangeText` → `replaceCharacters` →
/// `didChangeText`), narrowed to the smallest changed span by `minimalEdit`.
/// Nothing is retained — every function is `static` and allocates only the line
/// array it works on, in keeping with the "no resident data structures" rule
/// (ARCHITECTURE.md §3.4).
///
/// The check boxes are **literal characters** (`- [ ] ` / `- [x] `), not
/// decorations: a pad full of to-dos is still a plain text file that reads the
/// same in any other editor (the product red line — persisted content is always
/// a plain character stream).
public enum TodoEngine {

    // MARK: - Line state

    /// The three states a line can be in — the product of the two switches
    /// (`plain` collapses both "not a to-do" cases into one).
    public enum LineState: Equatable, Sendable {
        case plain
        case unchecked
        case checked
    }

    /// The marker written for each of the two to-do states. The trailing space
    /// belongs to the marker: it is what separates the box from the text.
    public static let uncheckedMarker = "- [ ] "
    public static let checkedMarker = "- [x] "

    /// Length of the box itself — `- [x]`, without the trailing space. A line
    /// may end right after it (an empty item typed at the end of the document),
    /// which is why the space is optional when recognising a marker.
    private static let boxLength = 5

    /// Offset of the state character inside the box (`- [` is 3 units).
    private static let boxOffset = 3

    /// A line dissected into indent / marker / body lengths.
    struct Parsed {
        /// UTF-16 length of the leading whitespace, which is always preserved.
        var indentLength: Int
        var state: LineState
        /// UTF-16 length of the marker following the indent; 0 when `.plain`.
        var markerLength: Int
    }

    /// Splits one line (terminator already removed) into indent + marker + body.
    ///
    /// A marker is recognised only at the very start of the line's content and
    /// only when it is followed by a space or the line's end — `- [x]y` is
    /// ordinary prose, not a checked item.
    static func parse(line: String) -> Parsed {
        let ns = line as NSString
        let indent = leadingWhitespaceLength(ns)
        let plain = Parsed(indentLength: indent, state: .plain, markerLength: 0)
        guard ns.length - indent >= boxLength else { return plain }

        let box = ns.substring(with: NSRange(location: indent, length: boxLength))
        guard box.hasPrefix("- ["), box.hasSuffix("]") else { return plain }
        let state: LineState
        switch (box as NSString).substring(with: NSRange(location: boxOffset, length: 1)) {
        case " ": state = .unchecked
        case "x", "X": state = .checked
        default: return plain
        }

        // The box must be followed by a space (or nothing at all).
        let afterBox = indent + boxLength
        var markerLength = boxLength
        if afterBox < ns.length {
            guard ns.substring(with: NSRange(location: afterBox, length: 1)) == " " else { return plain }
            markerLength += 1
        }
        return Parsed(indentLength: indent, state: state, markerLength: markerLength)
    }

    /// The state of a single line (terminator already removed).
    public static func state(ofLine line: String) -> LineState {
        parse(line: line).state
    }

    /// The check box's own characters — `[`, the state, `]` — as a line-relative
    /// range, or `nil` when the line carries no marker. This is the click target
    /// the text view hit-tests: clicking the box ticks it, clicking the text
    /// beside it just places the caret.
    public static func boxRange(inLine line: String) -> NSRange? {
        let parsed = parse(line: line)
        guard parsed.state != .plain else { return nil }
        return NSRange(location: parsed.indentLength + 2, length: 3)
    }

    // MARK: - "Is this a to-do?" (⇧⌘L)

    /// Turns every line the selection touches into a to-do item, or — when they
    /// all are one already — back into prose. **Nothing ever moves**: this
    /// switch is about the marker only, so the lines stay exactly where the user
    /// is looking at them.
    ///
    /// - any target still plain → those plain lines get `- [ ] `, in place;
    ///   lines that already carry a box (ticked or not) are left **untouched**,
    ///   so extending a list over a finished item cannot un-finish it;
    /// - otherwise (every target already marked) → **all** lose their marker, in
    ///   place. A checked line becomes ordinary prose in one step: the user is
    ///   explicitly saying "this is not a to-do", and discarding the done flag
    ///   with the box is what they asked for.
    ///
    /// Blank lines inside a multi-line selection are left alone (they are
    /// neither counted for the decision nor marked) — unless every covered line
    /// is blank, which is the "press ⇧⌘L on an empty line to start a list" case.
    public static func toggleTodo(text: String, selection: NSRange) -> (text: String, selection: NSRange) {
        let lines = splitLines(text)
        let starts = lineStarts(lines)
        let span = lineSpan(selection: selection, lines: lines, starts: starts)

        var targets = span.filter { !isBlank(lines[$0]) }
        if targets.isEmpty { targets = Array(span) }
        let states = targets.map { state(ofLine: lines[$0]) }

        if states.contains(.plain) {
            return rewriteInPlace(lines: lines, starts: starts, targets: targets,
                                  selection: selection, transform: markUnchecked)
        }
        return rewriteInPlace(lines: lines, starts: starts, targets: targets,
                              selection: selection, transform: stripMarker)
    }

    // MARK: - "Is it done?" (⇧⌘U)

    /// Ticks every to-do line the selection touches, or unticks them when they
    /// are all done already — the batch counterpart of clicking a check box, and
    /// the only entry point that moves lines:
    ///
    /// - any target unchecked → **all** become `- [x] ` and travel to the end of
    ///   the document as one block, keeping their relative order;
    /// - otherwise (everything already checked) → **all** become `- [ ] ` again
    ///   and travel back as one block, to the same place a single un-ticked line
    ///   returns to (`uncheckReturnIndex`, computed over the lines that stay).
    ///
    /// Plain lines never take part: they are neither marked nor moved. A
    /// selection holding nothing but prose is a no-op — ⇧⌘U on ordinary text
    /// must not silently turn it into a list; that is ⇧⌘L's job.
    public static func toggleChecked(text: String, selection: NSRange) -> (text: String, selection: NSRange) {
        let lines = splitLines(text)
        let starts = lineStarts(lines)
        let span = lineSpan(selection: selection, lines: lines, starts: starts)

        let targets = span.filter { state(ofLine: lines[$0]) != .plain }
        guard !targets.isEmpty else { return (text, selection) }
        let states = targets.map { state(ofLine: lines[$0]) }

        if states.contains(.unchecked) {
            let contents = targets.map { checkedContent(of: lines[$0]) }
            return relocate(lines: lines, starts: starts, targets: targets,
                            newContents: contents, selection: selection,
                            destination: { documentEndIndex(of: $0) })
        }
        // The block comes back where its *first* line used to be when the
        // document holds no other item — that slot survives the lift-out, every
        // other moved line sitting below it.
        let contents = targets.map { uncheckedContent(of: lines[$0]) }
        return relocate(lines: lines, starts: starts, targets: targets,
                        newContents: contents, selection: selection,
                        destination: { remaining in
                            uncheckReturnIndex(in: remaining, original: targets[0])
                        })
    }

    // MARK: - Single-line flip (check-box click)

    /// Flips the check box on the line containing `characterIndex` and moves the
    /// line where that state belongs:
    ///
    /// - unchecked → checked: to the end of the document (done work sinks);
    /// - checked → unchecked: back after the last `- [ ] ` line, or — when there
    ///   is none — in front of the first other `- [x] ` line, or nowhere at all
    ///   when the document holds neither.
    ///
    /// Returns `nil` for a plain line, so the caller can fall through to the
    /// text view's normal click handling.
    public static func flipChecked(text: String,
                                   lineAt characterIndex: Int,
                                   selection: NSRange) -> (text: String, selection: NSRange)? {
        let lines = splitLines(text)
        let starts = lineStarts(lines)
        let index = lineIndex(containing: characterIndex, starts: starts, count: lines.count)
        let parsed = parse(line: lines[index])
        guard parsed.state != .plain else { return nil }

        if parsed.state == .unchecked {
            return relocate(lines: lines, starts: starts, targets: [index],
                            newContents: [checkedContent(of: lines[index])],
                            selection: selection,
                            destination: { documentEndIndex(of: $0) })
        }
        return relocate(lines: lines, starts: starts, targets: [index],
                        newContents: [uncheckedContent(of: lines[index])],
                        selection: selection,
                        destination: { remaining in uncheckReturnIndex(in: remaining, original: index) })
    }

    /// Where an unchecked-again line (or block of them) goes back to: after the
    /// last remaining `- [ ] ` line, else in front of the first remaining
    /// `- [x] ` line, else straight back where it came from (`original`, which
    /// — the line having been lifted out — is its own old slot in `remaining`).
    static func uncheckReturnIndex(in remaining: [String], original: Int) -> Int {
        if let last = remaining.lastIndex(where: { state(ofLine: $0) == .unchecked }) {
            return last + 1
        }
        if let first = remaining.firstIndex(where: { state(ofLine: $0) == .checked }) {
            return first
        }
        return min(original, remaining.count)
    }

    /// Index one past the last line that carries content, i.e. where "the end of
    /// the document" is for a moved line. Trailing blank lines — chiefly the
    /// empty last line a final newline produces — stay at the bottom, so moving
    /// a line neither adds nor swallows a blank line.
    static func documentEndIndex(of lines: [String]) -> Int {
        var end = lines.count
        while end > 0, isBlank(lines[end - 1]) { end -= 1 }
        return end
    }

    // MARK: - List continuation (⏎)

    /// What ⏎ should do on a list line.
    public enum Continuation: Equatable, Sendable {
        /// Insert a newline followed by this prefix (the caret lands after it).
        case insert(String)
        /// The item is empty: delete this line-relative range and insert nothing
        /// — pressing ⏎ on an empty bullet leaves the list.
        case exit(NSRange)
    }

    /// Continues the list the caret sits on, Notes-style. Returns `nil` when the
    /// line is not a list item, or when the caret is still inside the prefix —
    /// both mean "just insert a plain newline".
    ///
    /// Recognised prefixes: `- [ ] ` / `- [x] ` (always continued *unchecked*:
    /// a new item starts undone), `- `, `* `, and `N. ` (continued as `N+1. `,
    /// without renumbering the lines below — that would rewrite text the user
    /// did not touch).
    public static func continuation(line: String, caretOffsetInLine caret: Int) -> Continuation? {
        let ns = line as NSString
        let indentLength = leadingWhitespaceLength(ns)
        guard let marker = listMarker(in: ns, indentLength: indentLength) else { return nil }

        let prefixLength = indentLength + marker.length
        // Inside the prefix (including the indent): an ordinary newline.
        guard caret >= prefixLength, caret <= ns.length else { return nil }

        let body = ns.substring(from: prefixLength)
        if body.trimmingCharacters(in: .whitespaces).isEmpty {
            // Empty item: ⏎ removes the prefix instead of making another one.
            return .exit(NSRange(location: 0, length: ns.length))
        }
        return .insert(ns.substring(to: indentLength) + marker.next)
    }

    /// The list marker at the start of `line`'s content, if any: its UTF-16
    /// length and the prefix a *following* item carries.
    private static func listMarker(in line: NSString, indentLength: Int) -> (length: Int, next: String)? {
        // To-do boxes first — they also start with "- ", so the bullet rule must
        // not claim them.
        let parsed = parse(line: line as String)
        if parsed.state != .plain {
            return (parsed.markerLength, uncheckedMarker)
        }
        guard indentLength < line.length else { return nil }

        if indentLength + 2 <= line.length {
            let bullet = line.substring(with: NSRange(location: indentLength, length: 2))
            if bullet == "- " || bullet == "* " { return (2, bullet) }
        }

        // `N. ` — an ordered item. The digit run is capped so a pasted wall of
        // digits can never overflow the increment.
        var digits = ""
        var scan = indentLength
        while scan < line.length, digits.count < 9 {
            let unit = line.substring(with: NSRange(location: scan, length: 1))
            guard unit.count == 1, let c = unit.unicodeScalars.first, c.value >= 48, c.value <= 57 else { break }
            digits += unit
            scan += 1
        }
        guard !digits.isEmpty, let number = Int(digits),
              scan + 2 <= line.length,
              line.substring(with: NSRange(location: scan, length: 2)) == ". " else { return nil }
        return (digits.count + 2, "\(number + 1). ")
    }

    // MARK: - Minimal edit

    /// The smallest replacement that turns `old` into `new`, found by trimming
    /// the common prefix and suffix. Returns `nil` when the two are equal.
    ///
    /// This is what keeps a whole-document rewrite honest inside a text view: a
    /// marker toggle plus a line move becomes **one** `replaceCharacters` — one
    /// undo step, one layout invalidation over the affected span only, rather
    /// than a full-document replacement that would throw away the layout and the
    /// scroll position.
    ///
    /// The trim never splits a surrogate pair, so the returned range is always a
    /// valid `NSRange` into `old`.
    public static func minimalEdit(from old: String, to new: String) -> (range: NSRange, replacement: String)? {
        let a = Array(old.utf16)
        let b = Array(new.utf16)
        guard a != b else { return nil }

        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        if prefix > 0, isHighSurrogate(a[prefix - 1]) { prefix -= 1 }

        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        if suffix > 0, isLowSurrogate(a[a.count - suffix]) { suffix -= 1 }

        let range = NSRange(location: prefix, length: a.count - prefix - suffix)
        let replacement = String(decoding: b[prefix..<(b.count - suffix)], as: UTF16.self)
        return (range, replacement)
    }

    private static func isHighSurrogate(_ unit: UInt16) -> Bool { unit >= 0xD800 && unit <= 0xDBFF }
    private static func isLowSurrogate(_ unit: UInt16) -> Bool { unit >= 0xDC00 && unit <= 0xDFFF }

    // MARK: - Line model
    //
    // A document is its lines *without* terminators: `components(separatedBy:)`
    // and `joined(separator:)` are exact inverses, so a document ending in a
    // newline simply has an empty last line — which is also where the caret can
    // legitimately sit. Nothing here can invent or swallow a newline.
    //
    // CRLF text keeps its `\r` at the end of each line's content: markers are
    // written at the *front* of a line, so the carriage returns ride along
    // untouched and the round-trip stays byte-exact.

    static func splitLines(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    static func joinLines(_ lines: [String]) -> String {
        lines.joined(separator: "\n")
    }

    /// UTF-16 offset of each line's first character.
    static func lineStarts(_ lines: [String]) -> [Int] {
        var starts: [Int] = []
        starts.reserveCapacity(lines.count)
        var offset = 0
        for line in lines {
            starts.append(offset)
            offset += (line as NSString).length + 1   // + the "\n" that follows
        }
        return starts
    }

    /// The line a character index falls on, clamped into the document.
    static func lineIndex(containing index: Int, starts: [Int], count: Int) -> Int {
        guard count > 0 else { return 0 }
        var line = 0
        for i in 0..<count where starts[i] <= index { line = i }
        return min(line, count - 1)
    }

    /// The lines a selection covers. A selection that merely *ends* at the very
    /// start of a line does not include that line — dragging down to the next
    /// line's left edge is how a user selects the lines above it, not one more.
    static func lineSpan(selection: NSRange, lines: [String], starts: [Int]) -> [Int] {
        let first = lineIndex(containing: max(0, selection.location), starts: starts, count: lines.count)
        guard selection.length > 0 else { return [first] }
        let end = selection.location + selection.length
        var last = lineIndex(containing: end, starts: starts, count: lines.count)
        if last > first, end == starts[last] { last -= 1 }
        return Array(first...max(first, last))
    }

    // MARK: - Per-line rewrites

    /// One line's replacement plus what it does to a caret sitting in it: text
    /// was inserted (or removed) at `column`, changing the length by `delta`.
    struct LineRewrite {
        var content: String
        var column: Int
        var delta: Int

        /// Where an offset inside the old line lands in the new one.
        func mapOffset(_ offset: Int) -> Int {
            offset < column ? offset : max(column, offset + delta)
        }
    }

    /// Gives a plain line an unchecked box. A line that already has one — box
    /// ticked or not — is returned verbatim: ⇧⌘L adds markers, it never resets
    /// the state of an item that is already on the list.
    private static func markUnchecked(_ line: String) -> LineRewrite {
        let ns = line as NSString
        let parsed = parse(line: line)
        guard parsed.state == .plain else { return LineRewrite(content: line, column: 0, delta: 0) }
        let content = ns.substring(to: parsed.indentLength)
            + uncheckedMarker
            + ns.substring(from: parsed.indentLength)
        return LineRewrite(content: content,
                           column: parsed.indentLength,
                           delta: (uncheckedMarker as NSString).length)
    }

    private static func stripMarker(_ line: String) -> LineRewrite {
        let ns = line as NSString
        let parsed = parse(line: line)
        guard parsed.state != .plain else { return LineRewrite(content: line, column: 0, delta: 0) }
        let content = ns.substring(to: parsed.indentLength)
            + ns.substring(from: parsed.indentLength + parsed.markerLength)
        return LineRewrite(content: content, column: parsed.indentLength, delta: -parsed.markerLength)
    }

    /// The same line with its box ticked. Only the one character changes, so
    /// every offset in the line — and the caret with it — stays put.
    private static func checkedContent(of line: String) -> String {
        setBox(of: line, to: "x")
    }

    private static func uncheckedContent(of line: String) -> String {
        setBox(of: line, to: " ")
    }

    private static func setBox(of line: String, to character: String) -> String {
        let parsed = parse(line: line)
        guard parsed.state != .plain else { return line }
        let ns = line as NSString
        let boxIndex = parsed.indentLength + boxOffset
        return ns.substring(to: boxIndex) + character + ns.substring(from: boxIndex + 1)
    }

    // MARK: - Whole-document rewrites

    /// Rewrites `targets` where they are, mapping the selection through the
    /// per-line offset shifts.
    private static func rewriteInPlace(lines: [String],
                                       starts: [Int],
                                       targets: [Int],
                                       selection: NSRange,
                                       transform: (String) -> LineRewrite) -> (text: String, selection: NSRange) {
        var newLines = lines
        var rewrites: [Int: LineRewrite] = [:]
        for index in targets {
            let rewrite = transform(lines[index])
            newLines[index] = rewrite.content
            rewrites[index] = rewrite
        }
        let lineMap = Array(lines.indices)
        return (joinLines(newLines),
                remap(selection: selection, oldStarts: starts, oldCount: lines.count,
                      newLines: newLines, lineMap: lineMap, rewrites: rewrites))
    }

    /// Lifts `targets` out of the document, replaces them with `newContents`
    /// (same length, so intra-line offsets are untouched) and re-inserts them as
    /// one block at the index `destination` picks in the *remaining* lines.
    private static func relocate(lines: [String],
                                 starts: [Int],
                                 targets: [Int],
                                 newContents: [String],
                                 selection: NSRange,
                                 destination: ([String]) -> Int) -> (text: String, selection: NSRange) {
        let moved = Set(targets)
        let remainingIndices = lines.indices.filter { !moved.contains($0) }
        let remaining = remainingIndices.map { lines[$0] }
        let insertAt = min(max(destination(remaining), 0), remaining.count)

        var newLines = Array(remaining[0..<insertAt])
        newLines += newContents
        newLines += Array(remaining[insertAt...])

        var lineMap = Array(repeating: 0, count: lines.count)
        for (position, old) in remainingIndices.enumerated() {
            lineMap[old] = position < insertAt ? position : position + targets.count
        }
        for (rank, old) in targets.enumerated() {
            lineMap[old] = insertAt + rank
        }

        return (joinLines(newLines),
                remap(selection: selection, oldStarts: starts, oldCount: lines.count,
                      newLines: newLines, lineMap: lineMap, rewrites: [:]))
    }

    /// Follows the selection through a rewrite: each endpoint keeps its line and
    /// its offset within it (clamped when the line got shorter), so a caret on a
    /// line that was moved to the bottom travels with it.
    private static func remap(selection: NSRange,
                              oldStarts: [Int],
                              oldCount: Int,
                              newLines: [String],
                              lineMap: [Int],
                              rewrites: [Int: LineRewrite]) -> NSRange {
        let newStarts = lineStarts(newLines)
        func map(_ index: Int) -> Int {
            let line = lineIndex(containing: max(0, index), starts: oldStarts, count: oldCount)
            var offset = max(0, index - oldStarts[line])
            if let rewrite = rewrites[line] { offset = rewrite.mapOffset(offset) }
            let newLine = min(max(lineMap[line], 0), newLines.count - 1)
            let clamped = min(offset, (newLines[newLine] as NSString).length)
            return newStarts[newLine] + clamped
        }
        let start = map(selection.location)
        let end = map(selection.location + selection.length)
        return NSRange(location: min(start, end), length: abs(end - start))
    }

    // MARK: - Small helpers

    private static func leadingWhitespaceLength(_ line: NSString) -> Int {
        var end = 0
        while end < line.length {
            let unit = line.substring(with: NSRange(location: end, length: 1))
            if unit == " " || unit == "\t" { end += 1 } else { break }
        }
        return end
    }

    private static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
