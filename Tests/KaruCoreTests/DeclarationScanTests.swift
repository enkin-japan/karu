import Foundation
import Testing
@testable import KaruCore

// M17 T17.1 — `DeclarationScan` runs the declaration regexes once and derives
// the navigator locations, the highlighter's classified table and the
// completion symbol set. It must reproduce the three pre-T17.1 scans exactly.

private enum ScanPaths {
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // KaruCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root
    static let fixtures = root.appendingPathComponent("Tests/Fixtures/M17", isDirectory: true)
    static let tests = root.appendingPathComponent("Tests/KaruCoreTests", isDirectory: true)
}

/// Every registered language identifier, plus plain / unknown.
private let allLanguageIdentifiers = [
    "json", "jsonl", "markdown", "python", "javascript", "typescript", "html", "css",
    "c", "cpp", "csharp", "java", "bash", "sql", "xml", "yaml", "toml", "go", "rust",
    "swift", "", "plaintext",
]

/// Removes the `⟨n⟩` caret markers used by the completion fixtures.
private func stripCaretMarkers(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{27E8}\\d+\u{27E9}", with: "", options: .regularExpression)
}

/// Every regular file under `directory`, recursively.
private func files(under directory: URL) -> [URL] {
    guard let walker = FileManager.default.enumerator(at: directory,
                                                      includingPropertiesForKeys: [.isRegularFileKey]) else {
        return []
    }
    var out: [URL] = []
    for case let url as URL in walker {
        if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { out.append(url) }
    }
    return out.sorted { $0.path < $1.path }
}

/// Decodes the escapes that appear in the test sources' string literals.
private func unescapeSwiftLiteral(_ body: String) -> String {
    var out = ""
    var chars = Array(body)
    var i = 0
    while i < chars.count {
        let c = chars[i]
        guard c == "\\", i + 1 < chars.count else { out.append(c); i += 1; continue }
        let next = chars[i + 1]
        switch next {
        case "n": out.append("\n"); i += 2
        case "t": out.append("\t"); i += 2
        case "r": out.append("\r"); i += 2
        case "0": out.append("\0"); i += 2
        case "\"": out.append("\""); i += 2
        case "'": out.append("'"); i += 2
        case "\\": out.append("\\"); i += 2
        case "u":
            // \u{XXXX}
            if i + 2 < chars.count, chars[i + 2] == "{",
               let close = chars[(i + 3)...].firstIndex(of: "}"),
               let scalar = UInt32(String(chars[(i + 3)..<close]), radix: 16).flatMap(Unicode.Scalar.init) {
                out.unicodeScalars.append(scalar)
                i = close + 1
            } else {
                out.append(c); i += 1
            }
        default:
            out.append(c); i += 1
        }
    }
    chars.removeAll()
    return out
}

/// The string literals in a Swift test source: multi-line `"""` blocks (with
/// the closing delimiter's indentation stripped) and single-line `"…"`
/// literals. An approximation of the compiler's rules that is exact for the
/// plain literals these suites use (no interpolation, no raw strings).
private func stringLiterals(inSwiftSource source: String) -> [String] {
    var literals: [String] = []
    let lines = source.components(separatedBy: "\n")
    var index = 0
    // swiftlint:disable:next force_try
    let single = try! NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)
    while index < lines.count {
        let line = lines[index]
        if line.trimmingCharacters(in: .whitespaces).hasSuffix("\"\"\""),
           line.components(separatedBy: "\"\"\"").count == 2 {
            // Opening delimiter: collect until the closing line.
            var body: [String] = []
            var close = index + 1
            while close < lines.count, !lines[close].trimmingCharacters(in: .whitespaces).hasPrefix("\"\"\"") {
                body.append(lines[close])
                close += 1
            }
            guard close < lines.count else { break }
            let indent = String(lines[close].prefix { $0 == " " || $0 == "\t" })
            let stripped = body.map { $0.hasPrefix(indent) ? String($0.dropFirst(indent.count)) : $0 }
            literals.append(unescapeSwiftLiteral(stripped.joined(separator: "\n")))
            index = close + 1
            continue
        }
        let ns = line as NSString
        for match in single.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            literals.append(unescapeSwiftLiteral(ns.substring(with: match.range(at: 1))))
        }
        index += 1
    }
    return literals
}

