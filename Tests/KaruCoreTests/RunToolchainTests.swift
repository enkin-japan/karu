import Foundation
import Testing
@testable import KaruCore

// Toolchain resolution with an injected file system, probes and login-shell
// runner: no real tool (and no real login shell) is ever executed here.

/// Records probe invocations from any thread.
private final class ProbeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _developer = 0
    private var _java = 0
    private var _shell: [(String, [String])] = []
    var developer: Int { lock.lock(); defer { lock.unlock() }; return _developer }
    var java: Int { lock.lock(); defer { lock.unlock() }; return _java }
    var shellCalls: [(String, [String])] { lock.lock(); defer { lock.unlock() }; return _shell }
    func noteDeveloper() { lock.lock(); _developer += 1; lock.unlock() }
    func noteJava() { lock.lock(); _java += 1; lock.unlock() }
    func noteShell(_ shell: String, _ args: [String]) { lock.lock(); _shell.append((shell, args)); lock.unlock() }
}

private struct FakeManaged: ManagedToolchainProvider {
    var toolchains: [RunnableLanguage: ManagedToolchain]
    func toolchain(for language: RunnableLanguage) -> ManagedToolchain? { toolchains[language] }
}

private func loginPath(_ path: String?, log: ProbeLog = ProbeLog()) -> LoginShellPath {
    LoginShellPath(shell: "/bin/zsh", timeout: 3) { shell, args, _ in
        log.noteShell(shell, args)
        guard let path else { return nil }
        return "Last login: today\nwelcome banner\n\(LoginShellPath.beginMarker)\(path)\(LoginShellPath.endMarker)\n"
    }
}

private func makeLocator(executables: Set<String>,
                         login: String? = "/opt/homebrew/bin:/usr/bin:/bin",
                         developerTools: Bool = true,
                         java: Bool = true,
                         managed: [RunnableLanguage: ManagedToolchain] = [:],
                         arch: String = "aarch64",
                         log: ProbeLog = ProbeLog()) -> ToolchainLocator {
    let probes = ToolchainProbes(
        isExecutable: { executables.contains($0) },
        developerToolsInstalled: { log.noteDeveloper(); return developerTools },
        javaRuntimeInstalled: { log.noteJava(); return java })
    return ToolchainLocator(managed: FakeManaged(toolchains: managed),
                            loginPath: loginPath(login, log: log),
                            probes: probes, hostArchitecture: arch)
}

@Suite("Toolchain locator")
struct ToolchainLocatorTests {
    private let managedPython = ManagedToolchain(binDirectory: URL(fileURLWithPath: "/K/python/bin"),
                                                 environment: ["PIP_CACHE_DIR": "/K/cache/pip"])

    @Test func autoPrefersCustomThenManagedThenLoginThenDefault() throws {
        let all: Set<String> = ["/custom/python3", "/K/python/bin/python3", "/opt/homebrew/bin/python3", "/bin/python3"]
        let custom = RunToolPreference(source: .auto, customPath: "/custom/python3")

        var locator = makeLocator(executables: all, managed: [.python: managedPython])
        #expect(try locator.resolve(.python, preference: custom).get().executable == "/custom/python3")
        #expect(try locator.resolve(.python, preference: custom).get().origin == .custom)

        // Custom set but not executable → skipped in auto mode.
        locator = makeLocator(executables: all.subtracting(["/custom/python3"]), managed: [.python: managedPython])
        let managed = try locator.resolve(.python, preference: custom).get()
        #expect(managed.executable == "/K/python/bin/python3")
        #expect(managed.origin == .managed)

        locator = makeLocator(executables: all, managed: [:])
        let login = try locator.resolve(.python, preference: RunToolPreference()).get()
        #expect(login.executable == "/opt/homebrew/bin/python3")
        #expect(login.origin == .loginPath)

        // Not on the login PATH → default system PATH entries are searched last.
        locator = makeLocator(executables: ["/sbin/go"], login: "/opt/homebrew/bin")
        let fallback = try locator.resolve(.go, preference: RunToolPreference()).get()
        #expect(fallback.executable == "/sbin/go")
        #expect(fallback.origin == .systemPath)
        #expect(fallback.searchPath == "/opt/homebrew/bin")
    }

    @Test func explicitSourcesRestrictTheSearch() {
        let all: Set<String> = ["/custom/node", "/K/node/bin/node", "/opt/homebrew/bin/node"]
        let managedNode = ManagedToolchain(binDirectory: URL(fileURLWithPath: "/K/node/bin"))
        let locator = makeLocator(executables: all, managed: [.javascript: managedNode])

        let custom = locator.resolve(.javascript, preference: .init(source: .custom, customPath: "/custom/node"))
        #expect((try? custom.get())?.executable == "/custom/node")
        let managed = locator.resolve(.javascript, preference: .init(source: .managed, customPath: "/custom/node"))
        #expect((try? managed.get())?.executable == "/K/node/bin/node")
        let system = locator.resolve(.javascript, preference: .init(source: .system, customPath: "/custom/node"))
        #expect((try? system.get())?.executable == "/opt/homebrew/bin/node")
    }

