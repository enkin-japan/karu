import AppKit
import Testing
@testable import KaruCore

// T14.11 — crash drafts: unsaved *content* survives a crash.
//
// Three layers, mirroring the session-restore suite (T14.8/T14.9):
//   1. `DraftStore` as pure filesystem logic (round-trip, overwrite, corruption),
//   2. the window controller's arbitration rule — a draft exists exactly while
//      the buffer differs from the saved baseline — and its close/save hooks,
//   3. `AppDelegate.restoreDrafts()` (untitled / file / disk-newer / orphan) plus
//      the wipe on a deliberate quit.
//
// Every case runs against its own temporary drafts directory (and, where a
// document is loaded, its own UserDefaults suite), so neither the developer's
// real drafts nor their session list is ever touched. The AppKit cases are
// serialized because they drive the shared NSApplication window list.

@MainActor
@Suite(.serialized)
struct CrashDraftTests {

// MARK: - Helpers

/// A drafts directory unique to one test, plus the store on top of it. The
/// returned closure tears the directory down.
private static func makeDraftStore() -> (DraftStore, URL, () -> Void) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("KaruDrafts-\(UUID().uuidString)")
    return (DraftStore(directory: dir), dir, {
        try? FileManager.default.removeItem(at: dir)
    })
}

/// An isolated session store, so loading a file in a test never writes into the
/// developer's real restore list.
private static func makeSessionStore() -> (SessionStore, () -> Void) {
    let name = "KaruDraftTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    return (SessionStore(defaults: defaults), {
        UserDefaults().removePersistentDomain(forName: name)
    })
}

private static func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("KaruDraftDoc-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@discardableResult
private static func writeFile(_ dir: URL, _ name: String, _ text: String) throws -> URL {
    let url = dir.appendingPathComponent(name)
    try text.write(to: url, atomically: true, encoding: .utf8)
    return url
}

/// Backdates (or postdates) a file's modification time so the disk-vs-draft
/// conflict rule can be exercised without depending on clock granularity.
private static func setModificationDate(_ url: URL, offset: TimeInterval) throws {
    try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(offset)], ofItemAtPath: url.path)
}

/// The controller's editor view (the window keeps it private, so reach it
/// through the view tree as the other AppKit tests do).
private static func editor(of controller: EditorWindowController?) -> NSTextView? {
    controller?.window?.contentView?.firstEditorTextView()
}

/// A window controller wired to isolated stores.
private static func makeController(drafts: DraftStore,
                                   session: SessionStore) -> EditorWindowController {
    let controller = EditorWindowController()
    controller.draftStore = drafts
    controller.sessionStore = session
    return controller
}

/// The open editor window showing `url`, whichever test opened it.
private static func window(for url: URL) -> EditorWindowController? {
    NSApplication.shared.windows
        .compactMap { $0.windowController as? EditorWindowController }
        .first { $0.currentFileURL.map { UbiquitousFile.sameFile($0, url) } ?? false }
}

/// The open untitled editor window whose buffer holds `content`.
private static func untitledWindow(holding content: String) -> EditorWindowController? {
    NSApplication.shared.windows
        .compactMap { $0.windowController as? EditorWindowController }
        .first { $0.currentFileURL == nil && editor(of: $0)?.string == content }
}

// MARK: - 1. DraftStore pure logic

@Test func draftRoundTripsThroughDiskAndCanBeRemoved() {
    let (store, _, teardown) = Self.makeDraftStore()
    defer { teardown() }

    let id = UUID()
    store.write(id: id, content: "half a thought", originalPath: "/tmp/notes.txt")

    let drafts = store.drafts()
    #expect(drafts.count == 1)
    #expect(drafts[0].id == id)
    #expect(drafts[0].content == "half a thought")
    #expect(drafts[0].originalPath == "/tmp/notes.txt")
    #expect(abs(drafts[0].savedAt.timeIntervalSinceNow) < 5)

    store.remove(id: id)
    #expect(store.drafts().isEmpty)
    store.remove(id: id)                    // second removal is a no-op
    #expect(store.drafts().isEmpty)
}

@Test func rewritingTheSameIdReplacesTheContent() {
    let (store, _, teardown) = Self.makeDraftStore()
    defer { teardown() }

    let id = UUID()
    store.write(id: id, content: "first", originalPath: nil)
    store.write(id: id, content: "second, longer version", originalPath: nil)

    // One draft, holding the newest text — no leftovers of the old one.
    #expect(store.drafts().count == 1)
    #expect(store.drafts()[0].content == "second, longer version")
}

