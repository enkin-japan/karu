import AppKit
import Foundation
import Testing
@testable import KaruCore

// First-paint / memory fix for folding: the allocation-free, resumable
// `FoldScan` must report exactly what the original `Character`-based scanner
// (kept as `LegacyFoldScanner`) reported; bounded windows must agree with the
// full scan on every line they resolve; and the controller's sliced scan must
// never publish results for text that changed underneath it.

private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func newScan(_ text: String, language: String = "") -> [FoldRegion] {
    FoldScanner.regions(text: text, lineIndex: LineIndex(text: text), language: language)
}

private func legacyScan(_ text: String, language: String = "") -> [FoldRegion] {
    LegacyFoldScanner.regions(text: text, lineIndex: LineIndex(text: text), language: language)
}

/// Every text fixture under Tests/Fixtures (highlight, embedded, parser,
/// completion, inference samples, parser corpus, baselines).
private func fixtureFiles() -> [URL] {
    let root = repoRoot.appendingPathComponent("Tests/Fixtures")
    guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
    var files: [URL] = []
    for case let url as URL in walker where !url.hasDirectoryPath {
        files.append(url)
    }
    return files.sorted { $0.path < $1.path }
}

/// `seed` repeated (with a per-copy suffix so lines are not all identical)
/// until the text reaches `targetBytes`.
private func repeated(_ seed: String, targetBytes: Int) -> String {
    var out = ""
    out.reserveCapacity(targetBytes + seed.utf8.count)
    var copy = 0
    while out.utf8.count < targetBytes {
        out += seed
        out += "\n# copy \(copy)\n"
        copy += 1
    }
    return out
}

private func fixture(_ relative: String) throws -> String {
    try String(contentsOf: repoRoot.appendingPathComponent(relative), encoding: .utf8)
}

/// Deterministic generator (SplitMix64) for the fuzz corpus.
private struct SplitMix {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func pick<T>(_ items: [T]) -> T { items[Int(next() % UInt64(items.count))] }
}

/// Short random documents built from every token the rules care about,
/// including the grapheme edge cases (combining / prepend marks glued to
/// structural characters, surrogate pairs, CRLF / CR terminators).
private func fuzzDocument(_ rng: inout SplitMix) -> String {
    let tokens = ["{", "}", "[", "]", "(", ")", ":", ",", ";", " ", "  ", "    ", "\t",
                  "\n", "\n", "\n", "\r\n", "\r", "#", "## ", "# ", "```", "~~~", "`", "~",
                  "a", "def f():", "x = [", "if y:", "  return", "\u{0301}", "\u{0600}", "\u{200D}",
                  "😀", "👍🏽", "中文", "\u{3099}", "e\u{0301}", "#\u{FE0F}", ": ", ":\u{0301}"]
    let count = 1 + Int(rng.next() % 120)
    var out = ""
    for _ in 0..<count { out += rng.pick(tokens) }
    return out
}

// MARK: - Scanner equivalence

