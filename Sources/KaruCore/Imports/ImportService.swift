import Foundation

// M17 T17.13 — import resolution (plan §9): which file an import names, its
// export summary, and when that summary is stale. Nothing here executes a
// program; files are only read.
//
// **Threading.** All lookup, reading and parsing runs on one serial,
// utility-QoS queue of its own (`queue`, a sibling of `WorkspaceIndex`'s
// indexing queue: a long index walk never delays an import, and an import
// never holds up indexing). Only finished summaries hop to the main thread
// (an inbox drained by one `DispatchQueue.main.async`), where they are
// merged into the LRU and the overlay the evaluators read. While a summary
// is pending the evaluator answers with what it already knows (unknown →
// usage evidence); when it arrives, `didUpdateNotification` is posted and a
// completion popup still at the same caret / version refreshes
// (`CompletionController`), otherwise the next keystroke uses it.
//
// **Module keys.** An imported module is an overlay module of the type
// tables: Python `§<context>:<dotted.name>`, JS / TS `§<context>:<file path>`.
// A context is a project folder (or none) with the Run-selected
// interpreter; context ids are unique per process, so two services never
// collide in the shared tables' caches. Standard-library Python names keep
// their plain names and resolve to the built-in typeshed tables first — no
// disk access at all.
//
// **No project folder** (an unsaved buffer, a file outside every project
// folder): only the built-in stubs and path ③ (the interpreter's own
// stdlib / site-packages); the document's directory is never read (T17.0:
// that triggers a privacy prompt). JS / TS imports then stay unknown.
//
// **Invalidation.** Project files: the project folder's FSEvents stream
// (`WorkspaceIndex.addFileChangeListener`) drops a changed file's summary
// and every "not found" answer of that folder. site-packages / node_modules
// / interpreter files: no resident watcher — a summary in use is
// revalidated against the recorded mtimes (file, package directory,
// site-packages / node_modules directory) at most every
// `revalidationInterval` seconds, on the queue.
//
// **Module toggles.** `typeInference` off (or completion off, which drops
// all inference state) releases everything: summaries, states, contexts,
// the worker's caches. `crossFileIndex` off releases everything too, and
// afterwards documents resolve as if outside every project folder (project
// folders are only known while the index is on): stdlib stubs and path ③
// keep working, ① / ② and JS / TS packages do not.
@MainActor
public final class ImportService {
    public static let didUpdateNotification = Notification.Name("KaruImportServiceDidUpdate")

    /// The app's service (wired by `EditorWindowController`).
    public static let shared = ImportService()

    /// App-wide summary budget (plan §11 item ③).
    public nonisolated static let summaryByteLimit = 8 * 1024 * 1024
    /// A single module over this keeps only its names (a quarter of the
    /// budget: the TypeScript compiler's 9 k-line declaration file fits).
    public nonisolated static let moduleByteLimit = 2 * 1024 * 1024
    /// Source files over this are summarised as names only (plan §9).
    public nonisolated static let namesOnlySourceBytes = 2 * 1024 * 1024
    /// Re-export / dependency chains loaded with a module, and followed by
    /// lookups through imported modules (plan §9: `__init__` re-exports ≤ 3).
    nonisolated static let reexportDepth = 3
    /// Modules one job reads at most (the rest load on demand).
    nonisolated static let modulesPerJob = 48

    public struct Configuration {
        public var fileSystem: ImportFileSystem
        /// The project folder containing a document path (nil: none).
        public var projectFolder: @MainActor (String) -> String?
        /// The Run-selected interpreter (read when a context is created).
        public var interpreter: @MainActor () -> PythonInterpreterDiscovery
        /// A top-level module name of the built-in standard-library table.
        public var isStdlib: @Sendable (String) -> Bool
        public var revalidationInterval: TimeInterval
        public var moduleSettings: ModuleSettings?
        public var center: NotificationCenter
        /// FSEvents source for project files (nil: none).
        public var workspace: WorkspaceIndex?
        public var byteLimit: Int
        public var moduleByteLimit: Int

        public init(fileSystem: ImportFileSystem = SystemImportFileSystem(),
                    projectFolder: @escaping @MainActor (String) -> String?,
                    interpreter: @escaping @MainActor () -> PythonInterpreterDiscovery,
                    isStdlib: @escaping @Sendable (String) -> Bool = { TypeTableStore.shared.hasPythonModule($0) },
                    revalidationInterval: TimeInterval = 2, moduleSettings: ModuleSettings? = nil,
                    center: NotificationCenter = .default, workspace: WorkspaceIndex? = nil,
                    byteLimit: Int = ImportService.summaryByteLimit,
                    moduleByteLimit: Int = ImportService.moduleByteLimit) {
            self.fileSystem = fileSystem
            self.projectFolder = projectFolder
            self.interpreter = interpreter
            self.isStdlib = isStdlib
            self.revalidationInterval = revalidationInterval
            self.moduleSettings = moduleSettings
            self.center = center
            self.workspace = workspace
            self.byteLimit = byteLimit
            self.moduleByteLimit = moduleByteLimit
        }

