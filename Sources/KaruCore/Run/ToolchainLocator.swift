import Foundation

// MARK: - Managed toolchains (T16.5 hook)

/// A Karu-installed toolchain for one language: the directory holding its
/// executables plus environment overrides for child processes (T16.5 uses the
/// latter to redirect GOPATH / GOCACHE / npm / pip / NuGet / Zig caches into
/// Karu's own directory).
public struct ManagedToolchain: Equatable, Sendable {
    public var binDirectory: URL
    public var environment: [String: String]
    /// Extra overrides for the compile step only (e.g. Go's HOME, so its local
    /// telemetry lands in Karu's cache instead of ~/Library/Application Support
    /// without changing HOME for the user's program).
    public var compileEnvironment: [String: String]

    public init(binDirectory: URL, environment: [String: String] = [:],
                compileEnvironment: [String: String] = [:]) {
        self.binDirectory = binDirectory
        self.environment = environment
        self.compileEnvironment = compileEnvironment
    }
}

/// Supplies Karu-managed toolchains. For C / C++ a provider supplies the
/// directory containing `zig` (used as `zig cc` / `zig c++`). Implementations
/// must be cheap and thread-safe: the locator calls this off the main thread.
public protocol ManagedToolchainProvider: Sendable {
    func toolchain(for language: RunnableLanguage) -> ManagedToolchain?
}

/// A provider that never has anything installed (tests; the app default is
/// `KaruManagedToolchains`).
public struct NoManagedToolchains: ManagedToolchainProvider {
    public init() {}
    public func toolchain(for language: RunnableLanguage) -> ManagedToolchain? { nil }
}

// MARK: - Login-shell PATH

/// The user's login-shell PATH. GUI apps inherit launchd's minimal PATH, so it
/// is captured once — lazily, on first use — by running `$SHELL -l -c` and
/// reading PATH between unique markers (profile output such as banners is
/// ignored). 3-second timeout; any failure falls back to the default system
/// PATH. The value is cached for the object's lifetime (the shared instance:
/// the app's lifetime). Thread-safe; the first access blocks its caller for up
/// to `timeout`, so resolve tools off the main thread.
public final class LoginShellPath: @unchecked Sendable {
    /// Runs `shell` with `arguments` and returns its stdout, or `nil` on
    /// failure / timeout. Injected in tests so the real login shell never runs.
    public typealias Runner = @Sendable (_ shell: String, _ arguments: [String], _ timeout: TimeInterval) -> String?

    public static let shared = LoginShellPath()
    public static let defaultPath = "/usr/bin:/bin:/usr/sbin:/sbin"
    public static let beginMarker = "__KARU_LOGIN_PATH_BEGIN_7F3A__"
    public static let endMarker = "__KARU_LOGIN_PATH_END_7F3A__"

    /// The `-c` script. `printf` with `"$PATH"` works in sh/bash/zsh and fish
    /// (fish joins path variables with ':' when quoted).
    public static let script = "printf '%s%s%s' '\(beginMarker)' \"$PATH\" '\(endMarker)'"

    private let shell: String
    private let timeout: TimeInterval
    private let runner: Runner
    private let lock = NSLock()
    private var cached: String?
    private var captured = false

    /// - Parameter shell: the login shell; defaults to `$SHELL`, falling back
    ///   to `/bin/zsh` when unset or not an absolute path.
    public init(shell: String? = ProcessInfo.processInfo.environment["SHELL"],
                timeout: TimeInterval = 3,
                runner: @escaping Runner = LoginShellPath.spawnRunner) {
        if let shell, shell.hasPrefix("/") { self.shell = shell } else { self.shell = "/bin/zsh" }
        self.timeout = timeout
        self.runner = runner
    }

    /// The captured PATH, or `defaultPath` when capture failed.
    public var path: String {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let output = runner(shell, ["-l", "-c", Self.script], timeout)
        if let output, let parsed = Self.parse(output) {
            cached = parsed
            captured = true
        } else {
            cached = Self.defaultPath
        }
        return cached!
    }

    /// Whether `path` came from the login shell (false = fallback). Forces
    /// the capture if it has not happened yet.
    public var didCapture: Bool {
        _ = path
        lock.lock(); defer { lock.unlock() }
        return captured
    }