/// All equivalence inputs, labelled for failure messages.
private func equivalenceInputs() throws -> [(label: String, text: String)] {
    var inputs: [(String, String)] = []
    let fixtureDirs = ["highlight", "completion", "inference"]
    for dir in fixtureDirs {
        for url in files(under: ScanPaths.fixtures.appendingPathComponent(dir, isDirectory: true)) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            inputs.append(("\(dir)/\(url.lastPathComponent)", stripCaretMarkers(text)))
        }
    }
    for suite in ["SymbolTableTests.swift", "CompletionTests.swift", "SymbolNavigatorTests.swift"] {
        let source = try String(contentsOf: ScanPaths.tests.appendingPathComponent(suite), encoding: .utf8)
        for (n, literal) in stringLiterals(inSwiftSource: source).enumerated() {
            inputs.append(("\(suite)#\(n)", literal))
        }
    }
    // Edge shapes: empty, terminators only, CRLF code, astral characters.
    inputs += [
        ("edge/empty", ""),
        ("edge/crlf-only", "\r\n\r\n"),
        ("edge/crlf-python", "def f(a, b):\r\n    x = 1\r\nclass K:\r\n    pass\r\n"),
        ("edge/emoji", "const 😀a = 1;\nfunction f😀(x) {}\nlet [p, q] = r;\ndef g(*args, **kw): pass\n"),
        ("edge/c-control", "if (x) { while (y) foo(1); } class Bar { void baz(int q); }\n"),
        // Gaps of ~20 000 and ~300 000 units between declarations: multi-byte
        // location deltas in the compact encoding.
        ("edge/wide-gaps", (0..<6).map { i in
            "def gap_fn_\(i)(p\(i), q):\n    v\(i) = 1\n" + String(repeating: "# filler\n", count: i == 3 ? 33_000 : 2_200)
        }.joined()),
    ]
    return inputs
}

@Test func declarationScanMatchesLegacyScansOnEveryFixtureAndLanguage() throws {
    let inputs = try equivalenceInputs()
    // Sanity: the fixture tree and the three suites were actually found.
    #expect(inputs.filter { $0.label.hasPrefix("highlight/") }.count >= 20)
    #expect(inputs.filter { $0.label.hasPrefix("completion/") }.count >= 10)
    #expect(inputs.filter { $0.label.hasPrefix("inference/") }.count == 2)
    #expect(inputs.filter { $0.label.hasPrefix("SymbolTableTests") }.count >= 7)
    #expect(inputs.filter { $0.label.hasPrefix("SymbolNavigatorTests") }.count >= 5)
    #expect(inputs.filter { $0.label.hasPrefix("CompletionTests") }.count >= 3)

    var compared = 0
    var nonEmpty = 0
    for input in inputs {
        for language in allLanguageIdentifiers {
            let scan = DeclarationScan.scan(text: input.text, languageIdentifier: language)
            let table = WordIndex.legacySymbolTable(text: input.text, languageIdentifier: language)
            let locations = WordIndex.legacyScanSymbolLocations(text: input.text, languageIdentifier: language)
            let symbols = WordIndex.legacySymbols(text: input.text, languageIdentifier: language)
            #expect(scan.languageIdentifier == language)
            #expect(scan.table == table, "table differs: \(input.label) [\(language)]")
            #expect(scan.locations == locations, "locations differ: \(input.label) [\(language)]")
            #expect(scan.completionSymbols == symbols, "symbols differ: \(input.label) [\(language)]")
            #expect(scan.locationCount == locations.count)
            // The wrappers the existing callers use go through the same scan.
            #expect(WordIndex.symbolTable(text: input.text, languageIdentifier: language) == table)
            compared += 1
            if !locations.isEmpty { nonEmpty += 1 }
        }
    }
    // The comparison must have exercised real declarations, not just empties.
    #expect(compared == inputs.count * allLanguageIdentifiers.count)
    #expect(nonEmpty >= 100)
}

@Test func declarationScanProductsAreMutuallyConsistent() {
    let source = """
    const { a, b } = obj;
    const handler = async (evt, ...rest) => evt;
    function compute(x, y) { return x + y; }
    class Widget {}
    let total = 0;
    """
    let scan = DeclarationScan.scan(text: source, languageIdentifier: "javascript")
    // Every location name is in the table; the flat set is the table's union.
    let tableNames = scan.table.all
    #expect(Set(scan.locations.map(\.name)) == tableNames)
    #expect(scan.completionSymbols == tableNames)
    #expect(scan.table.functions.contains("handler"))
    #expect(scan.table.variables.contains("rest"))
    #expect(!scan.table.variables.contains("handler"))
    // Document order.
    #expect(scan.locations.map(\.range.location) == scan.locations.map(\.range.location).sorted())
}
