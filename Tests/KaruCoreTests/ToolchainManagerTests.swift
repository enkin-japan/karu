import AppKit
import Foundation
import Testing
@testable import KaruCore

// T16.5 — the main-actor toolchain manager (lifetime, per-id concurrency,
// cancel, failure state, uninstall) and the Settings › Run managed-toolchain
// controls. Local fixture archives only; no network.

// MARK: - Helpers

/// Opens once; downloads blocked on it resume (or stop when cancelled).
final class DownloadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    func open() { lock.lock(); isOpen = true; lock.unlock() }
    var opened: Bool { lock.lock(); defer { lock.unlock() }; return isOpen }
}

/// A downloader that streams the fixture up to about half, then waits for
/// `gate` (polling cancellation).
func gatedDownloader(_ archive: URL, gate: DownloadGate) -> FixtureDownloader {
    let size = (try? Data(contentsOf: archive).count) ?? 0
    return FixtureDownloader(source: archive, chunkSize: max(1, size / 4), afterChunk: { written, cancellation in
        guard written * 2 >= Int64(size) else { return }
        while !gate.opened, !cancellation.isCancelled { usleep(5_000) }
    })
}

@MainActor
func waitFor(timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

/// A fixture archive plus a manifest entry under a real toolchain id.
struct ToolchainFixture {
    let dir: URL
    let archive: URL
    let entry: ToolchainManifestEntry
    let store: ToolchainStore

    init(id: String = "node", languages: [RunnableLanguage] = [.javascript, .typescript], checksum: String? = nil) throws {
        dir = ToolchainFixtures.tempDirectory("manager-\(id)")
        archive = try ToolchainFixtures.makeArchive(in: dir, top: "tool-1.0", files: ["bin/node", "bin/tool"])
        entry = try ToolchainFixtures.entry(id: id, archive: archive, checksum: checksum, executables: ["tool"],
                                            languages: languages)
        store = ToolchainStore(root: dir.appendingPathComponent("root"))
    }

    func cleanup() { try? FileManager.default.removeItem(at: dir) }
}

// MARK: - Manager

@Suite("Toolchain manager")
@MainActor
struct ToolchainManagerTests {
    @Test func installReportsProgressThenInstalledStateAndUsage() async throws {
        let fixture = try ToolchainFixture()
        defer { fixture.cleanup() }
        let center = NotificationCenter()
        let manager = ToolchainManager(store: fixture.store, manifest: [fixture.entry],
                                       downloader: FixtureDownloader(source: fixture.archive, chunkSize: 256),
                                       center: center)
        var seen: [ToolchainActivity?] = []
        var finished = 0
        let token = center.addObserver(forName: ToolchainManager.didChangeNotification, object: manager, queue: nil) { note in
            MainActor.assumeIsolated {
                seen.append(manager.state(for: "node").activity)
                if note.userInfo?[ToolchainManager.finishedKey] as? Bool == true { finished += 1 }
            }
        }
        defer { center.removeObserver(token) }

        #expect(manager.state(for: "node").installedVersion == nil)
        #expect(manager.install(fixture.entry))
        #expect(manager.state(for: "node").isInstalling)
        #expect(!manager.install(fixture.entry)) // one install per id
        #expect(await waitFor { manager.state(for: "node").activity == nil })
        #expect(await waitFor { manager.state(for: "node").diskUsage != nil })

        let state = manager.state(for: "node")
        #expect(state.installedVersion == "1.0")
        #expect(state.lastError == nil)
        #expect((state.diskUsage ?? 0) > 0)
        #expect(finished == 1)
        #expect(seen.contains { $0?.fraction != nil })
        #expect(seen.contains(.verifying))
        #expect(seen.contains(.extracting))
        #expect(fixture.store.installation(for: fixture.entry) != nil)
        #expect(ToolchainFixtures.stagingIsEmpty(fixture.store))
        #expect(!manager.hasActiveWork)
    }

    @Test func installOutlivesItsOwnerAndThenReleasesTheManager() async throws {
        let fixture = try ToolchainFixture()
        defer { fixture.cleanup() }
        let gate = DownloadGate()
        weak var weakManager: ToolchainManager?
        do {
            let manager = ToolchainManager(store: fixture.store, manifest: [fixture.entry],
                                           downloader: gatedDownloader(fixture.archive, gate: gate))
            weakManager = manager
            #expect(manager.install(fixture.entry))
        }
        // The "window" let go; the running install keeps the manager alive.
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(weakManager != nil)
        #expect(weakManager?.state(for: "node").isInstalling == true)
        gate.open()
        #expect(await waitFor { fixture.store.installation(for: fixture.entry) != nil })
        #expect(await waitFor { weakManager == nil })
        #expect(ToolchainFixtures.stagingIsEmpty(fixture.store))
    }

    @Test func differentIdsInstallConcurrently() async throws {
        let node = try ToolchainFixture(id: "node")
        let zig = try ToolchainFixture(id: "zig", languages: [.c, .cpp])
        defer { node.cleanup(); zig.cleanup() }
        let gate = DownloadGate()
        // Both share one store; each id has its own fixture archive.
        let store = node.store
        struct Router: ToolchainDownloader {
            let byHost: [String: FixtureDownloader]
            func download(from url: URL, to destination: URL, cancellation: ToolchainCancellation,
                          progress: @escaping @Sendable (Int64, Int64?) -> Void) throws -> URL {
                let key = url.lastPathComponent.hasPrefix("zig") ? "zig" : "node"
                return try byHost[key]!.download(from: url, to: destination, cancellation: cancellation, progress: progress)
            }
        }
        let manager = ToolchainManager(store: store, manifest: [node.entry, zig.entry],
                                       downloader: Router(byHost: ["node": gatedDownloader(node.archive, gate: gate),
                                                                   "zig": gatedDownloader(zig.archive, gate: gate)]))
        #expect(manager.install(node.entry))
        #expect(manager.install(zig.entry))
        #expect(manager.state(for: "node").isInstalling && manager.state(for: "zig").isInstalling)
        #expect(await waitFor {
            manager.state(for: "node").activity?.fraction ?? 0 >= 0.5 && manager.state(for: "zig").activity?.fraction ?? 0 >= 0.5
        })
        gate.open()
        #expect(await waitFor { !manager.hasActiveWork })
        #expect(manager.state(for: "node").installedVersion == "1.0")
        #expect(manager.state(for: "zig").installedVersion == "1.0")
    }

    @Test func cancelLeavesNothingAndNoError() async throws {
        let fixture = try ToolchainFixture()
        defer { fixture.cleanup() }
        let gate = DownloadGate()
        let manager = ToolchainManager(store: fixture.store, manifest: [fixture.entry],
                                       downloader: gatedDownloader(fixture.archive, gate: gate))
        #expect(manager.install(fixture.entry))
        #expect(await waitFor { (manager.state(for: "node").activity?.fraction ?? 0) >= 0.5 })
        manager.cancel("node")
        #expect(await waitFor { manager.state(for: "node").activity == nil })
        #expect(manager.state(for: "node").lastError == nil)
        #expect(manager.state(for: "node").installedVersion == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.store.toolchainDirectory("node").path))
        #expect(ToolchainFixtures.stagingIsEmpty(fixture.store))
        gate.open()
    }

    @Test func failureIsKeptAsLastErrorUntilTheNextAttempt() async throws {
        let fixture = try ToolchainFixture(checksum: String(repeating: "f", count: 64))
        defer { fixture.cleanup() }
        let manager = ToolchainManager(store: fixture.store, manifest: [fixture.entry],
                                       downloader: FixtureDownloader(source: fixture.archive))
        #expect(manager.install(fixture.entry))
        #expect(await waitFor { manager.state(for: "node").activity == nil })
        let state = manager.state(for: "node")
        guard case .checksumMismatch = state.lastError else {
            Issue.record("expected checksum mismatch, got \(String(describing: state.lastError))")
            return
        }
        #expect(state.installedVersion == nil)
        #expect(RunMessages.toolchainStatus(fixture.entry, state, language: .en)
                == L10n.string(.runToolchainFailed, language: .en, L10n.string(.runToolchainErrorChecksum, language: .en)))
        #expect(ToolchainFixtures.stagingIsEmpty(fixture.store))
        // A new attempt clears the error immediately.
        #expect(manager.install(fixture.entry))
        #expect(manager.state(for: "node").lastError == nil)
        #expect(await waitFor { manager.state(for: "node").activity == nil })
    }

    @Test func uninstallRemovesInstallAndCacheAndPurgesStagingOnCreation() async throws {
        let fixture = try ToolchainFixture()
        defer { fixture.cleanup() }
        try ToolchainFixtures.fakeInstall(fixture.entry, store: fixture.store)
        try FileManager.default.createDirectory(at: fixture.store.cacheDirectory("node"), withIntermediateDirectories: true)
        let leftover = fixture.store.stagingRoot.appendingPathComponent("stale")
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)

        let center = NotificationCenter()
        let manager = ToolchainManager(store: fixture.store, manifest: [fixture.entry],
                                       downloader: FixtureDownloader(source: fixture.archive), center: center)
        #expect(manager.state(for: "node").installedVersion == "1.0") // derived from disk
        #expect(await waitFor { ToolchainFixtures.stagingIsEmpty(fixture.store) })

        var finished = false
        let token = center.addObserver(forName: ToolchainManager.didChangeNotification, object: manager, queue: nil) { note in
            if note.userInfo?[ToolchainManager.finishedKey] as? Bool == true { MainActor.assumeIsolated { finished = true } }
        }
        defer { center.removeObserver(token) }
        #expect(manager.uninstall("node"))
        #expect(manager.state(for: "node").activity == .uninstalling)
        #expect(await waitFor { finished })
        #expect(manager.state(for: "node").installedVersion == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.store.toolchainDirectory("node").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.store.cacheDirectory("node").path))
    }
}

