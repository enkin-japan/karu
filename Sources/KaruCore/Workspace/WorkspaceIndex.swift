import Darwin
import Foundation

/// Project folders and their cross-file symbol index (M17 T17.12, plan §10).
///
/// **Threading.** All indexing runs on one serial, utility-QoS queue
/// (`queue`) that only reads files from disk — never AppKit, never an open
/// document. Work is split into steps of at most one (re)indexed file (or one
/// directory listing, or up to 64 unchanged-file checks), each step a
/// separate block, so at most one file is processed at a time across all
/// folders and the queue yields between files. FSEvents callbacks arrive on a
/// second private queue and only record paths. Queries run on the caller's
/// thread under the folder's database lock (held by the indexer for one
/// file's transaction at most). Mutable bookkeeping is under `lock`.
///
/// **Lifecycle.** Nothing happens until `start()` (the app calls it at
/// launch). Per folder: open its database, start its FSEvents stream, then a
/// full walk that skips files whose size and mtime match the database
/// (catching up offline changes), indexes the rest and deletes rows of files
/// that are gone; afterwards FSEvents drive incremental updates. Turning the
/// `crossFileIndex` module off stops the streams, drops pending work, closes
/// the databases and frees their caches (the files stay on disk); turning it
/// on resumes with the catch-up walk.
public final class WorkspaceIndex: @unchecked Sendable {
    /// Posted on the main queue (object: the index) when folder statuses change.
    public static let didChangeNotification = Notification.Name("KaruWorkspaceIndexDidChange")

    /// The app's index (Application Support root, standard defaults).
    public static let shared = WorkspaceIndex()

    public enum State: String, Sendable, Equatable {
        /// Walking / indexing.
        case indexing
        case upToDate
        /// Stopped at `IndexScope.maxFiles`; the rest of the folder is not indexed.
        case overLimit
        /// The folder is missing or cannot be listed.
        case unreadable
        /// The `crossFileIndex` module is off.
        case paused
    }

    public struct FolderStatus: Sendable, Equatable {
        public let path: String
        public let state: State
        public let indexedFiles: Int
        /// Database + WAL bytes on disk.
        public let diskBytes: Int64
    }

