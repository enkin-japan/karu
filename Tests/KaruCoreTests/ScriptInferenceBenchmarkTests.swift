import AppKit
import Darwin
import Foundation
import Testing
@testable import KaruCore

// M17 T17.11c JS / TS inference benchmark (plan §8.3 / §11).
// Opt-in: `KARU_T1711C_BENCH=1 swift test --filter ScriptInferenceBenchmark`
// (also `-c release -Xswiftc -enable-testing`). Prints a report and writes
// it to `.build/m17-baseline/t1711c-bench-<config>.txt`; never fails on
// timings. Measures, through a real `CompletionController`:
//   - keystroke → first member candidates (insertText + request) for the
//     `.` key that runs inference and the next keys, cold (first request
//     after open, type tables unmapped) and warm; the inference part
//     separately;
//   - sample_1000.ts and ~10 MB diverse TypeScript and JavaScript files
//     (summary mode);
//   - paired memory: the same ≥ 20 member positions with type inference
//     off and on (malloc in use, phys_footprint), inference-owned bytes,
//     and whether the DOM section was read.
// Release test binaries have no debug-only table path: also set
// `KARU_TYPE_TABLES=$PWD/assets/typetables`. `KARU_T1711C_SITES=1` prints
// each position's line and first candidate (source).

private let benchEnabled = ProcessInfo.processInfo.environment["KARU_T1711C_BENCH"] != nil

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

private func fixture(_ path: String) throws -> String {
    try String(contentsOf: root.appendingPathComponent("Tests/Fixtures/M17/" + path), encoding: .utf8)
}

