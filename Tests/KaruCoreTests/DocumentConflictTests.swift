import Foundation
import Testing
@testable import KaruCore

// R01 / N01: external-modification detection before save and identity-preserving
// writes. Every test works in its own fresh temporary directory.

private typealias DocError = DocumentController.DocumentError

/// A fresh, empty temp directory; removed (after restoring write permission) by
/// `cleanup`.
private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("KaruConflict-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func cleanup(_ dir: URL) {
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
    try? FileManager.default.removeItem(at: dir)
}

private func bytes(_ url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
}

/// Writes `text` "from outside" the way most tools do (atomic replace).
private func outsideWrite(_ text: String, to url: URL) throws {
    try Data(text.utf8).write(to: url, options: .atomic)
}

/// Directory listing, so tests can assert no temp file was left behind.
private func entries(_ dir: URL) throws -> Set<String> {
    Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
}

private func bumpModificationDate(_ url: URL) throws {
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSinceNow: 3600)], ofItemAtPath: url.path)
}

// MARK: - Conflict detection

@Test func externalEditMakesSaveThrowAndWritesNothing() throws {
    let dir = try makeTempDir()
    defer { cleanup(dir) }
    let url = dir.appendingPathComponent("doc.txt")
    try outsideWrite("original", to: url)

    let doc = DocumentController()
    try doc.load(from: url)
    let stateBefore = doc.diskState
    #expect(stateBefore != nil)
    try outsideWrite("someone else's edit", to: url)
    doc.markEdited()

    #expect(throws: DocError.changedOnDisk) { try doc.save(text: "mine") }
    #expect(try bytes(url) == "someone else's edit")
    #expect(doc.isDirty == true)
    #expect(doc.diskState == stateBefore)
    #expect(doc.matchesBaseline("original") == true)
    #expect(try entries(dir) == ["doc.txt"])
}

/// The scenario from the original report (R01 probe).
@Test func originalReportScenarioKeepsExternalChange() throws {
    let dir = try makeTempDir()
    defer { cleanup(dir) }
    let url = dir.appendingPathComponent("probe.txt")
    try outsideWrite("original", to: url)

    let doc = DocumentController()
    _ = try doc.load(from: url)
    try outsideWrite("external-change", to: url)
    doc.markEdited()
    var threw = false
    do { try doc.save(text: "local-change") } catch DocError.changedOnDisk { threw = true }
    #expect(threw)
    #expect(try bytes(url) == "external-change")
}

@Test func inPlaceExternalEditIsDetected() throws {
    let dir = try makeTempDir()
    defer { cleanup(dir) }
    let url = dir.appendingPathComponent("doc.txt")
    try outsideWrite("original", to: url)
    let doc = DocumentController()
    try doc.load(from: url)

    // Same inode, same size: only the bytes (and mtime) differ.
    let handle = try FileHandle(forWritingTo: url)
    try handle.write(contentsOf: Data("ORIGINAL".utf8))
    try handle.close()

    #expect(throws: DocError.changedOnDisk) { try doc.save(text: "mine") }
    #expect(try bytes(url) == "ORIGINAL")
}

@Test func touchOnlyDoesNotConflict() throws {
    let dir = try makeTempDir()
    defer { cleanup(dir) }
    let url = dir.appendingPathComponent("doc.txt")
    try outsideWrite("same", to: url)
    let doc = DocumentController()
    try doc.load(from: url)

    try bumpModificationDate(url)
    try doc.save(text: "after touch")
    #expect(try bytes(url) == "after touch")

    // Identical bytes rewritten (new inode, new mtime) → still no conflict.
    try outsideWrite("after touch", to: url)
    try doc.save(text: "after rewrite")
    #expect(try bytes(url) == "after rewrite")
    #expect(try entries(dir) == ["doc.txt"])
}

@Test func deleteAndRecreateWithDifferentContentConflicts() throws {
    let dir = try makeTempDir()
    defer { cleanup(dir) }
    let url = dir.appendingPathComponent("doc.txt")
    try outsideWrite("original", to: url)
    let doc = DocumentController()
    try doc.load(from: url)

    try FileManager.default.removeItem(at: url)
    try outsideWrite("recreated", to: url)
    #expect(throws: DocError.changedOnDisk) { try doc.save(text: "mine") }
    #expect(try bytes(url) == "recreated")
}

@Test func deleteAndRecreateWithIdenticalContentSaves() throws {
    let dir = try makeTempDir()
    defer { cleanup(dir) }
    let url = dir.appendingPathComponent("doc.txt")
    try outsideWrite("original", to: url)
    let doc = DocumentController()
    try doc.load(from: url)

    try FileManager.default.removeItem(at: url)
    try outsideWrite("original", to: url)
    try doc.save(text: "mine")
    #expect(try bytes(url) == "mine")
}