struct FoldScanEquivalenceTests {
    @Test func everyFixtureMatchesTheLegacyScanner() throws {
        let files = fixtureFiles()
        #expect(files.count > 50, "fixture walk found only \(files.count) files")
        var compared = 0
        for url in files {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            // Both rule sets on every file: markdown rules on code and code
            // rules on markdown are extra coverage for free.
            for language in ["", "markdown"] {
                #expect(newScan(text, language: language) == legacyScan(text, language: language),
                        "\(url.lastPathComponent) language=\(language.isEmpty ? "plain" : language)")
            }
            compared += 1
        }
        #expect(compared > 50)
    }

    @Test func groupedEdgeCasesMatchTheLegacyScanner() {
        let cases = [
            "", "\n", "{", "}", "{\n}", "{\n\n}", "[\n  1,\n  2\n]\n",
            "def f():\n    pass\n", "def f():\r\n    pass\r\n", "def f():\r    pass\r",
            "a:\n \u{0301}x\n  y\n", " \u{0301}a:\n   b\n", "a\u{0600}:\n  b\n", "a:\u{0301}\n  b\n",
            "a: \t\n\tb\n\n\n", "x = [\n    1,\n  ],\n  ]\n", "f(\n  a\n)\n",
            "# A\ntext\n## B\nmore\n# C\n", "#\u{0301} A\nx\n", "# \u{0301}A\nx\n", "  # A\nx\n",
            "    # A\nx\n", "####### A\nx\n", "```\ncode\n```\n", "```\u{0301}\ncode\n```\n",
            "````\u{0301}\ncode\n````\n", "``` a`b\nx\n```\n", "``` a`\u{0301}b\nx\n```\n",
            "~~~\n# not\n~~~~\n", "```\nunclosed\n\n\n", "# H\n```\n# in\n```\nx\n\n",
            "{\n  \"k\": \"😀\",\n  \"v\": [👍🏽,\n  1]\n}\n", "中文:\n  行\n", "a:\u{3099}\n  b\n",
        ]
        for text in cases {
            for language in ["", "markdown"] {
                #expect(newScan(text, language: language) == legacyScan(text, language: language),
                        "\(text.debugDescription) language=\(language)")
            }
        }
    }

    @Test func fuzzedDocumentsMatchTheLegacyScanner() {
        var rng = SplitMix(state: 0x5EED_F01D)
        for _ in 0..<1500 {
            let text = fuzzDocument(&rng)
            for language in ["", "markdown"] {
                let fresh = newScan(text, language: language)
                let legacy = legacyScan(text, language: language)
                #expect(fresh == legacy, "\(text.debugDescription) language=\(language)")
                if fresh != legacy { return }
            }
        }
    }

    /// The memory-benchmark shape: ~10 MB of Python and of JavaScript.
    @Test func tenMegabyteDocumentsMatchTheLegacyScanner() throws {
        let python = repeated(try fixture("Tests/Fixtures/M17/inference/sample_1000.py"), targetBytes: 10 << 20)
        let script = repeated(try fixture("Tests/Fixtures/M17/parser-corpus/javascript-grammar.js"),
                              targetBytes: 10 << 20)
        for text in [python, script] {
            let fresh = newScan(text)
            #expect(fresh.count > 10_000)
            #expect(fresh == legacyScan(text))
        }
    }

    @Test func outputIsSortedAndUnique() throws {
        let text = try fixture("Tests/Fixtures/M17/inference/sample_1000.ts")
        let regions = newScan(text)
        for (a, b) in zip(regions, regions.dropFirst()) {
            #expect(FoldRegion.precedes(a, b))
        }
    }

    @Test func foldRegionIsCompact() {
        #expect(MemoryLayout<FoldRegion>.stride == 8)
        var region = FoldRegion(startLine: 3, endLine: 9)
        region.endLine = 12
        #expect(region.startLine == 3 && region.endLine == 12)
    }
}

// MARK: - Sliced and windowed scans

struct FoldScanSlicingTests {
    /// Resuming after every few code units gives the one-shot result.
    @Test func tinySlicesMatchTheOneShotScan() throws {
        for (path, language) in [("Tests/Fixtures/M17/inference/sample_1000.py", ""),
                                 ("Tests/Fixtures/M17/highlight/javascript.js", ""),
                                 ("Tests/Fixtures/M17/highlight/embedded/fences.md", "markdown")] {
            let text = try fixture(path)
            let lineIndex = LineIndex(text: text)
            let scan = try #require(FoldScan(ns: text as NSString, lineIndex: lineIndex, language: language))
            var calls = 0
            while !scan.advance(maxWork: 37) { calls += 1 }
            #expect(calls > 10)
            #expect(scan.regions == FoldScanner.regions(text: text, lineIndex: lineIndex, language: language))
        }
    }

    /// A single huge line is still sliced (the generic rules resume mid-line).
    @Test func aSingleLongLineIsSliced() {
        let text = "[" + String(repeating: "{\"a\": 1}, ", count: 50_000) + "\n  1\n]\n"
        let lineIndex = LineIndex(text: text)
        let scan = FoldScan(ns: text as NSString, lineIndex: lineIndex, language: "")!
        #expect(scan.advance(maxWork: 10_000) == false)
        scan.advance()
        #expect(scan.regions == [FoldRegion(startLine: 1, endLine: 2)])
    }

