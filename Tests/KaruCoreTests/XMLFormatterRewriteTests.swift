import Foundation
import Testing
@testable import KaruCore

// Tests for the byte-scanning XMLFormatter rewrite (RELIABILITY-PLAN F7-XML,
// bugs R04 / N02 / R10, user decision D5):
// - differential tests against `LegacyXMLFormatter` (the pre-rewrite code,
//   verbatim) on seeded generated and mutated documents;
// - the four D5 grammar boundaries, positive and negative;
// - FormatLimits (depth, output size);
// - large / dense / multi-byte inputs.

// MARK: - Helpers

/// Deterministic SplitMix64; never the system generator, so every corpus is
/// reproducible from its seed.
private struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform-enough integer in `0..<bound` (bound > 0).
    mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
    mutating func chance(_ percent: Int) -> Bool { below(100) < percent }
    mutating func pick<T>(_ items: [T]) -> T { items[below(items.count)] }
}

private enum Outcome: Equatable {
    case output(String)
    case xmlError(XMLFormatError)
    case limitError(FormatLimitError)
    case otherError(String)

    init(_ body: () throws -> String) {
        do { self = .output(try body()) } catch let error as XMLFormatError {
            self = .xmlError(error)
        } catch let error as FormatLimitError {
            self = .limitError(error)
        } catch {
            self = .otherError("\(error)")
        }
    }
}

private func newOutcome(_ text: String, _ width: Int) -> Outcome {
    Outcome { try XMLFormatter.prettyPrint(text, indentWidth: width) }
}

private func legacyOutcome(_ text: String, _ width: Int) -> Outcome {
    Outcome { try LegacyXMLFormatter.prettyPrint(text, indentWidth: width) }
}

private func expectXMLError(_ text: String, line: Int, message: String,
                            sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(newOutcome(text, 2) == .xmlError(XMLFormatError(line: line, message: message)),
            sourceLocation: sourceLocation)
}

// MARK: - Document generator (no D5 boundary constructs)

private struct DocumentGenerator {
    var rng: SplitMix64

    static let elementNames = ["a", "b", "item", "x:y", "_n", "d-1", "data.v", "名前", "é", "𝒜b", "Key", "key"]
    static let attributeNames = ["id", "name", "class", "xml:lang", "v", "é", "data-x", "ID", "z.1"]
    static let separators = [" ", "  ", "\n  ", "\t", "\r\n ", " \u{3000}", "\u{00A0}"]
    static let textPieces = [
        "hello", "x", " ", "  ", "\n", "\r\n", "\t", "&amp;", "&lt;tag&gt;", "&#39;", "a > b", "]]>",
        "中文", "é", "Ω", "😀", "𝒜", "\u{00A0}", "1.0", "true", "-", "?", "/", "=", "'", "\"",
    ]
    static let commentPieces = [" note ", "-", "a > b", "<tag>", "中文 😀", "\n  line\n", "\"q\" 'q'", "]]>", " "]
    static let cdataPieces = ["if (a < b && c > d) { }", "]]", "x]", "<![CDATA[", "😀", "\r\n", "&amp;", " "]

    mutating func text(_ pieces: [String], count: Int) -> String {
        var s = ""
        for _ in 0..<count { s += rng.pick(pieces) }
        return s
    }

    mutating func separator() -> String { rng.pick(Self.separators) }

    mutating func attributeValue(quote: Character) -> String {
        var s = ""
        for _ in 0..<rng.below(4) {
            var piece = rng.pick(["1", "fish &amp; chips", "a b", "x>y", "<", "/", "中", "😀", "\n", "=", "'", "\"",
                                  "xml:space='preserve'"])
            piece.removeAll { $0 == quote }
            s += piece
        }
        return s
    }

    mutating func startTagTail(name: String) -> (attributes: String, preserve: Bool) {
        var used = Set<String>()
        var s = ""
        var preserve = false
        for _ in 0..<rng.below(4) {
            let attribute: String
            if rng.chance(5) {
                attribute = "xml:space"
            } else {
                attribute = rng.pick(Self.attributeNames)
            }
            guard used.insert(attribute).inserted else { continue }
            let quote: Character = rng.chance(50) ? "\"" : "'"
            let value: String
            if attribute == "xml:space" {
                value = rng.chance(70) ? "preserve" : "default"
                preserve = preserve || value == "preserve"
            } else {
                value = attributeValue(quote: quote)
            }
            let eq = rng.pick(["=", "=", " = ", "\n=\t"])
            s += separator() + attribute + eq + String(quote) + value + String(quote)
        }
        if rng.chance(20) { s += separator() }
        return (s, preserve)
    }

