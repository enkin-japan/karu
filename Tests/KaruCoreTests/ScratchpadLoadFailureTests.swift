import AppKit
import Testing
@testable import KaruCore

// R02 — the scratchpad must tell "no content yet" apart from "could not read
// it". Before, an unreadable or non-UTF-8 `content.txt` loaded as "" and the
// next hide / flush wrote that "" over the user's notes. Faults are injected on
// real temporary directories (chmod), restored in cleanup.

extension ScratchpadLoadResult {
    /// The loaded text, or `nil` for `.missing` / `.failure`.
    var loadedText: String? {
        if case .text(let text) = self { return text }
        return nil
    }

    var isMissing: Bool {
        if case .missing = self { return true }
        return false
    }

    var isUndecodable: Bool {
        if case .failure(.undecodable) = self { return true }
        return false
    }

    var isUnreadable: Bool {
        if case .failure(.unreadable) = self { return true }
        return false
    }
}

private let undecodableBytes = Data([0xFF, 0xFE, 0xFD, 0x0A, 0x80])

/// A fresh temporary pad directory, created, plus a cleanup that restores
/// permissions first so a failed test can never leave an undeletable folder.
private func makePadDirectory() throws -> (ScratchpadStore, URL, () -> Void) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("KaruScratchpadR02-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = ScratchpadStore(directory: dir)
    return (store, dir, {
        chmod(dir.path, 0o755)
        chmod(store.contentURL.path, 0o644)
        try? FileManager.default.removeItem(at: dir)
    })
}

private func entries(of dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
}

private func fixedDate() -> Date {
    var components = DateComponents()
    components.year = 2026; components.month = 11; components.day = 18
    components.hour = 9; components.minute = 30; components.second = 5
    return Calendar.current.date(from: components)!
}

// MARK: - Store: the three load() states

@Test func loadReportsMissingOnlyWhenThereIsNoFile() throws {
    let (store, dir, cleanup) = try makePadDirectory()
    defer { cleanup() }
    #expect(store.load().isMissing)
    // A directory that does not exist at all is just as missing.
    #expect(ScratchpadStore(directory: dir.appendingPathComponent("never/made")).load().isMissing)
}

@Test func loadReturnsTextIncludingAnEmptyFile() throws {
    let (store, _, cleanup) = try makePadDirectory()
    defer { cleanup() }
    try Data("notes ✓ 草稿\n".utf8).write(to: store.contentURL)
    #expect(store.load().loadedText == "notes ✓ 草稿\n")
    // 0 bytes is valid UTF-8: an emptied pad, not a missing one.
    try Data().write(to: store.contentURL)
    #expect(store.load().loadedText == "")
}

@Test func loadReportsUndecodableBytes() throws {
    let (store, _, cleanup) = try makePadDirectory()
    defer { cleanup() }
    try undecodableBytes.write(to: store.contentURL)
    #expect(store.load().isUndecodable)
}

@Test func loadReportsUnreadableFileAsFailureNotMissing() throws {
    let (store, _, cleanup) = try makePadDirectory()
    defer { cleanup() }
    try Data("precious".utf8).write(to: store.contentURL)
    chmod(store.contentURL.path, 0o000)
    #expect(store.load().isUnreadable)
    chmod(store.contentURL.path, 0o644)
    #expect(store.load().loadedText == "precious")
}

@Test func loadReportsADirectoryInPlaceOfTheFileAsUnreadable() throws {
    let (store, _, cleanup) = try makePadDirectory()
    defer { cleanup() }
    try FileManager.default.createDirectory(at: store.contentURL, withIntermediateDirectories: true)
    #expect(store.load().isUnreadable)
}

// MARK: - Store: preserving undecodable content

