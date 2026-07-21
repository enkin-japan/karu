import Foundation
import Testing
@testable import KaruCore

private func makeTempURL(ext: String = "txt") -> URL {
    let dir = FileManager.default.temporaryDirectory
    return dir.appendingPathComponent("KaruTest-\(UUID().uuidString).\(ext)")
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

// MARK: - Encoding fallback (v0.2.1 regression tests)

@Test func loadsUTF16FileWithBOM() throws {
    let url = makeTempURL(ext: "md")
    defer { try? FileManager.default.removeItem(at: url) }
    let original = "# 参考文献\n[1] Gemma モデルの概要， https://example.com (参照2026-07-21)．"
    try original.data(using: .utf16)!.write(to: url)

    let doc = DocumentController()
    #expect(try doc.load(from: url) == original)
}

@Test func loadsShiftJISFile() throws {
    let url = makeTempURL(ext: "txt")
    defer { try? FileManager.default.removeItem(at: url) }
    let original = """
    日本語のドキュメントです。文字コードの自動判定を検証します。
    [1] Gemma モデルの概要 | Google AI for Developers （参照2026-07-21）．
    [2] MLX - Apple Open Source プロジェクトの解説と利用方法について。
    改行を含む複数行のテキストで、実際のファイルに近いサンプルとする。
    """
    try original.data(using: .shiftJIS)!.write(to: url)

    let doc = DocumentController()
    #expect(try doc.load(from: url) == original)
}

@Test func loadsGB18030File() throws {
    let url = makeTempURL(ext: "txt")
    defer { try? FileManager.default.removeItem(at: url) }
    let gbk = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
    let original = "中文文档，全角标点。"
    try original.data(using: gbk)!.write(to: url)

    let doc = DocumentController()
    #expect(try doc.load(from: url) == original)
}

@Test func savedFileIsAlwaysUTF8RoundTrip() throws {
    let url = makeTempURL(ext: "txt")
    defer { try? FileManager.default.removeItem(at: url) }
    let doc = DocumentController()
    try doc.save(text: "混合 テキスト mixed", to: url)
    #expect(try String(contentsOf: url, encoding: .utf8) == "混合 テキスト mixed")
}

// MARK: - Rename (T11.4)

@Test func renameMovesFileAndAdoptsNewURL() throws {
    let dir = FileManager.default.temporaryDirectory
    let url = dir.appendingPathComponent("KaruRename-\(UUID().uuidString).txt")
    let newName = "KaruRenamed-\(UUID().uuidString).md"
    let expected = dir.appendingPathComponent(newName)
    defer {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: expected)
    }
    try Data("payload".utf8).write(to: url)

    let doc = DocumentController()
    try doc.load(from: url)
    let newURL = try doc.rename(to: newName)

    #expect(newURL == expected)
    #expect(doc.fileURL == expected)
    #expect(FileManager.default.fileExists(atPath: expected.path))
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(try String(contentsOf: expected, encoding: .utf8) == "payload")
}

@Test func renameToSameNameIsANoOpSuccess() throws {
    let url = makeTempURL(ext: "txt")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("x".utf8).write(to: url)

    let doc = DocumentController()
    try doc.load(from: url)
    let result = try doc.rename(to: url.lastPathComponent)
    #expect(result == url)
    #expect(doc.fileURL == url)
    #expect(FileManager.default.fileExists(atPath: url.path))
}

@Test func renameRejectsEmptyName() throws {
    let url = makeTempURL(ext: "txt")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("x".utf8).write(to: url)
    let doc = DocumentController()
    try doc.load(from: url)
    #expect(throws: DocumentController.RenameError.emptyName) {
        try doc.rename(to: "   ")
    }
}

@Test func renameRejectsPathSeparator() throws {
    let url = makeTempURL(ext: "txt")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("x".utf8).write(to: url)
    let doc = DocumentController()
    try doc.load(from: url)
    #expect(throws: DocumentController.RenameError.invalidName) {
        try doc.rename(to: "sub/evil.txt")
    }
}

@Test func renameRejectsExistingTarget() throws {
    let dir = FileManager.default.temporaryDirectory
    let url = dir.appendingPathComponent("KaruRename-\(UUID().uuidString).txt")
    let occupied = dir.appendingPathComponent("KaruOccupied-\(UUID().uuidString).txt")
    defer {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: occupied)
    }
    try Data("a".utf8).write(to: url)
    try Data("b".utf8).write(to: occupied)

    let doc = DocumentController()
    try doc.load(from: url)
    #expect(throws: DocumentController.RenameError.targetExists) {
        try doc.rename(to: occupied.lastPathComponent)
    }
    // The original file is untouched after a rejected rename.
    #expect(doc.fileURL == url)
    #expect(FileManager.default.fileExists(atPath: url.path))
}

@Test func renameWithoutURLThrows() {
    let doc = DocumentController()
    #expect(throws: DocumentController.RenameError.noFileURL) {
        try doc.rename(to: "whatever.txt")
    }
}
