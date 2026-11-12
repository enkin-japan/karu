import Foundation
import Testing
@testable import KaruCore

// Plan building (argv, file names, cwd, env) and the temp workspace lifecycle.

private func scratchRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("KaruRunPlanTests-\(UUID().uuidString)", isDirectory: true)
}

private let runID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AB")!

private func tool(_ exe: String, _ lead: [String] = [], path: String = "/opt/homebrew/bin:/usr/bin:/bin",
                  env: [String: String] = [:], origin: ToolOrigin = .loginPath) -> ResolvedTool {
    ResolvedTool(executable: exe, leadingArguments: lead, origin: origin, searchPath: path, environment: env)
}

@Suite("Run plan builder")
struct RunPlanBuilderTests {
    let root = URL(fileURLWithPath: "/tmp/KaruRunRoot", isDirectory: true)
    var builder: RunPlanBuilder { RunPlanBuilder(workspaceRoot: root, baseEnvironment: ["HOME": "/Users/u"]) }
    var dir: String { root.appendingPathComponent(runID.uuidString).path }

    private func plan(_ language: RunnableLanguage, _ text: String = "x", tool t: ResolvedTool,
                      flags: [String] = [], document: URL? = nil) -> RunPlan {
        builder.makePlan(language: language, text: text, documentURL: document, tool: t,
                         preference: RunToolPreference(extraFlags: flags), runID: runID)
    }

