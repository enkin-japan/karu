import AppKit
import Darwin
import Foundation
import Testing
@testable import KaruCore

// M17 T17.15a: keystroke → candidates on ~10 MB files when the declaration
// snapshot changes before every key (plan §11 "从按键提交到首批候选可见
// p95 ≤50 ms"). Opt-in: `KARU_T1715_BENCH=1 swift test -c release
// -Xswiftc -enable-testing --filter IndexRebuildBenchmark`. Prints a report
// and writes it to `.build/m17-baseline/t1715-index-bench-<config>.txt`;
// never fails on timings. Through a real `CompletionController`:
//   - Go and Swift (the T17.11d generator), Python and JavaScript (distinct
//     names per copy), ~10 MB each;
//   - identifier completion (two-unit prefix inside a function body) and,
//     for Go / Swift, the member operator with type inference (T17.11d);
//   - "steady": the snapshot is current and unchanged; "rescan": the
//     declarations are rescanned synchronously (untimed, `ensureDeclarations`)
//     right before every timed key, so every request sees a new snapshot and
//     nothing else ran in between; "pause": before every timed key the
//     pending analysis jobs run in their ~4 ms slices until none is left
//     (the debounced rescan publishes, and whatever follows it in the
//     analysis slices), as when the user pauses long enough for a rescan;
//   - the part of each key spent building the query index on the key (the
//     engine's own build, or the analysis finishing / building it).
// `KARU_T1715_KEYS=1` prints every timed key.

private let benchEnabled = ProcessInfo.processInfo.environment["KARU_T1715_BENCH"] != nil

private func summary(_ samples: [Double]) -> String {
    let s = samples.sorted()
    guard !s.isEmpty else { return "-" }
    let p50 = s[s.count / 2]
    let p95 = s[min(s.count - 1, Int((Double(s.count) * 0.95).rounded(.up)) - 1)]
    return String(format: "p50 %.2f  p95 %.2f  max %.2f ms (n=%d)", p50, p95, s.last!, s.count)
}

private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

/// A typing position: the end of a line inside a function body, the
/// indentation of the new line, and for member runs the receiver / operator.
private struct Position {
    let lineEnd: Int
    let indent: String
    let receiver: String
    let op: String
}

private enum Sources10MB {
    static let target = 10 * 1024 * 1024

    static func brace(_ language: String) -> String {
        var big = BraceBenchGenerator.header(language)
        var copy = 0
        while big.utf8.count < target {
            for i in 0..<BraceBenchGenerator.count {
                big += BraceBenchGenerator.block(language, i: i, j: (i + 1) % BraceBenchGenerator.count, p: "C\(copy)")
            }
            copy += 1
        }
        return big
    }

    static func python() -> String {
        var big = "import os\nfrom typing import Optional\n\n"
        var copy = 0
        while big.utf8.count < target {
            for i in 0..<48 {
                let c = "C\(copy)Model\(i)"
                big += """
                class \(c):
                    limit\(i) = 10

                    def __init__(self, ident\(i), title\(i)=None):
                        self.ident\(i) = ident\(i)
                        self.title\(i) = title\(i) or ""

                    def compute\(i)(self, value, scale=(1, 2)):
                        total\(i) = value * scale[0]
                        return total\(i)


                def use_c\(copy)_\(i)(input\(i), *rest\(i), **options\(i)):
                    local\(i) = \(c)(1)
                    value\(i) = local\(i).compute\(i)(2)
                    for item\(i) in rest\(i):
                        value\(i) += item\(i)
                    return value\(i)


                """
            }
            copy += 1
        }
        return big
    }

