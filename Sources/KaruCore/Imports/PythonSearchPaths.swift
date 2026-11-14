import Foundation

// M17 T17.13 — where Python modules are looked up (plan §9, the Python row):
// ① the project folder root, ② the project's `.venv` / `venv` (read from
// `pyvenv.cfg`), ③ the Run-selected interpreter's stdlib and site-packages,
// derived from its install layout. Only files are read: the interpreter is
// located from what the Run module already knows (the custom path, the
// Karu-managed toolchain, the login-shell PATH *if it was already captured*)
// and is never executed. `.pth` files contribute their path lines only;
// `import` lines run code and are always ignored.

/// Finds the Run-selected Python interpreter's executable without running
/// anything: the same order as `ToolchainLocator` (custom → managed →
/// login-shell PATH), but the PATH search only uses an already captured
/// login PATH (no capture → no system interpreter: path ③ is unavailable),
/// and Apple's `/usr/bin` shims are skipped (their real layout is only known
/// by running them).
public struct PythonInterpreterDiscovery: Sendable {
    public var preference: RunToolPreference
    /// The managed toolchain's bin directory (reads its marker file only).
    public var managedBinDirectory: @Sendable () -> String?
    /// The login PATH if already captured.
    public var cachedLoginPath: @Sendable () -> String?

    public init(preference: RunToolPreference,
                managedBinDirectory: @escaping @Sendable () -> String?,
                cachedLoginPath: @escaping @Sendable () -> String?) {
        self.preference = preference
        self.managedBinDirectory = managedBinDirectory
        self.cachedLoginPath = cachedLoginPath
    }

    /// No interpreter (tests, or path ③ switched off).
    public static let none = PythonInterpreterDiscovery(preference: RunToolPreference(source: .custom),
                                                        managedBinDirectory: { nil }, cachedLoginPath: { nil })

    /// A fixed executable (tests).
    public static func fixed(_ path: String) -> PythonInterpreterDiscovery {
        PythonInterpreterDiscovery(preference: RunToolPreference(source: .custom, customPath: path),
                                   managedBinDirectory: { nil }, cachedLoginPath: { nil })
    }

    /// The app's: Run settings, Karu-managed toolchains, the shared login PATH.
    @MainActor
    public static func runSelected(settings: RunSettings = RunSettings()) -> PythonInterpreterDiscovery {
        PythonInterpreterDiscovery(preference: settings.preference(for: .python),
                                   managedBinDirectory: { KaruManagedToolchains().toolchain(for: .python)?.binDirectory.path },
                                   cachedLoginPath: { LoginShellPath.shared.cachedPathIfCaptured })
    }

    /// The executable's path, or nil.
    func executable(fs: ImportFileSystem) -> String? {
        func usable(_ path: String) -> Bool { path.hasPrefix("/") && fs.isFile(path) }
        let custom = preference.customPath.flatMap { usable($0) ? $0 : nil }
        switch preference.source {
        case .custom:
            return custom
        case .managed:
            return managed(fs)
        case .system:
            return loginPathInterpreter(fs)
        case .auto:
            return custom ?? managed(fs) ?? loginPathInterpreter(fs)
        }
    }

    private func managed(_ fs: ImportFileSystem) -> String? {
        guard let bin = managedBinDirectory() else { return nil }
        let tool = ImportPath.join(bin, "python3")
        return fs.isFile(tool) ? tool : nil
    }

    private func loginPathInterpreter(_ fs: ImportFileSystem) -> String? {
        guard let path = cachedLoginPath() else { return nil }
        var seen = Set<String>()
        for dir in path.split(separator: ":").map(String.init) where dir.hasPrefix("/") && seen.insert(dir).inserted {
            guard dir != "/usr/bin" else { continue }   // Apple shim: layout unknown without running it
            let candidate = ImportPath.join(dir, "python3")
            if fs.isFile(candidate) { return candidate }
        }
        return nil
    }
}

/// One directory modules are searched in.
struct PythonSearchRoot: Sendable, Hashable {
    enum Kind: Int, Sendable, Hashable {
        /// ① The project folder root.
        case project = 1
        /// ② The project's virtual environment (and its `.pth` paths).
        case venv = 2
        /// ③ The interpreter's stdlib / site-packages (and `.pth` paths).
        case interpreter = 3
    }
    let path: String
    let kind: Kind
    /// A `site-packages` directory (its mtime and its packages' validate
    /// cached summaries; plan §9 "失效").
    let isSitePackages: Bool
}

/// The ordered lookup roots of one document context.
struct PythonSearchPaths: Sendable, Equatable {
    var roots: [PythonSearchRoot] = []
    /// Directories whose mtime decides whether these paths are still valid
    /// (`pyvenv.cfg`'s directory, site-packages; `.pth` files live there).
    var validators: [String: Double] = [:]

    /// Derives the roots: `projectRoot` (nil without a project folder: no
    /// ① and no ②), then its venv, then the interpreter.
    static func derive(projectRoot: String?, interpreter: PythonInterpreterDiscovery,
                       fs: ImportFileSystem) -> PythonSearchPaths {
        var out = PythonSearchPaths()
        if let root = projectRoot {
            out.roots.append(PythonSearchRoot(path: root, kind: .project, isSitePackages: false))
            for name in [".venv", "venv"] {
                let venv = ImportPath.join(root, name)
                guard let cfg = readConfig(ImportPath.join(venv, "pyvenv.cfg"), fs) else { continue }
                for site in venvSitePackages(venv, config: cfg, fs: fs) {
                    out.addSitePackages(site, kind: .venv, allowedRoots: [root], fs: fs)
                }
                break
            }
        }
        if let executable = interpreter.executable(fs: fs) {
            let layout = PythonInterpreterLayout.derive(executable: executable, fs: fs)
            if let stdlib = layout.stdlib {
                out.roots.append(PythonSearchRoot(path: stdlib, kind: .interpreter, isSitePackages: false))
            }
            for site in layout.sitePackages {
                out.addSitePackages(site, kind: .interpreter, allowedRoots: layout.prefixes, fs: fs)
            }
        }
        return out
    }

