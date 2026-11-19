import AppKit
import Darwin
import Foundation
import Testing
@testable import KaruCore

// M17 T17.5 completion benchmark (plan §11 rows "输入与滚动" / memory).
// Opt-in: `KARU_T175_BENCH=1 swift test --filter CompletionBenchmark`
// (also `-c release -Xswiftc -enable-testing`). Prints a report and writes it
// to `.build/m17-baseline/t175-bench-<config>.txt`; never fails on timings.

private let benchEnabled = ProcessInfo.processInfo.environment["KARU_T175_BENCH"] != nil

private func heapInUse() -> Int {
    var stats = malloc_statistics_t()
    malloc_zone_statistics(nil, &stats)
    return Int(stats.size_in_use)
}

private func millis(_ d: Duration) -> Double {
    Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
}

private func summary(_ samples: [Double]) -> String {
    let s = samples.sorted()
    guard !s.isEmpty else { return "-" }
    let p50 = s[s.count / 2]
    let p95 = s[min(s.count - 1, Int((Double(s.count) * 0.95).rounded(.up)) - 1)]
    return String(format: "p50 %.2f  p95 %.2f  max %.2f ms (n=%d)", p50, p95, s.last!, s.count)
}

/// ~10 MB of Python whose identifiers are renamed per copy (the T17.0
/// distinct-name probe document).
private func distinctPython(targetBytes: Int = 10 * 1024 * 1024) throws -> String {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    let sample = try String(contentsOf: root.appendingPathComponent("Tests/Fixtures/M17/inference/sample_1000.py"),
                            encoding: .utf8)
    let def = LanguageRegistry.definition(forIdentifier: "python")!
    let reserved = Set(def.keywords + def.builtins + ["self", "cls", "__future__", "annotations"])
    let regex = try NSRegularExpression(pattern: #"(?<![0-9A-Za-z_])[A-Za-z_][A-Za-z0-9_]*(?!['"])"#)
    let ns = sample as NSString
    var pieces: [(String, Bool)] = []
    var cursor = 0
    for m in regex.matches(in: sample, range: NSRange(location: 0, length: ns.length)) {
        pieces.append((ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)), false))
        let word = ns.substring(with: m.range)
        pieces.append((word, !reserved.contains(word)))
        cursor = m.range.location + m.range.length
    }
    pieces.append((ns.substring(from: cursor), false))
    var out = ""
    out.reserveCapacity(targetBytes + 64 * 1024)
    var copy = 0
    while out.utf8.count < targetBytes {
        copy += 1
        let suffix = "_\(copy)"
        for (text, rename) in pieces {
            out += text
            if rename { out += suffix }
        }
        if !out.hasSuffix("\n") { out += "\n" }
    }
    return out
}

@Suite("CompletionBenchmark", .enabled(if: benchEnabled), .serialized)
@MainActor
struct CompletionBenchmarkTests {
    #if DEBUG
    static let config = "debug"
    #else
    static let config = "release"
    #endif

