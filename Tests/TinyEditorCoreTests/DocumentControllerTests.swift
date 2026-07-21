import Foundation
import Testing
@testable import TinyEditorCore

private func makeTempURL(ext: String = "txt") -> URL {
    let dir = FileManager.default.temporaryDirectory
    return dir.appendingPathComponent("TinyEditorTest-\(UUID().uuidString).\(ext)")
}

@Test func newDocumentStartsClean() {
    let doc = DocumentController()
    #expect(doc.isDirty == false)
    #expect(doc.fileURL == nil)
    #expect(doc.displayName == "Untitled")
}

@Test func editingMarksDirty() {
    let doc = DocumentController()
    doc.markEdited()
    #expect(doc.isDirty == true)
}

@Test func savingClearsDirty() throws {
    let url = makeTempURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let doc = DocumentController()
    doc.markEdited()
    #expect(doc.isDirty == true)

    try doc.save(text: "hello", to: url)
    #expect(doc.isDirty == false)
    #expect(doc.fileURL == url)
}

@Test func saveThenLoadRoundTripsUnicode() throws {
    let url = makeTempURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let original = "第一行\n中文 mixed with English\nemoji 🎉🚀\n最后一行"
    let writer = DocumentController()
    try writer.save(text: original, to: url)

    let reader = DocumentController()
    let loaded = try reader.load(from: url)

    #expect(loaded == original)
    #expect(reader.fileURL == url)
    #expect(reader.isDirty == false)
}

@Test func loadClearsDirtyAndAdoptsURL() throws {
    let url = makeTempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("seed".utf8).write(to: url)

    let doc = DocumentController()
    doc.markEdited()
    let text = try doc.load(from: url)

    #expect(text == "seed")
    #expect(doc.isDirty == false)
    #expect(doc.fileURL == url)
    #expect(doc.displayName == url.lastPathComponent)
}

@Test func saveAsUpdatesURLAndDisplayName() throws {
    let first = makeTempURL()
    let second = makeTempURL()
    defer {
        try? FileManager.default.removeItem(at: first)
        try? FileManager.default.removeItem(at: second)
    }

    let doc = DocumentController()
    try doc.save(text: "v1", to: first)
    #expect(doc.fileURL == first)

    // "Save As…" to a new location.
    doc.markEdited()
    try doc.save(text: "v2", to: second)
    #expect(doc.fileURL == second)
    #expect(doc.displayName == second.lastPathComponent)
    #expect(doc.isDirty == false)

    let reloaded = try DocumentController().load(from: second)
    #expect(reloaded == "v2")
}

@Test func plainSaveWithoutURLThrows() {
    let doc = DocumentController()
    #expect(throws: DocumentController.DocumentError.self) {
        try doc.save(text: "no url")
    }
}

@Test func plainSaveWritesToCurrentURL() throws {
    let url = makeTempURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let doc = DocumentController()
    try doc.save(text: "a", to: url)   // establishes URL
    doc.markEdited()
    try doc.save(text: "b")            // plain save reuses URL
    #expect(doc.isDirty == false)

    let reloaded = try DocumentController().load(from: url)
    #expect(reloaded == "b")
}
