import AppKit
import Darwin
import Foundation
import Testing
@testable import KaruCore

// M17 T17.11b inference benchmark (plan §8.3 / §11).
// Opt-in: `KARU_T1711B_BENCH=1 swift test --filter TypeInferenceBenchmark`
// (also `-c release -Xswiftc -enable-testing`). Prints a report and writes
// it to `.build/m17-baseline/t1711b-bench-<config>.txt`; never fails on
// timings. Measures, through a real `CompletionController`:
//   - keystroke → first member candidates (insertText + request), the `.`
//     key that runs inference and the next keys, cold (first request after
//     open, type tables unmapped) and warm; the inference part separately;
//   - sample_1000.py and a ~10 MB diverse Python file (summary mode);
//   - paired memory: the same ≥ 20 member positions with type inference off
//     and on (malloc in use, phys_footprint), and inference-owned bytes.

private let benchEnabled = ProcessInfo.processInfo.environment["KARU_T1711B_BENCH"] != nil

private func footprint() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Int(info.phys_footprint) : 0
}

private func mallocInUse() -> Int {
    var stats = malloc_statistics_t()
    malloc_zone_statistics(nil, &stats)
    return Int(stats.size_in_use)
}

private func mb(_ bytes: Int) -> String { String(format: "%.2f MB", Double(bytes) / 1_048_576) }

private func summary(_ samples: [Double]) -> String {
    let s = samples.sorted()
    guard !s.isEmpty else { return "-" }
    let p50 = s[s.count / 2]
    let p95 = s[min(s.count - 1, Int((Double(s.count) * 0.95).rounded(.up)) - 1)]
    return String(format: "p50 %.2f  p95 %.2f  max %.2f ms (n=%d)", p50, p95, s.last!, s.count)
}

private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

private func sample1000() throws -> String {
    try String(contentsOf: root.appendingPathComponent("Tests/Fixtures/M17/inference/sample_1000.py"), encoding: .utf8)
}

/// ~10 MB of Python whose identifiers are renamed per copy (as in the T17.5
/// completion benchmark).
private func distinctPython(targetBytes: Int = 10 * 1024 * 1024) throws -> String {
    let sample = try sample1000()
    let def = LanguageRegistry.definition(forIdentifier: "python")!
    let reserved = Set(def.keywords + def.builtins + ["self", "cls", "__future__", "annotations"])
    let regex = try NSRegularExpression(pattern: #"(?<![0-9A-Za-z_.])[A-Za-z_][A-Za-z0-9_]*(?!['"])"#)
    let ns = sample as NSString
    var pieces: [(String, Bool)] = []
    var cursor = 0
    // Imported module names and stdlib attributes keep their spelling.
    let keep: Set<String> = ["json", "os", "re", "Counter", "defaultdict", "dataclass", "field", "datetime", "timedelta",
                             "Enum", "reduce", "chain", "Path", "Iterable", "Optional", "TypeVar", "T", "collections",
                             "dataclasses", "enum", "functools", "itertools", "pathlib", "typing"]
    for m in regex.matches(in: sample, range: NSRange(location: 0, length: ns.length)) {
        pieces.append((ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)), false))
        let word = ns.substring(with: m.range)
        pieces.append((word, !reserved.contains(word) && !keep.contains(word)))
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

/// Member accesses inside function bodies: (offset of the line end, indentation, receiver).
private func memberSites(_ text: NSString, near offsets: [Int]) -> [(Int, String, String)] {
    // swiftlint:disable:next force_try
    let regex = try! NSRegularExpression(pattern: #"^( {4,})(?:[A-Za-z_][A-Za-z0-9_]* = )?([a-z_][A-Za-z0-9_]*)\.[a-z_]"#,
                                         options: [.anchorsMatchLines])
    var out: [(Int, String, String)] = []
    var used = Set<Int>()
    for offset in offsets {
        let range = NSRange(location: offset, length: min(64 * 1024, text.length - offset))
        for m in regex.matches(in: text as String, range: range) {
            let receiver = text.substring(with: m.range(at: 2))
            let lineEnd = NSMaxRange(text.lineRange(for: m.range)) - 1
            guard !used.contains(lineEnd), receiver != "print" else { continue }
            used.insert(lineEnd)
            out.append((lineEnd, text.substring(with: m.range(at: 1)), receiver))
            break
        }
    }
    return out
}

@MainActor
private final class Editor {
    let center = NotificationCenter()
    let suite = "TypeInferenceBenchmark-\(UUID().uuidString)"
    let settings: ModuleSettings
    let textView: EditorTextView
    let window: NSWindow
    let hub = TextStorageObserverHub()
    let controller: CompletionController

    init(text: String, typeInference: Bool) {
        let defaults = TestDefaults.make(suite)
        settings = ModuleSettings(defaults: defaults, center: center)
        settings.setEnabled(typeInference, for: .typeInference)
        let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let scrollView = NSScrollView(frame: frame)
        textView = EditorTextView(frame: frame)
        textView.isRichText = false
        textView.allowsUndo = false
        textView.layoutManager?.allowsNonContiguousLayout = true
        scrollView.documentView = textView
        window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        textView.string = text
        textView.textStorage?.delegate = hub
        controller = CompletionController(textView: textView, moduleSettings: settings, moduleCenter: center)
        hub.add(controller)
        textView.completionKeyHandler = controller
    }

    func open() {
        controller.setLanguage(identifier: "python")
        controller.indexDocument()
    }

    /// Times one typed key (insert + request), in ms.
    func key(_ key: String) -> Double {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil, characters: key,
                                     charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0)!
        let start = DispatchTime.now().uptimeNanoseconds
        textView.insertText(key, replacementRange: NSRange(location: NSNotFound, length: 0))
        controller.textViewDidInsertKey(event)
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
    }

    var inferenceMilliseconds: Double {
        Double(controller.typeInferenceForTesting?.statistics.lastNanoseconds ?? 0) / 1e6
    }

    func close() {
        controller.dismissCompletion()
        textView.textStorage?.delegate = nil
        window.close()
        UserDefaults().removePersistentDomain(forName: suite)
    }
}

