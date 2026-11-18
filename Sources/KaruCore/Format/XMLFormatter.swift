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
///
/// **Only a limited well-formedness check, not an XML validator.** It checks
/// what it needs to re-indent safely: balanced and matching tags, terminated
/// comments / CDATA / processing instructions / DOCTYPE, one root element,
/// attributes written as `name = "value"` or `name = 'value'`, and no
/// attribute name twice on one element (names compared byte-wise). It does
/// not check entities, namespaces, the encoding, the DTD, or which
/// characters are allowed in names and text.
///
/// Implementation (RELIABILITY-PLAN F7): the input is scanned as UTF-8 bytes
/// with a cursor, without recursion (open elements live on an explicit stack
/// bounded by ``FormatLimits/maxDepth``). Pass 1 validates and measures: it
/// records one bit per non-self-closing element ("verbatim" or "expanded",
/// decided when the element closes) and computes the exact output size, so
/// an oversized result is refused before anything is allocated. Pass 2
/// re-scans and writes straight into the result `String`'s storage.
/// Names keep the original `Character` rules (Unicode letters / numbers,
/// canonically equivalent end-tag names match); markup delimiters are now
/// matched as bytes, so a combining mark written directly after `<`, `>` or a
/// quote no longer hides that delimiter as it did under grapheme comparison.
public enum XMLFormatter {

    /// Pretty-prints a single XML (or plist) document, re-indenting it with
    /// `indentWidth` spaces per nesting level (negative widths count as 0).
    ///
    /// The top level may contain an XML declaration, a DOCTYPE (with or
    /// without an internal subset), any number of comments, and exactly one
    /// root element, in any order. Elements containing character data
    /// (text or CDATA, even whitespace only) or `xml:space="preserve"` retain
    /// their exact inner source, including whitespace-only and mixed content.
    /// Elements without character data are expanded with indentation; their
    /// comments and processing instructions get a line of their own, like
    /// child elements, with the content kept verbatim. No schema is assumed
    /// to discard whitespace.
    ///
    /// - Throws: ``XMLFormatError`` for malformed input;
    ///   ``FormatLimitError/nestingTooDeep(line:limit:)`` when elements nest
    ///   deeper than `limits.maxDepth` (exactly `maxDepth` levels is fine);
    ///   ``FormatLimitError/outputTooLarge(limitBytes:)`` when the result
    ///   would exceed `limits.maxOutputBytes(forInputBytes:)`.
    public static func prettyPrint(
        _ text: String,
        indentWidth: Int = 2,
        limits: FormatLimits = .standard
    ) throws -> String {
        let width = max(0, indentWidth)
        // A native String is read in place. The text view's string is usually
        // a bridged NSString: copy its UTF-8 once into an exact-size array
        // (measured: `String.withUTF8` on a bridged 4.9 MB string peaked at
        // twice the input, `Array(utf8)` at once).
        if let result = try text.utf8.withContiguousStorageIfAvailable({ bytes in
            try format(bytes, indentWidth: width, limits: limits)
        }) {
            return result
        }
        let bytes = Array(text.utf8)
        return try bytes.withUnsafeBufferPointer { try format($0, indentWidth: width, limits: limits) }
    }

    private static func format(
        _ src: UnsafeBufferPointer<UInt8>,
        indentWidth: Int,
        limits: FormatLimits
    ) throws -> String {
        let limit = limits.maxOutputBytes(forInputBytes: src.count)

        var measurer = Measurer(src: src, indentWidth: indentWidth, limit: limit)
        var pass1 = Scanner(src: src, maxDepth: limits.maxDepth)
        try pass1.run(&measurer)
        let total = measurer.total
        guard total <= limit, total < Int.max else {
            throw FormatLimitError.outputTooLarge(limitBytes: limit)
        }

        var consistent = true
        let result = try String(unsafeUninitializedCapacity: total) { out in
            var renderer = Renderer(src: src, out: out, verbatimBits: measurer.verbatimBits,
                                    indentWidth: indentWidth)
            var pass2 = Scanner(src: src, maxDepth: limits.maxDepth)
            try pass2.run(&renderer)
            consistent = !renderer.overflowed && renderer.count == total
            return renderer.count
        }
        // Both passes run the same scanner over the same bytes, so the
        // measured size is exact; this only guards against a future change
        // breaking that invariant (the writer never goes out of bounds).
        guard consistent else {
            assertionFailure("XMLFormatter: measured and rendered sizes differ")
            throw XMLFormatError(line: 1, message: "internal formatter error")
        }
        return result
    }

