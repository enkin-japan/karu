import AppKit
import Darwin
import Foundation
import Testing
@testable import KaruCore

// M17 T17.11d static-language inference benchmark (plan §8.3 / §11).
// Opt-in: `KARU_T1711D_BENCH=1 swift test --filter BraceInferenceBenchmark`
// (also `-c release -Xswiftc -enable-testing`). Prints a report and writes
// it to `.build/m17-baseline/t1711d-bench-<config>.txt`; never fails on
// timings. Through a real `CompletionController`:
//   - generated ~1000-line files with distinct names for Swift, Go, Rust,
//     Java, C#, C and C++ (types with fields, methods, extensions / impls /
//     out-of-class definitions, functions with typed parameters and
//     locals); at ≥ 24 positions a receiver is typed on a new line, then
//     the access operator (`.` / `->` / `::`, timed: keystroke → member
//     candidates) and two more keys; the inference part separately;
//     "fresh" runs rescan the declarations before each operator (as the
//     background job would after a pause, so every request starts a new
//     model), "steady" runs keep the snapshot;
//   - ~10 MB Go and Swift files built from the same generators;
//   - inference-owned bytes, and paired memory with type inference off / on.

private let benchEnabled = ProcessInfo.processInfo.environment["KARU_T1711D_BENCH"] != nil

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
private func kb(_ bytes: Int) -> String { String(format: "%.1f KB", Double(bytes) / 1024) }

private func summary(_ samples: [Double]) -> String {
    let s = samples.sorted()
    guard !s.isEmpty else { return "-" }
    let p50 = s[s.count / 2]
    let p95 = s[min(s.count - 1, Int((Double(s.count) * 0.95).rounded(.up)) - 1)]
    return String(format: "p50 %.2f  p95 %.2f  max %.2f ms (n=%d)", p50, p95, s.last!, s.count)
}

private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

/// A member position: the offset of the end of a `SITE` marker line, the
/// indentation, the receiver text and the access operator.
struct BraceBenchSite {
    let lineEnd: Int
    let indent: String
    let receiver: String
    let op: String
}

private typealias Site = BraceBenchSite
private typealias Generator = BraceBenchGenerator

/// Generated sources with distinct names (`p` is a copy prefix for 10 MB
/// files); shared with the T17.15 index-rebuild benchmark.
enum BraceBenchGenerator {
    static let count = 48

    static func source(_ language: String, types n: Int = count, prefix p: String = "") -> String {
        var out = header(language)
        for i in 0..<n {
            let j = (i + 1) % n
            out += block(language, i: i, j: j, p: p)
        }
        return out
    }

    static func header(_ language: String) -> String {
        switch language {
        case "go": return "package bench\n\nimport \"fmt\"\n\n"
        case "java": return "import java.util.*;\n\n"
        case "csharp": return "using System;\nnamespace Bench\n{\n"
        case "c": return "#include <stdio.h>\n#include <stdlib.h>\n\n"
        case "cpp": return "#include <memory>\n#include <string>\n\n"
        default: return ""
        }
    }

    static func footer(_ language: String) -> String { language == "csharp" ? "}\n" : "" }

