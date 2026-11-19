import AppKit
import Foundation
import Testing
@testable import KaruCore

// M17 T17.14 — cross-file integration (plan §5.3, §8.1, §10, §13 「导入与跨文件」):
// other files' names in completion, cross-file members of the static
// languages, signature summaries in the index, the workspace-symbol
// navigator, and the `crossFileIndex` toggle. The fixture project is
// `Tests/Fixtures/M17/crossfile/project` (read only; its index lives in a
// temporary Application Support root); `outside/` next to it is never part
// of the project folder.

enum CrossFileFixtures {
    static let base: String = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/M17/crossfile").path
    }()
    static var project: String { ProjectFolderStore.standardize(base + "/project") }

    struct Expectations: Decodable {
        struct Names: Decodable { let id, file, after: String; let expect: [String]; let top: Int }
        struct Members: Decodable { let id, file, after: String; let expect: [String]; let forbid: [String] }
        struct Signature: Decodable { let id, file, after, name, detail: String }
        struct Symbols: Decodable { let id, query: String; let expect: [[String]]; let top: Int }
        struct Negative: Decodable { let id, kind: String; let file, after, query: String?; let forbid: [String] }
        let names: [Names]
        let members: [Members]
        let signatures: [Signature]
        let symbols: [Symbols]
        let negatives: [Negative]
    }

    static func expectations() throws -> Expectations {
        let data = try Data(contentsOf: URL(fileURLWithPath: base + "/expectations.json"))
        return try JSONDecoder().decode(Expectations.self, from: data)
    }
}

/// An index of a project folder, the cross-file and import services over
/// it, and documents (editor text view + completion controller) of its files.
@MainActor
final class CrossFileHarness {
    let fixture = IndexFixture()
    let index: WorkspaceIndex
    let crossFile: CrossFileTypeService
    let imports: ImportService
    let folder: String

    init(folder: String = CrossFileFixtures.project, scope: IndexScope = IndexScope()) {
        self.folder = folder
        index = fixture.makeIndex(scope: scope, latency: 0.1)
        index.start()
        index.addFolder(URL(fileURLWithPath: folder, isDirectory: true))
        _ = index.waitUntilIdle()
        crossFile = CrossFileTypeService(configuration: .init(workspace: index, moduleSettings: fixture.modules,
                                                               center: fixture.center))
        let index = self.index
        imports = ImportService(configuration: .init(projectFolder: { index.projectFolder(containing: $0) },
                                                     interpreter: { .none }, moduleSettings: fixture.modules,
                                                     center: fixture.center, workspace: index))
    }

    func document(_ relative: String) throws -> CrossFileDocument {
        try CrossFileDocument(harness: self, path: folder + "/" + relative)
    }

    /// Waits for the index to catch up (after a toggle).
    func settleIndex() { _ = index.waitUntilIdle() }
}

@MainActor
final class CrossFileDocument {
    let harness: CrossFileHarness
    let path: String
    let textView = EditorTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
    let window: NSWindow
    let controller: CompletionController
    let hub = TextStorageObserverHub()