@Test func syncStyleRenameOverPathConflicts() throws {
    let dir = try makeTempDir()
    defer { cleanup(dir) }
    let url = dir.appendingPathComponent("doc.txt")
    try outsideWrite("original", to: url)
    let doc = DocumentController()
    try doc.load(from: url)
    let inodeBefore = doc.diskState?.stamp.inode

    // Sync software: write a new file elsewhere, rename(2) it over the path.
    let staged = dir.appendingPathComponent(".sync-staging")
    try Data("synced from another Mac".utf8).write(to: staged)
    #expect(rename(staged.path, url.path) == 0)
    #expect(DiskState.Stamp.of(url)?.inode != inodeBefore)

    #expect(throws: DocError.changedOnDisk) { try doc.save(text: "mine") }
    #expect(try bytes(url) == "synced from another Mac")
}

@Test func removedFileIsRecreatedBySave() throws {
    let dir = try makeTempDir()
    defer { cleanup(dir) }
    let url = dir.appendingPathComponent("doc.txt")
    try outsideWrite("original", to: url)
    let doc = DocumentController()
    try doc.load(from: url)

    try FileManager.default.removeItem(at: url)
    doc.markEdited()
    try doc.save(text: "back again")
    #expect(try bytes(url) == "back again")
    #expect(doc.isDirty == false)
    #expect(doc.diskState?.stamp == DiskState.Stamp.of(url))
}

@Test func overwritingExternalChangesWritesOverThem() throws {
    let dir = try makeTempDir()
    defer { cleanup(dir) }
    let url = dir.appendingPathComponent("doc.txt")
    try outsideWrite("original", to: url)
    let doc = DocumentController()
    try doc.load(from: url)
    try outsideWrite("outside", to: url)

    doc.markEdited()
    try doc.save(text: "mine wins", overwritingExternalChanges: true)
    #expect(try bytes(url) == "mine wins")
    #expect(doc.isDirty == false)
    // Afterwards detection applies again against the newly written bytes.
    try doc.save(text: "and again")
    #expect(try bytes(url) == "and again")
}

// MARK: - File identity (N01)

@Test(arguments: [true, false])
func symlinkStaysALinkAfterSave(relative: Bool) throws {
    let dir = try makeTempDir()
    defer { cleanup(dir) }
    let target = dir.appendingPathComponent("target.txt")
    let link = dir.appendingPathComponent("link.txt")
    try outsideWrite("original", to: target)
    try FileManager.default.createSymbolicLink(
        atPath: link.path, withDestinationPath: relative ? "target.txt" : target.path)

    let doc = DocumentController()
    #expect(try doc.load(from: link) == "original")
    doc.markEdited()
    try doc.save(text: "through the link")

    let type = try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType
    #expect(type == .typeSymbolicLink)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
            == (relative ? "target.txt" : target.path))
    #expect(try bytes(target) == "through the link")
    #expect(doc.fileURL == link)
    #expect(try entries(dir) == ["target.txt", "link.txt"])

    // Conflict detection follows the link too.
    try outsideWrite("changed behind the link", to: target)
    #expect(throws: DocError.changedOnDisk) { try doc.save(text: "x") }
    #expect(try bytes(target) == "changed behind the link")
}

@Test func extendedAttributeAndPermissionsSurviveSave() throws {
    let dir = try makeTempDir()
    defer { cleanup(dir) }
    let url = dir.appendingPathComponent("doc.txt")
    try outsideWrite("original", to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
    let name = "dev.enkin.karu-test.tag"
    let value = Array("tag-value".utf8)
    #expect(setxattr(url.path, name, value, value.count, 0, 0) == 0)

    let doc = DocumentController()
    try doc.load(from: url)
    try doc.save(text: "rewritten")

    #expect(try bytes(url) == "rewritten")
    var buffer = [UInt8](repeating: 0, count: 64)
    let length = getxattr(url.path, name, &buffer, buffer.count, 0, 0)
    #expect(length == value.count)
    #expect(Array(buffer.prefix(max(length, 0))) == value)
    let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    #expect(perms == 0o640)
    #expect(try entries(dir) == ["doc.txt"])
}

@Test func failedWriteInReadOnlyDirectoryLeavesOriginalAndNoTemp() throws {
    let dir = try makeTempDir()
    defer { cleanup(dir) }
    let url = dir.appendingPathComponent("doc.txt")
    try outsideWrite("original", to: url)
    let doc = DocumentController()
    try doc.load(from: url)
    let stateBefore = doc.diskState

    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
    doc.markEdited()
    #expect(throws: (any Error).self) { try doc.save(text: "cannot land") }
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)

    #expect(try bytes(url) == "original")
    #expect(try entries(dir) == ["doc.txt"])
    #expect(doc.isDirty == true)
    #expect(doc.diskState == stateBefore)
}

