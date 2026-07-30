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
/// Layout: one directory holding two files per draft — `<uuid>` for the raw
/// UTF-8 contents and `<uuid>.json` for its metadata (originating file path,
/// timestamp). The split keeps a 10 MB buffer out of a JSON string escape, and
/// each file is written atomically, so a crash mid-write can never leave a
/// half-written draft: the reader either sees the previous version or the new
/// one. The metadata is written last and acts as the commit marker — a content
/// file with no readable sidecar is skipped rather than guessed at.
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

        public init(id: UUID, content: String, originalPath: String?, savedAt: Date) {
            self.id = id
            self.content = content
            self.originalPath = originalPath
            self.savedAt = savedAt
        }
    }

    /// The sidecar payload. Codable rather than a plist so a corrupt file fails
    /// loudly at decode time (and is then skipped) instead of half-parsing.
    private struct Metadata: Codable {
        let originalPath: String?
        let savedAt: Date
    }

    private static let metadataExtension = "json"

    /// Where the drafts live. Injectable so tests can run against a temporary
    /// directory instead of the user's real Application Support folder.
    public let directory: URL

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

    /// Records (or overwrites) the draft for `id`. Best-effort by design: a
    /// failing backup must never interrupt typing, so I/O errors are swallowed
    /// — the window keeps its content in memory either way.
    public func write(id: UUID, content: String, originalPath: String?) {
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            try Data(content.utf8).write(to: contentURL(id), options: .atomic)
            let metadata = Metadata(originalPath: originalPath, savedAt: Date())
            try JSONEncoder().encode(metadata).write(to: metadataURL(id), options: .atomic)
        } catch {
            // Ignored on purpose (see above).
        }
    }

    /// Forgets the draft for `id`. A no-op when there is none.
    public func remove(id: UUID) {
        try? FileManager.default.removeItem(at: metadataURL(id))
        try? FileManager.default.removeItem(at: contentURL(id))
    }

    /// Forgets every draft (a deliberate quit, or a launch that must not
    /// restore anything).
    public func clear() {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Reading

    /// Every readable draft, oldest first. Anything that does not parse — a
    /// truncated sidecar, a metadata file whose name is not a UUID, a sidecar
    /// whose content file went missing — is skipped rather than trusted, so a
    /// damaged directory degrades to "fewer drafts" instead of a failed launch.
    public func drafts() -> [Draft] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let decoder = JSONDecoder()
        var result: [Draft] = []
        for name in names where (name as NSString).pathExtension == Self.metadataExtension {
            guard let id = UUID(uuidString: (name as NSString).deletingPathExtension),
                  let metadataData = try? Data(contentsOf: metadataURL(id)),
                  let metadata = try? decoder.decode(Metadata.self, from: metadataData),
                  let contentData = try? Data(contentsOf: contentURL(id)),
                  let content = String(data: contentData, encoding: .utf8) else { continue }
            result.append(Draft(id: id,
                                content: content,
                                originalPath: metadata.originalPath,
                                savedAt: metadata.savedAt))
        }
        // Stable order: by age, then by id so equal timestamps never shuffle.
        return result.sorted {
            $0.savedAt == $1.savedAt
                ? $0.id.uuidString < $1.id.uuidString
                : $0.savedAt < $1.savedAt
        }
    }

    private func contentURL(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString)
    }

    private func metadataURL(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString)
            .appendingPathExtension(Self.metadataExtension)
    }
}
