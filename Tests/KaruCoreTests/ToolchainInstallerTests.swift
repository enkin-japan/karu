import Foundation
import Testing
@testable import KaruCore

// T16.5 — Karu-managed toolchain installer and on-disk store. Everything runs
// against temp directories and local archives built with /usr/bin/tar; no
// network access, and no real toolchain is ever downloaded.

// MARK: - Fixtures (shared with the other Toolchain*Tests files)

enum ToolchainFixtures {
    static func tempDirectory(_ label: String = "fixture") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("KaruToolchainTests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func writeExecutable(_ url: URL, _ body: String = "#!/bin/sh\necho fake\n") throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(body.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Builds `<dir>/archive.<ext>` whose top-level entry is `top` (or the
    /// payload root's contents when `top` is nil), containing `files`
    /// (relative path → executable script, or plain file when `executable`
    /// is false).
    static func makeArchive(in dir: URL, top: String?, files: [String], executable: Bool = true,
                            compression: String = "z") throws -> URL {
        let payload = dir.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        let base = top.map { payload.appendingPathComponent($0, isDirectory: true) } ?? payload
        for file in files {
            let url = base.appendingPathComponent(file)
            if executable {
                try writeExecutable(url)
            } else {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("data".utf8).write(to: url)
            }
        }
        let ext = compression == "J" ? "tar.xz" : "tar.gz"
        let archive = dir.appendingPathComponent("archive.\(ext)")
        let status = try run("/usr/bin/tar", ["-c\(compression)f", archive.path, "-C", payload.path, top ?? "."])
        precondition(status == 0, "tar failed")
        return archive
    }

    static func sha256(_ url: URL) throws -> String {
        try ToolchainInstaller.digest(of: url, algorithm: .sha256)
    }

    static func entry(id: String = "fake", version: String = "1.0", archive: URL, checksum: String? = nil,
                      binPath: String = "tool-1.0/bin", executables: [String] = ["tool"],
                      languages: [RunnableLanguage] = [.python]) throws -> ToolchainManifestEntry {
        let size = (try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? NSNumber)?.int64Value ?? 0
        return ToolchainManifestEntry(
            id: id, displayName: "Fake", languages: languages, version: version,
            url: URL(string: "https://example.invalid/\(id)-\(version).tar.gz")!,
            checksum: ToolchainChecksum(.sha256, try checksum ?? sha256(archive)),
            downloadSize: size, binPath: binPath, executables: executables)
    }

    /// Simulates an installed toolchain (as the installer would leave it).
    static func fakeInstall(_ entry: ToolchainManifestEntry, version: String? = nil, binPath: String? = nil,
                            store: ToolchainStore, marker: Bool = true) throws {
        let version = version ?? entry.version
        let binPath = binPath ?? entry.binPath
        let dir = store.versionDirectory(entry.id, version: version)
        let bin = ToolchainStore.binDirectory(in: dir, binPath: binPath)
        for exe in entry.executables { try writeExecutable(bin.appendingPathComponent(exe)) }
        if marker {
            try ToolchainStore.writeMarker(.init(id: entry.id, version: version, binPath: binPath), into: dir)
        }
    }

    static func stagingIsEmpty(_ store: ToolchainStore) -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: store.stagingRoot.path)) ?? []).isEmpty
    }
}

/// Copies a local file in small chunks, reporting progress; can run a hook
/// after every chunk (to cancel or block) and fake the final URL.
struct FixtureDownloader: ToolchainDownloader {
    var source: URL
    var finalURL: URL?
    var chunkSize = 1024
    var afterChunk: (@Sendable (_ written: Int64, _ cancellation: ToolchainCancellation) -> Void)?

    func download(from url: URL, to destination: URL, cancellation: ToolchainCancellation,
                  progress: @escaping @Sendable (Int64, Int64?) -> Void) throws -> URL {
        let data = try Data(contentsOf: source)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }
        var offset = 0
        while offset < data.count {
            try cancellation.check()
            let end = min(data.count, offset + chunkSize)
            try out.write(contentsOf: data[offset..<end])
            offset = end
            progress(Int64(offset), Int64(data.count))
            afterChunk?(Int64(offset), cancellation)
        }
        try cancellation.check()
        return finalURL ?? url
    }
}