    @Test func workspaceIsPerRunUUIDUnderRoot() {
        let p = plan(.python, tool: tool("/usr/bin/python3"))
        #expect(p.directory.path == dir)
        #expect(RunWorkspace.defaultRoot.path.hasSuffix("/Karu-Run"))
        #expect(RunWorkspace.defaultRoot.deletingLastPathComponent().standardizedFileURL
                == FileManager.default.temporaryDirectory.standardizedFileURL)
    }

    @Test func interpretedLanguages() {
        let py = plan(.python, tool: tool("/opt/homebrew/bin/python3"))
        #expect(py.run.argv == ["/opt/homebrew/bin/python3", "-u", "\(dir)/main.py"])
        #expect(py.compile == nil)
        #expect(plan(.javascript, tool: tool("/n/node")).run.argv == ["/n/node", "\(dir)/main.js"])
        #expect(plan(.typescript, tool: tool("/n/node")).run.argv == ["/n/node", "\(dir)/main.ts"])
        let go = plan(.go, tool: tool("/g/go"))
        #expect(go.compile?.argv == ["/g/go", "build", "-o", "\(dir)/a.out", "\(dir)/main.go"])
        #expect(go.compile?.workingDirectory.path == dir)
        #expect(go.run.argv == ["\(dir)/a.out"])
        #expect(plan(.csharp, tool: tool("/d/dotnet")).run.argv == ["/d/dotnet", "run", "\(dir)/main.cs"])
    }

    @Test func bashUsesResolvedShellAndShebangFlags() {
        #expect(plan(.bash, tool: tool("/bin/bash", origin: .fixed)).run.argv == ["/bin/bash", "\(dir)/main.sh"])
        #expect(plan(.bash, "#!/bin/zsh -e\n", tool: tool("/bin/zsh", ["-e"], origin: .fixed)).run.argv
                == ["/bin/zsh", "-e", "\(dir)/main.sh"])
    }

    @Test func javaFileNameFollowsPublicClass() {
        let java = plan(.java, "import java.util.*;\npublic final class Hello {\n}", tool: tool("/j/java"))
        #expect(java.sourceFileName == "Hello.java")
        #expect(java.run.argv == ["/j/java", "\(dir)/Hello.java"])
        #expect(RunPlanBuilder.javaPublicClass(in: "public abstract final class A_1 {}") == "A_1")
        #expect(RunPlanBuilder.javaPublicClass(in: "class Helper {}\npublic class Main2 {}") == "Main2")
        #expect(plan(.java, "class Foo { }", tool: tool("/j/java")).sourceFileName == "Main.java")
        #expect(RunPlanBuilder.javaPublicClass(in: "public interface X {}") == nil)
    }

    @Test func cCompilesWithClangThenRunsBinary() {
        let c = plan(.c, tool: tool("/usr/bin/clang"), flags: ["-Wall", "-lm"])
        #expect(c.compile?.argv == ["/usr/bin/clang", "-O0", "-Wall", "-lm", "\(dir)/main.c", "-o", "\(dir)/a.out"])
        #expect(c.compile?.workingDirectory.path == dir)
        #expect(c.run.argv == ["\(dir)/a.out"])
    }

    @Test func cWithZig() {
        let c = plan(.c, tool: tool("/K/zig", ["cc", "-target", "aarch64-macos"], origin: .managed))
        #expect(c.compile?.argv == ["/K/zig", "cc", "-target", "aarch64-macos", "-O0",
                                    "\(dir)/main.c", "-o", "\(dir)/a.out"])
    }

    @Test func cppDefaultsToCpp20UnlessOverridden() {
        let cpp = plan(.cpp, tool: tool("/usr/bin/clang++"))
        #expect(cpp.sourceFileName == "main.cpp")
        #expect(cpp.compile?.argv == ["/usr/bin/clang++", "-O0", "-std=c++20", "\(dir)/main.cpp", "-o", "\(dir)/a.out"])
        let cpp17 = plan(.cpp, tool: tool("/usr/bin/clang++"), flags: ["-std=c++17"])
        #expect(cpp17.compile?.argv == ["/usr/bin/clang++", "-O0", "-std=c++17", "\(dir)/main.cpp", "-o", "\(dir)/a.out"])
    }

    @Test func swiftAndRustCompile() {
        let swift = plan(.swift, tool: tool("/usr/bin/swiftc"))
        #expect(swift.compile?.argv == ["/usr/bin/swiftc", "\(dir)/main.swift", "-o", "\(dir)/a.out"])
        #expect(swift.run.argv == ["\(dir)/a.out"])
        let rust = plan(.rust, tool: tool("/c/rustc"))
        #expect(rust.compile?.argv == ["/c/rustc", "--edition", "2021", "\(dir)/main.rs", "-o", "\(dir)/a.out"])
    }

    @Test func extraFlagsOnlyApplyToCFamily() {
        let py = plan(.python, tool: tool("/p/python3"), flags: ["-Wall"])
        #expect(!py.run.arguments.contains("-Wall"))
    }

    @Test func lineEndingsAreNormalizedToLF() {
        let p = plan(.python, "a\r\nb\rc\n", tool: tool("/p/python3"))
        #expect(p.sourceText == "a\nb\nc\n")
        #expect(RunPlanBuilder.normalizeLineEndings("x\r\n\r\ny") == "x\n\ny")
        #expect(RunPlanBuilder.normalizeLineEndings("plain\n") == "plain\n")
    }

    @Test func workingDirectoryIsDocumentParentWhenSaved() throws {
        let docDir = scratchRoot()
        try FileManager.default.createDirectory(at: docDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: docDir) }
        let doc = docDir.appendingPathComponent("script.py")

        let saved = plan(.python, tool: tool("/p/python3"), document: doc)
        #expect(saved.run.workingDirectory.standardizedFileURL == docDir.standardizedFileURL)
        // The temp snapshot runs, never the on-disk document.
        #expect(saved.run.arguments.last == "\(dir)/main.py")

        let unsaved = plan(.python, tool: tool("/p/python3"))
        #expect(unsaved.run.workingDirectory.path == dir)

        let gone = plan(.python, tool: tool("/p/python3"),
                        document: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/x.py"))
        #expect(gone.run.workingDirectory.path == dir)

        let compiled = plan(.c, tool: tool("/usr/bin/clang"), document: doc)
        #expect(compiled.compile?.workingDirectory.path == dir)
        #expect(compiled.run.workingDirectory.standardizedFileURL == docDir.standardizedFileURL)
    }

    @Test func environmentContents() {
        let base = ["HOME": "/Users/u", "PATH": "/usr/bin:/bin", "KARU_DIAGNOSTIC_DIRECTORY": "/x",
                    "KARU_SNAPSHOT": "/y", "TERM": "xterm-256color", "LANG": "ja_JP.UTF-8", "KARUISH": "keep"]
        let b = RunPlanBuilder(workspaceRoot: root, baseEnvironment: base)
        let managed = tool("/K/go/bin/go", path: "/K/go/bin:/opt/homebrew/bin",
                           env: ["GOCACHE": "/K/cache/go", "GOPATH": "/K/gopath", "NO_COLOR": "managed"],
                           origin: .managed)
        let env = b.makePlan(language: .go, text: "", documentURL: nil, tool: managed,
                             preference: .init(), runID: runID).environment

        #expect(env["KARU_DIAGNOSTIC_DIRECTORY"] == nil)
        #expect(env["KARU_SNAPSHOT"] == nil)
        #expect(env["KARUISH"] == "keep")
        #expect(env["HOME"] == "/Users/u")
        #expect(env["PATH"] == "/K/go/bin:/opt/homebrew/bin")
        #expect(env["PYTHONUNBUFFERED"] == "1")
        #expect(env["PYTHONIOENCODING"] == "utf-8")
        #expect(env["TERM"] == "dumb")
        #expect(env["DOTNET_CLI_TELEMETRY_OPTOUT"] == "1")
        #expect(env["DOTNET_NOLOGO"] == "1")
        #expect(env["GOCACHE"] == "/K/cache/go")
        #expect(env["GOPATH"] == "/K/gopath")
        #expect(env["NO_COLOR"] == "managed") // managed overrides win
        #expect(env["LANG"] == "ja_JP.UTF-8") // existing locale kept
    }

    @Test func environmentAddsUTF8LocaleOnlyWhenMissing() {
        let env = RunPlanBuilder.environment(base: ["HOME": "/h"], tool: tool("/x"))
        #expect(env["LANG"] == "en_US.UTF-8")
        #expect(env["NO_COLOR"] == "1")
        let withCtype = RunPlanBuilder.environment(base: ["LC_CTYPE": "UTF-8"], tool: tool("/x"))
        #expect(withCtype["LANG"] == nil)
    }
}

