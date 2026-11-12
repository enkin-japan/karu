import Foundation
import Testing
@testable import KaruCore

// T16.5 — the built-in manifest, the managed-toolchain provider (bin dir +
// cache-redirecting environment) and its integration with the locator.

@Suite("Toolchain manifest")
struct ToolchainManifestTests {
    @Test func entriesAreCompleteAndPinned() throws {
        let all = ToolchainManifest.all
        #expect(all.map(\.id) == ["python", "node", "go", "java", "dotnet", "zig"])
        #expect(Set(all.map(\.id)).count == all.count)
        for entry in all {
            #expect(entry.url.scheme == "https", "\(entry.id)")
            #expect(ToolchainManifest.allowedHosts.contains(entry.url.host ?? ""), "\(entry.id)")
            #expect(entry.checksum.hex.count == entry.checksum.algorithm.hexLength, "\(entry.id)")
            #expect(entry.checksum.hex.allSatisfy { $0.isHexDigit && !$0.isUppercase }, "\(entry.id)")
            #expect(entry.downloadSize > 1_000_000, "\(entry.id)")
            #expect(!entry.version.isEmpty && !entry.version.contains("/"), "\(entry.id)")
            #expect(!entry.executables.isEmpty, "\(entry.id)")
            #expect(!entry.binPath.hasPrefix("/") && !entry.binPath.contains(".."), "\(entry.id)")
            #expect(!entry.languages.isEmpty, "\(entry.id)")
        }
        #expect(ToolchainManifest.entry(id: "dotnet")?.checksum.algorithm == .sha512)
        #expect(all.filter { $0.checksum.algorithm == .sha256 }.count == 5)
        #expect(ToolchainManifest.entry(id: "java")?.binPath == "jdk-25.0.5+8/Contents/Home/bin")
        #expect(ToolchainManifest.entry(id: "dotnet")?.binPath == ".")
    }

    @Test func everyManagedLanguageIsMappedAndUnmanagedOnesAreNot() {
        let expected: [RunnableLanguage: String] = [
            .python: "python", .javascript: "node", .typescript: "node", .go: "go",
            .java: "java", .csharp: "dotnet", .c: "zig", .cpp: "zig",
        ]
        for language in RunnableLanguage.allCases {
            #expect(ToolchainManifest.entry(for: language)?.id == expected[language], "\(language)")
        }
        for unmanaged in [RunnableLanguage.swift, .rust, .bash] {
            #expect(!ToolchainManifest.all.contains { $0.languages.contains(unmanaged) })
        }
        // Each language served by exactly one entry.
        let served = ToolchainManifest.all.flatMap(\.languages)
        #expect(served.count == Set(served).count)
    }
}

@Suite("Managed toolchain provider")
struct KaruManagedToolchainsTests {
    @Test func nilWhenNothingIsInstalled() {
        let dir = ToolchainFixtures.tempDirectory("provider-empty")
        defer { try? FileManager.default.removeItem(at: dir) }
        let provider = KaruManagedToolchains(store: ToolchainStore(root: dir))
        for language in RunnableLanguage.allCases {
            #expect(provider.toolchain(for: language) == nil, "\(language)")
        }
        // Missing root entirely.
        let missing = KaruManagedToolchains(store: ToolchainStore(root: dir.appendingPathComponent("nope")))
        #expect(missing.toolchain(for: .python) == nil)
    }