    /// Windows with an ample budget equal the full scan restricted to the window.
    @Test func windowsMatchTheFullScan() throws {
        let inputs: [(String, String)] = [
            (try fixture("Tests/Fixtures/M17/inference/sample_1000.py"), ""),
            (try fixture("Tests/Fixtures/M17/inference/sample_1000.ts"), ""),
            (try fixture("Tests/Fixtures/M17/parser-corpus/react-grammar.tsx"), ""),
            (try fixture("Tests/Fixtures/M17/highlight/yaml.yaml"), ""),
            (try fixture("Tests/Fixtures/M17/highlight/markdown.md"), "markdown"),
            (try fixture("Tests/Fixtures/M17/highlight/embedded/fences.md"), "markdown"),
        ]
        for (text, language) in inputs {
            let lineIndex = LineIndex(text: text)
            let full = FoldScanner.regions(text: text, lineIndex: lineIndex, language: language)
            for size in [1, 7, 128] {
                var first = 1
                while first <= lineIndex.lineCount {
                    let lines = first...(first + size - 1)
                    let window = FoldScanner.window(in: text as NSString, lineIndex: lineIndex,
                                                    language: language, lines: lines, budget: .max)
                    #expect(window.isComplete)
                    #expect(window.regions == full.filter { lines.contains($0.startLine) },
                            "window \(lines) language=\(language)")
                    first += size
                }
            }
        }
    }

    /// With a tight budget, every line a window resolves is exact, and lines
    /// it cannot settle are reported unresolved rather than guessed.
    @Test func budgetedWindowsAreExactOnResolvedLines() throws {
        var rng = SplitMix(state: 42)
        let inputs: [(String, String)] = [
            (try fixture("Tests/Fixtures/M17/parser-corpus/javascript-grammar.js"), ""),
            (try fixture("Tests/Fixtures/M17/inference/sample_1000.py"), ""),
            (try fixture("Tests/Fixtures/M17/highlight/markdown.md"), "markdown"),
            // One opener matched only at the very end: unresolved under budget.
            ("(function () {\n" + String(repeating: "  x = [\n    1,\n  ];\n", count: 5_000) + "})();\n", ""),
        ]
        var sawUnresolved = false
        for (text, language) in inputs {
            let lineIndex = LineIndex(text: text)
            let full = FoldScanner.regions(text: text, lineIndex: lineIndex, language: language)
            for _ in 0..<40 {
                let first = 1 + Int(rng.next() % UInt64(lineIndex.lineCount))
                let lines = first...(first + 63)
                let budget = 50 + Int(rng.next() % 4_000)
                let window = FoldScanner.window(in: text as NSString, lineIndex: lineIndex,
                                                language: language, lines: lines, budget: budget)
                for line in window.lines {
                    guard window.isResolved(line) else { sawUnresolved = true; continue }
                    #expect(window.regions.filter { $0.startLine == line } == full.filter { $0.startLine == line },
                            "line \(line) budget \(budget) language=\(language)")
                }
            }
        }
        #expect(sawUnresolved)
    }

    @Test func farMatchingOpenerStaysUnresolvedUnderBudget() {
        let text = "(function () {\n" + String(repeating: "  call();\n", count: 50_000) + "})();\n"
        let lineIndex = LineIndex(text: text)
        let window = FoldScanner.window(in: text as NSString, lineIndex: lineIndex,
                                        lines: 1...128, budget: 10_000)
        #expect(!window.isResolved(1))
        #expect(window.isResolved(2))
        let ample = FoldScanner.window(in: text as NSString, lineIndex: lineIndex, lines: 1...128, budget: .max)
        #expect(ample.regions == [FoldRegion(startLine: 1, endLine: 50_001)])
    }
}

// MARK: - Controller: off the draw path, versioned publishing

@MainActor
private final class ScanRig {
    let textView = NSTextView()
    let lineIndex: LineIndex
    let scheduler = AnalysisScheduler()
    let folding: FoldingController

    init(_ text: String) {
        textView.string = text
        lineIndex = LineIndex(text: text)
        folding = FoldingController(textView: textView, lineIndex: lineIndex, scheduler: scheduler)
        textView.layoutManager?.delegate = folding
    }

    var text: String { textView.string }

    func edit(replace range: NSRange, with replacement: String) {
        let storage = textView.textStorage!
        let delta = (replacement as NSString).length - range.length
        storage.replaceCharacters(in: range, with: replacement)
        let edited = NSRange(location: range.location, length: (replacement as NSString).length)
        lineIndex.update(text: storage.string, editedRange: edited, changeInLength: delta)
        folding.textStorageDidProcessEditing(editedMask: .editedCharacters, editedRange: edited,
                                             changeInLength: delta, textStorage: storage)
    }

