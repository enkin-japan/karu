import AppKit
import Testing
@testable import KaruCore

// T14.11 — crash drafts: unsaved *content* survives a crash.
//
// Three layers, mirroring the session-restore suite (T14.8/T14.9):
//   1. `DraftStore` as pure filesystem logic (round-trip, overwrite, corruption),
//   2. the window controller's arbitration rule — a draft exists exactly while
//      the buffer differs from the saved baseline — and its close/save hooks,
//   3. `AppDelegate.restoreDrafts()` (untitled / file / orphan, and the R07 / D4
//      conflict cases where the draft is kept as an untitled copy) plus the
//      wipe on a deliberate quit.
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
    let defaults = TestDefaults.make(name)
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

    // Truncated / garbage header line.
    try Data("{not json\ncontent is fine".utf8)
        .write(to: dir.appendingPathComponent("\(corrupt.uuidString).draft"))
    // A draft file whose name is not a UUID at all.
    try Data("{}\n".utf8).write(to: dir.appendingPathComponent("stray.draft"))
    // A legacy sidecar with no content file next to it.
    let orphan = UUID()
    try Data(#"{"savedAt":0}"#.utf8)
        .write(to: dir.appendingPathComponent("\(orphan.uuidString).json"))

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

// MARK: - 2b. Checkpoint timing, baseline off the main thread, failures (R05)

@Test func continuousTypingStillWritesADraftWithinTheMaximumInterval() throws {
    let (drafts, _, dropDrafts) = Self.makeDraftStore()
    let (session, dropSession) = Self.makeSessionStore()
    defer { dropDrafts(); dropSession() }

    let controller = Self.makeController(drafts: drafts, session: session)
    let clock = ManualCheckpointScheduler()
    controller.draftCheckpointScheduler = clock
    #expect(controller.draftDebounceInterval == EditorWindowController.defaultDraftDebounce)
    #expect(controller.draftMaxInterval == EditorWindowController.defaultDraftMaxInterval)
    let editor = try #require(Self.editor(of: controller))

    // A keystroke every 0.5 s: the debounce alone would never fire.
    var t: TimeInterval = 0
    while t < 10 {
        clock.advance(to: t)
        editor.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        t += 0.5
    }
    controller.waitForDraftWrites()
    #expect(drafts.drafts().isEmpty)

    clock.advance(to: 10)
    controller.waitForDraftWrites()
    #expect(drafts.drafts().map(\.content) == [String(repeating: "x", count: 20)])

    controller.window?.close()
}

@Test func theSnapshotCarriesTheBaselineDigestInsteadOfAMainThreadVerdict() throws {
    let (drafts, _, dropDrafts) = Self.makeDraftStore()
    let (session, dropSession) = Self.makeSessionStore()
    let dir = try Self.makeTempDir()
    defer { dropDrafts(); dropSession(); try? FileManager.default.removeItem(at: dir) }
    let url = try Self.writeFile(dir, "digest.txt", "baseline\n")

    let controller = Self.makeController(drafts: drafts, session: session)
    controller.load(url: url)
    let editor = try #require(Self.editor(of: controller))
    editor.insertText("x", replacementRange: NSRange(location: 0, length: 0))
    editor.undoManager?.undo()

    // The main thread hands over text + digest; deciding "back at baseline"
    // is the background job's business.
    let snapshot = controller.makeDraftSnapshot()
    #expect(snapshot.content == "baseline\n")
    #expect(snapshot.baselineDigest == controller.documentController.baselineSHA256)
    #expect(snapshot.id == controller.draftID)
    #expect(snapshot.originalPath == url.path)
    #expect(snapshot.matchesBaseline())

    controller.flushDraftNow()
    controller.waitForDraftWrites()
    #expect(drafts.drafts().isEmpty)

    controller.window?.close()
}

@Test func aDraftOfALoadedFileRecordsItsDiskBase() throws {
    let (drafts, _, dropDrafts) = Self.makeDraftStore()
    let (session, dropSession) = Self.makeSessionStore()
    let dir = try Self.makeTempDir()
    defer { dropDrafts(); dropSession(); try? FileManager.default.removeItem(at: dir) }
    let url = try Self.writeFile(dir, "based.txt", "on disk\n")

    let controller = Self.makeController(drafts: drafts, session: session)
    controller.load(url: url)
    let diskState = try #require(controller.documentController.diskState)
    Self.editor(of: controller)?.insertText("edit ", replacementRange: NSRange(location: 0, length: 0))
    controller.flushDraftNow()
    controller.waitForDraftWrites()

    let saved = try #require(drafts.drafts().first)
    #expect(saved.base == diskState)
    #expect(saved.base == controller.documentController.diskState)

    controller.window?.close()
}

@Test func aFailingDraftWriteFlashesOnceUntilAWriteSucceeds() throws {
    let dir = try Self.makeTempDir()
    let (session, dropSession) = Self.makeSessionStore()
    defer { dropSession(); try? FileManager.default.removeItem(at: dir) }
    // A regular file where the drafts directory should be: every write fails.
    let draftsDir = dir.appendingPathComponent("Drafts")
    let block = { try Data("in the way".utf8).write(to: draftsDir) }
    try block()
    let drafts = DraftStore(directory: draftsDir)

    let controller = Self.makeController(drafts: drafts, session: session)
    var flashes: [String] = []
    controller.statusFlashObserver = { flashes.append($0) }
    let editor = try #require(Self.editor(of: controller))

    editor.insertText("a", replacementRange: NSRange(location: 0, length: 0))
    controller.flushDraftNow()
    controller.waitForDraftWrites()
    #expect(controller.draftCheckpointFailing)
    #expect(flashes == [L10n.t(.draftCheckpointFailed)])

    editor.insertText("b", replacementRange: NSRange(location: 0, length: 0))
    controller.flushDraftNow()
    controller.waitForDraftWrites()
    #expect(controller.draftCheckpointFailing)
    #expect(flashes.count == 1)                 // consecutive failure: quiet

    // The obstacle goes away: the next write lands and re-arms the note.
    try FileManager.default.removeItem(at: draftsDir)
    editor.insertText("c", replacementRange: NSRange(location: 0, length: 0))
    controller.flushDraftNow()
    controller.waitForDraftWrites()
    #expect(!controller.draftCheckpointFailing)
    #expect(drafts.drafts().map(\.content) == ["cba"])
    #expect(flashes.count == 1)

    // A fresh failure after that success is reported again.
    try FileManager.default.removeItem(at: draftsDir)
    try block()
    editor.insertText("d", replacementRange: NSRange(location: 0, length: 0))
    controller.flushDraftNow()
    controller.waitForDraftWrites()
    #expect(controller.draftCheckpointFailing)
    #expect(flashes == [L10n.t(.draftCheckpointFailed), L10n.t(.draftCheckpointFailed)])

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

// Formerly `aFileTouchedAfterTheDraftWinsAndTheDraftIsDropped`: under R07 / D4
// a base-less draft whose file is newer is kept as an untitled copy instead.
@Test func aFileTouchedAfterABaselessDraftKeepsTheDraftAsACopy() throws {
    let (drafts, _, dropDrafts) = Self.makeDraftStore()
    let (session, dropSession) = Self.makeSessionStore()
    let dir = try Self.makeTempDir()
    defer { dropDrafts(); dropSession(); try? FileManager.default.removeItem(at: dir) }

    let url = try Self.writeFile(dir, "raced.txt", "newer on disk\n")
    session.record(path: url.path, caret: 0, scrollY: 0)
    let id = UUID()
    drafts.write(id: id, content: "stale draft\n", originalPath: url.path)
    try Self.setModificationDate(url, offset: 600)     // edited after the draft

    let delegate = AppDelegate()
    delegate.draftStore = drafts
    delegate.sessionStore = session
    #expect(delegate.restoreSession() == 1)
    #expect(delegate.restoreDrafts() == 1)

    let controller = try #require(Self.window(for: url))
    #expect(Self.editor(of: controller)?.string == "newer on disk\n")
    #expect(controller.documentController.isDirty == false)
    let copy = try #require(Self.untitledWindow(holding: "stale draft\n"))
    #expect(copy.documentController.isDirty)
    #expect(copy.draftID == id)
    #expect(drafts.drafts().map(\.id) == [id])

    copy.window?.close()
    controller.window?.close()
}

// MARK: - 4b. Restore conflicts (R07 / D4): never delete the only copy

/// The disk state a window would record right after loading `url`.
private static func base(of url: URL) throws -> DiskState {
    try DiskState.read(url)
}

/// Rewrites `url` in place (same inode), as an editor saving without rename.
private static func overwriteInPlace(_ url: URL, _ text: String) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.truncate(atOffset: 0)
    try handle.write(contentsOf: Data(text.utf8))
}

/// Replaces `url` with a new file holding `text` via rename(2) (new inode),
/// as an atomic-save editor or a sync client does.
private static func replaceByRename(_ url: URL, _ text: String) throws {
    let temp = url.deletingLastPathComponent()
        .appendingPathComponent(".replace-\(UUID().uuidString)")
    try Data(text.utf8).write(to: temp)
    let failed = temp.withUnsafeFileSystemRepresentation { src in
        url.withUnsafeFileSystemRepresentation { dst in
            Foundation.rename(src!, dst!) != 0
        }
    }
    if failed { throw POSIXError(.EIO) }
}

/// Every open editor window showing `url` (to catch duplicates).
private static func windows(for url: URL) -> [EditorWindowController] {
    NSApplication.shared.windows
        .compactMap { $0.windowController as? EditorWindowController }
        .filter { $0.currentFileURL.map { UbiquitousFile.sameFile($0, url) } ?? false }
}

/// Writes a pre-R06 draft pair (`<uuid>` content + `<uuid>.json` sidecar).
private static func writeLegacyDraft(_ dir: URL, id: UUID, content: String,
                                     path: String, savedAt: Date) throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data(content.utf8).write(to: dir.appendingPathComponent(id.uuidString))
    let json = #"{"originalPath":"\#(path)","savedAt":\#(savedAt.timeIntervalSinceReferenceDate)}"#
    try Data(json.utf8).write(to: dir.appendingPathComponent("\(id.uuidString).json"))
}