    // MARK: - Byte constants

    private static let lt: UInt8 = 0x3C        // <
    private static let gt: UInt8 = 0x3E        // >
    private static let slash: UInt8 = 0x2F     // /
    private static let equals: UInt8 = 0x3D    // =
    private static let dquote: UInt8 = 0x22    // "
    private static let squote: UInt8 = 0x27    // '
    private static let lbracket: UInt8 = 0x5B  // [
    private static let rbracket: UInt8 = 0x5D  // ]
    private static let newline: UInt8 = 0x0A
    private static let cr: UInt8 = 0x0D
    private static let space: UInt8 = 0x20

    private static let piOpen: [UInt8] = Array("<?".utf8)
    private static let piClose: [UInt8] = Array("?>".utf8)
    private static let commentOpen: [UInt8] = Array("<!--".utf8)
    private static let commentClose: [UInt8] = Array("-->".utf8)
    private static let cdataOpen: [UInt8] = Array("<![CDATA[".utf8)
    private static let cdataClose: [UInt8] = Array("]]>".utf8)
    private static let doctypeOpen: [UInt8] = Array("<!DOCTYPE".utf8)
    private static let endTagOpen: [UInt8] = Array("</".utf8)
    private static let xmlSpace: [UInt8] = Array("xml:space".utf8)
    private static let doctypeRenderedPrefix: [UInt8] = Array("<!DOCTYPE ".utf8)

    /// `CharacterSet.whitespacesAndNewlines`, which the original formatter
    /// trimmed with; its ASCII members are tested inline.
    private static let unicodeWhitespace = CharacterSet.whitespacesAndNewlines

    // MARK: - Events

    /// Markup copied through with its delimiters: `<?…?>`, `<!DOCTYPE …>`,
    /// `<!--…-->`.
    fileprivate enum Markup {
        case processingInstruction, doctype, comment

        var prefix: [UInt8] {
            switch self {
            case .processingInstruction: return XMLFormatter.piOpen
            case .doctype: return XMLFormatter.doctypeRenderedPrefix
            case .comment: return XMLFormatter.commentOpen
            }
        }

        var suffix: [UInt8] {
            switch self {
            case .processingInstruction: return XMLFormatter.piClose
            case .doctype: return [XMLFormatter.gt]
            case .comment: return XMLFormatter.commentClose
            }
        }

        var delimiterLength: Int {
            switch self {
            case .processingInstruction: return 4
            case .doctype: return 11
            case .comment: return 7
            }
        }
    }

    /// Receives the scanner's events. `level` is the 0-based nesting level the
    /// item is rendered at (the root element and top-level items are level 0).
    fileprivate protocol Sink {
        mutating func markup(_ kind: Markup, content: Range<Int>, level: Int)
        mutating func startElement(name: Range<Int>, attributes: Range<Int>, selfClosing: Bool, level: Int)
        mutating func endElement(name: Range<Int>, inner: Range<Int>, level: Int)
        /// Text or a CDATA section directly inside the innermost open element.
        mutating func characterData()
    }

    // MARK: - Scanner

    /// One open element on the scanner's explicit stack (byte offsets only).
    private struct OpenElement {
        var tagStart: Int
        var nameStart: Int
        var nameEnd: Int
        var innerStart: Int
    }

    private struct Scanner {
        let src: UnsafeBufferPointer<UInt8>
        let end: Int
        let maxDepth: Int
        var pos = 0
        var stack: [OpenElement] = []
        /// Attribute names of the start tag being scanned (reused per tag).
        var attributeNames: [Range<Int>] = []
        /// Hashes of `attributeNames`, used only for tags with many attributes.
        var attributeHashes: Set<Int> = []

        init(src: UnsafeBufferPointer<UInt8>, maxDepth: Int) {
            self.src = src
            self.end = src.count
            self.maxDepth = maxDepth
        }

        // MARK: Driver

