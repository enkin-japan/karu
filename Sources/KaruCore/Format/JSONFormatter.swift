import Foundation

/// Error thrown by ``JSONFormatter`` when the input text is not well-formed JSON.
public struct JSONFormatError: Error, Equatable {
    /// 1-based line number (in the original input) where the problem was detected.
    public let line: Int
    /// Human readable description of the problem.
    public let message: String

    public init(line: Int, message: String) {
        self.line = line
        self.message = message
    }
}

/// A dependency-free JSON / JSONL pretty printer.
///
/// This intentionally avoids `JSONSerialization` because that API does not
/// preserve key order and loses precision on large numeric literals. Instead
/// this performs a single-pass hand written tokenizer followed by a
/// recursive-descent re-layout pass that copies string and number lexemes
/// through untouched.
public enum JSONFormatter {

    /// Pretty-prints a single JSON document, re-indenting it with `indentWidth`
    /// spaces per nesting level.
    public static func prettyPrint(_ text: String, indentWidth: Int = 2) throws -> String {
        let tokens = try tokenize(text)
        return try render(tokens: tokens, style: .pretty(indentWidth: indentWidth))
    }

    /// Formats a JSONL document: every non-empty line is parsed as an
    /// independent JSON value and rewritten as a single compact line. Blank
    /// lines are dropped, line order is preserved, and thrown errors report
    /// the original document line number.
    public static func formatJSONL(_ text: String) throws -> String {
        var resultLines: [String] = []
        var lineNumber = 0

        let rawLines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for rawLine in rawLines {
            lineNumber += 1

            var line = String(rawLine)
            if line.hasSuffix("\r") {
                line.removeLast()
            }

            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                continue
            }

            do {
                let tokens = try tokenize(line)
                let compact = try render(tokens: tokens, style: .compact)
                resultLines.append(compact)
            } catch let error as JSONFormatError {
                throw JSONFormatError(line: lineNumber, message: error.message)
            }
        }