@Test func untitledAndFileDraftsCoexistAndClearWipesAll() {
    let (store, _, teardown) = Self.makeDraftStore()
    defer { teardown() }

    let untitled = UUID()
    let named = UUID()
    store.write(id: untitled, content: "scratch", originalPath: nil)
    store.write(id: named, content: "edited", originalPath: "/tmp/a.txt")

    let byID = Dictionary(uniqueKeysWithValues: store.drafts().map { ($0.id, $0) })
    #expect(byID.count == 2)
    #expect(byID[untitled]?.originalPath == nil)
    #expect(byID[named]?.originalPath == "/tmp/a.txt")

    store.clear()
    #expect(store.drafts().isEmpty)
    // Clearing an already-gone directory must not throw or resurrect anything.
    store.clear()
    #expect(store.drafts().isEmpty)
}

@Test func unreadableDraftsAreSkippedInsteadOfTrusted() throws {
    let (store, dir, teardown) = Self.makeDraftStore()
    defer { teardown() }

    let good = UUID()
    let corrupt = UUID()
    store.write(id: good, content: "intact", originalPath: nil)
    store.write(id: corrupt, content: "content is fine", originalPath: nil)

    // Truncated / garbage metadata.
    try Data("{not json".utf8)
        .write(to: dir.appendingPathComponent("\(corrupt.uuidString).json"))
    // A metadata file whose name is not a UUID at all.
    try Data("{}".utf8).write(to: dir.appendingPathComponent("stray.json"))
    // Metadata with no content file next to it.
    let orphan = UUID()
    store.write(id: orphan, content: "gone", originalPath: nil)
    try FileManager.default.removeItem(at: dir.appendingPathComponent(orphan.uuidString))

    #expect(store.drafts().map(\.id) == [good])
}

@Test func draftsComeBackOldestFirst() {
    let (store, _, teardown) = Self.makeDraftStore()
    defer { teardown() }

    let first = UUID()
    let second = UUID()
    store.write(id: first, content: "older", originalPath: nil)
    Thread.sleep(forTimeInterval: 0.02)
    store.write(id: second, content: "newer", originalPath: nil)

    #expect(store.drafts().map(\.id) == [first, second])
}

// MARK: - 2. Arbitration rule (buffer ≠ baseline ⟺ a draft exists)

@Test func editingWritesADraftAndUndoingBackToTheBaselineRemovesIt() throws {
    let (drafts, _, dropDrafts) = Self.makeDraftStore()
    let (session, dropSession) = Self.makeSessionStore()
    let dir = try Self.makeTempDir()
    defer { dropDrafts(); dropSession(); try? FileManager.default.removeItem(at: dir) }
    let url = try Self.writeFile(dir, "notes.txt", "one\ntwo\n")

    let controller = Self.makeController(drafts: drafts, session: session)
    controller.load(url: url)
    let editor = try #require(Self.editor(of: controller))

    editor.insertText("edited ", replacementRange: NSRange(location: 0, length: 0))
    controller.flushDraftNow()
    controller.waitForDraftWrites()

    let saved = drafts.drafts()
    #expect(saved.count == 1)
    #expect(saved[0].content == "edited one\ntwo\n")
    #expect(saved[0].originalPath == url.path)

    // Undo puts the buffer back on the baseline: nothing left worth recovering.
    editor.undoManager?.undo()
    #expect(editor.string == "one\ntwo\n")
    controller.flushDraftNow()
    controller.waitForDraftWrites()
    #expect(drafts.drafts().isEmpty)

    controller.window?.close()
}

@Test func savingRemovesTheDraft() throws {
    let (drafts, _, dropDrafts) = Self.makeDraftStore()
    let (session, dropSession) = Self.makeSessionStore()
    let dir = try Self.makeTempDir()
    defer { dropDrafts(); dropSession(); try? FileManager.default.removeItem(at: dir) }
    let url = try Self.writeFile(dir, "save.txt", "before\n")

    let controller = Self.makeController(drafts: drafts, session: session)
    controller.load(url: url)
    let editor = try #require(Self.editor(of: controller))

    editor.insertText("after\n", replacementRange: NSRange(location: 0, length: 0))
    controller.flushDraftNow()
    controller.waitForDraftWrites()
    #expect(drafts.drafts().count == 1)

    controller.saveDocument(nil)
    controller.waitForDraftWrites()
    #expect(drafts.drafts().isEmpty)
    #expect(try String(contentsOf: url, encoding: .utf8) == "after\nbefore\n")

    controller.window?.close()
}