        /// The app's: `WorkspaceIndex.shared`, Run settings, the real disk.
        public static var app: Configuration {
            Configuration(projectFolder: { WorkspaceIndex.shared.projectFolder(containing: $0) },
                          interpreter: { PythonInterpreterDiscovery.runSelected() },
                          moduleSettings: ModuleSettings(), workspace: .shared)
        }
    }

    public struct Statistics: Equatable {
        public var jobs = 0
        public var loadedModules = 0
        public var missingModules = 0
        public var invalidations = 0
        public var revalidations = 0
        public var generation: UInt64 = 0
    }

    // MARK: State

    let configuration: Configuration
    let cache: ImportSummaryCache
    let queue = DispatchQueue(label: "dev.enkin.Karu.imports", qos: .utility, autoreleaseFrequency: .workItem)
    private let worker: ImportWorker
    private let inbox = ImportInbox()

    enum State { case loading, missing }
    /// Module keys being loaded or known missing (loaded ones are in `cache`).
    private var states: [String: State] = [:]
    /// JS / TS `importer \0 specifier` → module key (nil: not found / pending).
    private var specifiers: [String: SpecifierState] = [:]
    enum SpecifierState: Equatable { case loading, resolved(String), missing }

    final class Context {
        let id: Int
        let prefix: String
        let projectRoot: String?
        let interpreter: PythonInterpreterDiscovery
        init(id: Int, projectRoot: String?, interpreter: PythonInterpreterDiscovery) {
            self.id = id
            self.prefix = "§\(id):"
            self.projectRoot = projectRoot
            self.interpreter = interpreter
        }
        var snapshot: ImportContextSnapshot {
            ImportContextSnapshot(id: id, prefix: prefix, projectRoot: projectRoot, interpreter: interpreter)
        }
    }
    private var contexts: [String: Context] = [:]
    private var contextsByID: [Int: Context] = [:]
    private static var nextContextID = 1

    private var pending: [ImportJobItem] = []
    private var pendingRevalidation = Set<String>()
    private var lastValidated: [String: TimeInterval] = [:]
    /// What a "not found" answer outside the project folder depends on
    /// (site-packages directories' mtimes): revalidated like summaries.
    private var missingValidators: [String: [String: Double]] = [:]
    /// Project modules dropped by a file event whose re-read is on its way.
    private var awaitingRefresh = Set<String>()
    /// When the queue finished reading each loaded module (diagnostics, tests).
    private(set) var loadedAt: [String: TimeInterval] = [:]
    private var listenerToken: UUID?
    private var observers: [NSObjectProtocol] = []
    private var tables: [WeakTables] = []
    private struct WeakTables {
        weak var python: PythonTypeTables?
        weak var script: ScriptTypeTables?
    }

    /// Bumped whenever summaries change (arrive, are invalidated, released).
    public private(set) var generation: UInt64 = 0
    /// Loads scheduled so far (a request that scheduled one is pending).
    private(set) var requestCount = 0
    public private(set) var statistics = Statistics()

    public init(configuration: Configuration? = nil) {
        let config = configuration ?? .app
        self.configuration = config
        cache = ImportSummaryCache(byteLimit: config.byteLimit, moduleByteLimit: config.moduleByteLimit)
        worker = ImportWorker(fs: config.fileSystem, isStdlib: config.isStdlib)
        observers.append(config.center.addObserver(forName: ModuleSettings.didChangeNotification, object: nil,
                                                    queue: nil) { [weak self] note in
            guard let raw = note.object as? String,
                  raw == FeatureModule.typeInference.rawValue || raw == FeatureModule.crossFileIndex.rawValue
                    || raw == FeatureModule.completion.rawValue else { return }
            Self.onMain {
                guard let self, let settings = self.configuration.moduleSettings,
                      let module = FeatureModule(rawValue: raw), !settings.isEnabled(module) else { return }
                self.release()
            }
        })
        observers.append(config.center.addObserver(forName: RunSettings.didChangeNotification, object: nil,
                                                   queue: nil) { [weak self] note in
            guard note.object as? String == RunnableLanguage.python.rawValue else { return }
            Self.onMain { self?.release() }
        })
    }

