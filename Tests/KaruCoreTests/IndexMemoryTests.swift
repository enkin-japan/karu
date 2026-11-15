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