    @Test func explicitSourceFailures() {
        let locator = makeLocator(executables: ["/opt/homebrew/bin/node"])
        #expect(locator.resolve(.javascript, preference: .init(source: .custom, customPath: "/missing/node"))
                == .failure(.customToolInvalid("/missing/node")))
        #expect(locator.resolve(.javascript, preference: .init(source: .custom, customPath: nil))
                == .failure(.customToolInvalid("")))
        #expect(locator.resolve(.javascript, preference: .init(source: .custom, customPath: "relative/node"))
                == .failure(.customToolInvalid("relative/node")))
        #expect(locator.resolve(.typescript, preference: .init(source: .managed))
                == .failure(.toolchainNotInstalled("typescript")))
        #expect(locator.resolve(.go, preference: .init(source: .system)) == .failure(.toolNotFound("go")))
        #expect(locator.resolve(.csharp, preference: .init()) == .failure(.toolNotFound("dotnet")))
    }

    @Test func managedToolchainSuppliesSearchPathAndEnvironment() throws {
        let locator = makeLocator(executables: ["/K/python/bin/python3"], managed: [.python: managedPython])
        let tool = try locator.resolve(.python, preference: .init()).get()
        #expect(tool.searchPath == "/K/python/bin:/opt/homebrew/bin:/usr/bin:/bin")
        #expect(tool.environment == ["PIP_CACHE_DIR": "/K/cache/pip"])
    }

    @Test func managedProviderWithoutTheToolFallsBack() throws {
        // The provider claims a toolchain but the binary is missing → system.
        let locator = makeLocator(executables: ["/opt/homebrew/bin/python3"], managed: [.python: managedPython])
        #expect(try locator.resolve(.python, preference: .init()).get().executable == "/opt/homebrew/bin/python3")
    }

    @Test func toolNamesPerLanguage() {
        let expected: [RunnableLanguage: String] = [
            .python: "python3", .javascript: "node", .typescript: "node", .bash: "bash", .c: "clang",
            .cpp: "clang++", .swift: "swiftc", .go: "go", .rust: "rustc", .java: "java", .csharp: "dotnet",
        ]
        for language in RunnableLanguage.allCases {
            #expect(ToolchainLocator.toolName(for: language) == expected[language])
        }
    }

    // MARK: Apple stubs

    @Test func developerToolShimWithoutCLTIsRejectedBeforeUse() {
        let log = ProbeLog()
        let locator = makeLocator(executables: ["/usr/bin/python3"], login: "/usr/bin:/bin",
                                  developerTools: false, log: log)
        #expect(locator.resolve(.python, preference: .init()) == .failure(.developerToolsMissing("python3")))
        #expect(log.developer == 1)
        #expect(log.java == 0)
        for (language, tool) in [(RunnableLanguage.c, "clang"), (.cpp, "clang++"), (.swift, "swiftc")] {
            let locator = makeLocator(executables: ["/usr/bin/\(tool)"], login: "/usr/bin",
                                      developerTools: false)
            #expect(locator.resolve(language, preference: .init()) == .failure(.developerToolsMissing(tool)))
        }
    }

    @Test func developerToolShimWithCLTIsAccepted() throws {
        let log = ProbeLog()
        let locator = makeLocator(executables: ["/usr/bin/clang"], login: "/usr/bin:/bin", log: log)
        let tool = try locator.resolve(.c, preference: .init()).get()
        #expect(tool.executable == "/usr/bin/clang")
        #expect(tool.leadingArguments.isEmpty)
        #expect(log.developer == 1)
    }

    @Test func rejectedShimFallsThroughToLaterPathEntry() throws {
        let locator = makeLocator(executables: ["/usr/bin/python3", "/opt/homebrew/bin/python3"],
                                  login: "/usr/bin:/opt/homebrew/bin", developerTools: false)
        #expect(try locator.resolve(.python, preference: .init()).get().executable == "/opt/homebrew/bin/python3")
    }

    @Test func customPathToShimIsAlsoChecked() {
        let locator = makeLocator(executables: ["/usr/bin/python3"], developerTools: false)
        #expect(locator.resolve(.python, preference: .init(source: .custom, customPath: "/usr/bin/python3"))
                == .failure(.developerToolsMissing("python3")))
    }

    @Test func javaStubDetection() throws {
        let log = ProbeLog()
        var locator = makeLocator(executables: ["/usr/bin/java"], login: "/usr/bin", java: false, log: log)
        #expect(locator.resolve(.java, preference: .init()) == .failure(.javaRuntimeMissing))
        #expect(log.java == 1)
        #expect(log.developer == 0)

        locator = makeLocator(executables: ["/usr/bin/java"], login: "/usr/bin", java: true)
        #expect(try locator.resolve(.java, preference: .init()).get().executable == "/usr/bin/java")
    }

    @Test func nonShimToolsAreNeverProbed() throws {
        let log = ProbeLog()
        let locator = makeLocator(executables: ["/opt/homebrew/bin/python3", "/usr/bin/node", "/opt/homebrew/bin/java"],
                                  developerTools: false, java: false, log: log)
        _ = try locator.resolve(.python, preference: .init()).get()   // not in /usr/bin
        _ = try locator.resolve(.javascript, preference: .init()).get() // /usr/bin but not a shim name
        _ = try locator.resolve(.java, preference: .init()).get()
        #expect(log.developer == 0)
        #expect(log.java == 0)
    }

    // MARK: C / C++ compiler choice

    @Test func managedZigIsUsedWithExplicitTarget() throws {
        let zig = ManagedToolchain(binDirectory: URL(fileURLWithPath: "/K/zig"), environment: ["ZIG_GLOBAL_CACHE_DIR": "/K/zc"])
        let locator = makeLocator(executables: ["/K/zig/zig", "/usr/bin/clang"], managed: [.c: zig, .cpp: zig])
        let c = try locator.resolve(.c, preference: .init()).get()
        #expect(c.executable == "/K/zig/zig")
        #expect(c.leadingArguments == ["cc", "-target", "aarch64-macos"])
        #expect(c.environment["ZIG_GLOBAL_CACHE_DIR"] == "/K/zc")
        let cpp = try locator.resolve(.cpp, preference: .init()).get()
        #expect(cpp.leadingArguments == ["c++", "-target", "aarch64-macos"])

        let intel = makeLocator(executables: ["/K/zig/zig"], managed: [.c: zig], arch: "x86_64")
        #expect(try intel.resolve(.c, preference: .init()).get().leadingArguments == ["cc", "-target", "x86_64-macos"])
    }

    @Test func withoutZigClangIsUsed() throws {
        let locator = makeLocator(executables: ["/usr/bin/clang++"])
        let tool = try locator.resolve(.cpp, preference: .init()).get()
        #expect(tool.executable == "/usr/bin/clang++")
        #expect(tool.leadingArguments.isEmpty)
    }

    @Test func customZigPathGetsZigMode() throws {
        let locator = makeLocator(executables: ["/tools/zig"])
        let tool = try locator.resolve(.cpp, preference: .init(source: .custom, customPath: "/tools/zig")).get()
        #expect(tool.leadingArguments == ["c++", "-target", "aarch64-macos"])
    }

    // MARK: Bash and shebangs

    @Test func bashDefaultsToBinBash() throws {
        let locator = makeLocator(executables: [])
        let tool = try locator.resolve(.bash, preference: .init(), text: "echo hi").get()
        #expect(tool.executable == "/bin/bash")
        #expect(tool.origin == .fixed)
    }

    @Test func bashShebangPicksShell() throws {
        let locator = makeLocator(executables: ["/bin/zsh", "/bin/sh", "/opt/homebrew/bin/bash", "/bin/bash"])
        #expect(try locator.resolve(.bash, preference: .init(), text: "#!/bin/zsh\necho").get().executable == "/bin/zsh")
        #expect(try locator.resolve(.bash, preference: .init(), text: "#!/usr/bin/env bash\necho").get().executable
                == "/opt/homebrew/bin/bash")
        let flagged = try locator.resolve(.bash, preference: .init(), text: "#!/bin/sh -eu\necho").get()
        #expect(flagged.executable == "/bin/sh")
        #expect(flagged.leadingArguments == ["-eu"])
        let viaEnvS = try locator.resolve(.bash, preference: .init(), text: "#!/usr/bin/env -S zsh -x\n").get()
        #expect(viaEnvS.executable == "/bin/zsh")
        #expect(viaEnvS.leadingArguments == ["-x"])
        // A missing absolute interpreter is looked up by name.
        #expect(try locator.resolve(.bash, preference: .init(), text: "#!/usr/local/bin/bash\n").get().executable
                == "/opt/homebrew/bin/bash")
        // Not a shell shebang → default.
        #expect(try locator.resolve(.bash, preference: .init(), text: "#!/usr/bin/env python3\n").get().executable
                == "/bin/bash")
    }

    @Test func shebangParsing() {
        #expect(ShellShebang.parse("#!/bin/bash\n") == ShellShebang(interpreter: "/bin/bash", arguments: []))
        #expect(ShellShebang.parse("#! /bin/sh -e\r\nx") == ShellShebang(interpreter: "/bin/sh", arguments: ["-e"]))
        #expect(ShellShebang.parse("#!/usr/bin/env FOO=1 zsh") == ShellShebang(interpreter: "zsh", arguments: []))
        #expect(ShellShebang.parse("#!/usr/bin/env") == nil)
        #expect(ShellShebang.parse("#!/usr/bin/fish") == nil)
        #expect(ShellShebang.parse("echo #!/bin/sh") == nil)
    }

    @Test func bashCustomPathOverridesShebang() throws {
        let locator = makeLocator(executables: ["/opt/bash5/bin/bash", "/bin/zsh"])
        let tool = try locator.resolve(.bash, preference: .init(source: .custom, customPath: "/opt/bash5/bin/bash"),
                                       text: "#!/bin/zsh\n").get()
        #expect(tool.executable == "/opt/bash5/bin/bash")
    }
}