    /// Runs `body` on the main actor: at once when posted on the main
    /// thread (module toggles release synchronously), else on the next turn.
    private nonisolated static func onMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated(body) }
        }
    }

    deinit {
        for o in observers { configuration.center.removeObserver(o) }
        if let token = listenerToken { configuration.workspace?.removeFileChangeListener(token) }
    }

    /// Nothing held: no summaries, states, contexts or queued work.
    public var isReleased: Bool {
        cache.isEmpty && states.isEmpty && specifiers.isEmpty && contexts.isEmpty && pending.isEmpty
            && listenerToken == nil
    }

    /// Approximate bytes of the cached summaries.
    public var retainedBytes: Int { cache.bytes }

    /// Drops every summary, state and context (module toggles; plan §11).
    public func release() {
        cache.removeAll()
        states.removeAll()
        specifiers.removeAll()
        contexts.removeAll()
        contextsByID.removeAll()
        pending.removeAll()
        pendingRevalidation.removeAll()
        lastValidated.removeAll()
        missingValidators.removeAll()
        awaitingRefresh.removeAll()
        loadedAt.removeAll()
        _ = inbox.drain()
        inbox.unwatchAll()
        if let token = listenerToken {
            configuration.workspace?.removeFileChangeListener(token)
            listenerToken = nil
        }
        let worker = self.worker
        queue.async { worker.reset() }
        bump()
    }

    /// The type tables whose derived caches mention imported modules
    /// (dropped whenever summaries change).
    func register(python: PythonTypeTables, script: ScriptTypeTables) {
        tables.removeAll { $0.python == nil && $0.script == nil }
        if !tables.contains(where: { $0.python === python && $0.script === script }) {
            tables.append(WeakTables(python: python, script: script))
        }
        python.importSource = self
        script.importSource = self
    }

    private func bump() {
        generation &+= 1
        statistics.generation = generation
        for t in tables {
            t.python?.dropImported()
            t.script?.dropImported()
        }
    }

    // MARK: - Scopes

    /// The import scope of a document (`path` nil: unsaved).
    func scope(forDocument path: String?) -> ImportScope {
        let root = path.flatMap { configuration.projectFolder($0) }
        let key = root ?? ""
        let context: Context
        if let existing = contexts[key] {
            context = existing
        } else {
            context = Context(id: Self.nextContextID, projectRoot: root, interpreter: configuration.interpreter())
            Self.nextContextID += 1
            contexts[key] = context
            contextsByID[context.id] = context
        }
        if root != nil, listenerToken == nil, let workspace = configuration.workspace {
            let inbox = self.inbox, worker = self.worker, queue = self.queue
            listenerToken = workspace.addFileChangeListener { [weak self] paths in
                // The changed summaries are re-read on the queue right away;
                // the main thread merges them whenever it next runs.
                inbox.add(changes: paths)
                let items = inbox.items(for: paths)
                guard !items.isEmpty else {
                    DispatchQueue.main.async { MainActor.assumeIsolated { _ = self?.applyInbox() } }
                    return
                }
                queue.async {
                    var result = worker.run(ImportJob(items: items, known: []))
                    result.refresh = true
                    inbox.add(result)
                    DispatchQueue.main.async { MainActor.assumeIsolated { _ = self?.applyInbox() } }
                }
            }
        }
        return ImportScope(service: self, context: context,
                           documentPath: root.flatMap { root in path.map { Self.path($0, spelledUnder: root) } })
    }

    /// `path` spelled under `root`, the project folder's stored form (T17.15c).
    /// The workspace index matches a document through `standardizingPath` and
    /// the folder's resolved path, so a document at `/private/tmp/p/a.js`
    /// (how AppKit spells an opened file) belongs to the folder `/tmp/p`, and
    /// a symlinked folder's documents to it; import paths are compared as
    /// strings, so the document path takes the root's spelling. Unchanged
    /// when no spelling of it is inside `root`.
    static func path(_ path: String, spelledUnder root: String) -> String {
        if ImportPath.isInside(path, root) { return path }
        let standardized = ProjectFolderStore.standardize(path)
        if ImportPath.isInside(standardized, root) { return standardized }
        let realRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        let realPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard ImportPath.isInside(realPath, realRoot) else { return path }
        return root + realPath.dropFirst(realRoot.count)
    }

    func isStdlib(_ top: String) -> Bool { configuration.isStdlib(top) }

    // MARK: - Overlay lookups (evaluators, main thread)

    /// The Python summary of `key`; schedules a load when not known.
    /// `speculative`: a submodule probe (`pkg.name`), loaded only when the
    /// parent is a loaded package.
    func pythonModule(_ key: String, speculative: Bool = false) -> PythonModuleSummary? {
        if let module = cache.module(key) {
            noteUse(key, module)
            if case .python(let p) = module.content { return p }
            return nil
        }
        if let state = states[key] {
            if state == .missing { noteMissing(key) }
            return nil
        }
        if speculative {
            guard let dot = key.lastIndex(of: "."), let parent = cache.peek(String(key[..<dot])),
                  case .python(let p) = parent.content, p.stub.isPackage else { return nil }
        }
        requestPython(key, names: [])
        return nil
    }

    /// The JS / TS summary of `key`; schedules a load when not known.
    func scriptModule(_ key: String) -> ScriptModuleSummary? {
        if let module = cache.module(key) {
            noteUse(key, module)
            if case .script(let s) = module.content { return s }
            return nil
        }
        if states[key] == nil { requestScript(key) }
        return nil
    }

    /// Whether `key` is loaded (no scheduling, no recency).
    func isLoaded(_ key: String) -> Bool { cache.contains(key) }

    func state(_ key: String) -> State? {
        if states[key] == .missing { noteMissing(key) }
        return states[key]
    }

    /// A "not found" answer in use: recheck its site-packages mtimes now and
    /// then (a package installed later is found without a watcher).
    private func noteMissing(_ key: String) {
        guard missingValidators[key]?.isEmpty == false else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastValidated[key], now - last < configuration.revalidationInterval { return }
        lastValidated[key] = now
        pendingRevalidation.insert(key)
    }

    private func noteUse(_ key: String, _ module: ImportedModule) {
        guard !module.isProjectFile else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastValidated[key], now - last < configuration.revalidationInterval { return }
        lastValidated[key] = now
        pendingRevalidation.insert(key)
    }

    // MARK: - Requests

    func requestPython(_ key: String, names: [String]) {
        guard states[key] == nil, !cache.contains(key), let (context, dotted) = parse(key) else { return }
        // `import a.b.c` loads `a` and `a.b` with it.
        let parts = dotted.split(separator: ".")
        for k in 1..<max(1, parts.count) {
            let parent = context.prefix + parts[0..<k].joined(separator: ".")
            if states[parent] == nil, !cache.contains(parent) {
                states[parent] = .loading
                pending.append(.python(key: parent, context: context.snapshot, dotted: String(parent.dropFirst(context.prefix.count)),
                                       names: [], depth: 0))
            }
        }
        states[key] = .loading
        requestCount += 1
        pending.append(.python(key: key, context: context.snapshot, dotted: dotted, names: names, depth: 0))
    }

    func requestScript(_ key: String) {
        guard states[key] == nil, !cache.contains(key), let (context, path) = parse(key) else { return }
        states[key] = .loading
        requestCount += 1
        pending.append(.script(key: key, context: context.snapshot, path: path, depth: 0))
    }

    func requestSpecifier(_ specifier: String, importer: String, context: Context) -> SpecifierState {
        let id = importer + "\u{0}" + specifier
        if let state = specifiers[id] { return state }
        specifiers[id] = .loading
        requestCount += 1
        pending.append(.specifier(id: id, context: context.snapshot, importer: importer, specifier: specifier))
        return .loading
    }

    private func parse(_ key: String) -> (Context, String)? {
        guard key.hasPrefix("§"), let colon = key.firstIndex(of: ":"),
              let id = Int(key[key.index(after: key.startIndex)..<colon]), let context = contextsByID[id] else { return nil }
        return (context, String(key[key.index(after: colon)...]))
    }

    /// Sends the requests and revalidations gathered so far to the queue.
    func flush() {
        guard !pending.isEmpty || !pendingRevalidation.isEmpty else { return }
        var job = ImportJob(items: pending, known: Set(cache.allKeys).union(states.keys))
        pending.removeAll()
        for key in pendingRevalidation {
            if let module = cache.peek(key) {
                job.revalidate.append((key, module.validators))
            } else if states[key] == .missing, let validators = missingValidators[key] {
                job.revalidate.append((key, validators))
            }
        }
        pendingRevalidation.removeAll()
        statistics.jobs += 1
        let worker = self.worker
        let inbox = self.inbox
        queue.async { [weak self] in
            let result = worker.run(job)
            inbox.add(result)
            DispatchQueue.main.async { MainActor.assumeIsolated { _ = self?.applyInbox() } }
        }
    }

    /// Merges finished jobs and file events (main thread).
    @discardableResult
    func applyInbox() -> Bool {
        let (results, changes) = inbox.drain()
        guard !results.isEmpty || !changes.isEmpty else { return false }
        // `changed`: a pending request may now be answered differently;
        // `summaries`: summaries or resolutions changed (derived caches and
        // reused answers are stale). A "not found" changes neither.
        var changed = false
        var summaries = false
        cache.beginBatch()
        // File events first: a refresh in the same drain re-inserts what they drop.
        if !changes.isEmpty, filesChanged(changes) {
            changed = true
            summaries = true
        }
        for result in results {
            for (id, key) in result.specifiers {
                guard specifiers[id] != nil else { continue }   // released meanwhile
                specifiers[id] = key.map { .resolved($0) } ?? .missing
                changed = true
                // Resolving to a module (possibly cached already) changes answers.
                if key != nil { summaries = true }
            }
            for record in result.loaded {
                guard let (context, _) = parse(record.key), contextsByID[context.id] === context else { continue }
                // A refresh only replaces what a file event dropped (not what was evicted since).
                if result.refresh {
                    guard awaitingRefresh.remove(record.key) != nil || cache.contains(record.key) else { continue }
                }
                states[record.key] = nil
                cache.insert(record.module, for: record.key)
                watch(record.key, record.module, context)
                loadedAt[record.key] = result.finishedAt
                lastValidated[record.key] = ProcessInfo.processInfo.systemUptime
                statistics.loadedModules += 1
                changed = true
                summaries = true
            }
            for (key, validators) in result.missing where parse(key) != nil {
                states[key] = .missing
                missingValidators[key] = validators
                lastValidated[key] = ProcessInfo.processInfo.systemUptime
                statistics.missingModules += 1
                changed = true
            }
            statistics.revalidations += result.revalidated
            for key in result.invalidated {
                cache.remove(key)
                states[key] = nil
                missingValidators[key] = nil
                lastValidated[key] = nil
                statistics.invalidations += 1
                changed = true
                summaries = true
            }
        }
        if summaries { bump() }
        if changed { configuration.center.post(name: Self.didUpdateNotification, object: self) }
        return changed
    }

    /// Registers a project module's source for proactive re-reads on file events.
    private func watch(_ key: String, _ module: ImportedModule, _ context: Context) {
        guard module.isProjectFile, let source = module.sourcePath, context.projectRoot != nil else { return }
        let path = String(key.dropFirst(context.prefix.count))
        let item: ImportJobItem = path.hasPrefix("/")
            ? .script(key: key, context: context.snapshot, path: path, depth: Self.reexportDepth)
            : .python(key: key, context: context.snapshot, dotted: path, names: [], depth: Self.reexportDepth)
        inbox.watch(source, item)
    }

    /// FSEvents paths of project folders: drops their summaries and every
    /// "not found" answer (a new file may now resolve).
    private func filesChanged(_ paths: [String]) -> Bool {
        var changed = false
        let roots = contexts.values.compactMap { $0.projectRoot }
        let realRoots = roots.map { configuration.fileSystem.realPath($0) }
        let touched = paths.filter { p in
            zip(roots, realRoots).contains { ImportPath.isInside(p, $0.0) || ImportPath.isInside(p, $0.1) }
        }
        guard !touched.isEmpty else { return false }
        // A file event names the file; a rescan event names a directory.
        for key in cache.keys(where: { module in
            guard let source = module.sourcePath else { return false }
            return touched.contains { ImportPath.isInside(source, $0) }
        }) {
            cache.remove(key)
            awaitingRefresh.insert(key)
            lastValidated[key] = nil
            statistics.invalidations += 1
            changed = true
        }
        for (key, state) in states where state == .missing {
            states[key] = nil
            missingValidators[key] = nil
            changed = true
        }
        for (id, state) in specifiers where state != .loading {
            if case .resolved(let key) = state, cache.contains(key) { continue }
            specifiers[id] = nil
            changed = true
        }
        return changed
    }

    // MARK: - Tests

    /// Sends pending work, waits for the queue and merges the results
    /// (tests and benchmarks; never on the main thread in the app).
    @discardableResult
    func waitForImports(rounds: Int = 1) -> Bool {
        var changed = false
        for _ in 0..<rounds {
            flush()
            queue.sync {}
            if applyInbox() { changed = true }
        }
        return changed
    }

    /// Bytes / entries of the LRU (tests).
    var cacheForTesting: ImportSummaryCache { cache }
    var contextCount: Int { contexts.count }
}

