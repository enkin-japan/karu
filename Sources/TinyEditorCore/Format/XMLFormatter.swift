import Foundation

/// Error thrown by ``XMLFormatter`` when the input text is not well-formed
/// XML (or a well-formed plist, which is itself just XML).
public struct XMLFormatError: Error, Equatable {
    /// 1-based line number (in the original input) where the problem was detected.
    public let line: Int
    /// Human readable description of the problem.
    public let message: String

    public init(line: Int, message: String) {
        self.line = line
        self.message = message
    }
}

/// A dependency-free XML / plist pretty printer.
///
/// This intentionally avoids `XMLParser` / `XMLDocument` because those APIs
/// are not reliably available in a bare command-line-tools environment and
/// because a hand written scanner makes it trivial to copy attribute
/// lexemes, comments, and CDATA sections through byte-for-byte instead of
/// re-encoding them. Entities (`&amp;`, `&lt;`, ...) are never decoded --
/// they are treated as ordinary text characters and passed through verbatim.
public enum XMLFormatter {

    /// Pretty-prints a single XML (or plist) document, re-indenting it with
    /// `indentWidth` spaces per nesting level.
    ///
    /// The top level may contain an XML declaration, a DOCTYPE, any number
    /// of comments, and exactly one root element, in any order. Elements
    /// that contain only text (no child elements) are kept on a single
    /// line, which is what keeps plist output such as
    /// `<key>CFBundleName</key>` readable.
    public static func prettyPrint(_ text: String, indentWidth: Int = 2) throws -> String {
        let scanner = Scanner(text)
        let topLevel = try parseDocument(scanner)
        return render(topLevel, indentWidth: indentWidth)
    }

    // MARK: - AST

    private indirect enum Node {
        /// Raw content between `<?` and `?>`, outer whitespace trimmed.
        case declaration(String)
        /// Raw content between `<!DOCTYPE` and `>`, outer whitespace trimmed.
        case doctype(String)
        /// Raw content between `<!--` and `-->`, kept exactly as written.
        case comment(String)
        /// Raw content between `<![CDATA[` and `]]>`, kept exactly as written.
        case cdata(String)
        /// Raw text between tags, outer whitespace trimmed, entities undecoded.
        case text(String)
        case element(name: String, attributes: String, children: [Node], selfClosing: Bool)
    }

    // MARK: - Scanner

    private final class Scanner {
        let chars: [Character]
        var i: Int = 0
        var line: Int = 1

        init(_ text: String) {
            chars = Array(text)
        }

        var isAtEnd: Bool { i >= chars.count }

        func peek(_ offset: Int = 0) -> Character? {
            let idx = i + offset
            return idx < chars.count ? chars[idx] : nil
        }

        @discardableResult
        func advance() -> Character {
            let c = chars[i]
            i += 1
            if c == "\n" { line += 1 }
            return c
        }

        func match(_ s: String) -> Bool {
            let sc = Array(s)
            guard i + sc.count <= chars.count else { return false }
            for k in 0..<sc.count where chars[i + k] != sc[k] { return false }
            return true
        }

        @discardableResult
        func consume(_ s: String) -> Bool {
            guard match(s) else { return false }
            for _ in 0..<s.count { advance() }
            return true
        }

        func skipWhitespace() {
            while let c = peek(), c == " " || c == "\t" || c == "\r" || c == "\n" {
                advance()
            }
        }
    }

    // MARK: - Parsing: document