        mutating func run<S: Sink>(_ sink: inout S) throws {
            var rootSeen = false
            while true {
                skipXMLWhitespace()
                if pos >= end { break }
                guard src[pos] == lt else {
                    throw error(at: pos, "unexpected content at top level")
                }
                if matches(piOpen) {
                    let content = try scanTerminated(open: piOpen, close: piClose,
                                                     message: "unterminated XML declaration, missing '?>'")
                    sink.markup(.processingInstruction, content: trimmed(content), level: 0)
                    continue
                }
                if matches(commentOpen) {
                    let content = try scanTerminated(open: commentOpen, close: commentClose,
                                                     message: "unterminated comment, missing '-->'")
                    sink.markup(.comment, content: content, level: 0)
                    continue
                }
                if matches(doctypeOpen) {
                    let content = try scanDoctype()
                    sink.markup(.doctype, content: trimmed(content), level: 0)
                    continue
                }
                if matches(cdataOpen) {
                    throw error(at: pos, "CDATA section is not allowed at the top level")
                }
                if rootSeen {
                    throw error(at: pos, "multiple root elements are not allowed")
                }
                try scanRootElement(&sink)
                rootSeen = true
            }
            guard rootSeen else {
                throw error(at: end, "missing root element")
            }
        }

        /// Scans the root element and everything inside it, iteratively.
        private mutating func scanRootElement<S: Sink>(_ sink: inout S) throws {
            try scanStartTag(&sink)
            while let top = stack.last {
                guard pos < end else {
                    let name = string(top.nameStart..<top.nameEnd)
                    throw error(at: top.tagStart, "unclosed element <\(name)>, missing matching </\(name)>")
                }
                if src[pos] == lt {
                    if matches(commentOpen) {
                        let content = try scanTerminated(open: commentOpen, close: commentClose,
                                                         message: "unterminated comment, missing '-->'")
                        sink.markup(.comment, content: content, level: stack.count)
                        continue
                    }
                    if matches(cdataOpen) {
                        _ = try scanTerminated(open: cdataOpen, close: cdataClose,
                                               message: "unterminated CDATA section, missing ']]>'")
                        sink.characterData()
                        continue
                    }
                    if matches(endTagOpen) {
                        try scanEndTag(&sink)
                        continue
                    }
                    if matches(piOpen) {
                        let content = try scanTerminated(open: piOpen, close: piClose,
                                                         message: "unterminated processing instruction, missing '?>'")
                        sink.markup(.processingInstruction, content: content, level: stack.count)
                        continue
                    }
                    try scanStartTag(&sink)
                    continue
                }
                // Character data runs to the next '<' (or the end of input,
                // which the loop then reports as an unclosed element).
                pos = index(of: lt, from: pos) ?? end
                sink.characterData()
            }
        }

        // MARK: Tags

        /// At a '<' that starts an element.
        private mutating func scanStartTag<S: Sink>(_ sink: inout S) throws {
            let tagStart = pos
            pos += 1
            guard let nameEnd = nameEnd(at: pos) else {
                throw error(at: tagStart, "expected element name after '<'")
            }
            let name = pos..<nameEnd
            pos = nameEnd
            if stack.count >= maxDepth {
                throw FormatLimitError.nestingTooDeep(line: line(at: tagStart), limit: maxDepth)
            }
            let (attributes, selfClosing) = try scanAttributes(tagStart: tagStart, name: name)
            sink.startElement(name: name, attributes: attributes, selfClosing: selfClosing, level: stack.count)
            if !selfClosing {
                stack.append(OpenElement(tagStart: tagStart, nameStart: name.lowerBound,
                                         nameEnd: name.upperBound, innerStart: pos))
            }
        }

