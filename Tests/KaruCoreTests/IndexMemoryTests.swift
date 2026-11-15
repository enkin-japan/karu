import Foundation
import Testing
@testable import KaruCore

// M17 T17.15a — the project-folder index's peak allocations (plan §11
// degradation order, step 1: reduce the scanner's peak before lowering the
// per-file cap). The index's resident memory is the allocator's high-water
// mark after its largest file, so each change bounds a buffer that grew with
// the file; none may change what is indexed:
//   - the text is a native Swift string bridged to `NSString` (UTF-8
//     storage) instead of a UTF-16 copy, with the same contents;
//   - declaration tokens are 20 bytes (32-bit offsets), the buffer a
//     file-long logical line keeps is half the size;
//   - the file is read straight into that string's storage (no `Data`);
//   - an autorelease pool per indexed file.
// T17.15d (the allocator keeps every freed block resident, so the index's
// footprint is the high-water mark of one file's transient allocations):
//   - `IndexedSymbol.extract` streams the scan's declarations in one pass
//     (no materialised declaration list, no second "pending" array) and
//     returns exactly what the two-pass version did;
//   - `IndexSignatures.enrich` updates the symbols in place;
//   - files above `IndexScope.richSignatureMaxBytes` keep the parameter-name
//     signatures (no summariser pass).

private let fixtureRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/M17")

private func language(of path: String) -> String? {
    switch (path as NSString).pathExtension {
    case "py", "pyi": return "python"
    case "ts", "mts", "cts": return "typescript"
    case "tsx": return "typescriptreact"
    case "js", "mjs", "cjs", "jsx": return "javascript"
    case "go": return "go"
    case "swift": return "swift"
    case "rs": return "rust"
    case "java": return "java"
    case "cs": return "csharp"
    case "c", "h": return "c"
    case "cpp", "hpp", "cc": return "cpp"
    default: return nil
    }
}

private func digest(_ symbols: [IndexedSymbol]) -> [String] {
    symbols.map { "\($0.name)|\($0.kind)|\($0.container ?? "")|\($0.location)|\($0.line)|\($0.signature ?? "")" }
}

/// Every fixture source file with its language.
private func fixtureSources() throws -> [(String, String, Data)] {
    var out: [(String, String, Data)] = []
    for sub in ["imports", "crossfile", "completion", "highlight", "inference"] {
        let root = fixtureRoot.appendingPathComponent(sub).path
        guard let walker = FileManager.default.enumerator(atPath: root) else { continue }
        for case let relative as String in walker {
            guard let language = language(of: relative) else { continue }
            let data = try Data(contentsOf: URL(fileURLWithPath: root + "/" + relative))
            out.append((sub + "/" + relative, language, data))
        }
    }
    return out
}

/// A ~200 KB Python module with classes, functions, annotated variables and
/// a module-long literal like `pydoc_data/topics.py` (one logical line).
private func largePython() -> String {
    var out = "\"\"\"Generated.\"\"\"\nfrom typing import Optional\n\n"
    var k = 0
    while out.utf16.count < 200_000 {
        out += """
        class Model\(k):
            limit: int = \(k)

            def __init__(self, value: int, label: Optional[str] = None) -> None:
                self.value = value

            def scaled\(k)(self, factor: float = 1.5, *, rounded: bool = True) -> float:
                return self.value * factor


        def helper\(k)(a: int, b: str = "x", *rest: int, **options: str) -> list[str]:
            return [b]

        CONSTANT_\(k): int = \(k)


        """
        k += 1
    }
    out += "topics = {\n"
    for i in 0..<400 { out += "    'key\(i)': 'first line\\n'\n              'second line\\n',\n" }
    out += "}\n"
    return out
}

private func largeScript() -> String {
    var out = "// Generated.\n"
    var k = 0
    while out.utf16.count < 200_000 {
        out += """
        export class Widget\(k) {
          size: number = \(k);
          render\(k)(x: number, y: string = 'a'): string[] { return [y]; }
        }
        export function build\(k)(opts: { width: number }, ...rest: number[]): Widget\(k) { return new Widget\(k)(); }
        export const value\(k): number = \(k);
        /** @param {string} name */
        export function legacy\(k)(name) { return name; }


        """
        k += 1
    }
    return out
}

