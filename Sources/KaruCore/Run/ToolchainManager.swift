import Foundation

/// Main-actor front end for installing / uninstalling Karu-managed toolchains
/// (T16.5, ARCHITECTURE.md §6).
///
/// Lifetime: exists only while Settings › Run is open or an install /
/// uninstall is running — the window holds it, and it holds itself while work
/// is in flight, so an install outlives a closed window and a reopened window
/// (`acquire()`) sees its progress. Installed state is always re-derived from
/// the file system; the only in-memory state is per-id activity, the last
/// error and a displayed disk-usage figure.
///
/// Work: each install runs on its own background thread (at most one per
/// toolchain id; different ids run concurrently). Changes are posted as
/// `didChangeNotification` (object: the manager, userInfo `id`, `finished`).
@MainActor
public final class ToolchainManager {
    public nonisolated static let didChangeNotification = Notification.Name("KaruToolchainManagerDidChange")
    /// userInfo key: the toolchain id (String).
    public nonisolated static let idKey = "id"
    /// userInfo key: `true` when an install / uninstall just completed
    /// successfully (the installed toolchain changed).
    public nonisolated static let finishedKey = "finished"

    public struct State: Equatable {
        /// The installed version directory in use, `nil` when not installed.
        public var installedVersion: String?
        /// Bytes of install + cache; `nil` while unknown / being computed.
        public var diskUsage: Int64?
        public var activity: ToolchainActivity?
        public var lastError: ToolchainInstallError?

        public var isInstalling: Bool {
            guard let activity else { return false }
            return activity != .uninstalling
        }
    }

    private static weak var current: ToolchainManager?

    /// The live manager, or a new one with the production store / downloader.
    public static func acquire() -> ToolchainManager {
        if let current { return current }
        let manager = ToolchainManager()
        current = manager
        return manager
    }

    public let store: ToolchainStore
    public let manifest: [ToolchainManifestEntry]
    let center: NotificationCenter
    private let installer: ToolchainInstaller
    private let workQueue = DispatchQueue(label: "dev.enkin.Karu.toolchains", qos: .utility, attributes: .concurrent)
    private let purgeDone = DispatchGroup()
    private var states: [String: State] = [:]
    private var cancellations: [String: ToolchainCancellation] = [:]
    private var usageGeneration: [String: Int] = [:]
    /// Self-reference while work is running (released when idle).
    private var keepAlive: ToolchainManager?

    public convenience init(store: ToolchainStore = ToolchainStore(),
                            manifest: [ToolchainManifestEntry] = ToolchainManifest.all,
                            downloader: any ToolchainDownloader = URLSessionToolchainDownloader(),
                            center: NotificationCenter = .default) {
        self.init(store: store, manifest: manifest, downloader: downloader, center: center, allowsFileURLs: false)
    }

    init(store: ToolchainStore, manifest: [ToolchainManifestEntry], downloader: any ToolchainDownloader,
         center: NotificationCenter, allowsFileURLs: Bool) {
        self.store = store
        self.manifest = manifest
        self.center = center
        var installer = ToolchainInstaller(store: store, downloader: downloader)
        installer.allowsFileURLs = allowsFileURLs
        self.installer = installer
        // Leftover staging from a crashed / killed install. Installs wait for it.
        purgeDone.enter()
        workQueue.async { [purgeDone] in
            store.purgeStaging()
            purgeDone.leave()
        }
        for entry in manifest {
            states[entry.id] = State(installedVersion: store.installation(for: entry)?.version)
        }
    }

    // MARK: Queries

    public func state(for id: String) -> State {
        states[id] ?? State()
    }

    public func entry(id: String) -> ToolchainManifestEntry? {
        manifest.first { $0.id == id }
    }

    public func entry(for language: RunnableLanguage) -> ToolchainManifestEntry? {
        manifest.first { $0.languages.contains(language) }
    }

    /// Whether an install or uninstall is running.
    public var hasActiveWork: Bool {
        states.values.contains { $0.activity != nil }
    }

    /// Re-reads the installed version from disk and recomputes disk usage in
    /// the background (skipped for ids with work in flight).
    public func refresh() {
        for entry in manifest where states[entry.id]?.activity == nil {
            states[entry.id, default: State()].installedVersion = store.installation(for: entry)?.version
            if states[entry.id]?.installedVersion != nil {
                refreshDiskUsage(entry.id)
            } else {
                states[entry.id]?.diskUsage = nil
            }
            notify(entry.id, finished: false)
        }
    }

