import AppKit
import Darwin
import Foundation
import Testing
@testable import KaruCore

// M17 T17.15b — real-window acceptance readings (plan §11 「输入与滚动」「压力测试」).
// Measurement only, opt-in, run alone:
//
//     KARU_TYPE_TABLES=$PWD/assets/typetables KARU_PERFLOG=<log.tsv> \
//     KARU_T1715B_FILES=<abs path>[:<abs path>…] KARU_T1715B_OUT=<report.txt> \
//       swift test -c release -Xswiftc -enable-testing --filter M17AcceptanceBenchmark
//
// Each file is copied to a temporary directory and opened in a real
// `EditorWindowController` (800×600, on screen, isolated session / draft
// stores). Phases, each with its synchronous main-thread wall time, the
// longest main-thread stall (a 1 ms main-run-loop heartbeat; a gap is time the
// run loop did not turn), the phys_footprint peak (sampled every 5 ms off the
// main thread) and the settled footprint, all relative to the settled
// footprint before the window opened:
//   open (load + first display) → idle; first manual invoke (⌥⎋ path, caret
//   inside an identifier near the top); first jump to the end; sustained
//   typing (identifier lines, key by key at ~40 keys/s through the key
//   handler); three top↔bottom scroll round trips (30 steps each way); the
//   highlight / completion / type-inference / cross-file modules off;
//   `malloc_zone_pressure_relief`; window closed; the modules switched back on
//   (a closed window must not react). Settled malloc in use is printed too. `KARU_T1715B_PAIR=<a>:<b>` instead opens an empty window, then a,
//   then b side by side (state that multiplies with windows). Phase start /
//   end uptimes are printed so a `KARU_PERFLOG` log can be sliced per phase.
// Module switches go to the test runner's own defaults domain and are removed
// afterwards. Never asserts on timings.

private let env = ProcessInfo.processInfo.environment
private let filesEnv = env["KARU_T1715B_FILES"]
private let pairEnv = env["KARU_T1715B_PAIR"]
private let outEnv = env["KARU_T1715B_OUT"]
/// T17.15d-A: also list every main-thread gap over 20 ms with its end uptime
/// (to match it against `KARU_PERFLOG` events).
private let gapLogEnv = env["KARU_T1715B_GAPLOG"] != nil

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

private func mb(_ bytes: Int) -> String { String(format: "%+.1f", Double(bytes) / 1_048_576) }
private func ms(_ seconds: Double) -> String { String(format: "%.1f", seconds * 1000) }
private func now() -> Double { ProcessInfo.processInfo.systemUptime }

@MainActor
private func spin(_ seconds: TimeInterval) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
}

/// Peak phys_footprint, sampled every 5 ms on a utility queue.
private final class PeakSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak = 0
    private let timer: DispatchSourceTimer

    init() {
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "t1715b.peak", qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            let f = footprint()
            guard let self else { return }
            self.lock.lock(); if f > self.peak { self.peak = f }; self.lock.unlock()
        }
        timer.resume()
    }
    func reset() { lock.lock(); peak = footprint(); lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return peak }
    func stop() { timer.cancel() }
}

/// Longest gap between 1 ms main-run-loop heartbeats since `reset()`.
@MainActor
private final class MainGapMeter {
    private var last = now()
    private(set) var maxGap = 0.0
    /// Gaps over 20 ms (end uptime, length) when `KARU_T1715B_GAPLOG` is set.
    private(set) var longGaps: [(end: Double, gap: Double)] = []
    private var timer: Timer?

    init() {
        let t = Timer(timeInterval: 0.001, repeats: true) { _ in
            MainActor.assumeIsolated { self.beat() }
        }
        t.tolerance = 0
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
    private func beat() {
        let n = now()
        maxGap = max(maxGap, n - last)
        if gapLogEnv, n - last > 0.020 { longGaps.append((n, n - last)) }
        last = n
    }
    func reset() { last = now(); maxGap = 0; longGaps = [] }
    /// Includes a stretch still running (a synchronous call that just returned).
    func read() -> Double { max(maxGap, now() - last) }
    func stop() { timer?.invalidate() }
}

/// Settled footprint: within 0.25 MB for 2 s (0.25 s samples, ≤ 20 s).
@MainActor
private func settled() async -> (bytes: Int, seconds: Double, stable: Bool) {
    var samples: [Int] = []
    let start = now()
    while now() - start < 20 {
        await spin(0.25)
        samples.append(footprint())
        let recent = samples.suffix(8)
        if recent.count == 8, recent.max()! - recent.min()! <= 256 * 1024 { return (recent.last!, now() - start, true) }
    }
    return (samples.last ?? footprint(), now() - start, false)
}

@MainActor
private final class Run {
    let peak = PeakSampler()
    let gap = MainGapMeter()
    var report = ""
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("t1715b-\(UUID().uuidString)")
    let suite = "M17AcceptanceBenchmark-\(UUID().uuidString)"