/// Runs a conflict scenario where the file changed after the draft (by
/// `change`) and checks that both sides survive in their own windows.
private func expectBothSidesKept(change: (URL) throws -> Void) throws {
    let (drafts, _, dropDrafts) = Self.makeDraftStore()
    let (session, dropSession) = Self.makeSessionStore()
    let dir = try Self.makeTempDir()
    defer { dropDrafts(); dropSession(); try? FileManager.default.removeItem(at: dir) }

    let url = try Self.writeFile(dir, "both.txt", "A\n")
    let id = UUID()
    drafts.write(id: id, content: "A\nmine\n", originalPath: url.path, base: try Self.base(of: url))
    try change(url)
    session.record(path: url.path, caret: 0, scrollY: 0)

    let delegate = AppDelegate()
    delegate.draftStore = drafts
    delegate.sessionStore = session
    #expect(delegate.restoreSession() == 1)
    #expect(delegate.restoreDrafts() == 1)

    // The file window shows the disk version, untouched, and is not duplicated.
    #expect(Self.windows(for: url).count == 1)
    let fileWindow = try #require(Self.window(for: url))
    #expect(Self.editor(of: fileWindow)?.string == "A\ntheirs\n")
    #expect(fileWindow.documentController.isDirty == false)
    #expect(fileWindow.draftID != id)

    // The draft comes back beside it as an untitled, edited copy that keeps
    // the draft's identity — so its file still protects the text.
    let copy = try #require(Self.untitledWindow(holding: "A\nmine\n"))
    #expect(copy.currentFileURL == nil)
    #expect(copy.documentController.isDirty)
    #expect(copy.draftID == id)
    #expect(drafts.drafts().map(\.id) == [id])
    #expect(drafts.drafts().first?.content == "A\nmine\n")
    // The copy is untitled from here on: its draft no longer names the file,
    // so a second crash brings it back as untitled, not as another conflict.
    #expect(drafts.drafts().first?.originalPath == nil)
    // And nothing touched the file itself.
    #expect(try String(contentsOf: url, encoding: .utf8) == "A\ntheirs\n")

    copy.window?.close()
    fileWindow.window?.close()
}