    @Test func installedToolchainsAnswerWithBinDirAndRedirectedCaches() throws {
        let dir = ToolchainFixtures.tempDirectory("provider")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ToolchainStore(root: dir)
        for entry in ToolchainManifest.all { try ToolchainFixtures.fakeInstall(entry, store: store) }
        let provider = KaruManagedToolchains(store: store)

        for language in RunnableLanguage.allCases {
            guard let entry = ToolchainManifest.entry(for: language) else {
                #expect(provider.toolchain(for: language) == nil, "\(language)")
                continue
            }
            let toolchain = try #require(provider.toolchain(for: language), "\(language)")
            let versionDir = store.versionDirectory(entry.id, version: entry.version)
            let expectedBin = entry.binPath == "." ? versionDir : versionDir.appendingPathComponent(entry.binPath)
            #expect(toolchain.binDirectory.path == expectedBin.path, "\(language)")
            for exe in entry.executables {
                #expect(FileManager.default.isExecutableFile(atPath: toolchain.binDirectory.appendingPathComponent(exe).path))
            }
            // Every path-valued override lives in <root>/.cache/<id>/ (or the install).
            let cachePrefix = store.cacheDirectory(entry.id).path + "/"
            for (key, value) in toolchain.environment where value.hasPrefix("/") {
                #expect(value.hasPrefix(cachePrefix) || value.hasPrefix(versionDir.path), "\(key)=\(value)")
            }
        }

        let cache = { (id: String, sub: String) in store.cacheDirectory(id).appendingPathComponent(sub).path }
        let go = try #require(provider.toolchain(for: .go)).environment
        #expect(go["GOTELEMETRY"] == "off")
        #expect(go["GOTOOLCHAIN"] == "local")
        #expect(go["GOFLAGS"] == nil)
        for key in ["GOPATH", "GOCACHE", "GOMODCACHE", "GOENV"] {
            #expect(go[key]?.hasPrefix(store.cacheDirectory("go").path + "/") == true, "\(key)")
        }

        let js = try #require(provider.toolchain(for: .javascript))
        let ts = try #require(provider.toolchain(for: .typescript))
        #expect(js == ts)
        #expect(js.binDirectory.path.hasSuffix("/node/26.13.1/node-v26.13.1-darwin-arm64/bin"))
        #expect(js.environment["NPM_CONFIG_CACHE"] == cache("node", "npm-cache"))
        #expect(js.environment["NPM_CONFIG_PREFIX"] == cache("node", "npm-prefix"))
        #expect(js.environment["COREPACK_HOME"] == cache("node", "corepack"))
        #expect(js.environment["NODE_REPL_HISTORY"] == "")

        let python = try #require(provider.toolchain(for: .python)).environment
        #expect(python["PIP_CACHE_DIR"] == cache("python", "pip"))
        #expect(python["PYTHONUSERBASE"] == cache("python", "userbase"))
        #expect(python["PIP_DISABLE_PIP_VERSION_CHECK"] == "1")

        let java = try #require(provider.toolchain(for: .java))
        #expect(java.environment["JAVA_HOME"] == java.binDirectory.deletingLastPathComponent().path)
        #expect(java.environment["JAVA_HOME"]?.hasSuffix("/jdk-25.0.5+8/Contents/Home") == true)

        let dotnet = try #require(provider.toolchain(for: .csharp))
        #expect(dotnet.environment["DOTNET_ROOT"] == store.versionDirectory("dotnet", version: "10.0.404").path)
        #expect(dotnet.environment["DOTNET_CLI_HOME"] == cache("dotnet", "home"))
        #expect(dotnet.environment["NUGET_PACKAGES"] == cache("dotnet", "nuget/packages"))
        for (key, value) in ["DOTNET_CLI_TELEMETRY_OPTOUT": "1", "DOTNET_SKIP_FIRST_TIME_EXPERIENCE": "1",
                             "DOTNET_NOLOGO": "1", "DOTNET_GENERATE_ASPNET_CERTIFICATE": "false",
                             "DOTNET_ADD_GLOBAL_TOOLS_TO_PATH": "false"] {
            #expect(dotnet.environment[key] == value, "\(key)")
        }

        let c = try #require(provider.toolchain(for: .c))
        let cpp = try #require(provider.toolchain(for: .cpp))
        #expect(c == cpp)
        #expect(c.binDirectory.lastPathComponent == "zig-aarch64-macos-0.17.1")
        #expect(c.environment["ZIG_GLOBAL_CACHE_DIR"] == cache("zig", "global"))
        #expect(c.environment["ZIG_LOCAL_CACHE_DIR"] == cache("zig", "local"))
    }

    @Test func brokenInstallIsNotReported() throws {
        let dir = ToolchainFixtures.tempDirectory("provider-broken")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ToolchainStore(root: dir)
        let go = try #require(ToolchainManifest.entry(id: "go"))
        try ToolchainFixtures.fakeInstall(go, store: store)
        let exe = store.versionDirectory("go", version: go.version).appendingPathComponent("go/bin/go")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: exe.path)
        #expect(KaruManagedToolchains(store: store).toolchain(for: .go) == nil)
    }
}