    // swiftlint:disable:next function_body_length
    static func block(_ language: String, i: Int, j: Int, p: String) -> String {
        let m = "\(p)Model\(i)", n = "\(p)Model\(j)"
        switch language {
        case "swift":
            return """
            final class \(m) {
                var ident\(i): Int = 0
                var title\(i): String = ""
                var link\(i): \(n)
                private var cache\(i): [Int] = []
                static let shared\(i) = 0
                init(link: \(n)) { self.link\(i) = link }
                func compute\(i)(value: Int, scale: Double) -> Int { return value }
                func neighbour\(i)() -> \(n) { return link\(i) }
            }

            extension \(m) {
                func describe\(i)() -> String { return title\(i) }
            }

            func use\(m)(input\(i): \(m)) {
                let local\(i): \(n) = input\(i).neighbour\(i)()
                let total\(i) = input\(i).compute\(i)(value: 1, scale: 2)
                print(local\(i), total\(i))
                // SITE input\(i) .
                // SITE local\(i) .
                // SITE input\(i).link\(i) .
                // SITE \(m) .
            }


            """
        case "go":
            return """
            type \(m) struct {
            \tIdent\(i) int
            \tTitle\(i) string
            \tLink\(i)  *\(n)
            }

            func (m *\(m)) Compute\(i)(value int, scale float64) int { return value }
            func (m *\(m)) Neighbour\(i)() *\(n) { return m.Link\(i) }
            func (m \(m)) Describe\(i)() string { return m.Title\(i) }

            func New\(m)() *\(m) { return &\(m){} }

            func use\(m)(input\(i) *\(m)) {
            \tlocal\(i) := New\(n)()
            \tvalue\(i) := \(m){Ident\(i): 1}
            \tfmt.Println(local\(i), value\(i))
            \t// SITE input\(i) .
            \t// SITE local\(i) .
            \t// SITE value\(i) .
            \t// SITE input\(i).Link\(i) .
            }


            """
        case "rust":
            let ms = "\(p)model\(i)"
            return """
            pub struct \(m) {
                pub ident\(i): i64,
                pub title\(i): String,
                pub link\(i): Box<\(n)>,
                cache\(i): Vec<i64>,
            }

            impl \(m) {
                pub const LIMIT\(i): i64 = 10;
                pub fn new() -> Self { todo!() }
                pub fn compute\(i)(&self, value: i64, scale: f64) -> i64 { value }
                pub fn neighbour\(i)(&self) -> &\(n) { &self.link\(i) }
            }

            fn use_\(ms)(input\(i): &\(m)) {
                let local\(i) = \(n)::new();
                let total\(i): i64 = input\(i).compute\(i)(1, 2.0);
                // SITE input\(i) .
                // SITE local\(i) .
                // SITE input\(i).link\(i) .
                // SITE \(m) ::
            }


            """
        case "java":
            return """
            class \(m) {
                int ident\(i);
                String title\(i);
                \(n) link\(i);
                private int cache\(i);
                static int created\(i);
                int compute\(i)(int value, double scale) { return value; }
                \(n) neighbour\(i)() { return link\(i); }
            }

            class User\(p)\(i) {
                void use(\(m) input\(i)) {
                    \(n) local\(i) = input\(i).neighbour\(i)();
                    var fresh\(i) = new \(m)();
                    // SITE input\(i) .
                    // SITE local\(i) .
                    // SITE fresh\(i) .
                    // SITE \(m) .
                }
            }


            """
        case "csharp":
            return """
                public class \(m)
                {
                    public int Ident\(i);
                    public string Title\(i) { get; set; }
                    public \(n) Link\(i) { get; set; }
                    private int cache\(i);
                    public static int Created\(i);
                    public int Compute\(i)(int value, double scale) { return value; }
                    public \(n) Neighbour\(i)() { return Link\(i); }
                }

                public class User\(p)\(i)
                {
                    public void Use(\(m) input\(i))
                    {
                        \(n) local\(i) = input\(i).Neighbour\(i)();
                        var fresh\(i) = new \(m)();
                        // SITE input\(i) .
                        // SITE local\(i) .
                        // SITE fresh\(i) .
                        // SITE input\(i).Link\(i) .
                    }
                }


            """
        case "c":
            let s = "\(p)model\(i)", t = "\(p)model\(j)"
            return """
            struct \(s) {
                int ident\(i);
                const char *title\(i);
                struct \(t) *link\(i);
                double weight\(i);
            };
            typedef struct \(s) \(m);

            int compute\(i)(\(m) *m, int value) { return value + m->ident\(i); }

            void use_\(s)(\(m) *input\(i)) {
                struct \(s) local\(i);
                local\(i).ident\(i) = compute\(i)(input\(i), 1);
                /* SITE input\(i) -> */
                /* SITE local\(i) . */
                /* SITE input\(i)->link\(i) -> */
                /* SITE local\(i) . */
            }


            """
        case "cpp":
            return """
            class \(m) {
            public:
                int ident\(i);
                std::string title\(i);
                \(n)* link\(i);
                int compute\(i)(int value, double scale) const;
                \(n)* neighbour\(i)() const;
                static \(m) make\(i)();
            private:
                int cache\(i);
            };

            int \(m)::compute\(i)(int value, double scale) const { return value + cache\(i); }

            void use\(m)(const \(m)& input\(i)) {
                auto local\(i) = std::make_unique<\(n)>();
                \(m) plain\(i);
                // SITE input\(i) .
                // SITE local\(i) ->
                // SITE input\(i).link\(i) ->
                // SITE \(m) ::
            }


            """
        default:
            return ""
        }
    }

    /// The `SITE` markers of `text`, every `stride`-th one.
    static func sites(_ text: NSString, limit: Int = 24, from: Int = 0) -> [BraceBenchSite] {
        // swiftlint:disable:next force_try
        let regex = try! NSRegularExpression(pattern: #"^(\s*)(?://|/\*) SITE (\S+) (\S+)"#, options: [.anchorsMatchLines])
        let matches = regex.matches(in: text as String, range: NSRange(location: from, length: text.length - from))
        guard !matches.isEmpty else { return [] }
        let stride = max(1, matches.count / limit)
        var out: [BraceBenchSite] = []
        for (k, m) in matches.enumerated() where k % stride == 0 && out.count < limit {
            let lineEnd = NSMaxRange(text.lineRange(for: m.range)) - 1
            out.append(BraceBenchSite(lineEnd: lineEnd, indent: text.substring(with: m.range(at: 1)),
                            receiver: text.substring(with: m.range(at: 2)), op: text.substring(with: m.range(at: 3))))
        }
        return out
    }
}

@MainActor
private final class Editor {
    let center = NotificationCenter()
    let suite = "BraceInferenceBenchmark-\(UUID().uuidString)"
    let settings: ModuleSettings
    let textView: EditorTextView
    let window: NSWindow
    let hub = TextStorageObserverHub()
    let controller: CompletionController
    let language: String