    static func javascript() -> String {
        var big = "'use strict';\n\n"
        var copy = 0
        while big.utf8.count < target {
            for i in 0..<48 {
                let c = "C\(copy)Model\(i)"
                big += """
                class \(c) {
                  constructor(ident\(i), title\(i)) {
                    this.ident\(i) = ident\(i);
                    this.title\(i) = title\(i) || '';
                  }
                  compute\(i)(value, scale = [1, 2]) {
                    const total\(i) = value * scale[0];
                    return total\(i);
                  }
                }

                function useC\(copy)_\(i)(input\(i), ...rest\(i)) {
                  const local\(i) = new \(c)(1);
                  let value\(i) = local\(i).compute\(i)(2);
                  for (const item\(i) of rest\(i)) {
                    value\(i) += item\(i);
                  }
                  return value\(i);
                }


                """
            }
            copy += 1
        }
        return big
    }

    /// `limit` positions spread over the document: ends of lines matching
    /// `pattern` (group 1 = indentation).
    static func positions(_ text: NSString, pattern: String, limit: Int = 24) -> [Position] {
        // swiftlint:disable:next force_try
        let regex = try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        let matches = regex.matches(in: text as String, range: NSRange(location: 0, length: text.length))
        let stride = max(1, matches.count / limit)
        var out: [Position] = []
        for (k, m) in matches.enumerated() where k % stride == 0 && out.count < limit {
            let lineEnd = NSMaxRange(text.lineRange(for: m.range)) - 1
            out.append(Position(lineEnd: lineEnd, indent: text.substring(with: m.range(at: 1)), receiver: "", op: ""))
        }
        return out
    }
}

@MainActor
private final class Editor {
    let center = NotificationCenter()
    let suite = "IndexRebuildBenchmark-\(UUID().uuidString)"
    let settings: ModuleSettings
    let textView: EditorTextView
    let window: NSWindow
    let hub = TextStorageObserverHub()
    let controller: CompletionController
    let language: String

    init(text: String, language: String) {
        self.language = language
        let defaults = TestDefaults.make(suite)
        settings = ModuleSettings(defaults: defaults, center: center)
        settings.setEnabled(true, for: .typeInference)
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

    func close() {
        controller.dismissCompletion()
        textView.textStorage?.delegate = nil
        window.close()
        UserDefaults().removePersistentDomain(forName: suite)
    }
}

private struct Run {
    var keys: [Double] = []
    var builds: [Double] = []
    var shown = 0
}

private enum Mode: String, CaseIterable {
    case steady = "steady snapshot"
    case rescan = "rescan right before the key"
    case pause = "pause (run loop idle) before the key"
}

/// Runs the pending analysis jobs in their real ~4 ms slices, as the run
/// loop would during a pause (a nested run loop inside a main-actor test
/// cannot drain the main queue): the debounced rescan publishes, and
/// whatever it schedules after publishing runs too.
@MainActor
private func idle(_ editor: Editor) {
    AnalysisScheduler.shared.runPendingJobsForTesting()
}

/// Types at every position: the untimed lead-in (`indent` + the receiver and
/// first operator unit, or the first prefix unit), an optional rescan, then
/// the timed key; restores the text afterwards.
@MainActor
private func exercise(_ editor: Editor, _ positions: [Position], mode: Mode, member: Bool) -> Run {
    var run = Run()
    let prefixes = ["in", "lo", "va", "co"]
    _ = editor.controller.analysis.ensureDeclarations()
    for (k, position) in positions.enumerated() { autoreleasepool {
        let storage = editor.textView.textStorage!
        let lead: String
        let timedKey: String
        if member {
            lead = position.receiver + (position.op.count == 2 ? String(position.op.first!) : "")
            timedKey = String(position.op.last!)
        } else {
            let prefix = prefixes[k % prefixes.count]
            lead = String(prefix.first!)
            timedKey = String(prefix.last!)
        }
        let inserted = "\n" + position.indent + lead
        storage.replaceCharacters(in: NSRange(location: position.lineEnd, length: 0), with: inserted)
        editor.textView.setSelectedRange(NSRange(location: position.lineEnd + (inserted as NSString).length, length: 0))
        switch mode {
        case .steady: break
        case .rescan: _ = editor.controller.analysis.ensureDeclarations()
        case .pause: idle(editor)
        }
        let builds = editor.controller.engineForTesting.indexBuilds
        let synchronous = editor.controller.analysis.queryIndexSynchronousBuilds
        run.keys.append(editor.key(timedKey))
        let engine = editor.controller.engineForTesting
        var built = engine.indexBuilds > builds ? Double(engine.lastIndexBuildNanoseconds) / 1e6 : 0
        let analysis = editor.controller.analysis
        if analysis.queryIndexSynchronousBuilds > synchronous { built += Double(analysis.lastQueryIndexSynchronousNanoseconds) / 1e6 }
        run.builds.append(built)
        if !editor.controller.currentCandidatesForTesting.isEmpty { run.shown += 1 }
        if ProcessInfo.processInfo.environment["KARU_T1715_KEYS"] != nil {
            print(String(format: "KEY %@ #%d at %d: %.2f ms (index %.2f)", editor.language, k, position.lineEnd,
                         run.keys.last!, run.builds.last!))
        }
        editor.controller.dismissCompletion()
        storage.replaceCharacters(in: NSRange(location: position.lineEnd, length: (inserted as NSString).length + 1),
                                  with: "")
    } }
    return run
}

@Suite("IndexRebuildBenchmark", .enabled(if: benchEnabled), .serialized)
@MainActor
struct IndexRebuildBenchmarkTests {
    #if DEBUG
    static let config = "debug"
    #else
    static let config = "release"
    #endif