    /// Adds a site-packages directory and the path lines of its `.pth`
    /// files (alphabetical, as `site` processes them). `import` lines are
    /// skipped; paths in privacy-protected home folders are skipped unless
    /// inside `allowedRoots`.
    mutating func addSitePackages(_ site: String, kind: PythonSearchRoot.Kind, allowedRoots: [String],
                                  fs: ImportFileSystem) {
        guard let info = fs.info(site), info.isDirectory,
              !roots.contains(where: { $0.path == site }) else { return }
        roots.append(PythonSearchRoot(path: site, kind: kind, isSitePackages: true))
        validators[site] = info.modificationTime
        let pthFiles = (fs.list(site) ?? []).filter { $0.hasSuffix(".pth") }.sorted()
        for name in pthFiles {
            for line in Self.pthPathLines(fs.contents(ImportPath.join(site, name))) {
                let path = ImportPath.normalized(line.hasPrefix("/") ? line : ImportPath.join(site, line))
                let allowed = allowedRoots.contains { ImportPath.isInside(path, $0) } || !ImportPath.isPrivacyProtected(path)
                guard allowed, fs.isDirectory(path), !roots.contains(where: { $0.path == path }) else { continue }
                roots.append(PythonSearchRoot(path: path, kind: kind, isSitePackages: false))
            }
        }
    }

    /// The path lines of a `.pth` file: blank lines, comments and lines
    /// starting with `import` (executed by `site`) are dropped.
    static func pthPathLines(_ data: Data?) -> [String] {
        guard let data, let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return []
        }
        var out: [String] = []
        for raw in text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("import ") || line.hasPrefix("import\t") { continue }
            out.append(line)
        }
        return out
    }

    /// `key = value` lines of a `pyvenv.cfg`.
    static func readConfig(_ path: String, _ fs: ImportFileSystem) -> [String: String]? {
        guard let data = fs.contents(path), let text = String(data: data, encoding: .utf8) else { return nil }
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            out[key] = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        }
        return out
    }

    /// `<venv>/lib/python3.X/site-packages` (version from `pyvenv.cfg`, else
    /// every `lib/python3.*` directory).
    static func venvSitePackages(_ venv: String, config: [String: String], fs: ImportFileSystem) -> [String] {
        let lib = ImportPath.join(venv, "lib")
        var versions: [String] = []
        if let v = config["version_info"] ?? config["version"], let mm = majorMinor(v) { versions = ["python" + mm] }
        if versions.isEmpty || !fs.isDirectory(ImportPath.join(lib, versions[0])) {
            versions = PythonInterpreterLayout.pythonDirectories(in: lib, fs: fs)
        }
        return versions.map { ImportPath.join(ImportPath.join(lib, $0), "site-packages") }
    }

    /// `3.13` from `3.13.1` / `3.13.1.final.0`.
    static func majorMinor(_ version: String) -> String? {
        let parts = version.split(separator: ".")
        guard parts.count >= 2, Int(parts[0]) != nil, Int(parts[1]) != nil else { return nil }
        return parts[0] + "." + parts[1]
    }
}

/// An interpreter's install layout, from its executable's path:
/// `<prefix>/bin/python3[.X]` → `<prefix>/lib/python3.X` (stdlib) and its
/// `site-packages`. A venv interpreter (`<venv>/bin/python` next to
/// `pyvenv.cfg`) contributes its own site-packages, then its base's.
struct PythonInterpreterLayout: Sendable, Equatable {
    var stdlib: String?
    var sitePackages: [String] = []
    /// Install prefixes (reading inside them is always allowed).
    var prefixes: [String] = []

    static func derive(executable: String, fs: ImportFileSystem) -> PythonInterpreterLayout {
        var out = PythonInterpreterLayout()
        let unresolvedPrefix = ImportPath.parent(ImportPath.parent(executable))
        if let cfg = PythonSearchPaths.readConfig(ImportPath.join(unresolvedPrefix, "pyvenv.cfg"), fs) {
            out.prefixes.append(unresolvedPrefix)
            out.sitePackages += PythonSearchPaths.venvSitePackages(unresolvedPrefix, config: cfg, fs: fs)
        }
        let real = fs.realPath(executable)
        let prefix = ImportPath.parent(ImportPath.parent(real))
        out.prefixes.append(prefix)
        let lib = ImportPath.join(prefix, "lib")
        var name = ImportPath.lastComponent(real)
        if !(name.hasPrefix("python3.") && fs.isDirectory(ImportPath.join(lib, name))) {
            name = pythonDirectories(in: lib, fs: fs).last ?? ""
        }
        guard !name.isEmpty else { return out }
        let stdlib = ImportPath.join(lib, name)
        guard fs.isDirectory(stdlib) else { return out }
        out.stdlib = stdlib
        let site = ImportPath.join(stdlib, "site-packages")
        if fs.isDirectory(site) { out.sitePackages.append(site) }
        return out
    }

    /// `python3.N` directories of `lib`, ascending by minor version.
    static func pythonDirectories(in lib: String, fs: ImportFileSystem) -> [String] {
        (fs.list(lib) ?? []).compactMap { entry -> (Int, String)? in
            guard entry.hasPrefix("python3."), let minor = Int(entry.dropFirst("python3.".count)) else { return nil }
            return (minor, entry)
        }.sorted { $0.0 < $1.0 }.map(\.1)
    }
}
