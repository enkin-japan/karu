import AppKit
import Testing
@testable import KaruCore

// T14.8 — session restore (plan A: files with a URL only).
//
// Three layers are covered here:
//   1. `SessionStore` as pure logic (dedup / removal / order / corrupt data),
//   2. the window controller's hooks (open, rename, close vs. quit),
//   3. `AppDelegate.restoreSession()` (reopen, prune vanished files).
//
// Everything runs against a private UserDefaults suite so the developer's real
// session list is never touched, and the AppKit cases are serialized because
// they drive the shared NSApplication window list.

@MainActor
@Suite(.serialized)
struct SessionRestoreTests {

// MARK: - Helpers

/// A UserDefaults suite unique to one test, plus the store on top of it.
/// The returned closure tears the suite down.
private static func makeStore() -> (SessionStore, UserDefaults, () -> Void) {
    let name = "KaruSessionTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    return (SessionStore(defaults: defaults), defaults, {
        UserDefaults().removePersistentDomain(forName: name)
    })
}

private static func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("KaruSession-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@discardableResult
private static func writeFile(_ dir: URL, _ name: String, _ text: String = "one\ntwo\nthree\n") throws -> URL {
    let url = dir.appendingPathComponent(name)
    try text.write(to: url, atomically: true, encoding: .utf8)
    return url
}

/// Caret offset of a window's editor (the controller keeps its text view
/// private, so reach it through the view tree as the other AppKit tests do).
private static func caret(of controller: EditorWindowController?) -> Int? {
    controller?.window?.contentView?
        .firstDescendant(ofType: NSTextView.self)?.selectedRange().location
}

// MARK: - 1. SessionStore pure logic

@Test func recordingSamePathTwiceUpdatesInsteadOfAppending() {
    let (store, _, teardown) = Self.makeStore()
    defer { teardown() }

    store.record(path: "/tmp/a.txt", caret: 3, scrollY: 10)
    store.record(path: "/tmp/b.txt", caret: 0, scrollY: 0)
    store.record(path: "/tmp/a.txt", caret: 42, scrollY: 120.5)

    let entries = store.entries()
    #expect(entries.count == 2)
    // Updated in place: the first slot is still a.txt, now with the new position.
    #expect(entries[0] == SessionStore.Entry(path: "/tmp/a.txt", caret: 42, scrollY: 120.5))
    #expect(entries[1].path == "/tmp/b.txt")
}

@Test func differentSpellingsOfTheSamePathAreOneEntry() {
    let (store, _, teardown) = Self.makeStore()
    defer { teardown() }

    store.record(path: "/tmp/a.txt", caret: 1, scrollY: 0)
    store.record(path: "/tmp/./sub/../a.txt", caret: 9, scrollY: 0)

    #expect(store.entries().count == 1)
    #expect(store.entries()[0].caret == 9)
}

@Test func removeDropsOnlyTheNamedEntryAndClearWipesAll() {
    let (store, _, teardown) = Self.makeStore()
    defer { teardown() }

    store.record(path: "/tmp/a.txt", caret: 0, scrollY: 0)
    store.record(path: "/tmp/b.txt", caret: 0, scrollY: 0)
    store.record(path: "/tmp/c.txt", caret: 0, scrollY: 0)

    store.remove(path: "/tmp/b.txt")
    #expect(store.entries().map(\.path) == ["/tmp/a.txt", "/tmp/c.txt"])

    store.remove(path: "/tmp/never-recorded.txt")   // no-op, must not throw/clear
    #expect(store.entries().count == 2)

    store.clear()
    #expect(store.entries().isEmpty)
}

@Test func entryOrderSurvivesRepeatedPositionUpdates() {
    let (store, _, teardown) = Self.makeStore()
    defer { teardown() }

    let paths = ["/tmp/1.txt", "/tmp/2.txt", "/tmp/3.txt"]
    for path in paths { store.record(path: path, caret: 0, scrollY: 0) }
    for _ in 0..<3 {
        for path in paths.reversed() { store.record(path: path, caret: 7, scrollY: 1) }
    }
    #expect(store.entries().map(\.path) == paths)
}

@Test func theListIsBoundedSoResidueCannotGrowForever() {
    let (store, _, teardown) = Self.makeStore()
    defer { teardown() }

    let total = SessionStore.maxEntries + 6
    for index in 0..<total { store.record(path: "/tmp/f\(index).txt", caret: 0, scrollY: 0) }

    let entries = store.entries()
    #expect(entries.count == SessionStore.maxEntries)
    // The oldest entries are the ones dropped; the newest survive.
    #expect(entries.first?.path == "/tmp/f6.txt")
    #expect(entries.last?.path == "/tmp/f\(total - 1).txt")
}

@Test func corruptedDefaultsDegradeToAnEmptySession() {
    let (store, defaults, teardown) = Self.makeStore()
    defer { teardown() }

    // Wrong type at the key entirely.
    defaults.set("not an array", forKey: SessionStore.key)
    #expect(store.entries().isEmpty)

    // An array of junk: unparseable elements are skipped, valid ones survive.
    defaults.set([
        "a string",
        ["caret": 4],                                   // no path
        ["path": "", "caret": 1],                       // empty path
        ["path": "/tmp/ok.txt", "caret": "nope", "scrollY": "nope"], // bad types
        ["path": "/tmp/good.txt", "caret": 12, "scrollY": 34.0],
    ], forKey: SessionStore.key)

    let entries = store.entries()
    #expect(entries.count == 2)
    // Unreadable position fields fall back to the document's top.
    #expect(entries[0] == SessionStore.Entry(path: "/tmp/ok.txt", caret: 0, scrollY: 0))
    #expect(entries[1] == SessionStore.Entry(path: "/tmp/good.txt", caret: 12, scrollY: 34))

    store.clear()
    #expect(store.entries().isEmpty)
}

// MARK: - 2. Window controller hooks

@Test func openingAFileRecordsItInTheSession() throws {
    let (store, _, teardown) = Self.makeStore()
    let dir = try Self.makeTempDir()
    defer { teardown(); try? FileManager.default.removeItem(at: dir) }
    let url = try Self.writeFile(dir, "open.txt")

    let controller = EditorWindowController()
    controller.sessionStore = store
    controller.load(url: url)

    #expect(store.entries().map(\.path) == [url.path])
    controller.window?.close()
}

@Test func userClosingAWindowRemovesItFromTheSession() throws {
    let (store, _, teardown) = Self.makeStore()
    let dir = try Self.makeTempDir()
    defer { teardown(); try? FileManager.default.removeItem(at: dir) }
    let url = try Self.writeFile(dir, "closed.txt")

    let controller = EditorWindowController()
    controller.sessionStore = store
    controller.load(url: url)
    #expect(store.entries().count == 1)

    controller.window?.close()      // the user is done with this file
    #expect(store.entries().isEmpty)
}

@Test func closingWhileTerminatingKeepsTheSessionEntry() throws {
    let (store, _, teardown) = Self.makeStore()
    let dir = try Self.makeTempDir()
    defer { teardown(); try? FileManager.default.removeItem(at: dir) }
    let url = try Self.writeFile(dir, "quit.txt")

    let controller = EditorWindowController()
    controller.sessionStore = store
    controller.isAppTerminating = { true }       // quit in progress
    controller.load(url: url)
    controller.restoreSession(caret: 4, scrollY: 0)

    controller.window?.close()
    // Still listed — and with the caret the window closed at, so the next
    // launch reopens exactly where the user was.
    #expect(store.entries().map(\.path) == [url.path])
    #expect(store.entries()[0].caret == 4)
}

@Test func renamingAFileMovesItsSessionEntryToTheNewPath() throws {
    let (store, _, teardown) = Self.makeStore()
    let dir = try Self.makeTempDir()
    defer { teardown(); try? FileManager.default.removeItem(at: dir) }
    let url = try Self.writeFile(dir, "before.txt")

    let controller = EditorWindowController()
    controller.sessionStore = store
    controller.load(url: url)
    #expect(store.entries().map(\.path) == [url.path])

    controller.renameFile(to: "after.txt")

    let renamed = dir.appendingPathComponent("after.txt")
    #expect(store.entries().map(\.path) == [renamed.path])
    controller.window?.close()
}

// MARK: - 3. Restore

@Test func restoringPutsTheCaretBackAndClampsAShrunkFile() throws {
    let (store, _, teardown) = Self.makeStore()
    let dir = try Self.makeTempDir()
    defer { teardown(); try? FileManager.default.removeItem(at: dir) }
    let url = try Self.writeFile(dir, "caret.txt", "0123456789\nabcdefghij\n")

    let controller = EditorWindowController()
    controller.sessionStore = store
    controller.load(url: url)

    controller.restoreSession(caret: 14, scrollY: 0)
    #expect(Self.caret(of: controller) == 14)
    #expect(store.entries()[0].caret == 14)

    // A caret past the end (file shrank on disk) clamps instead of crashing.
    controller.restoreSession(caret: 9_999, scrollY: 0)
    #expect(Self.caret(of: controller) == 22)

    controller.window?.close()
}

@Test func restoreReopensExistingFilesAndPrunesVanishedOnes() throws {
    let (store, _, teardown) = Self.makeStore()
    let dir = try Self.makeTempDir()
    defer { teardown(); try? FileManager.default.removeItem(at: dir) }

    let gone = try Self.writeFile(dir, "gone.txt")
    let kept = try Self.writeFile(dir, "kept.txt")
    store.record(path: gone.path, caret: 0, scrollY: 0)
    store.record(path: kept.path, caret: 5, scrollY: 0)
    try FileManager.default.removeItem(at: gone)    // deleted between sessions

    let delegate = AppDelegate()
    delegate.sessionStore = store
    #expect(delegate.restoreSession() == 1)

    // Exactly one window, showing the surviving file, caret restored.
    let restored = NSApplication.shared.windows
        .compactMap { $0.windowController as? EditorWindowController }
        .filter { $0.currentFileURL.map { UbiquitousFile.sameFile($0, kept) } ?? false }
    #expect(restored.count == 1)
    #expect(Self.caret(of: restored.first) == 5)

    // The vanished file is silently gone from the list; the other one stays.
    #expect(store.entries().map(\.path) == [kept.path])

    for controller in restored { controller.window?.close() }
}

@Test func quittingKeepsEveryOpenFileForTheNextLaunch() throws {
    let (store, _, teardown) = Self.makeStore()
    let dir = try Self.makeTempDir()
    defer { teardown(); try? FileManager.default.removeItem(at: dir) }
    let url = try Self.writeFile(dir, "session.txt")

    let app = NSApplication.shared
    let delegate = AppDelegate()
    delegate.sessionStore = store
    delegate.application(app, open: [url])
    #expect(store.entries().map(\.path) == [url.path])

    #expect(delegate.applicationShouldTerminate(app) == .terminateNow)
    #expect(delegate.isTerminating)

    // Windows closing as part of the quit must not wipe the list.
    let controllers = app.windows
        .compactMap { $0.windowController as? EditorWindowController }
        .filter { $0.currentFileURL.map { UbiquitousFile.sameFile($0, url) } ?? false }
    for controller in controllers { controller.window?.close() }
    #expect(store.entries().map(\.path) == [url.path])
}

}