/// Thread-safe recorder.
final class Recorder<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func append(_ item: T) { lock.lock(); items.append(item); lock.unlock() }
    var values: [T] { lock.lock(); defer { lock.unlock() }; return items }
}

// MARK: - Installer

@Suite("Toolchain installer")
struct ToolchainInstallerTests {
    private func installer(_ store: ToolchainStore, _ downloader: FixtureDownloader) -> ToolchainInstaller {
        ToolchainInstaller(store: store, downloader: downloader)
    }

    @Test(arguments: ["z", "J"])
    func happyPathPlacesVerifiedTreeAndCleansStaging(compression: String) throws {
        let dir = ToolchainFixtures.tempDirectory("happy")
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = try ToolchainFixtures.makeArchive(in: dir, top: "tool-1.0", files: ["bin/tool", "lib/x"],
                                                        compression: compression)
        let entry = try ToolchainFixtures.entry(archive: archive)
        let store = ToolchainStore(root: dir.appendingPathComponent("root"))
        let phases = Recorder<ToolchainActivity>()

        let installation = try installer(store, FixtureDownloader(source: archive, chunkSize: 512))
            .install(entry, cancellation: ToolchainCancellation()) { phases.append($0) }

        let versionDir = store.versionDirectory("fake", version: "1.0")
        #expect(installation.directory.path == versionDir.path)
        #expect(installation.binDirectory.path == versionDir.appendingPathComponent("tool-1.0/bin").path)
        #expect(FileManager.default.isExecutableFile(atPath: versionDir.appendingPathComponent("tool-1.0/bin/tool").path))
        #expect(FileManager.default.fileExists(atPath: versionDir.appendingPathComponent("tool-1.0/lib/x").path))
        #expect(ToolchainStore.readMarker(in: versionDir) == .init(id: "fake", version: "1.0", binPath: "tool-1.0/bin"))
        #expect(store.installation(for: entry) == installation)
        #expect(ToolchainFixtures.stagingIsEmpty(store))

        // Progress: downloading (monotonic, ends at 100%), then verify, then extract.
        let values = phases.values
        let downloads = values.compactMap { $0.fraction }
        #expect(downloads.count >= 2)
        #expect(downloads == downloads.sorted())
        #expect(downloads.last == 1)
        let verify = try #require(values.firstIndex(of: .verifying))
        let extract = try #require(values.firstIndex(of: .extracting))
        #expect(verify < extract)
        #expect(!values[verify...].contains { $0.fraction != nil })
    }