/// The two-pass `IndexedSymbol.extract` before T17.15d (materialised
/// declarations, a pending list, then a line sweep): the reference the
/// streaming version must match.
private func referenceExtract(from scan: DeclarationScan, text: NSString) -> [IndexedSymbol] {
    let scopes = scan.scopes
    let declarations = scan.declarations
    guard !declarations.isEmpty else { return [] }
    let documentLength = scan.documentLength
    func contains(_ scope: DeclarationScan.Scope, _ offset: Int) -> Bool {
        scope.start <= offset
            && (offset < scope.end || scope.end >= documentLength || scope.kind == .embedded && offset == scope.end)
    }
    func isContainer(_ scope: DeclarationScan.Scope) -> Bool {
        scope.kind == .class || (scope.kind == .block && scope.name != nil)
    }
    var parameters: [Int: [String]] = [:]
    var pending: [(name: String, kind: DeclarationScan.DeclarationKind, container: String?, location: Int, ownScope: Int?)] = []
    var stack: [DeclarationScan.Scope] = []
    var next = 0
    for declaration in declarations {
        let location = declaration.location
        while next < scopes.count, scopes[next].start <= location {
            let scope = scopes[next]
            while let top = stack.last, top.index != scope.parent { stack.removeLast() }
            stack.append(scope)
            next += 1
        }
        while let top = stack.last, !contains(top, location) { stack.removeLast() }
        guard let innermost = stack.last else { continue }
        switch declaration.kind {
        case .parameter:
            if innermost.kind == .function || innermost.kind == .lambda {
                parameters[innermost.index, default: []].append(declaration.name)
            }
            continue
        case .import, .global, .nonlocal:
            continue
        default:
            break
        }
        let owner: Int
        var ownScope: Int?
        if innermost.kind == .module || isContainer(innermost) {
            owner = stack.count - 1
        } else if declaration.kind == .function || declaration.kind == .method,
                  innermost.kind == .function, innermost.name == declaration.name, stack.count >= 2,
                  stack[stack.count - 2].kind == .module || isContainer(stack[stack.count - 2]) {
            owner = stack.count - 2
            ownScope = innermost.index
        } else if declaration.kind == .property, let classPosition = stack.lastIndex(where: { $0.kind == .class }) {
            owner = classPosition
        } else {
            continue
        }
        let names = stack[...owner].filter(isContainer).compactMap(\.name)
        var container = names.isEmpty ? nil : names.joined(separator: ".")
        if ownScope != nil, container == nil, let receiver = goReceiverType(text, nameLocation: location) {
            container = receiver
        }
        pending.append((declaration.name, declaration.kind, container, location, ownScope))
    }
    var symbols: [IndexedSymbol] = []
    var line = 1
    var cursor = 0
    let length = text.length
    for item in pending {
        let target = min(item.location, length)
        while cursor < target {
            let u = text.character(at: cursor)
            if u == 10 {
                line += 1
            } else if u == 13, cursor + 1 >= length || text.character(at: cursor + 1) != 10 {
                line += 1
            }
            cursor += 1
        }
        var signature: String?
        if let own = item.ownScope {
            signature = "(" + (parameters[own] ?? []).joined(separator: ", ") + ")"
        } else if item.kind == .function || item.kind == .method,
                  let first = scopes.first(where: { $0.start >= item.location }),
                  first.kind == .function || first.kind == .lambda, first.name == item.name {
            signature = "(" + (parameters[first.index] ?? []).joined(separator: ", ") + ")"
        }
        symbols.append(IndexedSymbol(name: item.name, kind: item.kind, container: item.container,
                                     location: item.location, line: line, signature: signature))
    }
    return symbols
}

@Suite("IndexMemory", .serialized)
struct IndexMemoryTests {

    @Test func declarationTokensAreTwentyBytes() {
        #expect(MemoryLayout<DeclToken>.stride <= 20)
        var token = DeclToken(kind: .ident, start: 1_234_567, end: 1_234_570)
        token.indent = 17
        token.lineStart = 1_234_000
        #expect(token.start == 1_234_567 && token.end == 1_234_570 && token.length == 3)
        #expect(token.indent == 17 && token.lineStart == 1_234_000)
    }

