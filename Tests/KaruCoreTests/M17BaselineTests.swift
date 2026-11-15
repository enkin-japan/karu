import AppKit
import Foundation
import Testing
@testable import KaruCore

// M17 T17.0 baseline capture (docs/HIGHLIGHT-AND-COMPLETION-PLAN.md §12–13).
//
// Opt-in: the whole suite runs only with `KARU_M17_BASELINE` set, e.g.
//
//     KARU_M17_BASELINE=1 swift test --filter M17Baseline
//
// It records the *current* behaviour; it asserts only fixture integrity, not
// quality targets. Outputs:
//   - Tests/Fixtures/M17/baseline/karu/<highlight sample>.colors.tsv
//   - with `KARU_M17_LIGHT=1` (T17.7) the highlight dump renders under the
//     light appearance (Light Modern) into `baseline/karu-light_modern/`
//     instead (not committed; compare with `vscode-light_modern/`)
//   - Tests/Fixtures/M17/baseline/completion-baseline.tsv
//   - Tests/Fixtures/M17/baseline/completion-summary.md
//   - .build/m17-baseline/probes.txt (machine-dependent timings; not committed)
//   - with `KARU_M17_OUT=<absolute dir>` (T17.15b) the colour dumps and the
//     completion TSV / summary go to that directory instead, leaving the
//     frozen T17.0 files under `baseline/` untouched (quality report runs)
//
// Language choice for the highlight dump: by file extension through
// `LanguageRegistry` (the app's own path); since T17.8b that includes `.jsx`
// (`javascript`) and `.tsx` (`typescriptreact`).

// MARK: - Paths

private enum M17Paths {
    /// Repository root, derived from this file's location.
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // KaruCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root
    static let fixtures = root.appendingPathComponent("Tests/Fixtures/M17", isDirectory: true)
    static let highlight = fixtures.appendingPathComponent("highlight", isDirectory: true)
    static let completion = fixtures.appendingPathComponent("completion", isDirectory: true)
    static let inference = fixtures.appendingPathComponent("inference", isDirectory: true)
    static let baseline = fixtures.appendingPathComponent("baseline", isDirectory: true)
    static let probes = root.appendingPathComponent(".build/m17-baseline", isDirectory: true)
    /// Where the dumps are written: `KARU_M17_OUT` when set (T17.15b), else `baseline`.
    static let output: URL = {
        if let path = ProcessInfo.processInfo.environment["KARU_M17_OUT"], path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return baseline
    }()
}

private let baselineEnabled = ProcessInfo.processInfo.environment["KARU_M17_BASELINE"] != nil
/// T17.7: dump the highlight colours under the light appearance.
private let baselineLight = ProcessInfo.processInfo.environment["KARU_M17_LIGHT"] == "1"

// MARK: - Shared helpers

private func m17Defaults() -> UserDefaults {
    let name = "M17BaselineTests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

/// Scroll view + text view configured like `EditorWindowController.makeEditorView`.
@MainActor
private func makeEditorLikeView(frame: NSRect) -> (NSScrollView, EditorTextView) {
    let scrollView = NSScrollView(frame: frame)
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    let textView = EditorTextView(frame: NSRect(origin: .zero, size: frame.size))
    textView.isRichText = false
    textView.allowsUndo = true
    textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticSpellingCorrectionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.autoresizingMask = [.width]
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.textContainer?.widthTracksTextView = true
    textView.textContainerInset = NSSize(width: 6, height: 8)
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineHeightMultiple = 1.15
    textView.defaultParagraphStyle = paragraph
    textView.typingAttributes[.paragraphStyle] = paragraph
    scrollView.documentView = textView
    return (scrollView, textView)
}

@MainActor
private func makeWindow(contentSize: NSSize, content: NSView,
                        appearance: NSAppearance.Name = .darkAqua) -> NSWindow {
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: contentSize),
                          styleMask: [.titled, .resizable, .closable],
                          backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: appearance)
    window.contentView = content
    return window
}

/// Resolves `color` under an appearance (darkAqua by default) in sRGB as
/// lowercase `#rrggbb`.
@MainActor
private final class DarkHexResolver {
    private var cache: [ObjectIdentifier: String] = [:]
    private let dark: NSAppearance

    init(appearance: NSAppearance.Name = .darkAqua) {
        dark = NSAppearance(named: appearance)!
    }