    init(text: String, language: String, typeInference: Bool) {
        self.language = language
        let defaults = UserDefaults(suiteName: suite)!
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
    var opKeys: [Double] = []
    var inference: [Double] = []
    var nextKeys: [Double] = []
    var inferred = 0
    var shown = 0
}

@MainActor
private func exercise(_ editor: Editor, sites: [Site], fresh: Bool, prefixes: [String] = ["co", "ne", "id", "ti"]) -> Run {
    var run = Run()
    // The background declaration job would have published the current text
    // during the pause before this run (untimed; also keeps the edit journal
    // mappable — the harness never spins the run loop).
    _ = editor.controller.analysis.ensureDeclarations()
    for (k, site) in sites.enumerated() { autoreleasepool {
        let storage = editor.textView.textStorage!
        let inserted = "\n" + site.indent + site.receiver + (site.op.count == 2 ? String(site.op.first!) : "")
        storage.replaceCharacters(in: NSRange(location: site.lineEnd, length: 0), with: inserted)
        editor.textView.setSelectedRange(NSRange(location: site.lineEnd + (inserted as NSString).length, length: 0))
        if fresh { _ = editor.controller.analysis.ensureDeclarations() }
        let t = editor.key(String(site.op.last!))
        run.opKeys.append(t)
        run.inference.append(editor.inferenceMilliseconds)
        let candidates = editor.controller.currentCandidatesForTesting
        if !candidates.isEmpty { run.shown += 1 }
        if candidates.first?.source == .inferredType { run.inferred += 1 }
        if ProcessInfo.processInfo.environment["KARU_T1711D_SITES"] != nil {
            print("SITE \(site.receiver)\(site.op) -> \(candidates.prefix(6).map(\.name)) \(candidates.first.map { "\($0.source)" } ?? "none")")
        }
        let prefix = prefixes[k % prefixes.count]
        for ch in prefix { run.nextKeys.append(editor.key(String(ch))) }
        editor.controller.dismissCompletion()
        let typed = 1 + prefix.utf16.count
        storage.replaceCharacters(in: NSRange(location: site.lineEnd, length: (inserted as NSString).length + typed),
                                  with: "")
    } }
    return run
}

private func describe(_ label: String, _ run: Run, sites: Int) -> String {
    var r = "  \(label): operator key " + summary(run.opKeys) + "\n"
    r += "    inference part: " + summary(run.inference) + "\n"
    r += "    keys after the operator (members reused): " + summary(run.nextKeys) + "\n"
    r += "    positions with a popup \(run.shown)/\(sites); inferred members first \(run.inferred)/\(sites)\n"
    return r
}

@Suite("BraceInferenceBenchmark", .enabled(if: benchEnabled), .serialized)
@MainActor
struct BraceInferenceBenchmarkTests {
    #if DEBUG
    static let config = "debug"
    #else
    static let config = "release"
    #endif

    static let languages = ["swift", "go", "rust", "java", "csharp", "c", "cpp"]

