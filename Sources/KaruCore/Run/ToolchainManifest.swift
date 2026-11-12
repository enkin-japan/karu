import Foundation

/// Digest algorithm of a manifest checksum.
public enum ToolchainChecksumAlgorithm: String, Sendable {
    case sha256, sha512

    /// Length of the lowercase hex digest.
    public var hexLength: Int {
        switch self {
        case .sha256: return 64
        case .sha512: return 128
        }
    }
}

/// The expected digest of a toolchain archive (lowercase hex).
public struct ToolchainChecksum: Equatable, Sendable {
    public var algorithm: ToolchainChecksumAlgorithm
    public var hex: String

    public init(_ algorithm: ToolchainChecksumAlgorithm, _ hex: String) {
        self.algorithm = algorithm
        self.hex = hex.lowercased()
    }
}

/// One Karu-installable toolchain (ARCHITECTURE.md §6 "Karu 安装的工具链").
public struct ToolchainManifestEntry: Equatable, Sendable, Identifiable {
    /// Stable identifier, also the directory name under the toolchain root.
    public var id: String
    /// Proper-noun display name (not localized).
    public var displayName: String
    /// Languages this toolchain serves (JS / TS share Node, C / C++ share Zig).
    public var languages: [RunnableLanguage]
    public var version: String
    /// Official https download URL of the archive.
    public var url: URL
    public var checksum: ToolchainChecksum
    /// Archive size in bytes (shown before download; progress fallback).
    public var downloadSize: Int64
    /// Directory holding the executables, relative to the extracted archive
    /// root (`.` = the root itself).
    public var binPath: String
    /// Executables that must exist (and be executable) after extraction.
    public var executables: [String]

    public init(id: String, displayName: String, languages: [RunnableLanguage], version: String,
                url: URL, checksum: ToolchainChecksum, downloadSize: Int64,
                binPath: String, executables: [String]) {
        self.id = id
        self.displayName = displayName
        self.languages = languages
        self.version = version
        self.url = url
        self.checksum = checksum
        self.downloadSize = downloadSize
        self.binPath = binPath
        self.executables = executables
    }
}

/// The built-in toolchain manifest. Pinned to this Karu version — there is no
/// remote manifest; updating a toolchain means shipping a new Karu.
/// Swift and Rust need Apple's Command Line Tools and are not managed; Bash
/// uses the system shell.
public enum ToolchainManifest {
    /// Hosts the manifest may point at (enforced by tests).
    public static let allowedHosts: Set<String> = [
        "github.com", "nodejs.org", "go.dev", "builds.dotnet.microsoft.com", "ziglang.org",
    ]

    public static let all: [ToolchainManifestEntry] = [
        ToolchainManifestEntry(
            id: "python", displayName: "Python", languages: [.python], version: "3.14.10",
            url: URL(string: "https://github.com/astral-sh/python-build-standalone/releases/download/20261110/cpython-3.14.10%2B20261110-aarch64-apple-darwin-install_only.tar.gz")!,
            checksum: ToolchainChecksum(.sha256, "42031ed5f0d38777335252c8c77d64708c8010dd67c128246bdec25000672666"),
            downloadSize: 27_109_898, binPath: "python/bin", executables: ["python3"]),
        ToolchainManifestEntry(
            id: "node", displayName: "Node.js", languages: [.javascript, .typescript], version: "26.13.1",
            url: URL(string: "https://nodejs.org/dist/v26.13.1/node-v26.13.1-darwin-arm64.tar.xz")!,
            checksum: ToolchainChecksum(.sha256, "af6202f5370a3a5209e85dc543758dfd9f44c8726626a236730cd603a67a8559"),
            downloadSize: 30_638_176, binPath: "node-v26.13.1-darwin-arm64/bin", executables: ["node"]),
        ToolchainManifestEntry(
            id: "go", displayName: "Go", languages: [.go], version: "1.27.4",
            url: URL(string: "https://go.dev/dl/go1.27.4.darwin-arm64.tar.gz")!,
            checksum: ToolchainChecksum(.sha256, "91a44a2b8a716600ad94a4f143e156116620db8828086a6e3602291be9bd0bb4"),
            downloadSize: 68_231_011, binPath: "go/bin", executables: ["go"]),
        ToolchainManifestEntry(
            id: "java", displayName: "Temurin JDK", languages: [.java], version: "25.0.5+8",
            url: URL(string: "https://github.com/adoptium/temurin25-binaries/releases/download/jdk-25.0.5%2B8/OpenJDK25U-jdk_aarch64_mac_hotspot_25.0.5_8.tar.gz")!,
            checksum: ToolchainChecksum(.sha256, "36dc14d797aaff6d89aab302cd053fdba6207dfdcf772052fa7b023a94b0e857"),
            downloadSize: 136_446_056, binPath: "jdk-25.0.5+8/Contents/Home/bin", executables: ["java"]),
        ToolchainManifestEntry(
            id: "dotnet", displayName: ".NET SDK", languages: [.csharp], version: "10.0.404",
            url: URL(string: "https://builds.dotnet.microsoft.com/dotnet/Sdk/10.0.404/dotnet-sdk-10.0.404-osx-arm64.tar.gz")!,
            checksum: ToolchainChecksum(.sha512, "1c9a13f625d0c08f08ef5a53597bababe3d2473527e98db2199210940c69dd5fc599a39a4d7c30ebf297ca2334a81b2f64b9bf05ff99585de9af4a5d85215e96"),
            downloadSize: 233_588_093, binPath: ".", executables: ["dotnet"]),
        ToolchainManifestEntry(
            id: "zig", displayName: "Zig", languages: [.c, .cpp], version: "0.17.1",
            url: URL(string: "https://ziglang.org/download/0.17.1/zig-aarch64-macos-0.17.1.tar.xz")!,
            checksum: ToolchainChecksum(.sha256, "75f1bc7a1e9852f17ec9a0c1895f767c4ec56d46bc8a834920eece1d0359dd8d"),
            downloadSize: 54_001_240, binPath: "zig-aarch64-macos-0.17.1", executables: ["zig"]),
    ]

    public static func entry(id: String) -> ToolchainManifestEntry? {
        all.first { $0.id == id }
    }

    /// The toolchain serving `language`, or `nil` (Swift, Rust, Bash).
    public static func entry(for language: RunnableLanguage) -> ToolchainManifestEntry? {
        all.first { $0.languages.contains(language) }
    }
}
