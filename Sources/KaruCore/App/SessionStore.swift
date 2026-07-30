import Foundation

/// Persistent "what was open" list backing session restore (T14.8, plan A).
///
/// Only *saved* documents are tracked — each entry is a file path plus the
/// caret offset and the visible-area top (`scrollY`) of its window. Untitled
/// drafts are deliberately out of scope (plan B, shelved): restoring them would
/// need a scratch-file store of their contents.
///
/// The list is written **as it happens** (open / rename / focus loss / close /
/// quit), never only on a graceful exit — that is precisely what makes a
/// Sparkle relaunch *or* a crash recoverable. Following the resident-memory
/// rule (ARCHITECTURE.md §3.4) this type keeps no state of its own and installs
/// no observer or timer: every call reads and writes `UserDefaults` on the spot.
///
/// Pure Foundation with an injectable `UserDefaults` so tests can run against an
/// isolated suite instead of the shared domain.
public struct SessionStore {

    /// One recorded window: the file it shows and where the user was in it.
    public struct Entry: Equatable {
        /// Absolute, standardized path of the document.
        public let path: String
        /// Caret offset (UTF-16 units) inside the document.
        public let caret: Int
        /// Document-space y of the visible area's top edge.
        public let scrollY: Double

        public init(path: String, caret: Int, scrollY: Double) {
            self.path = path
            self.caret = caret
            self.scrollY = scrollY
        }
    }

    /// UserDefaults key holding the array of per-window dictionaries.
    public static let key = "session.openFiles"

    /// Hard ceiling on the number of recorded windows. Entries are removed when
    /// a window is closed, so a normal session never approaches this; the cap
    /// only guarantees that residue from abnormal exits (or a pathological
    /// number of open files) can never grow the defaults file without bound.
    /// On overflow the oldest entries are dropped.
    static let maxEntries = 64

    private static let pathField = "path"
    private static let caretField = "caret"
    private static let scrollField = "scrollY"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Reading

    /// The recorded windows, in the order they were first recorded (re-recording
    /// an existing path updates it in place, so the order stays stable across a
    /// session). Anything that does not parse — a wrong type at the key, a
    /// non-dictionary element, a missing/empty path — is skipped rather than
    /// trusted, so corrupted defaults degrade to "no session" instead of
    /// crashing at launch.
    public func entries() -> [Entry] {
        guard let raw = defaults.array(forKey: Self.key) else { return [] }
        return raw.compactMap { element in
            guard let dictionary = element as? [String: Any],
                  let path = dictionary[Self.pathField] as? String,
                  !path.isEmpty else { return nil }
            let caret = dictionary[Self.caretField] as? Int ?? 0
            let scrollY = dictionary[Self.scrollField] as? Double ?? 0
            return Entry(path: path, caret: max(0, caret), scrollY: max(0, scrollY))
        }
    }

    // MARK: - Writing

    /// Adds `path` to the list, or updates the position of an entry that is
    /// already there (same path ⇒ update, never a duplicate append).
    public func record(path: String, caret: Int, scrollY: Double) {
        let normalized = Self.normalize(path)
        guard !normalized.isEmpty else { return }

        var current = entries()
        let entry = Entry(path: normalized, caret: max(0, caret), scrollY: max(0, scrollY))
        if let index = current.firstIndex(where: { $0.path == normalized }) {
            current[index] = entry
        } else {
            current.append(entry)
        }
        write(current)
    }

    /// Drops the entry for `path`, if any (user closed the window, the file was
    /// renamed away, or it no longer exists on disk).
    public func remove(path: String) {
        let normalized = Self.normalize(path)
        let remaining = entries().filter { $0.path != normalized }
        guard remaining.count != entries().count else { return }
        write(remaining)
    }

    /// Forgets the whole session.
    public func clear() {
        defaults.removeObject(forKey: Self.key)
    }

    private func write(_ entries: [Entry]) {
        let capped = entries.count > Self.maxEntries
            ? Array(entries.suffix(Self.maxEntries))
            : entries
        let raw: [[String: Any]] = capped.map {
            [Self.pathField: $0.path,
             Self.caretField: $0.caret,
             Self.scrollField: $0.scrollY]
        }
        defaults.set(raw, forKey: Self.key)
    }

    /// Canonical spelling used for identity: the same file must never produce
    /// two entries just because it arrived as `/a/./b` once and `/a/b` the next
    /// time. Purely lexical (no filesystem access), so it is safe to call for a
    /// path whose file has already been deleted.
    static func normalize(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
