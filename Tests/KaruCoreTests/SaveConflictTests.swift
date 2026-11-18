import AppKit
import Testing
@testable import KaruCore

/// F1b: what the window does when another program changed its file — the
/// manual-save question (D1), auto-save leaving the file alone (D1), and the
/// check made when the window becomes key (D2). Every test works in its own
/// temporary directory and drives the modal choices through test seams.
@Suite("Save conflict")
@MainActor
struct SaveConflictTests {
    private final class Fixture {
        let directory: URL
        let file: URL
        let drafts: DraftStore
        let controller: EditorWindowController
        private(set) var flashes: [String] = []
        private(set) var conflictQuestions = 0
        private let suite = "SaveConflictTests-\(UUID().uuidString)"

        init(_ contents: String = "hello\n") throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("KaruSaveConflict-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            file = directory.appendingPathComponent("notes.txt")
            try contents.write(to: file, atomically: true, encoding: .utf8)
            let defaults = UserDefaults(suiteName: suite)!
            drafts = DraftStore(directory: directory.appendingPathComponent("drafts", isDirectory: true))
            controller = EditorWindowController()
            controller.sessionStore = SessionStore(defaults: defaults)
            controller.draftStore = drafts
            controller.load(url: file)
            controller.statusFlashObserver = { [unowned self] in self.flashes.append($0) }
        }

        var textView: EditorTextView {
            func find(_ view: NSView) -> EditorTextView? {
                (view as? EditorTextView) ?? view.subviews.lazy.compactMap(find).first
            }
            return controller.window!.contentView.flatMap(find)!
        }

        var isEdited: Bool { controller.window?.isDocumentEdited == true }

        func edit(_ text: String) {
            textView.insertText(text, replacementRange: NSRange(location: 0, length: 0))
        }

        /// The manual-save question answers `choice` (and counts how often it
        /// was asked).
        func answer(_ choice: EditorWindowController.SaveConflictChoice) {
            controller.saveConflictChoiceOverride = { [unowned self] in
                self.conflictQuestions += 1
                return choice
            }
        }

        /// Replaces the file "from outside" the way most tools do.
        func outsideWrite(_ text: String) throws {
            try Data(text.utf8).write(to: file, options: .atomic)
        }

        func disk() throws -> String { try String(contentsOf: file, encoding: .utf8) }

        func draftCount() -> Int {
            controller.flushDraftNow()
            controller.waitForDraftWrites()
            return drafts.drafts().count
        }

        func cleanup() {
            controller.close()
            controller.waitForDraftWrites()
            try? FileManager.default.removeItem(at: directory)
            UserDefaults().removePersistentDomain(forName: suite)
        }
    }

    // MARK: - Manual save (D1)

    @Test func manualSaveCancelWritesNothing() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        f.answer(.cancel)
        f.edit("mine ")
        try f.outsideWrite("theirs\n")