    mutating func endTag(_ name: String) -> String {
        "</" + name + rng.pick(["", "", "", " ", "\n", "\r\n "]) + ">"
    }

    mutating func comment() -> String { "<!--" + text(Self.commentPieces, count: rng.below(3)) + "-->" }
    mutating func cdata() -> String { "<![CDATA[" + text(Self.cdataPieces, count: rng.below(3)) + "]]>" }

    mutating func element(depth: Int) -> String {
        let name = rng.pick(Self.elementNames)
        let (attributes, _) = startTagTail(name: name)
        let open = "<" + name + attributes
        let mode = depth >= 5 ? rng.pick([0, 1, 4]) : rng.below(6)
        switch mode {
        case 0:  // self-closing
            return open + rng.pick(["/>", "/>", " />", "/ >", "\n/>"])
        case 1:  // empty
            return open + ">" + endTag(name)
        case 2:  // element / comment children only: expanded
            var inner = ""
            for _ in 0..<(1 + rng.below(4)) {
                inner += rng.chance(20) ? comment() : element(depth: depth + 1)
            }
            return open + ">" + inner + endTag(name)
        case 3:  // mixed content
            var inner = ""
            for _ in 0..<(1 + rng.below(5)) {
                switch rng.below(4) {
                case 0: inner += text(Self.textPieces, count: 1 + rng.below(3))
                case 1: inner += cdata()
                case 2: inner += comment()
                default: inner += element(depth: depth + 1)
                }
            }
            return open + ">" + inner + endTag(name)
        case 4:  // text only
            return open + ">" + text(Self.textPieces, count: 1 + rng.below(4)) + endTag(name)
        default:  // already-indented children (whitespace text)
            var inner = ""
            for _ in 0..<(1 + rng.below(3)) {
                inner += rng.pick(["\n  ", "\r\n\t", " "]) + element(depth: depth + 1)
            }
            return open + ">" + inner + rng.pick(["\n", ""]) + endTag(name)
        }
    }

    mutating func topSeparator() -> String { rng.pick(["", "\n", "\r\n", "  ", "\t\n", "\n\n"]) }

    mutating func document() -> String {
        var s = ""
        if rng.chance(20) { s += topSeparator() }
        if rng.chance(50) {
            s += rng.pick(["<?xml version=\"1.0\" encoding=\"UTF-8\"?>", "<?  xml version='1.0'  ?>",
                           "<?xml-stylesheet href=\"a>b.xsl\"?>", "<?xml\nversion=\"1.0\"\n?>"])
            s += topSeparator()
        }
        if rng.chance(20) { s += comment() + topSeparator() }
        if rng.chance(40) {
            s += rng.pick([
                "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">",
                "<!DOCTYPE root SYSTEM 'a>b.dtd'>",
                "<!DOCTYPE   html  >",
                "<!DOCTYPE note\nSYSTEM \"note.dtd\">",
            ])
            s += topSeparator()
        }
        if rng.chance(20) { s += comment() + topSeparator() }
        s += element(depth: 0)
        if rng.chance(30) { s += topSeparator() + comment() }
        if rng.chance(20) { s += topSeparator() + "<?pi after root?>" }
        if rng.chance(30) { s += topSeparator() }
        return s
    }
}

// MARK: - Boundary-construct detector

/// The D5 constructs on which the rewrite intentionally differs from the
/// legacy formatter.
private enum BoundaryConstruct: Hashable {
    case processingInstructionInElement
    case doctypeInternalSubset
    /// Attribute text that is not a sequence of `name = "value"` (includes
    /// unquoted values, missing values, stray characters).
    case attributeSyntax
    case duplicateAttribute
}