    /// Extracts PATH from shell output: text between the first begin marker
    /// and the following end marker, trimmed; `nil` if absent or empty.
    public static func parse(_ output: String) -> String? {
        guard let begin = output.range(of: beginMarker),
              let end = output.range(of: endMarker, range: begin.upperBound..<output.endIndex) else { return nil }
        let value = output[begin.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Production runner: spawns the shell in its own process group.
    public static let spawnRunner: Runner = { shell, arguments, timeout in
        guard let result = SyncCommand.run(shell, arguments, timeout: timeout),
              result.termination.isSuccess else { return nil }
        return result.stdout
    }
}

// MARK: - Probes

/// File-system and Apple-stub probes, injectable so tests never execute real
/// tools. Probes are only consulted when a resolved tool is an Apple shim.
public struct ToolchainProbes: Sendable {
    public var isExecutable: @Sendable (String) -> Bool
    /// `xcode-select -p` succeeds and the printed directory exists.
    public var developerToolsInstalled: @Sendable () -> Bool
    /// `/usr/libexec/java_home` exits 0.
    public var javaRuntimeInstalled: @Sendable () -> Bool

    public init(isExecutable: @escaping @Sendable (String) -> Bool,
                developerToolsInstalled: @escaping @Sendable () -> Bool,
                javaRuntimeInstalled: @escaping @Sendable () -> Bool) {
        self.isExecutable = isExecutable
        self.developerToolsInstalled = developerToolsInstalled
        self.javaRuntimeInstalled = javaRuntimeInstalled
    }

    public static let system = ToolchainProbes(
        isExecutable: { path in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
                && !isDir.boolValue && FileManager.default.isExecutableFile(atPath: path)
        },
        developerToolsInstalled: {
            guard let result = SyncCommand.run("/usr/bin/xcode-select", ["-p"], timeout: 3),
                  result.termination.isSuccess else { return false }
            let dir = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            var isDir: ObjCBool = false
            return !dir.isEmpty && FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) && isDir.boolValue
        },
        javaRuntimeInstalled: {
            SyncCommand.run("/usr/libexec/java_home", [], timeout: 3)?.termination.isSuccess ?? false
        }
    )
}

// MARK: - Resolution result

/// Where a resolved tool came from.
public enum ToolOrigin: String, Sendable {
    case custom, managed, loginPath, systemPath
    /// A fixed absolute interpreter (`/bin/bash`, or a shebang's absolute path).
    case fixed
}

/// A located tool, ready for the plan builder.
public struct ResolvedTool: Equatable, Sendable {
    /// Absolute path of the executable.
    public var executable: String
    /// Arguments that precede the language-specific ones (e.g. `zig`'s
    /// `["cc", "-target", "aarch64-macos"]`, or a shebang's `-e`).
    public var leadingArguments: [String]
    public var origin: ToolOrigin
    /// PATH for the child process (managed bin dir first when managed).
    public var searchPath: String
    /// Extra environment from the managed provider (empty otherwise).
    public var environment: [String: String]
    /// Managed overrides applied to the compile step only.
    public var compileEnvironment: [String: String]

    public init(executable: String, leadingArguments: [String] = [], origin: ToolOrigin,
                searchPath: String, environment: [String: String] = [:],
                compileEnvironment: [String: String] = [:]) {
        self.executable = executable
        self.leadingArguments = leadingArguments
        self.origin = origin
        self.searchPath = searchPath
        self.environment = environment
        self.compileEnvironment = compileEnvironment
    }
}

// MARK: - Locator

/// Resolves the executable for a language (ARCHITECTURE.md §6 "工具链来源").
///
/// Order under `.auto`: (a) the custom absolute path if set and executable;
/// (b) the managed provider; (c) the login-shell PATH; (d) the default system
/// PATH. `.custom` / `.managed` / `.system` restrict to (a) / (b) / (c)+(d).
///
/// Apple shims: a `/usr/bin` python3 / clang / clang++ / swiftc / swift / git /
/// cc / c++ is only accepted when developer tools are installed, and
/// `/usr/bin/java` / `javac` only when `java_home` succeeds — checked *before*
/// the tool is ever run, so the system install dialog is never triggered. A
/// rejected shim during a PATH search is skipped in favour of a later entry.
///
/// May block (first login-PATH capture, probes): call off the main thread.
public struct ToolchainLocator: Sendable {
    public static let developerShims: Set<String> = ["python3", "clang", "clang++", "swiftc", "swift", "git", "cc", "c++"]
    public static let javaShims: Set<String> = ["java", "javac"]