private struct Run {
    var firstKey: Double = 0
    var firstInference: Double = 0
    var dotKeys: [Double] = []
    var dotInference: [Double] = []
    var dotSyntax: [Double] = []
    var nextKeys: [Double] = []
    var inferred = 0
    var shown = 0
}

/// Types `receiver.` + two characters at each site (the inserted line is
/// removed afterwards, so the document is the same for every site).
@MainActor
private func exercise(_ editor: Editor, sites: [(Int, String, String)], prefixes: [String]) -> Run {
    var run = Run()
    for (k, (lineEnd, indent, receiver)) in sites.enumerated() { autoreleasepool {
        let storage = editor.textView.textStorage!
        let inserted = "\n" + indent + receiver
        editor.textView.setSelectedRange(NSRange(location: lineEnd, length: 0))
        storage.replaceCharacters(in: NSRange(location: lineEnd, length: 0), with: inserted)
        editor.textView.setSelectedRange(NSRange(location: lineEnd + (inserted as NSString).length, length: 0))
        let t = editor.key(".")
        let inference = editor.inferenceMilliseconds
        if k == 0 { run.firstKey = t; run.firstInference = inference } else {
            run.dotKeys.append(t)
            run.dotInference.append(inference)
            run.dotSyntax.append(Double(editor.controller.typeInferenceForTesting?.statistics.lastSyntaxNanoseconds ?? 0) / 1e6)
        }
        let candidates = editor.controller.currentCandidatesForTesting
        if !candidates.isEmpty { run.shown += 1 }
        if candidates.first?.source == .inferredType { run.inferred += 1 }
        for ch in prefixes[k % prefixes.count] { run.nextKeys.append(editor.key(String(ch))) }
        editor.controller.dismissCompletion()
        let typed = 1 + prefixes[k % prefixes.count].utf16.count
        storage.replaceCharacters(in: NSRange(location: lineEnd, length: (inserted as NSString).length + typed), with: "")
    } }
    return run
}