// MARK: - Encodings, Save As, rename

@Test func legacyEncodedFileSavesWithoutConflict() throws {
    let dir = try makeTempDir()
    defer { cleanup(dir) }
    let url = dir.appendingPathComponent("gb.txt")
    let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
    try "中文文档，全角标点。".data(using: gb18030)!.write(to: url)

    let doc = DocumentController()
    let text = try doc.load(from: url)
    #expect(text == "中文文档，全角标点。")
    doc.markEdited()
    try doc.save(text: text + "新增")
    #expect(try bytes(url) == "中文文档，全角标点。新增")
}

@Test func reloadWithEncodingRecordsDiskState() throws {
    let dir = try makeTempDir()
    defer { cleanup(dir) }
    let url = dir.appendingPathComponent("sjis.txt")
    try "日本語のサンプル".data(using: .shiftJIS)!.write(to: url)

    let doc = DocumentController()
    try doc.reload(from: url, encoding: .shiftJIS)
    #expect(doc.diskState?.digest == DiskState.digest(of: try Data(contentsOf: url)))
    try doc.save(text: "保存")
    #expect(try bytes(url) == "保存")
}

@Test func saveAsOverExistingFileThenDetectsConflictsThere() throws {
    let dir = try makeTempDir()
    defer { cleanup(dir) }
    let first = dir.appendingPathComponent("first.txt")
    let second = dir.appendingPathComponent("second.txt")
    try outsideWrite("first", to: first)
    try outsideWrite("unrelated existing file", to: second)

    let doc = DocumentController()
    try doc.load(from: first)
    try doc.save(text: "saved as", to: second)
    #expect(doc.fileURL == second)
    #expect(try bytes(second) == "saved as")
    #expect(try bytes(first) == "first")

    try doc.save(text: "plain save")
    #expect(try bytes(second) == "plain save")

    try outsideWrite("outside", to: second)
    #expect(throws: DocError.changedOnDisk) { try doc.save(text: "x") }
    #expect(try bytes(second) == "outside")
    #expect(try entries(dir) == ["first.txt", "second.txt"])
}

@Test func renameKeepsDiskStateValid() throws {
    let dir = try makeTempDir()
    defer { cleanup(dir) }
    let url = dir.appendingPathComponent("old.txt")
    try outsideWrite("payload", to: url)
    let doc = DocumentController()
    try doc.load(from: url)
    let newURL = try doc.rename(to: "new.txt")
    #expect(doc.externalChange() == .none)
    try doc.save(text: "after rename")
    #expect(try bytes(newURL) == "after rename")
}

// MARK: - externalChange()

@Test func externalChangeReportsNoneModifiedRemoved() throws {
    let dir = try makeTempDir()
    defer { cleanup(dir) }
    let url = dir.appendingPathComponent("doc.txt")
    try outsideWrite("original", to: url)
    let doc = DocumentController()
    #expect(doc.externalChange() == .none)   // nothing recorded yet
    try doc.load(from: url)
    #expect(doc.externalChange() == .none)

    // Touch only: still `.none`, and the stamp is refreshed.
    try bumpModificationDate(url)
    #expect(doc.externalChange() == .none)
    #expect(doc.diskState?.stamp == DiskState.Stamp.of(url))

    try outsideWrite("changed", to: url)
    #expect(doc.externalChange() == .modified)

    try FileManager.default.removeItem(at: url)
    #expect(doc.externalChange() == .removed)
}

// MARK: - SafeFileWriter

@Test func safeWriterAbortsWhenTargetChangesBeforeReplace() throws {
    let dir = try makeTempDir()
    defer { cleanup(dir) }
    let url = dir.appendingPathComponent("doc.txt")
    try outsideWrite("original", to: url)
    let stamp = try #require(DiskState.Stamp.of(url))

    let writer = SafeFileWriter(beforeReplace: { target in
        try? outsideWrite("slipped in", to: target)
    })
    #expect(throws: DocError.changedOnDisk) {
        try writer.write(Data("mine".utf8), to: url, expecting: .stamp(stamp))
    }
    #expect(try bytes(url) == "slipped in")
    #expect(try entries(dir) == ["doc.txt"])
}