        /// Scans the attributes after a start tag's name through its `>` or
        /// `/>`. Returns the byte range from the first attribute name to the
        /// last closing quote (empty without attributes) — the original
        /// formatter's trimmed attribute text, copied verbatim.
        private mutating func scanAttributes(tagStart: Int, name: Range<Int>) throws -> (Range<Int>, Bool) {
            var first = -1
            var last = -1
            attributeNames.removeAll(keepingCapacity: true)

            func unterminated() -> XMLFormatError {
                error(at: tagStart, "unterminated tag <\(string(name))>, missing '>'")
            }

            while true {
                skipTagWhitespace()
                guard pos < end else { throw unterminated() }
                let byte = src[pos]
                if byte == gt {
                    pos += 1
                    return (first < 0 ? pos..<pos : first..<last, false)
                }
                if byte == slash {
                    pos += 1
                    skipTagWhitespace()
                    guard pos < end else { throw unterminated() }
                    guard src[pos] == gt else {
                        throw error(at: pos, "expected '>' after '/' in tag <\(string(name))>")
                    }
                    pos += 1
                    return (first < 0 ? pos..<pos : first..<last, true)
                }

                guard let attributeEnd = nameEnd(at: pos) else {
                    throw error(at: pos, "expected an attribute name in tag <\(string(name))>")
                }
                let attribute = pos..<attributeEnd
                pos = attributeEnd
                skipTagWhitespace()
                guard pos < end else { throw unterminated() }
                guard src[pos] == equals else {
                    throw error(at: pos, "expected '=' after attribute '\(string(attribute))' in tag <\(string(name))>")
                }
                pos += 1
                skipTagWhitespace()
                guard pos < end else { throw unterminated() }
                let quote = src[pos]
                guard quote == dquote || quote == squote else {
                    throw error(at: pos, "value of attribute '\(string(attribute))' in tag <\(string(name))> must be quoted with \" or '")
                }
                guard let close = index(of: quote, from: pos + 1) else { throw unterminated() }
                pos = close + 1

                if isDuplicate(attribute) {
                    throw error(at: attribute.lowerBound, "duplicate attribute '\(string(attribute))' in tag <\(string(name))>")
                }
                if first < 0 { first = attribute.lowerBound }
                last = pos
            }
        }

        /// Records `name` and reports whether the current tag already has it.
        /// Pairwise byte comparison for the usual handful of attributes; a
        /// hash set (verified byte-wise on a hit) beyond that.
        private mutating func isDuplicate(_ name: Range<Int>) -> Bool {
            let smallCount = 8
            if attributeNames.count < smallCount {
                for other in attributeNames where bytesEqual(other, name) { return true }
                attributeNames.append(name)
                return false
            }
            if attributeNames.count == smallCount {
                attributeHashes.removeAll(keepingCapacity: true)
                for other in attributeNames { attributeHashes.insert(hash(other)) }
            }
            if !attributeHashes.insert(hash(name)).inserted {
                for other in attributeNames where bytesEqual(other, name) { return true }
            }
            attributeNames.append(name)
            return false
        }

        /// At `</`.
        private mutating func scanEndTag<S: Sink>(_ sink: inout S) throws {
            guard let open = stack.last else { return }
            let endTagStart = pos
            pos += 2
            guard let endNameEnd = nameEnd(at: pos) else {
                throw error(at: endTagStart, "expected element name in end tag")
            }
            let endName = pos..<endNameEnd
            pos = endNameEnd
            skipXMLWhitespace()
            guard pos < end, src[pos] == gt else {
                throw error(at: endTagStart, "expected '>' to close end tag </\(string(endName))>")
            }
            pos += 1
            let name = open.nameStart..<open.nameEnd
            guard namesMatch(name, endName) else {
                throw error(at: endTagStart,
                            "mismatched closing tag: expected </\(string(name))> but found </\(string(endName))>")
            }
            stack.removeLast()
            sink.endElement(name: name, inner: open.innerStart..<endTagStart, level: stack.count)
        }

        /// The original compared names as Swift strings (canonical
        /// equivalence); bytes decide unless non-ASCII text is involved.
        private func namesMatch(_ a: Range<Int>, _ b: Range<Int>) -> Bool {
            if bytesEqual(a, b) { return true }
            if isASCII(a) && isASCII(b) { return false }
            return string(a) == string(b)
        }

        // MARK: Prolog constructs

        /// At `open`; returns the content range and moves past `close`.
        private mutating func scanTerminated(open: [UInt8], close: [UInt8], message: String) throws -> Range<Int> {
            let start = pos
            let contentStart = pos + open.count
            guard let closeStart = find(close, from: contentStart) else {
                throw error(at: start, message)
            }
            pos = closeStart + close.count
            return contentStart..<closeStart
        }

        /// At `<!DOCTYPE`; returns the raw content up to the closing `>`.
        /// Quoted strings may contain `>`; so may an internal subset `[ … ]`,
        /// inside its declarations, comments, processing instructions and
        /// quoted strings.
        private mutating func scanDoctype() throws -> Range<Int> {
            let start = pos
            let contentStart = pos + doctypeOpen.count
            pos = contentStart
            var quote: UInt8 = 0
            while true {
                guard pos < end else {
                    throw error(at: start, "unterminated DOCTYPE declaration, missing '>'")
                }
                let byte = src[pos]
                if quote != 0 {
                    if byte == quote { quote = 0 }
                    pos += 1
                    continue
                }
                if byte == dquote || byte == squote {
                    quote = byte
                    pos += 1
                    continue
                }
                if byte == lbracket {
                    try skipInternalSubset(doctypeStart: start)
                    continue
                }
                if byte == gt {
                    let content = contentStart..<pos
                    pos += 1
                    return content
                }
                pos += 1
            }
        }