    @Test func report() throws {
        var r = "# T17.11d static-language inference benchmark (\(Self.config)) — \(Date())\n"
        r += "# host: \(ProcessInfo.processInfo.operatingSystemVersionString), "
        r += "\(ProcessInfo.processInfo.activeProcessorCount) cores; load "
        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        r += String(format: "%.2f %.2f %.2f\n\n", loads[0], loads[1], loads[2])

        r += "## ~1000-line files (distinct names)\n"
        for language in Self.languages {
            let source = Generator.source(language) + Generator.footer(language)
            let ns = source as NSString
            let lines = source.split(separator: "\n", omittingEmptySubsequences: false).count
            let sites = Array(Generator.sites(ns).reversed())
            let editor = Editor(text: source, language: language, typeInference: true)
            editor.open()
            r += "### \(language): \(lines) lines, \(ns.length) units, \(sites.count) positions\n"
            let fresh = exercise(editor, sites: sites, fresh: true)
            r += describe("fresh model per operator", fresh, sites: sites.count)
            let steady = exercise(editor, sites: sites, fresh: false)
            r += describe("steady snapshot", steady, sites: sites.count)
            let owned = editor.controller.typeInferenceForTesting?.retainedBytes ?? 0
            r += "    inference-owned after the runs: \(kb(owned))\n"
            editor.close()
        }

        // Paired memory, Swift and Go samples: the same positions off → on.
        r += "\n## Memory (paired off → on, same positions, twice)\n"
        for language in ["swift", "go", "java", "cpp"] {
            let source = Generator.source(language) + Generator.footer(language)
            let sites = Array(Generator.sites(source as NSString).reversed())
            let editor = Editor(text: source, language: language, typeInference: false)
            editor.open()
            _ = exercise(editor, sites: sites, fresh: false)
            var heap: [Int] = []
            var foot: [Int] = []
            var owned = 0
            var released = true
            for _ in 0..<2 {
                _ = exercise(editor, sites: sites, fresh: false)
                let h0 = mallocInUse(), f0 = footprint()
                editor.settings.setEnabled(true, for: .typeInference)
                _ = exercise(editor, sites: sites, fresh: false)
                heap.append(mallocInUse() - h0)
                foot.append(footprint() - f0)
                owned = editor.controller.typeInferenceForTesting?.retainedBytes ?? 0
                editor.settings.setEnabled(false, for: .typeInference)
                released = released && editor.controller.isInferenceStateReleased
            }
            r += "\(language): malloc \(heap.map(mb).joined(separator: ", ")); phys_footprint "
                + "\(foot.map(mb).joined(separator: ", ")); inference-owned while on \(kb(owned)); "
                + "released when off: \(released)\n"
            editor.close()
        }

        // ~10 MB Go and Swift.
        r += "\n## ~10 MB files\n"
        for language in ["go", "swift"] {
            var big = Generator.header(language)
            var copy = 0
            while big.utf8.count < 10 * 1024 * 1024 {
                for i in 0..<Generator.count {
                    big += Generator.block(language, i: i, j: (i + 1) % Generator.count, p: "C\(copy)")
                }
                copy += 1
            }
            let ns = big as NSString
            let sites = Array(Generator.sites(ns, limit: 24).reversed())
            let heap0 = mallocInUse(), foot0 = footprint()
            let editor = Editor(text: big, language: language, typeInference: true)
            let openStart = DispatchTime.now().uptimeNanoseconds
            editor.open()
            let openMs = Double(DispatchTime.now().uptimeNanoseconds - openStart) / 1e6
            let heap1 = mallocInUse(), foot1 = footprint()
            r += String(format: "### %@: %d units, %d copies of the 1000-line sample, open (index + scan) %.0f ms\n",
                        language, ns.length, copy, openMs)
            let steady = exercise(editor, sites: sites, fresh: false)
            r += describe("steady snapshot", steady, sites: sites.count)
            let freshSites = Array(sites.prefix(8))
            let fresh = exercise(editor, sites: freshSites, fresh: true)
            r += describe("fresh snapshot per operator (rescan untimed)", fresh, sites: freshSites.count)
            // Control: the same fresh-snapshot keys with type inference off
            // (the engine's per-snapshot query index rebuild, no inference).
            editor.settings.setEnabled(false, for: .typeInference)
            let control = exercise(editor, sites: freshSites, fresh: true)
            r += "  control, type inference off, fresh snapshot per operator: operator key " + summary(control.opKeys) + "\n"
            editor.settings.setEnabled(true, for: .typeInference)
            _ = exercise(editor, sites: Array(sites.prefix(1)), fresh: false)
            let heap2 = mallocInUse(), foot2 = footprint()
            let service = editor.controller.typeInferenceForTesting
            r += "    inference-owned: \(kb(service?.retainedBytes ?? 0)); types built in the last model: "
                + "\(service?.braceViewForTesting?.statistics.typesBuilt ?? 0), bodies read "
                + "\(service?.braceViewForTesting?.statistics.bodiesRead ?? 0); class-name map "
                + String(format: "%.2f ms", Double(service?.braceViewForTesting?.statistics.classNamesNanoseconds ?? 0) / 1e6)
                + ", Go method index "
                + String(format: "%.2f ms", Double(service?.braceViewForTesting?.statistics.goMethodsNanoseconds ?? 0) / 1e6)
                + "\n"
            r += "    malloc: open \(mb(heap1 - heap0)), runs \(mb(heap2 - heap1)); phys_footprint: "
                + "\(mb(foot1 - foot0)), \(mb(foot2 - foot1))\n"
            if let s = service?.statistics {
                r += "    service: requests \(s.requests), inferred \(s.inferred), reused \(s.reused), aborted \(s.aborted), "
                    + "models \(s.sessions)\n"
            }
            editor.close()
        }

        print(r)
        let out = root.appendingPathComponent(".build/m17-baseline")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try r.write(to: out.appendingPathComponent("t1711d-bench-\(Self.config).txt"), atomically: true, encoding: .utf8)
    }
}