// MARK: - Scope

/// One request's view of imports: a document's context (project folder,
/// interpreter) and position (for relative imports). Records whether a
/// lookup is still pending (the controller refreshes when it arrives).
@MainActor
final class ImportScope {
    unowned let service: ImportService
    let context: ImportService.Context
    /// The document's path when inside the project folder (nil otherwise:
    /// relative imports and JS / TS packages are unavailable).
    let documentPath: String?
    private(set) var hasPending = false
    /// The document's own module name in the project (Python relative imports).
    let pythonDocument: (dotted: String, isPackage: Bool)?

    init(service: ImportService, context: ImportService.Context, documentPath: String?) {
        self.service = service
        self.context = context
        self.documentPath = documentPath
        if let root = context.projectRoot, let path = documentPath, ImportPath.isInside(path, root) {
            var relative = String(path.dropFirst(root.count)).split(separator: "/").map(String.init)
            let file = relative.popLast() ?? ""
            let stem = (file as NSString).deletingPathExtension
            let isPackage = stem == "__init__"
            if !isPackage { relative.append(stem) }
            pythonDocument = relative.contains(where: { $0.contains(".") || $0.isEmpty }) ? nil
                : (relative.joined(separator: "."), isPackage)
        } else {
            pythonDocument = nil
        }
    }

