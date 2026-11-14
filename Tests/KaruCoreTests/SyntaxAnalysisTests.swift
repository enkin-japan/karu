import AppKit
import Foundation
import Testing
@testable import KaruCore

// M17 T17.11a — the syntax layer of `DocumentAnalysis`: built in scheduler
// slices per version, updated incrementally from the edit journal, gated by
// completion + type inference, released on language change, summary mode
// with on-demand statements for large documents.

private func isolatedDefaults() -> UserDefaults {
    let name = "SyntaxAnalysisTests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

@MainActor
private func pump(_ seconds: TimeInterval) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

@MainActor
private func pump(until done: () -> Bool, timeout: TimeInterval = 10) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !done(), Date() < deadline {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

/// A text view with an analysis registered on its storage hub, on isolated
/// module settings and its own scheduler.
@MainActor
private final class Document {
    let center = NotificationCenter()
    let settings: ModuleSettings
    let scheduler = AnalysisScheduler()
    let textView: NSTextView
    let hub = TextStorageObserverHub()
    let analysis: DocumentAnalysis

    init(text: String, language: String) {
        settings = ModuleSettings(defaults: isolatedDefaults(), center: center)
        textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        textView.textStorage?.delegate = hub
        analysis = DocumentAnalysis(textView: textView, moduleSettings: settings,
                                    moduleCenter: center, scheduler: scheduler)
        hub.add(analysis)
        textView.string = text
        analysis.setLanguage(identifier: language)
    }

    var text: NSString { textView.textStorage!.mutableString }

    func replace(_ range: NSRange, with string: String) {
        textView.textStorage!.replaceCharacters(in: range, with: string)
    }

    func close() { analysis.cancelPendingWork() }
}

private let inferenceSamples = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/M17/inference")

@MainActor
@Suite("Syntax analysis", .serialized)
struct SyntaxAnalysisTests {

    @Test func builtInSlicesAfterOpeningAndUpdatedIncrementallyAfterEdits() async throws {
        let source = try String(contentsOf: inferenceSamples.appendingPathComponent("sample_1000.py"), encoding: .utf8)
        let doc = Document(text: source, language: "python")
        defer { doc.close() }
        #expect(doc.analysis.syntax == nil)              // scheduled, not built synchronously
        await pump(until: { doc.analysis.syntax != nil })
        let first = try #require(doc.analysis.syntax)
        #expect(first.version == doc.analysis.version)
        #expect(first.tree == SyntaxBuild.parse(doc.text, dialect: .python))
        #expect(doc.analysis.syntaxAnalysis.buildCount == 1)
        #expect(!doc.analysis.syntaxAnalysis.lastBuildStats.incremental)

        // A burst of edits: the published snapshot stays readable with its
        // journal; one incremental build follows.
        let middle = doc.text.range(of: "\n", options: [], range: NSRange(location: doc.text.length / 2,
                                                                             length: doc.text.length / 2)).location
        doc.replace(NSRange(location: middle, length: 0), with: "\nvalue = 1")
        doc.replace(NSRange(location: middle + 4, length: 2), with: "")
        #expect(doc.analysis.syntax == nil)
        let published = try #require(doc.analysis.publishedSyntax)
        #expect(published.snapshot.version == first.version && published.journal.edits.count == 2)
        await pump(until: { doc.analysis.syntax != nil })
        let second = try #require(doc.analysis.syntax)
        #expect(second.tree == SyntaxBuild.parse(doc.text, dialect: .python))
        #expect(doc.analysis.syntaxAnalysis.buildCount == 2)
        let stats = doc.analysis.syntaxAnalysis.lastBuildStats
        #expect(stats.incremental)
        #expect(stats.reusedStatements > stats.reparsedStatements)
        #expect(doc.analysis.publishedSyntax?.journal.isEmpty == true)

        // Far-apart edits: one covering edit (the range between is reparsed).
        doc.replace(NSRange(location: 0, length: 0), with: "# head\n")
        doc.replace(NSRange(location: doc.text.length, length: 0), with: "\ntail = 2\n")
        await pump(until: { doc.analysis.syntax != nil })
        #expect(doc.analysis.syntax?.tree == SyntaxBuild.parse(doc.text, dialect: .python))
        #expect(doc.analysis.syntaxAnalysis.lastBuildStats.incremental)
    }

    @Test func editsBetweenSlicesDropTheStaleBuild() async throws {
        // Large enough that the build takes several slices.
        var source = try String(contentsOf: inferenceSamples.appendingPathComponent("sample_1000.ts"), encoding: .utf8)
        source = String(repeating: source + "\n", count: 12)
        let doc = Document(text: source, language: "typescript")
        defer { doc.close() }
        await pump(until: { doc.analysis.syntaxAnalysis.lastBuildStats.slices > 0 || doc.analysis.syntax != nil },
                   timeout: 3)
        // Edit while (or after) building; whatever was in flight is dropped.
        doc.replace(NSRange(location: 5, length: 0), with: "let inserted = 1;\n")
        await pump(until: { doc.analysis.syntax != nil })
        let snapshot = try #require(doc.analysis.syntax)
        #expect(snapshot.version == doc.analysis.version)
        #expect(snapshot.tree == SyntaxBuild.parse(doc.text, dialect: .typescript))
    }

    @Test func gatedByCompletionAndTypeInference() async throws {
        let doc = Document(text: "def f(a):\n    return a\n", language: "python")
        defer { doc.close() }
        let built = try #require(doc.analysis.ensureSyntax())
        #expect(built.tree != nil)
        #expect(!doc.analysis.syntaxAnalysis.isReleased)

        // Turning another module off carries the snapshot to the new version.
        doc.settings.setEnabled(false, for: .highlight)
        #expect(doc.analysis.syntax?.version == doc.analysis.version)
        #expect(doc.analysis.syntaxAnalysis.buildCount == 1)

        // Type inference off: everything released, edits schedule nothing.
        doc.settings.setEnabled(false, for: .typeInference)
        #expect(doc.analysis.syntax == nil && doc.analysis.publishedSyntax == nil)
        #expect(doc.analysis.syntaxAnalysis.isReleased)
        doc.replace(NSRange(location: 0, length: 0), with: "x = 1\n")
        await pump(0.2)
        #expect(doc.analysis.syntaxAnalysis.isReleased)
        // A synchronous request while off is transient.
        #expect(doc.analysis.ensureSyntax()?.tree != nil)
        #expect(doc.analysis.syntaxAnalysis.isReleased)

        // Back on: rebuilt (scheduled).
        doc.settings.setEnabled(true, for: .typeInference)
        await pump(until: { doc.analysis.syntax != nil })
        #expect(doc.analysis.syntax?.tree == SyntaxBuild.parse(doc.text, dialect: .python))

        // Completion off: released as well.
        doc.settings.setEnabled(false, for: .completion)
        #expect(doc.analysis.syntaxAnalysis.isReleased)

        // All four analysis modules off: the whole analysis is released.
        doc.settings.setEnabled(false, for: .crossFileIndex)
        #expect(doc.analysis.isRuntimeStateReleased)
    }

    @Test func languageChangesReleaseAndRebuild() async throws {
        let doc = Document(text: "const a = [1, 2];\nfunction f(x) { return x.y; }\n", language: "javascript")
        defer { doc.close() }
        #expect(doc.analysis.ensureSyntax()?.dialect == .javascript)
        doc.analysis.setLanguage(identifier: "typescript")
        #expect(doc.analysis.syntax == nil && doc.analysis.publishedSyntax == nil)
        await pump(until: { doc.analysis.syntax != nil })
        #expect(doc.analysis.syntax?.dialect == .typescript)
        // A language without a parser holds nothing.
        doc.analysis.setLanguage(identifier: "go")
        await pump(0.2)
        #expect(doc.analysis.syntaxAnalysis.isReleased)
        #expect(doc.analysis.ensureSyntax() == nil)
        doc.analysis.setLanguage(identifier: "typescriptreact")
        #expect(doc.analysis.ensureSyntax()?.dialect == .typescriptReact)
    }

    @Test func largeDocumentsKeepASummaryAndParseStatementsOnDemand() async throws {
        let block = try String(contentsOf: inferenceSamples.appendingPathComponent("sample_1000.py"), encoding: .utf8)
        var source = ""
        while (source as NSString).length <= SyntaxBuild.fullTreeUnitLimit { source += block + "\n" }
        let doc = Document(text: source, language: "python")
        defer { doc.close() }
        let snapshot = try #require(doc.analysis.ensureSyntax())
        let summary = try #require(snapshot.summary)
        #expect(snapshot.tree == nil)
        #expect(summary.textLength == doc.text.length)
        // Retained: the summary only (no tree), well under the tree's size.
        #expect(doc.analysis.syntaxRetainedBytes < doc.text.length)

        let offset = doc.text.range(of: "    def ", options: [], range: NSRange(location: doc.text.length / 2,
                                                                                  length: doc.text.length / 2)).location
        let statement = try #require(doc.analysis.syntaxStatement(at: offset))
        let node = statement.tree[statement.node]
        #expect(Int(node.start) <= offset && offset <= Int(node.end))
        #expect(statement.tree.kind(statement.node) == .classDef || statement.tree.kind(statement.node) == .funcDef)
        // The on-demand subtree equals the full parse's.
        let full = SyntaxBuild.parse(doc.text, dialect: .python)
        let fullStatement = try #require(full.topLevelStatement(at: offset))
        #expect(Array(statement.tree.nodes.dropLast()) == Array(full.nodes[full.subtree(fullStatement)]))
        #expect(doc.analysis.syntaxAnalysis.cache.count == 1)
        _ = doc.analysis.syntaxStatement(at: offset)
        #expect(doc.analysis.syntaxAnalysis.cache.count == 1)    // cached
        #expect(doc.analysis.syntaxAnalysis.cache.bytes <= SyntaxSubtreeCache.defaultByteLimit)

        // An edit clears the cache; the summary is updated incrementally.
        doc.replace(NSRange(location: offset, length: 0), with: "    pass\n")
        #expect(doc.analysis.syntaxAnalysis.cache.isEmpty)
        let updated = try #require(doc.analysis.ensureSyntax()?.summary)
        #expect(doc.analysis.syntaxAnalysis.lastBuildStats.incremental)
        var fresh = SyntaxBuild(dialect: .python, text: doc.text, mode: .summary)
        #expect(updated == fresh.finish(doc.text)?.summary)
    }
}
