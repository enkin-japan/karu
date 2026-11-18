import Foundation
import Testing
@testable import KaruCore

// R06 — crash drafts are a single-file commit (`<uuid>.draft`: JSON header line
// + raw UTF-8 body) and carry the disk state they were taken against. Every
// test runs in its own temporary directory; crashes are simulated through the
// store's `crashBefore` seam, which abandons a write before a given step.

struct DraftStoreFormatTests {

    // MARK: - Helpers

    private static func makeDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("KaruDraftFormat-\(UUID().uuidString)", isDirectory: true)
    }

    private static func cleanup(_ dir: URL) {
        chmod(dir.path, 0o755)
        try? FileManager.default.removeItem(at: dir)
    }

    private static func store(_ dir: URL, at date: Date) -> DraftStore {
        var store = DraftStore(directory: dir)
        store.now = { date }
        return store
    }

    private static let baseA = DiskState(
        stamp: .init(device: 1, inode: 2, size: 3,
                     modificationSeconds: 1_700_000_000, modificationNanoseconds: 123_456_789),
        digest: Data(repeating: 0xAB, count: 32))
    private static let baseB = DiskState(
        stamp: .init(device: 9, inode: 8, size: 7,
                     modificationSeconds: 1_800_000_000, modificationNanoseconds: 1),
        digest: Data(repeating: 0x01, count: 32))

    private static let t0 = Date(timeIntervalSinceReferenceDate: 812_345_678.125)
    private static let t1 = Date(timeIntervalSinceReferenceDate: 812_349_999.5)

    /// Writes a pre-R06 draft: `<uuid>` content plus `<uuid>.json` sidecar.
    private static func writeLegacy(_ dir: URL, id: UUID, content: String,
                                    path: String?, savedAt: Date) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(content.utf8).write(to: dir.appendingPathComponent(id.uuidString))
        let pathJSON = path.map { "\"\($0)\"" } ?? "null"
        let json = #"{"originalPath":\#(pathJSON),"savedAt":\#(savedAt.timeIntervalSinceReferenceDate)}"#
        try Data(json.utf8).write(to: dir.appendingPathComponent("\(id.uuidString).json"))
    }

    private static func names(_ dir: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
    }

    /// The fields that must always travel together.
    private struct Snapshot: Equatable {
        let content: String
        let path: String?
        let savedAt: Date
        let base: DiskState?
        init(_ d: DraftStore.Draft) {
            content = d.content; path = d.originalPath; savedAt = d.savedAt; base = d.base
        }
        init(content: String, path: String?, savedAt: Date, base: DiskState?) {
            self.content = content; self.path = path; self.savedAt = savedAt; self.base = base
        }
    }

    // MARK: - 1. Round trip

    @Test(arguments: [
        "plain ascii",
        "多字节：中文、日本語、한국어 and emoji 🧑‍💻👍🏽",
        "line one\nline two\r\nline three\rend",
        "\nleading newline",
        "\n\n\n",
        "",
        "no trailing newline",
        "trailing newline\n",
        "{\"looks\":\"like json\"}\n{\"second\":1}",
    ])
    func contentRoundTripsByteForByte(content: String) throws {
        let dir = Self.makeDir()
        defer { Self.cleanup(dir) }
        for base in [nil, Self.baseA] as [DiskState?] {
            let store = Self.store(dir, at: Self.t0)
            let id = UUID()
            let path = base == nil ? nil : "/Users/someone/dir with spaces/文件.txt"
            try store.write(id: id, content: content, originalPath: path, base: base).get()

            let draft = try #require(store.drafts().first { $0.id == id })
            #expect(Array(draft.content.utf8) == Array(content.utf8))
            #expect(draft.originalPath == path)
            #expect(draft.savedAt == Self.t0)
            #expect(draft.base == base)
            #expect(draft.isLegacy == false)
        }
    }

    @Test func aTwoMegabyteBodyRoundTrips() throws {
        let dir = Self.makeDir()
        defer { Self.cleanup(dir) }
        let store = Self.store(dir, at: Self.t1)
        var content = ""
        content.reserveCapacity(2 << 20)
        var line = 0
        while content.utf8.count < 2 << 20 {
            content += "line \(line) — 行 \(line)\n"
            line += 1
        }
        content += "tail without newline"
        let id = UUID()
        try store.write(id: id, content: content, originalPath: "/tmp/big.txt", base: Self.baseB).get()

        let draft = try #require(store.drafts().first)
        #expect(draft.content.utf8.elementsEqual(content.utf8))
        #expect(draft.originalPath == "/tmp/big.txt")
        #expect(draft.savedAt == Self.t1)
        #expect(draft.base == Self.baseB)
    }

    @Test func onDiskLayoutIsOneFileWithACompactHeaderLine() throws {
        let dir = Self.makeDir()
        defer { Self.cleanup(dir) }
        let store = Self.store(dir, at: Self.t0)
        let id = UUID()
        try store.write(id: id, content: "a\nb", originalPath: nil).get()

        #expect(Self.names(dir) == ["\(id.uuidString).draft"])
        let data = try Data(contentsOf: dir.appendingPathComponent("\(id.uuidString).draft"))
        let newline = try #require(data.firstIndex(of: 0x0A))
        let header = try #require(
            try JSONSerialization.jsonObject(with: data[..<newline]) as? [String: Any])
        #expect(header["version"] as? Int == 1)
        #expect(header["originalPath"] is NSNull)
        #expect(header["base"] is NSNull)
        #expect(header["savedAt"] != nil)
        #expect(data[data.index(after: newline)...] == Data("a\nb".utf8))
    }

    // MARK: - 2. Overwrite interrupted at every step (R06)

    @Test(arguments: DraftStore.WriteStep.allCases)
    func anInterruptedOverwriteLeavesOldOrNewNeverAMix(step: DraftStore.WriteStep) throws {
        let dir = Self.makeDir()
        defer { Self.cleanup(dir) }
        let id = UUID()
        let old = Snapshot(content: "old content\n", path: "/old/path.txt",
                           savedAt: Self.t0, base: Self.baseA)
        let new = Snapshot(content: "new, longer content\nwith lines", path: "/new/path.txt",
                           savedAt: Self.t1, base: Self.baseB)

        try Self.store(dir, at: Self.t0)
            .write(id: id, content: old.content, originalPath: old.path, base: old.base).get()

        var crashing = Self.store(dir, at: Self.t1)
        crashing.crashBefore = { $0 == step }
        let result = crashing.write(id: id, content: new.content,
                                    originalPath: new.path, base: new.base)
        guard case .failure(let error) = result else {
            Issue.record("the simulated crash did not stop the write")
            return
        }
        #expect(error is DraftStore.SimulatedCrash)

        let drafts = DraftStore(directory: dir).drafts()
        #expect(drafts.count == 1)
        let found = try #require(drafts.first)
        #expect(found.id == id)
        let snapshot = Snapshot(found)
        #expect(snapshot == old || snapshot == new)
        // Before the rename nothing new is visible; from then on all of it is.
        switch step {
        case .createDirectory, .writeTemporary, .commit: #expect(snapshot == old)
        case .removeLegacyMetadata, .removeLegacyContent: #expect(snapshot == new)
        }

        // Whatever a crash left behind (a temp file) goes with `remove`.
        DraftStore(directory: dir).remove(id: id)
        #expect(Self.names(dir).isEmpty)
    }

    @Test(arguments: DraftStore.WriteStep.allCases)
    func anInterruptedUpgradeOfALegacyDraftYieldsExactlyOneDraft(step: DraftStore.WriteStep) throws {
        let dir = Self.makeDir()
        defer { Self.cleanup(dir) }
        let id = UUID()
        try Self.writeLegacy(dir, id: id, content: "legacy text", path: "/legacy.txt",
                             savedAt: Self.t0)

        var crashing = Self.store(dir, at: Self.t1)
        crashing.crashBefore = { $0 == step }
        _ = crashing.write(id: id, content: "fresh text", originalPath: "/legacy.txt",
                           base: Self.baseA)

        let drafts = DraftStore(directory: dir).drafts()
        #expect(drafts.count == 1)
        let found = try #require(drafts.first)
        switch step {
        case .createDirectory, .writeTemporary, .commit:
            #expect(found.content == "legacy text")
            #expect(found.isLegacy)
            #expect(found.base == nil)
            #expect(found.savedAt == Self.t0)
        case .removeLegacyMetadata, .removeLegacyContent:
            #expect(found.content == "fresh text")
            #expect(!found.isLegacy)
            #expect(found.base == Self.baseA)
            #expect(found.savedAt == Self.t1)
        }
    }

    // MARK: - 3. Legacy compatibility

    @Test func aLegacyPairIsStillRead() throws {
        let dir = Self.makeDir()
        defer { Self.cleanup(dir) }
        let id = UUID()
        try Self.writeLegacy(dir, id: id, content: "old\nformat", path: nil, savedAt: Self.t0)

        let drafts = DraftStore(directory: dir).drafts()
        #expect(drafts == [DraftStore.Draft(id: id, content: "old\nformat", originalPath: nil,
                                            savedAt: Self.t0, base: nil, isLegacy: true)])
    }

    @Test func aDraftFileShadowsTheLegacyPairOfTheSameId() throws {
        let dir = Self.makeDir()
        defer { Self.cleanup(dir) }
        let id = UUID()
        let other = UUID()
        try Self.writeLegacy(dir, id: id, content: "legacy", path: "/a", savedAt: Self.t0)
        try Self.writeLegacy(dir, id: other, content: "other legacy", path: nil, savedAt: Self.t0)
        // Put a `.draft` in place without the store's legacy cleanup.
        var store = Self.store(dir, at: Self.t1)
        store.crashBefore = { $0 == .removeLegacyMetadata }
        _ = store.write(id: id, content: "new", originalPath: "/a", base: Self.baseA)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(id.uuidString).json").path))

        let drafts = DraftStore(directory: dir).drafts()
        #expect(drafts.count == 2)
        #expect(Set(drafts.map(\.id)) == Set([id, other]))
        let mine = try #require(drafts.first { $0.id == id })
        #expect(mine.content == "new")
        #expect(!mine.isLegacy)
        #expect(drafts.first { $0.id == other }?.isLegacy == true)
    }

    @Test func theFirstNewFormatWriteDeletesTheLegacyPair() throws {
        let dir = Self.makeDir()
        defer { Self.cleanup(dir) }
        let id = UUID()
        try Self.writeLegacy(dir, id: id, content: "legacy", path: nil, savedAt: Self.t0)

        try Self.store(dir, at: Self.t1).write(id: id, content: "upgraded", originalPath: nil).get()

        #expect(Self.names(dir) == ["\(id.uuidString).draft"])
        #expect(DraftStore(directory: dir).drafts().map(\.content) == ["upgraded"])
    }

    // MARK: - 4. Corrupt inputs are skipped

    @Test func corruptDraftFilesAreSkippedWithoutAffectingOthers() throws {
        let dir = Self.makeDir()
        defer { Self.cleanup(dir) }
        let good = UUID()
        try Self.store(dir, at: Self.t0).write(id: good, content: "intact", originalPath: nil).get()

        func put(_ name: String, _ bytes: [UInt8]) throws {
            try Data(bytes).write(to: dir.appendingPathComponent(name))
        }
        let validHeader = Array(#"{"version":1,"originalPath":null,"savedAt":0,"base":null}"#.utf8)
        // Undecodable header.
        try put("\(UUID().uuidString).draft", Array("{not json\nbody".utf8))
        // A future format version.
        try put("\(UUID().uuidString).draft",
                Array(#"{"version":2,"originalPath":null,"savedAt":0,"base":null}"#.utf8) + [0x0A] + Array("body".utf8))
        // No newline at all.
        try put("\(UUID().uuidString).draft", validHeader)
        // Body that is not UTF-8.
        try put("\(UUID().uuidString).draft", validHeader + [0x0A, 0x61, 0xFF, 0xFE, 0x62])
        // A name that is not a UUID (contents otherwise valid).
        try put("not-a-uuid.draft", validHeader + [0x0A] + Array("body".utf8))
        // Zero bytes.
        try put("\(UUID().uuidString).draft", [])
        // Leftover temp file of an interrupted write.
        try put(".\(UUID().uuidString).\(UUID().uuidString).tmp", validHeader + [0x0A])

        // Sanity: the same valid header with a valid body is accepted.
        let control = UUID()
        try put("\(control.uuidString).draft", validHeader + [0x0A] + Array("ok".utf8))

        let drafts = DraftStore(directory: dir).drafts()
        #expect(Set(drafts.map(\.id)) == [good, control])
        #expect(drafts.first { $0.id == good }?.content == "intact")
    }

    // MARK: - 5. Failures are reported

    @Test func writeFailsWhenTheDirectoryPathIsARegularFile() throws {
        let parent = Self.makeDir()
        defer { Self.cleanup(parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let occupied = parent.appendingPathComponent("Drafts")
        try Data("in the way".utf8).write(to: occupied)

        let result = DraftStore(directory: occupied).write(id: UUID(), content: "x", originalPath: nil)
        guard case .failure = result else {
            Issue.record("expected failure, got \(result)")
            return
        }
    }

    @Test func writeFailsInAReadOnlyDirectoryAndKeepsThePreviousDraft() throws {
        let dir = Self.makeDir()
        defer { Self.cleanup(dir) }
        let id = UUID()
        let store = Self.store(dir, at: Self.t0)
        try store.write(id: id, content: "before", originalPath: nil).get()
        #expect(chmod(dir.path, 0o555) == 0)

        let result = store.write(id: id, content: "after", originalPath: nil)
        guard case .failure = result else {
            Issue.record("expected failure, got \(result)")
            return
        }
        #expect(store.drafts().map(\.content) == ["before"])

        #expect(chmod(dir.path, 0o755) == 0)
        if case .failure(let error) = store.write(id: id, content: "after", originalPath: nil) {
            Issue.record("expected success, got \(error)")
        }
        #expect(store.drafts().map(\.content) == ["after"])
        #expect(Self.names(dir) == ["\(id.uuidString).draft"])
    }

    // MARK: - 6. remove / clear

    @Test func removeDeletesNewAndLegacyFiles() throws {
        let dir = Self.makeDir()
        defer { Self.cleanup(dir) }
        let id = UUID()
        let keep = UUID()
        try Self.writeLegacy(dir, id: id, content: "legacy", path: nil, savedAt: Self.t0)
        var store = Self.store(dir, at: Self.t1)
        store.crashBefore = { $0 == .removeLegacyMetadata }   // keep both formats
        _ = store.write(id: id, content: "new", originalPath: nil)
        try Self.store(dir, at: Self.t1).write(id: keep, content: "keep", originalPath: nil).get()
        #expect(Self.names(dir).count == 4)

        DraftStore(directory: dir).remove(id: id)
        #expect(Self.names(dir) == ["\(keep.uuidString).draft"])
        DraftStore(directory: dir).remove(id: id)              // no-op
        #expect(DraftStore(directory: dir).drafts().map(\.id) == [keep])
    }

    @Test func clearEmptiesEverything() throws {
        let dir = Self.makeDir()
        defer { Self.cleanup(dir) }
        try Self.writeLegacy(dir, id: UUID(), content: "legacy", path: nil, savedAt: Self.t0)
        try Self.store(dir, at: Self.t1).write(id: UUID(), content: "new", originalPath: nil).get()
        #expect(DraftStore(directory: dir).drafts().count == 2)

        DraftStore(directory: dir).clear()
        #expect(DraftStore(directory: dir).drafts().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    // MARK: - Ordering

    @Test func newAndLegacyDraftsSortBySavedAtThenId() throws {
        let dir = Self.makeDir()
        defer { Self.cleanup(dir) }
        let a = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
        let b = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
        let c = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!
        try Self.store(dir, at: Self.t1).write(id: a, content: "a", originalPath: nil).get()
        try Self.writeLegacy(dir, id: b, content: "b", path: nil, savedAt: Self.t0)
        try Self.store(dir, at: Self.t1).write(id: c, content: "c", originalPath: nil).get()

        #expect(DraftStore(directory: dir).drafts().map(\.id) == [b, a, c])
    }
}

// Added by the main session's review: an unreadable `.draft` must not hide a
// readable legacy pair of the same id — the pair may be the only copy left.
@Test func unreadableDraftFileFallsBackToItsLegacyPair() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("KaruDraftFallback-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DraftStore(directory: directory)
    let id = UUID()

    try Data("older but intact".utf8).write(to: store.legacyContentURL(id))
    let sidecar = #"{"originalPath":null,"savedAt":700000000}"#
    try Data(sidecar.utf8).write(to: store.legacyMetadataURL(id))
    try Data("not a header at all".utf8).write(to: store.draftURL(id))

    let drafts = store.drafts()
    #expect(drafts.count == 1)
    #expect(drafts.first?.id == id)
    #expect(drafts.first?.content == "older but intact")
    #expect(drafts.first?.isLegacy == true)
}
