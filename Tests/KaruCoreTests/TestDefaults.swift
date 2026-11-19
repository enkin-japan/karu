import Foundation
import Testing

/// Throw-away preference domains for tests.
///
/// `UserDefaults.removePersistentDomain(forName:)` empties a domain but leaves
/// its plist behind: by 2026-11-19 the test suite had left tens of thousands
/// of `…Tests-<UUID>.plist` files in `~/Library/Preferences`. Unlinking the
/// file from the same process does not work either: cfprefsd writes the domain
/// out a few seconds after its last change and recreates the file (measured
/// with 40 domains: all 40 were back 4 s after the unlink).
///
/// So every domain made here is written to a manifest, and the next test
/// process unlinks the plists of manifests that have been quiet for a while,
/// when cfprefsd is long done with them. What stays on disk is bounded by one
/// test run instead of growing forever.
///
/// Tests must not call `UserDefaults(suiteName:)` themselves;
/// `TestDefaultsConventionTests` checks that.
enum TestDefaults {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var manifest: FileHandle?
    nonisolated(unsafe) private static var started = false

    static let manifestDirectory = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Caches/KaruCoreTests/test-defaults", isDirectory: true)
    static let preferencesDirectory = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Preferences", isDirectory: true)
    /// A manifest untouched for this long belongs to a finished run.
    static let quietInterval: TimeInterval = 60

    /// A `UserDefaults` for the suite `name`, recorded for removal by a later
    /// run. Calling it again with the same name gives another handle on the
    /// same domain (what a "relaunch" test needs).
    static func make(_ name: String) -> UserDefaults {
        lock.lock()
        if !started {
            started = true
            sweep(manifests: manifestDirectory, preferences: preferencesDirectory, quietFor: quietInterval, now: Date())
            try? FileManager.default.createDirectory(at: manifestDirectory, withIntermediateDirectories: true)
            let url = manifestDirectory.appendingPathComponent("\(getpid())-\(UUID().uuidString).txt")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            manifest = try? FileHandle(forWritingTo: url)
        }
        manifest?.write(Data((name + "\n").utf8))
        lock.unlock()
        return UserDefaults(suiteName: name)!
    }

    /// Unlinks the plists named by every manifest in `manifests` that was last
    /// written more than `quietFor` seconds before `now`, then the manifest.
    /// Returns the number of plists removed.
    @discardableResult
    static func sweep(manifests: URL, preferences: URL, quietFor: TimeInterval, now: Date) -> Int {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: manifests, includingPropertiesForKeys: [.contentModificationDateKey]) else { return 0 }
        var removed = 0
        for file in files where file.pathExtension == "txt" {
            guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  now.timeIntervalSince(modified) > quietFor,
                  let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for name in Set(text.split(separator: "\n").map(String.init)) {
                // A suite name is a single path component; anything else is not ours.
                guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { continue }
                if unlink(preferences.appendingPathComponent(name + ".plist").path) == 0 { removed += 1 }
            }
            try? fm.removeItem(at: file)
        }
        return removed
    }
}

@Suite("Test defaults convention")
struct TestDefaultsConventionTests {

    @Test func aQuietManifestIsSweptAndAFreshOneIsLeftAlone() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("KaruTestDefaults-\(UUID().uuidString)", isDirectory: true)
        let manifests = root.appendingPathComponent("manifests", isDirectory: true)
        let preferences = root.appendingPathComponent("prefs", isDirectory: true)
        try fm.createDirectory(at: manifests, withIntermediateDirectories: true)
        try fm.createDirectory(at: preferences, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside.plist")
        for name in ["Old-1", "Old-2", "Fresh-1", "Unlisted"] {
            try Data("x".utf8).write(to: preferences.appendingPathComponent(name + ".plist"))
        }
        try Data("x".utf8).write(to: outside)
        let old = manifests.appendingPathComponent("old.txt")
        let fresh = manifests.appendingPathComponent("fresh.txt")
        try Data("Old-1\nOld-2\nOld-2\nMissing\n../outside\n\n".utf8).write(to: old)
        try Data("Fresh-1\n".utf8).write(to: fresh)
        let now = Date()
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-120)], ofItemAtPath: old.path)
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-5)], ofItemAtPath: fresh.path)

        let removed = TestDefaults.sweep(manifests: manifests, preferences: preferences, quietFor: 60, now: now)

        #expect(removed == 2)
        let left = try fm.contentsOfDirectory(atPath: preferences.path).sorted()
        #expect(left == ["Fresh-1.plist", "Unlisted.plist"])
        #expect(fm.fileExists(atPath: outside.path))
        #expect(!fm.fileExists(atPath: old.path))
        #expect(fm.fileExists(atPath: fresh.path))
    }

    /// Every other test file goes through `TestDefaults.make`.
    @Test func noTestOpensASuiteDirectly() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "TestDefaults.swift" }
        #expect(files.count > 50)
        let needle = "UserDefaults(" + "suiteName:"
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains(needle), "\(file.lastPathComponent) calls UserDefaults(suiteName:) directly")
        }
    }
}