@Test func anUntitledBufferGetsADraftWithNoOriginalPath() {
    let (drafts, _, dropDrafts) = Self.makeDraftStore()
    let (session, dropSession) = Self.makeSessionStore()
    defer { dropDrafts(); dropSession() }

    let controller = Self.makeController(drafts: drafts, session: session)
    let editor = Self.editor(of: controller)
    editor?.insertText("a thought worth keeping",
                       replacementRange: NSRange(location: 0, length: 0))
    controller.flushDraftNow()
    controller.waitForDraftWrites()

    #expect(drafts.drafts().count == 1)
    #expect(drafts.drafts()[0].originalPath == nil)
    #expect(drafts.drafts()[0].content == "a thought worth keeping")

    controller.window?.close()
}

@Test func typingAloneWritesTheDraftOnceTheDebounceFires() async throws {
    let (drafts, _, dropDrafts) = Self.makeDraftStore()
    let (session, dropSession) = Self.makeSessionStore()
    defer { dropDrafts(); dropSession() }

    let controller = Self.makeController(drafts: drafts, session: session)
    controller.draftDebounceInterval = 0        // no waiting around in a test

    Self.editor(of: controller)?.insertText("typed, never flushed by hand",
                                            replacementRange: NSRange(location: 0, length: 0))
    // Deliberately deferred: the write must not ride on the keystroke itself.
    #expect(drafts.drafts().isEmpty)

    try await Task.sleep(nanoseconds: 200_000_000)
    controller.waitForDraftWrites()
    #expect(drafts.drafts().map(\.content) == ["typed, never flushed by hand"])

    controller.window?.close()
}

// MARK: - 3. Close vs. quit

@Test func closingAWindowByHandRemovesItsDraft() {
    let (drafts, _, dropDrafts) = Self.makeDraftStore()
    let (session, dropSession) = Self.makeSessionStore()
    defer { dropDrafts(); dropSession() }

    let controller = Self.makeController(drafts: drafts, session: session)
    Self.editor(of: controller)?.insertText("throwaway",
                                            replacementRange: NSRange(location: 0, length: 0))
    controller.flushDraftNow()
    controller.waitForDraftWrites()
    #expect(drafts.drafts().count == 1)

    // The user closed it (having answered the unsaved-changes prompt).
    controller.window?.close()
    controller.waitForDraftWrites()
    #expect(drafts.drafts().isEmpty)
}

@Test func closingWhileTerminatingKeepsTheDraftForTheDelegateToWipe() {
    let (drafts, _, dropDrafts) = Self.makeDraftStore()
    let (session, dropSession) = Self.makeSessionStore()
    defer { dropDrafts(); dropSession() }

    let controller = Self.makeController(drafts: drafts, session: session)
    controller.isAppTerminating = { true }               // quit in progress
    Self.editor(of: controller)?.insertText("mid-quit",
                                            replacementRange: NSRange(location: 0, length: 0))
    controller.flushDraftNow()
    controller.waitForDraftWrites()

    controller.window?.close()
    controller.waitForDraftWrites()
    // A single window closing during a quit decides nothing: clearing the
    // drafts is the delegate's job, once termination is actually approved.
    #expect(drafts.drafts().count == 1)
}

// MARK: - 4. Restore

@Test func anUntitledDraftComesBackInItsOwnDirtyWindow() {
    let (drafts, _, dropDrafts) = Self.makeDraftStore()
    let (session, dropSession) = Self.makeSessionStore()
    defer { dropDrafts(); dropSession() }

    let id = UUID()
    drafts.write(id: id, content: "recovered scratch", originalPath: nil)

    let delegate = AppDelegate()
    delegate.draftStore = drafts
    delegate.sessionStore = session
    #expect(delegate.restoreDrafts() == 1)

    let restored = Self.untitledWindow(holding: "recovered scratch")
    #expect(restored != nil)
    #expect(restored?.documentController.isDirty == true)
    // The draft's identity is inherited, so later edits update the same file.
    #expect(restored?.draftID == id)

    restored?.window?.close()
}

@Test func aDraftNewerThanItsFileReplacesTheBufferAndStaysDirty() throws {
    let (drafts, _, dropDrafts) = Self.makeDraftStore()
    let (session, dropSession) = Self.makeSessionStore()
    let dir = try Self.makeTempDir()
    defer { dropDrafts(); dropSession(); try? FileManager.default.removeItem(at: dir) }

    let url = try Self.writeFile(dir, "crash.txt", "on disk\n")
    try Self.setModificationDate(url, offset: -600)     // the draft is newer
    session.record(path: url.path, caret: 0, scrollY: 0)
    drafts.write(id: UUID(), content: "on disk\nplus unsaved\n", originalPath: url.path)

    let delegate = AppDelegate()
    delegate.draftStore = drafts
    delegate.sessionStore = session
    #expect(delegate.restoreSession() == 1)
    #expect(delegate.restoreDrafts() == 1)

    let controller = try #require(Self.window(for: url))
    #expect(Self.editor(of: controller)?.string == "on disk\nplus unsaved\n")
    #expect(controller.documentController.isDirty)
    // The baseline is still the file's contents, so the close prompt (and a
    // later undo back to it) behave exactly as they did before the crash.
    #expect(controller.documentController.matchesBaseline("on disk\n"))

    controller.window?.close()
}