@Suite("Run workspace", .serialized)
struct RunWorkspaceTests {
    @Test func prepareWritesUTF8LFSourceAndCleanupRemoves() throws {
        let root = scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let builder = RunPlanBuilder(workspaceRoot: root, baseEnvironment: [:])
        let plan = builder.makePlan(language: .python, text: "print('中文')\r\nprint(1)\r\n", documentURL: nil,
                                    tool: tool("/p/python3"), preference: .init())
        try RunWorkspace.prepare(plan)
        let data = try Data(contentsOf: plan.sourceURL)
        #expect(data == Data("print('中文')\nprint(1)\n".utf8))
        #expect(plan.directory.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL)

        RunWorkspace.cleanup(plan)
        #expect(!FileManager.default.fileExists(atPath: plan.directory.path))
    }

    @Test func purgeStaleRemovesOnlyOldDirectories() throws {
        let root = scratchRoot()
        let fm = FileManager.default
        defer { try? fm.removeItem(at: root) }
        let old = root.appendingPathComponent(UUID().uuidString)
        let fresh = root.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try fm.createDirectory(at: fresh, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: old.appendingPathComponent("a.out"))
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3 * 86_400)], ofItemAtPath: old.path)

        #expect(RunWorkspace.purgeStale(olderThan: 86_400, root: root) == 1)
        #expect(!fm.fileExists(atPath: old.path))
        #expect(fm.fileExists(atPath: fresh.path))
        // Missing root is harmless.
        #expect(RunWorkspace.purgeStale(olderThan: 0, root: root.appendingPathComponent("nope")) == 0)
    }

    @Test func preparerResolvesBuildsAndWrites() throws {
        let root = scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let locator = ToolchainLocator(
            loginPath: LoginShellPath(shell: "/bin/zsh") { _, _, _ in nil },
            probes: ToolchainProbes(isExecutable: { _ in false },
                                    developerToolsInstalled: { false }, javaRuntimeInstalled: { false }))
        let preparer = RunPreparer(locator: locator, builder: RunPlanBuilder(workspaceRoot: root, baseEnvironment: [:]))

        let plan = try preparer.prepare(language: .bash, text: "echo hi\r\n", documentURL: nil, preference: .init()).get()
        #expect(plan.run.argv == ["/bin/bash", plan.sourceURL.path])
        #expect(try String(contentsOf: plan.sourceURL, encoding: .utf8) == "echo hi\n")
        #expect(plan.environment["PATH"] == LoginShellPath.defaultPath)

        #expect(preparer.prepare(language: .go, text: "", documentURL: nil, preference: .init())
                == .failure(.toolNotFound("go")))
    }
}