    /// The overlay / table name of Python module `dotted` (`level` leading
    /// dots), nil while unknown. `names`: the names imported from it (a
    /// submodule check). Standard-library names never touch the disk.
    func python(_ dotted: String, level: Int = 0, names: [String] = []) -> String? {
        var absolute = dotted
        if level > 0 {
            guard let doc = pythonDocument,
                  let a = PythonModuleLocator.absolute(level: level, name: dotted, from: doc.dotted, isPackage: doc.isPackage),
                  !a.isEmpty else { return nil }
            absolute = a
        }
        guard let head = absolute.split(separator: ".").first.map(String.init), !head.isEmpty else { return nil }
        if level == 0, service.isStdlib(head) { return absolute }
        return pythonKey(absolute, names: names)
    }

    /// `from . import x` in a module at the project root: `x` is a
    /// top-level module.
    func relativeBaseIsRoot(level: Int) -> Bool {
        guard let doc = pythonDocument else { return false }
        return PythonModuleLocator.absolute(level: level, name: "", from: doc.dotted, isPackage: doc.isPackage) == ""
    }

    /// The overlay key of absolute module `absolute` of this context (no
    /// standard-library check), nil while loading or when missing.
    func pythonKey(_ absolute: String, names: [String] = []) -> String? {
        let key = context.prefix + absolute
        if service.isLoaded(key), let summary = service.pythonModule(key) {
            for name in names where !ImportWorker.defines(summary.stub, name) && !service.isLoaded(key + "." + name) {
                if service.pythonModule(key + "." + name, speculative: true) == nil,
                   service.state(key + "." + name) == .loading { hasPending = true }
            }
            return key
        }
        if service.state(key) != .missing {
            service.requestPython(key, names: names)
            hasPending = true
        }
        return nil
    }

