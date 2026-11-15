import Foundation

// M17 T17.14 — cross-file types of the static languages (plan §8.1, §10
// "使用者：跨文件类型的成员"): when a receiver's type is not declared in the
// document, the project-folder index names the files that declare it (or
// extend it: `impl` blocks, Go methods, Swift extension members are filed
// under the type's name), those files are read and summarised per type name
// (`BraceForeignPart`, see BraceForeign.swift), and the document's
// inference merges them (`BraceForeignResolver`).
//
// **Threading** (the T17.13 pattern): lookups run on one serial, utility-QoS
// queue of their own (`queue`); only finished summaries hop to the main
// thread (an inbox drained by one `DispatchQueue.main.async`), where they
// are merged into a byte-capped LRU. While a name is loading the resolver
// answers unknown; on arrival `didUpdateNotification` is posted and a
// completion popup still at the same caret / version / edit count refreshes
// (`CompletionController`), otherwise the next keystroke uses it.
//
// **Bounds**: at most `filesPerName` files (≤ 2 MB each) are read per type
// name; summaries only (members with written types and signature summaries,
// bases), the LRU holds at most `byteLimit` bytes.
//
// **Invalidation**: the index's FSEvents stream
// (`WorkspaceIndex.addFileChangeListener`) drops every entry of a changed
// file's folder (a saved file can add, remove or change any type's parts).
//
// **Module toggles**: `crossFileIndex`, `typeInference` or `completion`
// off releases everything; with the index off no document has a project
// folder (`WorkspaceIndex.projectFolder` answers nil), so nothing is asked.
@MainActor
public final class CrossFileTypeService {
    public static let didUpdateNotification = Notification.Name("KaruCrossFileTypesDidUpdate")

    /// The app's service (wired by `EditorWindowController`).
    public static let shared = CrossFileTypeService()

    /// LRU budget of the summaries (counted with the import summaries'
    /// share of plan §11 item ③).
    public nonisolated static let byteLimit = 2 * 1024 * 1024
    /// Files read per type name at most.
    nonisolated static let filesPerName = 16
    nonisolated static let maxFileBytes = IndexScope.defaultMaxFileBytes

    public struct Configuration {
        public var workspace: WorkspaceIndex
        public var fileSystem: ImportFileSystem
        public var moduleSettings: ModuleSettings?
        public var center: NotificationCenter
        public var byteLimit: Int

        public init(workspace: WorkspaceIndex, fileSystem: ImportFileSystem = SystemImportFileSystem(),
                    moduleSettings: ModuleSettings? = nil, center: NotificationCenter = .default,
                    byteLimit: Int = CrossFileTypeService.byteLimit) {
            self.workspace = workspace
            self.fileSystem = fileSystem
            self.moduleSettings = moduleSettings
            self.center = center
            self.byteLimit = byteLimit
        }

        public static var app: Configuration {
            Configuration(workspace: .shared, moduleSettings: ModuleSettings())
        }
    }

    public struct Statistics: Equatable {
        public var jobs = 0
        public var names = 0
        public var filesRead = 0
        /// Queue time of the last job (reading, scanning, summarising).
        public var lastJobMilliseconds = 0.0
    }

    let configuration: Configuration
    var center: NotificationCenter { configuration.center }
    let queue = DispatchQueue(label: "dev.enkin.Karu.crossfile", qos: .utility, autoreleaseFrequency: .workItem)
    private let worker: CrossFileWorker
    private let inbox = CrossFileInbox()

    private struct Entry {
        let folder: String
        let parts: [BraceForeignPart]
    }
    private let cache: ByteLRU<String, Entry>
    /// Keys being loaded, keys known to have no parts (with their folder).
    private var loading = Set<String>()
    private var missing: [String: String] = [:]
    private var pending: [CrossFileRequest] = []
    private var listenerToken: UUID?
    private var observer: NSObjectProtocol?

    /// Bumped whenever answers change (arrive, are invalidated, released).
    public private(set) var generation: UInt64 = 0
    public private(set) var statistics = Statistics()

    public init(configuration: Configuration? = nil) {
        let config = configuration ?? .app
        self.configuration = config
        cache = ByteLRU(byteLimit: config.byteLimit, countLimit: 2_048)
        worker = CrossFileWorker(workspace: config.workspace, fs: config.fileSystem)
        observer = config.center.addObserver(forName: ModuleSettings.didChangeNotification, object: nil, queue: nil) {
            [weak self] note in
            guard let raw = note.object as? String,
                  raw == FeatureModule.crossFileIndex.rawValue || raw == FeatureModule.typeInference.rawValue
                    || raw == FeatureModule.completion.rawValue else { return }
            let release: @MainActor () -> Void = {
                guard let self, let settings = self.configuration.moduleSettings,
                      let module = FeatureModule(rawValue: raw), !settings.isEnabled(module) else { return }
                self.release()
            }
            if Thread.isMainThread { MainActor.assumeIsolated(release) } else {
                DispatchQueue.main.async { MainActor.assumeIsolated(release) }
            }
        }
    }