private extension NSView {
    func firstDescendant<T: NSView>(ofType type: T.Type) -> T? {
        for sub in subviews {
            if let hit = sub as? T { return hit }
            if let hit = sub.firstDescendant(ofType: type) { return hit }
        }
        return nil
    }
}

// MARK: - Restore policy: clean exit vs crash vs update relaunch (T14.9)

private func makePolicyStore() -> (SessionStore, () -> Void) {
    let name = "KaruSessionPolicyTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    return (SessionStore(defaults: defaults), {
        UserDefaults().removePersistentDomain(forName: name)
    })
}

@Test func cleanExitDoesNotRestore() {
    let (store, tearDown) = makePolicyStore()
    defer { tearDown() }
    // Previous run: began, then quit cleanly → next launch starts fresh.
    _ = store.beginSession()
    store.markCleanExit()
    #expect(store.beginSession() == false)
}

@Test func crashRestores() {
    let (store, tearDown) = makePolicyStore()
    defer { tearDown() }
    // Previous run began a session and never marked a clean exit (crash /
    // force quit): the next launch restores.
    _ = store.beginSession()
    #expect(store.beginSession() == true)
    // The flag is consumed: the run after that (ending cleanly) does not.
    store.markCleanExit()
    #expect(store.beginSession() == false)
}

@Test func updateRelaunchRestoresDespiteCleanQuit() {
    let (store, tearDown) = makePolicyStore()
    defer { tearDown() }
    // Sparkle: will-relaunch fires, then the (clean) termination follows.
    _ = store.beginSession()
    store.markUpdateRelaunch()
    store.markCleanExit()
    #expect(store.beginSession() == true)
    // The update flag is one-shot.
    store.markCleanExit()
    #expect(store.beginSession() == false)
}

@Test func firstRunEverDoesNotRestore() {
    let (store, tearDown) = makePolicyStore()
    defer { tearDown() }
    // Fresh install: no cleanExit key at all reads as "clean".
    #expect(store.beginSession() == false)
}