    /// The index (file read into a native string, bridged) indexes exactly
    /// what it did from `NSString(data:)`'s UTF-16 copy: every fixture,
    /// generated large Python (a module-long literal) and TypeScript, and
    /// edge samples — non-ASCII, astral, a BOM, CRLF and invalid UTF-8 (both
    /// decode it with replacement characters).
    @Test func bridgedTextIndexesLikeTheUTF16Copy() throws {
        var cases = try fixtureSources()
        cases.append(("large.py", "python", Data(largePython().utf8)))
        cases.append(("large.ts", "typescript", Data(largeScript().utf8)))
        cases += [
            ("café.py", "python", Data("def café(naïve, 名前=1):\n    return naïve\nclass Ünïcode:\n    x𝔸 = 1\n".utf8)),
            ("bom.py", "python", Data([0xEF, 0xBB, 0xBF] + Array("def f(a):\r\n    return a\r\n".utf8))),
            ("bad.py", "python", Data(Array("def ok(a):\n    s = '".utf8) + [0xFF, 0xFE, 0xC3]
                                      + Array("'\ndef after(b):\n    pass\n".utf8))),
            ("astral.ts", "typescript", Data("export function 𝑓(x: number): string { return ''; }\nexport class Ä { b = 1 }\n".utf8)),
            ("größe.go", "go", Data("package m\n\nfunc Größe(a int) int { return a }\n".utf8)),
        ]
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IndexMemoryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var symbols = 0
        for (k, (name, language, data)) in cases.enumerated() {
            var bytes = data
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
            let utf16 = NSString(data: bytes, encoding: String.Encoding.utf8.rawValue)
                ?? (String(decoding: bytes, as: UTF8.self) as NSString)
            let scan = DeclarationScan.scan(text: utf16 as String, languageIdentifier: language)
            let expected = IndexSignatures.enrich(IndexedSymbol.extract(from: scan, text: utf16), text: utf16,
                                                  language: language)
            let url = directory.appendingPathComponent("\(k)-" + (name as NSString).lastPathComponent)
            try data.write(to: url)
            let text = try #require(WorkspaceIndex.readText(atPath: url.path, size: data.count))
            #expect(digest(WorkspaceIndex.symbols(of: text, language: language)) == digest(expected), "\(name)")
            #expect(digest(WorkspaceIndex.symbols(of: data, language: language)) == digest(expected), "\(name)")
            symbols += expected.count
        }
        #expect(cases.count > 40)
        #expect(symbols > 2_000)
    }

    /// T17.15d: the streaming `extract` returns exactly the two-pass
    /// reference's symbols (names, kinds, containers, locations, lines and
    /// parameter-name signatures) for every fixture in every language, the
    /// generated large Python / TypeScript, Go methods, CRLF / CR line ends
    /// and non-ASCII names.
    @Test func streamingExtractMatchesTheTwoPassReference() throws {
        var cases = try fixtureSources().map { ($0.0, $0.1, String(decoding: $0.2, as: UTF8.self)) }
        cases.append(("large.py", "python", largePython()))
        cases.append(("large.ts", "typescript", largeScript()))
        cases += [
            ("crlf.py", "python", "class A:\r\n    def m(self, x):\r\n        self.v = x\r\ndef f(a, b=1):\r\n    pass\r\n"),
            ("cr.py", "python", "def f(a):\r    return a\rclass B:\r    y = 2\r"),
            ("methods.go", "go", "package m\n\ntype S struct{ A int }\n\nfunc (s *S) Run(port int, h string) error { return nil }\nfunc (S) Name() string { return \"\" }\nfunc New(a int) *S { return nil }\n"),
            ("café.py", "python", "def café(naïve, 名前=1):\n    return naïve\nclass Ünïcode:\n    x𝔸 = 1\n"),
            ("ns.ts", "typescript", "namespace Outer { export namespace Inner { export function deep(a: number) {} } }\nclass K { m(x) {} p = 1 }\n"),
        ]
        var symbols = 0
        for (name, language, text) in cases {
            let ns = text as NSString
            let scan = DeclarationScan.scan(text: text, languageIdentifier: language)
            let streamed = IndexedSymbol.extract(from: scan, text: ns)
            let reference = referenceExtract(from: scan, text: ns)
            #expect(streamed == reference, "\(name)")
            symbols += reference.count
        }
        #expect(cases.count > 40)
        #expect(symbols > 2_000)
    }