@Suite("Login-shell PATH capture")
struct LoginShellPathTests {
    @Test func parsesBetweenMarkersIgnoringNoise() {
        let begin = LoginShellPath.beginMarker, end = LoginShellPath.endMarker
        #expect(LoginShellPath.parse("motd\n\(begin)/a:/b\(end)\ntrailer") == "/a:/b")
        #expect(LoginShellPath.parse("\(begin)  /a:/b \n\(end)") == "/a:/b")
        #expect(LoginShellPath.parse("\(begin)\(end)") == nil)
        #expect(LoginShellPath.parse("\(begin)/a:/b") == nil)
        #expect(LoginShellPath.parse("/a:/b\(end)") == nil)
        #expect(LoginShellPath.parse("") == nil)
    }

    @Test func capturesOnceAndCaches() {
        let log = ProbeLog()
        let path = loginPath("/x/bin:/usr/bin", log: log)
        #expect(path.path == "/x/bin:/usr/bin")
        #expect(path.path == "/x/bin:/usr/bin")
        #expect(path.didCapture)
        #expect(log.shellCalls.count == 1)
        #expect(log.shellCalls.first?.0 == "/bin/zsh")
        #expect(log.shellCalls.first?.1 == ["-l", "-c", LoginShellPath.script])
    }