@Test func secondStatGuardThroughDocumentController() throws {
    let dir = try makeTempDir()
    defer { cleanup(dir) }
    let url = dir.appendingPathComponent("doc.txt")
    try outsideWrite("original", to: url)
    let doc = DocumentController()
    try doc.load(from: url)
    let stateBefore = doc.diskState
    doc.writer = SafeFileWriter(beforeReplace: { target in
        try? outsideWrite("raced", to: target)
    })
    doc.markEdited()

    #expect(throws: DocError.changedOnDisk) { try doc.save(text: "mine") }
    #expect(try bytes(url) == "raced")
    #expect(doc.isDirty == true)
    #expect(doc.diskState == stateBefore)
    #expect(try entries(dir) == ["doc.txt"])
}

@Test func safeWriterAbortsWhenFileAppearsAfterMissingCheck() throws {
    let dir = try makeTempDir()
    defer { cleanup(dir) }
    let url = dir.appendingPathComponent("doc.txt")
    let writer = SafeFileWriter(beforeReplace: { target in
        try? outsideWrite("created meanwhile", to: target)
    })
    #expect(throws: DocError.changedOnDisk) {
        try writer.write(Data("mine".utf8), to: url, expecting: .missing)
    }
    #expect(try bytes(url) == "created meanwhile")
}

@Test func safeWriterResolvesDanglingSymlinkToItsTarget() throws {
    let dir = try makeTempDir()
    defer { cleanup(dir) }
    let link = dir.appendingPathComponent("link.txt")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "missing.txt")
    try SafeFileWriter().write(Data("created".utf8), to: link, expecting: .unchecked)
    let type = try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType
    #expect(type == .typeSymbolicLink)
    #expect(try bytes(dir.appendingPathComponent("missing.txt")) == "created")
}

// MARK: - DiskState

@Test func diskStateRoundTripsThroughCodable() throws {
    let dir = try makeTempDir()
    defer { cleanup(dir) }
    let url = dir.appendingPathComponent("doc.txt")
    try outsideWrite("payload", to: url)
    let state = try DiskState.read(url)
    #expect(state.digest.count == 32)
    #expect(state.digest == DiskState.digest(of: Data("payload".utf8)))
    #expect(state.stamp == DiskState.Stamp.of(url))
    let decoded = try JSONDecoder().decode(DiskState.self, from: JSONEncoder().encode(state))
    #expect(decoded == state)
    #expect(DiskState.Stamp.of(dir.appendingPathComponent("absent")) == nil)
}

// MARK: - Replace fallback and temp naming (added by the main session's review)

@Test func safeWriterFallsBackToRenameWhenReplaceIsUnavailable() throws {
    let dir = try makeTempDir()
    defer { cleanup(dir) }
    let url = dir.appendingPathComponent("doc.txt")
    try outsideWrite("original", to: url)
    let stamp = try #require(DiskState.Stamp.of(url))

    var writer = SafeFileWriter()
    writer.replaceItem = { _, _ in throw CocoaError(.featureUnsupported) }
    try writer.write(Data("mine".utf8), to: url, expecting: .stamp(stamp))
    #expect(try bytes(url) == "mine")
    #expect(try entries(dir) == ["doc.txt"])
}

@Test func safeWriterReportsTheReplaceErrorWhenTheTargetMovedDuringTheFailure() throws {
    let dir = try makeTempDir()
    defer { cleanup(dir) }
    let url = dir.appendingPathComponent("doc.txt")
    try outsideWrite("original", to: url)
    let stamp = try #require(DiskState.Stamp.of(url))

    var writer = SafeFileWriter()
    writer.replaceItem = { original, _ in
        try outsideWrite("slipped in", to: original)
        throw CocoaError(.featureUnsupported)
    }
    #expect(throws: CocoaError.self) {
        try writer.write(Data("mine".utf8), to: url, expecting: .stamp(stamp))
    }
    #expect(try bytes(url) == "slipped in")
    #expect(try entries(dir) == ["doc.txt"])
}

@Test func saveWorksForAFileNameAtTheLengthLimit() throws {
    let dir = try makeTempDir()
    defer { cleanup(dir) }
    // 255 bytes is NAME_MAX; a temp name derived from the document's name would not fit.
    let name = String(repeating: "n", count: 251) + ".txt"
    let url = dir.appendingPathComponent(name)
    try outsideWrite("original", to: url)

    let doc = DocumentController()
    _ = try doc.load(from: url)
    doc.markEdited()
    try doc.save(text: "changed")
    #expect(try bytes(url) == "changed")
    #expect(try entries(dir) == [name])
}