    func hex(_ color: NSColor) -> String {
        let key = ObjectIdentifier(color)
        if let hit = cache[key] { return hit }
        var resolved: NSColor?
        dark.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB)
        }
        let c = resolved ?? color
        func byte(_ v: CGFloat) -> Int { max(0, min(255, Int((v * 255).rounded()))) }
        let out = String(format: "#%02x%02x%02x",
                         byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
        cache[key] = out
        return out
    }
}

/// Maximal runs of foreground temporary attributes over the whole document, as
/// (location, length, hex). Uncoloured spans are omitted.
@MainActor
private func foregroundRuns(_ layoutManager: NSLayoutManager, length: Int,
                            resolver: DarkHexResolver) -> [(Int, Int, String)] {
    var runs: [(Int, Int, String)] = []
    var index = 0
    let full = NSRange(location: 0, length: length)
    while index < length {
        var effective = NSRange(location: 0, length: 0)
        let value = layoutManager.temporaryAttribute(.foregroundColor, atCharacterIndex: index,
                                                     longestEffectiveRange: &effective, in: full)
        let end = max(effective.location + effective.length, index + 1)
        if let color = value as? NSColor {
            let hex = resolver.hex(color)
            if let last = runs.last, last.2 == hex, last.0 + last.1 == index {
                runs[runs.count - 1].1 += end - index
            } else {
                runs.append((index, end - index, hex))
            }
        }
        index = end
    }
    return runs
}

/// Run count and covered characters of foreground temporary attributes (raw
/// attribute runs, not merged by colour) — the probe's accumulation measure.
@MainActor
private func foregroundCoverage(_ layoutManager: NSLayoutManager, length: Int) -> (runs: Int, chars: Int) {
    var runs = 0, chars = 0, index = 0
    let full = NSRange(location: 0, length: length)
    while index < length {
        var effective = NSRange(location: 0, length: 0)
        let value = layoutManager.temporaryAttribute(.foregroundColor, atCharacterIndex: index,
                                                     longestEffectiveRange: &effective, in: full)
        let end = max(effective.location + effective.length, index + 1)
        if value != nil {
            runs += 1
            chars += end - index
        }
        index = end
    }
    return (runs, chars)
}

private func readText(_ url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
}

private func ms(_ d: Duration) -> Double {
    let c = d.components
    return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
}

private func fmt(_ v: Double, _ digits: Int = 2) -> String { String(format: "%.\(digits)f", v) }

// MARK: - Completion fixtures

private struct CompletionCase: Decodable {
    let id: String
    let file: String
    let language: String
    let caret: Int
    let typed: String
    let kind: String
    let category: String
    let expectTop1: String?
    let expectTop3: [String]?
    let expectInTop10: [String]?
    let forbidden: [String]
    /// Names that may appear only as plain document words, below every
    /// code-sourced candidate (e.g. a `def` written inside a comment).
    let docWordOnly: [String]?
    let expectNoPopup: Bool
    let holdout: Bool
    let note: String

    /// Every name the case expects to be offered somewhere.
    var expectedNames: [String] {
        var out: [String] = []
        for name in [expectTop1].compactMap({ $0 }) + (expectTop3 ?? []) + (expectInTop10 ?? [])
        where !out.contains(name) { out.append(name) }
        return out
    }
}

/// A caret-marked source: markers `⟨n⟩` removed, their UTF-16 offsets recorded.
private struct MarkedSource {
    let text: String
    let carets: [Int: Int]
    let duplicateMarkers: [Int]

    // swiftlint:disable:next force_try
    private static let marker = try! NSRegularExpression(pattern: "\u{27E8}(\\d+)\u{27E9}")

    init(raw: String) {
        let ns = raw as NSString
        var out = ""
        var carets: [Int: Int] = [:]
        var duplicates: [Int] = []
        var cursor = 0
        var removed = 0
        for match in Self.marker.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let number = Int(ns.substring(with: match.range(at: 1)))!
            if carets[number] != nil { duplicates.append(number) }
            carets[number] = match.range.location - removed
            removed += match.range.length
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        self.text = out
        self.carets = carets
        self.duplicateMarkers = duplicates
    }
}

private func loadCases() throws -> [CompletionCase] {
    let data = try Data(contentsOf: M17Paths.completion.appendingPathComponent("cases.json"))
    return try JSONDecoder().decode([CompletionCase].self, from: data)
}