/// Independent, Character-based scan (written separately from both
/// formatters) that finds the D5 constructs in a mutated document. It only
/// tokenizes as far as needed: comments, CDATA, processing instructions,
/// DOCTYPE, end tags and start tags; element depth is approximate.
private func boundaryConstructs(in text: String) -> Set<BoundaryConstruct> {
    let c = Array(text)
    var found = Set<BoundaryConstruct>()
    var i = 0
    var depth = 0
    let whitespace = CharacterSet.whitespacesAndNewlines

    func at(_ s: String, _ k: Int) -> Bool {
        let p = Array(s)
        guard k + p.count <= c.count else { return false }
        return (0..<p.count).allSatisfy { c[k + $0] == p[$0] }
    }
    func skip(past terminator: String, from k: Int) -> Int {
        var j = k
        while j < c.count, !at(terminator, j) { j += 1 }
        return min(c.count, j + terminator.count)
    }
    func isNameStart(_ ch: Character) -> Bool { ch.isLetter || ch == "_" || ch == ":" }
    func isName(_ ch: Character) -> Bool {
        ch.isLetter || ch.isNumber || ch == "_" || ch == "-" || ch == "." || ch == ":"
    }
    func isSpace(_ ch: Character) -> Bool { ch.unicodeScalars.allSatisfy { whitespace.contains($0) } }
    func name(_ chars: [Character], _ k: Int) -> Int {
        guard k < chars.count, isNameStart(chars[k]) else { return k }
        var j = k + 1
        while j < chars.count, isName(chars[j]) { j += 1 }
        return j
    }

    /// Checks a start tag's text after its name (without the closing '>').
    /// `closed` is false when the input ended inside the tag: running out of
    /// text there is the old "unterminated tag" error, not a boundary.
    func checkAttributes(_ r: [Character], closed: Bool) -> (Set<BoundaryConstruct>, selfClosing: Bool) {
        var j = 0
        var names: [String] = []
        func skipSpace() { while j < r.count, isSpace(r[j]) { j += 1 } }
        while true {
            skipSpace()
            if j == r.count { return ([], false) }
            if r[j] == "/" {
                j += 1
                skipSpace()
                return (j == r.count ? [] : [.attributeSyntax], true)
            }
            let nameEnd = name(r, j)
            if nameEnd == j { return ([.attributeSyntax], false) }
            let attribute = String(r[j..<nameEnd])
            j = nameEnd
            skipSpace()
            if j == r.count { return (closed ? [.attributeSyntax] : [], false) }
            if r[j] != "=" { return ([.attributeSyntax], false) }
            j += 1
            skipSpace()
            if j == r.count { return (closed ? [.attributeSyntax] : [], false) }
            let quote = r[j]
            if quote != "\"" && quote != "'" { return ([.attributeSyntax], false) }
            j += 1
            while j < r.count, r[j] != quote { j += 1 }
            if j == r.count { return ([], false) }
            j += 1
            if names.contains(where: { $0.utf8.elementsEqual(attribute.utf8) }) {
                return ([.duplicateAttribute], false)
            }
            names.append(attribute)
        }
    }

    while i < c.count {
        guard c[i] == "<" else { i += 1; continue }
        if at("<!--", i) { i = skip(past: "-->", from: i + 4); continue }
        if at("<![CDATA[", i) { i = skip(past: "]]>", from: i + 9); continue }
        if at("<?", i) {
            if depth > 0 { found.insert(.processingInstructionInElement) }
            i = skip(past: "?>", from: i + 2)
            continue
        }
        if at("<!DOCTYPE", i) {
            var j = i + 9
            var quote: Character?
            while j < c.count {
                let ch = c[j]
                if let q = quote {
                    if ch == q { quote = nil }
                } else if ch == "\"" || ch == "'" {
                    quote = ch
                } else if ch == "[" {
                    found.insert(.doctypeInternalSubset)
                    return found  // everything after it is read differently
                } else if ch == ">" {
                    break
                }
                j += 1
            }
            i = j + 1
            continue
        }
        if at("</", i) {
            depth = max(0, depth - 1)
            i = skip(past: ">", from: i + 2)
            continue
        }
        let nameEnd = name(c, i + 1)
        guard nameEnd > i + 1 else { i += 1; continue }
        var j = nameEnd
        var quote: Character?
        while j < c.count {
            let ch = c[j]
            if let q = quote {
                if ch == q { quote = nil }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == ">" {
                break
            }
            j += 1
        }
        let closed = j < c.count
        let (problems, selfClosing) = checkAttributes(Array(c[nameEnd..<j]), closed: closed)
        found.formUnion(problems)
        if closed && !selfClosing { depth += 1 }
        i = j + 1
    }
    return found
}

// MARK: - Differential tests

@Suite("XMLFormatter rewrite: differential against the legacy formatter")
struct XMLFormatterDifferentialTests {

    @Test("2 000 generated well-formed documents × widths 1/2/4/8 format byte-identically")
    func generatedDocuments() {
        var generator = DocumentGenerator(rng: SplitMix64(seed: 0x5EED_0001))
        var expandedSeen = 0
        var preservedSeen = 0
        for index in 0..<2_000 {
            let document = generator.document()
            #expect(boundaryConstructs(in: document).isEmpty, "generator produced a boundary construct: \(document)")
            for width in [1, 2, 4, 8] {
                let old = legacyOutcome(document, width)
                guard case .output(let expected) = old else {
                    Issue.record("legacy rejected generated document #\(index): \(old)\n\(document)")
                    continue
                }
                let new = newOutcome(document, width)
                #expect(new == old, "document #\(index), width \(width):\n\(document)")
                if width == 2 {
                    if expected.contains("\n  <") { expandedSeen += 1 }
                    if document.contains("xml:space=") { preservedSeen += 1 }
                }
            }
        }
        // The corpus must exercise both layouts, not only verbatim copies.
        #expect(expandedSeen > 500)
        #expect(preservedSeen > 20)
        print("XML differential (valid): 2000 documents x 4 widths; expanded=\(expandedSeen) xml:space=\(preservedSeen)")
    }

    @Test("6 000 mutated documents: same accept / reject, same output, error line never later")
    func mutatedDocuments() {
        var generator = DocumentGenerator(rng: SplitMix64(seed: 0x5EED_0002))
        var rng = SplitMix64(seed: 0x5EED_0003)
        let insertions = [
            "<", ">", "/", "\"", "'", "=", "<!--", "-->", "<![CDATA[", "]]>", "</a>", "<a>", "<b/>", " ", "\n",
            "\r\n", "x", "中", "😀", "&", "<?", "?>", "[", "]", "<!DOCTYPE r>", "a=\"1\"", "</", "\r",
        ]
        var counts = (bothAccepted: 0, bothRejected: 0, sameError: 0, earlierLine: 0, boundary: 0)
        var boundaryKinds: [String: Int] = [:]
        let total = 6_000

        for index in 0..<total {
            var chars = Array(generator.document())
            for _ in 0..<(1 + rng.below(3)) {
                switch rng.below(5) {
                case 0 where !chars.isEmpty:  // delete a short run
                    let start = rng.below(chars.count)
                    chars.removeSubrange(start..<min(chars.count, start + 1 + rng.below(4)))
                case 1:  // insert a token
                    chars.insert(contentsOf: Array(rng.pick(insertions)), at: rng.below(chars.count + 1))
                case 2 where !chars.isEmpty:  // truncate
                    chars.removeSubrange(rng.below(chars.count)..<chars.count)
                case 3 where chars.count > 2:  // duplicate a slice somewhere else
                    let start = rng.below(chars.count)
                    let slice = Array(chars[start..<min(chars.count, start + 1 + rng.below(12))])
                    chars.insert(contentsOf: slice, at: rng.below(chars.count + 1))
                default:  // replace one character
                    if !chars.isEmpty { chars[rng.below(chars.count)] = Character(rng.pick(insertions.filter { $0.count == 1 })) }
                }
            }
            let document = String(chars)
            let width = [1, 2, 4, 8][index % 4]
            let old = legacyOutcome(document, width)
            let new = newOutcome(document, width)

            let boundary = boundaryConstructs(in: document)
            if !boundary.isEmpty {
                counts.boundary += 1
                for kind in boundary { boundaryKinds["\(kind)", default: 0] += 1 }
                // The implementations may legitimately differ; the new one
                // must still answer with a format error or an output.
                if case .otherError(let e) = new { Issue.record("unexpected error \(e) for #\(index)") }
                if case .limitError(let e) = new { Issue.record("unexpected limit error \(e) for #\(index)") }
                continue
            }
            switch (old, new) {
            case (.output(let a), .output(let b)):
                counts.bothAccepted += 1
                #expect(a == b, "mutated #\(index), width \(width):\n\(document)")
            case (.xmlError(let a), .xmlError(let b)):
                counts.bothRejected += 1
                #expect(b.line <= a.line, "mutated #\(index): legacy \(a), new \(b)\n\(document)")
                if a == b { counts.sameError += 1 } else if b.line < a.line { counts.earlierLine += 1 }
            default:
                Issue.record("accept/reject differs for mutated #\(index): legacy \(old), new \(new)\n\(document)")
            }
        }
        #expect(counts.bothAccepted > 500)
        #expect(counts.bothRejected > 2_500)
        #expect(counts.bothAccepted + counts.bothRejected >= 4_000)
        #expect(counts.bothAccepted + counts.bothRejected + counts.boundary == total)
        print("XML differential (mutated): \(total) documents; bothAccepted=\(counts.bothAccepted) "
              + "bothRejected=\(counts.bothRejected) (identical error \(counts.sameError), earlier line \(counts.earlierLine)) "
              + "boundaryHits=\(counts.boundary) \(boundaryKinds.sorted { $0.key < $1.key })")
    }
}

// MARK: - D5 boundaries

@Suite("XMLFormatter rewrite: D5 grammar boundaries")
struct XMLFormatterBoundaryTests {

    @Test("a processing instruction inside an element is laid out like a comment, content verbatim")
    func processingInstructionInElement() throws {
        #expect(try XMLFormatter.prettyPrint("<root><?pi data?></root>") == "<root>\n  <?pi data?>\n</root>")
        #expect(try XMLFormatter.prettyPrint("<root><a/><?pi  spaced  ?><b>1</b></root>", indentWidth: 4)
                == "<root>\n    <a/>\n    <?pi  spaced  ?>\n    <b>1</b>\n</root>")
        #expect(try XMLFormatter.prettyPrint("<r><s><?x?></s></r>") == "<r>\n  <s>\n    <?x?>\n  </s>\n</r>")
    }

    @Test("a processing instruction with '?' and '>' in its data ends only at '?>'")
    func processingInstructionWithQuestionMarkAndGreaterThan() throws {
        #expect(try XMLFormatter.prettyPrint("<root><?pi a?b>c > d ?></root>")
                == "<root>\n  <?pi a?b>c > d ?>\n</root>")
    }

    @Test("a processing instruction next to text keeps the mixed content verbatim")
    func processingInstructionInMixedContent() throws {
        let input = "<root><p>text<?pi x?>more</p><q/></root>"
        #expect(try XMLFormatter.prettyPrint(input) == "<root>\n  <p>text<?pi x?>more</p>\n  <q/>\n</root>")
    }

    @Test("an unterminated processing instruction inside an element is reported at its line")
    func unterminatedProcessingInstruction() {
        expectXMLError("<root>\n  <?pi data\n</root>", line: 2,
                       message: "unterminated processing instruction, missing '?>'")
    }

    @Test("a DOCTYPE internal subset with '>' in an entity value and in a comment is kept verbatim")
    func doctypeInternalSubset() throws {
        let doctype = """
        <!DOCTYPE r [
          <!ENTITY e "v>w">
          <!ENTITY f 'single > quoted'>
          <!-- a comment with > and an unbalanced " quote -->
          <?pi in > subset?>
          <!ELEMENT r (#PCDATA)>
        ]>
        """
        let input = doctype + "\n<r><a/></r>"
        let expected = doctype + "\n<r>\n  <a/>\n</r>"
        #expect(try XMLFormatter.prettyPrint(input) == expected)
        #expect(try XMLFormatter.prettyPrint("<!DOCTYPE r [ <!ENTITY e \"v\"> ]><r/>")
                == "<!DOCTYPE r [ <!ENTITY e \"v\"> ]>\n<r/>")
    }

    @Test("an unterminated DOCTYPE internal subset is rejected at the DOCTYPE's line")
    func unterminatedInternalSubset() {
        expectXMLError("<?xml version=\"1.0\"?>\n<!DOCTYPE r [ <!ENTITY e \"v\">\n<r/>", line: 2,
                       message: "unterminated DOCTYPE internal subset, missing ']'")
        expectXMLError("<!DOCTYPE r [ <!-- never closed ]>\n<r/>", line: 1,
                       message: "unterminated comment, missing '-->'")
        expectXMLError("\n<!DOCTYPE r [ ]", line: 2,
                       message: "unterminated DOCTYPE declaration, missing '>'")
    }

    @Test("an unquoted attribute value is rejected with its line")
    func unquotedAttributeValue() {
        expectXMLError("<a b=c/>", line: 1,
                       message: "value of attribute 'b' in tag <a> must be quoted with \" or '")
        expectXMLError("<root>\n  <item\n    id=42>x</item>\n</root>", line: 3,
                       message: "value of attribute 'id' in tag <item> must be quoted with \" or '")
        expectXMLError("<a b = \nc>", line: 2,
                       message: "value of attribute 'b' in tag <a> must be quoted with \" or '")
    }

    @Test("other attribute syntax errors are rejected with clear messages")
    func otherAttributeSyntaxErrors() {
        expectXMLError("<a b></a>", line: 1, message: "expected '=' after attribute 'b' in tag <a>")
        expectXMLError("<a\n\"x\"/>", line: 2, message: "expected an attribute name in tag <a>")
        expectXMLError("<a b=\"1\" / c=\"2\">", line: 1, message: "expected '>' after '/' in tag <a>")
        // Running out of input inside the tag keeps the old message and line.
        expectXMLError("<r>\n<a b=\"1", line: 2, message: "unterminated tag <a>, missing '>'")
        expectXMLError("<r>\n<a b=", line: 2, message: "unterminated tag <a>, missing '>'")
        expectXMLError("<r>\n<a b", line: 2, message: "unterminated tag <a>, missing '>'")
    }

    @Test("a duplicate attribute is rejected at the duplicate's line")
    func duplicateAttribute() {
        expectXMLError("<root a=\"1\" a=\"2\"/>", line: 1, message: "duplicate attribute 'a' in tag <root>")
        expectXMLError("<root a=\"1\"\n  a='2'/>", line: 2, message: "duplicate attribute 'a' in tag <root>")
        expectXMLError("<r x=\"1\" y=\"2\" z=\"3\"\n x=\"4\"></r>", line: 2, message: "duplicate attribute 'x' in tag <r>")
        expectXMLError("<r>\n<e id=\"1\" b=\"2\" b=\"3\" c=\"4\"/></r>", line: 2, message: "duplicate attribute 'b' in tag <e>")
        // Past the pairwise threshold the hash path is used.
        let many = (0..<20).map { "a\($0)=\"\($0)\"" }.joined(separator: " ")
        expectXMLError("<r \(many)\n a7=\"x\"/>", line: 2, message: "duplicate attribute 'a7' in tag <r>")
        expectXMLError("<r 名=\"1\" 名=\"2\"/>", line: 1, message: "duplicate attribute '名' in tag <r>")
    }

    @Test("distinct names (including case and many attributes) and repeats across elements are fine")
    func nonDuplicateAttributes() throws {
        #expect(try XMLFormatter.prettyPrint("<r a=\"1\" A=\"2\"/>") == "<r a=\"1\" A=\"2\"/>")
        #expect(try XMLFormatter.prettyPrint("<r><a id=\"1\"/><b id=\"1\"/></r>")
                == "<r>\n  <a id=\"1\"/>\n  <b id=\"1\"/>\n</r>")
        let many = (0..<40).map { "a\($0)='\($0)'" }.joined(separator: " ")
        #expect(try XMLFormatter.prettyPrint("<r \(many)/>") == "<r \(many)/>")
        #expect(try XMLFormatter.prettyPrint("<r ab=\"1\" a=\"2\" b=\"3\"/>") == "<r ab=\"1\" a=\"2\" b=\"3\"/>")
    }

    @Test("the legacy formatter differed on exactly these inputs (documents the D5 change)")
    func legacyDifferedHere() {
        #expect(throws: XMLFormatError.self) { try LegacyXMLFormatter.prettyPrint("<root><?pi data?></root>") }
        #expect(throws: XMLFormatError.self) {
            try LegacyXMLFormatter.prettyPrint("<!DOCTYPE r [ <!ENTITY e \"v\"> ]><r/>")
        }
        #expect((try? LegacyXMLFormatter.prettyPrint("<a b=c/>")) != nil)
        #expect((try? LegacyXMLFormatter.prettyPrint("<root a=\"1\" a=\"2\"/>")) != nil)
    }
}