    init(harness: CrossFileHarness, path: String) throws {
        self.harness = harness
        self.path = path
        let scroll = NSScrollView(frame: textView.frame)
        scroll.documentView = textView
        window = NSWindow(contentRect: textView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        textView.string = try String(contentsOfFile: path, encoding: .utf8)
        textView.textStorage?.delegate = hub
        controller = CompletionController(textView: textView, moduleSettings: harness.fixture.modules,
                                          moduleCenter: harness.fixture.center, scheduler: AnalysisScheduler(),
                                          importService: harness.imports, workspaceIndex: harness.index,
                                          crossFileTypes: harness.crossFile)
        let url = URL(fileURLWithPath: path)
        controller.documentURLProvider = { url }
        hub.add(controller)
        textView.completionKeyHandler = controller
        controller.setLanguage(identifier: LanguageRegistry.identifier(forExtension: url.pathExtension))
        controller.indexDocument()
        window.makeFirstResponder(textView)
    }

    deinit {
        MainActor.assumeIsolated {
            controller.dismissCompletion()
            window.close()
        }
    }

    func caret(after marker: String) -> Int {
        let ns = textView.string as NSString
        let range = ns.range(of: marker)
        precondition(range.location != NSNotFound, "marker \(marker) not in \(path)")
        return NSMaxRange(range)
    }

    /// The popup's candidates at the caret after `marker`, once pending
    /// cross-file types and imports have arrived (bounded).
    func candidates(after marker: String, manual: Bool = false) -> [Candidate] {
        textView.setSelectedRange(NSRange(location: caret(after: marker), length: 0))
        controller.requestCompletion(manual: manual)
        var rounds = 0
        while controller.isWaitingForImportsForTesting, rounds < 12 {
            harness.crossFile.waitForTypes()
            harness.imports.waitForImports()
            controller.requestCompletion(manual: manual)
            rounds += 1
        }
        return controller.currentCandidatesForTesting
    }

    func inferred(after marker: String) -> [Candidate] {
        candidates(after: marker).filter { $0.source == .inferredType }
    }
}

// MARK: - §13 fixture

@MainActor
@Suite("T17.14 cross-file fixture", .serialized)
struct CrossFileFixtureTests {
    @Test func crossFileSamples() throws {
        let expectations = try CrossFileFixtures.expectations()
        let h = CrossFileHarness()
        var report: [String] = []
        var documents: [String: CrossFileDocument] = [:]
        func document(_ file: String) throws -> CrossFileDocument {
            if let open = documents[file] { return open }
            let opened = try h.document(file)
            documents[file] = opened
            return opened
        }

        var passed = 0
        for sample in expectations.names {
            let names = try document(sample.file).candidates(after: sample.after).prefix(sample.top)
            let ok = sample.expect.allSatisfy { name in names.contains { $0.name == name && $0.source == .workspace } }
            #expect(ok, "\(sample.id): \(names.map { "\($0.name)[\($0.source)]" })")
            if ok { passed += 1 }
        }
        report.append("names \(passed)/\(expectations.names.count)")

        passed = 0
        for sample in expectations.members {
            let names = try document(sample.file).inferred(after: sample.after).map(\.name)
            let ok = sample.expect.allSatisfy(names.contains) && !sample.forbid.contains(where: names.contains)
            #expect(ok, "\(sample.id): \(names)")
            if ok { passed += 1 }
        }
        report.append("members \(passed)/\(expectations.members.count)")

        passed = 0
        for sample in expectations.signatures {
            let detail = try document(sample.file).candidates(after: sample.after).first { $0.name == sample.name }?.detail
            let ok = detail == sample.detail
            #expect(ok, "\(sample.id): \(detail ?? "nil")")
            if ok { passed += 1 }
        }
        report.append("signatures \(passed)/\(expectations.signatures.count)")

        passed = 0
        for sample in expectations.symbols {
            let rows = h.index.searchSymbols(sample.query, inFolder: h.folder, limit: sample.top)
            let ok = sample.expect.allSatisfy { pair in
                rows.contains { $0.symbol.name == pair[0] && $0.symbol.relativePath == pair[1] }
            }
            #expect(ok, "\(sample.id): \(rows.map { "\($0.symbol.name)@\($0.symbol.relativePath)" })")
            if ok { passed += 1 }
        }
        report.append("symbols \(passed)/\(expectations.symbols.count)")

        passed = 0
        for sample in expectations.negatives {
            var names: [String]
            switch sample.kind {
            case "symbols":
                names = h.index.searchSymbols(try #require(sample.query), inFolder: nil).map(\.symbol.name)
            case "members":
                names = try document(try #require(sample.file)).inferred(after: try #require(sample.after)).map(\.name)
                // Nothing else may stand in for the unknown type either.
                names += try document(try #require(sample.file)).candidates(after: try #require(sample.after)).map(\.name)
            default:
                names = try document(try #require(sample.file)).candidates(after: try #require(sample.after),
                                                                            manual: true).map(\.name)
            }
            let ok = !sample.forbid.contains(where: names.contains)
            #expect(ok, "\(sample.id): \(names)")
            if ok { passed += 1 }
        }
        report.append("negatives \(passed)/\(expectations.negatives.count)")
        print("T17.14 cross-file fixture: " + report.joined(separator: ", ")
              + " (cross-file lookups \(h.crossFile.statistics.names), files read \(h.crossFile.statistics.filesRead))")
        for document in documents.values { document.controller.dismissCompletion() }
    }
}

// MARK: - Ranking, label, detail

@MainActor
@Suite("T17.14 workspace names in the engine")
struct WorkspaceNameRankingTests {
    private func request(_ source: String, workspace: [WorkspaceNameBatch.Name], truncated: Bool = false,
                         calls: Box? = nil) -> CompletionResult? {
        let ns = source as NSString
        let bar = ns.range(of: "|")
        let text = ns.replacingCharacters(in: bar, with: "") as NSString
        var request = CompletionRequest(text: text, caret: bar.location, languageIdentifier: "python")
        let scan = DeclarationScan.scan(text: text as String, languageIdentifier: "python")
        request.snapshot = scan
        request.snapshotVersion = 1
        request.keywords = ["mkeyword_kw"]
        var builder = WordIndexBuilder(dollar: false)
        request.words = builder.finish(text)
        request.scanner = CandidateEngine.contextScanner(for: "python", definition: LanguageRegistry.definition(forIdentifier: "python"))
        request.workspaceNames = { prefix in
            calls?.prefixes.append(prefix)
            return WorkspaceNameBatch(names: workspace.filter { $0.name.lowercased().hasPrefix(prefix.lowercased()) },
                                      truncated: truncated)
        }
        var engine = CandidateEngine()
        var checkpoints = CheckpointStore()
        return engine.complete(request, checkpoints: &checkpoints)
    }

    final class Box { var prefixes: [String] = [] }

    @Test func rankedBelowScopeAndFileAboveKeywordsAndWords() throws {
        let source = """
            def mk_file():
                pass

            def run(mk_param):
                mk_local = 1
                # mk_word in a comment
                mk|
            """
        let remote = WorkspaceNameBatch.Name(name: "mk_remote", kind: .function, detail: "other.py  (a) -> int")
        let result = try #require(request(source, workspace: [remote]))
        let names = result.candidates.map(\.name)
        let order = ["mk_local", "mk_param", "mk_file", "mk_remote", "mkeyword_kw", "mk_word"]
        let positions = order.compactMap { names.firstIndex(of: $0) }
        #expect(positions.count == order.count, "\(names)")
        #expect(positions == positions.sorted(), "\(names)")
        let candidate = try #require(result.candidates.first { $0.name == "mk_remote" })
        #expect(candidate.source == .workspace)
        #expect(candidate.detail == "other.py  (a) -> int")
        #expect(CompletionCategory.of(candidate) == .file)
        let row = CompletionRowContent(candidate: candidate, language: .zhHans)
        #expect(row.label == "文件" && row.detail == "other.py  (a) -> int")
        #expect(CompletionRowContent(candidate: candidate, language: .en).label == "file")
    }

    @Test func exactPrefixTiersOnlyAndMatchTierBeatsSource() throws {
        // `mrm` would fuzzy-match `my_remote_module`: the index source never fuzzy-matches.
        let remote = [WorkspaceNameBatch.Name(name: "my_remote_module", kind: .variable, detail: nil),
                      WorkspaceNameBatch.Name(name: "Mrm_exact", kind: .variable, detail: nil)]
        let result = try #require(request("my_remote_module_local = 1\nmrm|", workspace: remote))
        #expect(!result.candidates.contains { $0.name == "my_remote_module" && $0.source == .workspace })
        // A case-insensitive prefix match from the index ranks above a fuzzy local match.
        let names = result.candidates.map(\.name)
        let exact = try #require(names.firstIndex(of: "Mrm_exact"))
        if let local = names.firstIndex(of: "my_remote_module_local") { #expect(exact < local) }
    }

    @Test func providerIsAskedOncePerMatchedSetAndNeverForMembers() throws {
        let calls = Box()
        _ = request("x = 1\nab|", workspace: [], calls: calls)
        #expect(calls.prefixes == ["ab"])
        _ = request("x = 1\nx.ab|", workspace: [], calls: calls)
        #expect(calls.prefixes == ["ab"])   // member access: not asked
        _ = request("x = 'ab|'", workspace: [], calls: calls)
        #expect(calls.prefixes == ["ab"])   // string: not asked
    }
}

// MARK: - Main-thread query bound

@MainActor
@Suite("T17.14 bounded name query", .serialized)
struct WorkspaceNameQueryTests {
    @Test func boundedByScanCapLimitAndLockWait() throws {
        let f = IndexFixture()
        var text = ""
        for i in 0..<4_000 { text += "def item_\(String(format: "%04d", i))(a, b):\n    return a\n" }
        f.write("big.py", text)
        f.write("small.py", "def item_zzz_small():\n    pass\n")
        f.write("other.go", "package x\nfunc ItemGo() {}\n")
        let index = f.makeIndex()
        index.start()
        index.addFolder(f.folder)
        #expect(index.waitUntilIdle())
        let doc = f.folder.appendingPathComponent("doc.py").path
        // Bounded: ≤ limit rows, truncated, a few ms.
        var times: [Double] = []
        var answer: WorkspaceIndex.NameQuery?
        for _ in 0..<20 {
            let start = DispatchTime.now().uptimeNanoseconds
            answer = index.topLevelNames(withPrefix: "item", inFolder: f.path, excludingFile: doc, languages: ["python"])
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        let result = try #require(answer)
        #expect(result.symbols.count == 64 && result.truncated)
        #expect(result.symbols.allSatisfy { $0.languageIdentifier == "python" && $0.container == nil })
        times.sort()
        print(String(format: "T17.14 name query (4,001 matches, debug): p50 %.2f ms, max %.2f ms", times[10], times[19]))
        #expect(times[10] < 20)
        // Other languages and the excluded file never appear. The scan cap
        // counts every language: 4,001 Python names before `itemgo` → nothing
        // yet, but marked truncated (the next keystroke asks again).
        let capped = try #require(index.topLevelNames(withPrefix: "item", inFolder: f.path, languages: ["go"]))
        #expect(capped.symbols.isEmpty && capped.truncated)
        let go = try #require(index.topLevelNames(withPrefix: "itemg", inFolder: f.path, languages: ["go"]))
        #expect(go.symbols.map(\.name) == ["ItemGo"] && !go.truncated)
        let excluded = try #require(index.topLevelNames(withPrefix: "item_zzz", inFolder: f.path,
                                                        excludingFile: f.folder.appendingPathComponent("small.py").path,
                                                        languages: ["python"]))
        #expect(excluded.symbols.isEmpty)
        // The indexer holding the database: the main-thread query gives up (nil) within its wait.
        let held = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        index.holdDatabaseLockForTesting(f.path, signal: held, until: release)
        held.wait()
        let start = Date()
        #expect(index.topLevelNames(withPrefix: "item", inFolder: f.path, languages: ["python"]) == nil)
        #expect(Date().timeIntervalSince(start) < 0.1)
        release.signal()
        #expect(index.topLevelNames(withPrefix: "item", inFolder: f.path, languages: ["python"]) != nil)
    }
}

// MARK: - Background member resolution and popup refresh

@MainActor
@Suite("T17.14 cross-file members", .serialized)
struct CrossFileMemberTests {
    @Test func membersArriveInTheBackgroundAndRefreshTheOpenPopup() throws {
        let h = CrossFileHarness()
        let doc = try h.document("swift/main.swift")
        doc.textView.setSelectedRange(NSRange(location: doc.caret(after: "user."), length: 0))
        doc.controller.requestCompletion(manual: false)
        // The type lives in another file: its lookup is pending, nothing inferred yet.
        #expect(doc.controller.isWaitingForImportsForTesting)
        #expect(h.crossFile.hasPendingWork)
        #expect(!doc.controller.currentCandidatesForTesting.contains { $0.source == .inferredType })
        // The queue answers; the notification refreshes the popup at the same caret.
        for _ in 0..<8 where !doc.controller.currentCandidatesForTesting.contains(where: { $0.name == "greet" }) {
            h.crossFile.waitForTypes()
        }
        let names = doc.controller.currentCandidatesForTesting.filter { $0.source == .inferredType }.map(\.name)
        #expect(names.contains("greet") && names.contains("describe"), "\(names)")
        #expect(!names.contains("secret"))
        #expect(h.crossFile.statistics.filesRead >= 2)
        #expect(h.crossFile.retainedBytes > 0 && h.crossFile.retainedBytes < CrossFileTypeService.byteLimit)
    }

    @Test func savingAnotherFileInvalidatesItsTypes() async throws {
        let (root, cleanup) = copyProject()
        defer { cleanup() }
        let h = CrossFileHarness(folder: root)
        let doc = try h.document("swift/main.swift")
        #expect(doc.inferred(after: "user.").map(\.name).contains("greet"))
        let extensions = root + "/swift/UserExtensions.swift"
        let edited = try String(contentsOfFile: extensions, encoding: .utf8)
            .replacingOccurrences(of: "func greet(times: Int)", with: "func wave(times: Int)")
        try Data(edited.utf8).write(to: URL(fileURLWithPath: extensions))
        let start = Date()
        var names: [String] = []
        while Date().timeIntervalSince(start) < 5 {
            h.crossFile.applyInbox()
            names = doc.inferred(after: "user.").map(\.name)
            if names.contains("wave") { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        print(String(format: "T17.14 save → cross-file members updated: %.0f ms", Date().timeIntervalSince(start) * 1000))
        #expect(names.contains("wave") && !names.contains("greet"), "\(names)")
    }

    private func copyProject() -> (String, () -> Void) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("KaruCrossFile-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let target = base.appendingPathComponent("project")
        try! FileManager.default.copyItem(atPath: CrossFileFixtures.project, toPath: target.path)
        return (ProjectFolderStore.standardize(SystemImportFileSystem().realPath(target.path)),
                { try? FileManager.default.removeItem(at: base) })
    }
}

// MARK: - Toggle

@MainActor
@Suite("T17.14 cross-file index toggle", .serialized)
struct CrossFileToggleTests {
    @Test func offRemovesEverythingAtOnceOnBringsItBack() throws {
        let h = CrossFileHarness()
        let swift = try h.document("swift/main.swift")
        let python = try h.document("python/app.py")
        #expect(swift.inferred(after: "user.").contains { $0.name == "greet" })
        #expect(python.candidates(after: "    make_").contains { $0.name == "make_admin" && $0.source == .workspace })
        #expect(!h.crossFile.isReleased)
        let navigatorIndex = h.index

        h.fixture.modules.setEnabled(false, for: .crossFileIndex)
        // Immediately: no cross-file state, names, members or workspace symbols.
        #expect(h.crossFile.isReleased && h.crossFile.retainedBytes == 0)
        #expect(!python.candidates(after: "    make_").contains { $0.source == .workspace })
        #expect(!swift.inferred(after: "user.").contains { $0.name == "greet" })
        #expect(!h.crossFile.hasPendingWork)
        #expect(navigatorIndex.searchSymbols("greet", inFolder: h.folder).isEmpty)
        #expect(WorkspaceSymbolNavigator.availability(index: navigatorIndex, documentPath: swift.path) == .indexOff)

        h.fixture.modules.setEnabled(true, for: .crossFileIndex)
        h.settleIndex()
        #expect(python.candidates(after: "    make_").contains { $0.name == "make_admin" && $0.source == .workspace })
        #expect(swift.inferred(after: "user.").contains { $0.name == "greet" })
        #expect(WorkspaceSymbolNavigator.availability(index: navigatorIndex, documentPath: swift.path)
                == .available(folder: h.folder))
    }

    @Test func otherModulesReleaseTheService() throws {
        let h = CrossFileHarness()
        let swift = try h.document("swift/main.swift")
        #expect(swift.inferred(after: "user.").contains { $0.name == "greet" })
        h.fixture.modules.setEnabled(false, for: .typeInference)
        #expect(h.crossFile.isReleased)
        h.fixture.modules.setEnabled(true, for: .typeInference)
        #expect(swift.inferred(after: "user.").contains { $0.name == "greet" })
        h.fixture.modules.setEnabled(false, for: .completion)
        #expect(h.crossFile.isReleased)
    }
}

// MARK: - Workspace symbol navigator

@MainActor
@Suite("T17.14 workspace symbol navigator", .serialized)
struct WorkspaceSymbolNavigatorTests {
    @Test func searchOpensTheFileAndJumpsToTheSymbol() throws {
        let h = CrossFileHarness()
        let controller = EditorWindowController()
        controller.workspaceIndex = h.index
        controller.load(url: URL(fileURLWithPath: h.folder + "/swift/main.swift"))
        var opened: [EditorWindowController] = []
        let previous = EditorWindowController.fileOpener
        EditorWindowController.fileOpener = { url in
            let other = EditorWindowController()
            other.load(url: url)
            opened.append(other)
            return other
        }
        defer {
            EditorWindowController.fileOpener = previous
            for other in opened { other.close() }
            controller.close()
        }
        let item = NSMenuItem(title: "", action: #selector(EditorWindowController.showWorkspaceSymbols(_:)), keyEquivalent: "")
        #expect(controller.validateMenuItem(item))
        controller.showWorkspaceSymbols(nil)
        let navigator = try #require(controller.workspaceSymbolNavigatorForTesting)
        #expect(navigator.isFieldEnabledForTesting && navigator.messageForTesting == nil)
        navigator.searchForTesting("mkcir")
        let rows = navigator.resultsForTesting
        let row = try #require(rows.firstIndex { $0.symbol.name == "makeCircle" })
        #expect(WorkspaceSymbolNavigator.detail(of: rows[row].symbol, language: .en) == "function · ts/shapes.ts:11")
        #expect(WorkspaceSymbolNavigator.detail(of: rows[row].symbol, language: .zhHans) == "函数 · ts/shapes.ts:11")
        navigator.acceptForTesting(row: row)
        #expect(controller.workspaceSymbolNavigatorForTesting == nil)
        let other = try #require(opened.first)
        #expect(other.currentFileURL?.lastPathComponent == "shapes.ts")
        let text = other.textViewForTesting.string as NSString
        let selection = other.textViewForTesting.selectedRange()
        #expect(text.substring(with: selection) == "makeCircle")
        #expect(text.substring(to: selection.location).components(separatedBy: "\n").count == 11)

        // A symbol of this document is revealed here, without opening anything.
        controller.showWorkspaceSymbols(nil)
        let again = try #require(controller.workspaceSymbolNavigatorForTesting)
        again.searchForTesting("makeAdmin")
        let own = try #require(again.resultsForTesting.firstIndex { $0.symbol.relativePath == "swift/Admin.swift" })
        _ = own
        again.closeForTesting()
        let mainSymbol = WorkspaceSymbol(folder: h.folder, relativePath: "swift/main.swift", languageIdentifier: "swift",
                                         name: "admin", kind: .variable, container: nil, location: 0, line: 3, signature: nil)
        controller.openWorkspaceSymbol(mainSymbol)
        #expect(opened.count == 1)
        let mainText = controller.textViewForTesting.string as NSString
        #expect(mainText.substring(with: controller.textViewForTesting.selectedRange()) == "admin")
    }

    @Test func disabledStatesExplainThemselves() throws {
        let h = CrossFileHarness()
        let index = h.index
        // Not in a project folder (an unsaved buffer, a file elsewhere).
        #expect(WorkspaceSymbolNavigator.availability(index: index, documentPath: nil) == .notInProjectFolder)
        #expect(WorkspaceSymbolNavigator.availability(index: index, documentPath: CrossFileFixtures.base + "/outside/outside.py")
                == .notInProjectFolder)
        let controller = EditorWindowController()
        controller.workspaceIndex = index
        defer { controller.close() }
        let item = NSMenuItem(title: "", action: #selector(EditorWindowController.showWorkspaceSymbols(_:)), keyEquivalent: "")
        #expect(!controller.validateMenuItem(item))
        controller.showWorkspaceSymbols(nil)
        #expect(controller.workspaceSymbolNavigatorForTesting == nil)
        // Index off.
        controller.load(url: URL(fileURLWithPath: h.folder + "/python/app.py"))
        #expect(controller.validateMenuItem(item))
        h.fixture.modules.setEnabled(false, for: .crossFileIndex)
        #expect(!controller.validateMenuItem(item))
        h.fixture.modules.setEnabled(true, for: .crossFileIndex)
        // Indexing: the panel opens disabled with a message, enables when done.
        let slow = IndexFixture()
        for i in 0..<400 { slow.write("m\(i).py", "def f\(i)(): pass\n") }
        let slowIndex = slow.makeIndex()
        slowIndex.start()
        slowIndex.addFolder(slow.folder)
        let state = WorkspaceSymbolNavigator.availability(index: slowIndex,
                                                          documentPath: slow.folder.appendingPathComponent("m0.py").path)
        if case .indexing = state {
            let navigator = WorkspaceSymbolNavigator(textView: NSTextView(), index: slowIndex,
                                                     documentPath: slow.folder.appendingPathComponent("m0.py").path) { _ in }
            navigator.labelLanguageOverride = .zhHans
            navigator.present()
            #expect(!navigator.isFieldEnabledForTesting)
            #expect(navigator.messageForTesting == "正在为项目文件夹建立索引…请稍后再试")
            navigator.closeForTesting()
        }
        #expect(slowIndex.waitUntilIdle())
        #expect(WorkspaceSymbolNavigator.availability(index: slowIndex, documentPath: slow.folder.appendingPathComponent("m0.py").path)
                == .available(folder: slow.path))
    }
}

// MARK: - Strings and shortcut

@MainActor
@Suite("T17.14 strings and shortcut")
struct CrossFileStringsAndShortcutTests {
    @Test func newStringsInThreeLanguages() {
        let keys: [L10nKey] = [.menuWorkspaceSymbols, .workspaceSymbolPlaceholder, .workspaceSymbolNone,
                               .workspaceSymbolNotInFolder, .workspaceSymbolIndexOff, .workspaceSymbolIndexing]
        for key in keys {
            let values = AppLanguage.allCases.map { L10n.string(key, language: $0) }
            #expect(values.allSatisfy { !$0.isEmpty && $0 != key.rawValue }, "\(key)")
            #expect(Set(values).count == 3, "\(key): \(values)")
        }
        #expect(L10n.string(.menuWorkspaceSymbols, language: .zhHans) == "工作区符号…")
        #expect(L10n.string(.menuWorkspaceSymbols, language: .en) == "Workspace Symbols…")
        #expect(L10n.string(.menuWorkspaceSymbols, language: .ja) == "ワークスペースシンボル…")
    }

    @Test func menuItemHasCommandTAndIsRebindable() throws {
        let suite = "CrossFileShortcut-\(UUID().uuidString)"
        let defaults = TestDefaults.make(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let menu = MainMenu.build(applyShortcuts: false)
        let edit = try #require(menu.items.compactMap(\.submenu).first { $0.title == L10n.t(.menuEdit) })
        let item = try #require(edit.items.first { $0.action == #selector(EditorWindowController.showWorkspaceSymbols(_:)) })
        #expect(item.keyEquivalent == "t" && item.keyEquivalentModifierMask == [.command])
        let settings = ShortcutSettings(defaults: defaults)
        let command = try #require(settings.commands.first { $0.id == "menu.showWorkspaceSymbols:" })
        #expect(command.scope == .editor)
        #expect(command.defaultBinding == [ShortcutStroke("t", .command)])
        #expect(command.title == L10n.t(.menuEdit) + " ▸ " + L10n.t(.menuWorkspaceSymbols))
        #expect(settings.conflicts(command.defaultBinding, for: command).isEmpty)
        let rebound = [ShortcutStroke("t", [.command, .option])]
        #expect(settings.set(rebound, for: command).isEmpty)
        #expect(settings.binding(for: command) == rebound)
        guard case .command(let resolved) = ShortcutRouter().resolve(rebound[0], scope: .editor, settings: settings) else {
            Issue.record("rebound key does not resolve")
            return
        }
        #expect(resolved.action == "showWorkspaceSymbols:")
    }
}

// MARK: - Index signatures

@Suite("T17.14 index signatures")
struct IndexSignatureTests {
    @Test func summariesPerLanguage() {
        func signatures(_ text: String, _ language: String) -> [String: String] {
            let data = Data(text.utf8)
            var out: [String: String] = [:]
            for symbol in WorkspaceIndex.symbols(of: data, language: language) {
                out[(symbol.container.map { $0 + "." } ?? "") + symbol.name] = symbol.signature ?? "nil"
            }
            return out
        }
        let py = signatures("""
            class User:
                def __init__(self, name: str, age: int = 0):
                    self.name = name
                def greet(self, other: str) -> str:
                    return other
            def make(name: str) -> User:
                return User(name)
            def plain(a, b):
                return a
            VERSION: str = "1"
            """, "python")
        #expect(py["User"] == "(name: str, age: int = ...)")
        #expect(py["User.greet"] == "(other: str) -> str")
        #expect(py["make"] == "(name: str) -> User")
        #expect(py["plain"] == "(a, b)")
        #expect(py["VERSION"] == "str")
        let ts = signatures("""
            export class Circle { constructor(public radius: number) {} area(): number { return 1 } }
            export function makeCircle(r: number): Circle { return new Circle(r) }
            export const unit: number = 1
            """, "typescript")
        #expect(ts["makeCircle"] == "(r: number) -> Circle")
        #expect(ts["Circle.area"] == "() -> number")
        #expect(ts["Circle"] == "(radius: number)")
        #expect(ts["unit"] == "number")
        let swift = signatures("struct Item {\n    var count: Int\n    func scaled(by factor: Int) -> Int { count * factor }\n}\n"
                               + "func make(_ n: Int) -> Item { Item(count: n) }\n", "swift")
        #expect(swift["Item.scaled"] == "(by factor: Int) -> Int")
        #expect(swift["Item.count"] == "Int")
        #expect(swift["make"] == "(_ n: Int) -> Item")
        let go = signatures("package x\n\ntype Server struct {\n\tAddr string\n}\n\nfunc (s *Server) Start(port int) error {\n\treturn nil\n}\n", "go")
        #expect(go["Server.Start"] == "(port int) error")
        let java = signatures("class Service { public String handle(int n) { return null; } }\n", "java")
        #expect(java["Service.handle"] == "(int n) : String")
    }

    @Test func goMethodsFiledUnderTheirReceiverType() {
        let text = "package x\n\ntype Box[T any] struct{}\n\nfunc (b *Box[T]) Put(v T) {}\nfunc (Box[T]) Len() int { return 0 }\n"
        let symbols = WorkspaceIndex.symbols(of: Data(text.utf8), language: "go")
        #expect(symbols.first { $0.name == "Put" }?.container == "Box")
        #expect(symbols.first { $0.name == "Len" }?.container == "Box")
        #expect(goReceiverType("func (s *Server) Start" as NSString, nameLocation: 17) == "Server")
    }
}

// MARK: - Screenshots

/// `KARU_T1714_SHOTS=<dir> swift test --filter CrossFileScreenshotTests` renders
/// the completion popup with other files' names and the workspace-symbol
/// navigator (dark; zh-Hans and en) into `<dir>`.
@MainActor
@Suite("CrossFileScreenshots", .serialized)
struct CrossFileScreenshotTests {
    private func bitmap(_ view: NSView, _ appearance: NSAppearance.Name) -> NSBitmapImageRep {
        var rep: NSBitmapImageRep!
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: rep)
        }
        return rep
    }

    private func write(_ rep: NSBitmapImageRep, _ name: String, _ dir: String) throws {
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
    }

    @Test func render() throws {
        guard let dir = ProcessInfo.processInfo.environment["KARU_T1714_SHOTS"] else { return }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let h = CrossFileHarness()
        let appearance = NSAppearance.Name.darkAqua
        for language in [AppLanguage.zhHans, .en] {
            // Popup: `make` in app.py — this file's import, then other files' names with signatures.
            let doc = try h.document("python/app.py")
            doc.window.appearance = NSAppearance(named: appearance)
            doc.controller.labelLanguageOverride = language
            let ns = doc.textView.string as NSString
            let at = ns.range(of: "    make_").location + 4
            doc.textView.setSelectedRange(NSRange(location: at, length: 5))
            doc.textView.insertText("make", replacementRange: NSRange(location: at, length: 5))
            doc.controller.requestCompletion(manual: false)
            let panel = try #require(doc.controller.panelForTesting)
            panel.appearance = NSAppearance(named: appearance)
            panel.contentView?.layoutSubtreeIfNeeded()
            let content = try #require(doc.window.contentView)
            content.layoutSubtreeIfNeeded()
            let editor = bitmap(content, appearance)
            let popup = bitmap(try #require(panel.contentView), appearance)
            let size = content.bounds.size
            let canvas = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            canvas.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
            editor.draw(in: NSRect(origin: .zero, size: size))
            popup.draw(in: doc.window.convertFromScreen(panel.frame))
            NSGraphicsContext.restoreGraphicsState()
            try write(canvas, "crossfile-names-dark-\(language.rawValue).png", dir)
            doc.controller.dismissCompletion()

            // Navigator: `greet` across the project folder.
            let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
            let navigator = WorkspaceSymbolNavigator(textView: textView, index: h.index,
                                                     documentPath: h.folder + "/swift/main.swift") { _ in }
            navigator.labelLanguageOverride = language
            navigator.present()
            let navPanel = try #require(navigator.panelForTesting)
            navPanel.appearance = NSAppearance(named: appearance)
            navigator.searchForTesting("greet")
            let navContent = try #require(navPanel.contentView)
            navContent.layoutSubtreeIfNeeded()
            if let table = navigator.tableViewForTesting {
                table.sizeLastColumnToFit()
                table.reloadData()
                table.layoutSubtreeIfNeeded()
            }
            navContent.displayIfNeeded()
            let navBits = bitmap(navContent, appearance)
            let navCanvas = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: navBits.pixelsWide, pixelsHigh: navBits.pixelsHigh,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            navCanvas.size = navContent.bounds.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: navCanvas)
            NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                NSColor.windowBackgroundColor.setFill()
                NSRect(origin: .zero, size: navContent.bounds.size).fill()
            }
            navBits.draw(in: NSRect(origin: .zero, size: navContent.bounds.size))
            // The list is drawn on its own, through PDF (the cached display of
            // the container skips the table's rows).
            if let scroll = navigator.tableViewForTesting?.enclosingScrollView {
                NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                    NSColor.windowBackgroundColor.setFill()
                    scroll.frame.fill()
                    if let table = navigator.tableViewForTesting {
                        for row in 0..<table.numberOfRows {
                            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) else { continue }
                            let pdf = cell.dataWithPDF(inside: cell.bounds)
                            let rowRect = table.rect(ofRow: row)
                            let origin = NSPoint(x: scroll.frame.minX + rowRect.minX,
                                                 y: scroll.frame.maxY - rowRect.maxY)
                            if row == 0 {
                                NSColor.selectedContentBackgroundColor.setFill()
                                NSRect(origin: origin, size: rowRect.size).fill()
                            }
                            NSImage(data: pdf)?.draw(in: NSRect(origin: origin, size: rowRect.size))
                        }
                    }
                }
            }
            NSGraphicsContext.restoreGraphicsState()
            try write(navCanvas, "workspace-symbols-dark-\(language.rawValue).png", dir)
            if let table = navigator.tableViewForTesting {
                print("T17.14 navigator rows (\(language.rawValue)): \(navigator.resultsForTesting.count), table \(table.frame), "
                      + "scroll \(table.enclosingScrollView?.frame ?? .zero), rows \(table.numberOfRows), "
                      + "cell \(String(describing: table.view(atColumn: 0, row: 0, makeIfNecessary: true)?.frame))")
            }
            navigator.closeForTesting()
        }
        print("T17.14 screenshots in \(dir)")
    }
}
