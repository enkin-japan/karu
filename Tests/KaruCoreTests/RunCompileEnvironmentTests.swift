import Foundation
import Testing
@testable import KaruCore

/// Compile-step-only environment (T16.5 real-network finding): Go's local
/// telemetry and NuGet's migration marker must not land in global user dirs.
@Suite struct RunCompileEnvironmentTests {
    @Test func builderAppliesCompileOverridesToCompileStepOnly() {
        let root = URL(fileURLWithPath: "/tmp/karu-ws")
        let builder = RunPlanBuilder(workspaceRoot: root, baseEnvironment: ["HOME": "/Users/me", "PATH": "/usr/bin"])
        let tool = ResolvedTool(executable: "/K/go/bin/go", origin: .managed, searchPath: "/K/go/bin:/usr/bin",
                                environment: ["GOPATH": "/K/cache/go/gopath"],
                                compileEnvironment: ["HOME": "/K/cache/go/home"])
        let plan = builder.makePlan(language: .go, text: "package main\nfunc main() {}\n", documentURL: nil,
                                    tool: tool, preference: .init())
        #expect(plan.compile?.environmentOverrides == ["HOME": "/K/cache/go/home"])
        #expect(plan.run.environmentOverrides.isEmpty)
        #expect(plan.environment["HOME"] == "/Users/me")
        #expect(plan.environment["GOPATH"] == "/K/cache/go/gopath")
    }

    @Test func managedProviderRedirectsGoHomeAndDotnetDataHome() {
        let cache = URL(fileURLWithPath: "/K/.cache/go")
        #expect(KaruManagedToolchains.compileEnvironment(id: "go", cacheDirectory: cache)
                == ["HOME": "/K/.cache/go/home"])
        for id in ["python", "node", "java", "dotnet", "zig"] {
            #expect(KaruManagedToolchains.compileEnvironment(id: id, cacheDirectory: cache).isEmpty)
        }
        let dotnetCache = URL(fileURLWithPath: "/K/.cache/dotnet")
        let env = KaruManagedToolchains.environment(id: "dotnet", binDirectory: URL(fileURLWithPath: "/K/dotnet/10"),
                                                    cacheDirectory: dotnetCache)
        #expect(env["XDG_DATA_HOME"] == "/K/.cache/dotnet/data")
    }

    @MainActor @Test func runnerMergesOverridesPerStep() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("karu-compile-env-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plan = RunPlan(language: .go, directory: dir, sourceFileName: "main.go", sourceText: "",
                           compile: RunCommand(executable: "/bin/sh", arguments: ["-c", "echo compile=$TV"],
                                               workingDirectory: dir, environmentOverrides: ["TV": "c"]),
                           run: RunCommand(executable: "/bin/sh", arguments: ["-c", "echo run=$TV"],
                                           workingDirectory: dir),
                           environment: ["PATH": "/usr/bin:/bin", "TV": "r"])
        let runner = CodeRunner()
        runner.cleansUpWorkspace = false
        var result: RunResult?
        runner.onFinish = { result = $0 }
        #expect(runner.start(plan))
        let deadline = Date().addingTimeInterval(10)
        while result == nil, Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        #expect(result?.completion == .finished(.exited(0)))
        #expect(runner.output.text.contains("compile=c"))
        #expect(runner.output.text.contains("run=r"))
    }
}
