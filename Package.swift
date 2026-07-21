// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Karu",
    platforms: [.macOS(.v13)],
    dependencies: [
        // The only external dependency, admitted 2026-07-21 (see
        // ARCHITECTURE.md §1 note): one-click in-app updates. Binary xcframework;
        // inflates the bundle (disk), not resident memory.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "KaruCore",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/KaruCore"
        ),
        .executableTarget(
            name: "KaruApp",
            dependencies: ["KaruCore"],
            path: "Sources/KaruApp",
            linkerSettings: [
                // Sparkle.framework is embedded at Contents/Frameworks by
                // scripts/bundle-macos.sh; the executable must look there.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .testTarget(
            name: "KaruCoreTests",
            dependencies: ["KaruCore"],
            path: "Tests/KaruCoreTests"
        )
    ]
)