// MARK: - Settings › Run managed controls

@Suite("Run settings managed toolchains")
@MainActor
struct RunPreferencesToolchainTests {
    private func isolatedSettings() -> (RunSettings, NotificationCenter) {
        let name = "ToolchainSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let center = NotificationCenter()
        return (RunSettings(defaults: defaults, center: center), center)
    }

    private func makeController(manager: ToolchainManager, developerTools: Bool = true,
                                onInstallCLT: @escaping () -> Void = {}) -> RunPreferencesController {
        let (settings, center) = isolatedSettings()
        let probes = ToolchainProbes(isExecutable: { ToolchainStore.isExecutableFile(URL(fileURLWithPath: $0)) },
                                     developerToolsInstalled: { developerTools }, javaRuntimeInstalled: { true })
        let loginPath = LoginShellPath(shell: "/bin/zsh", timeout: 1, runner: { _, _, _ in nil })
        let store = manager.store
        let manifest = manager.manifest
        return RunPreferencesController(settings: settings, center: center, makeLocator: {
            ToolchainLocator(managed: KaruManagedToolchains(store: store, manifest: manifest),
                             loginPath: loginPath, probes: probes)
        }, manager: manager, probes: probes, installCommandLineTools: onInstallCLT)
    }

    @Test func rowsShowNotInstalledInstalledAndUpdateStates() async throws {
        let dir = ToolchainFixtures.tempDirectory("settings")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ToolchainStore(root: dir)
        let python = try #require(ToolchainManifest.entry(id: "python"))
        let node = try #require(ToolchainManifest.entry(id: "node"))
        try ToolchainFixtures.fakeInstall(python, store: store)
        // An older Node installed by a previous Karu (layout from its marker).
        try ToolchainFixtures.fakeInstall(node, version: "24.0.0", binPath: "node-v24.0.0-darwin-arm64/bin", store: store)
        let manager = ToolchainManager(store: store, manifest: ToolchainManifest.all,
                                       downloader: FixtureDownloader(source: dir))
        let controller = makeController(manager: manager)
        defer { controller.close() }

        // Every row but Bash has slot controls.
        for row in controller.rows {
            #expect(row.managedSlot.arrangedSubviews.isEmpty == (row.language == .bash), "\(row.language)")
        }

        let py = try #require(controller.managedControls[.python])
        #expect(await waitFor { manager.state(for: "python").diskUsage != nil })
        let usage = RunMessages.megabytes(manager.state(for: "python").diskUsage!)
        #expect(py.statusLabel.stringValue == L10n.t(.runToolchainInstalledSize, "3.14.10", usage))
        #expect(py.actionButton.isHidden) // already current
        #expect(py.uninstallButton?.isHidden == false)

        let go = try #require(controller.managedControls[.go])
        #expect(go.statusLabel.stringValue == L10n.t(.runToolchainNotInstalled, "68 MB"))
        #expect(!go.actionButton.isHidden && go.actionButton.title == L10n.t(.runToolchainInstall))
        #expect(go.uninstallButton?.isHidden == true)
        let dotnet = try #require(controller.managedControls[.csharp])
        #expect(dotnet.statusLabel.stringValue == L10n.t(.runToolchainNotInstalled, "234 MB"))

        // JS and TS share Node: same state, labelled with the provider.
        let js = try #require(controller.managedControls[.javascript])
        let ts = try #require(controller.managedControls[.typescript])
        #expect(js.statusLabel.stringValue == ts.statusLabel.stringValue)
        #expect(js.statusLabel.stringValue.hasPrefix("Node.js · "))
        #expect(js.statusLabel.stringValue.contains("24.0.0"))
        #expect(js.statusLabel.toolTip?.hasPrefix(L10n.t(.runToolchainProvidedBy, "Node.js")) == true)
        #expect(js.actionButton.title == L10n.t(.runToolchainUpdate, "26.13.1") && !js.actionButton.isHidden)
        #expect(ts.actionButton.title == js.actionButton.title)
        let c = try #require(controller.managedControls[.c])
        let cpp = try #require(controller.managedControls[.cpp])
        #expect(c.statusLabel.stringValue == cpp.statusLabel.stringValue)
        #expect(c.statusLabel.stringValue.hasPrefix("Zig · "))
    }