    /// The overlay name of the JS / TS module `specifier`, nil while unknown.
    func script(_ specifier: String) -> String? {
        guard context.projectRoot != nil, let importer = documentPath else { return nil }
        switch service.requestSpecifier(specifier, importer: importer, context: context) {
        case .resolved(let key):
            if service.scriptModule(key) != nil { return key }
            if service.state(key) != .missing { hasPending = true }
            return nil
        case .loading:
            hasPending = true
            return nil
        case .missing:
            return nil
        }
    }

    /// A lookup of an imported module's own imports is still loading.
    func notePending() { hasPending = true }
}

// MARK: - Jobs

struct ImportContextSnapshot: Sendable {
    let id: Int
    let prefix: String
    let projectRoot: String?
    let interpreter: PythonInterpreterDiscovery
}

enum ImportJobItem: Sendable {
    case python(key: String, context: ImportContextSnapshot, dotted: String, names: [String], depth: Int)
    case script(key: String, context: ImportContextSnapshot, path: String, depth: Int)
    case specifier(id: String, context: ImportContextSnapshot, importer: String, specifier: String)
}

struct ImportJob: Sendable {
    var items: [ImportJobItem]
    /// Keys loaded, loading or known missing on the main thread.
    var known: Set<String>
    var revalidate: [(key: String, validators: [String: Double])] = []
}