        f.controller.saveDocument(nil)
        #expect(f.conflictQuestions == 1)
        #expect(try f.disk() == "theirs\n")
        #expect(f.isEdited)
        #expect(f.textView.string == "mine hello\n")
        #expect(f.draftCount() == 1)
    }

    @Test func manualSaveOverwriteWritesTheBuffer() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        f.answer(.overwrite)
        f.edit("mine ")
        #expect(f.draftCount() == 1)
        try f.outsideWrite("theirs\n")

        f.controller.saveDocument(nil)
        #expect(f.conflictQuestions == 1)
        #expect(try f.disk() == "mine hello\n")
        #expect(!f.isEdited)
        f.controller.waitForDraftWrites()
        #expect(f.drafts.drafts().isEmpty)

        // The overwrite recorded the new disk state: the next save does not ask.
        f.edit("more ")
        f.controller.saveDocument(nil)
        #expect(f.conflictQuestions == 1)
        #expect(try f.disk() == "more mine hello\n")
    }

    @Test func manualSaveSaveAsRunsTheSaveAsPath() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        f.answer(.saveAs)
        let copy = f.directory.appendingPathComponent("mine.txt")
        var suggested: [String] = []
        f.controller.saveAsURLOverride = { name in
            suggested.append(name)
            return copy
        }
        f.edit("mine ")
        try f.outsideWrite("theirs\n")

        f.controller.saveDocument(nil)
        #expect(suggested == ["notes.txt"])
        #expect(try f.disk() == "theirs\n")
        #expect(try String(contentsOf: copy, encoding: .utf8) == "mine hello\n")
        #expect(f.controller.documentController.fileURL?.lastPathComponent == "mine.txt")
        #expect(!f.isEdited)
    }

    @Test func cancelledSaveAsAfterTheQuestionKeepsEverything() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        f.answer(.saveAs)
        var asked = 0
        f.controller.saveAsURLOverride = { _ in asked += 1; return nil }
        f.edit("mine ")
        try f.outsideWrite("theirs\n")

        f.controller.saveDocument(nil)
        #expect(asked == 1)
        #expect(try f.disk() == "theirs\n")
        #expect(f.isEdited)
        #expect(f.controller.documentController.fileURL == f.file)
    }

    /// The close prompt's Save runs `performSave`; its own alert has no test
    /// seam, so this covers the shared path through `saveDocument`: a cancelled
    /// conflict question reports failure, which keeps the window open.
    @Test func closeConfirmationSaveThenCancelKeepsTheWindowOpen() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        f.answer(.cancel)
        f.edit("mine ")
        try f.outsideWrite("theirs\n")

        f.controller.saveDocument(nil)
        #expect(f.isEdited)
        #expect(f.controller.documentController.isDirty)
        #expect(!f.controller.documentController.matchesBaseline(f.textView.string))
        #expect(try f.disk() == "theirs\n")
    }

    // MARK: - Focus-loss auto-save (D1)

    @Test func autoSaveNeverOverwritesAndShowsTheConflictBand() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let banner = f.controller.saveFailureBanner
        f.edit("mine ")
        try f.outsideWrite("theirs\n")

        f.controller.autoSaveOnFocusLoss(enabled: true)
        #expect(try f.disk() == "theirs\n")
        #expect(f.isEdited)
        #expect(banner.isShowing)
        #expect(banner.mode == .conflict)
        #expect(banner.message == L10n.t(.saveConflictBanner))
        #expect(banner.retryButton.title == L10n.t(.saveConflictBannerSave))
        #expect(f.draftCount() == 1)
        #expect(f.conflictQuestions == 0)

        // Activating the window again does not repeat what the band says.
        f.controller.checkForExternalChange()
        #expect(f.flashes.isEmpty)

        // The band's save button takes the manual path, which asks.
        f.answer(.overwrite)
        banner.retryButton.performClick(nil)
        #expect(f.conflictQuestions == 1)
        #expect(!banner.isShowing)
        #expect(!f.isEdited)
        #expect(try f.disk() == "mine hello\n")
    }

    @Test func autoSaveConflictThenCancelKeepsTheBand() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let banner = f.controller.saveFailureBanner
        f.edit("mine ")
        try f.outsideWrite("theirs\n")
        f.controller.autoSaveOnFocusLoss(enabled: true)
        #expect(banner.isShowing)

        f.answer(.cancel)
        banner.retryButton.performClick(nil)
        #expect(banner.isShowing)
        #expect(banner.mode == .conflict)
        #expect(f.isEdited)
        #expect(try f.disk() == "theirs\n")
    }

    // MARK: - Become-key check (D2)

    @Test func cleanBufferReloadsTheNewContents() throws {
        let f = try Fixture("one\ntwo\nthree\n")
        defer { f.cleanup() }
        // An edit, saved: the buffer is clean but the undo stack is not empty.
        f.textView.setSelectedRange(NSRange(location: 0, length: 0))
        f.edit("zero\n")
        f.controller.saveDocument(nil)
        #expect(!f.isEdited)
        f.textView.setSelectedRange(NSRange(location: 15, length: 0))
        #expect(f.textView.undoManager?.canUndo == true)

        try f.outsideWrite("new\n")
        f.controller.checkForExternalChange()
        #expect(f.textView.string == "new\n")
        #expect(!f.isEdited)
        #expect(f.textView.undoManager?.canUndo != true)
        #expect(f.flashes == [L10n.t(.externalChangeReloaded)])
        #expect(f.textView.selectedRange() == NSRange(location: 4, length: 0))
        f.controller.waitForDraftWrites()
        #expect(f.drafts.drafts().isEmpty)

        // The reloaded state is the new baseline: saving does not ask.
        f.answer(.cancel)
        f.edit("x")
        f.controller.saveDocument(nil)
        #expect(f.conflictQuestions == 0)
        #expect(try f.disk() == "xnew\n")

        // Nothing changed since: a second activation does nothing.
        f.controller.checkForExternalChange()
        #expect(f.flashes.count == 1)
    }

    @Test func reloadKeepsAManualLanguageChoice() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        f.controller.chooseLanguage(identifier: "python")
        try f.outsideWrite("print(1)\n")
        f.controller.checkForExternalChange()
        #expect(f.textView.string == "print(1)\n")
        #expect(!f.controller.isLanguageAuto)
        #expect(f.controller.currentLanguageIdentifierValue == "python")
    }

    @Test func editedThenUndoneBufferCountsAsClean() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        f.edit("x")
        f.textView.undoManager?.undo()
        #expect(f.textView.string == "hello\n")
        try f.outsideWrite("theirs\n")
        f.controller.checkForExternalChange()
        #expect(f.textView.string == "theirs\n")
        #expect(!f.isEdited)
    }

    @Test func dirtyBufferIsKeptAndTheChangeIsReportedOnce() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        f.edit("mine ")
        try f.outsideWrite("theirs\n")

        f.controller.checkForExternalChange()
        #expect(f.textView.string == "mine hello\n")
        #expect(f.isEdited)
        #expect(f.flashes == [L10n.t(.externalChangeKeptEdits)])

        // Same external state: no second notice.
        f.controller.checkForExternalChange()
        f.controller.checkForExternalChange()
        #expect(f.flashes.count == 1)

        // Another outside change is reported again.
        try f.outsideWrite("theirs, again\n")
        f.controller.checkForExternalChange()
        #expect(f.flashes == [L10n.t(.externalChangeKeptEdits), L10n.t(.externalChangeKeptEdits)])
        #expect(f.textView.string == "mine hello\n")
        #expect(try f.disk() == "theirs, again\n")
    }

    @Test func noChangeTouchOrRemovalDoesNothing() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        f.controller.checkForExternalChange()
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 3600)],
                                              ofItemAtPath: f.file.path)
        f.controller.checkForExternalChange()
        try FileManager.default.removeItem(at: f.file)
        f.controller.checkForExternalChange()
        #expect(f.flashes.isEmpty)
        #expect(f.textView.string == "hello\n")
        #expect(!f.isEdited)

        // Same with unsaved changes.
        f.edit("x")
        f.controller.checkForExternalChange()
        #expect(f.flashes.isEmpty)
        #expect(f.textView.string == "xhello\n")
    }

    @Test func ownSaveIsNotAnExternalChange() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        f.edit("mine ")
        f.controller.saveDocument(nil)
        f.controller.checkForExternalChange()
        f.edit("more ")
        f.controller.autoSaveOnFocusLoss(enabled: true)
        f.controller.checkForExternalChange()
        #expect(f.flashes.isEmpty)
        #expect(f.textView.string == "more mine hello\n")
        #expect(!f.isEdited)
        #expect(f.conflictQuestions == 0)
    }

    @Test func becomingKeyRunsTheCheck() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.outsideWrite("theirs\n")
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: f.controller.window)
        #expect(f.textView.string == "theirs\n")
        // Another window's activation is not ours to check.
        try f.outsideWrite("again\n")
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: NSWindow())
        #expect(f.textView.string == "theirs\n")
    }
}