    @Test func checksumMismatchInstallsNothing() throws {
        let dir = ToolchainFixtures.tempDirectory("mismatch")
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = try ToolchainFixtures.makeArchive(in: dir, top: "tool-1.0", files: ["bin/tool"])
        let entry = try ToolchainFixtures.entry(archive: archive, checksum: String(repeating: "0", count: 64))
        let store = ToolchainStore(root: dir.appendingPathComponent("root"))
        let phases = Recorder<ToolchainActivity>()

        #expect {
            try installer(store, FixtureDownloader(source: archive))
                .install(entry, cancellation: ToolchainCancellation()) { phases.append($0) }
        } throws: { error in
            guard case .checksumMismatch(let expected, let actual) = error as? ToolchainInstallError else { return false }
            return expected == String(repeating: "0", count: 64) && actual.count == 64
        }
        #expect(!FileManager.default.fileExists(atPath: store.toolchainDirectory("fake").path))
        #expect(ToolchainFixtures.stagingIsEmpty(store))
        #expect(!phases.values.contains(.extracting))
    }

    @Test func missingExecutableAfterExtractInstallsNothing() throws {
        let dir = ToolchainFixtures.tempDirectory("missing")
        defer { try? FileManager.default.removeItem(at: dir) }
        // Wrong layout: tool lives elsewhere.
        let archive = try ToolchainFixtures.makeArchive(in: dir, top: "tool-1.0", files: ["libexec/tool"])
        let entry = try ToolchainFixtures.entry(archive: archive)
        let store = ToolchainStore(root: dir.appendingPathComponent("root"))
        #expect(throws: ToolchainInstallError.executableMissing("tool-1.0/bin/tool")) {
            try installer(store, FixtureDownloader(source: archive)).install(entry, cancellation: ToolchainCancellation()) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: store.toolchainDirectory("fake").path))
        #expect(ToolchainFixtures.stagingIsEmpty(store))

        // Present but not executable is rejected too.
        let dir2 = dir.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)
        let plain = try ToolchainFixtures.makeArchive(in: dir2, top: "tool-1.0", files: ["bin/tool"], executable: false)
        #expect(throws: ToolchainInstallError.executableMissing("tool-1.0/bin/tool")) {
            try installer(store, FixtureDownloader(source: plain))
                .install(try ToolchainFixtures.entry(archive: plain), cancellation: ToolchainCancellation()) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: store.toolchainDirectory("fake").path))
    }

    @Test func archiveRootBinPathAndSymlinkedExecutable() throws {
        let dir = ToolchainFixtures.tempDirectory("root")
        defer { try? FileManager.default.removeItem(at: dir) }
        // .NET-style: executable at the archive root.
        let archive = try ToolchainFixtures.makeArchive(in: dir, top: nil, files: ["dotnet"])
        let entry = try ToolchainFixtures.entry(id: "dotnet", archive: archive, binPath: ".", executables: ["dotnet"])
        let store = ToolchainStore(root: dir.appendingPathComponent("root"))
        let installation = try installer(store, FixtureDownloader(source: archive))
            .install(entry, cancellation: ToolchainCancellation()) { _ in }
        #expect(installation.binDirectory.path == store.versionDirectory("dotnet", version: "1.0").path)

        // python-build-standalone style: python3 is a symlink inside the tree.
        let payload = dir.appendingPathComponent("py", isDirectory: true)
        try ToolchainFixtures.writeExecutable(payload.appendingPathComponent("python/bin/python3.14"))
        try FileManager.default.createSymbolicLink(atPath: payload.appendingPathComponent("python/bin/python3").path,
                                                   withDestinationPath: "python3.14")
        let pyArchive = dir.appendingPathComponent("py.tar.gz")
        try ToolchainFixtures.run("/usr/bin/tar", ["-czf", pyArchive.path, "-C", payload.path, "python"])
        let py = try ToolchainFixtures.entry(id: "python", archive: pyArchive, binPath: "python/bin", executables: ["python3"])
        _ = try installer(store, FixtureDownloader(source: pyArchive)).install(py, cancellation: ToolchainCancellation()) { _ in }
        #expect(store.installation(for: py) != nil)

        // A symlink escaping the tree is rejected.
        let evil = dir.appendingPathComponent("evil", isDirectory: true)
        try FileManager.default.createDirectory(at: evil.appendingPathComponent("t/bin"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: evil.appendingPathComponent("t/bin/tool").path,
                                                   withDestinationPath: "/bin/sh")
        let evilArchive = dir.appendingPathComponent("evil.tar.gz")
        try ToolchainFixtures.run("/usr/bin/tar", ["-czf", evilArchive.path, "-C", evil.path, "t"])
        let evilEntry = try ToolchainFixtures.entry(id: "evil", archive: evilArchive, binPath: "t/bin")
        #expect(throws: ToolchainInstallError.executableMissing("t/bin/tool")) {
            try installer(store, FixtureDownloader(source: evilArchive)).install(evilEntry, cancellation: ToolchainCancellation()) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: store.toolchainDirectory("evil").path))
    }

    @Test func nonHTTPSFinalURLIsRejected() throws {
        let dir = ToolchainFixtures.tempDirectory("insecure")
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = try ToolchainFixtures.makeArchive(in: dir, top: "tool-1.0", files: ["bin/tool"])
        let entry = try ToolchainFixtures.entry(archive: archive)
        let store = ToolchainStore(root: dir.appendingPathComponent("root"))
        let redirected = URL(string: "http://example.invalid/tool.tar.gz")!
        #expect(throws: ToolchainInstallError.insecureURL(redirected.absoluteString)) {
            try installer(store, FixtureDownloader(source: archive, finalURL: redirected))
                .install(entry, cancellation: ToolchainCancellation()) { _ in }
        }
        // file:// is only accepted when explicitly allowed (tests).
        var strict = installer(store, FixtureDownloader(source: archive, finalURL: archive))
        #expect(throws: ToolchainInstallError.insecureURL(archive.absoluteString)) {
            try strict.install(entry, cancellation: ToolchainCancellation()) { _ in }
        }
        strict.allowsFileURLs = true
        _ = try strict.install(entry, cancellation: ToolchainCancellation()) { _ in }
        #expect(store.installation(for: entry) != nil)
        #expect(ToolchainFixtures.stagingIsEmpty(store))
    }

    @Test func cancelDuringDownloadLeavesNothing() throws {
        let dir = ToolchainFixtures.tempDirectory("cancel-dl")
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = try ToolchainFixtures.makeArchive(in: dir, top: "tool-1.0", files: ["bin/tool", "lib/a", "lib/b"])
        let entry = try ToolchainFixtures.entry(archive: archive)
        let store = ToolchainStore(root: dir.appendingPathComponent("root"))
        let downloader = FixtureDownloader(source: archive, chunkSize: 64, afterChunk: { written, cancellation in
            if written >= 128 { cancellation.cancel() }
        })
        #expect(throws: ToolchainInstallError.cancelled) {
            try installer(store, downloader).install(entry, cancellation: ToolchainCancellation()) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: store.toolchainDirectory("fake").path))
        #expect(ToolchainFixtures.stagingIsEmpty(store))
    }

    @Test func cancelDuringExtractKillsTarAndLeavesNothing() throws {
        let dir = ToolchainFixtures.tempDirectory("cancel-x")
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = try ToolchainFixtures.makeArchive(in: dir, top: "tool-1.0", files: ["bin/tool"])
        let entry = try ToolchainFixtures.entry(archive: archive)
        let store = ToolchainStore(root: dir.appendingPathComponent("root"))
        // A slow "tar" that writes a partial file into -C <dir>, then hangs.
        let fakeTar = dir.appendingPathComponent("bin/slow-tar")
        try ToolchainFixtures.writeExecutable(fakeTar, "#!/bin/sh\ntouch \"$4/partial\"\nexec /bin/sleep 30\n")
        var slow = installer(store, FixtureDownloader(source: archive))
        slow.tarPath = fakeTar.path
        let cancellation = ToolchainCancellation()
        let started = Date()
        #expect(throws: ToolchainInstallError.cancelled) {
            try slow.install(entry, cancellation: cancellation) { activity in
                guard activity == .extracting else { return }
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { cancellation.cancel() }
            }
        }
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(!FileManager.default.fileExists(atPath: store.toolchainDirectory("fake").path))
        #expect(ToolchainFixtures.stagingIsEmpty(store))
    }

    @Test func corruptArchiveReportsExtractionFailure() throws {
        let dir = ToolchainFixtures.tempDirectory("corrupt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = dir.appendingPathComponent("junk.tar.gz")
        try Data(repeating: 0x42, count: 4096).write(to: archive)
        let entry = try ToolchainFixtures.entry(archive: archive)
        let store = ToolchainStore(root: dir.appendingPathComponent("root"))
        #expect {
            try installer(store, FixtureDownloader(source: archive)).install(entry, cancellation: ToolchainCancellation()) { _ in }
        } throws: { error in
            if case .extractionFailed = error as? ToolchainInstallError { return true } else { return false }
        }
        #expect(!FileManager.default.fileExists(atPath: store.toolchainDirectory("fake").path))
        #expect(ToolchainFixtures.stagingIsEmpty(store))
    }

    @Test func newVersionReplacesOldVersionDirectory() throws {
        let dir = ToolchainFixtures.tempDirectory("upgrade")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ToolchainStore(root: dir.appendingPathComponent("root"))
        let v1dir = dir.appendingPathComponent("v1", isDirectory: true)
        try FileManager.default.createDirectory(at: v1dir, withIntermediateDirectories: true)
        let v1 = try ToolchainFixtures.makeArchive(in: v1dir, top: "tool-1.0", files: ["bin/tool"])
        let v1entry = try ToolchainFixtures.entry(version: "1.0", archive: v1)
        _ = try installer(store, FixtureDownloader(source: v1)).install(v1entry, cancellation: ToolchainCancellation()) { _ in }
        #expect(store.installedVersions("fake") == ["1.0"])
        // Cache survives an upgrade.
        try FileManager.default.createDirectory(at: store.cacheDirectory("fake"), withIntermediateDirectories: true)
        try Data("c".utf8).write(to: store.cacheDirectory("fake").appendingPathComponent("c"))

        let v2dir = dir.appendingPathComponent("v2", isDirectory: true)
        try FileManager.default.createDirectory(at: v2dir, withIntermediateDirectories: true)
        let v2 = try ToolchainFixtures.makeArchive(in: v2dir, top: "tool-2.0", files: ["bin/tool"])
        let v2entry = try ToolchainFixtures.entry(version: "2.0", archive: v2, binPath: "tool-2.0/bin")

        // Before upgrading, the v1 install still serves the v2 manifest entry via its marker.
        let old = try #require(store.installation(for: v2entry))
        #expect(old.version == "1.0")
        #expect(old.binDirectory.path.hasSuffix("/fake/1.0/tool-1.0/bin"))

        _ = try installer(store, FixtureDownloader(source: v2)).install(v2entry, cancellation: ToolchainCancellation()) { _ in }
        #expect(store.installedVersions("fake") == ["2.0"])
        #expect(store.installation(for: v2entry)?.version == "2.0")
        #expect(FileManager.default.fileExists(atPath: store.cacheDirectory("fake").appendingPathComponent("c").path))

        // Reinstalling the same version replaces it in place.
        _ = try installer(store, FixtureDownloader(source: v2)).install(v2entry, cancellation: ToolchainCancellation()) { _ in }
        #expect(store.installedVersions("fake") == ["2.0"])
        #expect(ToolchainFixtures.stagingIsEmpty(store))
    }

    @Test func digestStreamsSHA256AndSHA512() throws {
        let dir = ToolchainFixtures.tempDirectory("digest")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("f")
        // Larger than one chunk so streaming crosses chunk boundaries.
        try Data(repeating: 0x61, count: ToolchainInstaller.chunkSize + 123).write(to: file)
        let tools = [("/usr/bin/shasum", ["-a", "256"], ToolchainChecksumAlgorithm.sha256),
                     ("/usr/bin/shasum", ["-a", "512"], .sha512)]
        for (tool, args, algorithm) in tools {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = args + [file.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            let expected = String(out.split(separator: " ").first ?? "")
            let actual = try ToolchainInstaller.digest(of: file, algorithm: algorithm)
            #expect(actual == expected)
            #expect(actual.count == algorithm.hexLength)
        }
        let cancelled = ToolchainCancellation()
        cancelled.cancel()
        #expect(throws: ToolchainInstallError.cancelled) {
            try ToolchainInstaller.digest(of: file, algorithm: .sha256, cancellation: cancelled)
        }
    }

    @Test func urlSessionDownloaderStreamsALocalFile() throws {
        // file:// through the production URLSession downloader: no network.
        let dir = ToolchainFixtures.tempDirectory("urlsession")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("src.bin")
        try Data(repeating: 7, count: 300_000).write(to: source)
        let destination = dir.appendingPathComponent("out.bin")
        let progress = Recorder<Int64>()
        let final = try URLSessionToolchainDownloader().download(from: source, to: destination,
                                                                 cancellation: ToolchainCancellation()) { received, _ in
            progress.append(received)
        }
        #expect(final.isFileURL)
        #expect(try Data(contentsOf: destination) == Data(contentsOf: source))
        #expect(progress.values.last == 300_000)
        // Cancelled before start: nothing written.
        let cancelled = ToolchainCancellation()
        cancelled.cancel()
        let other = dir.appendingPathComponent("never.bin")
        #expect(throws: ToolchainInstallError.cancelled) {
            try URLSessionToolchainDownloader().download(from: source, to: other, cancellation: cancelled) { _, _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: other.path))
    }
}