    func waitForPublish(timeout: TimeInterval = 30) async {
        let end = Date().addingTimeInterval(timeout)
        while folding.publishedRegions == nil, Date() < end {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

@MainActor
struct FoldingControllerScanTests {
    private static func bigPython() throws -> String {
        repeated(try fixture("Tests/Fixtures/M17/inference/sample_1000.py"), targetBytes: 2 << 20)
    }

    /// The gutter's first query neither scans the document nor blocks: it
    /// answers from a window, schedules the sliced scan, and the markers it
    /// shows equal the full scan's.
    @Test func firstQueryAnswersFromAWindowAndSchedulesTheScan() async throws {
        let rig = ScanRig(try Self.bigPython())
        let full = FoldScanner.regions(text: rig.text, lineIndex: rig.lineIndex)
        for line in 1...300 {
            let expected: FoldArrow = full.contains { $0.startLine == line } ? .foldable : .none
            #expect(rig.folding.foldState(atLine: line) == expected, "line \(line)")
        }
        #expect(rig.folding.publishedRegions == nil, "the draw path must not run the full scan")
        await rig.waitForPublish()
        #expect(rig.folding.publishedRegions == full)
        #expect(rig.scheduler.sliceCount > 1, "a 2 MB scan should take more than one slice")
    }

    /// Edits while the sliced scan is in flight: the stale scan is never
    /// published, and the scan that is published describes the edited text.
    @Test func editsDuringASlicedScanPublishOnlyTheCurrentText() async throws {
        let rig = ScanRig(try Self.bigPython())
        var slicesBeforeEdit = 0
        var windowsMatched = false
        rig.folding.scanSliceObserver = { [unowned rig] in
            slicesBeforeEdit += 1
            rig.folding.scanSliceObserver = nil
            #expect(rig.folding.publishedRegions == nil, "a 2 MB scan does not fit in one slice")
            // Mid-scan (from inside the running job): break the first block's
            // header, and add a block at the end.
            let firstColon = (rig.text as NSString).range(of: ":\n")
            rig.edit(replace: firstColon, with: "\n")
            let length = (rig.text as NSString).length
            rig.edit(replace: NSRange(location: length, length: 0), with: "\nclass Tail:\n    x = 1\n")
            #expect(rig.folding.publishedRegions == nil)
            // While the rescan is pending, windows answer for the new text.
            let expected = FoldScanner.regions(text: rig.text, lineIndex: LineIndex(text: rig.text))
            windowsMatched = (1...200).allSatisfy { line in
                let arrow: FoldArrow = expected.contains { $0.startLine == line } ? .foldable : .none
                return rig.folding.foldState(atLine: line) == arrow
            }
        }
        _ = rig.folding.foldState(atLine: 1) // schedules the scan
        await rig.waitForPublish()
        #expect(slicesBeforeEdit == 1)
        #expect(windowsMatched)
        let expected = FoldScanner.regions(text: rig.text, lineIndex: LineIndex(text: rig.text))
        #expect(rig.folding.publishedRegions == expected)
        let tail = rig.lineIndex.lineCount - 2
        #expect(rig.folding.foldState(atLine: tail) == .foldable)
    }

    /// Fold-all during an in-flight scan finishes it synchronously, and the
    /// queued job then completes without republishing anything stale.
    @Test func foldAllFinishesAnInFlightScan() async throws {
        let rig = ScanRig(try Self.bigPython())
        _ = rig.folding.foldState(atLine: 1)
        rig.folding.foldAll()
        let full = FoldScanner.regions(text: rig.text, lineIndex: rig.lineIndex)
        #expect(rig.folding.publishedRegions == full)
        #expect(rig.folding.foldedHeaderLines().count == Set(full.map(\.startLine)).count)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(rig.folding.publishedRegions == full)
    }

    /// Toggling a header resolved by a window works before the scan lands,
    /// and the fold survives validation when the scan is published.
    @Test func toggleBeforeThePublishSurvivesValidation() async throws {
        let rig = ScanRig("def f():\n    a = 1\n    b = 2\n\nx = 3\n")
        #expect(rig.folding.foldState(atLine: 1) == .foldable)
        rig.folding.toggleFold(atLine: 1)
        #expect(rig.folding.foldState(atLine: 1) == .folded)
        await rig.waitForPublish()
        #expect(rig.folding.foldedHeaderLines() == [1])
        #expect(rig.folding.hiddenLineCount(forHeader: 1) == 2)
    }

    /// A language switch drops the published regions and rescans with the
    /// new rule set.
    @Test func languageChangeRescans() async {
        let text = "# A\n\nbody:\n  x\n"
        let rig = ScanRig(text)
        var language = ""
        rig.folding.languageProvider = { language }
        rig.folding.foldAll()
        #expect(rig.folding.publishedRegions == [FoldRegion(startLine: 3, endLine: 4)])
        language = "markdown"
        rig.folding.noteLanguageChanged()
        #expect(rig.folding.publishedRegions == nil)
        await rig.waitForPublish()
        #expect(rig.folding.publishedRegions == [FoldRegion(startLine: 1, endLine: 4)])
    }
}