struct ImportJobResult: Sendable {
    var loaded: [(key: String, module: ImportedModule)] = []
    /// Keys not found, with the site-packages mtimes the answer depends on.
    var missing: [(key: String, validators: [String: Double])] = []
    var specifiers: [(id: String, key: String?)] = []
    var invalidated: [String] = []
    var revalidated = 0
    /// A refresh after a project file changed (FSEvents), started on the
    /// event queue without waiting for the main thread.
    var refresh = false
    /// When the queue finished it (`systemUptime`).
    var finishedAt: TimeInterval = 0
}

/// Finished jobs and file events waiting for the main thread.
final class ImportInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [ImportJobResult] = []
    private var changes: [String] = []
    /// Project source file (realpath) → the job item that re-reads it.
    private var watched: [String: ImportJobItem] = [:]

    func watch(_ path: String, _ item: ImportJobItem?) {
        lock.lock(); watched[path] = item; lock.unlock()
    }

    func unwatchAll() {
        lock.lock(); watched.removeAll(); lock.unlock()
    }

    /// Items re-reading the watched files an event batch names.
    func items(for paths: [String]) -> [ImportJobItem] {
        lock.lock(); defer { lock.unlock() }
        guard !watched.isEmpty else { return [] }
        var out: [ImportJobItem] = []
        for (path, item) in watched where paths.contains(where: { ImportPath.isInside(path, $0) }) { out.append(item) }
        return out
    }

    func add(_ result: ImportJobResult) {
        lock.lock(); results.append(result); lock.unlock()
    }

    func add(changes paths: [String]) {
        lock.lock(); changes += paths; lock.unlock()
    }

    func drain() -> ([ImportJobResult], [String]) {
        lock.lock(); defer { lock.unlock() }
        let out = (results, changes)
        results = []
        changes = []
        return out
    }
}

/// The queue side: search paths per context, lookup, reading, summaries.
/// Confined to `ImportService.queue`.
final class ImportWorker: @unchecked Sendable {
    let fs: ImportFileSystem
    let isStdlib: @Sendable (String) -> Bool
    private var pythonPaths: [Int: PythonSearchPaths] = [:]

    init(fs: ImportFileSystem, isStdlib: @escaping @Sendable (String) -> Bool) {
        self.fs = fs
        self.isStdlib = isStdlib
    }

    func reset() { pythonPaths.removeAll() }

    func paths(_ context: ImportContextSnapshot) -> PythonSearchPaths {
        if let cached = pythonPaths[context.id],
           cached.validators.allSatisfy({ fs.info($0.key)?.modificationTime == $0.value }) {
            return cached
        }
        let derived = PythonSearchPaths.derive(projectRoot: context.projectRoot, interpreter: context.interpreter, fs: fs)
        pythonPaths[context.id] = derived
        return derived
    }

    func run(_ job: ImportJob) -> ImportJobResult {
        var result = ImportJobResult()
        var queue = job.items
        var done = Set<String>()
        var reads = 0
        while !queue.isEmpty {
            let item = queue.removeFirst()
            switch item {
            case .specifier(let id, let context, let importer, let specifier):
                guard let root = context.projectRoot,
                      let file = ScriptModuleLocator.resolve(specifier, from: importer, projectRoot: root, fs: fs) else {
                    result.specifiers.append((id, nil))
                    continue
                }
                let key = context.prefix + file
                result.specifiers.append((id, key))
                if !job.known.contains(key), !done.contains(key) {
                    queue.append(.script(key: key, context: context, path: file, depth: 0))
                }
            case .python(let key, let context, let dotted, let names, let depth):
                guard done.insert(key).inserted else { continue }
                guard reads < ImportService.modulesPerJob || depth == 0 else { continue }
                reads += 1
                guard let (module, summary) = loadPython(dotted, context: context) else {
                    result.missing.append((key, paths(context).validators))
                    continue
                }
                result.loaded.append((key, module))
                guard depth < ImportService.reexportDepth else { continue }
                var next: [(String, [String])] = summary.dependencies
                // `from pkg import name`: `name` may be a submodule.
                for name in names where !Self.defines(summary.stub, name) { next.append((dotted + "." + name, [])) }
                for (dep, depNames) in next {
                    let parts = dep.split(separator: ".")
                    for k in 1...parts.count {
                        let sub = parts[0..<k].joined(separator: ".")
                        let depKey = context.prefix + sub
                        guard !job.known.contains(depKey), !done.contains(depKey) else { continue }
                        queue.append(.python(key: depKey, context: context, dotted: sub,
                                             names: k == parts.count ? depNames : [], depth: depth + 1))
                    }
                }
            case .script(let key, let context, let path, let depth):
                guard done.insert(key).inserted else { continue }
                guard reads < ImportService.modulesPerJob || depth == 0 else { continue }
                reads += 1
                guard let module = loadScript(path, key: key, context: context) else {
                    result.missing.append((key, [:]))
                    continue
                }
                result.loaded.append((key, module))
                guard depth < ImportService.reexportDepth, case .script(let summary) = module.content else { continue }
                for dep in summary.dependencies where !job.known.contains(dep) && !done.contains(dep) {
                    queue.append(.script(key: dep, context: context, path: String(dep.dropFirst(context.prefix.count)),
                                         depth: depth + 1))
                }
            }
        }
        for (key, validators) in job.revalidate {
            result.revalidated += 1
            if validators.contains(where: { fs.info($0.key)?.modificationTime != $0.value }) { result.invalidated.append(key) }
        }
        result.finishedAt = ProcessInfo.processInfo.systemUptime
        return result
    }