private struct CaseResult {
    let c: CompletionCase
    let list: [String]
    var shown: Bool { !list.isEmpty }
    var top1Rank: Int? { c.expectTop1.flatMap { name in list.firstIndex(of: name).map { $0 + 1 } } }
    var top3All: Bool? { c.expectTop3.map { names in names.allSatisfy { list.prefix(3).contains($0) } } }
    var top10Found: Int? { c.expectInTop10.map { names in names.filter { list.prefix(10).contains($0) }.count } }
    var forbiddenHits: [String] { c.forbidden.filter { list.contains($0) } }
    var missingFromTop50: [String] { c.expectedNames.filter { !list.prefix(50).contains($0) } }
}

/// Drives one case through a real `CompletionController`, the way the editor does
/// (edits are delivered through a `TextStorageObserverHub`, as in the window).
@MainActor
private func runCompletionCase(_ c: CompletionCase) throws -> [String] {
    let source = MarkedSource(raw: try readText(M17Paths.fixtures.appendingPathComponent(c.file)))
    guard let caret = source.carets[c.caret] else { return [] }

    let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
    let (scrollView, textView) = makeEditorLikeView(frame: frame)
    let window = makeWindow(contentSize: frame.size, content: scrollView)
    defer { window.close() }
    textView.string = source.text
    window.makeFirstResponder(textView)

    let center = NotificationCenter()
    let settings = ModuleSettings(defaults: m17Defaults(), center: center)
    let controller = CompletionController(textView: textView, moduleSettings: settings, moduleCenter: center)
    textView.completionKeyHandler = controller
    // Edits reach the controller (and its analysis) as in the editor window
    // (T17.5: the analysis journals them to map snapshot offsets).
    let hub = TextStorageObserverHub()
    hub.add(controller)
    textView.textStorage?.delegate = hub
    defer {
        textView.textStorage?.delegate = nil
        withExtendedLifetime(hub) {}
    }
    // Same wiring as EditorWindowController.load: language, then a full index.
    controller.setLanguage(identifier: c.language == "plaintext" ? nil : c.language)
    controller.indexDocument()
    defer { controller.dismissCompletion() }

    textView.setSelectedRange(NSRange(location: caret, length: 0))
    var list: [String] = []
    for ch in c.typed {
        let key = String(ch)
        // The NSTextInputClient path interpretKeyEvents uses for a plain key.
        textView.insertText(key, replacementRange: NSRange(location: NSNotFound, length: 0))
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil,
                                     characters: key, charactersIgnoringModifiers: key,
                                     isARepeat: false, keyCode: 0)!
        controller.textViewDidInsertKey(event)
        list = controller.currentSuggestionsForTesting
    }
    return list
}

// MARK: - Suite

@Suite("M17Baseline", .enabled(if: baselineEnabled), .serialized)
@MainActor
struct M17BaselineTests {

    // MARK: Fixture integrity