    @Test func failureOrTimeoutFallsBackToDefault() {
        let log = ProbeLog()
        let path = loginPath(nil, log: log) // runner returns nil, as on timeout
        #expect(path.path == LoginShellPath.defaultPath)
        #expect(path.path == "/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(!path.didCapture)
        #expect(log.shellCalls.count == 1) // fallback is cached too
    }

    @Test func shellFallsBackToZsh() {
        let log = ProbeLog()
        for shell in [nil, "", "zsh"] as [String?] {
            let path = LoginShellPath(shell: shell) { s, args, _ in log.noteShell(s, args); return nil }
            _ = path.path
        }
        #expect(log.shellCalls.map(\.0) == ["/bin/zsh", "/bin/zsh", "/bin/zsh"])
        let fish = LoginShellPath(shell: "/opt/homebrew/bin/fish") { s, args, _ in log.noteShell(s, args); return nil }
        _ = fish.path
        #expect(log.shellCalls.last?.0 == "/opt/homebrew/bin/fish")
    }

    @Test func timeoutIsPassedToRunner() {
        let seen = ProbeLog()
        let path = LoginShellPath(shell: "/bin/zsh", timeout: 3) { _, _, timeout in
            if timeout == 3 { seen.noteJava() }
            return nil
        }
        _ = path.path
        #expect(seen.java == 1)
    }

    // The capture script itself, run through a NON-login /bin/sh, so no user
    // profile is involved.
    @Test func captureScriptPrintsPathBetweenMarkers() throws {
        let result = try #require(SyncCommand.run("/bin/sh", ["-c", "echo noise; " + LoginShellPath.script],
                                                  environment: ["PATH": "/p/one:/p/two"], timeout: 3))
        #expect(result.termination == .exited(0))
        #expect(LoginShellPath.parse(result.stdout) == "/p/one:/p/two")
    }

    @Test func syncCommandTimesOut() {
        let start = Date()
        #expect(SyncCommand.run("/bin/sleep", ["5"], timeout: 0.3) == nil)
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test func syncCommandDoesNotWaitForBackgroundGrandchild() throws {
        // A profile that backgrounds a daemon keeps the pipe open; the capture
        // must still return as soon as the shell itself exits.
        let start = Date()
        let result = try #require(SyncCommand.run("/bin/sh", ["-c", "/bin/sleep 3 & echo ready"], timeout: 2.5))
        #expect(result.stdout == "ready\n")
        #expect(Date().timeIntervalSince(start) < 2)
    }
}