        /// At the `[` of a DOCTYPE internal subset; moves past its `]`.
        private mutating func skipInternalSubset(doctypeStart: Int) throws {
            pos += 1
            while true {
                guard pos < end else {
                    throw error(at: doctypeStart, "unterminated DOCTYPE internal subset, missing ']'")
                }
                let byte = src[pos]
                if byte == rbracket {
                    pos += 1
                    return
                }
                if byte == dquote || byte == squote {
                    guard let close = index(of: byte, from: pos + 1) else {
                        throw error(at: doctypeStart, "unterminated DOCTYPE internal subset, missing ']'")
                    }
                    pos = close + 1
                    continue
                }
                if matches(commentOpen) {
                    _ = try scanTerminated(open: commentOpen, close: commentClose,
                                           message: "unterminated comment, missing '-->'")
                    continue
                }
                if matches(piOpen) {
                    _ = try scanTerminated(open: piOpen, close: piClose,
                                           message: "unterminated processing instruction, missing '?>'")
                    continue
                }
                pos += 1
            }
        }

        // MARK: Names

        /// End of the name starting at `start`, or nil when no name starts
        /// there. Same rules as the original formatter, which worked on
        /// `Character`s: start with a letter, `_` or `:`; continue with
        /// letters, numbers, `_`, `-`, `.`, `:`.
        private func nameEnd(at start: Int) -> Int? {
            var i = start
            guard i < end else { return nil }
            let first = src[i]
            guard first < 0x80 else { return unicodeNameEnd(at: start) }
            guard isASCIINameStart(first) else { return nil }
            i += 1
            while i < end {
                let byte = src[i]
                if byte >= 0x80 { return unicodeNameEnd(at: start) }
                guard isASCIINameChar(byte) else { break }
                i += 1
            }
            return i
        }

        /// Slow path for names with non-ASCII bytes: applies the original
        /// `Character` rules (grapheme clusters, Unicode letter / number
        /// properties) to the run up to the next ASCII non-name byte. A
        /// cluster never extends across such a byte, so the run's end is a
        /// cluster boundary.
        private func unicodeNameEnd(at start: Int) -> Int? {
            var runEnd = start
            while runEnd < end, src[runEnd] >= 0x80 || isASCIINameChar(src[runEnd]) { runEnd += 1 }
            let run = String(decoding: UnsafeBufferPointer(rebasing: src[start..<runEnd]), as: UTF8.self)
            var length = 0
            var isFirst = true
            for character in run {
                let accepted = isFirst ? XMLFormatter.isNameStartChar(character) : XMLFormatter.isNameChar(character)
                guard accepted else { break }
                length += character.utf8.count
                isFirst = false
            }
            return length == 0 ? nil : start + length
        }

        private func isASCIINameStart(_ b: UInt8) -> Bool {
            (b >= 0x61 && b <= 0x7A) || (b >= 0x41 && b <= 0x5A) || b == 0x5F || b == 0x3A
        }

        private func isASCIINameChar(_ b: UInt8) -> Bool {
            isASCIINameStart(b) || (b >= 0x30 && b <= 0x39) || b == 0x2D || b == 0x2E
        }

        // MARK: Whitespace

        /// The original `skipWhitespace`: space, tab, CR, LF only.
        private mutating func skipXMLWhitespace() {
            while pos < end {
                let byte = src[pos]
                guard byte == space || byte == 0x09 || byte == cr || byte == newline else { return }
                pos += 1
            }
        }

        /// Whitespace inside a start tag: everything the original trimmed off
        /// its attribute text (`CharacterSet.whitespacesAndNewlines`).
        private mutating func skipTagWhitespace() {
            while pos < end {
                let byte = src[pos]
                if byte < 0x80 {
                    guard byte == space || (byte >= 0x09 && byte <= 0x0D) else { return }
                    pos += 1
                } else {
                    let (scalar, length) = decodeScalar(src, at: pos)
                    guard unicodeWhitespace.contains(scalar) else { return }
                    pos += length
                }
            }
        }

