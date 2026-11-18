import Foundation

/// On-disk safety net for unsaved buffer contents (T14.11).
///
/// A draft exists for exactly as long as a window's text differs from what is
/// on disk (its `DocumentController` baseline); the window writes one whenever
/// that becomes true and deletes it the moment it stops being true — saved,
/// undone back to the baseline, or closed by the user. Nothing is left behind
/// after a deliberate quit (`AppDelegate` wipes the directory once termination
/// is approved), so whatever *is* found at launch can only come from a crash or
/// a force quit.
///
/// Layout (R06): one directory, **one file per draft** — `<uuid>.draft`. Its
/// first line is a compact JSON header (`version`, `originalPath`, `savedAt`,
/// `base`) ended by a single `\n`; every byte after that newline is the raw
/// UTF-8 buffer, verbatim. JSON never contains a raw newline, so the first `\n`
/// is always the separator, and the 10 MB body never goes through a JSON
/// string escape. The whole file is written to a hidden temp file in the same
/// directory and renamed over the old one, so the header and the content are
/// committed together: a crash leaves either the complete previous draft or
/// the complete new one, never new text paired with old metadata.
///
/// Drafts written by older builds as a pair (`<uuid>` content + `<uuid>.json`
/// sidecar) are still read, flagged `isLegacy` and without a `base`. A `.draft`
/// file that can be read wins over a legacy pair of the same id, and the first new-format
/// write for an id deletes that pair — after the new file is committed.
///
/// Following the resident-memory rule (ARCHITECTURE.md §3.4) the type keeps no
/// state beyond its directory and installs no observer or timer: every call
/// touches the filesystem on the spot and returns.
public struct DraftStore: Sendable {

    /// One recovered draft: what was in the buffer, where it came from, and when.
    public struct Draft: Equatable, Sendable {
        /// Identity of the draft — also the window's `draftID`, so a recovered
        /// window keeps updating the same files.
        public let id: UUID
        /// The unsaved buffer contents.
        public let content: String
        /// Absolute path of the document the draft belongs to, or `nil` for an
        /// untitled (never-saved) window.
        public let originalPath: String?
        /// When the draft was last written.
        public let savedAt: Date
        /// The on-disk state of the document the draft was taken against, or
        /// `nil` for untitled documents, callers that did not supply it, and
        /// legacy drafts.
        public let base: DiskState?
        /// `true` for a draft read from the pre-R06 two-file layout.
        public let isLegacy: Bool

        public init(id: UUID, content: String, originalPath: String?, savedAt: Date,
                    base: DiskState? = nil, isLegacy: Bool = false) {
            self.id = id
            self.content = content
            self.originalPath = originalPath
            self.savedAt = savedAt
            self.base = base
            self.isLegacy = isLegacy
        }
    }

    /// The first line of a `.draft` file. Codable rather than a plist so a
    /// corrupt header fails loudly at decode time (and is then skipped).
    private struct Header: Codable {
        static let currentVersion = 1

        let version: Int
        let originalPath: String?
        let savedAt: Date
        let base: DiskState?

        init(originalPath: String?, savedAt: Date, base: DiskState?) {
            self.version = Self.currentVersion
            self.originalPath = originalPath
            self.savedAt = savedAt
            self.base = base
        }

        private enum CodingKeys: String, CodingKey {
            case version, originalPath, savedAt, base
        }