    @Test func report() throws {
        var r = "# T17.15a index-rebuild benchmark (\(Self.config)) — \(Date())\n"
        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        r += String(format: "# load %.2f %.2f %.2f; %d cores\n\n", loads[0], loads[1], loads[2],
                    ProcessInfo.processInfo.activeProcessorCount)
        let cases: [(String, () -> String, String)] = [
            ("go", { Sources10MB.brace("go") }, #"^(\s*)// SITE "#),
            ("swift", { Sources10MB.brace("swift") }, #"^(\s*)// SITE "#),
            ("python", Sources10MB.python, #"^(\s*)local\d+ = "#),
            ("javascript", Sources10MB.javascript, #"^(\s*)const local\d+ = "#),
        ]
        for (language, make, pattern) in cases {
            let text = make()
            let ns = text as NSString
            // Descending positions: an edit never invalidates the checkpoints
            // the next position resumes from.
            let positions = Array(Sources10MB.positions(ns, pattern: pattern).reversed())
            let editor = Editor(text: text, language: language)
            r += "## \(language): \(ns.length) units, \(positions.count) positions\n"
            _ = exercise(editor, Array(positions.prefix(2)), mode: .steady, member: false)   // warm-up
            for mode in Mode.allCases {
                let run = exercise(editor, positions, mode: mode, member: false)
                r += "  identifier, \(mode.rawValue): " + summary(run.keys) + "; popups \(run.shown)/\(positions.count)\n"
                if mode != .steady { r += "    query-index build on the key: " + summary(run.builds) + "\n" }
            }
            if BraceLanguage(identifier: language) != nil {
                let sites = Array(BraceBenchGenerator.sites(ns, limit: 24).reversed()).map {
                    Position(lineEnd: $0.lineEnd, indent: $0.indent, receiver: $0.receiver, op: $0.op)
                }
                for mode in Mode.allCases {
                    let run = exercise(editor, sites, mode: mode, member: true)
                    r += "  member operator, \(mode.rawValue): " + summary(run.keys) + "; popups \(run.shown)/\(sites.count)\n"
                    if mode != .steady { r += "    query-index build on the key: " + summary(run.builds) + "\n" }
                }
            }
            editor.close()
        }
        print(r)
        let out = root.appendingPathComponent(".build/m17-baseline")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try r.write(to: out.appendingPathComponent("t1715-index-bench-\(Self.config).txt"), atomically: true,
                    encoding: .utf8)
    }
}
