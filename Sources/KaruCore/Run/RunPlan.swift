import Foundation

/// One process invocation: argv as an array (never a shell string).
public struct RunCommand: Equatable, Sendable {
    /// Absolute path of the executable (also argv[0]).
    public var executable: String
    /// argv[1...].
    public var arguments: [String]
    public var workingDirectory: URL
    /// Merged over `RunPlan.environment` for this step only.
    public var environmentOverrides: [String: String]

    public init(executable: String, arguments: [String], workingDirectory: URL,
                environmentOverrides: [String: String] = [:]) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environmentOverrides = environmentOverrides
    }

    public var argv: [String] { [executable] + arguments }
}

/// Everything needed to run one buffer snapshot. Produced by
/// `RunPlanBuilder`, materialised by `RunWorkspace.prepare`, executed by
/// `CodeRunner`.
public struct RunPlan: Equatable, Sendable {
    public var language: RunnableLanguage
    /// Per-run temp directory (`…/Karu-Run/<UUID>/`), removed after the run.
    public var directory: URL
    /// Source file name inside `directory` (e.g. `main.py`, `Hello.java`).
    public var sourceFileName: String
    /// Buffer snapshot, UTF-8, line endings normalised to LF.
    public var sourceText: String
    /// Optional compile step (C, C++, Swift, Rust, Go); runs in `directory`.
    public var compile: RunCommand?
    public var run: RunCommand
    public var environment: [String: String]

    public var sourceURL: URL { directory.appendingPathComponent(sourceFileName) }
    public var workingDirectory: URL { run.workingDirectory }
}

/// Builds a `RunPlan` from a resolved tool. Pure apart from one existence
/// check on the document's directory.
///
/// - The buffer snapshot is what runs — never the on-disk file; nothing is saved.
/// - Working directory: the saved document's parent directory, else the temp dir.
/// - Environment: the app's environment minus `KARU_*`, PATH = tool search
///   path (managed bin first when managed), plus fixed variables and the
///   managed provider's overrides.
public struct RunPlanBuilder: Sendable {
    public var workspaceRoot: URL
    public var baseEnvironment: [String: String]

    public init(workspaceRoot: URL = RunWorkspace.defaultRoot,
                baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) {
        self.workspaceRoot = workspaceRoot
        self.baseEnvironment = baseEnvironment
    }

    /// Variables always set for a run.
    public static let fixedEnvironment: [String: String] = [
        "PYTHONUNBUFFERED": "1",
        "PYTHONIOENCODING": "utf-8",
        "NO_COLOR": "1",
        "TERM": "dumb",
        "DOTNET_CLI_TELEMETRY_OPTOUT": "1",
        "DOTNET_NOLOGO": "1",
    ]

    public func makePlan(language: RunnableLanguage, text: String, documentURL: URL?,
                         tool: ResolvedTool, preference: RunToolPreference,
                         runID: UUID = UUID()) -> RunPlan {
        let dir = workspaceRoot.appendingPathComponent(runID.uuidString, isDirectory: true)
        let source = Self.normalizeLineEndings(text)
        let fileName = Self.sourceFileName(for: language, text: source)
        let srcPath = dir.appendingPathComponent(fileName).path
        let binary = dir.appendingPathComponent("a.out").path
        let cwd = Self.workingDirectory(documentURL: documentURL, fallback: dir)
        let exe = tool.executable
        let lead = tool.leadingArguments

        var compile: RunCommand?
        let run: RunCommand
        switch language {
        case .python:
            run = RunCommand(executable: exe, arguments: lead + ["-u", srcPath], workingDirectory: cwd)
        case .javascript, .typescript, .bash, .java:
            run = RunCommand(executable: exe, arguments: lead + [srcPath], workingDirectory: cwd)
        case .go:
            // Build in the temp dir (no go.mod there) rather than `go run` from the
            // document's directory, which fails inside an unrelated Go module.
            compile = RunCommand(executable: exe, arguments: lead + ["build", "-o", binary, srcPath],
                                 workingDirectory: dir)
            run = RunCommand(executable: binary, arguments: [], workingDirectory: cwd)
        case .csharp:
            run = RunCommand(executable: exe, arguments: lead + ["run", srcPath], workingDirectory: cwd)
        case .c, .cpp:
            var args = lead + ["-O0"]
            if language == .cpp, !preference.extraFlags.contains(where: { $0.hasPrefix("-std=") }) {
                args.append("-std=c++20")
            }
            args += preference.extraFlags + [srcPath, "-o", binary]
            compile = RunCommand(executable: exe, arguments: args, workingDirectory: dir)
            run = RunCommand(executable: binary, arguments: [], workingDirectory: cwd)
        case .swift:
            compile = RunCommand(executable: exe, arguments: lead + [srcPath, "-o", binary], workingDirectory: dir)
            run = RunCommand(executable: binary, arguments: [], workingDirectory: cwd)
        case .rust:
            compile = RunCommand(executable: exe, arguments: lead + ["--edition", "2021", srcPath, "-o", binary],
                                 workingDirectory: dir)
            run = RunCommand(executable: binary, arguments: [], workingDirectory: cwd)
        }

        compile?.environmentOverrides = tool.compileEnvironment
        return RunPlan(language: language, directory: dir, sourceFileName: fileName, sourceText: source,
                       compile: compile, run: run,
                       environment: Self.environment(base: baseEnvironment, tool: tool))
    }