@Test func bothSidesChangedKeepsTheDiskWindowAndAnUntitledCopy() throws {
    try expectBothSidesKept { try Self.overwriteInPlace($0, "A\ntheirs\n") }
}

@Test func aFileReplacedByRenameKeepsTheDiskWindowAndAnUntitledCopy() throws {
    try expectBothSidesKept { try Self.replaceByRename($0, "A\ntheirs\n") }
}

@Test func onlyTheModificationTimeChangingStillAppliesTheDraft() throws {
    let (drafts, _, dropDrafts) = Self.makeDraftStore()
    let (session, dropSession) = Self.makeSessionStore()
    let dir = try Self.makeTempDir()
    defer { dropDrafts(); dropSession(); try? FileManager.default.removeItem(at: dir) }

    let url = try Self.writeFile(dir, "touched.txt", "A\n")
    let id = UUID()
    drafts.write(id: id, content: "A\nmine\n", originalPath: url.path, base: try Self.base(of: url))
    // Identical bytes re-saved through a rename (new inode), then the mtime
    // pushed well past the draft: a stamp change, not a content change.
    try Self.replaceByRename(url, "A\n")
    try Self.setModificationDate(url, offset: 600)
    session.record(path: url.path, caret: 0, scrollY: 0)

    let delegate = AppDelegate()
    delegate.draftStore = drafts
    delegate.sessionStore = session
    #expect(delegate.restoreSession() == 1)
    #expect(delegate.restoreDrafts() == 1)

    #expect(Self.windows(for: url).count == 1)      // session window reused
    let controller = try #require(Self.window(for: url))
    #expect(Self.editor(of: controller)?.string == "A\nmine\n")
    #expect(controller.documentController.isDirty)
    #expect(controller.draftID == id)
    #expect(Self.untitledWindow(holding: "A\nmine\n") == nil)
    #expect(drafts.drafts().map(\.id) == [id])

    controller.window?.close()
}

