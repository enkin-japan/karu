import Foundation

// MARK: - On-disk layout

/// File-system layout of Karu-installed toolchains (ARCHITECTURE.md §6):
///
/// - `<root>/<id>/<version>/…` — the extracted archive plus a small
///   `.karu-toolchain.json` marker recording where its executables live.
///   One version per id.
/// - `<root>/.cache/<id>/…` — caches the provider redirects tools into
///   (GOPATH, npm, pip, NuGet, Zig …); removed together with the install.
/// - `<root>/.staging/<uuid>/` — in-flight downloads / extractions; leftovers
///   are purged on launch and when the manager is created.
///
/// Installed state is derived from the file system on every query; nothing
/// is cached in memory. Methods do blocking I/O — call them off the main
/// thread except for the cheap `installation(for:)` listing.
public struct ToolchainStore: Equatable, Sendable {
    public static let markerFileName = ".karu-toolchain.json"

    public let root: URL

    public init(root: URL = ToolchainStore.defaultRoot) {
        self.root = root
    }

    /// `~/Library/Application Support/<bundle id>/Toolchains`, falling back
    /// to the app name when there is no bundle identifier (test / benchmark
    /// binaries) — same rule as `DraftStore` / `ScratchpadStore`.
    public static var defaultRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Karu")
            .appendingPathComponent("Toolchains")
    }

    public func toolchainDirectory(_ id: String) -> URL {
        root.appendingPathComponent(id, isDirectory: true)
    }

    public func versionDirectory(_ id: String, version: String) -> URL {
        toolchainDirectory(id).appendingPathComponent(version, isDirectory: true)
    }

    public var cacheRoot: URL { root.appendingPathComponent(".cache", isDirectory: true) }
    public var stagingRoot: URL { root.appendingPathComponent(".staging", isDirectory: true) }

    public func cacheDirectory(_ id: String) -> URL {
        cacheRoot.appendingPathComponent(id, isDirectory: true)
    }

    /// The bin directory for `binPath` inside an extracted tree (`.` = root).
    static func binDirectory(in tree: URL, binPath: String) -> URL {
        let trimmed = binPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.isEmpty || trimmed == "." { return tree }
        return tree.appendingPathComponent(trimmed, isDirectory: true)
    }

    // MARK: Marker

    struct Marker: Codable, Equatable {
        var id: String
        var version: String
        var binPath: String
    }

    static func writeMarker(_ marker: Marker, into tree: URL) throws {
        let data = try JSONEncoder().encode(marker)
        try data.write(to: tree.appendingPathComponent(markerFileName), options: .atomic)
    }

    static func readMarker(in tree: URL) -> Marker? {
        guard let data = try? Data(contentsOf: tree.appendingPathComponent(markerFileName)) else { return nil }
        return try? JSONDecoder().decode(Marker.self, from: data)
    }

    // MARK: Queries

    /// A usable installed toolchain.
    public struct Installation: Equatable, Sendable {
        public var id: String
        public var version: String
        /// `<root>/<id>/<version>`.
        public var directory: URL
        public var binDirectory: URL
    }

    /// Version directory names under `<root>/<id>` (hidden entries skipped).
    public func installedVersions(_ id: String) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: toolchainDirectory(id).path) else { return [] }
        return names.filter { name in
            guard !name.hasPrefix(".") else { return false }
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: versionDirectory(id, version: name).path, isDirectory: &isDir) && isDir.boolValue
        }.sorted()
    }

    /// The installed toolchain for `entry`, preferring the manifest's version,
    /// else any other version (e.g. one installed by an older Karu) whose
    /// marker points at existing executables. `nil` when nothing usable is
    /// installed. Cheap: one directory listing plus a marker read.
    public func installation(for entry: ToolchainManifestEntry) -> Installation? {
        let versions = installedVersions(entry.id)
        let ordered = versions.contains(entry.version)
            ? [entry.version] + versions.filter { $0 != entry.version }.reversed()
            : Array(versions.reversed())
        for version in ordered {
            let directory = versionDirectory(entry.id, version: version)
            let marker = Self.readMarker(in: directory)
            guard let binPath = marker?.binPath ?? (version == entry.version ? entry.binPath : nil) else { continue }
            let bin = Self.binDirectory(in: directory, binPath: binPath)
            guard entry.executables.allSatisfy({ Self.isExecutableFile(bin.appendingPathComponent($0)) }) else { continue }
            return Installation(id: entry.id, version: version, directory: directory, binDirectory: bin)
        }
        return nil
    }

    /// Regular (or symlinked-to-regular) executable file.
    static func isExecutableFile(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        let fm = FileManager.default
        return fm.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
            && fm.isExecutableFile(atPath: url.path)
    }

    /// Allocated bytes of `<root>/<id>` plus its cache. Blocking.
    public func diskUsage(_ id: String) -> Int64 {
        Self.allocatedSize(of: toolchainDirectory(id)) + Self.allocatedSize(of: cacheDirectory(id))
    }

    /// Allocated size of a directory tree (symlinks not followed); 0 if absent.
    public static func allocatedSize(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys,
                                                              options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }

    // MARK: Mutations

    /// Removes the install and its caches. Blocking.
    public func uninstall(_ id: String) throws {
        try Self.forceRemove(toolchainDirectory(id))
        try Self.forceRemove(cacheDirectory(id))
    }

    /// Removes every leftover staging directory. Returns how many were removed.
    @discardableResult
    public func purgeStaging() -> Int {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: stagingRoot, includingPropertiesForKeys: nil) else { return 0 }
        var removed = 0
        for entry in entries where (try? Self.forceRemove(entry)) != nil { removed += 1 }
        return removed
    }

    /// `removeItem`, retried after granting the owner write permission on
    /// every directory — Go's module cache is deliberately read-only, which
    /// otherwise makes it undeletable. Absent paths succeed.
    public static func forceRemove(_ url: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) || (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil else { return }
        do {
            try fm.removeItem(at: url)
        } catch {
            makeOwnerWritable(url)
            try fm.removeItem(at: url)
        }
    }

    private static func makeOwnerWritable(_ url: URL) {
        let fm = FileManager.default
        func grant(_ path: String) {
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  attrs[.type] as? FileAttributeType == .typeDirectory,
                  let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue else { return }
            if perms & 0o700 != 0o700 {
                try? fm.setAttributes([.posixPermissions: perms | 0o700], ofItemAtPath: path)
            }
        }
        grant(url.path)
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                             options: [], errorHandler: { _, _ in true }) else { return }
        for case let item as URL in enumerator { grant(item.path) }
    }
}

