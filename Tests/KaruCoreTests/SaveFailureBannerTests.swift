import AppKit
import Testing
@testable import KaruCore

/// Auto-save on focus loss that fails must leave a lasting, non-modal notice
/// above the editor until the document is saved by any route.
@Suite("Save failure banner")
@MainActor
struct SaveFailureBannerTests {
    private final class Fixture {
        let directory: URL
        let file: URL
        let controller: EditorWindowController
        private let suite = "SaveFailureBannerTests-\(UUID().uuidString)"

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("KaruSaveBanner-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            file = directory.appendingPathComponent("notes.txt")
            try "hello\n".write(to: file, atomically: true, encoding: .utf8)
            let defaults = TestDefaults.make(suite)
            controller = EditorWindowController()
            controller.sessionStore = SessionStore(defaults: defaults)
            controller.draftStore = DraftStore(directory: directory.appendingPathComponent("drafts", isDirectory: true))
            controller.load(url: file)
        }

        var textView: EditorTextView {
            func find(_ view: NSView) -> EditorTextView? {
                (view as? EditorTextView) ?? view.subviews.lazy.compactMap(find).first
            }
            return controller.window!.contentView.flatMap(find)!
        }

        func edit(_ text: String) {
            textView.insertText(text, replacementRange: NSRange(location: 0, length: 0))
        }

        /// Makes saving fail (the file and its folder turn read-only) or work again.
        func setWritable(_ writable: Bool) throws {
            try FileManager.default.setAttributes([.posixPermissions: writable ? 0o755 : 0o555],
                                                  ofItemAtPath: directory.path)
            try FileManager.default.setAttributes([.posixPermissions: writable ? 0o644 : 0o444],
                                                  ofItemAtPath: file.path)
        }

        func cleanup() {
            try? setWritable(true)
            controller.close()
            try? FileManager.default.removeItem(at: directory)
            UserDefaults().removePersistentDomain(forName: suite)
        }
    }

    @Test func failedAutoSaveShowsTheBannerUntilASaveSucceeds() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let banner = f.controller.saveFailureBanner
        #expect(!banner.isShowing)
        // First in the content stack: above the find bar and the editor.
        #expect((banner.superview as? NSStackView)?.arrangedSubviews.first === banner)

        f.edit("x")
        try f.setWritable(false)
        f.controller.autoSaveOnFocusLoss(enabled: true)
        #expect(banner.isShowing)
        #expect(f.controller.window?.isDocumentEdited == true)
        #expect(try String(contentsOf: f.file, encoding: .utf8) == "hello\n")

        // Failing again while it is up changes nothing.
        f.controller.autoSaveOnFocusLoss(enabled: true)
        #expect(banner.isShowing)

        // More edits do not dismiss it either: only a save does.
        f.edit("y")
        #expect(banner.isShowing)

        try f.setWritable(true)
        f.controller.autoSaveOnFocusLoss(enabled: true)
        #expect(!banner.isShowing)
        #expect(f.controller.window?.isDocumentEdited == false)
        #expect(try String(contentsOf: f.file, encoding: .utf8) == "yxhello\n")
    }

    @Test func retryGoesThroughTheManualSavePath() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let banner = f.controller.saveFailureBanner
        f.edit("x")
        try f.setWritable(false)
        f.controller.autoSaveOnFocusLoss(enabled: true)
        #expect(banner.isShowing)

        try f.setWritable(true)
        banner.retryButton.performClick(nil)
        #expect(!banner.isShowing)
        #expect(try String(contentsOf: f.file, encoding: .utf8) == "xhello\n")
    }

    @Test func noBannerWhenAutoSaveIsOffOrSucceeds() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let banner = f.controller.saveFailureBanner
        f.edit("x")
        try f.setWritable(false)
        f.controller.autoSaveOnFocusLoss(enabled: false)
        #expect(!banner.isShowing)

        try f.setWritable(true)
        f.controller.autoSaveOnFocusLoss(enabled: true)
        #expect(!banner.isShowing)
        #expect(f.controller.window?.isDocumentEdited == false)
    }

    @Test func bannerNeverTakesKeyboardFocusAndKeepsItsMessageInFull() {
        let banner = SaveFailureBanner()
        #expect(banner.retryButton.refusesFirstResponder && banner.saveAsButton.refusesFirstResponder)
        #expect(!banner.isShowing)
        banner.show(reason: "Permission denied")
        #expect(banner.isShowing)
        #expect(banner.accessibilityLabel() == L10n.t(.saveFailedBanner))
        let label = banner.subviews.compactMap { $0 as? NSTextField }.first
        #expect(label?.toolTip == L10n.t(.saveFailedBanner) + "\nPermission denied")
        #expect(banner.retryButton.title == L10n.t(.saveFailedRetry))
        #expect(banner.saveAsButton.title == L10n.t(.menuSaveAs))
        banner.hide()
        #expect(!banner.isShowing)
    }

    @Test func conflictModeHasItsOwnTextAndTheFailureModeStillWorks() {
        let banner = SaveFailureBanner()
        banner.show(reason: nil, mode: .conflict)
        #expect(banner.isShowing)
        #expect(banner.mode == .conflict)
        #expect(banner.message == L10n.t(.saveConflictBanner))
        #expect(banner.accessibilityLabel() == L10n.t(.saveConflictBanner))
        #expect(banner.retryButton.title == L10n.t(.saveConflictBannerSave))
        #expect(banner.saveAsButton.title == L10n.t(.menuSaveAs))

        // A later write failure switches the band back to the generic text.
        banner.show(reason: "Permission denied")
        #expect(banner.isShowing)
        #expect(banner.mode == .failure)
        #expect(banner.message == L10n.t(.saveFailedBanner))
        #expect(banner.retryButton.title == L10n.t(.saveFailedRetry))
        banner.hide()
        #expect(!banner.isShowing)
    }

    @Test func genericFailureStillShowsTheGenericText() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let banner = f.controller.saveFailureBanner
        f.edit("x")
        try f.setWritable(false)
        f.controller.autoSaveOnFocusLoss(enabled: true)
        #expect(banner.isShowing)
        #expect(banner.mode == .failure)
        #expect(banner.message == L10n.t(.saveFailedBanner))
    }
}