    @Test func installingCancelInstallAndUninstallFromTheRows() async throws {
        let fixture = try ToolchainFixture()
        defer { fixture.cleanup() }
        let gate = DownloadGate()
        let manager = ToolchainManager(store: fixture.store, manifest: [fixture.entry],
                                       downloader: gatedDownloader(fixture.archive, gate: gate))
        var controller = makeController(manager: manager)
        let js = try #require(controller.managedControls[.javascript])
        let ts = try #require(controller.managedControls[.typescript])
        #expect(js.actionButton.title == L10n.t(.runToolchainInstall))

        // Install from the TS row; both rows follow.
        ts.actionButton.performClick(nil)
        #expect(manager.state(for: "node").isInstalling)
        #expect(await waitFor { (manager.state(for: "node").activity?.fraction ?? 0) >= 0.5 })
        let percent = Int(((manager.state(for: "node").activity?.fraction ?? 0) * 100).rounded(.down))
        #expect(js.statusLabel.stringValue == fixture.entry.displayName + " · " + L10n.t(.runToolchainDownloading, percent))
        #expect(ts.statusLabel.stringValue == js.statusLabel.stringValue)
        #expect(js.actionButton.title == L10n.t(.runToolchainCancel) && !js.actionButton.isHidden)
        #expect(js.uninstallButton?.isHidden == true)

        // Cancel from the JS row.
        js.actionButton.performClick(nil)
        #expect(await waitFor { manager.state(for: "node").activity == nil })
        #expect(js.statusLabel.stringValue.hasSuffix(L10n.t(.runToolchainNotInstalled, RunMessages.megabytes(fixture.entry.downloadSize))))
        #expect(js.actionButton.title == L10n.t(.runToolchainInstall))

        // Install again, close the window mid-download, reopen: progress shows.
        js.actionButton.performClick(nil)
        #expect(await waitFor { (manager.state(for: "node").activity?.fraction ?? 0) >= 0.5 })
        controller.close()
        controller = makeController(manager: manager)
        defer { controller.close() }
        let js2 = try #require(controller.managedControls[.javascript])
        #expect(js2.actionButton.title == L10n.t(.runToolchainCancel))
        #expect(js2.statusLabel.stringValue.contains(L10n.t(.runToolchainDownloading, percent)))
        gate.open()
        #expect(await waitFor { manager.state(for: "node").installedVersion == "1.0" && !manager.hasActiveWork })
        // Detect results of the affected rows refresh after the install.
        #expect(await waitFor {
            if case .resolved(let tool)? = controller.detections[.typescript] { return tool.origin == .managed }
            return false
        })
        #expect(controller.detections[.javascript] != nil)
        #expect(controller.detections[.python] == nil)
        #expect(await waitFor { manager.state(for: "node").diskUsage != nil })
        #expect(js2.statusLabel.stringValue.contains(L10n.t(.runToolchainInstalledSize, "1.0",
                                                             RunMessages.megabytes(manager.state(for: "node").diskUsage!))))
        #expect(js2.actionButton.isHidden)
        #expect(js2.uninstallButton?.isHidden == false)

        // Uninstall: declined, then confirmed.
        var asked: [(String, Int64?)] = []
        var answer = false
        controller.confirmUninstall = { entry, usage, completion in
            asked.append((entry.id, usage))
            completion(answer)
        }
        js2.uninstallButton?.performClick(nil)
        #expect(asked.count == 1 && asked[0].0 == "node" && asked[0].1 != nil)
        #expect(manager.state(for: "node").installedVersion == "1.0")
        answer = true
        controller.managedControls[.typescript]?.uninstallButton?.performClick(nil)
        #expect(await waitFor { manager.state(for: "node").installedVersion == nil && !manager.hasActiveWork })
        #expect(!FileManager.default.fileExists(atPath: fixture.store.toolchainDirectory("node").path))
        #expect(js2.uninstallButton?.isHidden == true)
        #expect(await waitFor {
            if case .failed(.toolNotFound)? = controller.detections[.typescript] { return true }
            if case .resolved(let tool)? = controller.detections[.typescript] { return tool.origin != .managed }
            return false
        })
    }

    @Test(arguments: [false, true])
    func swiftAndRustRowsShowCommandLineTools(installed: Bool) async throws {
        let dir = ToolchainFixtures.tempDirectory("clt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = ToolchainManager(store: ToolchainStore(root: dir), manifest: ToolchainManifest.all,
                                       downloader: FixtureDownloader(source: dir))
        var launches = 0
        let controller = makeController(manager: manager, developerTools: installed, onInstallCLT: { launches += 1 })
        defer { controller.close() }
        #expect(await waitFor { controller.commandLineToolsInstalled != nil })
        for language in [RunnableLanguage.swift, .rust] {
            let controls = try #require(controller.managedControls[language])
            #expect(controls.uninstallButton == nil)
            #expect(controls.statusLabel.stringValue == L10n.t(installed ? .runCLTInstalled : .runCLTMissing))
            #expect(controls.actionButton.isHidden == installed)
            #expect(controls.actionButton.title == L10n.t(.runCLTInstall))
            if !installed { controls.actionButton.performClick(nil) }
        }
        #expect(launches == (installed ? 0 : 2))
        #expect(controller.managedControls[.rust]?.hintLabel?.stringValue == L10n.t(.runRustHint))
        #expect(controller.managedControls[.rust]?.hintLabel?.toolTip == L10n.t(.runRustHintDetail))
        #expect(controller.managedControls[.swift]?.hintLabel == nil)
    }

    @Test func statusTextExistsInAllThreeLanguages() throws {
        let entry = try #require(ToolchainManifest.entry(id: "go"))
        let states: [ToolchainManager.State] = [
            .init(), .init(installedVersion: "1.27.4"), .init(installedVersion: "1.27.4", diskUsage: 250_000_000),
            .init(activity: .downloading(received: 45, expected: 100)), .init(activity: .verifying),
            .init(activity: .extracting), .init(activity: .uninstalling), .init(lastError: .httpStatus(404)),
        ]
        for state in states {
            let texts = AppLanguage.allCases.map { RunMessages.toolchainStatus(entry, state, language: $0) }
            #expect(Set(texts).count == 3, "\(texts)")
        }
        #expect(RunMessages.toolchainStatus(entry, .init(activity: .downloading(received: 45, expected: 100)), language: .zhHans) == "下载中 45%")
        #expect(RunMessages.toolchainStatus(entry, .init(), language: .zhHans) == "未安装（下载约 68 MB）")
        #expect(RunMessages.toolchainStatus(entry, .init(installedVersion: "1.27.4", diskUsage: 250_000_000), language: .zhHans)
                == "已安装 v1.27.4 · 占用 250 MB")
        for error: ToolchainInstallError in [.cancelled, .network("x"), .httpStatus(500), .insecureURL("http://a"),
                                             .checksumMismatch(expected: "a", actual: "b"), .extractionFailed("e"),
                                             .executableMissing("bin/go"), .filesystem("f")] {
            for language in AppLanguage.allCases {
                #expect(!RunMessages.toolchainError(error, language: language).isEmpty)
            }
        }
        #expect(RunMessages.megabytes(1) == "1 MB")
        #expect(RunMessages.megabytes(27_109_898) == "27 MB")
    }
}