        /// `range` with leading / trailing `whitespacesAndNewlines` removed,
        /// like the original's `trimmingCharacters(in:)`.
        private func trimmed(_ range: Range<Int>) -> Range<Int> {
            var lower = range.lowerBound
            var upper = range.upperBound
            while lower < upper {
                let byte = src[lower]
                if byte < 0x80 {
                    guard byte == space || (byte >= 0x09 && byte <= 0x0D) else { break }
                    lower += 1
                } else {
                    let (scalar, length) = decodeScalar(src, at: lower)
                    guard unicodeWhitespace.contains(scalar) else { break }
                    lower += length
                }
            }
            while upper > lower {
                var start = upper - 1
                while start > lower, src[start] & 0xC0 == 0x80 { start -= 1 }
                let byte = src[start]
                if byte < 0x80 {
                    guard byte == space || (byte >= 0x09 && byte <= 0x0D) else { break }
                } else {
                    guard unicodeWhitespace.contains(decodeScalar(src, at: start).0) else { break }
                }
                upper = start
            }
            return lower..<upper
        }

        // MARK: Bytes

        private func matches(_ pattern: [UInt8]) -> Bool {
            guard end - pos >= pattern.count else { return false }
            for k in 0..<pattern.count where src[pos + k] != pattern[k] { return false }
            return true
        }

        private func index(of byte: UInt8, from start: Int) -> Int? {
            guard start < end, let base = src.baseAddress else { return nil }
            guard let hit = memchr(base + start, Int32(byte), end - start) else { return nil }
            return base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
        }

        private func find(_ pattern: [UInt8], from start: Int) -> Int? {
            var i = start
            while let candidate = index(of: pattern[0], from: i) {
                guard end - candidate >= pattern.count else { return nil }
                var k = 1
                while k < pattern.count, src[candidate + k] == pattern[k] { k += 1 }
                if k == pattern.count { return candidate }
                i = candidate + 1
            }
            return nil
        }

        private func bytesEqual(_ a: Range<Int>, _ b: Range<Int>) -> Bool {
            guard a.count == b.count else { return false }
            guard a.count > 0, let base = src.baseAddress else { return true }
            return memcmp(base + a.lowerBound, base + b.lowerBound, a.count) == 0
        }

        private func isASCII(_ range: Range<Int>) -> Bool {
            for i in range where src[i] >= 0x80 { return false }
            return true
        }

        private func hash(_ range: Range<Int>) -> Int {
            var hasher = Hasher()
            hasher.combine(bytes: UnsafeRawBufferPointer(UnsafeBufferPointer(rebasing: src[range])))
            return hasher.finalize()
        }

        private func string(_ range: Range<Int>) -> String {
            String(decoding: UnsafeBufferPointer(rebasing: src[range]), as: UTF8.self)
        }

        // MARK: Errors

        /// 1-based line of byte offset `offset`, counted only when an error
        /// is reported. LF, CRLF and a lone CR each end a line, as the
        /// original's `Character`-based counter did.
        private func line(at offset: Int) -> Int {
            var line = 1
            var i = 0
            let limit = min(offset, end)
            while i < limit {
                let byte = src[i]
                if byte == newline {
                    line += 1
                } else if byte == cr, i + 1 >= end || src[i + 1] != newline {
                    line += 1
                }
                i += 1
            }
            return line
        }

        private func error(at offset: Int, _ message: String) -> XMLFormatError {
            XMLFormatError(line: line(at: offset), message: message)
        }
    }

    // MARK: - Pass 1: measure

    /// Validates nothing itself; decides each element's layout when it
    /// closes and sums the exact output size. Memory: one frame per open
    /// element plus one bit per non-self-closing element.
    private struct Measurer: Sink {
        private struct Frame {
            var openTagLength: Int
            var nameLength: Int
            var bit: Int
            var preservesSpace: Bool
            var hasChildren = false
            var hasCharacterData = false
            /// Size of the children if the element is expanded: Σ (1 + child).
            var expandedChildren = 0
        }

        let src: UnsafeBufferPointer<UInt8>
        let indentWidth: Int
        let limit: Int
        private var frames: [Frame] = []
        private var topLevelCount = 0
        /// Bit set per non-self-closing element, in document order: 1 =
        /// copy the inner source verbatim, 0 = expand the children.
        private(set) var verbatimBits: [UInt64] = []
        private var nextBit = 0
        private(set) var total = 0

