import Foundation

/// The user's project folders (M17 T17.12, plan §10): standardized absolute
/// paths in `UserDefaults` under `workspace.projectFolders`, with an optional
/// bookmark per folder (`workspace.projectFolderBookmarks`, path → data;
/// security-scoped when the system allows it) so the grant the open panel
/// gave can be re-entered after a restart.
///
/// Machine-specific: deliberately **not** part of `SettingsArchive` (its
/// allowlist never names these keys); the `crossFileIndex` module toggle is
/// exported as before.
public struct ProjectFolderStore {
    public static let foldersKey = "workspace.projectFolders"
    public static let bookmarksKey = "workspace.projectFolderBookmarks"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Standardized form used everywhere as the folder's identity.
    public static func standardize(_ path: String) -> String {
        var standardized = (path as NSString).standardizingPath
        while standardized.count > 1, standardized.hasSuffix("/") { standardized.removeLast() }
        return standardized
    }

    public var folders: [String] {
        (defaults.array(forKey: Self.foldersKey) ?? []).compactMap { $0 as? String }
    }

    /// Adds `path` (standardized); false when already present.
    @discardableResult
    public func add(_ path: String, bookmark: Data? = nil) -> Bool {
        let standardized = Self.standardize(path)
        var list = folders
        guard !list.contains(standardized) else { return false }
        list.append(standardized)
        defaults.set(list, forKey: Self.foldersKey)
        if let bookmark {
            var bookmarks = defaults.dictionary(forKey: Self.bookmarksKey) ?? [:]
            bookmarks[standardized] = bookmark
            defaults.set(bookmarks, forKey: Self.bookmarksKey)
        }
        return true
    }

    public func remove(_ path: String) {
        let standardized = Self.standardize(path)
        let list = folders.filter { $0 != standardized }
        if list.isEmpty { defaults.removeObject(forKey: Self.foldersKey) } else { defaults.set(list, forKey: Self.foldersKey) }
        var bookmarks = defaults.dictionary(forKey: Self.bookmarksKey) ?? [:]
        if bookmarks.removeValue(forKey: standardized) != nil {
            if bookmarks.isEmpty { defaults.removeObject(forKey: Self.bookmarksKey) } else { defaults.set(bookmarks, forKey: Self.bookmarksKey) }
        }
    }

    public func bookmark(for path: String) -> Data? {
        (defaults.dictionary(forKey: Self.bookmarksKey) ?? [:])[Self.standardize(path)] as? Data
    }

    /// A bookmark for a folder the user just chose: security-scoped when the
    /// system grants one to this (non-sandboxed) app, else a plain bookmark,
    /// else nil.
    public static func makeBookmark(for url: URL) -> Data? {
        if let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil,
                                            relativeTo: nil) {
            return data
        }
        return try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }
}