    /// T17.15d: in-place `enrich` gives what mapping over a copy gave, and
    /// leaves a caller's other reference to the array untouched.
    @Test func inPlaceEnrichKeepsOtherReferences() {
        let text = "def f(a: int, b: str = 'x') -> list[str]:\n    return [b]\nclass C:\n    def m(self, n: float) -> None: ...\n" as NSString
        let plain = IndexedSymbol.extract(from: DeclarationScan.scan(text: text as String, languageIdentifier: "python"), text: text)
        let kept = plain
        let enriched = IndexSignatures.enrich(plain, text: text, language: "python")
        #expect(kept == plain)
        #expect(kept.first?.signature == "(a, b)")
        #expect(enriched.map(\.name) == plain.map(\.name))
        #expect(enriched.map(\.location) == plain.map(\.location))
        #expect(enriched.first?.signature != nil && enriched.first?.signature != "(a, b)")
    }

    /// T17.15d: files above `richSignatureMaxBytes` are indexed with the
    /// parameter-name signatures (no summariser), smaller ones with
    /// summaries; the names, kinds and locations are the same either way.
    @Test func largeFilesKeepParameterNameSignatures() async throws {
        #expect(IndexScope().richSignatureMaxBytes == 64 * 1024)
        let f = IndexFixture()
        let small = "def small(a: int, b: str = 'x') -> int:\n    return a\n"
        var large = "def large(a: int, b: str = 'x') -> int:\n    return a\n"
        while large.utf8.count <= 400 { large += "# padding padding padding padding\n" }
        f.write("small.py", small)
        f.write("large.py", large)
        let index = f.makeIndex(scope: IndexScope(richSignatureMaxBytes: 200))
        index.start()
        index.addFolder(f.folder)
        #expect(await settle(index))
        let smallRow = try #require(index.symbols(inFile: f.folder.appendingPathComponent("small.py").path).first)
        let largeRow = try #require(index.symbols(inFile: f.folder.appendingPathComponent("large.py").path).first)
        let rich = try #require(WorkspaceIndex.symbols(of: Data(small.utf8), language: "python").first)
        let plain = try #require(WorkspaceIndex.symbols(of: Data(large.utf8), language: "python", rich: false).first)
        #expect(smallRow.signature == rich.signature)
        #expect(smallRow.signature != "(a, b)")
        #expect(largeRow.signature == plain.signature)
        #expect(largeRow.signature == "(a, b)")
        #expect(largeRow.name == "large" && largeRow.line == 1)
    }

    /// `readText` (straight into the string's storage) reads what
    /// `decodedText` decodes from the bytes: BOM, invalid UTF-8, empty,
    /// astral; a file longer than its stat'ed size is read whole.
    @Test func readTextMatchesDecodedText() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IndexMemoryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let samples: [[UInt8]] = [
            [], Array("x = 1\n".utf8), [0xEF, 0xBB, 0xBF] + Array("def f():\n    pass\n".utf8), [0xEF, 0xBB, 0xBF],
            Array("a = '".utf8) + [0xFF, 0xC3, 0x28, 0xE2, 0x82] + Array("'\n名前 = 𝔸\n".utf8),
            Array(String(repeating: "def g(a, b):\n    return a\n", count: 3_000).utf8),
        ]
        for (k, bytes) in samples.enumerated() {
            let url = directory.appendingPathComponent("f\(k).py")
            try Data(bytes).write(to: url)
            let text = try #require(WorkspaceIndex.readText(atPath: url.path, size: bytes.count))
            #expect(text as String == WorkspaceIndex.decodedText(Data(bytes)), "sample \(k)")
            // Stat'ed smaller than it is now: still the whole file.
            let grown = try #require(WorkspaceIndex.readText(atPath: url.path, size: max(0, bytes.count - 2)))
            #expect(grown as String == WorkspaceIndex.decodedText(Data(bytes)), "sample \(k), grown")
        }
        #expect(WorkspaceIndex.readText(atPath: directory.appendingPathComponent("missing.py").path, size: 3) == nil)
    }
}