    private static func parseDocument(_ s: Scanner) throws -> [Node] {
        var topLevel: [Node] = []
        var rootSeen = false

        while true {
            s.skipWhitespace()
            if s.isAtEnd {
                break
            }
            guard s.peek() == "<" else {
                throw XMLFormatError(line: s.line, message: "unexpected content at top level")
            }

            if s.match("<?") {
                topLevel.append(try parseDeclaration(s))
                continue
            }
            if s.match("<!--") {
                topLevel.append(try parseComment(s))
                continue
            }
            if s.match("<!DOCTYPE") {
                topLevel.append(try parseDoctype(s))
                continue
            }
            if s.match("<![CDATA[") {
                throw XMLFormatError(line: s.line, message: "CDATA section is not allowed at the top level")
            }
            if rootSeen {
                throw XMLFormatError(line: s.line, message: "multiple root elements are not allowed")
            }
            topLevel.append(try parseElement(s))
            rootSeen = true
        }

        guard rootSeen else {
            throw XMLFormatError(line: s.line, message: "missing root element")
        }
        return topLevel
    }

    // MARK: - Parsing: prolog constructs

    private static func parseDeclaration(_ s: Scanner) throws -> Node {
        let startLine = s.line
        s.consume("<?")
        var content = ""
        while true {
            if s.isAtEnd {
                throw XMLFormatError(line: startLine, message: "unterminated XML declaration, missing '?>'")
            }
            if s.match("?>") {
                s.consume("?>")
                break
            }
            content.append(s.advance())
        }
        return .declaration(content.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func parseComment(_ s: Scanner) throws -> Node {
        let startLine = s.line
        s.consume("<!--")
        var content = ""
        while true {
            if s.isAtEnd {
                throw XMLFormatError(line: startLine, message: "unterminated comment, missing '-->'")
            }
            if s.match("-->") {
                s.consume("-->")
                break
            }
            content.append(s.advance())
        }
        return .comment(content)
    }

    private static func parseCDATA(_ s: Scanner) throws -> Node {
        let startLine = s.line
        s.consume("<![CDATA[")
        var content = ""
        while true {
            if s.isAtEnd {
                throw XMLFormatError(line: startLine, message: "unterminated CDATA section, missing ']]>'")
            }
            if s.match("]]>") {
                s.consume("]]>")
                break
            }
            content.append(s.advance())
        }
        return .cdata(content)
    }

    private static func parseDoctype(_ s: Scanner) throws -> Node {
        let startLine = s.line
        s.consume("<!DOCTYPE")
        var content = ""
        var quote: Character?
        while true {
            guard let c = s.peek() else {
                throw XMLFormatError(line: startLine, message: "unterminated DOCTYPE declaration, missing '>'")
            }
            if let q = quote {
                content.append(s.advance())
                if c == q { quote = nil }
                continue
            }
            if c == "\"" || c == "'" {
                quote = c
                content.append(s.advance())
                continue
            }
            if c == ">" {
                s.advance()
                break
            }
            content.append(s.advance())
        }
        return .doctype(content.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Parsing: elements

    private static func parseElement(_ s: Scanner) throws -> Node {
        let startLine = s.line
        guard s.consume("<") else {
            throw XMLFormatError(line: s.line, message: "expected '<' to start element")
        }
        guard let name = scanName(s) else {
            throw XMLFormatError(line: startLine, message: "expected element name after '<'")
        }
        let (attributes, selfClosing) = try scanTagRemainder(s, startLine: startLine, tagName: name)

        if selfClosing {
            return .element(name: name, attributes: attributes, children: [], selfClosing: true)
        }

        var children: [Node] = []
        var textBuffer = ""

        func flushText() {
            let trimmed = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                children.append(.text(trimmed))
            }
            textBuffer = ""
        }

        while true {
            guard !s.isAtEnd else {
                throw XMLFormatError(
                    line: startLine,
                    message: "unclosed element <\(name)>, missing matching </\(name)>"
                )
            }

            if s.peek() == "<" {
                if s.match("<!--") {
                    flushText()
                    children.append(try parseComment(s))
                    continue
                }
                if s.match("<![CDATA[") {
                    flushText()
                    children.append(try parseCDATA(s))
                    continue
                }
                if s.match("</") {
                    flushText()
                    let endLine = s.line
                    s.consume("</")
                    guard let endName = scanName(s) else {
                        throw XMLFormatError(line: endLine, message: "expected element name in end tag")
                    }
                    s.skipWhitespace()
                    guard s.consume(">") else {
                        throw XMLFormatError(line: endLine, message: "expected '>' to close end tag </\(endName)>")
                    }
                    guard endName == name else {
                        throw XMLFormatError(
                            line: endLine,
                            message: "mismatched closing tag: expected </\(name)> but found </\(endName)>"
                        )
                    }
                    return .element(name: name, attributes: attributes, children: children, selfClosing: false)
                }
                flushText()
                children.append(try parseElement(s))
                continue
            }

            textBuffer.append(s.advance())
        }
    }

    private static func scanName(_ s: Scanner) -> String? {
        guard let c = s.peek(), isNameStartChar(c) else { return nil }
        var name = String(s.advance())
        while let c = s.peek(), isNameChar(c) {
            name.append(s.advance())
        }
        return name
    }

    private static func isNameStartChar(_ c: Character) -> Bool {
        c.isLetter || c == "_" || c == ":"
    }

    private static func isNameChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_" || c == "-" || c == "." || c == ":"
    }

    /// Scans everything between the end of a start-tag's name and its
    /// closing `>` (or `/>`), respecting quoted attribute values so that a
    /// `>` or `/` inside an attribute value is not mistaken for the end of
    /// the tag. Returns the raw, outer-trimmed attribute text (order and
    /// quoting preserved verbatim) and whether the tag was self-closing.
    private static func scanTagRemainder(_ s: Scanner, startLine: Int, tagName: String) throws -> (String, Bool) {
        var raw = ""
        var quote: Character?

        while true {
            guard let c = s.peek() else {
                throw XMLFormatError(line: startLine, message: "unterminated tag <\(tagName)>, missing '>'")
            }
            if let q = quote {
                raw.append(s.advance())
                if c == q { quote = nil }
                continue
            }
            if c == "\"" || c == "'" {
                quote = c
                raw.append(s.advance())
                continue
            }
            if c == ">" {
                s.advance()
                var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                var selfClosing = false
                if trimmed.hasSuffix("/") {
                    selfClosing = true
                    trimmed.removeLast()
                    trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return (trimmed, selfClosing)
            }
            raw.append(s.advance())
        }
    }

    // MARK: - Rendering

    private static func render(_ nodes: [Node], indentWidth: Int) -> String {
        var out = ""
        for (idx, node) in nodes.enumerated() {
            if idx > 0 { out += "\n" }
            renderNode(node, level: 0, indentWidth: indentWidth, into: &out)
        }
        return out
    }

    private static func renderNode(_ node: Node, level: Int, indentWidth: Int, into out: inout String) {
        let indent = String(repeating: " ", count: level * indentWidth)

        switch node {
        case .declaration(let content):
            out += "<?" + content + "?>"
        case .doctype(let content):
            out += "<!DOCTYPE " + content + ">"
        case .comment(let content):
            out += indent + "<!--" + content + "-->"
        case .cdata(let content):
            out += indent + "<![CDATA[" + content + "]]>"
        case .text(let content):
            out += indent + content
        case .element(let name, let attributes, let children, let selfClosing):
            let openTag = "<" + name + (attributes.isEmpty ? "" : " " + attributes)

            if selfClosing {
                out += indent + openTag + "/>"
                return
            }
            if children.isEmpty {
                out += indent + openTag + "></" + name + ">"
                return
            }
            if children.count == 1, case .text(let textContent) = children[0] {
                out += indent + openTag + ">" + textContent + "</" + name + ">"
                return
            }
            if children.count == 1, case .cdata(let cdataContent) = children[0] {
                out += indent + openTag + "><![CDATA[" + cdataContent + "]]></" + name + ">"
                return
            }

            out += indent + openTag + ">"
            for child in children {
                out += "\n"
                renderNode(child, level: level + 1, indentWidth: indentWidth, into: &out)
            }
            out += "\n" + indent + "</" + name + ">"
        }
    }
}