private func describe(_ label: String, _ run: Run, sites: Int) -> String {
    var r = "### \(label)\n"
    r += String(format: "first `.` (cold): %.2f ms end to end, inference %.2f ms\n", run.firstKey, run.firstInference)
    r += "later `.` keys (warm): " + summary(run.dotKeys) + "\n"
    r += "  inference part: " + summary(run.dotInference) + "\n"
    r += "    of which the syntax snapshot update (ensureSyntax): " + summary(run.dotSyntax) + "\n"
    r += "keys after the dot (members reused): " + summary(run.nextKeys) + "\n"
    r += "positions with a popup: \(run.shown)/\(sites); inferred members first: \(run.inferred)/\(sites)\n"
    return r
}

@Suite("TypeInferenceBenchmark", .enabled(if: benchEnabled), .serialized)
@MainActor
struct TypeInferenceBenchmarkTests {
    #if DEBUG
    static let config = "debug"
    #else
    static let config = "release"
    #endif

    @Test func report() throws {
        var r = "# T17.11b inference benchmark (\(Self.config)) — \(Date())\n"
        r += "# host: \(ProcessInfo.processInfo.operatingSystemVersionString), "
        r += "\(ProcessInfo.processInfo.activeProcessorCount) cores; load "
        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        r += String(format: "%.2f %.2f %.2f\n\n", loads[0], loads[1], loads[2])
        let prefixes = ["ge", "to", "it", "na", "ap", "st", "va", "co"]

        // sample_1000.py: latency, cold and warm.
        let sample = try sample1000()
        let sampleNS = sample as NSString
        let step = max(1, sampleNS.length / 28)
        let sampleSites = Array(memberSites(sampleNS, near: stride(from: 0, to: sampleNS.length, by: step).map { $0 }).prefix(24))
        PythonTypeTables.shared.release()
        do {
            let editor = Editor(text: sample, typeInference: true)
            editor.open()
            let run = exercise(editor, sites: sampleSites, prefixes: prefixes)
            r += describe("sample_1000.py (\(sampleNS.length) units), \(sampleSites.count) member positions", run, sites: sampleSites.count)
            // Warm again: the same positions, second pass.
            let warm = exercise(editor, sites: sampleSites, prefixes: prefixes)
            r += "second pass `.` keys: " + summary([warm.firstKey] + warm.dotKeys) + "; inference "
                + summary([warm.firstInference] + warm.dotInference) + "\n"
            if let s = editor.controller.typeInferenceForTesting?.statistics {
                r += "service: requests \(s.requests), inferred \(s.inferred), reused \(s.reused), aborted \(s.aborted), "
                    + "sessions \(s.sessions), return cache hits \(s.returnCacheHits) / inferences \(s.returnInferences)\n\n"
            }
            editor.close()
        }

        // Memory, paired: the same positions with type inference off and on,
        // alternated twice after a warm-up (the harness's own growth cancels).
        do {
            PythonTypeTables.shared.release()
            let editor = Editor(text: sample, typeInference: false)
            editor.open()
            _ = exercise(editor, sites: sampleSites, prefixes: prefixes)
            _ = exercise(editor, sites: sampleSites, prefixes: prefixes)
            var heapDeltas: [Int] = []
            var footDeltas: [Int] = []
            var owned = 0
            var ownedText = ""
            var released = true
            for _ in 0..<2 {
                _ = exercise(editor, sites: sampleSites, prefixes: prefixes)
                let heapOff = mallocInUse(), footOff = footprint()
                editor.settings.setEnabled(true, for: .typeInference)
                _ = exercise(editor, sites: sampleSites, prefixes: prefixes)
                let heapOn = mallocInUse(), footOn = footprint()
                heapDeltas.append(heapOn - heapOff)
                footDeltas.append(footOn - footOff)
                let syntax = editor.controller.analysis.syntaxRetainedBytes
                let service = editor.controller.typeInferenceForTesting?.retainedBytes ?? 0
                let tables = PythonTypeTables.shared.retainedBytes
                let store = TypeTableStore.shared.statistics.cachedBytes
                owned = syntax + service + tables + store
                ownedText = "syntax \(mb(syntax)), service (return cache + name index) \(mb(service)), tables \(mb(tables)), "
                    + "type-table store LRU \(mb(store))"
                editor.settings.setEnabled(false, for: .typeInference)
                released = released && editor.controller.isInferenceStateReleased && editor.controller.analysis.syntax == nil
                    && PythonTypeTables.shared.isReleased
            }
            r += "### Memory, sample_1000.py, \(sampleSites.count) member positions (paired off → on, twice)\n"
            r += "malloc in use, on − off: \(heapDeltas.map(mb).joined(separator: ", "))\n"
            r += "phys_footprint, on − off: \(footDeltas.map(mb).joined(separator: ", "))\n"
            r += "inference-owned while on: \(ownedText) (sum \(mb(owned)))\n"
            r += "released after switching off: \(released)\n\n"
            editor.close()
        }

        // ~10 MB diverse Python: summary mode.
        let big = try distinctPython()
        let bigNS = big as NSString
        let bigStep = bigNS.length / 26
        let bigSites = Array(memberSites(bigNS, near: stride(from: bigStep / 2, to: bigNS.length - 70_000, by: bigStep).map { $0 }).prefix(24))
        PythonTypeTables.shared.release()
        do {
            let heap0 = mallocInUse(), foot0 = footprint()
            let editor = Editor(text: big, typeInference: true)
            let openStart = DispatchTime.now().uptimeNanoseconds
            editor.open()
            let openMs = Double(DispatchTime.now().uptimeNanoseconds - openStart) / 1e6
            // Before the background build publishes a summary: unknown, not blocking.
            let early = exercise(editor, sites: Array(bigSites.prefix(1)), prefixes: prefixes)
            let buildStart = DispatchTime.now().uptimeNanoseconds
            _ = editor.controller.analysis.ensureSyntax()
            let buildMs = Double(DispatchTime.now().uptimeNanoseconds - buildStart) / 1e6
            let heap1 = mallocInUse(), foot1 = footprint()
            let run = exercise(editor, sites: bigSites, prefixes: prefixes)
            let heap2 = mallocInUse(), foot2 = footprint()
            r += "### ~10 MB diverse Python (\(bigNS.length) units), \(bigSites.count) member positions\n"
            r += String(format: "open (language + index): %.0f ms; summary build (as the sliced background job would): %.0f ms\n",
                        openMs, buildMs)
            r += String(format: "a `.` before the summary is published: %.2f ms, popup %@ (no inference, usage path)\n",
                        early.firstKey, early.shown > 0 ? "shown" : "none")
            r += describe("10 MB, after the summary is published", run, sites: bigSites.count)
            let syntax = editor.controller.analysis.syntaxRetainedBytes
            let service = editor.controller.typeInferenceForTesting?.retainedBytes ?? 0
            let tables = PythonTypeTables.shared.retainedBytes
            let store = TypeTableStore.shared.statistics.cachedBytes
            r += "inference-owned: syntax (summary + statement LRU ≤ \(mb(SyntaxSubtreeCache.defaultByteLimit))) \(mb(syntax)), "
                + "return cache \(mb(service)) (cap \(mb(TypeInferenceService.returnCacheBytes))), tables \(mb(tables)) "
                + "(caps \(mb(PythonTypeTables.typeCacheBytes)) + \(mb(PythonTypeTables.memberCacheBytes)) + "
                + "\(mb(PythonTypeTables.memberCacheBytes / 2))), store LRU \(mb(store)) (cap \(mb(TypeTableStore.defaultCacheByteLimit)))\n"
            r += "malloc: open → summary \(mb(heap1 - heap0)), summary → after positions \(mb(heap2 - heap1)); "
                + "phys_footprint: \(mb(foot1 - foot0)), \(mb(foot2 - foot1))\n"
            if let s = editor.controller.typeInferenceForTesting?.statistics {
                r += "service: requests \(s.requests), inferred \(s.inferred), skipped (no summary) \(s.skippedLarge), "
                    + "aborted \(s.aborted), name-index builds \(s.nameIndexBuilds)\n"
            }
            editor.close()
        }

        print(r)
        let out = root.appendingPathComponent(".build/m17-baseline")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try r.write(to: out.appendingPathComponent("t1711b-bench-\(Self.config).txt"), atomically: true, encoding: .utf8)
    }
}