/// Copies of `sample` up to `targetBytes`, every identifier not preceded by
/// `.` (except keywords, lib names and `keep`) suffixed with the copy number.
private func distinct(_ sample: String, language: String, targetBytes: Int = 10 * 1024 * 1024) throws -> String {
    let def = LanguageRegistry.definition(forIdentifier: language)!
    let keep: Set<String> = ["Map", "Set", "Date", "Promise", "Array", "Record", "Number", "String", "JSON", "Math",
                             "fetch", "console", "Error", "Object", "Pick", "Partial", "Readonly", "Response", "RegExp",
                             "Boolean", "this", "undefined", "null", "true", "false", "string", "number", "boolean",
                             "void", "any", "unknown", "never", "async", "await", "of", "as", "type", "interface",
                             "readonly", "private", "public", "protected", "constructor", "get", "set", "static",
                             "extends", "implements", "keyof", "typeof", "new", "export", "import", "from", "enum",
                             "length", "map", "filter", "push", "values", "keys", "entries", "forEach", "reduce",
                             "toFixed", "toString", "trim", "split", "join", "slice", "includes", "find", "sort"]
    let reserved = Set(def.keywords + def.builtins).union(keep)
    let regex = try NSRegularExpression(pattern: #"(?<![0-9A-Za-z_$.'"`])[A-Za-z_$][A-Za-z0-9_$]*(?![A-Za-z0-9_$'"`])"#)
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

/// Member accesses inside function bodies: (offset of the line end, indentation, receiver).
private func memberSites(_ text: NSString, near offsets: [Int]) -> [(Int, String, String)] {
    // swiftlint:disable:next force_try
    let regex = try! NSRegularExpression(
        pattern: #"^( {2,})(?:(?:const|let) [A-Za-z_$][\w$]* = )?(?:return )?(?:await )?([a-z_$][\w$]*)\.[a-z_]"#,
        options: [.anchorsMatchLines])
    var out: [(Int, String, String)] = []
    var used = Set<Int>()
    for offset in offsets {
        let range = NSRange(location: offset, length: min(64 * 1024, text.length - offset))
        for m in regex.matches(in: text as String, range: range) {
            let receiver = text.substring(with: m.range(at: 2))
            let lineEnd = NSMaxRange(text.lineRange(for: m.range)) - 1
            guard !used.contains(lineEnd), receiver != "console" else { continue }
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
    let suite = "ScriptInferenceBenchmark-\(UUID().uuidString)"
    let settings: ModuleSettings
    let textView: EditorTextView
    let window: NSWindow
    let hub = TextStorageObserverHub()
    let controller: CompletionController
    let language: String

    init(text: String, language: String, typeInference: Bool) {
        self.language = language
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
        controller.setLanguage(identifier: language)
        controller.indexDocument()
    }

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
        if ProcessInfo.processInfo.environment["KARU_T1711C_SITES"] != nil {
            let text = editor.textView.string as NSString
            let line = text.substring(with: text.lineRange(for: NSRange(location: max(0, lineEnd - 1), length: 0)))
            print("SITE \(receiver). after: \(line.trimmingCharacters(in: .whitespacesAndNewlines)) -> \(candidates.first.map { "\($0.name) \($0.source)" } ?? "none")")
        }
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

@MainActor
private func release() {
    ScriptTypeTables.shared.release()
    PythonTypeTables.shared.release()
}

@MainActor
private func owned(_ editor: Editor) -> (Int, String) {
    let syntax = editor.controller.analysis.syntaxRetainedBytes
    let service = editor.controller.typeInferenceForTesting?.retainedBytes ?? 0
    let tables = ScriptTypeTables.shared.retainedBytes
    let store = TypeTableStore.shared.statistics.cachedBytes
    return (syntax + service + tables + store,
            "syntax \(mb(syntax)), service (return cache + name index) \(mb(service)), tables \(mb(tables)), "
                + "type-table store LRU \(mb(store))")
}

@Suite("ScriptInferenceBenchmark", .enabled(if: benchEnabled), .serialized)
@MainActor
struct ScriptInferenceBenchmarkTests {
    #if DEBUG
    static let config = "debug"
    #else
    static let config = "release"
    #endif

    @Test func report() throws {
        var r = "# T17.11c JS / TS inference benchmark (\(Self.config)) — \(Date())\n"
        r += "# host: \(ProcessInfo.processInfo.operatingSystemVersionString), "
        r += "\(ProcessInfo.processInfo.activeProcessorCount) cores; load "
        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        r += String(format: "%.2f %.2f %.2f\n\n", loads[0], loads[1], loads[2])
        let prefixes = ["ge", "to", "it", "na", "le", "st", "va", "co"]

        // sample_1000.ts: latency, cold and warm.
        let sample = try fixture("inference/sample_1000.ts")
        let sampleNS = sample as NSString
        let step = max(1, sampleNS.length / 30)
        let sampleSites = Array(memberSites(sampleNS, near: stride(from: 0, to: sampleNS.length, by: step).map { $0 }).prefix(24))
        release()
        let domBefore = TypeTableStore.shared.statistics.domSectionLookups
        do {
            let editor = Editor(text: sample, language: "typescript", typeInference: true)
            editor.open()
            let run = exercise(editor, sites: sampleSites, prefixes: prefixes)
            r += describe("sample_1000.ts (\(sampleNS.length) units), \(sampleSites.count) member positions", run, sites: sampleSites.count)
            let warm = exercise(editor, sites: sampleSites, prefixes: prefixes)
            r += "second pass `.` keys: " + summary([warm.firstKey] + warm.dotKeys) + "; inference "
                + summary([warm.firstInference] + warm.dotInference) + "\n"
            if let s = editor.controller.typeInferenceForTesting?.statistics {
                r += "service: requests \(s.requests), inferred \(s.inferred), reused \(s.reused), aborted \(s.aborted), "
                    + "sessions \(s.sessions), return cache hits \(s.returnCacheHits) / inferences \(s.returnInferences)\n"
            }
            r += "DOM section lookups during the run: \(TypeTableStore.shared.statistics.domSectionLookups - domBefore) "
                + "(none of the positions' receivers depends on the sample's `fetch` calls)\n\n"
            editor.close()
        }

        // Memory, paired: the same positions with type inference off and on.
        do {
            release()
            let editor = Editor(text: sample, language: "typescript", typeInference: false)
            editor.open()
            _ = exercise(editor, sites: sampleSites, prefixes: prefixes)
            _ = exercise(editor, sites: sampleSites, prefixes: prefixes)
            var heapDeltas: [Int] = []
            var footDeltas: [Int] = []
            var ownedText = ""
            var ownedBytes = 0
            var released = true
            for _ in 0..<2 {
                _ = exercise(editor, sites: sampleSites, prefixes: prefixes)
                let heapOff = mallocInUse(), footOff = footprint()
                editor.settings.setEnabled(true, for: .typeInference)
                _ = exercise(editor, sites: sampleSites, prefixes: prefixes)
                let heapOn = mallocInUse(), footOn = footprint()
                heapDeltas.append(heapOn - heapOff)
                footDeltas.append(footOn - footOff)
                (ownedBytes, ownedText) = owned(editor)
                editor.settings.setEnabled(false, for: .typeInference)
                released = released && editor.controller.isInferenceStateReleased && editor.controller.analysis.syntax == nil
                    && ScriptTypeTables.shared.isReleased
            }
            r += "### Memory, sample_1000.ts, \(sampleSites.count) member positions (paired off → on, twice)\n"
            r += "malloc in use, on − off: \(heapDeltas.map(mb).joined(separator: ", "))\n"
            r += "phys_footprint, on − off: \(footDeltas.map(mb).joined(separator: ", "))\n"
            r += "inference-owned while on: \(ownedText) (sum \(mb(ownedBytes)))\n"
            r += "released after switching off: \(released)\n\n"
            editor.close()
        }

        // ~10 MB diverse TypeScript and JavaScript: summary mode.
        let jsSample = try fixture("completion/scope/js_scope.js") + "\n" + fixture("highlight/javascript.js") + "\n"
            + fixture("completion/member/js_members.js").replacingOccurrences(of: #"⟨\d+⟩"#, with: "", options: .regularExpression)
        for (language, source) in [("typescript", sample), ("javascript", jsSample)] {
            let big = try distinct(source, language: language)
            let bigNS = big as NSString
            let bigStep = bigNS.length / 26
            let bigSites = Array(memberSites(bigNS, near: stride(from: bigStep / 2, to: bigNS.length - 70_000, by: bigStep).map { $0 }).prefix(24))
            release()
            let heap0 = mallocInUse(), foot0 = footprint()
            let editor = Editor(text: big, language: language, typeInference: true)
            let openStart = DispatchTime.now().uptimeNanoseconds
            editor.open()
            let openMs = Double(DispatchTime.now().uptimeNanoseconds - openStart) / 1e6
            let early = exercise(editor, sites: Array(bigSites.prefix(1)), prefixes: prefixes)
            let buildStart = DispatchTime.now().uptimeNanoseconds
            _ = editor.controller.analysis.ensureSyntax()
            let buildMs = Double(DispatchTime.now().uptimeNanoseconds - buildStart) / 1e6
            let heap1 = mallocInUse(), foot1 = footprint()
            let run = exercise(editor, sites: bigSites, prefixes: prefixes)
            let heap2 = mallocInUse(), foot2 = footprint()
            r += "### ~10 MB diverse \(language) (\(bigNS.length) units), \(bigSites.count) member positions\n"
            r += String(format: "open (language + index): %.0f ms; summary build (as the sliced background job would): %.0f ms\n",
                        openMs, buildMs)
            r += String(format: "a `.` before the summary is published: %.2f ms, popup %@ (no inference, usage path)\n",
                        early.firstKey, early.shown > 0 ? "shown" : "none")
            r += describe("10 MB \(language), after the summary is published", run, sites: bigSites.count)
            let (_, text) = owned(editor)
            r += "inference-owned: \(text); caps: statement LRU \(mb(SyntaxSubtreeCache.defaultByteLimit)), return cache "
                + "\(mb(TypeInferenceService.returnCacheBytes)), tables \(mb(ScriptTypeTables.typeCacheBytes)) + "
                + "\(mb(ScriptTypeTables.memberCacheBytes)) + \(mb(ScriptTypeTables.memberCacheBytes / 2)), store LRU "
                + "\(mb(TypeTableStore.defaultCacheByteLimit))\n"
            r += "malloc: open → summary \(mb(heap1 - heap0)), summary → after positions \(mb(heap2 - heap1)); "
                + "phys_footprint: \(mb(foot1 - foot0)), \(mb(foot2 - foot1))\n"
            if let s = editor.controller.typeInferenceForTesting?.statistics {
                r += "service: requests \(s.requests), inferred \(s.inferred), skipped (no summary) \(s.skippedLarge), "
                    + "aborted \(s.aborted), name-index builds \(s.nameIndexBuilds)\n\n"
            }
            editor.close()
        }

        print(r)
        let out = root.appendingPathComponent(".build/m17-baseline")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try r.write(to: out.appendingPathComponent("t1711c-bench-\(Self.config).txt"), atomically: true, encoding: .utf8)
    }
}