@Test func aFileTouchedAfterTheDraftWinsAndTheDraftIsDropped() throws {
    let (drafts, _, dropDrafts) = Self.makeDraftStore()
    let (session, dropSession) = Self.makeSessionStore()
    let dir = try Self.makeTempDir()
    defer { dropDrafts(); dropSession(); try? FileManager.default.removeItem(at: dir) }

    let url = try Self.writeFile(dir, "raced.txt", "newer on disk\n")
    session.record(path: url.path, caret: 0, scrollY: 0)
    drafts.write(id: UUID(), content: "stale draft\n", originalPath: url.path)
    try Self.setModificationDate(url, offset: 600)     // edited after the draft

    let delegate = AppDelegate()
    delegate.draftStore = drafts
    delegate.sessionStore = session
    #expect(delegate.restoreSession() == 1)
    #expect(delegate.restoreDrafts() == 0)

    let controller = try #require(Self.window(for: url))
    #expect(Self.editor(of: controller)?.string == "newer on disk\n")
    #expect(controller.documentController.isDirty == false)
    #expect(drafts.drafts().isEmpty)

    controller.window?.close()
}

@Test func aDraftWhoseFileVanishedComesBackAsUntitled() throws {
    let (drafts, _, dropDrafts) = Self.makeDraftStore()
    let (session, dropSession) = Self.makeSessionStore()
    let dir = try Self.makeTempDir()
    defer { dropDrafts(); dropSession(); try? FileManager.default.removeItem(at: dir) }

    let url = try Self.writeFile(dir, "deleted.txt", "was here\n")
    drafts.write(id: UUID(), content: "was here\nand then some\n", originalPath: url.path)
    try FileManager.default.removeItem(at: url)         // deleted while away

    let delegate = AppDelegate()
    delegate.draftStore = drafts
    delegate.sessionStore = session
    #expect(delegate.restoreDrafts() == 1)

    // The content is the only copy left, so it must not be thrown away.
    let restored = Self.untitledWindow(holding: "was here\nand then some\n")
    #expect(restored != nil)
    #expect(restored?.currentFileURL == nil)
    #expect(restored?.documentController.isDirty == true)

    restored?.window?.close()
}

@Test func aDraftForAFileNoSessionRestoredOpensItsOwnWindow() throws {
    let (drafts, _, dropDrafts) = Self.makeDraftStore()
    let (session, dropSession) = Self.makeSessionStore()
    let dir = try Self.makeTempDir()
    defer { dropDrafts(); dropSession(); try? FileManager.default.removeItem(at: dir) }

    // No session entry at all for this file — only a draft.
    let url = try Self.writeFile(dir, "orphan.txt", "on disk\n")
    try Self.setModificationDate(url, offset: -600)
    drafts.write(id: UUID(), content: "on disk\nunsaved tail\n", originalPath: url.path)

    let delegate = AppDelegate()
    delegate.draftStore = drafts
    delegate.sessionStore = session
    #expect(delegate.restoreSession() == 0)
    #expect(delegate.restoreDrafts() == 1)

    let controller = try #require(Self.window(for: url))
    #expect(Self.editor(of: controller)?.string == "on disk\nunsaved tail\n")
    #expect(controller.documentController.isDirty)

    controller.window?.close()
}

// MARK: - 5. A deliberate quit wipes the drafts

@Test func approvingTerminationClearsEveryDraft() {
    let (drafts, _, dropDrafts) = Self.makeDraftStore()
    let (session, dropSession) = Self.makeSessionStore()
    defer { dropDrafts(); dropSession() }

    drafts.write(id: UUID(), content: "unsaved", originalPath: nil)
    drafts.write(id: UUID(), content: "also unsaved", originalPath: "/tmp/x.txt")
    #expect(drafts.drafts().count == 2)

    let delegate = AppDelegate()
    delegate.draftStore = drafts
    delegate.sessionStore = session

    #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
    // Reaching .terminateNow means every window passed its unsaved-changes
    // confirmation, so nothing is left to recover.
    #expect(drafts.drafts().isEmpty)
}

}

private extension NSView {
    /// Depth-first search for the window's editor view.
    func firstEditorTextView() -> NSTextView? {
        for sub in subviews {
            if let hit = sub as? NSTextView { return hit }
            if let hit = sub.firstEditorTextView() { return hit }
        }
        return nil
    }
}