    @Test func completionManifestIsValid() throws {
        let cases = try loadCases()
        #expect(Set(cases.map(\.id)).count == cases.count, "duplicate case ids")
        for c in cases {
            let url = M17Paths.fixtures.appendingPathComponent(c.file)
            #expect(FileManager.default.fileExists(atPath: url.path), "\(c.id): missing \(c.file)")
            guard let raw = try? readText(url) else { continue }
            let source = MarkedSource(raw: raw)
            #expect(source.duplicateMarkers.isEmpty, "\(c.id): duplicate markers \(source.duplicateMarkers)")
            #expect(source.carets[c.caret] != nil, "\(c.id): caret ⟨\(c.caret)⟩ not in \(c.file)")
            #expect(!c.typed.isEmpty, "\(c.id): empty typed")
            #expect(["scope", "member"].contains(c.kind), "\(c.id): kind \(c.kind)")
            if c.expectNoPopup {
                #expect(c.expectedNames.isEmpty, "\(c.id): no-popup case lists expectations")
            } else {
                #expect(!c.expectedNames.isEmpty, "\(c.id): no expectation")
            }
            if c.kind == "member" { #expect(c.typed.hasPrefix("."), "\(c.id): member typed must start with .") }
        }

        let scope = cases.filter { $0.kind == "scope" }
        let member = cases.filter { $0.kind == "member" && $0.category != "explicitDecl" }
        let explicit = cases.filter { $0.category == "explicitDecl" }
        func lang(_ set: [CompletionCase], _ ids: Set<String>) -> Int { set.filter { ids.contains($0.language) }.count }
        #expect(scope.count >= 40)
        #expect(lang(scope, ["python"]) >= 14)
        #expect(lang(scope, ["javascript", "typescript"]) >= 14)
        #expect(lang(scope, ["typescript"]) >= 4)
        #expect(lang(scope, ["plaintext"]) >= 4)
        #expect(scope.filter { $0.category == "negative" }.count >= 6)
        #expect(member.count >= 40)
        #expect(lang(member, ["python"]) >= 20)
        #expect(lang(member, ["javascript", "typescript"]) >= 20)
        #expect(explicit.count >= 10)
        #expect(Set(explicit.map(\.language)) == ["swift", "go", "rust", "java", "csharp", "c", "cpp"])
        let holdoutShare = Double(cases.filter(\.holdout).count) / Double(cases.count)
        #expect(holdoutShare >= 0.2 && holdoutShare <= 0.35, "holdout share \(holdoutShare)")
        for set in [scope, member + explicit] {
            #expect(Set(set.filter(\.holdout).map(\.category)).count >= 5, "holdout not spread across categories")
        }
    }

    @Test func highlightSamplesCoverAllLanguages() throws {
        let files = try highlightSampleFiles()
        let languages = Set(files.compactMap { try? highlightLanguage(for: $0.url) })
        #expect(languages == ["bash", "c", "cpp", "csharp", "css", "go", "html", "java", "javascript",
                              "json", "jsonl", "markdown", "python", "rust", "sql", "swift", "toml",
                              "typescript", "typescriptreact", "xml", "yaml"])
        for file in files {
            let lines = try readText(file.url).components(separatedBy: "\n").count
            #expect(lines <= 201, "\(file.relative) has \(lines) lines")
        }
    }

    // MARK: (a) Highlight dump

    private struct SampleFile { let url: URL; let relative: String }

    private func highlightSampleFiles() throws -> [SampleFile] {
        let base = M17Paths.highlight.standardizedFileURL.path + "/"
        guard let walker = FileManager.default.enumerator(at: M17Paths.highlight,
                                                          includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var out: [SampleFile] = []
        for case let url as URL in walker {
            guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true,
                  !url.lastPathComponent.hasPrefix(".") else { continue }
            let path = url.standardizedFileURL.path
            out.append(SampleFile(url: url, relative: String(path.dropFirst(base.count))))
        }
        return out.sorted { $0.relative < $1.relative }
    }

    /// Identifier the dump uses for `url` (see the header comment).
    private func highlightLanguage(for url: URL) throws -> String {
        let ext = url.pathExtension.lowercased()
        guard let def = LanguageRegistry.definition(forExtension: ext) else {
            throw CocoaError(.fileReadUnsupportedScheme, userInfo: [NSFilePathErrorKey: url.path])
        }
        return def.identifier
    }

    @Test func dumpHighlightColours() throws {
        let files = try highlightSampleFiles()
        #expect(files.count >= 24)
        let appearance: NSAppearance.Name = baselineLight ? .aqua : .darkAqua
        let outDirectory = baselineLight ? "karu-light_modern" : "karu"
        let resolver = DarkHexResolver(appearance: appearance)
        for file in files {
            let text = try readText(file.url)
            let length = (text as NSString).length
            let ext = file.url.pathExtension.lowercased()

            let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
            let (scrollView, textView) = makeEditorLikeView(frame: frame)
            let window = makeWindow(contentSize: frame.size, content: scrollView, appearance: appearance)
            defer { window.close() }
            textView.string = text
            let layoutManager = textView.layoutManager!
            layoutManager.ensureLayout(for: textView.textContainer!)
            // Tall enough that the viewport alone spans the whole sample, so the
            // engine's normal viewport path paints every line.
            let used = layoutManager.usedRect(for: textView.textContainer!).height
            window.setContentSize(NSSize(width: 800, height: max(600, used + 200)))
            layoutManager.ensureLayout(for: textView.textContainer!)

            let center = NotificationCenter()
            let engine = HighlightEngine(textView: textView, scrollView: scrollView,
                                         moduleSettings: ModuleSettings(defaults: m17Defaults(), center: center),
                                         moduleCenter: center)
            if LanguageRegistry.definition(forExtension: ext) != nil {
                engine.setLanguage(fileExtension: ext)
            } else {
                engine.setLanguage(identifier: try highlightLanguage(for: file.url))
            }
            engine.appearanceDidChange()   // invalidate + repaint synchronously
            #expect(engine.paintedRange == NSRange(location: 0, length: length),
                    "\(file.relative): painted \(String(describing: engine.paintedRange)) of \(length)")

            let runs = foregroundRuns(layoutManager, length: length, resolver: resolver)
            let tsv = runs.map { "\($0.0)\t\($0.1)\t\($0.2)\n" }.joined()
            let out = M17Paths.output.appendingPathComponent("\(outDirectory)/\(file.relative).colors.tsv")
            try FileManager.default.createDirectory(at: out.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try tsv.write(to: out, atomically: true, encoding: .utf8)
            #expect(!runs.isEmpty || ext == "txt", "\(file.relative): nothing coloured")
        }
    }

    // MARK: (b) Completion ranks

    @Test func captureCompletionRanks() throws {
        let cases = try loadCases()
        var results: [CaseResult] = []
        for c in cases {
            results.append(CaseResult(c: c, list: try runCompletionCase(c)))
        }

        var tsv = "id\tkind\tcategory\tholdout\tpopupShown\ttop1Rank\ttop3All\ttop10Found\tforbiddenHits\tfirst10\n"
        for r in results {
            let top10 = r.top10Found.map { "\($0)/\(r.c.expectInTop10!.count)" } ?? "-"
            let top3 = r.top3All.map { $0 ? "yes" : "no" } ?? "-"
            let row: [String] = [
                r.c.id, r.c.kind, r.c.category, r.c.holdout ? "1" : "0", r.shown ? "1" : "0",
                r.top1Rank.map(String.init) ?? "-", top3, top10,
                r.forbiddenHits.isEmpty ? "-" : r.forbiddenHits.joined(separator: ","),
                r.list.prefix(10).joined(separator: "|"),
            ]
            tsv += row.joined(separator: "\t") + "\n"
        }
        try FileManager.default.createDirectory(at: M17Paths.output, withIntermediateDirectories: true)
        try tsv.write(to: M17Paths.output.appendingPathComponent("completion-baseline.tsv"),
                      atomically: true, encoding: .utf8)
        try completionSummary(results).write(to: M17Paths.output.appendingPathComponent("completion-summary.md"),
                                             atomically: true, encoding: .utf8)
        #expect(results.count == cases.count)
    }

    private func completionSummary(_ results: [CaseResult]) -> String {
        func row(_ label: String, _ rs: [CaseResult]) -> String {
            let withTop1 = rs.filter { $0.c.expectTop1 != nil }
            let withTop3 = rs.filter { $0.c.expectTop3 != nil }
            let withTop10 = rs.filter { $0.c.expectInTop10 != nil }
            let noPopup = rs.filter(\.c.expectNoPopup)
            let expected = rs.reduce(0) { $0 + $1.c.expectedNames.count }
            let missing = rs.reduce(0) { $0 + $1.missingFromTop50.count }
            let top10Total = withTop10.reduce(0) { $0 + $1.c.expectInTop10!.count }
            let top10Found = withTop10.reduce(0) { $0 + ($1.top10Found ?? 0) }
            let cells = [
                label, "\(rs.count)",
                "\(withTop1.filter { $0.top1Rank == 1 }.count)/\(withTop1.count)",
                "\(withTop3.filter { $0.top3All == true }.count)/\(withTop3.count)",
                top10Total == 0 ? "-" : "\(top10Found)/\(top10Total)",
                "\(missing)/\(expected)",
                "\(noPopup.filter(\.shown).count)/\(noPopup.count)",
                "\(rs.filter { !$0.forbiddenHits.isEmpty }.count)",
                "\(rs.filter(\.shown).count)",
            ]
            return "| " + cells.joined(separator: " | ") + " |\n"
        }
        let header = "| group | N | top1 hits | top3 hits | in-top10 found | missing from top 50 (names) | false popups | forbidden-hit cases | popup shown |\n"
            + "|---|---|---|---|---|---|---|---|---|\n"

        func table(_ rs: [CaseResult]) -> String {
            var out = header
            for kind in ["scope", "member"] {
                let ofKind = rs.filter { $0.c.kind == kind }
                guard !ofKind.isEmpty else { continue }
                let categories = Array(Set(ofKind.map(\.c.category))).sorted()
                for category in categories {
                    out += row("\(kind) / \(category)", ofKind.filter { $0.c.category == category })
                }
                out += row("**\(kind) total**", ofKind)
            }
            out += row("**all**", rs)
            return out
        }

        var md = "# M17 completion baseline (current Karu)\n\n"
        md += "Generated by `KARU_M17_BASELINE=1 swift test --filter M17Baseline` from "
        md += "`Tests/Fixtures/M17/completion/cases.json` (\(results.count) cases). "
        md += "Each case types `typed` keystroke by keystroke through `insertText` + "
        md += "`CompletionController.textViewDidInsertKey`, after a full `indexDocument()` at load "
        md += "(no debounce rebuild in between, i.e. fast typing; since T17.5 the edits reach the controller "
        md += "through a `TextStorageObserverHub` as in the editor window); the list is the popup content after "
        md += "the last keystroke (empty = no popup).\n\n"
        md += "Columns: top1 hits = cases whose `expectTop1` ranks first / cases with `expectTop1`; "
        md += "top3 hits = cases with every `expectTop3` name in the first three / cases with `expectTop3`; "
        md += "in-top10 found = `expectInTop10` names in the first ten / names listed; missing = expected "
        md += "names (top1 ∪ top3 ∪ top10) absent from the whole list (≤ 50) / expected names; false popups = "
        md += "`expectNoPopup` cases that showed a popup / such cases; forbidden-hit cases = cases listing "
        md += "any `forbidden` name anywhere.\n\n"
        md += "## Tuning set (holdout = false)\n\n" + table(results.filter { !$0.c.holdout })
        md += "\n## Holdout set (holdout = true)\n\n" + table(results.filter(\.c.holdout))
        md += "\n## All cases\n\n" + table(results)
        return md
    }

    // MARK: (c) Probes

    /// ~10 MB of Python built from `sample_1000.py` copies, every identifier
    /// (except keywords / builtins / string prefixes) suffixed with the copy number.
    private static var distinctPython: String?

    private func distinctPythonDocument() throws -> String {
        if let cached = Self.distinctPython { return cached }
        let sample = try readText(M17Paths.inference.appendingPathComponent("sample_1000.py"))
        let def = LanguageRegistry.definition(forIdentifier: "python")!
        let reserved = Set(def.keywords + def.builtins + ["self", "cls", "__future__", "annotations"])
        let regex = try NSRegularExpression(pattern: #"(?<![0-9A-Za-z_])[A-Za-z_][A-Za-z0-9_]*(?!['"])"#)
        let ns = sample as NSString
        let matches = regex.matches(in: sample, range: NSRange(location: 0, length: ns.length))
        // Split once into (literal, identifier?) pieces so each copy is a cheap join.
        var pieces: [(String, Bool)] = []
        var cursor = 0
        for m in matches {
            pieces.append((ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)), false))
            let word = ns.substring(with: m.range)
            pieces.append((word, !reserved.contains(word)))
            cursor = m.range.location + m.range.length
        }
        pieces.append((ns.substring(from: cursor), false))

        let target = 10 * 1024 * 1024
        var out = ""
        out.reserveCapacity(target + 64 * 1024)
        var copy = 0
        while out.utf8.count < target {
            copy += 1
            let suffix = "_\(copy)"
            for (text, rename) in pieces {
                out += text
                if rename { out += suffix }
            }
            if !out.hasSuffix("\n") { out += "\n" }
        }
        Self.distinctPython = out
        return out
    }

    /// The repeated-name block `scripts/mem-benchmark.sh` writes into large.py.
    private func repeatedPythonDocument() -> String {
        let block = """
        def sample_function(a, b, c):
            \"\"\"Auto-generated function for Karu memory benchmark.\"\"\"
            result = a + b + c
            for i in range(10):
                result += i
            return result

        """
        let target = 10 * 1024 * 1024
        var out = String(repeating: block, count: target / block.utf8.count + 1)
        out = String(out.utf8.prefix(target))!
        return out
    }

    @Test func probes() async throws {
        var report = "# M17 T17.0 probes — \(Date())\n"
        report += "# debug build under `swift test`; timings are wall-clock on this machine\n"
        report += "# host: \(ProcessInfo.processInfo.operatingSystemVersionString), "
        report += "\(ProcessInfo.processInfo.activeProcessorCount) cores\n\n"

        let distinct = try distinctPythonDocument()
        report += try await probeOffscreenAccumulation(distinct)
        report += try probeLongLine()
        report += try probeDeclarationScan(distinct)
        report += try probeHotQuery(distinct)

        try FileManager.default.createDirectory(at: M17Paths.probes, withIntermediateDirectories: true)
        try report.write(to: M17Paths.probes.appendingPathComponent("probes.txt"), atomically: true, encoding: .utf8)
        print(report)
    }

    /// (1) Scroll a 10 MB Python document top → bottom in viewport-height steps
    /// through the engine's normal bounds-change path; count foreground runs.
    private func probeOffscreenAccumulation(_ text: String) async throws -> String {
        let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let (scrollView, textView) = makeEditorLikeView(frame: frame)
        let window = makeWindow(contentSize: frame.size, content: scrollView)
        defer { window.close() }
        let layoutManager = textView.layoutManager!
        layoutManager.allowsNonContiguousLayout = true   // LayoutModeController: ≥ 512 KB
        textView.string = text
        let length = (text as NSString).length

        let center = NotificationCenter()
        let engine = HighlightEngine(textView: textView, scrollView: scrollView,
                                     moduleSettings: ModuleSettings(defaults: m17Defaults(), center: center),
                                     moduleCenter: center)
        engine.setLanguage(fileExtension: "py")
        let before = foregroundCoverage(layoutManager, length: length)

        let clip = scrollView.contentView
        var steps = 0
        var passes = 0
        var stalls = 0
        var lastPainted = engine.paintedRange
        var bands: [NSRange] = lastPainted.map { [$0] } ?? []
        let clock = ContinuousClock()
        let started = clock.now
        while steps < 100_000 {
            let maxY = textView.frame.height - clip.bounds.height
            if clip.bounds.minY >= maxY - 0.5 {
                // Noncontiguous layout estimates the height; it grows as later
                // text is laid out. Stop once the painted band reaches the end
                // or the height stops growing.
                if (engine.paintedRange.map { $0.location + $0.length } ?? 0) >= length { break }
                stalls += 1
                if stalls > 3 { break }
                layoutManager.ensureLayout(forCharacterRange: NSRange(location: max(0, length - 1), length: 1))
                await Task.yield()
                continue
            }
            stalls = 0
            clip.scroll(to: NSPoint(x: 0, y: min(clip.bounds.minY + clip.bounds.height, maxY)))
            scrollView.reflectScrolledClipView(clip)
            // The engine handles bounds changes with a DispatchQueue.main.async
            // item; this test is itself a main-actor job, so suspend to let it run.
            await Task.yield()
            steps += 1
            if engine.paintedRange != lastPainted {
                passes += 1
                lastPainted = engine.paintedRange
                if let band = lastPainted { bands.append(band) }
            }
        }
        let elapsed = clock.now - started
        // Union of every band the engine painted on the way down.
        var unionChars = 0
        var unionEnd = 0
        for band in bands.sorted(by: { $0.location < $1.location }) {
            let start = max(band.location, unionEnd)
            let end = band.location + band.length
            if end > start { unionChars += end - start }
            unionEnd = max(unionEnd, end)
        }
        let after = foregroundCoverage(layoutManager, length: length)
        let reachedEnd = (engine.paintedRange.map { $0.location + $0.length } ?? 0) == length

        var r = "## (1) Off-screen attribute accumulation\n"
        r += "doc: distinct-name Python, \(length) UTF-16 units, viewport 800×600, noncontiguous layout\n"
        r += "scroll: \(steps) viewport-height steps, \(passes) repaint passes, \(fmt(ms(elapsed) / 1000, 1)) s total, reached end: \(reachedEnd)\n"
        r += "union of painted bands: \(unionChars) chars (\(fmt(Double(unionChars) / Double(length) * 100)) % of doc)\n"
        r += "before (top painted): \(before.runs) foreground runs, \(before.chars) chars covered (\(fmt(Double(before.chars) / Double(length) * 100)) % of doc)\n"
        r += "after  (scrolled to bottom): \(after.runs) foreground runs, \(after.chars) chars covered (\(fmt(Double(after.chars) / Double(length) * 100)) % of doc)\n\n"
        return r
    }

    /// (2) One highlight pass at the top of a 5 MB single-line minified JSON array.
    private func probeLongLine() throws -> String {
        var json = "["
        var i = 0
        while json.utf8.count < 5 * 1024 * 1024 {
            if i > 0 { json += "," }
            json += #"{"id":\#(i),"name":"item-\#(i)","tags":["a","b"],"price":\#(i % 97).5,"ok":true,"note":null}"#
            i += 1
        }
        json += "]"
        let length = (json as NSString).length

        let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let (scrollView, textView) = makeEditorLikeView(frame: frame)
        let window = makeWindow(contentSize: frame.size, content: scrollView)
        defer { window.close() }
        let layoutManager = textView.layoutManager!
        layoutManager.allowsNonContiguousLayout = true
        textView.string = json

        let center = NotificationCenter()
        let engine = HighlightEngine(textView: textView, scrollView: scrollView,
                                     moduleSettings: ModuleSettings(defaults: m17Defaults(), center: center),
                                     moduleCenter: center)
        let clock = ContinuousClock()
        let cold = clock.measure { engine.setLanguage(fileExtension: "json") }
        let afterCold = foregroundCoverage(layoutManager, length: length)
        let warm = clock.measure { engine.appearanceDidChange() }
        let afterWarm = foregroundCoverage(layoutManager, length: length)

        var r = "## (2) Long line\n"
        r += "doc: single-line minified JSON array, \(length) UTF-16 units, \(i) objects, viewport 800×600\n"
        r += "first pass (setLanguage: clear + layout + paint): \(fmt(ms(cold))) ms main-thread wall\n"
        r += "second pass (appearanceDidChange repaint): \(fmt(ms(warm))) ms main-thread wall\n"
        r += "painted band: \(engine.paintedRange.map { "\($0.location)+\($0.length)" } ?? "nil")\n"
        r += "runs painted: \(afterCold.runs) after first pass (\(afterCold.chars) chars), \(afterWarm.runs) after second (\(afterWarm.chars) chars)\n\n"
        return r
    }

    /// (3) Declaration / word scan cost on distinct names vs the repeated block.
    private func probeDeclarationScan(_ distinct: String) throws -> String {
        let repeated = repeatedPythonDocument()
        let clock = ContinuousClock()
        var r = "## (3) Declaration scan cost (Python, ~10 MB)\n"
        r += "doc\tUTF-16 units\tWordIndex(text:) ms\tsymbols(text:) ms\tscanSymbolLocations ms\twords\tsymbols\tlocations\n"
        for (name, text) in [("distinct", distinct), ("repeated (mem-benchmark block)", repeated)] {
            var index: WordIndex?
            var symbols: Set<String> = []
            var locations: [WordIndex.SymbolLocation] = []
            let tIndex = clock.measure { index = WordIndex(text: text) }
            let tSymbols = clock.measure { symbols = WordIndex.symbols(text: text, languageIdentifier: "python") }
            let tScan = clock.measure { locations = WordIndex.scanSymbolLocations(text: text, languageIdentifier: "python") }
            r += "\(name)\t\((text as NSString).length)\t\(fmt(ms(tIndex)))\t\(fmt(ms(tSymbols)))\t\(fmt(ms(tScan)))\t"
            r += "\(index?.words.count ?? 0)\t\(symbols.count)\t\(locations.count)\n"
        }
        return r + "\n"
    }

    /// (4) Hot completion query: 2-letter prefix on the distinct-name document.
    private func probeHotQuery(_ distinct: String) throws -> String {
        let index = WordIndex(text: distinct)
        let symbols = WordIndex.symbols(text: distinct, languageIdentifier: "python")
        let def = LanguageRegistry.definition(forIdentifier: "python")!
        let keywords = def.keywords + def.builtins
        let clock = ContinuousClock()
        var r = "## (4) Hot completion query (WordIndex.suggestions, 20 runs each)\n"
        r += "doc: distinct-name Python, \(index.words.count) words, \(symbols.count) symbols\n"
        r += "prefix\tmatches(words+symbols)\tresults\tmedian ms\tp95 ms\tmax ms\n"
        for prefix in ["in", "pa", "zz"] {
            var samples: [Double] = []
            var hits: [String] = []
            for _ in 0..<20 {
                samples.append(ms(clock.measure {
                    hits = index.suggestions(prefix: prefix, language: keywords, symbols: symbols)
                }))
            }
            samples.sort()
            let matches = index.words.filter { $0.lowercased().hasPrefix(prefix) }.count
                + symbols.filter { $0.lowercased().hasPrefix(prefix) }.count
            r += "\(prefix)\t\(matches)\t\(hits.count)\t\(fmt(samples[samples.count / 2]))\t"
            r += "\(fmt(samples[Int(Double(samples.count - 1) * 0.95)]))\t\(fmt(samples.last!))\n"
        }
        return r + "\n"
    }
}