        init(src: UnsafeBufferPointer<UInt8>, indentWidth: Int, limit: Int) {
            self.src = src
            self.indentWidth = indentWidth
            self.limit = limit
        }

        mutating func markup(_ kind: Markup, content: Range<Int>, level: Int) {
            if level > 0 { frames[frames.count - 1].hasChildren = true }
            add(sum(indent(level), kind.delimiterLength, content.count), level: level)
        }

        mutating func startElement(name: Range<Int>, attributes: Range<Int>, selfClosing: Bool, level: Int) {
            if level > 0 { frames[frames.count - 1].hasChildren = true }
            let openTagLength = 1 + name.count + (attributes.isEmpty ? 0 : 1 + attributes.count)
            if selfClosing {
                add(sum(indent(level), openTagLength, 2), level: level)
                return
            }
            if nextBit % 64 == 0 { verbatimBits.append(0) }
            frames.append(Frame(openTagLength: openTagLength, nameLength: name.count, bit: nextBit,
                                preservesSpace: preservesSpace(attributes)))
            nextBit += 1
        }

        mutating func endElement(name: Range<Int>, inner: Range<Int>, level: Int) {
            let frame = frames.removeLast()
            let verbatim = !frame.hasChildren || frame.hasCharacterData || frame.preservesSpace
            let size: Int
            if verbatim {
                verbatimBits[frame.bit >> 6] |= 1 << UInt64(frame.bit & 63)
                // indent + open tag + ">" + inner + "</" name ">"
                size = sum(indent(level), frame.openTagLength, 1, inner.count, 3, frame.nameLength)
            } else {
                // indent + open tag + ">" + children + "\n" + indent + "</" name ">"
                size = sum(sum(indent(level), frame.openTagLength, 1, frame.expandedChildren),
                           sum(1, indent(level), 3, frame.nameLength))
            }
            add(size, level: level)
        }

        mutating func characterData() {
            frames[frames.count - 1].hasChildren = true
            frames[frames.count - 1].hasCharacterData = true
        }

        /// The original's test, run on the attribute text only when it can
        /// match at all.
        private func preservesSpace(_ attributes: Range<Int>) -> Bool {
            let pattern = XMLFormatter.xmlSpace
            guard attributes.count >= pattern.count else { return false }
            var found = false
            var i = attributes.lowerBound
            while i + pattern.count <= attributes.upperBound {
                var k = 0
                while k < pattern.count, src[i + k] == pattern[k] { k += 1 }
                if k == pattern.count { found = true; break }
                i += 1
            }
            guard found else { return false }
            let text = String(decoding: UnsafeBufferPointer(rebasing: src[attributes]), as: UTF8.self)
            return text.range(of: #"xml:space\s*=\s*["']preserve["']"#, options: .regularExpression) != nil
        }

        private mutating func add(_ size: Int, level: Int) {
            if level == 0 {
                total = sum(total, topLevelCount > 0 ? 1 : 0, size)
                topLevelCount += 1
            } else {
                frames[frames.count - 1].expandedChildren = sum(frames[frames.count - 1].expandedChildren, 1, size)
            }
        }

        private func indent(_ level: Int) -> Int {
            let (product, overflow) = level.multipliedReportingOverflow(by: indentWidth)
            return overflow ? .max : product
        }

        /// Saturating sum.
        private func sum(_ values: Int...) -> Int {
            var result = 0
            for value in values {
                let (next, overflow) = result.addingReportingOverflow(value)
                if overflow { return .max }
                result = next
            }
            return result
        }
    }

    // MARK: - Pass 2: render

    /// Writes the layout pass 1 decided straight into the result's storage.
    /// Everything inside a verbatim element is skipped until it closes, then
    /// its inner source is copied in one piece.
    private struct Renderer: Sink {
        let src: UnsafeBufferPointer<UInt8>
        let out: UnsafeMutableBufferPointer<UInt8>
        let verbatimBits: [UInt64]
        let indentWidth: Int
        private(set) var count = 0
        private(set) var overflowed = false
        private var nextBit = 0
        private var topLevelCount = 0
        /// Open elements from the outermost verbatim element inwards
        /// (0 = currently rendering).
        private var verbatimDepth = 0