    deinit {
        if let observer { configuration.center.removeObserver(observer) }
        if let token = listenerToken { configuration.workspace.removeFileChangeListener(token) }
    }

    /// Nothing held: no summaries, states or queued work.
    public var isReleased: Bool {
        cache.isEmpty && loading.isEmpty && missing.isEmpty && pending.isEmpty && listenerToken == nil
    }

    /// Approximate bytes of the cached summaries.
    public var retainedBytes: Int { cache.bytes }

    /// Drops every summary and state (module toggles).
    public func release() {
        cache.removeAll()
        loading.removeAll()
        missing.removeAll()
        pending.removeAll()
        _ = inbox.drain()
        if let token = listenerToken {
            configuration.workspace.removeFileChangeListener(token)
            listenerToken = nil
        }
        generation &+= 1
    }

    /// The project folder of a document path (nil: none, or the index off).
    func projectFolder(containing path: String) -> String? {
        configuration.workspace.projectFolder(containing: path)
    }

    private static func key(folder: String, language: BraceLanguage, name: String) -> String {
        folder + "\u{0}" + language.familyIdentifiers.joined(separator: ",") + "\u{0}" + language.identifier
            + "\u{0}" + name
    }

    /// The parts other files of `folder` declare for type `name`; schedules
    /// a load when unknown (send it with `flush()`).
    func lookup(name: String, folder: String, language: BraceLanguage) -> BraceForeignResolver.Lookup {
        let key = Self.key(folder: folder, language: language, name: name)
        if let entry = cache.value(for: key) { return .found(entry.parts) }
        if missing[key] != nil { return .missing }
        if loading.contains(key) { return .loading }
        loading.insert(key)
        pending.append(CrossFileRequest(key: key, folder: folder, name: name, language: language))
        watchFolders()
        return .loading
    }

    /// A resolver for one request of a document at `path` (nil outside a
    /// project folder or with the index off).
    func resolver(documentPath path: String?, language: BraceLanguage, text: NSString,
                  context: BraceFileContext? = nil) -> BraceForeignResolver? {
        guard let path, let folder = projectFolder(containing: path) else { return nil }
        let standardized = ProjectFolderStore.standardize(path)
        guard standardized.hasPrefix(folder + "/") else { return nil }
        let relative = String(standardized.dropFirst(folder.count + 1))
        return BraceForeignResolver(language: language, documentPath: relative,
                                    context: context ?? BraceFileContext.parse(text, language: language)) {
            [weak self] name in
            guard let self else { return .missing }
            return MainActor.assumeIsolated { self.lookup(name: name, folder: folder, language: language) }
        }
    }

    /// Sends the scheduled lookups to the queue.
    func flush() {
        guard !pending.isEmpty else { return }
        let requests = pending
        pending.removeAll()
        statistics.jobs += 1
        let worker = self.worker
        let inbox = self.inbox
        queue.async { [weak self] in
            let start = DispatchTime.now().uptimeNanoseconds
            let results = requests.map { worker.run($0) }
            inbox.add(results, nanoseconds: DispatchTime.now().uptimeNanoseconds &- start)
            DispatchQueue.main.async { MainActor.assumeIsolated { _ = self?.applyInbox() } }
        }
    }

    /// Merges finished lookups and file events (main thread).
    @discardableResult
    func applyInbox() -> Bool {
        let (results, changes, nanoseconds) = inbox.drain()
        guard !results.isEmpty || !changes.isEmpty else { return false }
        var changed = false
        if !changes.isEmpty {
            // A file of a folder changed: every answer of that folder may.
            let folders = Set(changes)
            let before = cache.count + missing.count
            cache.removeAll { key in folders.contains { key.hasPrefix($0 + "\u{0}") } }
            missing = missing.filter { !folders.contains($0.value) }
            if cache.count + missing.count != before { changed = true }
        }
        for result in results where loading.remove(result.key) != nil {
            statistics.names += 1
            statistics.filesRead += result.filesRead
            if result.parts.isEmpty {
                missing[result.key] = result.folder
            } else {
                cache.insert(Entry(folder: result.folder, parts: result.parts), for: result.key,
                             cost: 96 + result.key.utf8.count + result.parts.reduce(0) { $0 + $1.approximateBytes })
            }
            changed = true
        }
        if nanoseconds > 0 { statistics.lastJobMilliseconds = Double(nanoseconds) / 1e6 }
        if changed {
            generation &+= 1
            configuration.center.post(name: Self.didUpdateNotification, object: self)
        }
        return changed
    }