    /// `~/Library/Application Support/<bundle id>` (the `Index/` folder lives
    /// below it); same fallback rule as `ToolchainStore`.
    public static var defaultRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Karu", isDirectory: true)
    }

    public let root: URL
    public let scope: IndexScope
    let latency: TimeInterval
    private let store: ProjectFolderStore
    private let modules: ModuleSettings
    private let center: NotificationCenter

    let queue = DispatchQueue(label: "dev.enkin.Karu.workspace-index", qos: .utility,
                              autoreleaseFrequency: .workItem)
    private let eventQueue = DispatchQueue(label: "dev.enkin.Karu.workspace-index.events", qos: .utility,
                                           autoreleaseFrequency: .workItem)

    private let lock = NSLock()
    private var started = false
    private var enabled = false
    private var folders: [String: Folder] = [:]
    private var pumpScheduled = false
    private var roundRobin = 0
    private var notifyScheduled = false
    private var observer: NSObjectProtocol?
    /// Files (re)indexed since init (tests: unchanged files are skipped).
    private var writes = 0

    /// - Parameters:
    ///   - root: Application Support root (tests inject a temporary directory).
    ///   - scope: size / count caps (tests inject small ones).
    ///   - latency: FSEvents coalescing (≤ 0.3 s).
    public init(root: URL = WorkspaceIndex.defaultRoot, scope: IndexScope = IndexScope(),
                store: ProjectFolderStore = ProjectFolderStore(), modules: ModuleSettings? = nil,
                center: NotificationCenter = .default, latency: TimeInterval = 0.3) {
        self.root = root
        self.scope = scope
        self.store = store
        self.center = center
        self.modules = modules ?? ModuleSettings(center: center)
        self.latency = latency
    }

    deinit {
        if let observer { center.removeObserver(observer) }
        for folder in folders.values { folder.watcher?.stop() }
    }

    // MARK: - Folder model

    final class Folder {
        let path: String
        /// `realpath` of `path` (FSEvents report resolved paths).
        let realPath: String
        let databaseURL: URL
        /// Guards `database` use (indexer writes, queries).
        let databaseLock = NSLock()
        var database: IndexDatabase?

        // Under `WorkspaceIndex.lock`.
        var active = false
        var state: State = .paused
        var indexedFiles = 0
        var overLimit = false
        var needsFullScan = false
        var pending = Set<String>()
        var watcher: FolderWatcher?
        var bookmarkURL: URL?
        /// Mirror of `scan != nil`.
        var scanning = false

        // Queue only.
        var scan: ScanState?
        /// Directory (relative) → rules of its own `.gitignore`.
        var ruleCache: [String: [GitIgnoreRule]] = [:]

        init(path: String, root: URL) {
            self.path = path
            self.realPath = Self.resolve(path)
            self.databaseURL = IndexDatabase.fileURL(forFolder: path, root: root)
        }

        static func resolve(_ path: String) -> String {
            guard let resolved = realpath(path, nil) else { return path }
            defer { free(resolved) }
            return String(cString: resolved)
        }

        /// `absolute` relative to this folder ("" for the folder itself), or nil.
        func relativePath(_ absolute: String) -> String? {
            for base in [path, realPath] {
                if absolute == base { return "" }
                if absolute.hasPrefix(base + "/") { return String(absolute.dropFirst(base.count + 1)) }
            }
            return nil
        }

        /// Under `WorkspaceIndex.lock`.
        var hasWork: Bool { scanning || needsFullScan || !pending.isEmpty }
    }

    struct ScanState {
        /// "" for a full walk, else the directory being reconciled.
        let prefix: String
        let full: Bool
        /// Directories still to list with the accumulated rules for their entries.
        var directories: [(path: String, rules: [GitIgnoreRule])]
        var files: [(path: String, language: String)] = []
        var seen = Set<Int64>()
        var counted = 0
        var overLimit = false
        var rootUnreadable = false
    }

    // MARK: - Lifecycle

    /// Loads the stored folders and, when the module is on, starts indexing.
    /// Idempotent.
    public func start() {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        enabled = modules.isEnabled(.crossFileIndex)
        lock.unlock()
        observer = center.addObserver(forName: ModuleSettings.didChangeNotification, object: nil, queue: nil) {
            [weak self] note in
            guard let self, note.object as? String == FeatureModule.crossFileIndex.rawValue else { return }
            self.setEnabled(self.modules.isEnabled(.crossFileIndex))
        }
        for path in store.folders { attach(path) }
        postChange()
    }

    public var isEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled
    }

    /// Module toggle: off stops streams and work and closes databases; on
    /// resumes with a catch-up walk.
    func setEnabled(_ on: Bool) {
        lock.lock()
        guard started, enabled != on else { lock.unlock(); return }
        enabled = on
        let all = Array(folders.values)
        lock.unlock()
        for folder in all {
            if on { activate(folder) } else { deactivate(folder) }
        }
        postChange()
    }

    private func attach(_ path: String) {
        let folder = Folder(path: path, root: root)
        if let bookmark = store.bookmark(for: path) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope],
                                  relativeTo: nil, bookmarkDataIsStale: &stale),
               url.startAccessingSecurityScopedResource() {
                folder.bookmarkURL = url
            }
        }
        lock.lock()
        folders[path] = folder
        let on = enabled
        lock.unlock()
        if on { activate(folder) }
    }

    private func activate(_ folder: Folder) {
        lock.lock()
        guard !folder.active else { lock.unlock(); return }
        folder.active = true
        folder.state = .indexing
        folder.needsFullScan = true
        folder.pending.removeAll()
        lock.unlock()
        queue.async { [self, folder] in
            guard isActive(folder) else { return }
            openDatabase(folder)
            lock.lock()
            let needsWatcher = folder.watcher == nil
            lock.unlock()
            if folder.database != nil, needsWatcher {
                let watcher = FolderWatcher(path: folder.realPath, latency: latency, queue: eventQueue) {
                    [weak self, weak folder] events in
                    guard let self, let folder else { return }
                    self.record(events, in: folder)
                }
                lock.lock()
                if folder.active { folder.watcher = watcher } else { watcher?.stop() }
                lock.unlock()
            }
            schedulePump()
        }
    }

    /// Stops the stream at once; closes the database on the queue (after any
    /// in-flight step). `then` runs on the queue afterwards.
    private func deactivate(_ folder: Folder, then: (() -> Void)? = nil) {
        lock.lock()
        folder.active = false
        folder.state = .paused
        folder.needsFullScan = false
        folder.pending.removeAll()
        let watcher = folder.watcher
        folder.watcher = nil
        lock.unlock()
        watcher?.stop()
        queue.async { [self] in
            setScan(nil, of: folder)
            folder.ruleCache = [:]
            folder.databaseLock.lock()
            folder.database?.checkpoint()
            folder.database?.close()
            folder.database = nil
            folder.databaseLock.unlock()
            then?()
        }
    }

    private func isActive(_ folder: Folder) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return folder.active
    }

    private func openDatabase(_ folder: Folder) {
        folder.databaseLock.lock()
        defer { folder.databaseLock.unlock() }
        guard folder.database == nil else { return }
        do {
            let database = try IndexDatabase(url: folder.databaseURL, folderPath: folder.path)
            folder.database = database
            let count = (try? database.fileCount()) ?? 0
            lock.lock()
            folder.indexedFiles = count
            lock.unlock()
        } catch {
            lock.lock()
            folder.state = .unreadable
            folder.needsFullScan = false
            lock.unlock()
            postChange()
        }
    }

    // MARK: - Folder management (Settings)

    /// Adds a folder chosen by the user; false when it is already listed or
    /// not a directory.
    @discardableResult
    public func addFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let path = ProjectFolderStore.standardize(url.path)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue,
              store.add(path, bookmark: ProjectFolderStore.makeBookmark(for: url)) else { return false }
        lock.lock()
        let isStarted = started
        lock.unlock()
        if isStarted { attach(path) }
        postChange()
        return true
    }

    /// Removes a folder: stops its work and deletes its database.
    /// `completion` runs on the main queue once the files are gone.
    public func removeFolder(_ path: String, completion: (@Sendable () -> Void)? = nil) {
        let path = ProjectFolderStore.standardize(path)
        store.remove(path)
        lock.lock()
        let folder = folders.removeValue(forKey: path)
        lock.unlock()
        postChange()
        let databaseURL = folder?.databaseURL ?? IndexDatabase.fileURL(forFolder: path, root: root)
        let finish: () -> Void = {
            IndexDatabase.remove(at: databaseURL)
            folder?.bookmarkURL?.stopAccessingSecurityScopedResource()
            DispatchQueue.main.async { completion?() }
        }
        if let folder { deactivate(folder, then: finish) } else { queue.async(execute: finish) }
    }

    /// Deletes a folder's database and rebuilds it from scratch.
    /// `completion` runs on the main queue once the rebuild has been queued.
    public func clearIndex(_ path: String, completion: (@Sendable () -> Void)? = nil) {
        let path = ProjectFolderStore.standardize(path)
        lock.lock()
        let folder = folders[path]
        let on = enabled
        lock.unlock()
        guard let folder else { DispatchQueue.main.async { completion?() }; return }
        deactivate(folder) { [self] in
            IndexDatabase.remove(at: folder.databaseURL)
            lock.lock()
            folder.indexedFiles = 0
            folder.overLimit = false
            lock.unlock()
            if on { activate(folder) }
            postChange()
            DispatchQueue.main.async { completion?() }
        }
    }

    /// Statuses in the stored order.
    public func statuses() -> [FolderStatus] {
        let paths = store.folders
        lock.lock()
        let snapshot: [(String, State, Int, URL)] = paths.map { path in
            if let folder = folders[path] {
                return (path, folder.state, folder.indexedFiles, folder.databaseURL)
            }
            return (path, .paused, 0, IndexDatabase.fileURL(forFolder: path, root: root))
        }
        lock.unlock()
        return snapshot.map {
            FolderStatus(path: $0.0, state: $0.1, indexedFiles: $0.2, diskBytes: IndexDatabase.diskUsage(at: $0.3))
        }
    }

    public var folderPaths: [String] { store.folders }

    /// Whether every active folder has finished its pending work.
    public var isIdle: Bool {
        lock.lock(); defer { lock.unlock() }
        return !pumpScheduled && !folders.values.contains { $0.active && ($0.hasWork || $0.state == .indexing) }
    }

    // MARK: - Events

    private func record(_ events: [(path: String, rescan: Bool)], in folder: Folder) {
        lock.lock()
        guard folder.active else { lock.unlock(); return }
        for event in events {
            guard let relative = folder.relativePath(event.path) else { continue }
            if event.rescan || relative.isEmpty {
                folder.needsFullScan = true
            } else {
                folder.pending.insert(relative)
            }
        }
        lock.unlock()
        schedulePump()
    }

    // MARK: - Pump

    private func schedulePump() {
        lock.lock()
        guard !pumpScheduled else { lock.unlock(); return }
        pumpScheduled = true
        lock.unlock()
        queue.async { [self] in pump() }
    }

    /// One step of one folder's work, then re-dispatch (yielding the queue).
    private func pump() {
        lock.lock()
        pumpScheduled = false
        let candidates = folders.values.filter { $0.active && $0.hasWork }.sorted { $0.path < $1.path }
        guard !candidates.isEmpty else { lock.unlock(); return }
        roundRobin = (roundRobin + 1) % candidates.count
        let folder = candidates[roundRobin]
        var startFull = false
        var pendingPath: String?
        if !folder.scanning {
            if folder.needsFullScan {
                folder.needsFullScan = false
                folder.pending.removeAll()
                folder.state = .indexing
                startFull = true
            } else {
                // Any order: each path is reconciled against the disk as it is now.
                pendingPath = folder.pending.popFirst()
            }
        }
        lock.unlock()

        if startFull {
            folder.ruleCache = [:]
            setScan(ScanState(prefix: "", full: true, directories: [("", [])]), of: folder)
            postChange()
        } else if let pendingPath {
            handle(pendingPath, in: folder)
        } else if folder.scan != nil {
            stepScan(folder)
        }
        schedulePump()
    }

    // MARK: - Scanning

    /// Sets the queue-only scan state and its lock-protected mirror.
    private func setScan(_ scan: ScanState?, of folder: Folder) {
        folder.scan = scan
        lock.lock()
        folder.scanning = scan != nil
        lock.unlock()
    }

    private func stepScan(_ folder: Folder) {
        guard var scan = folder.scan else { return }
        if !scan.files.isEmpty {
            // Up to 64 unchanged-file checks, but at most one (re)indexed file.
            var checked = 0
            var index = 0
            while index < scan.files.count, checked < 64 {
                let file = scan.files[index]
                index += 1
                checked += 1
                let (id, wrote) = indexIfChanged(file.path, language: file.language, in: folder, allowNew: scan.full)
                if let id { scan.seen.insert(id) }
                if wrote { break }
            }
            scan.files.removeFirst(index)
            folder.scan = scan
            return
        }
        if !scan.directories.isEmpty {
            let directory = scan.directories.removeLast()
            list(directory, in: folder, scan: &scan)
            folder.scan = scan
            return
        }
        setScan(nil, of: folder)
        finish(&scan, in: folder)
    }

    private func absolute(_ relative: String, in folder: Folder) -> String {
        relative.isEmpty ? folder.path : folder.path + "/" + relative
    }

    /// Lists one directory into `scan`: its `.gitignore`, then subdirectories
    /// (pushed for later, in sorted order) and indexable files.
    private func list(_ directory: (path: String, rules: [GitIgnoreRule]), in folder: Folder, scan: inout ScanState) {
        let directoryPath = absolute(directory.path, in: folder)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directoryPath) else {
            if directory.path == scan.prefix { scan.rootUnreadable = true; scan.directories.removeAll() }
            return
        }
        let own = gitIgnoreRules(of: directory.path, in: folder)
        let rules = directory.rules + own
        var subdirectories: [String] = []
        for name in names.sorted() {
            let relative = directory.path.isEmpty ? name : directory.path + "/" + name
            var info = stat()
            guard lstat(absolute(relative, in: folder), &info) == 0 else { continue }
            let type = info.st_mode & S_IFMT
            if type == S_IFDIR {
                guard !IndexScope.isSkippedDirectory(name),
                      !GitIgnoreRule.isIgnored(relative, isDirectory: true, rules: rules) else { continue }
                subdirectories.append(relative)
            } else if type == S_IFREG {
                guard let language = IndexScope.languageIdentifier(forFileName: name),
                      Int(info.st_size) <= scope.maxFileBytes,
                      !GitIgnoreRule.isIgnored(relative, isDirectory: false, rules: rules) else { continue }
                if scan.full {
                    if scan.counted >= scope.maxFiles {
                        scan.overLimit = true
                        scan.directories.removeAll()
                        return
                    }
                    scan.counted += 1
                }
                scan.files.append((relative, language))
            }
        }
        for subdirectory in subdirectories.reversed() { scan.directories.append((subdirectory, rules)) }
    }

    /// Sweeps rows not seen by the walk and publishes the result.
    private func finish(_ scan: inout ScanState, in folder: Folder) {
        if scan.rootUnreadable {
            lock.lock()
            if scan.full { folder.state = .unreadable }
            lock.unlock()
            postChange()
            return
        }
        folder.databaseLock.lock()
        if let database = folder.database {
            let stale = ((try? database.files(under: scan.prefix)) ?? []).filter { !scan.seen.contains($0.id) }
            try? database.deleteFiles(ids: stale.map(\.id))
            if scan.full || !stale.isEmpty { database.checkpoint() }
            database.releaseMemory()
            let count = (try? database.fileCount()) ?? 0
            lock.lock()
            folder.indexedFiles = count
            lock.unlock()
        }
        folder.databaseLock.unlock()
        lock.lock()
        if scan.full { folder.overLimit = scan.overLimit }
        if folder.active, folder.state == .indexing || folder.state == .upToDate || folder.state == .overLimit {
            folder.state = folder.overLimit ? .overLimit : .upToDate
        }
        lock.unlock()
        postChange()
    }

    /// The rules of `directory`'s own `.gitignore` (cached per walk).
    private func gitIgnoreRules(of directory: String, in folder: Folder) -> [GitIgnoreRule] {
        if let cached = folder.ruleCache[directory] { return cached }
        let file = absolute(directory, in: folder) + "/.gitignore"
        var rules: [GitIgnoreRule] = []
        if let data = FileManager.default.contents(atPath: file), data.count <= 1_048_576 {
            rules = GitIgnoreRule.parse(String(decoding: data, as: UTF8.self), base: directory)
        }
        folder.ruleCache[directory] = rules
        return rules
    }

    /// Accumulated rules that apply to the entries of `directory`, and
    /// whether `directory` itself (or an ancestor) is excluded.
    private func rules(for directory: String, in folder: Folder) -> (rules: [GitIgnoreRule], excluded: Bool) {
        var rules = gitIgnoreRules(of: "", in: folder)
        guard !directory.isEmpty else { return (rules, false) }
        var current = ""
        for component in directory.split(separator: "/") {
            current = current.isEmpty ? String(component) : current + "/" + component
            if IndexScope.isSkippedDirectory(String(component))
                || GitIgnoreRule.isIgnored(current, isDirectory: true, rules: rules) {
                return (rules, true)
            }
            rules += gitIgnoreRules(of: current, in: folder)
        }
        return (rules, false)
    }

    // MARK: - Incremental

    /// Applies one changed path (relative) from FSEvents.
    private func handle(_ relative: String, in folder: Folder) {
        let name = (relative as NSString).lastPathComponent
        if name == ".gitignore" {
            lock.lock()
            folder.needsFullScan = true
            lock.unlock()
            return
        }
        let parent = (relative as NSString).deletingLastPathComponent
        let (rules, parentExcluded) = rules(for: parent, in: folder)
        var info = stat()
        let exists = lstat(absolute(relative, in: folder), &info) == 0
        let type = info.st_mode & S_IFMT
        if parentExcluded || !exists {
            removeRows(relative, in: folder)
            return
        }
        if type == S_IFDIR {
            if IndexScope.isSkippedDirectory(name) || GitIgnoreRule.isIgnored(relative, isDirectory: true, rules: rules) {
                removeRows(relative, in: folder)
                return
            }
            setScan(ScanState(prefix: relative, full: false, directories: [(relative, rules)]), of: folder)
            return
        }
        guard type == S_IFREG, let language = IndexScope.languageIdentifier(forFileName: name),
              Int(info.st_size) <= scope.maxFileBytes,
              !GitIgnoreRule.isIgnored(relative, isDirectory: false, rules: rules) else {
            removeRows(relative, in: folder)
            return
        }
        _ = indexIfChanged(relative, language: language, in: folder, allowNew: false)
        postChange()
    }

    private func removeRows(_ relative: String, in folder: Folder) {
        folder.databaseLock.lock()
        let removed = (try? folder.database?.deleteFiles(path: relative, includingDescendants: true)) ?? 0
        let count = removed > 0 ? (try? folder.database?.fileCount()) ?? 0 : nil
        folder.databaseLock.unlock()
        if let count {
            lock.lock()
            folder.indexedFiles = count
            if count < scope.maxFiles, folder.state == .overLimit, !folder.overLimit { folder.state = .upToDate }
            lock.unlock()
            postChange()
        }
    }

    /// Re-indexes `relative` unless its size and mtime match the database.
    /// `allowNew` false (incremental) refuses new files past the file cap.
    /// Returns the file's row id (nil when not indexed) and whether it wrote.
    private func indexIfChanged(_ relative: String, language: String, in folder: Folder,
                                allowNew: Bool) -> (Int64?, Bool) {
        let path = absolute(relative, in: folder)
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return (nil, false) }
        let size = Int64(info.st_size)
        let mtime = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        folder.databaseLock.lock()
        let record = try? folder.database?.fileRecord(path: relative)
        folder.databaseLock.unlock()
        if let record, record.size == size, record.mtime == mtime { return (record.id, false) }
        if record == nil, !allowNew {
            lock.lock()
            let full = folder.indexedFiles >= scope.maxFiles
            if full { folder.overLimit = true; folder.state = .overLimit }
            lock.unlock()
            if full { postChange(); return (nil, false) }
        }
        guard size <= Int64(scope.maxFileBytes), let data = FileManager.default.contents(atPath: path) else {
            return (nil, false)
        }
        let symbols = Self.symbols(of: data, language: language)
        folder.databaseLock.lock()
        let id = try? folder.database?.replaceFile(path: relative, language: language, size: size, mtime: mtime,
                                                    symbols: symbols)
        let count = record == nil && id != nil ? (try? folder.database?.fileCount()) : nil
        folder.databaseLock.unlock()
        lock.lock()
        if id != nil { writes += 1 }
        if let count { folder.indexedFiles = count }
        lock.unlock()
        if count != nil { postChange() }
        return (id, id != nil)
    }

    /// The indexed declarations of a file's bytes (UTF-8, a leading BOM
    /// dropped; invalid sequences replaced).
    static func symbols(of data: Data, language: String) -> [IndexedSymbol] {
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        let text: NSString = NSString(data: bytes, encoding: String.Encoding.utf8.rawValue)
            ?? (String(decoding: bytes, as: UTF8.self) as NSString)
        let scan = DeclarationScan.scan(text: text as String, languageIdentifier: language)
        return IndexedSymbol.extract(from: scan, text: text)
    }

    /// The text the index reads for a file (for tests comparing against
    /// `DeclarationScan`).
    static func decodedText(_ data: Data) -> String {
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        return (NSString(data: bytes, encoding: String.Encoding.utf8.rawValue) as String?)
            ?? String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Notifications

    private func postChange() {
        lock.lock()
        guard !notifyScheduled else { lock.unlock(); return }
        notifyScheduled = true
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.notifyScheduled = false
            self.lock.unlock()
            self.center.post(name: Self.didChangeNotification, object: self)
        }
    }

    // MARK: - Queries (T17.14)

    /// The project folder containing `documentPath` (longest match), or nil
    /// (also while the module is off).
    public func projectFolder(containing documentPath: String) -> String? {
        let standardized = ProjectFolderStore.standardize(documentPath)
        lock.lock()
        defer { lock.unlock() }
        guard enabled else { return nil }
        var best: Folder?
        for folder in folders.values where folder.relativePath(standardized).map({ !$0.isEmpty }) ?? false {
            if best == nil || folder.path.count > best!.path.count { best = folder }
        }
        return best?.path
    }

    private func withDatabase<T>(_ folderPath: String, _ body: (IndexDatabase, Folder) throws -> T) -> T? {
        lock.lock()
        let folder = enabled ? folders[ProjectFolderStore.standardize(folderPath)] : nil
        lock.unlock()
        guard let folder else { return nil }
        folder.databaseLock.lock()
        defer { folder.databaseLock.unlock() }
        guard let database = folder.database, database.isOpen else { return nil }
        return try? body(database, folder)
    }

    private func symbol(_ row: IndexDatabase.SymbolRow, folder: Folder) -> WorkspaceSymbol {
        WorkspaceSymbol(folder: folder.path, relativePath: row.path, languageIdentifier: row.language,
                        name: row.name, kind: DeclarationScan.DeclarationKind(rawValue: UInt8(clamping: row.kind)) ?? .variable,
                        container: row.container, location: row.location, line: row.line, signature: row.signature)
    }

    /// Symbols in `folder` whose name starts with `prefix` (case-insensitive;
    /// exact-case matches are not separated — rank with `CandidateMatcher`),
    /// excluding the file at `excludingFile` (absolute path), ordered by name.
    public func names(withPrefix prefix: String, inFolder folder: String, excludingFile: String? = nil,
                      limit: Int = 200) -> [WorkspaceSymbol] {
        withDatabase(folder) { database, owner in
            let excluded = excludingFile.flatMap { owner.relativePath(ProjectFolderStore.standardize($0)) }
            return try database.symbols(foldedPrefix: IndexDatabase.folded(prefix), excludingPath: excluded, limit: limit)
                .map { symbol($0, folder: owner) }
        } ?? []
    }

    /// Symbols named exactly `name` in `folder`.
    public func symbols(named name: String, inFolder folder: String, limit: Int = 100) -> [WorkspaceSymbol] {
        withDatabase(folder) { database, owner in
            try database.symbols(named: name, limit: limit).map { symbol($0, folder: owner) }
        } ?? []
    }

    /// Every indexed symbol of one file (absolute path), in document order.
    public func symbols(inFile path: String) -> [WorkspaceSymbol] {
        let standardized = ProjectFolderStore.standardize(path)
        guard let folderPath = projectFolder(containing: standardized) else { return [] }
        return withDatabase(folderPath) { database, owner in
            guard let relative = owner.relativePath(standardized) else { return [] }
            return try database.symbols(inFile: relative).map { symbol($0, folder: owner) }
        } ?? []
    }

    /// Workspace-symbol search: the completion matcher's tiers (exact prefix,
    /// case-insensitive prefix, word start, fuzzy) over every symbol of
    /// `folder` (nil = all folders), best first, at most `limit`. At most
    /// `scanLimit` prefiltered rows are examined per folder.
    public func searchSymbols(_ query: String, inFolder folder: String? = nil, limit: Int = 100,
                              scanLimit: Int = 50_000) -> [WorkspaceSymbolMatch] {
        guard !query.isEmpty else { return [] }
        let matcher = CandidateMatcher(query)
        lock.lock()
        let targets = folder.map { [ProjectFolderStore.standardize($0)] } ?? Array(folders.keys)
        lock.unlock()
        var matches: [WorkspaceSymbolMatch] = []
        for target in targets {
            _ = withDatabase(target) { database, owner in
                var examined = 0
                try database.forEachSymbol(subsequence: matcher.folded) { row in
                    examined += 1
                    if let match = matcher.match(row.name, allowFuzzy: true) {
                        matches.append(WorkspaceSymbolMatch(symbol: symbol(row, folder: owner), tier: match.tier,
                                                            ranges: match.ranges))
                    }
                    return examined < scanLimit
                }
            }
        }
        matches.sort {
            ($0.tier, $0.symbol.name.utf16.count, $0.symbol.name, $0.symbol.relativePath, $0.symbol.location)
                < ($1.tier, $1.symbol.name.utf16.count, $1.symbol.name, $1.symbol.relativePath, $1.symbol.location)
        }
        return Array(matches.prefix(limit))
    }

    // MARK: - Test support

    /// Blocks until the queue has drained all pending work (tests and
    /// benchmarks; never call on the main thread in the app).
    func waitUntilIdle(timeout: TimeInterval = 60) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            queue.sync {}
            if isIdle {
                queue.sync {}
                if isIdle { return true }
            }
            usleep(2_000)
        }
        return false
    }

    /// Whether `path`'s FSEvents stream is running and its database open.
    func isRunning(_ path: String) -> (stream: Bool, database: Bool) {
        lock.lock()
        let folder = folders[ProjectFolderStore.standardize(path)]
        let stream = folder?.watcher?.isRunning ?? false
        lock.unlock()
        guard let folder else { return (false, false) }
        folder.databaseLock.lock()
        defer { folder.databaseLock.unlock() }
        return (stream, folder.database?.isOpen ?? false)
    }

    var writeCount: Int {
        lock.lock(); defer { lock.unlock() }
        return writes
    }

    func databaseURL(forFolder path: String) -> URL {
        IndexDatabase.fileURL(forFolder: ProjectFolderStore.standardize(path), root: root)
    }
}
