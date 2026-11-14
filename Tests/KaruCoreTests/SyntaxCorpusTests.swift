import Foundation
import Testing
@testable import KaruCore

// M17 T17.11a — the parsers on real, valid code: every file must parse
// without error or recovered nodes. The committed samples run by default;
// the large corpora (typeshed stubs, the local CPython standard library,
// TypeScript's lib `.d.ts` files and `typescript.js`) are opt-in:
//
//     KARU_PARSER_CORPUS=1 swift test --filter SyntaxCorpus
//
// with the paths overridable by `KARU_TYPESHED`, `KARU_CPYTHON_LIB` and
// `KARU_TYPESCRIPT_PACKAGE`; the report (files, units, problems, parse
// time, the largest step ratio) goes to `KARU_PARSER_CORPUS_OUT` or
// `.build/m17-parser-corpus.txt`.

private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
private let corpusEnabled = ProcessInfo.processInfo.environment["KARU_PARSER_CORPUS"] == "1"

/// A parse's problems, with the first one located (line:column and text).
struct ParseReport {
    var errors = 0
    var recovered = 0
    var first: String?
    var capHits = 0
    var maxStepRatio = 0.0
    var problems: Int { errors + recovered }
}

func parseReport(_ text: NSString, dialect: SyntaxDialect) -> (SyntaxTree, ParseReport) {
    var build = SyntaxBuild(dialect: dialect, text: text, mode: .tree)
    let tree = build.finish(text)!.tree!
    var report = ParseReport()
    (report.errors, report.recovered) = tree.errorCounts
    report.capHits = build.capHits
    report.maxStepRatio = build.maxStepRatio
    if let p = tree.firstProblem {
        let n = tree[p]
        let before = text.substring(to: Int(n.start))
        let line = before.components(separatedBy: "\n").count
        let column = Int(n.start) - ((before as NSString).range(of: "\n", options: .backwards).location + 1)
        let lineRange = text.lineRange(for: NSRange(location: Int(n.start), length: 0))
        let source = text.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
        report.first = "\(line):\(column) \(n.kind)\(n.flags != 0 ? " flags \(n.flags)" : "") `\(source.prefix(120))`"
    }
    return (tree, report)
}

@Suite("Syntax parser corpora")
struct SyntaxCorpusTests {
    static let fixtures = repoRoot.appendingPathComponent("Tests/Fixtures/M17")

    /// The committed valid samples: grammar coverage files and the M17
    /// inference samples.
    static func committedSamples() -> [(URL, SyntaxDialect)] {
        let corpus = fixtures.appendingPathComponent("parser-corpus")
        var out: [(URL, SyntaxDialect)] = []
        for name in (try? FileManager.default.contentsOfDirectory(atPath: corpus.path))?.sorted() ?? [] {
            let url = corpus.appendingPathComponent(name)
            switch url.pathExtension {
            case "py", "pyi": out.append((url, .python))
            case "js", "jsx", "mjs": out.append((url, .javascript))
            case "ts": out.append((url, .typescript))
            case "tsx": out.append((url, .typescriptReact))
            default: break
            }
        }
        out.append((fixtures.appendingPathComponent("inference/sample_1000.py"), .python))
        out.append((fixtures.appendingPathComponent("inference/sample_1000.ts"), .typescript))
        return out
    }

    @Test func committedSamplesParseWithoutProblems() throws {
        let samples = Self.committedSamples()
        #expect(samples.count >= 8)
        for (url, dialect) in samples {
            let text = try String(contentsOf: url, encoding: .utf8) as NSString
            let (tree, report) = parseReport(text, dialect: dialect)
            #expect(report.problems == 0, "\(url.lastPathComponent): \(report.first ?? "")")
            #expect(report.capHits == 0)
            #expect(tree.textLength == text.length)
        }
    }

    // MARK: - Opt-in corpora

    struct Corpus {
        let name: String
        let root: URL
        let dialect: SyntaxDialect
        let include: (String) -> Bool
    }

    static func corpora() -> [Corpus] {
        let env = ProcessInfo.processInfo.environment
        let typeshed = env["KARU_TYPESHED"]
            ?? "/Volumes/enkin/project-support/KaruM17-TypeSources/typeshed-983d92a71d43"
        let cpython = env["KARU_CPYTHON_LIB"]
            ?? NSString(string: "~/.local/share/uv/python/cpython-3.13-macos-aarch64-none/lib/python3.13").expandingTildeInPath
        let typescript = env["KARU_TYPESCRIPT_PACKAGE"]
            ?? "/Volumes/enkin/project-support/KaruM17-TypeSources/typescript-6.0.3/package"
        return [
            Corpus(name: "typeshed stdlib", root: URL(fileURLWithPath: typeshed).appendingPathComponent("stdlib"),
                   dialect: .python, include: { $0.hasSuffix(".pyi") }),
            Corpus(name: "CPython 3.13 lib", root: URL(fileURLWithPath: cpython), dialect: .python,
                   include: { $0.hasSuffix(".py") && !$0.contains("site-packages/") }),
            Corpus(name: "TypeScript lib .d.ts", root: URL(fileURLWithPath: typescript).appendingPathComponent("lib"),
                   dialect: .typescript, include: { $0.hasSuffix(".d.ts") }),
            Corpus(name: "typescript.js", root: URL(fileURLWithPath: typescript).appendingPathComponent("lib"),
                   dialect: .javascript, include: { $0 == "typescript.js" }),
        ]
    }