    /// Computes install + cache size on a background queue.
    public func refreshDiskUsage(_ id: String) {
        let generation = (usageGeneration[id] ?? 0) + 1
        usageGeneration[id] = generation
        let store = self.store
        workQueue.async { [weak self] in
            let bytes = store.diskUsage(id)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.usageGeneration[id] == generation else { return }
                    self.states[id, default: State()].diskUsage = bytes
                    self.notify(id, finished: false)
                }
            }
        }
    }

    // MARK: Install / cancel / uninstall

    /// Starts installing `entry` (explicit user action only). Returns `false`
    /// when work for this id is already running.
    @discardableResult
    public func install(_ entry: ToolchainManifestEntry) -> Bool {
        guard states[entry.id]?.activity == nil, cancellations[entry.id] == nil else { return false }
        let cancellation = ToolchainCancellation()
        cancellations[entry.id] = cancellation
        var state = states[entry.id] ?? State()
        state.activity = .downloading(received: 0, expected: entry.downloadSize)
        state.lastError = nil
        states[entry.id] = state
        keepAlive = self
        notify(entry.id, finished: false)

        let installer = self.installer
        let purgeDone = self.purgeDone
        // Strong captures are fine: `keepAlive` holds the manager until the
        // install finishes anyway.
        workQueue.async { [self] in
            purgeDone.wait()
            let result: Result<ToolchainStore.Installation, ToolchainInstallError>
            do {
                let installation = try installer.install(entry, cancellation: cancellation) { activity in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self.progress(entry.id, activity, cancellation) }
                    }
                }
                result = .success(installation)
            } catch let error as ToolchainInstallError {
                result = .failure(error)
            } catch {
                result = .failure(.filesystem(error.localizedDescription))
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.installFinished(entry, result, cancellation) }
            }
        }
        return true
    }

    /// Cancels a running install for `id` (no-op otherwise).
    public func cancel(_ id: String) {
        cancellations[id]?.cancel()
    }

    /// App termination: cancel every running install (kills a running tar's
    /// process group); leftover staging is purged on next launch.
    public static func cancelAllInstalls() {
        guard let current else { return }
        for cancellation in current.cancellations.values { cancellation.cancel() }
    }

    /// Removes the install and its caches in the background.
    @discardableResult
    public func uninstall(_ id: String) -> Bool {
        guard let entry = entry(id: id), states[id]?.activity == nil else { return false }
        states[id, default: State()].activity = .uninstalling
        states[id]?.lastError = nil
        usageGeneration[id, default: 0] += 1
        keepAlive = self
        notify(id, finished: false)
        let store = self.store
        workQueue.async {
            var failure: ToolchainInstallError?
            do { try store.uninstall(id) } catch { failure = .filesystem(error.localizedDescription) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.uninstallFinished(entry, failure) }
            }
        }
        return true
    }

    // MARK: Completion

    private func progress(_ id: String, _ activity: ToolchainActivity, _ cancellation: ToolchainCancellation) {
        guard cancellations[id] === cancellation, !cancellation.isCancelled else { return }
        states[id]?.activity = activity
        notify(id, finished: false)
    }

    private func installFinished(_ entry: ToolchainManifestEntry,
                                 _ result: Result<ToolchainStore.Installation, ToolchainInstallError>,
                                 _ cancellation: ToolchainCancellation) {
        guard cancellations[entry.id] === cancellation else { return }
        cancellations[entry.id] = nil
        var state = states[entry.id] ?? State()
        state.activity = nil
        state.installedVersion = store.installation(for: entry)?.version
        var finished = false
        switch result {
        case .success:
            state.lastError = nil
            state.diskUsage = nil
            finished = true
        case .failure(.cancelled):
            state.lastError = nil
        case .failure(let error):
            state.lastError = error
        }
        states[entry.id] = state
        if state.installedVersion != nil { refreshDiskUsage(entry.id) }
        notify(entry.id, finished: finished)
        releaseIfIdle()
    }

    private func uninstallFinished(_ entry: ToolchainManifestEntry, _ failure: ToolchainInstallError?) {
        var state = states[entry.id] ?? State()
        state.activity = nil
        state.lastError = failure
        state.installedVersion = store.installation(for: entry)?.version
        state.diskUsage = nil
        states[entry.id] = state
        if state.installedVersion != nil { refreshDiskUsage(entry.id) }
        notify(entry.id, finished: failure == nil)
        releaseIfIdle()
    }

    private func releaseIfIdle() {
        if !hasActiveWork { keepAlive = nil }
    }

    private func notify(_ id: String, finished: Bool) {
        center.post(name: Self.didChangeNotification, object: self,
                    userInfo: [Self.idKey: id, Self.finishedKey: finished])
    }
}