    /// File events of the index's project folders invalidate their answers.
    private func watchFolders() {
        guard listenerToken == nil else { return }
        let inbox = self.inbox
        let workspace = configuration.workspace
        listenerToken = workspace.addFileChangeListener { [weak self] paths in
            let folders = Set(paths.compactMap { workspace.projectFolder(containing: $0 + "/x") })
            guard !folders.isEmpty else { return }
            inbox.add(changes: Array(folders))
            DispatchQueue.main.async { MainActor.assumeIsolated { _ = self?.applyInbox() } }
        }
    }

    // MARK: - Tests

    /// Sends pending work, waits for the queue and merges the results
    /// (tests and benchmarks; never on the main thread in the app).
    @discardableResult
    func waitForTypes() -> Bool {
        flush()
        queue.sync {}
        return applyInbox()
    }

    var hasPendingWork: Bool { !loading.isEmpty || !pending.isEmpty }
    var cachedNameCount: Int { cache.count }
}

// MARK: - Queue side

struct CrossFileRequest: Sendable {
    let key: String
    let folder: String
    let name: String
    let language: BraceLanguage
}

struct CrossFileResult: Sendable {
    let key: String
    let folder: String
    let parts: [BraceForeignPart]
    let filesRead: Int
}

/// Finished lookups and file events waiting for the main thread.
final class CrossFileInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [CrossFileResult] = []
    private var changes: [String] = []
    private var nanoseconds: UInt64 = 0

    func add(_ batch: [CrossFileResult], nanoseconds: UInt64) {
        lock.lock(); results += batch; self.nanoseconds = nanoseconds; lock.unlock()
    }

    func add(changes folders: [String]) {
        lock.lock(); changes += folders; lock.unlock()
    }

    func drain() -> ([CrossFileResult], [String], UInt64) {
        lock.lock(); defer { lock.unlock() }
        let out = (results, changes, nanoseconds)
        results = []
        changes = []
        nanoseconds = 0
        return out
    }
}

/// Reads and summarises the files declaring one type name. Confined to
/// `CrossFileTypeService.queue`.
final class CrossFileWorker: @unchecked Sendable {
    let workspace: WorkspaceIndex
    let fs: ImportFileSystem

    init(workspace: WorkspaceIndex, fs: ImportFileSystem) {
        self.workspace = workspace
        self.fs = fs
    }

    func run(_ request: CrossFileRequest) -> CrossFileResult {
        let family = Set(request.language.familyIdentifiers)
        // Declarations of the name, and members filed under it (`impl`
        // blocks, Go methods, extension members).
        var paths: [String] = []
        var seen = Set<String>()
        let declared = workspace.symbols(named: request.name, inFolder: request.folder, limit: 64)
            .filter { ($0.kind == .class || $0.kind == .type) && family.contains($0.languageIdentifier) }
        let members = workspace.symbols(container: request.name, inFolder: request.folder, limit: 256)
            .filter { family.contains($0.languageIdentifier) }
        for symbol in declared + members where seen.insert(symbol.relativePath).inserted {
            paths.append(symbol.relativePath)
        }
        var parts: [BraceForeignPart] = []
        var read = 0
        for relative in paths.prefix(CrossFileTypeService.filesPerName) {
            let absolute = (request.folder as NSString).appendingPathComponent(relative)
            guard let info = fs.info(absolute), !info.isDirectory, info.size <= CrossFileTypeService.maxFileBytes,
                  let data = fs.contents(absolute) else { continue }
            read += 1
            let text = WorkspaceIndex.decodedText(data) as NSString
            parts += Self.parts(named: request.name, in: text, path: relative, language: request.language)
        }
        return CrossFileResult(key: request.key, folder: request.folder, parts: parts, filesRead: read)
    }

    /// The parts `text` (the file at `path`, relative) declares for `name`,
    /// read as `language` (a C++ document reads `.h` headers as C++).
    static func parts(named name: String, in text: NSString, path: String,
                      language: BraceLanguage) -> [BraceForeignPart] {
        let scan = DeclarationScan.scan(text: text as String, languageIdentifier: language.identifier)
        let index = DeclarationQueryIndex(scan: scan)
        let file = BraceStaticFile(text: text, language: language, identifier: language.identifier)
        let view = BraceModuleView(language: language, version: 0, index: index, journal: EditJournal(), reader: file.reader)
        view.budget = InferenceBudget(maxSteps: 4_000_000, milliseconds: 1_000)
        let directory = (path as NSString).deletingLastPathComponent
        let namespace = BraceFileNamespace.of(text: text, path: path, language: language)
        return view.foreignParts(named: name, path: path, directory: directory).map { part in
            var copy = part
            copy.namespaces = namespace + part.namespaces
            return copy
        }
    }
}