        init(src: UnsafeBufferPointer<UInt8>, out: UnsafeMutableBufferPointer<UInt8>,
             verbatimBits: [UInt64], indentWidth: Int) {
            self.src = src
            self.out = out
            self.verbatimBits = verbatimBits
            self.indentWidth = indentWidth
        }

        mutating func markup(_ kind: Markup, content: Range<Int>, level: Int) {
            guard verbatimDepth == 0 else { return }
            beginItem(level: level)
            write(kind.prefix)
            write(content)
            write(kind.suffix)
        }

        mutating func startElement(name: Range<Int>, attributes: Range<Int>, selfClosing: Bool, level: Int) {
            if verbatimDepth > 0 {
                if !selfClosing {
                    verbatimDepth += 1
                    nextBit += 1
                }
                return
            }
            beginItem(level: level)
            writeByte(XMLFormatter.lt)
            write(name)
            if !attributes.isEmpty {
                writeByte(XMLFormatter.space)
                write(attributes)
            }
            if selfClosing {
                writeByte(XMLFormatter.slash)
                writeByte(XMLFormatter.gt)
                return
            }
            writeByte(XMLFormatter.gt)
            let bit = nextBit
            nextBit += 1
            if verbatimBits[bit >> 6] & (1 << UInt64(bit & 63)) != 0 {
                verbatimDepth = 1
            }
        }

        mutating func endElement(name: Range<Int>, inner: Range<Int>, level: Int) {
            if verbatimDepth > 0 {
                verbatimDepth -= 1
                guard verbatimDepth == 0 else { return }
                write(inner)
            } else {
                writeByte(XMLFormatter.newline)
                writeSpaces(level)
            }
            writeByte(XMLFormatter.lt)
            writeByte(XMLFormatter.slash)
            write(name)
            writeByte(XMLFormatter.gt)
        }

        mutating func characterData() {
            // Only ever inside a verbatim element, which copies it in one piece.
        }

        /// Top-level items are separated by a newline; children of an
        /// expanded element each start on a new, indented line.
        private mutating func beginItem(level: Int) {
            if level == 0 {
                if topLevelCount > 0 { writeByte(XMLFormatter.newline) }
                topLevelCount += 1
            } else {
                writeByte(XMLFormatter.newline)
                writeSpaces(level)
            }
        }

        private mutating func writeSpaces(_ level: Int) {
            let (n, overflow) = level.multipliedReportingOverflow(by: indentWidth)
            guard !overflow, n <= out.count - count else { overflowed = true; return }
            guard n > 0 else { return }
            memset(out.baseAddress! + count, Int32(XMLFormatter.space), n)
            count += n
        }

        private mutating func writeByte(_ byte: UInt8) {
            guard count < out.count else { overflowed = true; return }
            out[count] = byte
            count += 1
        }

        private mutating func write(_ bytes: [UInt8]) {
            for byte in bytes { writeByte(byte) }
        }

        private mutating func write(_ range: Range<Int>) {
            let n = range.count
            guard n <= out.count - count else { overflowed = true; return }
            guard n > 0 else { return }
            memcpy(out.baseAddress! + count, src.baseAddress! + range.lowerBound, n)
            count += n
        }
    }

    // MARK: - Shared helpers

    private static func isNameStartChar(_ c: Character) -> Bool {
        c.isLetter || c == "_" || c == ":"
    }

    private static func isNameChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_" || c == "-" || c == "." || c == ":"
    }
}

/// Decodes the UTF-8 scalar starting at `offset` of valid UTF-8 `bytes`.
private func decodeScalar(_ bytes: UnsafeBufferPointer<UInt8>, at offset: Int) -> (Unicode.Scalar, Int) {
    let b0 = UInt32(bytes[offset])
    let length: Int
    var value: UInt32
    switch b0 {
    case 0..<0x80: return (Unicode.Scalar(UInt8(b0)), 1)
    case 0xC0..<0xE0: length = 2; value = b0 & 0x1F
    case 0xE0..<0xF0: length = 3; value = b0 & 0x0F
    default: length = 4; value = b0 & 0x07
    }
    let available = min(length, bytes.count - offset)
    for k in 1..<max(1, available) {
        value = (value << 6) | (UInt32(bytes[offset + k]) & 0x3F)
    }
    return (Unicode.Scalar(value) ?? "\u{FFFD}", max(1, available))
}