        // Explicit nulls, so every header spells out all four fields.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(version, forKey: .version)
            try container.encode(originalPath, forKey: .originalPath)
            try container.encode(savedAt, forKey: .savedAt)
            try container.encode(base, forKey: .base)
        }
    }

    /// The pre-R06 sidecar payload, kept only to read old drafts.
    private struct LegacyMetadata: Codable {
        let originalPath: String?
        let savedAt: Date
    }

    /// The persistence steps of `write`, in order. Test seam only.
    enum WriteStep: CaseIterable, Sendable {
        case createDirectory
        case writeTemporary
        case commit
        case removeLegacyMetadata
        case removeLegacyContent
    }

    /// Raised when `crashBefore` stops a write.
    struct SimulatedCrash: Error {}

    static let draftExtension = "draft"
    static let legacyMetadataExtension = "json"
    private static let temporarySuffix = ".tmp"

    /// Where the drafts live. Injectable so tests can run against a temporary
    /// directory instead of the user's real Application Support folder.
    public let directory: URL

    /// Test seam: asked before each persistence step of `write`; returning
    /// `true` abandons the write right there, with no cleanup — what a crash at
    /// that point would leave behind. Never set in production.
    var crashBefore: (@Sendable (WriteStep) -> Bool)?

    /// Test seam: the clock stamped into `savedAt`.
    var now: @Sendable () -> Date = { Date() }

    public init(directory: URL = DraftStore.defaultDirectory) {
        self.directory = directory
    }

    /// `~/Library/Application Support/<bundle id>/Drafts`, falling back to the
    /// app name when there is no bundle identifier (test / benchmark binaries),
    /// which also keeps a test run away from the shipping app's drafts.
    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Karu")
            .appendingPathComponent("Drafts")
    }

    // MARK: - Writing

    /// Records (or overwrites) the draft for `id` in one atomic commit and
    /// reports whether it landed. A failed checkpoint never touches the
    /// previous draft for `id`; the caller decides whether a failure matters
    /// (the window keeps its content in memory either way).
    @discardableResult
    public func write(id: UUID, content: String, originalPath: String?,
                      base: DiskState? = nil) -> Result<Void, Error> {
        let fileManager = FileManager.default
        var temporary: URL?
        do {
            try step(.createDirectory)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

            let header = Header(originalPath: originalPath, savedAt: now(), base: base)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            var data = try encoder.encode(header)
            data.reserveCapacity(data.count + 1 + content.utf8.count)
            data.append(0x0A)
            data.append(contentsOf: content.utf8)

            try step(.writeTemporary)
            let tmp = directory.appendingPathComponent(
                ".\(id.uuidString).\(UUID().uuidString)\(Self.temporarySuffix)")
            temporary = tmp
            try data.write(to: tmp, options: .withoutOverwriting)

            try step(.commit)
            try Self.rename(tmp, over: draftURL(id))
            temporary = nil

            // The new file is committed; only now may the legacy pair go. The
            // sidecar (the old commit marker) first, so a crash in between can
            // only leave an orphan content file, which the reader ignores.
            // Best-effort: the draft already landed and shadows the pair.
            try step(.removeLegacyMetadata)
            try? fileManager.removeItem(at: legacyMetadataURL(id))
            try step(.removeLegacyContent)
            try? fileManager.removeItem(at: legacyContentURL(id))
            return .success(())
        } catch is SimulatedCrash {
            // A "crash": leave the directory exactly as it is.
            return .failure(SimulatedCrash())
        } catch {
            if let temporary { try? fileManager.removeItem(at: temporary) }
            return .failure(error)
        }
    }

    /// Forgets the draft for `id` (new and legacy files, and any temp file a
    /// crashed write left behind). A no-op when there is none.
    public func remove(id: UUID) {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: draftURL(id))
        try? fileManager.removeItem(at: legacyMetadataURL(id))
        try? fileManager.removeItem(at: legacyContentURL(id))
        let tempPrefix = ".\(id.uuidString)."
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(tempPrefix) && name.hasSuffix(Self.temporarySuffix) {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Forgets every draft (a deliberate quit, or a launch that must not
    /// restore anything).
    public func clear() {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Reading

    /// Every readable draft, oldest first. Anything that does not parse — an
    /// undecodable or newer-version header, a file with no header line, a body
    /// that is not UTF-8, a name that is not a UUID, a legacy sidecar whose
    /// content file went missing — is skipped rather than trusted, so a damaged
    /// directory degrades to "fewer drafts" instead of a failed launch.
    public func drafts() -> [Draft] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let decoder = JSONDecoder()
        var result: [Draft] = []
        var seen = Set<UUID>()

        for name in names where (name as NSString).pathExtension == Self.draftExtension {
            guard let id = UUID(uuidString: (name as NSString).deletingPathExtension) else { continue }
            // A readable `.draft` file shadows a legacy pair of the same id.
            // An unreadable one does not: if a legacy pair is still there it
            // may be the only copy left, and an older copy beats none.
            guard let draft = readDraft(id: id, decoder: decoder) else { continue }
            seen.insert(id)
            result.append(draft)
        }

        for name in names where (name as NSString).pathExtension == Self.legacyMetadataExtension {
            guard let id = UUID(uuidString: (name as NSString).deletingPathExtension),
                  !seen.contains(id),
                  let metadataData = try? Data(contentsOf: legacyMetadataURL(id)),
                  let metadata = try? decoder.decode(LegacyMetadata.self, from: metadataData),
                  let contentData = try? Data(contentsOf: legacyContentURL(id)),
                  let content = String(data: contentData, encoding: .utf8) else { continue }
            result.append(Draft(id: id,
                                content: content,
                                originalPath: metadata.originalPath,
                                savedAt: metadata.savedAt,
                                base: nil,
                                isLegacy: true))
        }

        // Stable order: by age, then by id so equal timestamps never shuffle.
        return result.sorted {
            $0.savedAt == $1.savedAt
                ? $0.id.uuidString < $1.id.uuidString
                : $0.savedAt < $1.savedAt
        }
    }

    /// Parses one `.draft` file: header up to the first `\n`, body after it.
    private func readDraft(id: UUID, decoder: JSONDecoder) -> Draft? {
        guard let data = try? Data(contentsOf: draftURL(id)),
              let newline = data.firstIndex(of: 0x0A),
              let header = try? decoder.decode(Header.self, from: data[data.startIndex..<newline]),
              header.version == Header.currentVersion,
              let content = String(data: data[data.index(after: newline)...], encoding: .utf8)
        else { return nil }
        return Draft(id: id,
                     content: content,
                     originalPath: header.originalPath,
                     savedAt: header.savedAt,
                     base: header.base)
    }

    // MARK: - Helpers

    private func step(_ step: WriteStep) throws {
        if let crashBefore, crashBefore(step) { throw SimulatedCrash() }
    }

    /// `rename(2)`: atomically replaces `destination` (same volume).
    private static func rename(_ source: URL, over destination: URL) throws {
        let failure = source.withUnsafeFileSystemRepresentation { src in
            destination.withUnsafeFileSystemRepresentation { dst -> Int32? in
                guard let src, let dst else { return EINVAL }
                return Foundation.rename(src, dst) == 0 ? nil : errno
            }
        }
        if let failure {
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
    }

    func draftURL(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString)
            .appendingPathExtension(Self.draftExtension)
    }

    func legacyContentURL(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString)
    }

    func legacyMetadataURL(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString)
            .appendingPathExtension(Self.legacyMetadataExtension)
    }
}
