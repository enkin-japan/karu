import Foundation

/// Pure, NSTextView-independent line-manipulation logic (VS Code's Move / Copy /
/// Delete Line commands). Every entry point takes the document string plus the
/// current selection and returns a single replacement (or `nil` at a document
/// boundary where the operation is a no-op). `EditorWindowController` feeds the
/// result through the undo-aware text mutation path. Nothing is retained.
public enum LineOperations {

    /// Moves the block of lines the selection covers up by one line, swapping it
    /// with the preceding line. Returns `nil` at the top of the document.
    /// Line terminators keep their positions so the last line's missing newline
    /// is preserved.
    public static func moveLinesUp(
        text: String,
        selection: NSRange
    ) -> (replacement: String, range: NSRange, newSelection: NSRange)? {
        let ns = text as NSString
        guard ns.length > 0 else { return nil }
        let block = ns.lineRange(for: selection)
        guard block.location > 0 else { return nil }

        let prev = ns.lineRange(for: NSRange(location: block.location - 1, length: 0))
        let region = NSRange(location: prev.location, length: prev.length + block.length)
        let unitList = units(ns, in: region)                 // [prev, block…]
        let contents = unitList.map { $0.content }
        let terms = unitList.map { $0.terminator }
        let blockCount = contents.count - 1

        // New content order: block lines first, then the previous line.
        var newContents = Array(contents[1...])
        newContents.append(contents[0])

        let replacement = rebuild(contents: newContents, terminators: terms)

        // The moved block now occupies the first `blockCount` rebuilt units.
        var blockLen = 0
        for i in 0..<blockCount {
            blockLen += (newContents[i] as NSString).length + (terms[i] as NSString).length
        }
        return (replacement, region,
                NSRange(location: region.location, length: blockLen))
    }

    /// Moves the block of lines the selection covers down by one line, swapping it
    /// with the following line. Returns `nil` at the bottom of the document.
    public static func moveLinesDown(
        text: String,
        selection: NSRange
    ) -> (replacement: String, range: NSRange, newSelection: NSRange)? {
        let ns = text as NSString
        guard ns.length > 0 else { return nil }
        let block = ns.lineRange(for: selection)
        guard block.location + block.length < ns.length else { return nil }

        let next = ns.lineRange(for: NSRange(location: block.location + block.length, length: 0))
        let region = NSRange(location: block.location, length: block.length + next.length)
        let unitList = units(ns, in: region)                 // [block…, next]
        let contents = unitList.map { $0.content }
        let terms = unitList.map { $0.terminator }
        let blockCount = contents.count - 1

        // New content order: the following line first, then the block lines.
        var newContents = [contents[blockCount]]
        newContents.append(contentsOf: contents[0..<blockCount])

        let replacement = rebuild(contents: newContents, terminators: terms)

        // The moved block now starts after the (rebuilt) first line.
        let firstLen = (newContents[0] as NSString).length + (terms[0] as NSString).length
        let newBlockLoc = region.location + firstLen
        let newBlockLen = (replacement as NSString).length - firstLen
        return (replacement, region,
                NSRange(location: newBlockLoc, length: newBlockLen))
    }

    /// Duplicates the selection's line block below itself; the selection lands on
    /// the new copy. Always succeeds.
    public static func copyLinesDown(
        text: String,
        selection: NSRange
    ) -> (replacement: String, range: NSRange, newSelection: NSRange)? {
        let ns = text as NSString
        let block = ns.lineRange(for: selection)
        let blockStr = ns.substring(with: block)
        let blockLen = (blockStr as NSString).length
        let insertAt = block.location + block.length

        if endsWithNewline(blockStr) {
            return (blockStr, NSRange(location: insertAt, length: 0),
                    NSRange(location: insertAt, length: blockLen))
        } else {
            // Last line (no trailing newline): add a newline before the copy.
            return ("\n" + blockStr, NSRange(location: insertAt, length: 0),
                    NSRange(location: insertAt + 1, length: blockLen))
        }
    }

