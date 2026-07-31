import Foundation

/// On-disk home of the always-available scratchpad (T15.1).
///
/// Deliberately *not* a crash draft: `DraftStore` exists only while a window's
/// buffer differs from disk and is wiped on a deliberate quit, whereas this file
/// is a notebook the user expects to find untouched next launch — nothing but an
/// explicit `clear()` (graduating the text into a real file) ever removes it.
/// The two are fully independent: separate directory, separate lifecycle, and
/// neither one's cleanup can reach the other's data.
///
/// Layout: one directory holding a single `content.txt`, written atomically so a
/// crash mid-write leaves either the previous text or the new one, never half of
/// both. Following the resident-memory rule (ARCHITECTURE.md §3.4) the type keeps
/// no state beyond its directory and installs no observer or timer.
public struct ScratchpadStore: Sendable {

    /// UserDefaults key for the pin toggle: `true` (the default) keeps the panel
    /// on screen when it loses focus, `false` hides it the moment focus leaves.
    public static let pinnedKey = "scratchpad.pinned"

    /// Whether the panel stays put on focus loss. Absent = pinned, so the panel
    /// never vanishes under a user who has not asked for that.
    public static func isPinned(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: pinnedKey) == nil || defaults.bool(forKey: pinnedKey)
    }

    private static let contentFileName = "content.txt"

    /// Where the scratchpad lives. Injectable so tests can run against a
    /// temporary directory instead of the user's real Application Support folder.
    public let directory: URL

    public init(directory: URL = ScratchpadStore.defaultDirectory) {
        self.directory = directory
    }

    /// `~/Library/Application Support/<bundle id>/Scratchpad`, falling back to
    /// the app name when there is no bundle identifier (test / benchmark
    /// binaries), which also keeps a test run away from the shipping app's notes.
    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Karu")
            .appendingPathComponent("Scratchpad")
    }

    /// The stored text, or `""` when nothing has been written yet (or the file
    /// is unreadable — a fresh empty pad beats refusing to open).
    public func read() -> String {
        guard let data = try? Data(contentsOf: contentURL),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    /// Replaces the stored text. Best-effort by design, like `DraftStore.write`:
    /// a failing backup must never interrupt typing, so I/O errors are swallowed
    /// — the panel keeps its content in memory either way.
    public func write(_ content: String) {
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            try Data(content.utf8).write(to: contentURL, options: .atomic)
        } catch {
            // Ignored on purpose (see above).
        }
    }

    /// Empties the pad — the text has graduated into a real file and must not
    /// come back the next time the panel opens.
    public func clear() {
        try? FileManager.default.removeItem(at: contentURL)
    }

    private var contentURL: URL {
        directory.appendingPathComponent(Self.contentFileName)
    }
}