// MARK: - Limits

@Suite("XMLFormatter rewrite: FormatLimits")
struct XMLFormatterLimitTests {

    @Test("exactly maxDepth (512) levels formats; 513 throws nestingTooDeep at the 513th tag's line")
    func depthLimit() throws {
        let n = FormatLimits.standard.maxDepth
        let ok = String(repeating: "<a>", count: n) + String(repeating: "</a>", count: n)
        let result = try XMLFormatter.prettyPrint(ok)
        #expect(result.split(separator: "\n").count == 2 * n - 1)
        #expect(result.hasSuffix("\n</a>"))

        let tooDeep = String(repeating: "<a>\n", count: n + 1) + String(repeating: "</a>", count: n + 1)
        #expect(newOutcome(tooDeep, 2) == .limitError(.nestingTooDeep(line: n + 1, limit: n)))

        // A self-closing element one level too deep counts as well.
        let selfClosing = String(repeating: "<a>", count: n) + "<b/>" + String(repeating: "</a>", count: n)
        #expect(newOutcome(selfClosing, 2) == .limitError(.nestingTooDeep(line: 1, limit: n)))
    }

    @Test("a custom small depth limit")
    func customDepthLimit() throws {
        let limits = FormatLimits(maxDepth: 3, outputFactor: 8, outputSlackBytes: 1 << 20)
        #expect(try XMLFormatter.prettyPrint("<a><b><c/></b></a>", limits: limits) == "<a>\n  <b>\n    <c/>\n  </b>\n</a>")
        #expect(throws: FormatLimitError.nestingTooDeep(line: 2, limit: 3)) {
            try XMLFormatter.prettyPrint("<a><b><c>\n<d/></c></b></a>", limits: limits)
        }
    }

    @Test("output past the limit throws outputTooLarge; exactly at the limit is fine")
    func outputLimitCustom() throws {
        let input = "<r><a/><a/><a/></r>"
        let generous = FormatLimits(maxDepth: 512, outputFactor: 100, outputSlackBytes: 0)
        let size = try XMLFormatter.prettyPrint(input, indentWidth: 4, limits: generous).utf8.count
        let inputBytes = input.utf8.count
        #expect(size > inputBytes)

        let exact = FormatLimits(maxDepth: 512, outputFactor: 1, outputSlackBytes: size - inputBytes)
        #expect((try? XMLFormatter.prettyPrint(input, indentWidth: 4, limits: exact))?.utf8.count == size)

        let tight = FormatLimits(maxDepth: 512, outputFactor: 1, outputSlackBytes: size - inputBytes - 1)
        #expect(throws: FormatLimitError.outputTooLarge(limitBytes: size - 1)) {
            try XMLFormatter.prettyPrint(input, indentWidth: 4, limits: tight)
        }
    }

    @Test("standard limits: 400 levels deep with many small children inside throws outputTooLarge")
    func outputLimitStandard() {
        let depth = 400
        let input = String(repeating: "<a>", count: depth) + String(repeating: "<b/>", count: 5_000)
            + String(repeating: "</a>", count: depth)
        let limit = FormatLimits.standard.maxOutputBytes(forInputBytes: input.utf8.count)
        #expect(newOutcome(input, 2) == .limitError(.outputTooLarge(limitBytes: limit)))
        // The same shape with fewer children still formats.
        let small = String(repeating: "<a>", count: depth) + String(repeating: "<b/>", count: 100)
            + String(repeating: "</a>", count: depth)
        if case .output(let out) = newOutcome(small, 2) {
            #expect(out.utf8.count <= FormatLimits.standard.maxOutputBytes(forInputBytes: small.utf8.count))
        } else {
            Issue.record("expected the smaller document to format")
        }
    }

    @Test("a huge indent width saturates into outputTooLarge instead of overflowing")
    func hugeIndentWidth() {
        let outcome = newOutcome("<r><a/></r>", Int.max)
        #expect(outcome == .limitError(.outputTooLarge(limitBytes: FormatLimits.standard.maxOutputBytes(forInputBytes: 11))))
        #expect(newOutcome("<r><a/></r>", -3) == .output("<r>\n<a/>\n</r>"))
    }
}