    init() {
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    func line(_ s: String) { report += s + "\n"; print(s) }

    func open(_ path: String?) -> EditorWindowController {
        let controller = EditorWindowController()
        controller.sessionStore = SessionStore(defaults: UserDefaults(suiteName: suite)!)
        controller.draftStore = DraftStore(directory: tmp.appendingPathComponent("Drafts"))
        controller.showWindow(nil)
        if let path {
            let copy = tmp.appendingPathComponent(UUID().uuidString + "-" + (path as NSString).lastPathComponent)
            try? FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: copy)
            controller.load(url: copy)
        }
        controller.window?.displayIfNeeded()
        return controller
    }

    /// Runs `body`, then waits until the footprint settles; reports the phase.
    var mallocBase = 0

    func phase(_ name: String, base: Int, _ body: () async -> String) async {
        peak.reset(); gap.reset()
        let t0 = now()
        let detail = await body()
        let gapNow = gap.read()
        let s = await settled()
        line("phase \(name)\tstart_uptime \(String(format: "%.3f", t0))\tend_uptime \(String(format: "%.3f", now()))\t"
             + "\(detail)\tmaxMainStall_ms \(ms(max(gapNow, gap.read())))\tpeak_MB \(mb(peak.value - base))\t"
             + "settled_MB \(mb(s.bytes - base))\tmalloc_MB \(mb(mallocInUse() - mallocBase))\tsettledAfter_s \(String(format: "%.1f", s.seconds))\(s.stable ? "" : " UNSTABLE")")
        if gapLogEnv, !gap.longGaps.isEmpty {
            line("gaps \(name)\t" + gap.longGaps.map { String(format: "%.3f:%.1f", $0.end, $0.gap * 1000) }
                .joined(separator: " "))
        }
    }

    func cleanup() {
        peak.stop(); gap.stop()
        let modules = UserDefaults.standard
        for module in [FeatureModule.highlight, .completion, .typeInference, .crossFileIndex] {
            modules.removeObject(forKey: "module.\(module.rawValue).enabled")
        }
        UserDefaults().removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: tmp)
    }
}

@MainActor
private func keyEvent(_ k: String, window: NSWindow?) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                     windowNumber: window?.windowNumber ?? 0, context: nil, characters: k,
                     charactersIgnoringModifiers: k, isARepeat: false, keyCode: 0)!
}

private func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return .nan }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, max(0, Int((p / 100 * Double(sorted.count)).rounded(.up)) - 1))]
}

/// Identifiers (≥ 4 units) in the first 64 KB, most frequent first.
private func identifiers(in text: NSString) -> [String] {
    let head = text.substring(to: min(text.length, 65_536))
    // swiftlint:disable:next force_try
    let regex = try! NSRegularExpression(pattern: "[A-Za-z_][A-Za-z0-9_]{3,}")
    var counts: [String: Int] = [:]
    for m in regex.matches(in: head, range: NSRange(location: 0, length: (head as NSString).length)) {
        counts[(head as NSString).substring(with: m.range), default: 0] += 1
    }
    let skip: Set<String> = ["true", "false", "null", "None", "True", "False", "return", "import", "from", "const",
                             "class", "function", "export", "def", "self", "this", "string", "number"]
    return counts.filter { !skip.contains($0.key) }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        .map(\.key)
}

