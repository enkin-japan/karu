import Foundation

/// On-disk home of the always-available scratchpad (T15.1).
///
/// Deliberately *not* a crash draft: `DraftStore` exists only while a window's
/// buffer differs from disk and is wiped on a deliberate quit, whereas this file
/// is a notebook the user expects to find untouched next launch — nothing but an
/// explicit `clear()` (graduating the text into a real file) ever removes it.
/// The two are fully independent: separate directory, separate lifecycle, and
/// neither one's cleanup can reach the other's data.
///
/// Layout: one directory holding a single `content.txt`, written atomically so a
/// crash mid-write leaves either the previous text or the new one, never half of
/// both. Following the resident-memory rule (ARCHITECTURE.md §3.4) the type keeps
/// no state beyond its directory and installs no observer or timer.
public struct ScratchpadStore: Sendable {

    /// UserDefaults key for the pin toggle: `true` (the default) keeps the panel
    /// on screen when it loses focus, `false` hides it the moment focus leaves.
    public static let pinnedKey = "scratchpad.pinned"

    /// Whether the panel stays put on focus loss. Absent = pinned, so the panel
    /// never vanishes under a user who has not asked for that.
    public static func isPinned(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: pinnedKey) == nil || defaults.bool(forKey: pinnedKey)
    }

    /// UserDefaults key for the pad's own font size.
    public static let fontSizeKey = "scratchpad.fontSize"

    /// Posted (object: nil) after ``setFontSize(_:defaults:)`` so a visible panel
    /// re-applies the size live. The editor's own notification is deliberately not
    /// reused: the two sizes are independent once the pad has one of its own.
    public static let fontDidChangeNotification = Notification.Name("ScratchpadFontSizeDidChange")

    /// The pad's font size.
    ///
    /// Unset it *inherits* the editor's size — a user who has only ever set one
    /// font size expects the pad to match — but the moment the pad is given a size
    /// of its own the two part ways for good, so zooming the pad never resizes
    /// every editor window behind it (the old behaviour, user report).
    public static func fontSize(defaults: UserDefaults = .standard) -> CGFloat {
        if defaults.object(forKey: fontSizeKey) != nil {
            let value = defaults.double(forKey: fontSizeKey)
            if value > 0 {
                return min(max(CGFloat(value), EditorFontSettings.minFontSize),
                           EditorFontSettings.maxFontSize)
            }
        }
        return EditorFontSettings(defaults: defaults).fontSize
    }

    /// Persists the pad's font size (clamped to the editor's range, so the two
    /// steppers cannot disagree about what is a legal size) and broadcasts it.
    public static func setFontSize(_ size: CGFloat, defaults: UserDefaults = .standard) {
        let clamped = min(max(size, EditorFontSettings.minFontSize), EditorFontSettings.maxFontSize)
        defaults.set(Double(clamped), forKey: fontSizeKey)
        NotificationCenter.default.post(name: fontDidChangeNotification, object: nil)
    }

    private static let contentFileName = "content.txt"

    /// Where the scratchpad lives. Injectable so tests can run against a
    /// temporary directory instead of the user's real Application Support folder.
    public let directory: URL

    public init(directory: URL = ScratchpadStore.defaultDirectory) {
        self.directory = directory
    }

    /// `~/Library/Application Support/<bundle id>/Scratchpad`, falling back to
    /// the app name when there is no bundle identifier (test / benchmark
    /// binaries), which also keeps a test run away from the shipping app's notes.
    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Karu")
            .appendingPathComponent("Scratchpad")
    }

    /// The stored text, or `""` when nothing has been written yet (or the file
    /// is unreadable — a fresh empty pad beats refusing to open).
    public func read() -> String {
        guard let data = try? Data(contentsOf: contentURL),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    /// Replaces the stored text. Best-effort by design, like `DraftStore.write`:
    /// a failing backup must never interrupt typing, so I/O errors are swallowed
    /// — the panel keeps its content in memory either way.
    public func write(_ content: String) {
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            try Data(content.utf8).write(to: contentURL, options: .atomic)
        } catch {
            // Ignored on purpose (see above).
        }
    }

    /// Empties the pad — the text has graduated into a real file and must not
    /// come back the next time the panel opens.
    public func clear() {
        try? FileManager.default.removeItem(at: contentURL)
    }

    private var contentURL: URL {
        directory.appendingPathComponent(Self.contentFileName)
    }
}