    public var managed: any ManagedToolchainProvider
    public var loginPath: LoginShellPath
    public var probes: ToolchainProbes
    /// `aarch64` or `x86_64`, for `zig cc -target <arch>-macos`.
    public var hostArchitecture: String

    public init(managed: any ManagedToolchainProvider = KaruManagedToolchains(),
                loginPath: LoginShellPath = .shared,
                probes: ToolchainProbes = .system,
                hostArchitecture: String = ToolchainLocator.currentHostArchitecture) {
        self.managed = managed
        self.loginPath = loginPath
        self.probes = probes
        self.hostArchitecture = hostArchitecture
    }

    public static var currentHostArchitecture: String {
        #if arch(arm64)
        return "aarch64"
        #else
        return "x86_64"
        #endif
    }

    /// The tool name searched for a language (C → clang, C++ → clang++).
    public static func toolName(for language: RunnableLanguage) -> String {
        switch language {
        case .python: return "python3"
        case .javascript, .typescript: return "node"
        case .bash: return "bash"
        case .c: return "clang"
        case .cpp: return "clang++"
        case .swift: return "swiftc"
        case .go: return "go"
        case .rust: return "rustc"
        case .java: return "java"
        case .csharp: return "dotnet"
        }
    }

    /// Resolves the tool for `language`. `text` is only consulted for Bash
    /// (a `#!` line naming sh / bash / zsh picks that shell).
    public func resolve(_ language: RunnableLanguage, preference: RunToolPreference,
                        text: String = "") -> Result<ResolvedTool, RunFailure> {
        if language == .bash { return resolveShell(preference: preference, text: text) }
        let name = Self.toolName(for: language)

        switch preference.source {
        case .custom:
            return resolveCustom(language, preference.customPath, failIfInvalid: true)!
        case .managed:
            return resolveManaged(language, name: name) ?? .failure(.toolchainNotInstalled(language.identifier))
        case .system:
            return searchSystem(name)
        case .auto:
            if let custom = resolveCustom(language, preference.customPath, failIfInvalid: false) { return custom }
            if let managed = resolveManaged(language, name: name) { return managed }
            return searchSystem(name)
        }
    }

    // MARK: Custom / managed

    private func resolveCustom(_ language: RunnableLanguage, _ path: String?,
                               failIfInvalid: Bool) -> Result<ResolvedTool, RunFailure>? {
        guard let path, path.hasPrefix("/"), probes.isExecutable(path) else {
            return failIfInvalid ? .failure(.customToolInvalid(path ?? "")) : nil
        }
        let name = (path as NSString).lastPathComponent
        if let failure = shimFailure(path: path, name: name) { return .failure(failure) }
        var leading: [String] = []
        if name == "zig", let mode = zigMode(language) { leading = mode }
        return .success(ResolvedTool(executable: path, leadingArguments: leading,
                                     origin: .custom, searchPath: loginPath.path))
    }

    private func resolveManaged(_ language: RunnableLanguage, name: String) -> Result<ResolvedTool, RunFailure>? {
        guard let toolchain = managed.toolchain(for: language) else { return nil }
        let bin = toolchain.binDirectory.path
        let searchPath = bin + ":" + loginPath.path
        if let mode = zigMode(language) {
            let zig = (bin as NSString).appendingPathComponent("zig")
            guard probes.isExecutable(zig) else { return nil }
            return .success(ResolvedTool(executable: zig, leadingArguments: mode, origin: .managed,
                                         searchPath: searchPath, environment: toolchain.environment,
                                         compileEnvironment: toolchain.compileEnvironment))
        }
        let tool = (bin as NSString).appendingPathComponent(name)
        guard probes.isExecutable(tool) else { return nil }
        return .success(ResolvedTool(executable: tool, origin: .managed,
                                     searchPath: searchPath, environment: toolchain.environment,
                                     compileEnvironment: toolchain.compileEnvironment))
    }

    private func zigMode(_ language: RunnableLanguage) -> [String]? {
        switch language {
        case .c: return ["cc", "-target", "\(hostArchitecture)-macos"]
        case .cpp: return ["c++", "-target", "\(hostArchitecture)-macos"]
        default: return nil
        }
    }