@Test func aDraftWithABaseWhoseFileVanishedComesBackAsUntitled() throws {
    let (drafts, _, dropDrafts) = Self.makeDraftStore()
    let (session, dropSession) = Self.makeSessionStore()
    let dir = try Self.makeTempDir()
    defer { dropDrafts(); dropSession(); try? FileManager.default.removeItem(at: dir) }

    let url = try Self.writeFile(dir, "gone.txt", "A\n")
    let id = UUID()
    drafts.write(id: id, content: "A\nonly copy\n", originalPath: url.path,
                 base: try Self.base(of: url))
    try FileManager.default.removeItem(at: url)

    let delegate = AppDelegate()
    delegate.draftStore = drafts
    delegate.sessionStore = session
    #expect(delegate.restoreDrafts() == 1)

    let restored = try #require(Self.untitledWindow(holding: "A\nonly copy\n"))
    #expect(restored.documentController.isDirty)
    #expect(restored.draftID == id)
    #expect(Self.windows(for: url).isEmpty)

    restored.window?.close()
}

@Test func aDraftTheDiskAlreadyHoldsIsRemovedAndNotCounted() throws {
    let (drafts, _, dropDrafts) = Self.makeDraftStore()
    let (session, dropSession) = Self.makeSessionStore()
    let dir = try Self.makeTempDir()
    defer { dropDrafts(); dropSession(); try? FileManager.default.removeItem(at: dir) }

    let url = try Self.writeFile(dir, "same.txt", "A\n")
    drafts.write(id: UUID(), content: "A\nmine\n", originalPath: url.path,
                 base: try Self.base(of: url))
    // The text did reach the disk (saved just before the crash, or by hand).
    try Self.overwriteInPlace(url, "A\nmine\n")

    let delegate = AppDelegate()
    delegate.draftStore = drafts
    delegate.sessionStore = session
    #expect(delegate.restoreDrafts() == 0)

    #expect(drafts.drafts().isEmpty)
    let controller = try #require(Self.window(for: url))
    #expect(Self.editor(of: controller)?.string == "A\nmine\n")
    #expect(controller.documentController.isDirty == false)
    #expect(Self.untitledWindow(holding: "A\nmine\n") == nil)

    controller.window?.close()
}