    static func defines(_ stub: PythonModuleStub, _ name: String) -> Bool {
        stub.class(named: name) != nil || stub.function(named: name) != nil || stub.variable(named: name) != nil
            || stub.alias(named: name) != nil || stub.import(named: name) != nil
    }

    /// Text of a source file (UTF-8, Latin-1 fallback), and its size.
    private func read(_ path: String) -> (NSString, Int, Double)? {
        guard let info = fs.info(path), !info.isDirectory, let data = fs.contents(path) else { return nil }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return (text as NSString, info.size, info.modificationTime)
    }

    private func loadPython(_ dotted: String, context: ImportContextSnapshot) -> (ImportedModule, PythonModuleSummary)? {
        let paths = self.paths(context)
        guard let location = PythonModuleLocator.locate(dotted, in: paths, fs: fs) else { return nil }
        let summaryContext = PythonSummaryContext(dotted: dotted, isPackage: location.isPackage, isStub: location.isStub,
                                                  keyPrefix: context.prefix, isStdlib: isStdlib)
        var validators: [String: Double] = [:]
        if location.root.isSitePackages, let info = fs.info(location.root.path) { validators[location.root.path] = info.modificationTime }
        let summary: PythonModuleSummary
        var source: String?
        if let file = location.file {
            guard let (text, size, mtime) = read(file) else { return nil }
            validators[file] = mtime
            source = fs.realPath(file)
            summary = PythonModuleSummarizer.summarize(text, context: summaryContext,
                                                       namesOnly: size > ImportService.namesOnlySourceBytes)
        } else {
            summary = PythonModuleSummary(stub: PythonModuleStub(name: summaryContext.key, isPackage: true, all: nil, imports: [],
                                                                 starImports: [], typeVars: [], aliases: [], variables: [],
                                                                 functions: [], classes: []),
                                          kinds: nil, dependencies: [])
        }
        for dir in location.packageDirectories.prefix(1) {
            if let info = fs.info(dir) { validators[dir] = info.modificationTime }
        }
        let module = ImportedModule(content: .python(summary), sourcePath: source, validators: validators,
                                    isProjectFile: location.root.kind == .project)
        return (module, summary)
    }

    private func loadScript(_ path: String, key: String, context: ImportContextSnapshot) -> ImportedModule? {
        guard let root = context.projectRoot, let (text, size, mtime) = read(path) else { return nil }
        let fs = self.fs
        let summaryContext = ScriptSummaryContext(key: key, path: path, dialect: ScriptModuleLocator.dialect(of: path)) { spec in
            ScriptModuleLocator.resolve(spec, from: path, projectRoot: root, fs: fs).map { context.prefix + $0 }
        }
        let summary = ScriptModuleSummarizer.summarize(text, context: summaryContext,
                                                       namesOnly: size > ImportService.namesOnlySourceBytes)
        var validators: [String: Double] = [path: mtime]
        // The enclosing node_modules and package directory (mtime checks).
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        if let k = components.lastIndex(of: "node_modules") {
            let modules = components[0...k].joined(separator: "/")
            if let info = fs.info(modules) { validators[modules] = info.modificationTime }
            var end = k + 1
            if end < components.count, components[end].hasPrefix("@") { end += 1 }
            if end < components.count - 1 {
                let package = components[0...end].joined(separator: "/")
                if let info = fs.info(package) { validators[package] = info.modificationTime }
            }
        }
        let inNodeModules = path.contains("/node_modules/")
        return ImportedModule(content: .script(summary), sourcePath: fs.realPath(path), validators: validators,
                              isProjectFile: !inNodeModules)
    }
}
