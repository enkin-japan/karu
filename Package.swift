// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TinyEditor",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "TinyEditorCore", path: "Sources/TinyEditorCore"),
        .executableTarget(
            name: "TinyEditorApp",
            dependencies: ["TinyEditorCore"],
            path: "Sources/TinyEditorApp"
        ),
        .testTarget(
            name: "TinyEditorCoreTests",
            dependencies: ["TinyEditorCore"],
            path: "Tests/TinyEditorCoreTests"
        )
    ]
)
