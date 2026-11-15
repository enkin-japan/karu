import AppKit
import Darwin
import Foundation
import Testing
@testable import KaruCore

// M17 T17.15a — is the extra memory of popup rows that carry a detail
// (signature summary) transient or resident? Opt-in, one mode per process:
//
//     KARU_T1715_POPUP=detail|plain swift test -c release -Xswiftc -enable-testing \
//         --filter PopupMemoryBenchmark
//
// Drives the real `CompletionController` and its panel in an on-screen
// window and lets the run loop draw every popup (display cycle), at member
// positions whose rows carry inferred summaries (Python `str` / `list` /
// `dict` and a document class; 30–50 rows each). `plain` strips the details
// from the rows (`stripsRowDetailsForTesting`), everything else equal.
// Prints phys_footprint and malloc deltas against a settled baseline after
// a warm-up: the peak while popups are up, resident (settled) after the last
// popup closed, after `malloc_zone_pressure_relief`, and after a second
// batch (growth per popup or a plateau). Alternate the modes over several
// processes for a paired reading. Release builds need
// `KARU_TYPE_TABLES=$PWD/assets/typetables` (the builtin members).

private let mode = ProcessInfo.processInfo.environment["KARU_T1715_POPUP"]

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

private func mb(_ bytes: Int) -> String { String(format: "%+.2f MB", Double(bytes) / 1_048_576) }

/// Yields the main actor so the main run loop turns (display cycle, main
/// queue) for `seconds`; a nested run loop inside a main-actor test would not
/// drain the main queue.
@MainActor
private func spin(_ seconds: TimeInterval) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
}

/// Waits until phys_footprint has stayed within 0.25 MB for 2 s (sampled
/// every 0.25 s, at most 20 s) and returns it — a settled reading, as
/// `scripts/mem-benchmark.sh` takes (window backing stores and other
/// process state move by tens of MB shortly after windows appear).
@MainActor
private func settledFootprint() async -> Int {
    var samples: [Int] = []
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
        await spin(0.25)
        samples.append(footprint())
        let recent = samples.suffix(8)
        if recent.count == 8, recent.max()! - recent.min()! <= 256 * 1024 { return recent.last! }
    }
    return samples.last ?? footprint()
}

@Suite("PopupMemoryBenchmark", .enabled(if: mode != nil), .serialized)
@MainActor
struct PopupMemoryBenchmarkTests {
    static let source: String = {
        var out = "class Ledger:\n"
        for i in 0..<40 {
            out += "    def entry_\(i)(self, amount: float, note: str = \"\", *, tag: int = \(i)) -> list[str]:\n"
            out += "        return [note]\n"
        }
        out += "\n\ndef work(ledger: Ledger, title: str, items: list[int], table: dict[str, int]):\n"
        for k in 0..<32 { out += "    pass  # site \(k)\n" }
        return out
    }()

