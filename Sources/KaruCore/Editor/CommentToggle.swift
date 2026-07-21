import Foundation

/// Pure, NSTextView-independent comment-toggle logic (VS Code's ⌘/ behaviour).
///
/// Every entry point takes the document string plus the current selection and
/// returns a single replacement (or `nil` when the language has no comment
/// syntax, e.g. JSON). `EditorWindowController` is a thin wrapper that feeds the
/// result through the undo-aware text mutation path. Nothing is retained — the
/// language comment table is a `static` lookup, in keeping with the "no resident
/// data structures" rule.
public enum CommentToggle {

    /// A language's comment delimiters: a line-comment token (preferred when
    /// present) and/or a block-comment pair. A language with neither yields no
    /// comment behaviour.
    struct Tokens {
        var line: String?
        var block: (open: String, close: String)?
    }

    /// Comment delimiters per language identifier (identifiers match
    /// `LanguageDefinition.identifier` / `SupportedLanguage`). Languages with a
    /// line comment use line-comment toggling; block-only languages wrap/unwrap.
    /// JSON / JSONL carry no comment syntax and return `nil`.
    static func tokens(for languageIdentifier: String) -> Tokens? {
        switch languageIdentifier.lowercased() {
        case "python", "bash", "sh", "shell", "yaml":
            return Tokens(line: "#", block: nil)
        case "javascript", "typescript", "c", "cpp", "csharp", "java", "swift":
            return Tokens(line: "//", block: nil)
        case "sql":
            return Tokens(line: "--", block: nil)
        case "css":
            return Tokens(line: nil, block: ("/*", "*/"))
        case "html", "xml", "plist", "markdown":
            return Tokens(line: nil, block: ("<!--", "-->"))
        default:
            // JSON / JSONL / Plain Text / anything unknown: no comment syntax.
            return nil
        }
    }

    /// Toggles comments over the lines the selection covers (VS Code semantics):
    /// if every non-blank line is already commented the comments are removed,
    /// otherwise a comment is added at the common minimum indent column. Returns
    /// `nil` for languages with no comment syntax so the caller can beep.
    public static func toggle(
        text: String,
        selection: NSRange,
        languageIdentifier: String
    ) -> (replacement: String, range: NSRange, newSelection: NSRange)? {
        guard let tokens = tokens(for: languageIdentifier) else { return nil }
        if let line = tokens.line {
            return toggleLineComment(text: text, selection: selection, token: line)
        }
        if let block = tokens.block {
            return toggleBlockComment(text: text, selection: selection,
                                      open: block.open, close: block.close)
        }
        return nil
    }

    // MARK: - Line comments

    private static func toggleLineComment(
        text: String,
        selection: NSRange,
        token: String
    ) -> (replacement: String, range: NSRange, newSelection: NSRange) {
        let ns = text as NSString
        let block = ns.length == 0
            ? NSRange(location: 0, length: 0)
            : ns.lineRange(for: selection)

        let lines = splitLines(ns.substring(with: block)).map(lineComponents)

        // Non-blank line indices participate in the decision and the edit; blank
        // lines are skipped entirely (never commented, never counted).
        let nonBlank = lines.indices.filter { !isBlank(lines[$0].content) }

        // No content to comment: return the block unchanged (no-op edit).
        guard !nonBlank.isEmpty else {
            let original = ns.substring(with: block)
            return (original, block, NSRange(location: block.location,
                                             length: (original as NSString).length))
        }

        let minIndent = nonBlank
            .map { leadingWhitespaceLength(lines[$0].content) }
            .min() ?? 0

        let allCommented = nonBlank.allSatisfy { i in
            let content = lines[i].content as NSString
            let wsLen = leadingWhitespaceLength(lines[i].content)
            return content.substring(from: wsLen).hasPrefix(token)
        }

        var result = ""
        for (i, unit) in lines.enumerated() {
            var content = unit.content
            if nonBlank.contains(i) {
                if allCommented {
                    content = removeComment(content, token: token)
                } else {
                    content = addComment(content, token: token, atColumn: minIndent)
                }
            }
            result += content + unit.terminator
        }

        return (result, block,
                NSRange(location: block.location, length: (result as NSString).length))
    }

    /// Inserts `token + " "` at `column` (the common minimum indent) of `content`.
    private static func addComment(_ content: String, token: String, atColumn column: Int) -> String {
        let ns = content as NSString
        let safeColumn = min(column, ns.length)
        return ns.substring(to: safeColumn) + token + " " + ns.substring(from: safeColumn)
    }

    /// Removes the line comment token (and one following space, if present) at the
    /// line's own indent, tolerating a missing space after the token.
    private static func removeComment(_ content: String, token: String) -> String {
        let ns = content as NSString
        let wsLen = leadingWhitespaceLength(content)
        let afterWS = ns.substring(from: wsLen)
        guard afterWS.hasPrefix(token) else { return content }
        var rest = String(afterWS.dropFirst(token.count))
        if rest.hasPrefix(" ") { rest = String(rest.dropFirst()) }
        return ns.substring(to: wsLen) + rest
    }

    // MARK: - Block comments

    private static func toggleBlockComment(
        text: String,
        selection: NSRange,
        open: String,
        close: String
    ) -> (replacement: String, range: NSRange, newSelection: NSRange) {
        let ns = text as NSString

        let targetRange: NSRange
        if selection.length > 0 {
            targetRange = selection
        } else {
            let lineRange = ns.length == 0
                ? NSRange(location: 0, length: 0)
                : ns.lineRange(for: NSRange(location: selection.location, length: 0))
            let content = lineComponents(ns.substring(with: lineRange)).content
            targetRange = NSRange(location: lineRange.location,
                                  length: (content as NSString).length)
        }

        let inner = ns.substring(with: targetRange)
        let trimmed = inner.trimmingCharacters(in: .whitespacesAndNewlines)

        let replacement: String
        if trimmed.hasPrefix(open), trimmed.hasSuffix(close),
           trimmed.count >= open.count + close.count {
            var body = String(trimmed.dropFirst(open.count).dropLast(close.count))
            if body.hasPrefix(" ") { body = String(body.dropFirst()) }
            if body.hasSuffix(" ") { body = String(body.dropLast()) }
            replacement = body
        } else {
            replacement = "\(open) \(inner) \(close)"
        }

        return (replacement, targetRange,
                NSRange(location: targetRange.location,
                        length: (replacement as NSString).length))
    }

    // MARK: - Helpers

    /// Splits a block of text into lines, each retaining its line terminator.
    private static func splitLines(_ text: String) -> [String] {
        let ns = text as NSString
        var lines: [String] = []
        var index = 0
        while index < ns.length {
            let range = ns.lineRange(for: NSRange(location: index, length: 0))
            lines.append(ns.substring(with: range))
            index = range.location + range.length
        }
        return lines
    }

    /// Separates a line into its content and trailing terminator (`\n`, `\r\n`,
    /// `\r`, or empty for the final line).
    private static func lineComponents(_ line: String) -> (content: String, terminator: String) {
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

    private static func leadingWhitespaceLength(_ content: String) -> Int {
        let ns = content as NSString
        var end = 0
        while end < ns.length {
            let c = ns.substring(with: NSRange(location: end, length: 1))
            if c == " " || c == "\t" { end += 1 } else { break }
        }
        return end
    }

    private static func isBlank(_ content: String) -> Bool {
        content.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