// MARK: - Shapes and sizes

@Suite("XMLFormatter rewrite: large, dense and multi-byte input")
struct XMLFormatterShapeTests {

    @Test("a 1 MB text node is copied verbatim")
    func largeTextNode() throws {
        let text = String(repeating: "lorem ipsum & 中文 😀 \n", count: 40_000)
        #expect(text.utf8.count > 1_000_000)
        let input = "<root><t>" + text + "</t><u/></root>"
        #expect(try XMLFormatter.prettyPrint(input) == "<root>\n  <t>" + text + "</t>\n  <u/>\n</root>")
    }

    @Test("a 1 MB CDATA section is copied verbatim")
    func largeCDATA() throws {
        let data = String(repeating: "if (a < b && c > d) { x = ']]'; }\n", count: 32_000)
        #expect(data.utf8.count > 1_000_000)
        let input = "<root><s><![CDATA[" + data + "]]></s></root>"
        #expect(try XMLFormatter.prettyPrint(input) == "<root>\n  <s><![CDATA[" + data + "]]></s>\n</root>")
    }

    @Test("dense tiny elements match the legacy formatter")
    func denseTinyElements() throws {
        let input = "<r>" + String(repeating: "<a/><b></b><c>1</c>", count: 20_000) + "</r>"
        let result = try XMLFormatter.prettyPrint(input)
        #expect(result == (try LegacyXMLFormatter.prettyPrint(input)))
        #expect(result.split(separator: "\n").count == 60_002)
    }

