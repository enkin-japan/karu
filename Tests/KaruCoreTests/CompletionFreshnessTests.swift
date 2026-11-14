import AppKit
import Foundation
import Testing
@testable import KaruCore

// M17 T17.5 — freshness and hot-path structures: the edit journal, the
// published snapshot through edits, the per-snapshot query index (equal to
// the full `visibleBindings` sweep), and the sorted document word index.

private func isolatedDefaults() -> UserDefaults {
    let name = "CompletionFreshnessTests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

@MainActor
private func pump(until done: () -> Bool, timeout: TimeInterval = 3) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !done(), Date() < deadline {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
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

@Suite("CompletionFreshness", .serialized)
struct CompletionFreshnessTests {

    // MARK: Edit journal

    @Test func journalMapsThroughRandomEditSequences() {
        var rng = SeededGenerator(state: 17)
        for round in 0..<200 {
            let baseLength = Int.random(in: 0...40, using: &rng)
            // Live text as base origins (-1: inserted since).
            var live = Array(0..<baseLength)
            var journal = EditJournal()
            for _ in 0..<Int.random(in: 1...12, using: &rng) {
                let location = Int.random(in: 0...live.count, using: &rng)
                let removed = Int.random(in: 0...min(5, live.count - location), using: &rng)
                let inserted = Int.random(in: 0...5, using: &rng)
                live.replaceSubrange(location..<location + removed, with: Array(repeating: -1, count: inserted))
                journal.record(editedRange: NSRange(location: location, length: inserted),
                               changeInLength: inserted - removed)
            }
            #expect(journal.netDelta == live.count - baseLength, "round \(round)")
            for (position, origin) in live.enumerated() where origin >= 0 {
                #expect(journal.mapFromBase(origin) == position, "round \(round): base \(origin)")
                #expect(journal.mapToBase(position) == origin, "round \(round): live \(position)")
            }
            // Every offset maps into range.
            for offset in 0...baseLength {
                let mapped = journal.mapFromBase(offset)!
                #expect(mapped >= 0 && mapped <= live.count)
            }
            for offset in 0...live.count {
                let mapped = journal.mapToBase(offset)!
                #expect(mapped >= 0 && mapped <= baseLength)
            }
        }
    }

    @Test func journalInsertDeleteReplace() {
        var journal = EditJournal()
        // "hello world" → insert "big " at 6 → "hello big world"
        journal.record(editedRange: NSRange(location: 6, length: 4), changeInLength: 4)
        #expect(journal.mapFromBase(6) == 10)         // "w"
        #expect(journal.mapToBase(8) == 6)            // inside the insertion → its point
        // delete "hello " (0..<6) → "big world"
        journal.record(editedRange: NSRange(location: 0, length: 0), changeInLength: -6)
        #expect(journal.mapFromBase(6) == 4)
        #expect(journal.mapFromBase(2) == 0)          // deleted → the deletion point
        // replace "big" with "small" → "small world"
        journal.record(editedRange: NSRange(location: 0, length: 5), changeInLength: 2)
        #expect(journal.mapFromBase(6) == 6)
        #expect(journal.mapToBase(6) == 6)
        #expect(journal.netDelta == 0)
    }

    @Test func journalTurnsUnmappableAndResets() {
        var journal = EditJournal()
        for _ in 0..<EditJournal.capacity {
            journal.record(editedRange: NSRange(location: 0, length: 1), changeInLength: 1)
        }
        #expect(!journal.isUnmappable)
        #expect(journal.mapFromBase(0) == EditJournal.capacity)
        journal.record(editedRange: NSRange(location: 0, length: 1), changeInLength: 1)
        #expect(journal.isUnmappable)
        #expect(journal.mapFromBase(0) == nil)
        #expect(journal.mapToBase(0) == nil)
        journal.reset()
        #expect(journal.isEmpty)
        #expect(journal.mapFromBase(3) == 3)
    }

    @MainActor
    @Test func publishedSnapshotSurvivesEditsWithAJournal() async {
        let center = NotificationCenter()
        let settings = ModuleSettings(defaults: isolatedDefaults(), center: center)
        let scheduler = AnalysisScheduler()
        let textView = EditorTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let hub = TextStorageObserverHub()
        textView.textStorage?.delegate = hub
        let analysis = DocumentAnalysis(textView: textView, moduleSettings: settings, moduleCenter: center,
                                        scheduler: scheduler)
        hub.add(analysis)
        textView.string = "def alpha(one):\n    return one\n"
        analysis.setLanguage(identifier: "python")
        let version = analysis.publishedDeclarations?.snapshot.version
        #expect(version != nil)
        #expect(analysis.publishedDeclarations?.journal.isEmpty == true)

        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.insertText("# x\n", replacementRange: NSRange(location: 0, length: 0))
        #expect(analysis.declarations == nil)                       // not current any more
        let published = analysis.publishedDeclarations
        #expect(published?.snapshot.version == version)             // still readable
        #expect(published?.journal.edits.count == 1)
        // `one` (offset 10 in the scan) is at 14 in the live text.
        let oneInScan = published!.snapshot.scan.declarations.first { $0.name == "one" }!.location
        #expect(published?.journal.mapFromBase(oneInScan) == oneInScan + 4)
        #expect(analysis.mapFromSnapshot(offset: oneInScan) == oneInScan + 4)
        #expect(analysis.mapToSnapshot(offset: oneInScan + 4) == oneInScan)

        // The debounced rescan publishes a new snapshot and clears the journal.
        await pump(until: { analysis.declarations != nil })
        #expect(analysis.publishedDeclarations?.snapshot.version == analysis.version)
        #expect(analysis.publishedDeclarations?.journal.isEmpty == true)
        withExtendedLifetime(hub) {}
    }

    // MARK: Query index

    private static let equivalenceFixtures: [(String, String)] = [
        ("completion/scope/py_params.py", "python"), ("completion/scope/py_locals.py", "python"),
        ("completion/scope/py_negative.py", "python"), ("completion/member/py_members.py", "python"),
        ("completion/scope/js_scope.js", "javascript"), ("completion/member/js_members.js", "javascript"),
        ("completion/scope/ts_scope.ts", "typescript"), ("completion/member/ts_members.ts", "typescript"),
        ("highlight/python.py", "python"), ("highlight/javascript.js", "javascript"),
        ("highlight/typescript.ts", "typescript"), ("highlight/swift.swift", "swift"),
        ("highlight/go.go", "go"), ("highlight/rust.rs", "rust"), ("highlight/java.java", "java"),
        ("highlight/csharp.cs", "csharp"), ("highlight/c.c", "c"), ("highlight/cpp.cpp", "cpp"),
        ("completion/explicit/account.swift", "swift"), ("completion/explicit/config.rs", "rust"),
    ]

    /// `DeclarationQueryIndex` serves exactly the full sweep's bindings and
    /// scope chain (brace-language module bindings may report another
    /// declaration of the same name, so locations are not compared there).
    private func assertEquivalent(_ text: String, _ language: String, stride: Int, label: String) {
        let scan = DeclarationScan.scan(text: text, languageIdentifier: language)
        let index = DeclarationQueryIndex(scan: scan)
        let brace = BraceLanguage(identifier: language) != nil
        let length = (text as NSString).length
        var offset = 0
        while offset <= length {
            let full = scan.visibleBindings(at: offset)
            let fast = index.visibleBindings(at: offset)
            func key(_ b: DeclarationScan.ScopedBinding) -> String {
                brace ? "\(b.name)@\(b.scopeDepth)" : "\(b.name)@\(b.scopeDepth):\(b.kind):\(b.location)"
            }
            let fullKeys = Set(full.map(key))
            let fastKeys = Set(fast.map(key))
            #expect(fullKeys == fastKeys, "\(label) @\(offset): \(fullKeys.symmetricDifference(fastKeys).sorted())")
            #expect(index.scopeChain(at: offset) == scan.scopeChain(at: offset), "\(label) chain @\(offset)")
            offset += stride
        }
    }

    @Test func queryIndexMatchesTheFullSweepOnFixtures() throws {
        for (file, language) in Self.equivalenceFixtures {
            assertEquivalent(try fixtureText(file), language, stride: 7, label: file)
        }
    }

    @Test func queryIndexMatchesTheFullSweepAcrossSeekPoints() {
        // Enough scopes and declarations to cross many seek points.
        var py = "import os\nTOP = 1\n"
        var js = "const top = 1;\n"
        for i in 0..<300 {
            py += "class K\(i):\n    attr\(i) = \(i)\n    def m\(i)(self, a\(i)):\n        self.v\(i) = a\(i)\n"
            py += "        return [x for x in a\(i)]\n\ndef f\(i)(p\(i), q):\n    r\(i) = p\(i)\n    return r\(i)\n\n"
            js += "function f\(i)(p\(i)) { let r\(i) = p\(i); if (r\(i)) { const b\(i) = 1; } return () => r\(i); }\n"
            js += "class C\(i) { m() { this.x\(i) = 1; } }\n"
        }
        assertEquivalent(py, "python", stride: 1_499, label: "generated.py")
        assertEquivalent(js, "javascript", stride: 1_201, label: "generated.js")
    }

    @Test func classMembersSpanSameNamedScopesInBraceLanguages() throws {
        let text = try fixtureText("completion/explicit/config.rs")
        let scan = DeclarationScan.scan(text: text, languageIdentifier: "rust")
        let index = DeclarationQueryIndex(scan: scan)
        let inMethod = (text as NSString).range(of: "!self.name").location
        let members = Set(index.classMembers(at: inMethod)?.map(\.name) ?? [])
        #expect(members.isSuperset(of: ["validate", "with_retries", "name", "retries"]))
        #expect(!members.contains("Fast"))
    }

    @Test func moduleBindingLookup() {
        let scan = DeclarationScan.scan(text: "def Alpha(): pass\ndef alpha(): pass\nalphabet = 1\n",
                                        languageIdentifier: "python")
        let index = DeclarationQueryIndex(scan: scan)
        #expect(index.moduleBinding(named: "alpha")?.kind == .function)
        #expect(index.moduleBinding(named: "Alpha")?.name == "Alpha")
        #expect(index.moduleBinding(named: "ALPHA") == nil)
        let range = index.moduleRange(loweredPrefix: CaseFold.folded("alp"))
        #expect(range.map { index.moduleBinding(at: $0).name } == ["Alpha", "alpha", "alphabet"])
    }

    // MARK: Word index

    @Test func wordIndexPrefixRangesAreInDictionaryOrder() {
        let index = WordIndex(text: "Batch basic Bard batch_size bazaar zebra Ba1 _private")
        let hits = index.prefixMatches(Array("ba".utf16), limit: 10)
        #expect(hits.exact.map(index.word) == ["basic", "batch_size", "bazaar"])
        #expect(hits.folded.map(index.word) == ["Ba1", "Bard", "Batch"])
        #expect(!hits.truncated)
        let limited = index.prefixMatches(Array("ba".utf16), limit: 1)
        #expect(limited.exact.map(index.word) == ["basic"])
        #expect(limited.truncated)
        #expect(index.lookup(Array("Bard".utf16)).map(index.word) == "Bard")
        #expect(index.lookup(Array("bard".utf16)) == nil)
        #expect(index.prefixMatches(Array("_p".utf16), limit: 5).exact.map(index.word) == ["_private"])
    }

    @Test func wordIndexInitialsAndCounts() {
        let text = "userDisplayName user_display_name useDefaultNames userDisplayName other"
        let index = WordIndex(text: text)
        let initials = index.initialsMatches(CaseFold.folded("udn"), limit: 10)
        #expect(Set(initials.ids.map(index.word)) == ["userDisplayName", "user_display_name", "useDefaultNames"])
        let id = index.lookup(Array("userDisplayName".utf16))!
        #expect(index.occurrences(of: id).count == 2)
        #expect(index.occurrences(of: id).firstLocation == 0)
        #expect(index.occurrences(of: index.lookup(Array("other".utf16))!).firstLocation
                == (text as NSString).range(of: "other").location)
    }

    @Test func wordIndexUnicodeAndDollar() {
        let index = WordIndex(text: "\u{1D465}value cafe\u{301}s 12abc 下周 $store", languageIdentifier: "javascript")
        let words = index.words
        #expect(words.contains("\u{1D465}value"))
        #expect(words.contains("cafe\u{301}s"))
        #expect(words.contains("下周"))
        #expect(words.contains("$store"))
        #expect(!words.contains("12abc"))
        #expect(!words.contains("abc"))
        #expect(!WordIndex(text: "$store", languageIdentifier: "python").words.contains("$store"))
    }

    @Test func slicedWordIndexBuildEqualsOneGo() throws {
        let text = try fixtureText("highlight/python.py") + (try fixtureText("highlight/typescript.ts"))
        let ns = text as NSString
        let oneGo = WordIndex(text: text)
        for budget in [3, 64, 4096] {
            var builder = WordIndexBuilder(dollar: false)
            var steps = 0
            while !builder.step(ns, budgetUnits: budget) { steps += 1 }
            let sliced = builder.index!
            #expect(sliced.count == oneGo.count, "budget \(budget)")
            #expect((0..<sliced.count).map { sliced.word(sliced.sorted[$0]) }
                    == (0..<oneGo.count).map { oneGo.word(oneGo.sorted[$0]) }, "budget \(budget)")
            #expect(sliced.initials.map(sliced.word) == oneGo.initials.map(oneGo.word), "budget \(budget)")
            #expect(steps > 1)
        }
    }

    @Test func wordIndexGrowsItsTableIncrementally() {
        // Far more distinct words than the initial table holds, built in tiny
        // steps so lookups run while the old table is still draining.
        let text = (0..<20_000).map { "w\($0) w\($0 / 2)" }.joined(separator: " ")
        var builder = WordIndexBuilder(dollar: false)
        while !builder.step(text as NSString, budgetUnits: 37) {}
        let index = builder.index!
        #expect(index.count == 20_000)
        for probe in [0, 1, 4095, 4096, 12_345, 19_999] {
            let id = index.lookup(Array("w\(probe)".utf16))
            #expect(id != nil, "w\(probe)")
            // w(k) occurs once as itself and once as (2k)/2 or (2k+1)/2.
            if let id { #expect(index.occurrences(of: id).count == (probe < 10_000 ? 3 : 1), "w\(probe)") }
        }
    }

    @Test func resumableSortSortsInAnyBudget() {
        var rng = SeededGenerator(state: 5)
        for count in [0, 1, 2, 15, 16, 17, 100, 1000] {
            let values = (0..<count).map { _ in UInt32.random(in: 0..<500, using: &rng) }
            for budget in [1, 3, 64] {
                var sorter = ResumableSort(Array(values.indices.map(UInt32.init)))
                while !sorter.step(budget: budget, less: { values[Int($0)] < values[Int($1)] }) {}
                let sorted = sorter.items.map { values[Int($0)] }
                #expect(sorted == values.sorted(), "count \(count) budget \(budget)")
                // Stable: equal values keep their original order.
                for i in sorter.items.indices.dropFirst() where sorted[i] == sorted[i - 1] {
                    #expect(sorter.items[i] > sorter.items[i - 1])
                }
            }
        }
    }
}