@Test func preserveRenamesTheFileWithATimestamp() throws {
    let (store, dir, cleanup) = try makePadDirectory()
    defer { cleanup() }
    try undecodableBytes.write(to: store.contentURL)
    let url = try store.preserveUndecodableContent(date: fixedDate()).get()
    #expect(url.lastPathComponent == "content.unreadable-20261118-093005.txt")
    #expect(url.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
    #expect(try Data(contentsOf: url) == undecodableBytes)
    #expect(!FileManager.default.fileExists(atPath: store.contentURL.path))
    #expect(store.load().isMissing)
}

@Test func preserveNeverOverwritesAnEarlierPreservedFile() throws {
    let (store, dir, cleanup) = try makePadDirectory()
    defer { cleanup() }
    let first = Data([0xFF, 0x01])
    let second = Data([0xFE, 0x02])
    let third = Data([0xFD, 0x03])
    try first.write(to: store.contentURL)
    let url1 = try store.preserveUndecodableContent(date: fixedDate()).get()
    try second.write(to: store.contentURL)
    let url2 = try store.preserveUndecodableContent(date: fixedDate()).get()
    try third.write(to: store.contentURL)
    let url3 = try store.preserveUndecodableContent(date: fixedDate()).get()
    #expect(Set([url1, url2, url3]).count == 3)
    #expect(try Data(contentsOf: url1) == first)
    #expect(try Data(contentsOf: url2) == second)
    #expect(try Data(contentsOf: url3) == third)
    #expect(entries(of: dir).count == 3)
}

@Test func preserveFailsWithoutTouchingTheFileInAReadOnlyDirectory() throws {
    let (store, dir, cleanup) = try makePadDirectory()
    defer { cleanup() }
    try undecodableBytes.write(to: store.contentURL)
    chmod(dir.path, 0o555)
    let result = store.preserveUndecodableContent(date: fixedDate())
    chmod(dir.path, 0o755)
    if case .success = result { Issue.record("rename into a read-only directory succeeded") }
    #expect(try Data(contentsOf: store.contentURL) == undecodableBytes)
    #expect(entries(of: dir) == ["content.txt"])
}

// MARK: - Controller

/// A controller wired to recording hooks, so no real alert or sheet runs.
@MainActor
private final class PadHookRecorder {
    var loadFailures: [ScratchpadLoadFailure] = []
    var preserved: [URL] = []
    var persistenceErrors = 0

    func attach(to controller: ScratchpadController) {
        controller.loadFailureHandler = { [unowned self] in self.loadFailures.append($0) }
        controller.preservedContentHandler = { [unowned self] in self.preserved.append($0) }
        controller.persistenceErrorHandler = { [unowned self] _ in self.persistenceErrors += 1 }
    }
}

enum PadCloseAction: CaseIterable, Sendable {
    case hide, flushIfVisible
}

@MainActor
@Test(arguments: PadCloseAction.allCases)
func undecodableContentIsKeptAsideAndThePadOpensEmpty(action: PadCloseAction) throws {
    let (store, dir, cleanup) = try makePadDirectory()
    defer { cleanup() }
    try undecodableBytes.write(to: store.contentURL)
    let controller = ScratchpadController(store: store)
    let recorder = PadHookRecorder()
    recorder.attach(to: controller)

    controller.show()
    defer { controller.hide() }
    #expect(recorder.loadFailures.isEmpty)
    #expect(recorder.preserved.count == 1)
    let preservedURL = try #require(recorder.preserved.first)
    #expect(preservedURL.lastPathComponent.hasPrefix("content.unreadable-"))
    #expect(controller.diagnosticPanel != nil)
    #expect(controller.diagnosticTextView?.string == "")

    switch action {
    case .hide: controller.hide()
    case .flushIfVisible: #expect(controller.flushIfVisible())
    }

    // The original bytes survive, byte for byte, in the preserved file; the
    // pad's own file is the (empty) new pad.
    #expect(try Data(contentsOf: preservedURL) == undecodableBytes)
    #expect(try Data(contentsOf: store.contentURL).isEmpty)
    #expect(entries(of: dir) == ["content.txt", preservedURL.lastPathComponent].sorted())
    #expect(recorder.persistenceErrors == 0)
}