    @Test func popupMemory() async throws {
        let detail = mode == "detail"
        let rounds = Int(ProcessInfo.processInfo.environment["KARU_T1715_POPUP_ROUNDS"] ?? "") ?? 48
        let name = "PopupMemoryBenchmark-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults().removePersistentDomain(forName: name) }
        let center = NotificationCenter()
        let settings = ModuleSettings(defaults: defaults, center: center)
        let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let scroll = NSScrollView(frame: frame)
        let textView = EditorTextView(frame: frame)
        textView.isRichText = false
        textView.allowsUndo = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        scroll.documentView = textView
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 800, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        textView.string = Self.source
        let hub = TextStorageObserverHub()
        textView.textStorage?.delegate = hub
        let controller = CompletionController(textView: textView, moduleSettings: settings, moduleCenter: center,
                                              scheduler: AnalysisScheduler())
        hub.add(controller)
        textView.completionKeyHandler = controller
        controller.stripsRowDetailsForTesting = !detail
        controller.labelLanguageOverride = .en
        controller.setLanguage(identifier: "python")
        controller.indexDocument()
        window.orderFront(nil)
        window.makeFirstResponder(textView)

        let ns = Self.source as NSString
        var sites: [Int] = []
        var search = NSRange(location: 0, length: ns.length)
        while true {
            let r = ns.range(of: "  # site ", options: [], range: search)
            if r.location == NSNotFound { break }
            sites.append(NSMaxRange(ns.lineRange(for: r)) - 1)
            search = NSRange(location: NSMaxRange(r), length: ns.length - NSMaxRange(r))
        }
        sites.reverse()
        let receivers: [(String, String)] = [("title", "s"), ("items", "c"), ("table", "g"), ("ledger", "e"),
                                             ("title", "r"), ("items", "p")]
        func key(_ k: String) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, characters: k,
                                         charactersIgnoringModifiers: k, isARepeat: false, keyCode: 0)!
            textView.insertText(k, replacementRange: NSRange(location: NSNotFound, length: 0))
            controller.textViewDidInsertKey(event)
        }
        var rowsShown = 0
        var popups = 0
        var detailRows = 0
        var peak = 0
        func popup(_ k: Int) async {
            do {
                let site = sites[k % sites.count]
                let (receiver, next) = receivers[k % receivers.count]
                let storage = textView.textStorage!
                let lead = "\n    " + receiver
                storage.replaceCharacters(in: NSRange(location: site, length: 0), with: lead)
                textView.setSelectedRange(NSRange(location: site + (lead as NSString).length, length: 0))
                key(".")
                await spin(0.03)                                 // the display cycle draws the popup
                controller.panelForTesting?.display()             // and certainly once
                let shown = controller.currentCandidatesForTesting
                if !shown.isEmpty { popups += 1 }
                rowsShown += shown.count
                detailRows += shown.filter { $0.detail != nil }.count
                // Scroll the list: draws the rows below the first ten.
                if let table = controller.panelForTesting.flatMap({ ($0.contentView as? NSScrollView)?.documentView as? NSTableView }) {
                    table.scrollRowToVisible(max(0, table.numberOfRows - 1))
                    controller.panelForTesting?.display()
                    await spin(0.02)
                }
                peak = max(peak, footprint())
                key(next)
                await spin(0.02)
                peak = max(peak, footprint())
                controller.dismissCompletion()
                storage.replaceCharacters(in: NSRange(location: site, length: (lead as NSString).length + 2), with: "")
                await spin(0.01)
            }
        }
        // Warm-up: one-time process state (type tables, fonts, the first panel).
        for k in 0..<8 { await popup(k) }
        let f0 = await settledFootprint(), m0 = mallocInUse()
        peak = f0
        let t0 = Date()
        for k in 0..<rounds { await popup(k) }
        let elapsed = Date().timeIntervalSince(t0)
        let f1 = await settledFootprint(), m1 = mallocInUse()
        malloc_zone_pressure_relief(nil, 0)
        let f2 = await settledFootprint()
        // A second batch: does it keep growing (resident per popup) or plateau?
        for k in 0..<rounds { await popup(k) }
        let f3 = await settledFootprint(), m3 = mallocInUse()
        print(String(format: "[T17.15a popup] mode %@: %d popups, %.1f rows avg (%d with detail), %.2f s; "
                     + "footprint peak %@, resident %@ (after pressure relief %@), after a second batch %@; "
                     + "malloc in use %@, after second batch %@",
                     detail ? "detail" : "plain", popups, Double(rowsShown) / Double(max(popups, 1)), detailRows,
                     elapsed, mb(peak - f0), mb(f1 - f0), mb(f2 - f0), mb(f3 - f0), mb(m1 - m0), mb(m3 - m0)))
        #expect(popups >= 2 * rounds + 8)
        controller.dismissCompletion()
        textView.textStorage?.delegate = nil
        window.close()
    }
}