// MARK: - Store

@Suite("Toolchain store")
struct ToolchainStoreTests {
    @Test func uninstallRemovesInstallAndCacheIncludingReadOnlyTrees() throws {
        let dir = ToolchainFixtures.tempDirectory("uninstall")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ToolchainStore(root: dir)
        let go = try #require(ToolchainManifest.entry(id: "go"))
        try ToolchainFixtures.fakeInstall(go, store: store)
        // Go's module cache is read-only (0555 dirs, 0444 files).
        let mod = store.cacheDirectory("go").appendingPathComponent("gopath/pkg/mod/example.com/m@v1")
        try FileManager.default.createDirectory(at: mod, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: mod.appendingPathComponent("f.go"))
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: mod.appendingPathComponent("f.go").path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: mod.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: mod.deletingLastPathComponent().path)
        // Another toolchain is untouched.
        let zig = try #require(ToolchainManifest.entry(id: "zig"))
        try ToolchainFixtures.fakeInstall(zig, store: store)

        #expect(store.installation(for: go) != nil)
        try store.uninstall("go")
        #expect(!FileManager.default.fileExists(atPath: store.toolchainDirectory("go").path))
        #expect(!FileManager.default.fileExists(atPath: store.cacheDirectory("go").path))
        #expect(store.installation(for: go) == nil)
        #expect(store.installation(for: zig) != nil)
        // Uninstalling something absent is harmless.
        try store.uninstall("go")
    }

    @Test func purgeStagingRemovesLeftovers() throws {
        let dir = ToolchainFixtures.tempDirectory("purge")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ToolchainStore(root: dir)
        #expect(store.purgeStaging() == 0) // no staging dir yet
        for name in ["a", "b"] {
            let leftover = store.stagingRoot.appendingPathComponent(name).appendingPathComponent("x/bin")
            try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
            try Data("partial".utf8).write(to: leftover.appendingPathComponent("archive"))
        }
        let python = try #require(ToolchainManifest.entry(id: "python"))
        try ToolchainFixtures.fakeInstall(python, store: store)
        #expect(store.purgeStaging() == 2)
        #expect(ToolchainFixtures.stagingIsEmpty(store))
        #expect(store.installation(for: python) != nil)
    }

    @Test func diskUsageCountsInstallAndCache() throws {
        let dir = ToolchainFixtures.tempDirectory("usage")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ToolchainStore(root: dir)
        #expect(store.diskUsage("node") == 0)
        let install = store.versionDirectory("node", version: "1").appendingPathComponent("big")
        try FileManager.default.createDirectory(at: install.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 200_000).write(to: install)
        let installOnly = store.diskUsage("node")
        #expect(installOnly >= 200_000)
        try FileManager.default.createDirectory(at: store.cacheDirectory("node"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 100_000).write(to: store.cacheDirectory("node").appendingPathComponent("c"))
        #expect(store.diskUsage("node") >= installOnly + 100_000)
        #expect(store.diskUsage("python") == 0)
    }

    @Test func versionWithoutMarkerOnlyCountsForTheManifestVersion() throws {
        let dir = ToolchainFixtures.tempDirectory("marker")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ToolchainStore(root: dir)
        let node = try #require(ToolchainManifest.entry(id: "node"))
        // Unknown older version without a marker: layout unknown → ignored.
        try ToolchainFixtures.fakeInstall(node, version: "1.0.0", store: store, marker: false)
        #expect(store.installation(for: node) == nil)
        // Current version without a marker uses the manifest's bin path.
        try ToolchainFixtures.fakeInstall(node, store: store, marker: false)
        #expect(store.installation(for: node)?.version == node.version)
        // Hidden entries are never versions.
        try FileManager.default.createDirectory(at: store.toolchainDirectory("node").appendingPathComponent(".tmp"),
                                                withIntermediateDirectories: true)
        #expect(store.installedVersions("node") == ["1.0.0", node.version].sorted())
    }

    @Test func defaultRootFollowsTheDraftStoreRule() {
        let root = ToolchainStore.defaultRoot
        #expect(root.lastPathComponent == "Toolchains")
        #expect(root.deletingLastPathComponent().lastPathComponent == (Bundle.main.bundleIdentifier ?? "Karu"))
        #expect(root.path.contains("/Library/Application Support/"))
    }
}