    static func files(_ corpus: Corpus) -> [String] {
        guard let e = FileManager.default.enumerator(atPath: corpus.root.path) else { return [] }
        var out: [String] = []
        while let path = e.nextObject() as? String {
            if corpus.include(path) { out.append(path) }
        }
        return out.sorted()
    }

    /// Writes, per corpus file, the top-level statements' start lines and
    /// every named definition (name, line) as JSON lines, for a comparison
    /// with the reference parsers (Python `ast`, the TypeScript compiler API).
    static func dumpStructure(to path: String) throws {
        var out = ""
        for corpus in corpora() {
            for file in files(corpus) {
                let url = corpus.root.appendingPathComponent(file)
                guard let string = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let text = string as NSString
                let tree = SyntaxBuild.parse(text, dialect: corpus.dialect)
                var lineStarts = [0]
                for i in 0..<text.length where text.character(at: i) == 10 { lineStarts.append(i + 1) }
                func line(_ offset: Int32) -> Int {
                    var lo = 0, hi = lineStarts.count
                    while lo < hi {
                        let mid = (lo + hi) / 2
                        if lineStarts[mid] <= Int(offset) { lo = mid + 1 } else { hi = mid }
                    }
                    return lo
                }
                let top = tree.topLevelStatements.map { line(tree[$0].start) }
                var defs: [String] = []
                for (i, n) in tree.nodes.enumerated() {
                    let nameNode: Int?
                    switch n.kind {
                    case .funcDef, .classDef, .funcDecl, .classDecl, .classExpr, .interfaceDecl, .typeAlias, .enumDecl:
                        nameNode = tree.firstChild(i, kind: .name)
                    case .method where n.aux == 0:
                        // (Accessors and constructors are other kinds to the TS compiler.)
                        nameNode = tree.children(i).first { tree.kind($0) != .decorator }
                    default:
                        nameNode = nil
                    }
                    guard let nameNode, tree.kind(nameNode) == .name else { continue }
                    let name = text.substring(with: tree.range(nameNode))
                    defs.append("[\"\(name)\",\(line(tree[nameNode].start))]")
                }
                let escaped = url.path.replacingOccurrences(of: "\"", with: "\\\"")
                out += "{\"path\":\"\(escaped)\",\"dialect\":\"\(corpus.dialect.languageIdentifier)\",\"top\":\(top),\"defs\":[\(defs.joined(separator: ","))]}\n"
            }
        }
        try out.write(toFile: path, atomically: true, encoding: .utf8)
    }

    @Test(.enabled(if: corpusEnabled)) func corporaParseWithoutProblems() throws {
        var lines: [String] = []
        var failing: [String] = []
        for corpus in Self.corpora() {
            let files = Self.files(corpus)
            var units = 0, problems = 0, problemFiles = 0, capHits = 0
            var maxRatio = 0.0
            var seconds = 0.0
            var details: [String] = []
            for path in files {
                let url = corpus.root.appendingPathComponent(path)
                guard let data = FileManager.default.contents(atPath: url.path),
                      let string = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { continue }
                let text = string as NSString
                let start = DispatchTime.now().uptimeNanoseconds
                let (_, report) = parseReport(text, dialect: corpus.dialect)
                seconds += Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
                units += text.length
                capHits += report.capHits
                maxRatio = max(maxRatio, report.maxStepRatio)
                if report.problems > 0 {
                    problems += report.problems
                    problemFiles += 1
                    details.append("    \(path): \(report.errors) errors, \(report.recovered) recovered — \(report.first ?? "")")
                }
            }
            lines.append(String(format: "%@: %d files, %.1f M units, %d problems in %d files, %d cap hits, max step ratio %.1f, parse %.2f s",
                                corpus.name, files.count, Double(units) / 1e6, problems, problemFiles, capHits, maxRatio, seconds))
            lines.append(contentsOf: details)
            if problems > 0 { failing.append(corpus.name) }
        }
        if let dump = ProcessInfo.processInfo.environment["KARU_PARSER_CORPUS_DUMP"] {
            try Self.dumpStructure(to: dump)
        }
        let report = lines.joined(separator: "\n") + "\n"
        let out = ProcessInfo.processInfo.environment["KARU_PARSER_CORPUS_OUT"]
            ?? repoRoot.appendingPathComponent(".build/m17-parser-corpus.txt").path
        try report.write(toFile: out, atomically: true, encoding: .utf8)
        print(report)
        #expect(failing.isEmpty, "corpora with problems: \(failing) (see \(out))")
    }
}