    /// Duplicates the selection's line block above itself; the selection lands on
    /// the new copy. Always succeeds.
    public static func copyLinesUp(
        text: String,
        selection: NSRange
    ) -> (replacement: String, range: NSRange, newSelection: NSRange)? {
        let ns = text as NSString
        let block = ns.lineRange(for: selection)
        let blockStr = ns.substring(with: block)
        let blockLen = (blockStr as NSString).length

        if endsWithNewline(blockStr) {
            return (blockStr, NSRange(location: block.location, length: 0),
                    NSRange(location: block.location, length: blockLen))
        } else {
            // Last line (no trailing newline): add a newline after the copy so it
            // separates from the original.
            return (blockStr + "\n", NSRange(location: block.location, length: 0),
                    NSRange(location: block.location, length: blockLen))
        }
    }

    /// Deletes the block of lines the selection covers. The caret lands at the
    /// original column on the line that shifts up (clamped to that line's length,
    /// or the document end when the last line is removed). Returns `nil` for an
    /// empty document.
    public static func deleteLines(
        text: String,
        selection: NSRange
    ) -> (replacement: String, range: NSRange, newSelection: NSRange)? {
        let ns = text as NSString
        guard ns.length > 0 else { return nil }
        let block = ns.lineRange(for: selection)
        let caretColumn = selection.location - block.location
        let atEnd = block.location + block.length == ns.length

        if atEnd && block.location > 0 {
            // Removing the trailing line(s): also drop the preceding newline so no
            // dangling blank line is left; caret goes to the new document end.
            let nlLen = precedingTerminatorLength(ns, before: block.location)
            let delRange = NSRange(location: block.location - nlLen,
                                   length: block.length + nlLen)
            let newLength = ns.length - delRange.length
            return ("", delRange,
                    NSRange(location: min(delRange.location, newLength), length: 0))
        }

        // A following line will shift up into the deleted block's position.
        let followingContentLen: Int
        if block.location + block.length < ns.length {
            let nextLine = ns.lineRange(for: NSRange(location: block.location + block.length, length: 0))
            followingContentLen = (lineContent(ns.substring(with: nextLine)) as NSString).length
        } else {
            followingContentLen = 0
        }
        let col = min(caretColumn, followingContentLen)
        return ("", block, NSRange(location: block.location + col, length: 0))
    }

    // MARK: - Helpers

    /// Splits an NSRange that covers whole lines into `(content, terminator)`
    /// units, one per line.
    private static func units(_ ns: NSString, in range: NSRange) -> [(content: String, terminator: String)] {
        var result: [(String, String)] = []
        var index = range.location
        let end = range.location + range.length
        while index < end {
            let lineRange = ns.lineRange(for: NSRange(location: index, length: 0))
            result.append(splitTerminator(ns.substring(with: lineRange)))
            let next = lineRange.location + lineRange.length
            if next <= index { break }
            index = next
        }
        return result
    }

    /// Rejoins `contents` with `terminators` positionally: content *i* keeps the
    /// terminator that originally sat at position *i*, preserving the document's
    /// newline structure (including a final line with no terminator).
    private static func rebuild(contents: [String], terminators: [String]) -> String {
        var result = ""
        for (i, content) in contents.enumerated() {
            result += content + terminators[i]
        }
        return result
    }

    private static func splitTerminator(_ line: String) -> (content: String, terminator: String) {
        let ns = line as NSString
        let end = ns.length
        if end >= 2, ns.substring(with: NSRange(location: end - 2, length: 2)) == "\r\n" {
            return (ns.substring(to: end - 2), "\r\n")
        }
        if end >= 1 {
            let last = ns.substring(from: end - 1)
            if last == "\n" || last == "\r" {
                return (ns.substring(to: end - 1), last)
            }
        }
        return (line, "")
    }

    private static func lineContent(_ line: String) -> String {
        splitTerminator(line).content
    }

    private static func endsWithNewline(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return last == "\n" || last == "\r"
    }

    private static func precedingTerminatorLength(_ ns: NSString, before loc: Int) -> Int {
        guard loc > 0 else { return 0 }
        let prev = ns.substring(with: NSRange(location: loc - 1, length: 1))
        if prev == "\n" {
            if loc - 2 >= 0, ns.substring(with: NSRange(location: loc - 2, length: 1)) == "\r" {
                return 2
            }
            return 1
        }
        if prev == "\r" { return 1 }
        return 0
    }
}
