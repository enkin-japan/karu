import Darwin
import Foundation

// M17 T17.13 — the only door import resolution has to the disk (plan §9:
// "不执行任何程序，只读文件"). Every lookup, listing and read of the
// resolvers goes through an `ImportFileSystem`, so tests can inject a
// recording reader and assert which paths were touched (the no-project-folder
// rule: never the document's own directory). Nothing here starts a process.

/// What `stat` says about a path.
public struct ImportFileInfo: Sendable, Equatable {
    public var isDirectory: Bool
    public var size: Int
    /// Modification time (seconds since 1970, sub-second precision).
    public var modificationTime: Double

    public init(isDirectory: Bool, size: Int, modificationTime: Double) {
        self.isDirectory = isDirectory
        self.size = size
        self.modificationTime = modificationTime
    }
}

/// Read-only file access for import resolution. Implementations must be
/// thread-safe: the resolvers call them on the import queue.
public protocol ImportFileSystem: Sendable {
    /// `stat` of `path` (following symbolic links), nil when it does not exist.
    func info(_ path: String) -> ImportFileInfo?
    /// The file's bytes, nil when unreadable.
    func contents(_ path: String) -> Data?
    /// Entry names of a directory, nil when it cannot be listed.
    func list(_ path: String) -> [String]?
    /// At most `limit` entry names of a directory (in enumeration order, `.`
    /// and `..` excluded); `truncated` when it holds more. Nil when it cannot
    /// be listed. The default builds on `list(_:)` (the whole directory);
    /// `SystemImportFileSystem` stops enumerating at the limit (R09).
    func list(_ path: String, limit: Int) -> (names: [String], truncated: Bool)?
    /// `realpath(3)`, or `path` itself when it cannot be resolved.
    func realPath(_ path: String) -> String
}

extension ImportFileSystem {
    func isFile(_ path: String) -> Bool { info(path).map { !$0.isDirectory } ?? false }
    func isDirectory(_ path: String) -> Bool { info(path)?.isDirectory ?? false }

    public func list(_ path: String, limit: Int) -> (names: [String], truncated: Bool)? {
        guard let names = list(path) else { return nil }
        let bound = max(0, limit)
        return names.count > bound ? (Array(names.prefix(bound)), true) : (names, false)
    }

    /// The bytes of a regular file of at most `maxBytes` (its size checked
    /// with `info` before anything is read, R09); nil when it is missing, a
    /// directory, larger, or unreadable.
    func contents(_ path: String, maxBytes: Int) -> Data? {
        guard let info = info(path), !info.isDirectory, info.size <= maxBytes,
              let data = contents(path), data.count <= maxBytes else { return nil }
        return data
    }
}

/// The production reader: `stat`, `Data(contentsOf:)`, `FileManager` listings
/// (bounded ones with `readdir`).
public struct SystemImportFileSystem: ImportFileSystem {
    public init() {}

    public func info(_ path: String) -> ImportFileInfo? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1_000_000_000
        return ImportFileInfo(isDirectory: (st.st_mode & S_IFMT) == S_IFDIR, size: Int(st.st_size),
                              modificationTime: mtime)
    }

    public func contents(_ path: String) -> Data? {
        try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
    }

    public func list(_ path: String) -> [String]? {
        try? FileManager.default.contentsOfDirectory(atPath: path)
    }

    /// `readdir` until `limit` names (one more is looked at to know whether
    /// the directory holds more); the full listing is never built.
    public func list(_ path: String, limit: Int) -> (names: [String], truncated: Bool)? {
        guard let dir = opendir(path) else { return nil }
        defer { closedir(dir) }
        let bound = max(0, limit)
        var names: [String] = []
        while let entry = readdir(dir) {
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafePointer(to: &entry.pointee.d_name) { tuple in
                tuple.withMemoryRebound(to: CChar.self, capacity: length + 1) {
                    FileManager.default.string(withFileSystemRepresentation: $0, length: length)
                }
            }
            if name == "." || name == ".." { continue }
            if names.count >= bound { return (names, true) }
            names.append(name)
        }
        return (names, false)
    }

    public func realPath(_ path: String) -> String {
        guard let resolved = Darwin.realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// Path helpers shared by the resolvers (plain string work, no disk).
enum ImportPath {
    /// `a/b` joined (no normalisation of `..`; see `normalized`).
    static func join(_ base: String, _ component: String) -> String {
        if base.hasSuffix("/") { return base + component }
        return base + "/" + component
    }

    static func parent(_ path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    static func lastComponent(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    /// `.` and `..` components resolved lexically (no symlinks).
    static func normalized(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    /// `.` and `..` components resolved as text only (T17.16): unlike
    /// `normalized` it never rewrites `/private/var/…` to `/var/…`, so the
    /// result keeps the project root's spelling.
    static func resolvingDots(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }

    /// `path` lies in `root` (or is `root`).
    static func isInside(_ path: String, _ root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// The folders macOS guards with a privacy prompt for non-sandboxed apps
    /// (T17.0: reading another file there triggers a "Documents" prompt).
    /// Import resolution never reads them unless they lie inside an allowed
    /// root (the project folder, an interpreter prefix the user configured).
    static let protectedHomeFolders = ["Desktop", "Documents", "Downloads", "Library/Mobile Documents",
                                       "Pictures", "Movies", "Music"]

    static func isPrivacyProtected(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        protectedHomeFolders.contains { isInside(path, join(home, $0)) }
    }
}