    // MARK: System PATH search

    /// Searches the login PATH, then any default-PATH entries it lacks.
    func searchSystem(_ name: String) -> Result<ResolvedTool, RunFailure> {
        let login = loginPath.path
        let loginDirs = login.split(separator: ":").map(String.init)
        let defaultDirs = LoginShellPath.defaultPath.split(separator: ":").map(String.init)
        var seen = Set<String>()
        var rejected: RunFailure?
        for (dir, origin) in loginDirs.map({ ($0, ToolOrigin.loginPath) }) + defaultDirs.map({ ($0, ToolOrigin.systemPath) }) {
            guard dir.hasPrefix("/"), seen.insert(dir).inserted else { continue }
            let candidate = (dir as NSString).appendingPathComponent(name)
            guard probes.isExecutable(candidate) else { continue }
            if let failure = shimFailure(path: candidate, name: name) {
                if rejected == nil { rejected = failure }
                continue
            }
            return .success(ResolvedTool(executable: candidate, origin: origin, searchPath: login))
        }
        return .failure(rejected ?? .toolNotFound(name))
    }

    /// Non-nil when `path` is an Apple `/usr/bin` shim whose backing tools are
    /// absent. Never executes `path` itself.
    func shimFailure(path: String, name: String) -> RunFailure? {
        guard (path as NSString).deletingLastPathComponent == "/usr/bin" else { return nil }
        if Self.developerShims.contains(name) {
            return probes.developerToolsInstalled() ? nil : .developerToolsMissing(name)
        }
        if Self.javaShims.contains(name) {
            return probes.javaRuntimeInstalled() ? nil : .javaRuntimeMissing
        }
        return nil
    }

    // MARK: Bash / shebang shells

    private func resolveShell(preference: RunToolPreference, text: String) -> Result<ResolvedTool, RunFailure> {
        if preference.source == .custom {
            return resolveCustom(.bash, preference.customPath, failIfInvalid: true)!
        }
        if preference.source == .auto, let custom = resolveCustom(.bash, preference.customPath, failIfInvalid: false) {
            return custom
        }
        guard let shebang = ShellShebang.parse(text) else {
            return .success(ResolvedTool(executable: "/bin/bash", origin: .fixed, searchPath: loginPath.path))
        }
        if shebang.interpreter.hasPrefix("/"), probes.isExecutable(shebang.interpreter) {
            return .success(ResolvedTool(executable: shebang.interpreter, leadingArguments: shebang.arguments,
                                         origin: .fixed, searchPath: loginPath.path))
        }
        let name = (shebang.interpreter as NSString).lastPathComponent
        switch searchSystem(name) {
        case .success(var tool):
            tool.leadingArguments = shebang.arguments
            return .success(tool)
        case .failure(let failure):
            return .failure(failure)
        }
    }
}

/// A `#!` line naming sh / bash / zsh, either directly (`#!/bin/zsh -e`) or
/// via env (`#!/usr/bin/env bash`, `#!/usr/bin/env -S bash -x`).
public struct ShellShebang: Equatable, Sendable {
    public static let shells: Set<String> = ["sh", "bash", "zsh"]

    /// Absolute path (`/bin/zsh`) or bare name when invoked through env (`bash`).
    public var interpreter: String
    /// Interpreter options from the shebang (e.g. `-e`).
    public var arguments: [String]

    public static func parse(_ text: String) -> ShellShebang? {
        guard text.hasPrefix("#!") else { return nil }
        let firstLine = text.dropFirst(2).prefix { !$0.isNewline }
        var words = firstLine.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard !words.isEmpty else { return nil }
        var interpreter = words.removeFirst()
        if (interpreter as NSString).lastPathComponent == "env" {
            // Skip env options (-S, -i, …) and VAR=value assignments.
            while let next = words.first, next.hasPrefix("-") || next.contains("=") { words.removeFirst() }
            guard !words.isEmpty else { return nil }
            interpreter = words.removeFirst()
        }
        guard shells.contains((interpreter as NSString).lastPathComponent) else { return nil }
        return ShellShebang(interpreter: interpreter, arguments: words.filter { $0.hasPrefix("-") })
    }
}
