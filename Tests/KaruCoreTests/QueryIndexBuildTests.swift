import AppKit
import Foundation
import Testing
@testable import KaruCore

// M17 T17.15a — the query index off the keystroke path: the resumable
// `DeclarationQueryIndex.Builder` equals the one-shot build at any split,
// the flat-buffer sort keeps the T17.5 order exactly (a port of the old
// build is the reference), and the index the analysis prebuilds in its
// slices after publishing equals a fresh build — tables and candidates —
// over random edit sequences.

private func isolatedDefaults() -> UserDefaults {
    let name = "QueryIndexBuildTests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

/// Deterministic generator (SplitMix64).
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private let fixtureRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/M17")

private func fixtureText(_ relative: String) throws -> String {
    let raw = try String(contentsOf: fixtureRoot.appendingPathComponent(relative), encoding: .utf8)
    return raw.replacingOccurrences(of: "\u{27E8}\\d+\u{27E9}", with: "", options: .regularExpression)
}

private let fixtures: [(String, String)] = [
    ("completion/scope/py_params.py", "python"), ("completion/scope/py_locals.py", "python"),
    ("completion/member/py_members.py", "python"), ("completion/scope/js_scope.js", "javascript"),
    ("completion/member/js_members.js", "javascript"), ("completion/scope/ts_scope.ts", "typescript"),
    ("completion/member/ts_members.ts", "typescript"), ("highlight/swift.swift", "swift"),
    ("highlight/go.go", "go"), ("highlight/rust.rs", "rust"), ("highlight/java.java", "java"),
    ("highlight/csharp.cs", "csharp"), ("highlight/c.c", "c"), ("highlight/cpp.cpp", "cpp"),
    ("completion/explicit/account.swift", "swift"), ("completion/explicit/server.go", "go"),
    ("completion/explicit/buffer.cpp", "cpp"), ("completion/explicit/Player.cs", "csharp"),
    ("highlight/embedded/page.html", "html"), ("highlight/embedded/fences.md", "markdown"),
    ("highlight/embedded/component.tsx", "typescriptreact"),
]

/// Module-level assignments with names built to stress the order: case
/// variants that fold equal, shared prefixes longer than the packed head,
/// non-ASCII letters that fold (and ones that do not), short names.
private func randomModuleNames(_ rng: inout SeededGenerator, count: Int) -> String {
    let pieces = ["a", "A", "b", "B", "z", "Z", "_", "1", "é", "É", "ß", "Ω", "ω", "名", "カ", "ab", "Ab", "AB",
                  "compute", "Compute", "COMPUTE", "x"]
    var out = ""
    for k in 0..<count {
        var name = ["a", "A", "_", "é", "Ω", "名", "c", "C"].randomElement(using: &rng)!
        for _ in 0..<Int.random(in: 0...4, using: &rng) { name += pieces.randomElement(using: &rng)! }
        out += "\(name) = \(k)\n"
        if k % 7 == 0 { out += "def f\(k)(\(name)_p, q):\n    \(name)_local = q\n    return q\n" }
    }
    return out
}

// MARK: - Reference (the T17.5 build's module tables, ported unchanged)

private struct ReferenceEntry: Equatable {
    let name: String
    let kind: DeclarationScan.DeclarationKind
    let location: Int
}

/// The module bindings (group -1) and each embedded group's, in the order
/// the T17.5 build produced: first module-owned declaration per name,
/// sorted by `CaseFold.folded` then exact UTF-16.
private func referenceTables(_ scan: DeclarationScan) -> [Int32: [ReferenceEntry]] {
    let documentLength = scan.documentLength
    var firstModule: [Int32: ReferenceEntry] = [:]
    var order: [Int32] = []
    var firstInGroup: [Int32: [Int32: ReferenceEntry]] = [:]
    var groupOrder: [Int32: [Int32]] = [:]
    var outline = DeclarationScan.Reader(scan.outline)
    var nextStart = 0
    var nextIndex = 0
    func readNext() -> DeclarationScan.ScopeRecord? {
        guard !outline.atEnd else { return nil }
        nextStart += outline.varint()
        let packed = outline.varint()
        let name = packed & 1 != 0 ? outline.varint() : -1
        let record = DeclarationScan.ScopeRecord(
            index: nextIndex, start: nextStart, end: nextStart + (packed >> 4),
            kind: DeclarationScan.ScopeKind(rawValue: UInt8((packed >> 1) & 7)) ?? .block, name: name)
        nextIndex += 1
        return record
    }
    var pending = readNext()
    var stack: [DeclarationScan.ScopeRecord] = []
    var reader = DeclarationScan.Reader(scan.encodedLocations)
    var location = 0
    let hasOutline = scan.scopeCount > 0
    while !reader.atEnd {
        location += reader.varint()
        let nameKind = reader.varint()
        let nameIndex = Int32(nameKind >> 4)
        let (kind, _) = DeclarationScan.decode(code: nameKind & 15)
        var moduleOwned = !hasOutline
        var group: Int32 = -1
        if hasOutline {
            while let record = pending, record.start <= location {
                while let top = stack.last, record.start >= top.end, top.end < documentLength { stack.removeLast() }
                stack.append(record)
                pending = readNext()
            }
            while let top = stack.last, !scan.contains(top, location) { stack.removeLast() }
            if !stack.isEmpty {
                let floor = DeclarationScan.topLevelPosition(stack)
                moduleOwned = DeclarationScan.ownerPosition(of: kind, stack: stack) == floor
                if floor == 1 { group = Int32(stack[1].name) }
            }
        }
        let entry = ReferenceEntry(name: scan.names[Int(nameIndex)], kind: kind, location: location)
        if moduleOwned, group >= 0 {
            if firstInGroup[group, default: [:]][nameIndex] == nil {
                firstInGroup[group, default: [:]][nameIndex] = entry
                groupOrder[group, default: []].append(nameIndex)
            }
        } else if moduleOwned, firstModule[nameIndex] == nil {
            firstModule[nameIndex] = entry
            order.append(nameIndex)
        }
    }
    func sorted(_ entries: [ReferenceEntry]) -> [ReferenceEntry] {
        entries.sorted { lhs, rhs in
            let order = DeclarationQueryIndex.compare(CaseFold.folded(lhs.name), CaseFold.folded(rhs.name))
            if order != 0 { return order < 0 }
            return DeclarationQueryIndex.compare(Array(lhs.name.utf16), Array(rhs.name.utf16)) < 0
        }
    }
    var out: [Int32: [ReferenceEntry]] = [-1: sorted(order.compactMap { firstModule[$0] })]
    for (group, names) in groupOrder {
        let first = firstInGroup[group] ?? [:]
        out[group] = sorted(names.compactMap { first[$0] })
    }
    return out
}

private func tables(of index: DeclarationQueryIndex, groups: some Sequence<Int32>) -> [Int32: [ReferenceEntry]] {
    var out: [Int32: [ReferenceEntry]] = [:]
    for group in groups {
        out[group] = (0..<index.moduleBindingCount(group: group)).map {
            let b = index.moduleBinding(at: $0, group: group)
            return ReferenceEntry(name: b.name, kind: b.kind, location: b.location)
        }
    }
    return out
}

@Suite("QueryIndexBuild")
struct QueryIndexBuildTests {

    // MARK: Builder

    /// Any split of the build — down to one work item per step — yields the
    /// one-shot index.
    @Test func slicedBuildEqualsOneShot() throws {
        var texts: [(String, String)] = try fixtures.map { (try fixtureText($0.0), $0.1) }
        var rng = SeededGenerator(state: 15)
        for _ in 0..<6 { texts.append((randomModuleNames(&rng, count: 120), "python")) }
        texts.append(("", "python"))
        texts.append(("x = 1", "python"))
        for (text, language) in texts {
            let scan = DeclarationScan.scan(text: text, languageIdentifier: language)
            let oneShot = DeclarationQueryIndex(scan: scan)
            for chunk in [1, 3, 64] {
                var builder = DeclarationQueryIndex.Builder(scan: scan, chunk: chunk)
                var steps = 1
                while !builder.step(deadline: 0) { steps += 1 }   // a past deadline: one chunk per step
                #expect(builder.isFinished)
                #expect(builder.finish().hasSameTables(as: oneShot), "\(language) chunk \(chunk)")
                if scan.declarations.count > 8, chunk == 1 { #expect(steps > scan.declarations.count) }
            }
        }
    }

    /// The flat-buffer sort keeps the T17.5 order (folded, then exact
    /// UTF-16) and the same first declaration per name, groups included.
    @Test func moduleTablesMatchTheReferenceBuild() throws {
        var texts: [(String, String)] = try fixtures.map { (try fixtureText($0.0), $0.1) }
        var rng = SeededGenerator(state: 1715)
        for _ in 0..<20 { texts.append((randomModuleNames(&rng, count: Int.random(in: 1...300, using: &rng)), "python")) }
        for (text, language) in texts {
            let scan = DeclarationScan.scan(text: text, languageIdentifier: language)
            let reference = referenceTables(scan)
            let index = DeclarationQueryIndex(scan: scan)
            #expect(tables(of: index, groups: reference.keys) == reference, "\(language)")
            if language == "html" || language == "markdown" { #expect(reference.count > 1, "embedded groups present") }
            // Prefix ranges agree with a linear filter of the reference order.
            for prefix in ["a", "A", "c", "co", "comp", "é", "名", "_", "zz"] {
                let folded = CaseFold.folded(prefix)
                let expected = reference[-1]!.filter { CaseFold.folded($0.name).starts(with: folded) }
                let range = index.moduleRange(loweredPrefix: folded)
                #expect(range.map { index.moduleBinding(at: $0).name } == expected.map(\.name), "\(language) \(prefix)")
            }
        }
    }

    // MARK: Analysis pipeline

    @MainActor
    private final class Harness {
        let center = NotificationCenter()
        let settings: ModuleSettings
        let scheduler = AnalysisScheduler()
        let window: NSWindow
        let textView: EditorTextView
        let hub = TextStorageObserverHub()
        let controller: CompletionController
        var analysis: DocumentAnalysis { controller.analysis }

        init(_ text: String, language: String) {
            settings = ModuleSettings(defaults: isolatedDefaults(), center: center)
            let frame = NSRect(x: 0, y: 0, width: 600, height: 400)
            let scrollView = NSScrollView(frame: frame)
            textView = EditorTextView(frame: frame)
            textView.allowsUndo = false
            textView.isRichText = false
            scrollView.documentView = textView
            window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = scrollView
            textView.string = text
            textView.textStorage?.delegate = hub
            controller = CompletionController(textView: textView, moduleSettings: settings, moduleCenter: center,
                                              scheduler: scheduler)
            hub.add(controller)
            textView.completionKeyHandler = controller
            controller.setLanguage(identifier: language)
            controller.indexDocument()
        }

        func type(_ key: String) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, characters: key,
                                         charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0)!
            textView.insertText(key, replacementRange: NSRange(location: NSNotFound, length: 0))
            controller.textViewDidInsertKey(event)
        }

        func close() {
            controller.dismissCompletion()
            textView.textStorage?.delegate = nil
            window.close()
        }
    }

    /// The same request answered with the analysis's index and by a fresh
    /// engine building its own: identical candidates.
    @MainActor
    private func assertSameCandidates(_ h: Harness, caret: Int, manual: Bool, label: String) {
        guard let published = h.analysis.publishedDeclarations,
              let prebuilt = h.analysis.publishedQueryIndex() else {
            Issue.record("no published snapshot (\(label))")
            return
        }
        #expect(prebuilt.version == published.snapshot.version)
        #expect(prebuilt.index.hasSameTables(as: DeclarationQueryIndex(scan: published.snapshot.scan)), "\(label)")
        let text = h.textView.textStorage!.mutableString
        let language = h.analysis.languageIdentifier
        let definition = LanguageRegistry.definition(forIdentifier: language)
        func request(_ index: DeclarationQueryIndex?) -> CompletionRequest {
            var r = CompletionRequest(text: text, caret: caret, languageIdentifier: language)
            r.manual = manual
            r.keywords = definition?.keywords ?? []
            r.builtins = definition?.builtins ?? []
            r.snapshot = published.snapshot.scan
            r.snapshotVersion = published.snapshot.version
            r.snapshotJournal = published.journal
            r.snapshotIndex = index
            r.scanner = CandidateEngine.contextScanner(for: language, definition: definition)
            return r
        }
        var withIndex = CandidateEngine()
        var checkpointsA = CheckpointStore()
        let a = withIndex.complete(request(prebuilt.index), checkpoints: &checkpointsA)
        #expect(withIndex.indexBuilds == 0)
        var fresh = CandidateEngine()
        var checkpointsB = CheckpointStore()
        let b = fresh.complete(request(nil), checkpoints: &checkpointsB)
        #expect(fresh.indexBuilds == 1)
        func digest(_ result: CompletionResult?) -> [String] {
            (result?.candidates ?? []).map { "\($0.name)|\($0.kind)|\($0.source)|\($0.scopeDepth ?? -1)|\($0.location ?? -1)" }
        }
        #expect(digest(a) == digest(b), "\(label) caret \(caret)")
    }

    /// Random edits; after each, the scheduler drains in minimal steps (the
    /// rescan publishes, the prebuild runs in many slices). The prebuilt
    /// index equals a fresh build, candidates agree at random carets — also
    /// against a stale snapshot through its journal — and a typed key that
    /// follows a prebuild builds nothing.
    @MainActor
    @Test(arguments: [("completion/scope/py_locals.py", "python"), ("completion/scope/js_scope.js", "javascript"),
                      ("completion/explicit/server.go", "go"), ("completion/explicit/account.swift", "swift"),
                      ("completion/scope/ts_scope.ts", "typescript"), ("highlight/embedded/page.html", "html")])
    func prebuiltIndexEqualsFreshBuildOverRandomEdits(_ fixture: String, _ language: String) throws {
        let h = Harness(try fixtureText(fixture), language: language)
        defer { h.close() }
        var rng = SeededGenerator(state: UInt64(fixture.utf16.count) &* 31 &+ 7)
        let snippets = ["\nzeta_value = 1\n", "\nfunction extra(a, b) { return a }\n", "\ndef extra(a, b):\n    return a\n",
                        "{", "}", "(", ")", " ", "\n", "x", "local_name", "\n    inner = 2\n", "\"", "'", "#", "//",
                        "\nfunc extra(a int) int { return a }\n", "\nlet extraValue = 3\n"]
        _ = h.analysis.publishedQueryIndex()               // completion has used this document
        var prebuilt = 0
        for round in 0..<30 {
            let storage = h.textView.textStorage!
            let length = storage.length
            if length > 0, Bool.random(using: &rng), round % 3 != 0 {
                let location = Int.random(in: 0..<length, using: &rng)
                let removed = Int.random(in: 1...min(12, length - location), using: &rng)
                storage.replaceCharacters(in: NSRange(location: location, length: removed), with: "")
            } else {
                let location = Int.random(in: 0...length, using: &rng)
                storage.replaceCharacters(in: NSRange(location: location, length: 0),
                                          with: snippets.randomElement(using: &rng)!)
            }
            let text = storage.mutableString
            func carets() -> [Int] {
                (0..<4).map { _ in Int.random(in: 0...text.length, using: &rng) }
            }
            if round % 4 == 1 {
                // Stale snapshot: queried through the journal before the rescan.
                for caret in carets() { assertSameCandidates(h, caret: caret, manual: true, label: "stale \(round)") }
            }
            let slicedBefore = h.analysis.queryIndexSlicedBuilds
            h.scheduler.runPendingJobsForTesting(budget: 0)
            #expect(h.analysis.declarations != nil)
            #expect(h.analysis.publishedDeclarations?.journal.isEmpty == true)
            if h.analysis.queryIndexSlicedBuilds > slicedBefore { prebuilt += 1 }
            let synchronousBefore = h.analysis.queryIndexSynchronousBuilds
            for caret in carets() { assertSameCandidates(h, caret: caret, manual: Bool.random(using: &rng), label: "round \(round)") }
            #expect(h.analysis.queryIndexSynchronousBuilds == synchronousBefore, "prebuilt, nothing built on request")
        }
        #expect(prebuilt == 30)

        // Through the controller: the key after a prebuild builds no index.
        h.textView.setSelectedRange(NSRange(location: h.textView.textStorage!.length, length: 0))
        h.type("\n")
        h.scheduler.runPendingJobsForTesting()
        let engineBuilds = h.controller.engineForTesting.indexBuilds
        let synchronous = h.analysis.queryIndexSynchronousBuilds
        h.type("z")
        h.type("e")
        #expect(h.controller.engineForTesting.indexBuilds == engineBuilds)
        #expect(h.analysis.queryIndexSynchronousBuilds == synchronous)
    }

    /// Prebuilding follows use: nothing before completion queried an index;
    /// after a query the next `prebuildGenerations` snapshots are prebuilt
    /// even without further queries (a paste or undo publishes without a
    /// keystroke request), then it stops; a request before a prebuild
    /// finished completes it on the spot; turning completion off drops the
    /// index and stops prebuilding; releasing everything leaves nothing held.
    @MainActor
    @Test func prebuildFollowsUseAndModules() {
        let h = Harness("def alpha(one):\n    return one\n", language: "python")
        defer { h.close() }
        func edit(_ text: String) {
            h.textView.textStorage!.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
        }
        h.scheduler.runPendingJobsForTesting()
        // No completion request yet: an edit's snapshot is not prebuilt.
        edit("beta = 1\n")
        h.scheduler.runPendingJobsForTesting()
        #expect(h.analysis.queryIndexSlicedBuilds == 0)
        #expect(!h.analysis.holdsQueryIndex)
        // The first request builds it synchronously; the next snapshots are prebuilt.
        #expect(h.analysis.publishedQueryIndex() != nil)
        #expect(h.analysis.queryIndexSynchronousBuilds == 1)
        for (k, text) in ["gamma = 2\n", "gamma2 = 2\n"].enumerated() {
            edit(text)
            h.scheduler.runPendingJobsForTesting(budget: 0)
            #expect(h.analysis.queryIndexSlicedBuilds == k + 1)
            #expect(h.analysis.holdsQueryIndex)
        }
        // Unqueried for `prebuildGenerations` snapshots: the next is not prebuilt.
        #expect(DocumentAnalysis.prebuildGenerations == 2)
        edit("gamma3 = 2\n")
        h.scheduler.runPendingJobsForTesting()
        #expect(h.analysis.queryIndexSlicedBuilds == 2)
        #expect(!h.analysis.holdsQueryIndex)
        #expect(h.analysis.publishedQueryIndex() != nil)
        #expect(h.analysis.queryIndexSynchronousBuilds == 2)
        // A request before the prebuild finished completes it on the spot.
        edit("delta = 3\n")
        _ = h.analysis.ensureDeclarations()
        #expect(h.analysis.holdsQueryIndex)
        let index = h.analysis.publishedQueryIndex()
        #expect(index?.version == h.analysis.publishedDeclarations?.snapshot.version)
        #expect(h.analysis.queryIndexSynchronousBuilds == 3)
        #expect(index?.index.moduleBinding(named: "delta") != nil)
        h.scheduler.runPendingJobsForTesting()
        #expect(h.analysis.queryIndexSlicedBuilds == 2)                 // the cancelled job built nothing
        // Completion off: dropped, and new snapshots are not prebuilt.
        h.settings.setEnabled(false, for: .completion)
        #expect(!h.analysis.holdsQueryIndex)
        edit("eps = 4\n")
        h.scheduler.runPendingJobsForTesting()
        #expect(!h.analysis.holdsQueryIndex)
        // Everything off: released.
        h.settings.setEnabled(true, for: .completion)
        _ = h.analysis.publishedQueryIndex()
        for module in DocumentAnalysis.analysisModules { h.settings.setEnabled(false, for: module) }
        #expect(h.analysis.isRuntimeStateReleased)
    }
}