@Suite("Managed toolchains in the locator")
struct ManagedLocatorIntegrationTests {
    private func locator(_ store: ToolchainStore, extra: Set<String> = []) -> ToolchainLocator {
        let probes = ToolchainProbes(
            isExecutable: { extra.contains($0) || ToolchainStore.isExecutableFile(URL(fileURLWithPath: $0)) },
            developerToolsInstalled: { true }, javaRuntimeInstalled: { true })
        return ToolchainLocator(managed: KaruManagedToolchains(store: store),
                                loginPath: LoginShellPath(shell: "/bin/zsh") { _, _, _ in
                                    "\(LoginShellPath.beginMarker)/opt/sys/bin:/usr/bin\(LoginShellPath.endMarker)"
                                },
                                probes: probes, hostArchitecture: "aarch64")
    }

    @Test func autoPrefersManagedWhenInstalledAndManagedRequiresIt() throws {
        let dir = ToolchainFixtures.tempDirectory("locator")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ToolchainStore(root: dir)
        let system: Set<String> = ["/opt/sys/bin/python3", "/opt/sys/bin/node", "/opt/sys/bin/clang"]
        let locator = locator(store, extra: system)

        // Nothing installed: auto falls back to the login PATH; managed fails.
        #expect(try locator.resolve(.python, preference: .init()).get().executable == "/opt/sys/bin/python3")
        #expect(locator.resolve(.python, preference: .init(source: .managed)) == .failure(.toolchainNotInstalled("python")))
        #expect(locator.resolve(.c, preference: .init(source: .managed)) == .failure(.toolchainNotInstalled("c")))

        for id in ["python", "node", "zig"] {
            try ToolchainFixtures.fakeInstall(try #require(ToolchainManifest.entry(id: id)), store: store)
        }
        let python = try locator.resolve(.python, preference: .init()).get()
        let bin = store.versionDirectory("python", version: "3.14.10").appendingPathComponent("python/bin")
        #expect(python.executable == bin.appendingPathComponent("python3").path)
        #expect(python.origin == .managed)
        #expect(python.searchPath.hasPrefix(bin.path + ":"))
        #expect(python.environment["PIP_CACHE_DIR"]?.hasPrefix(store.cacheDirectory("python").path) == true)
        #expect(try locator.resolve(.python, preference: .init(source: .managed)).get() == python)
        // System still selectable explicitly.
        #expect(try locator.resolve(.python, preference: .init(source: .system)).get().executable == "/opt/sys/bin/python3")

        let ts = try locator.resolve(.typescript, preference: .init()).get()
        #expect(ts.executable.hasSuffix("/node-v26.13.1-darwin-arm64/bin/node"))

        // C / C++ go through `zig cc` / `zig c++` with the host target.
        let c = try locator.resolve(.c, preference: .init()).get()
        #expect(c.executable.hasSuffix("/zig-aarch64-macos-0.17.1/zig"))
        #expect(c.leadingArguments == ["cc", "-target", "aarch64-macos"])
        let cpp = try locator.resolve(.cpp, preference: .init(source: .managed)).get()
        #expect(cpp.leadingArguments == ["c++", "-target", "aarch64-macos"])
        #expect(cpp.environment["ZIG_GLOBAL_CACHE_DIR"] == store.cacheDirectory("zig").appendingPathComponent("global").path)

        // The plan carries the managed environment into the child.
        let plan = RunPlanBuilder(workspaceRoot: dir.appendingPathComponent("runs"), baseEnvironment: ["HOME": "/h"])
            .makePlan(language: .python, text: "print(1)", documentURL: nil, tool: python, preference: .init())
        #expect(plan.environment["PATH"] == python.searchPath)
        #expect(plan.environment["PIP_CACHE_DIR"] == python.environment["PIP_CACHE_DIR"])

        // Uninstalled again → back to system / not installed.
        try store.uninstall("python")
        #expect(try locator.resolve(.python, preference: .init()).get().origin == .loginPath)
        #expect(locator.resolve(.python, preference: .init(source: .managed)) == .failure(.toolchainNotInstalled("python")))
    }

    @Test func defaultLocatorUsesKaruManagedToolchains() {
        #expect(ToolchainLocator().managed is KaruManagedToolchains)
        #expect(RunPreparer().locator.managed is KaruManagedToolchains)
    }
}
