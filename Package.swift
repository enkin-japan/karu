// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Karu",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "KaruCore", path: "Sources/KaruCore"),
        .executableTarget(
            name: "KaruApp",
            dependencies: ["KaruCore"],
            path: "Sources/KaruApp"
        ),
        .testTarget(
            name: "KaruCoreTests",
            dependencies: ["KaruCore"],
            path: "Tests/KaruCoreTests"
        )
    ]
)