@MainActor
@Test func unreadableFileOpensNoPanelAndIsNeverWritten() throws {
    let (store, dir, cleanup) = try makePadDirectory()
    defer { cleanup() }
    let original = Data("precious notes\n".utf8)
    try original.write(to: store.contentURL)
    chmod(store.contentURL.path, 0o000)
    let controller = ScratchpadController(store: store)
    let recorder = PadHookRecorder()
    recorder.attach(to: controller)

    controller.show()
    #expect(!controller.isVisible)
    #expect(controller.diagnosticPanel == nil)
    #expect(controller.diagnosticTextView == nil)
    #expect(recorder.loadFailures.count == 1)
    #expect(recorder.loadFailures.first.map { if case .unreadable = $0 { true } else { false } } == true)

    controller.hide()
    controller.toggle()  // retries the load, fails again, still nothing built
    #expect(controller.flushIfVisible())
    #expect(controller.diagnosticPanel == nil)
    #expect(recorder.loadFailures.count == 2)
    #expect(recorder.preserved.isEmpty)

    chmod(store.contentURL.path, 0o644)
    #expect(try Data(contentsOf: store.contentURL) == original)
    #expect(entries(of: dir) == ["content.txt"])

    // Once the file is readable again, the next show() loads it as usual.
    controller.show()
    defer { controller.hide() }
    #expect(controller.diagnosticTextView?.string == "precious notes\n")
}

@MainActor
@Test func undecodableFileThatCannotBeRenamedIsTreatedAsUnreadable() throws {
    let (store, dir, cleanup) = try makePadDirectory()
    defer { cleanup() }
    try undecodableBytes.write(to: store.contentURL)
    chmod(dir.path, 0o555)
    let controller = ScratchpadController(store: store)
    let recorder = PadHookRecorder()
    recorder.attach(to: controller)

    controller.show()
    #expect(!controller.isVisible)
    #expect(controller.diagnosticPanel == nil)
    #expect(controller.diagnosticTextView == nil)
    #expect(recorder.loadFailures.count == 1)
    #expect(recorder.preserved.isEmpty)

    controller.hide()
    controller.toggle()
    #expect(controller.flushIfVisible())
    #expect(controller.diagnosticPanel == nil)
    #expect(recorder.loadFailures.count == 2)

    chmod(dir.path, 0o755)
    #expect(try Data(contentsOf: store.contentURL) == undecodableBytes)
    #expect(entries(of: dir) == ["content.txt"])
}

@MainActor
@Test func missingFileStillOpensAnEmptyPad() throws {
    let (store, _, cleanup) = try makePadDirectory()
    defer { cleanup() }
    let controller = ScratchpadController(store: store)
    let recorder = PadHookRecorder()
    recorder.attach(to: controller)

    controller.show()
    #expect(controller.diagnosticTextView?.string == "")
    controller.diagnosticTextView?.string = "first words"
    controller.hide()
    #expect(controller.diagnosticPanel == nil)
    #expect(store.load().loadedText == "first words")
    #expect(recorder.loadFailures.isEmpty)
    #expect(recorder.preserved.isEmpty)
}

@MainActor
@Test(arguments: ["", "kept text\n"])
func existingTextStillLoadsAsBefore(stored: String) throws {
    let (store, dir, cleanup) = try makePadDirectory()
    defer { cleanup() }
    try Data(stored.utf8).write(to: store.contentURL)
    let controller = ScratchpadController(store: store)
    let recorder = PadHookRecorder()
    recorder.attach(to: controller)

    controller.show()
    #expect(controller.diagnosticTextView?.string == stored)
    controller.hide()
    #expect(store.load().loadedText == stored)
    #expect(entries(of: dir) == ["content.txt"])
    #expect(recorder.loadFailures.isEmpty)
    #expect(recorder.preserved.isEmpty)
}