    // MARK: Pieces (exposed for tests and T16.3b)

    public static func normalizeLineEndings(_ text: String) -> String {
        // Byte-level check: "\r\n" is a single Character, so `contains("\r")` misses it.
        guard text.utf8.contains(UInt8(ascii: "\r")) else { return text }
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    public static func sourceFileName(for language: RunnableLanguage, text: String) -> String {
        switch language {
        case .python: return "main.py"
        case .javascript: return "main.js"
        case .typescript: return "main.ts"
        case .bash: return "main.sh"
        case .c: return "main.c"
        case .cpp: return "main.cpp"
        case .swift: return "main.swift"
        case .go: return "main.go"
        case .rust: return "main.rs"
        case .java: return (javaPublicClass(in: text) ?? "Main") + ".java"
        case .csharp: return "main.cs"
        }
    }

    private static let javaClassRegex = try! NSRegularExpression(
        pattern: #"\bpublic\s+(?:(?:final|abstract)\s+)*class\s+([A-Za-z_$][\w$]*)"#)

    /// Name of the first `public [final|abstract] class X`, if any.
    public static func javaPublicClass(in text: String) -> String? {
        let ns = text as NSString
        guard let match = javaClassRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        return ns.substring(with: match.range(at: 1))
    }

    static func workingDirectory(documentURL: URL?, fallback: URL) -> URL {
        guard let url = documentURL, url.isFileURL else { return fallback }
        let parent = url.deletingLastPathComponent()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDir), isDir.boolValue else {
            return fallback
        }
        return parent
    }

    public static func environment(base: [String: String], tool: ResolvedTool) -> [String: String] {
        var env = base.filter { !$0.key.hasPrefix("KARU_") }
        env["PATH"] = tool.searchPath
        for (key, value) in fixedEnvironment { env[key] = value }
        // GUI apps often start without a locale; give children a UTF-8 one so
        // e.g. Java's stdout encoding does not degrade CJK text to "?".
        if env["LANG"] == nil, env["LC_ALL"] == nil, env["LC_CTYPE"] == nil {
            env["LANG"] = "en_US.UTF-8"
        }
        for (key, value) in tool.environment { env[key] = value }
        return env
    }
}

/// Temp-directory lifecycle for runs: `<tmp>/Karu-Run/<UUID>/`.
public enum RunWorkspace {
    public static var defaultRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Karu-Run", isDirectory: true)
    }

    /// Creates the plan's directory and writes the source (UTF-8, LF).
    public static func prepare(_ plan: RunPlan) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: plan.directory, withIntermediateDirectories: true)
        try Data(plan.sourceText.utf8).write(to: plan.sourceURL)
    }

    /// Removes a finished run's directory (errors ignored).
    public static func cleanup(_ plan: RunPlan) {
        try? FileManager.default.removeItem(at: plan.directory)
    }

    /// Removes leftover run directories (e.g. after a crash) whose
    /// modification date is older than `age`. Returns the number removed.
    @discardableResult
    public static func purgeStale(olderThan age: TimeInterval, root: URL = defaultRoot, now: Date = Date()) -> Int {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                                        options: [.skipsHiddenFiles]) else { return 0 }
        var removed = 0
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let modified, now.timeIntervalSince(modified) > age else { continue }
            if (try? fm.removeItem(at: entry)) != nil { removed += 1 }
        }
        return removed
    }
}

/// Convenience pipeline for T16.3b: resolve the tool, build the plan and
/// write the workspace. Blocking (login-PATH capture, probes, file I/O) —
/// call it off the main thread, e.g. `Task.detached { preparer.prepare(...) }`.
public struct RunPreparer: Sendable {
    public var locator: ToolchainLocator
    public var builder: RunPlanBuilder

    public init(locator: ToolchainLocator = ToolchainLocator(), builder: RunPlanBuilder = RunPlanBuilder()) {
        self.locator = locator
        self.builder = builder
    }

    public func prepare(language: RunnableLanguage, text: String, documentURL: URL?,
                        preference: RunToolPreference) -> Result<RunPlan, RunFailure> {
        let tool: ResolvedTool
        switch locator.resolve(language, preference: preference, text: text) {
        case .success(let resolved): tool = resolved
        case .failure(let failure): return .failure(failure)
        }
        let plan = builder.makePlan(language: language, text: text, documentURL: documentURL,
                                    tool: tool, preference: preference)
        do {
            try RunWorkspace.prepare(plan)
        } catch {
            return .failure(.workspaceFailed(error.localizedDescription))
        }
        return .success(plan)
    }
}