        return resultLines.joined(separator: "\n")
    }

    // MARK: - Rendering style

    private enum Style {
        case pretty(indentWidth: Int)
        case compact
    }

    private static func isCompact(_ style: Style) -> Bool {
        if case .compact = style {
            return true
        }
        return false
    }

    private static func appendIndent(_ level: Int, style: Style, into out: inout String) {
        guard case .pretty(let width) = style else { return }
        out += "\n" + String(repeating: " ", count: max(0, level) * width)
    }

    // MARK: - Tokens

    private enum TokenKind {
        case leftBrace
        case rightBrace
        case leftBracket
        case rightBracket
        case colon
        case comma
        case string(String)
        case number(String)
        case literal(String)
    }

    private struct Token {
        let kind: TokenKind
        let line: Int
    }

    // MARK: - Tokenizer

    private static func tokenize(_ text: String) throws -> [Token] {
        var tokens: [Token] = []
        let chars = Array(text)
        let n = chars.count
        var i = 0
        var line = 1

        while i < n {
            let c = chars[i]
            switch c {
            case " ", "\t", "\r":
                i += 1
            case "\n":
                line += 1
                i += 1
            case "{":
                tokens.append(Token(kind: .leftBrace, line: line))
                i += 1
            case "}":
                tokens.append(Token(kind: .rightBrace, line: line))
                i += 1
            case "[":
                tokens.append(Token(kind: .leftBracket, line: line))
                i += 1
            case "]":
                tokens.append(Token(kind: .rightBracket, line: line))
                i += 1
            case ":":
                tokens.append(Token(kind: .colon, line: line))
                i += 1
            case ",":
                tokens.append(Token(kind: .comma, line: line))
                i += 1
            case "\"":
                let (lexeme, consumed, linesConsumed) = try scanString(chars, i, startLine: line)
                tokens.append(Token(kind: .string(lexeme), line: line))
                i += consumed
                line += linesConsumed
            case "t", "f", "n":
                guard let (word, consumed) = matchKeyword(chars, i) else {
                    throw JSONFormatError(line: line, message: "unexpected character '\(c)'")
                }
                tokens.append(Token(kind: .literal(word), line: line))
                i += consumed
            case "-", "0"..."9":
                let (lexeme, consumed) = try scanNumber(chars, i, line: line)
                tokens.append(Token(kind: .number(lexeme), line: line))
                i += consumed
            default:
                throw JSONFormatError(line: line, message: "unexpected character '\(c)'")
            }
        }

        return tokens
    }

    /// Scans a JSON string literal starting at `chars[i]` (which must be `"`).
    /// Returns the raw lexeme (including surrounding quotes and escapes,
    /// undecoded), the number of characters consumed, and how many newlines
    /// were consumed (only possible via an escaped `\n` inside the literal
    /// text of a raw, otherwise-invalid, embedded newline).
    private static func scanString(_ chars: [Character], _ start: Int, startLine: Int) throws -> (String, Int, Int) {
        var lexeme = "\""
        var i = start + 1
        let n = chars.count
        var linesConsumed = 0

        while i < n {
            let sc = chars[i]
            if sc == "\\" {
                lexeme.append(sc)
                i += 1
                if i < n {
                    lexeme.append(chars[i])
                    if chars[i] == "\n" { linesConsumed += 1 }
                    i += 1
                }
                continue
            }
            if sc == "\n" { linesConsumed += 1 }
            lexeme.append(sc)
            i += 1
            if sc == "\"" {
                return (lexeme, i - start, linesConsumed)
            }
        }

        throw JSONFormatError(line: startLine, message: "unterminated string literal")
    }

    private static func matchKeyword(_ chars: [Character], _ i: Int) -> (String, Int)? {
        for word in ["true", "false", "null"] {
            let wordChars = Array(word)
            guard i + wordChars.count <= chars.count else { continue }
            var matches = true
            for k in 0..<wordChars.count where chars[i + k] != wordChars[k] {
                matches = false
                break
            }
            if matches {
                return (word, wordChars.count)
            }
        }
        return nil
    }

    private static func scanNumber(_ chars: [Character], _ start: Int, line: Int) throws -> (String, Int) {
        let n = chars.count
        var j = start

        if j < n, chars[j] == "-" {
            j += 1
        }

        guard j < n, isDigit(chars[j]) else {
            throw JSONFormatError(line: line, message: "invalid number literal")
        }
        while j < n, isDigit(chars[j]) {
            j += 1
        }

        if j < n, chars[j] == "." {
            var k = j + 1
            guard k < n, isDigit(chars[k]) else {
                throw JSONFormatError(line: line, message: "invalid number literal: expected digit after '.'")
            }
            while k < n, isDigit(chars[k]) {
                k += 1
            }
            j = k
        }

        if j < n, chars[j] == "e" || chars[j] == "E" {
            var k = j + 1
            if k < n, chars[k] == "+" || chars[k] == "-" {
                k += 1
            }
            guard k < n, isDigit(chars[k]) else {
                throw JSONFormatError(line: line, message: "invalid number literal: expected digit in exponent")
            }
            while k < n, isDigit(chars[k]) {
                k += 1
            }
            j = k
        }

        return (String(chars[start..<j]), j - start)
    }

    private static func isDigit(_ c: Character) -> Bool {
        c >= "0" && c <= "9"
    }

    // MARK: - Rendering (structure validation + re-layout in one pass)

    private static func render(tokens: [Token], style: Style) throws -> String {
        var idx = 0
        var out = ""
        try renderValue(tokens, &idx, indent: 0, style: style, into: &out)
        if idx != tokens.count {
            throw JSONFormatError(line: tokens[idx].line, message: "unexpected token after top-level JSON value")
        }
        return out
    }

    private static func renderValue(
        _ tokens: [Token],
        _ idx: inout Int,
        indent: Int,
        style: Style,
        into out: inout String
    ) throws {
        guard idx < tokens.count else {
            throw JSONFormatError(line: tokens.last?.line ?? 1, message: "unexpected end of input, expected a value")
        }

        let token = tokens[idx]
        switch token.kind {
        case .leftBrace:
            idx += 1
            try renderObject(tokens, &idx, indent: indent, style: style, into: &out, openLine: token.line)
        case .leftBracket:
            idx += 1
            try renderArray(tokens, &idx, indent: indent, style: style, into: &out, openLine: token.line)
        case .string(let raw):
            out += raw
            idx += 1
        case .number(let raw):
            out += raw
            idx += 1
        case .literal(let raw):
            out += raw
            idx += 1
        default:
            throw JSONFormatError(line: token.line, message: "unexpected token, expected a value")
        }
    }

    private static func renderObject(
        _ tokens: [Token],
        _ idx: inout Int,
        indent: Int,
        style: Style,
        into out: inout String,
        openLine: Int
    ) throws {
        if idx < tokens.count, case .rightBrace = tokens[idx].kind {
            idx += 1
            out += "{}"
            return
        }
        guard idx < tokens.count else {
            throw JSONFormatError(line: openLine, message: "unclosed object, missing '}'")
        }

        out += "{"
        let childIndent = indent + 1

        while true {
            guard idx < tokens.count, case .string(let keyRaw) = tokens[idx].kind else {
                let line = idx < tokens.count ? tokens[idx].line : openLine
                throw JSONFormatError(line: line, message: "expected string key in object")
            }
            idx += 1

            appendIndent(childIndent, style: style, into: &out)
            out += keyRaw

            guard idx < tokens.count, case .colon = tokens[idx].kind else {
                let line = idx < tokens.count ? tokens[idx].line : openLine
                throw JSONFormatError(line: line, message: "expected ':' after object key")
            }
            idx += 1
            out += isCompact(style) ? ":" : ": "

            try renderValue(tokens, &idx, indent: childIndent, style: style, into: &out)

            guard idx < tokens.count else {
                throw JSONFormatError(line: openLine, message: "unclosed object, missing '}'")
            }

            switch tokens[idx].kind {
            case .comma:
                idx += 1
                out += ","
                continue
            case .rightBrace:
                idx += 1
                appendIndent(indent, style: style, into: &out)
                out += "}"
                return
            default:
                throw JSONFormatError(line: tokens[idx].line, message: "expected ',' or '}' in object")
            }
        }
    }

    private static func renderArray(
        _ tokens: [Token],
        _ idx: inout Int,
        indent: Int,
        style: Style,
        into out: inout String,
        openLine: Int
    ) throws {
        if idx < tokens.count, case .rightBracket = tokens[idx].kind {
            idx += 1
            out += "[]"
            return
        }
        guard idx < tokens.count else {
            throw JSONFormatError(line: openLine, message: "unclosed array, missing ']'")
        }

        out += "["
        let childIndent = indent + 1

        while true {
            appendIndent(childIndent, style: style, into: &out)
            try renderValue(tokens, &idx, indent: childIndent, style: style, into: &out)

            guard idx < tokens.count else {
                throw JSONFormatError(line: openLine, message: "unclosed array, missing ']'")
            }

            switch tokens[idx].kind {
            case .comma:
                idx += 1
                out += ","
                continue
            case .rightBracket:
                idx += 1
                appendIndent(indent, style: style, into: &out)
                out += "]"
                return
            default:
                throw JSONFormatError(line: tokens[idx].line, message: "expected ',' or ']' in array")
            }
        }
    }
}