    @Test func report() throws {
        var r = "# T17.5 completion benchmark (\(Self.config)) — \(Date())\n"
        r += "# host: \(ProcessInfo.processInfo.operatingSystemVersionString), "
        r += "\(ProcessInfo.processInfo.activeProcessorCount) cores\n\n"
        let clock = ContinuousClock()
        let text = try distinctPython()
        let ns = text as NSString
        r += "doc: distinct-name Python, \(ns.length) UTF-16 units\n\n"

        // 1. Declaration snapshot.
        var heap = heapInUse()
        var scan: DeclarationScan!
        let scanTime = millis(clock.measure { scan = DeclarationScan.scan(text: text, languageIdentifier: "python") })
        let scanHeap = heapInUse() - heap
        let bytes = scan.compactStorageBytes
        r += "## Declaration snapshot\n"
        r += String(format: "scan %.0f ms; heap Δ %.0f KB; names %d KB, declarations %d KB, outline %d KB, scopes %d\n",
                    scanTime, Double(scanHeap) / 1024, bytes.names / 1024, bytes.declarations / 1024,
                    bytes.outline / 1024, scan.scopeCount)

        // 2. Query index.
        heap = heapInUse()
        var index: DeclarationQueryIndex!
        let indexTime = millis(clock.measure { index = DeclarationQueryIndex(scan: scan) })
        r += String(format: "query index: build %.1f ms; heap Δ %.0f KB; module bindings %d\n\n",
                    indexTime, Double(heapInUse() - heap) / 1024, index.moduleBindingCount)

        // 3. Word index: old Set<String> vs new sorted index.
        heap = heapInUse()
        var legacy: Set<String>! = []
        let legacyTime = millis(clock.measure {
            let regex = try! NSRegularExpression(pattern: #"\w{2,}"#)
            var set = Set<String>()
            regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                set.insert(ns.substring(with: m!.range))
            }
            legacy = set
        })
        let legacyHeap = heapInUse() - heap
        let legacyCount = legacy.count
        legacy = nil
        heap = heapInUse()
        var words: WordIndex!
        let wordTime = millis(clock.measure { words = WordIndex(text: text, languageIdentifier: "python") })
        let wordHeap = heapInUse() - heap
        r += "## Document words\n"
        r += String(format: "pre-T17.5 Set<String>: %d words, build %.0f ms, heap Δ %.0f KB\n",
                    legacyCount, legacyTime, Double(legacyHeap) / 1024)
        r += String(format: "T17.5 WordIndex: %d words, build %.0f ms (one go), heap Δ %.0f KB (resident estimate %.0f KB)\n",
                    words.count, wordTime, Double(wordHeap) / 1024, Double(words.residentBytes) / 1024)
        // Sliced build: 4 ms slices of 16 K-unit steps.
        var builder = WordIndexBuilder(dollar: false)
        var slices: [Double] = []
        var phaseMax: [Int: Double] = [:]
        var done = false
        while !done {
            let phase = builder.phase
            let start = DispatchTime.now().uptimeNanoseconds
            let deadline = start + 4_000_000
            repeat { done = builder.step(ns, budgetUnits: 4_096) } while !done
                && DispatchTime.now().uptimeNanoseconds < deadline
            slices.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            phaseMax[phase] = max(phaseMax[phase] ?? 0, slices.last!)
        }
        r += String(format: "sliced build (4 K-unit steps until a 4 ms deadline): %d slices, total %.0f ms, longest slice %.2f ms\n\n",
                    slices.count, slices.reduce(0, +), slices.max() ?? 0)
        r += "longest slice by starting phase (0 tokenize, 1 sort, 2 initials, 3 sort initials): "
            + phaseMax.sorted { $0.key < $1.key }.map { String(format: "%d: %.2f", $0.key, $0.value) }
                .joined(separator: ", ") + " ms\n\n"

        // 4. Hot queries at a caret inside a function in the middle.
        let middle = ns.length / 2
        let defRange = ns.range(of: "\n    def ", options: [], range: NSRange(location: middle, length: ns.length - middle))
        let lineEnd = ns.range(of: "\n", options: [], range: NSRange(location: defRange.location + 1,
                                                                       length: ns.length - defRange.location - 1))
        // The caret: start of the line after the def (inside its body).
        let caret = NSMaxRange(lineEnd)
        // A multi-part module name for the word-start query.
        var initialsQuery = "gtn"
        for i in 0..<index.moduleBindingCount {
            let name = index.moduleBinding(at: i).name
            let parts = CandidateMatcher.partStarts(Array(name.utf16))
            if parts.count >= 3, name.first?.isLetter == true {
                let units = Array(name.utf16)
                initialsQuery = String(utf16CodeUnits: parts.prefix(3).map { units[$0] }, count: 3).lowercased()
                break
            }
        }
        let scanner = CandidateEngine.contextScanner(for: "python", definition: nil)
        let def = LanguageRegistry.definition(forIdentifier: "python")!
        r += "## Hot query (CandidateEngine.complete, caret inside a function at \(caret))\n"
        r += "prefix\tresults\tcold ms\thot\n"
        var checkpoints = CheckpointStore()
        for prefix in ["in", "pa", "zq", initialsQuery] {
            let typed = ns.replacingCharacters(in: NSRange(location: caret, length: 0), with: "        " + prefix)
            let live = typed as NSString
            var request = CompletionRequest(text: live, caret: caret + 8 + prefix.utf16.count,
                                            languageIdentifier: "python")
            request.keywords = def.keywords
            request.builtins = def.builtins
            request.snapshot = scan
            request.snapshotVersion = 1
            request.snapshotJournal.record(editedRange: NSRange(location: caret, length: 8 + prefix.utf16.count),
                                           changeInLength: 8 + prefix.utf16.count)
            request.words = words
            request.scanner = scanner
            var engine = CandidateEngine()
            var count = 0
            let cold = millis(clock.measure { count = engine.complete(request, checkpoints: &checkpoints)?.candidates.count ?? 0 })
            var hot: [Double] = []
            for _ in 0..<40 {
                hot.append(millis(clock.measure { _ = engine.complete(request, checkpoints: &checkpoints) }))
            }
            r += "\(prefix)\t\(count)\t" + String(format: "%.2f", cold) + "\t" + summary(hot) + "\n"
        }
        r += "\n"

        // 5. Key to first candidates: a real controller and text view.
        r += try keyToCandidates(text: text, caret: caret, clock: clock)

        print(r)
        let out = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/m17-baseline")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try r.write(to: out.appendingPathComponent("t175-bench-\(Self.config).txt"), atomically: true, encoding: .utf8)
    }