@Test func aLegacyDraftWhoseFileChangedLaterIsKeptAsACopy() throws {
    let (drafts, draftsDir, dropDrafts) = Self.makeDraftStore()
    let (session, dropSession) = Self.makeSessionStore()
    let dir = try Self.makeTempDir()
    defer { dropDrafts(); dropSession(); try? FileManager.default.removeItem(at: dir) }

    let url = try Self.writeFile(dir, "legacy.txt", "A\ntheirs\n")
    let id = UUID()
    try Self.writeLegacyDraft(draftsDir, id: id, content: "A\nmine\n", path: url.path,
                              savedAt: Date().addingTimeInterval(-600))
    #expect(drafts.drafts().first?.isLegacy == true)

    let delegate = AppDelegate()
    delegate.draftStore = drafts
    delegate.sessionStore = session
    #expect(delegate.restoreDrafts() == 1)

    let fileWindow = try #require(Self.window(for: url))
    #expect(Self.editor(of: fileWindow)?.string == "A\ntheirs\n")
    #expect(fileWindow.documentController.isDirty == false)
    let copy = try #require(Self.untitledWindow(holding: "A\nmine\n"))
    #expect(copy.documentController.isDirty)
    #expect(copy.draftID == id)
    #expect(drafts.drafts().map(\.id) == [id])     // previously deleted

    copy.window?.close()
    fileWindow.window?.close()
}

@Test func aSecondDraftForTheSameFileIsNotPouredOverTheFirst() throws {
    let (drafts, _, dropDrafts) = Self.makeDraftStore()
    let (session, dropSession) = Self.makeSessionStore()
    let dir = try Self.makeTempDir()
    defer { dropDrafts(); dropSession(); try? FileManager.default.removeItem(at: dir) }

    let url = try Self.writeFile(dir, "twice.txt", "A\n")
    let base = try Self.base(of: url)
    let first = UUID()
    let second = UUID()
    drafts.write(id: first, content: "A\nfirst\n", originalPath: url.path, base: base)
    Thread.sleep(forTimeInterval: 0.02)
    drafts.write(id: second, content: "A\nsecond\n", originalPath: url.path, base: base)

    let delegate = AppDelegate()
    delegate.draftStore = drafts
    delegate.sessionStore = session
    #expect(delegate.restoreDrafts() == 2)

    #expect(Self.windows(for: url).count == 1)
    let controller = try #require(Self.window(for: url))
    #expect(Self.editor(of: controller)?.string == "A\nfirst\n")
    #expect(controller.draftID == first)
    let other = try #require(Self.untitledWindow(holding: "A\nsecond\n"))
    #expect(other.draftID == second)
    #expect(Set(drafts.drafts().map(\.id)) == [first, second])

    other.window?.close()
    controller.window?.close()
}

@Test func aLegacyDraftWhoseFileIsUnchangedSinceIsApplied() throws {
    let (drafts, draftsDir, dropDrafts) = Self.makeDraftStore()
    let (session, dropSession) = Self.makeSessionStore()
    let dir = try Self.makeTempDir()
    defer { dropDrafts(); dropSession(); try? FileManager.default.removeItem(at: dir) }

    let url = try Self.writeFile(dir, "legacy-ok.txt", "A\n")
    try Self.setModificationDate(url, offset: -600)
    session.record(path: url.path, caret: 0, scrollY: 0)
    let id = UUID()
    try Self.writeLegacyDraft(draftsDir, id: id, content: "A\nmine\n", path: url.path,
                              savedAt: Date())

    let delegate = AppDelegate()
    delegate.draftStore = drafts
    delegate.sessionStore = session
    #expect(delegate.restoreSession() == 1)
    #expect(delegate.restoreDrafts() == 1)

    #expect(Self.windows(for: url).count == 1)
    let controller = try #require(Self.window(for: url))
    #expect(Self.editor(of: controller)?.string == "A\nmine\n")
    #expect(controller.documentController.isDirty)
    #expect(Self.untitledWindow(holding: "A\nmine\n") == nil)

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