    @Test("multi-byte and surrogate-pair characters in names, attributes and text")
    func multiByte() throws {
        let input = "<名前 属性=\"値😀\"><𝒜b é='ü𝒜'>😀 text 中文</𝒜b><x\u{3000}y=\"\u{00A0}\"/><z>𝄞</z></名前>"
        let expected = """
        <名前 属性="値😀">
          <𝒜b é='ü𝒜'>😀 text 中文</𝒜b>
          <x y="\u{00A0}"/>
          <z>𝄞</z>
        </名前>
        """
        let result = try XMLFormatter.prettyPrint(input)
        #expect(result == expected)
        #expect(result == (try LegacyXMLFormatter.prettyPrint(input)))
        // Canonically equivalent end-tag names still match, as before.
        let decomposed = "<caf\u{E9}>1</cafe\u{301}>"
        #expect(try XMLFormatter.prettyPrint(decomposed) == (try LegacyXMLFormatter.prettyPrint(decomposed)))
        // A mismatched non-ASCII name reports the legacy message.
        expectXMLError("<名前></名>", line: 1, message: "mismatched closing tag: expected </名前> but found </名>")
    }

    @Test("a real-shaped Info.plist matches the legacy formatter at every width")
    func realPlist() throws {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>\r
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\r
        <plist version="1.0"><dict><key>CFBundleDevelopmentRegion</key><string>en</string>\
        <key>CFBundleIdentifier</key><string>dev.example.App</string><key>CFBundleShortVersionString</key>\
        <string>0.13.0</string><key>LSMinimumSystemVersion</key><string>13.0</string>\
        <key>NSHumanReadableCopyright</key><string>© 2026 Example &amp; Co.</string>\
        <key>CFBundleDocumentTypes</key><array><dict><key>CFBundleTypeExtensions</key><array>\
        <string>txt</string><string>md</string></array><key>LSHandlerRank</key><string>Alternate</string>\
        </dict></array><key>SUEnableAutomaticChecks</key><true/><key>Count</key><integer>27</integer>\
        <key>Data</key><data>\nAAECAw==\n</data><key>Empty</key><string></string><key>Nothing</key><dict/></dict></plist>\r\n
        """
        for width in [1, 2, 4, 8] {
            let result = try XMLFormatter.prettyPrint(plist, indentWidth: width)
            #expect(result == (try LegacyXMLFormatter.prettyPrint(plist, indentWidth: width)))
        }
        let result = try XMLFormatter.prettyPrint(plist)
        #expect(result.contains("\n    <key>CFBundleTypeExtensions</key>\n") == false)
        #expect(result.contains("\n        <key>CFBundleTypeExtensions</key>\n"))
        #expect(result.contains("\n    <true/>\n"))
        #expect(result.contains("\n    <data>\nAAECAw==\n</data>\n"))
    }

    @Test("empty and whitespace-only input behave as before")
    func emptyInput() {
        for input in ["", "   ", "\n\n", "\r\n\t \r\n", "\r"] {
            #expect(newOutcome(input, 2) == legacyOutcome(input, 2), "input \(input.debugDescription)")
        }
        #expect(newOutcome("", 2) == .xmlError(XMLFormatError(line: 1, message: "missing root element")))
        #expect(newOutcome("\n\r\n\r", 2) == .xmlError(XMLFormatError(line: 4, message: "missing root element")))
    }

    @Test("legacy error messages and lines are unchanged for single-error inputs")
    func legacyErrors() {
        let cases = [
            "text<r/>", "<r/>junk", "<![CDATA[x]]><r/>", "<r/><s/>", "<?xml", "<!-- x", "<r><![CDATA[x</r>",
            "<!DOCTYPE r", "<r>< b/></r>", "<r>\n<a", "<r>\n<a>", "<r></>", "<r></r", "<r>\n</s>", "<!x>",
            "<r>a < b</r>", "<r><!DOCTYPE x></r>", "\u{FEFF}<r/>", "<r/>\n\n<!-- c --> x",
        ]
        for input in cases {
            let old = legacyOutcome(input, 2)
            guard case .xmlError = old else {
                Issue.record("legacy accepted \(input.debugDescription)")
                continue
            }
            #expect(newOutcome(input, 2) == old, "input \(input.debugDescription)")
        }
    }
}