    /// Types identifiers at `caret` keystroke by keystroke (insert + request),
    /// measuring each key from `insertText` to the popup being updated.
    private func keyToCandidates(text: String, caret: Int, clock: ContinuousClock) throws -> String {
        let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let scrollView = NSScrollView(frame: frame)
        let textView = EditorTextView(frame: frame)
        textView.isRichText = false
        textView.layoutManager?.allowsNonContiguousLayout = true
        scrollView.documentView = textView
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        defer { window.close() }
        textView.string = text
        let center = NotificationCenter()
        let suite = "CompletionBenchmark-\(UUID().uuidString)"
        let defaults = TestDefaults.make(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ModuleSettings(defaults: defaults, center: center)
        let hub = TextStorageObserverHub()
        textView.textStorage?.delegate = hub
        let controller = CompletionController(textView: textView, moduleSettings: settings, moduleCenter: center)
        hub.add(controller)
        textView.completionKeyHandler = controller
        var r = "## Key to first candidates (insertText + CompletionController, 10 MB text view)\n"
        let open = millis(clock.measure {
            controller.setLanguage(identifier: "python")
            controller.indexDocument()
        })
        r += String(format: "open (language + synchronous index): %.0f ms\n", open)
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        textView.insertText("\n        ", replacementRange: NSRange(location: NSNotFound, length: 0))
        var samples: [Double] = []
        var first: Double = 0
        var shown = 0
        for word in ["inv", "pay", "zqx", "status", "self.inv"] {
            for (n, ch) in word.enumerated() {
                let key = String(ch)
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, characters: key,
                                             charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0)!
                let t = millis(clock.measure {
                    textView.insertText(key, replacementRange: NSRange(location: NSNotFound, length: 0))
                    controller.textViewDidInsertKey(event)
                })
                if samples.isEmpty && first == 0 { first = t } else { samples.append(t) }
                if n == word.count - 1, !controller.currentSuggestionsForTesting.isEmpty { shown += 1 }
            }
            textView.insertText(" ", replacementRange: NSRange(location: NSNotFound, length: 0))
            controller.dismissCompletion()
        }
        r += String(format: "first key (cold: query index, checkpoints): %.1f ms\n", first)
        r += "later keys: " + summary(samples) + "; words with a popup at the end: \(shown)/5\n"
        withExtendedLifetime(hub) {}
        textView.textStorage?.delegate = nil
        return r
    }
}