// MARK: - Provider

/// The app's `ManagedToolchainProvider`: answers from the file system on each
/// call (no resident state) — the language's manifest toolchain if installed,
/// with caches redirected into `<root>/.cache/<id>/` and telemetry disabled so
/// nothing is written to the user's global tool configuration.
public struct KaruManagedToolchains: ManagedToolchainProvider {
    public var store: ToolchainStore
    public var manifest: [ToolchainManifestEntry]

    public init(store: ToolchainStore = ToolchainStore(), manifest: [ToolchainManifestEntry] = ToolchainManifest.all) {
        self.store = store
        self.manifest = manifest
    }

    public func toolchain(for language: RunnableLanguage) -> ManagedToolchain? {
        guard let entry = manifest.first(where: { $0.languages.contains(language) }),
              let installation = store.installation(for: entry) else { return nil }
        let cache = store.cacheDirectory(entry.id)
        return ManagedToolchain(binDirectory: installation.binDirectory,
                                environment: Self.environment(id: entry.id, binDirectory: installation.binDirectory,
                                                              cacheDirectory: cache),
                                compileEnvironment: Self.compileEnvironment(id: entry.id, cacheDirectory: cache))
    }

    /// Compile-step-only overrides. Go's local telemetry (enabled by default,
    /// not switchable via env) writes to os.UserConfigDir = $HOME/Library/
    /// Application Support/go on macOS; a cache-local HOME for `go build`
    /// keeps it inside Karu's directory while the built program keeps the
    /// user's real HOME.
    public static func compileEnvironment(id: String, cacheDirectory cache: URL) -> [String: String] {
        switch id {
        case "go": return ["HOME": cache.appendingPathComponent("home").path]
        default: return [:]
        }
    }

    /// Child-process environment for a managed toolchain.
    public static func environment(id: String, binDirectory: URL, cacheDirectory cache: URL) -> [String: String] {
        func dir(_ name: String) -> String { cache.appendingPathComponent(name).path }
        switch id {
        case "go":
            return [
                "GOPATH": dir("gopath"),
                "GOMODCACHE": dir("gopath/pkg/mod"),
                "GOCACHE": dir("build"),
                "GOENV": dir("env"),
                // GOTELEMETRY is read-only as an env var; the real redirect is
                // the compile-step HOME (see `compileEnvironment`).
                "GOTELEMETRY": "off",
                "GOTOOLCHAIN": "local",
            ]
        case "node":
            return [
                "NPM_CONFIG_CACHE": dir("npm-cache"),
                "NPM_CONFIG_PREFIX": dir("npm-prefix"),
                "NPM_CONFIG_UPDATE_NOTIFIER": "false",
                "COREPACK_HOME": dir("corepack"),
                "NODE_REPL_HISTORY": "",
            ]
        case "python":
            return [
                "PIP_CACHE_DIR": dir("pip"),
                "PYTHONUSERBASE": dir("userbase"),
                "PIP_DISABLE_PIP_VERSION_CHECK": "1",
            ]
        case "java":
            return ["JAVA_HOME": binDirectory.deletingLastPathComponent().path]
        case "dotnet":
            return [
                "DOTNET_ROOT": binDirectory.path,
                "DOTNET_CLI_HOME": dir("home"),
                "NUGET_PACKAGES": dir("nuget/packages"),
                "NUGET_HTTP_CACHE_PATH": dir("nuget/http-cache"),
                "NUGET_PLUGINS_CACHE_PATH": dir("nuget/plugins-cache"),
                "DOTNET_CLI_TELEMETRY_OPTOUT": "1",
                "DOTNET_SKIP_FIRST_TIME_EXPERIENCE": "1",
                "DOTNET_NOLOGO": "1",
                "DOTNET_GENERATE_ASPNET_CERTIFICATE": "false",
                "DOTNET_ADD_GLOBAL_TOOLS_TO_PATH": "false",
                // NuGet writes a Migrations marker under LocalApplicationData
                // (~/.local/share on macOS). `dotnet run` is one step, so this
                // also applies to the user's program (documented in §6).
                "XDG_DATA_HOME": dir("data"),
            ]
        case "zig":
            return [
                "ZIG_GLOBAL_CACHE_DIR": dir("global"),
                "ZIG_LOCAL_CACHE_DIR": dir("local"),
            ]
        default:
            return [:]
        }
    }
}