@Suite("M17AcceptanceBenchmark", .enabled(if: filesEnv != nil || pairEnv != nil), .serialized)
@MainActor
struct M17AcceptanceBenchmarkTests {
    @Test func acceptance() async throws {
        let run = Run()
        defer { run.cleanup() }
        run.line("# M17 T17.15b acceptance — \(Date()) — \(ProcessInfo.processInfo.operatingSystemVersionString)")
        // Warm-up: one-time process state (fonts, first window, type tables).
        let warm = run.open(nil)
        await spin(1)
        warm.close()
        await spin(0.5)

        if let pairEnv {
            let paths = pairEnv.split(separator: ":").map(String.init)
            let base = await settled().bytes
            var windows: [EditorWindowController] = []
            await run.phase("pair.emptyWindow", base: base) { windows.append(run.open(nil)); return "-" }
            for (k, path) in paths.enumerated() {
                await run.phase("pair.open\(k + 1) \((path as NSString).lastPathComponent)", base: base) {
                    let t = now()
                    let c = run.open(path)
                    c.window?.setFrameOrigin(NSPoint(x: 60 + 120 * k, y: 60 + 40 * k))
                    windows.append(c)
                    return "sync_ms \(ms(now() - t))"
                }
            }
            await run.phase("pair.closeAll", base: base) { for w in windows { w.close() }; return "-" }
        }

        for path in (filesEnv ?? "").split(separator: ":").map(String.init) where !path.isEmpty {
            run.line("\n## \(path) (\((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0) bytes)")
            let base = await settled().bytes
            run.mallocBase = mallocInUse()
            var controller: EditorWindowController!
            await run.phase("open", base: base) {
                let t = now()
                controller = run.open(path)
                return "sync_ms \(ms(now() - t))"
            }
            // The phases up to the pressure relief hold the text view, window and
            // completion controller in locals; the scope ends before "closed" so
            // nothing here keeps the closed window alive.
            do {
            let textView = controller.textViewForTesting
            let window = controller.window
            let handler = (textView as? EditorTextView)?.completionKeyHandler
            let text = textView.string as NSString
            let names = identifiers(in: text)

            // First manual invoke: caret two units into an identifier near the top.
            await run.phase("manualInvoke", base: base) {
                guard let name = names.first else { return "no identifier" }
                let r = text.range(of: name)
                textView.setSelectedRange(NSRange(location: r.location + 2, length: 0))
                textView.scrollRangeToVisible(textView.selectedRange())
                window?.displayIfNeeded()
                let t = now()
                handler?.requestManualCompletion()
                let sync = now() - t
                let shown = (handler as? CompletionController)?.currentSuggestionsForTesting.count ?? -1
                window?.displayIfNeeded()
                await spin(0.3)
                handler?.dismissCompletion()
                return "sync_ms \(ms(sync))\tprefix \(name.prefix(2))\tshown \(shown)"
            }

            // First jump to the end.
            await run.phase("jumpToEnd", base: base) {
                let t = now()
                let end = (textView.string as NSString).length
                textView.setSelectedRange(NSRange(location: end, length: 0))
                textView.scrollRangeToVisible(NSRange(location: end, length: 0))
                window?.displayIfNeeded()
                return "sync_ms \(ms(now() - t))"
            }

            // Sustained typing at the end: identifier lines from the document.
            await run.phase("typing", base: base) {
                var keys: [Double] = []
                var popups = 0
                var script = "\n"
                for k in 0..<10 {
                    let a = names.isEmpty ? "value" : names[k % names.count]
                    let b = names.count > 1 ? names[(k + 1) % names.count] : "item"
                    script += "\(a.prefix(3))x_\(k) = \(b.prefix(4))\n"
                }
                let typingStart = now()
                for ch in script {
                    let k = String(ch)
                    let t = now()
                    textView.insertText(k, replacementRange: NSRange(location: NSNotFound, length: 0))
                    if k != "\n" { handler?.textViewDidInsertKey(keyEvent(k, window: window)) }
                    window?.displayIfNeeded()
                    keys.append(now() - t)
                    if !((handler as? CompletionController)?.currentSuggestionsForTesting.isEmpty ?? true) { popups += 1 }
                    await spin(0.025)
                }
                handler?.dismissCompletion()
                return "keys \(keys.count)\tpopupKeys \(popups)\tkey_p50_ms \(ms(percentile(keys, 50)))\t"
                    + "key_p95_ms \(ms(percentile(keys, 95)))\tkey_max_ms \(ms(keys.max() ?? 0))\t"
                    + "typing_s \(String(format: "%.1f", now() - typingStart))"
            }

            // Three top ↔ bottom round trips, 30 steps each way.
            await run.phase("scroll3x", base: base) {
                guard let scrollView = textView.enclosingScrollView else { return "no scroll view" }
                let clip = scrollView.contentView
                var steps: [Double] = []
                for _ in 0..<3 {
                    for down in [true, false] {
                        for s in 1...30 {
                            let maxY = max(0, textView.frame.height - clip.bounds.height)
                            let y = maxY * Double(down ? s : 30 - s) / 30
                            let t = now()
                            clip.scroll(to: NSPoint(x: 0, y: y))
                            scrollView.reflectScrolledClipView(clip)
                            window?.displayIfNeeded()
                            steps.append(now() - t)
                            await spin(0.016)
                        }
                    }
                }
                return "steps \(steps.count)\tstep_p50_ms \(ms(percentile(steps, 50)))\t"
                    + "step_p95_ms \(ms(percentile(steps, 95)))\tstep_max_ms \(ms(steps.max() ?? 0))"
            }

            await run.phase("modulesOff", base: base) {
                let modules = ModuleSettings()
                for module in [FeatureModule.highlight, .completion, .typeInference, .crossFileIndex] {
                    modules.setEnabled(false, for: module)
                }
                return "-"
            }
            await run.phase("pressureRelief", base: base) {
                malloc_zone_pressure_relief(nil, 0)
                return "-"
            }
            }
            await run.phase("closed", base: base) {
                controller.close()
                controller = nil
                return "-"
            }
            // A closed window must not react to module switches any more: any
            // analysis / highlight events in this phase come from a window that
            // outlived its close.
            await run.phase("modulesOnAfterClose", base: base) {
                let modules = ModuleSettings()
                for module in [FeatureModule.highlight, .completion, .typeInference, .crossFileIndex] {
                    modules.setEnabled(true, for: module)
                }
                return "-"
            }
        }

        if let outEnv { try run.report.write(toFile: outEnv, atomically: true, encoding: .utf8) }
    }
}
