import AppKit
import Testing
@testable import KaruCore

// T13.1 — Save As / titlebar rename must re-run language detection when the
// file's extension changes (extension first, content fallback), and must NOT
// disturb a manual language choice when the extension stays the same.

@MainActor
private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("KaruRedetect-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@MainActor
@Test func renameToNewExtensionRedetectsLanguage() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    // Plain prose: the content sniffer classifies nothing, so language state
    // hinges purely on the extension.
    let url = dir.appendingPathComponent("notes.txt")
    try "plain prose, nothing to sniff here\n".write(to: url, atomically: true, encoding: .utf8)

    let controller = EditorWindowController()
    controller.load(url: url)
    #expect(controller.currentLanguageIdentifierValue != "python")

    controller.renameFile(to: "notes.py")
    #expect(controller.currentLanguageIdentifierValue == "python")
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("notes.py").path))
}

@MainActor
@Test func sameExtensionRenameKeepsManualLanguageChoice() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("notes.txt")
    try "plain prose, nothing to sniff here\n".write(to: url, atomically: true, encoding: .utf8)

    let controller = EditorWindowController()
    controller.load(url: url)
    controller.chooseLanguage(identifier: "json") // manual override

    controller.renameFile(to: "renamed.txt")      // stem changes, extension doesn't
    #expect(controller.currentLanguageIdentifierValue == "json")
    #expect(controller.isLanguageAuto == false)
}
