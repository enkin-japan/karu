import Foundation

/// What ``ScratchpadStore/load()`` found on disk.
public enum ScratchpadLoadResult {
    /// Nothing has been written yet — an empty pad is the right answer.
    case missing
    /// The stored text (possibly empty: a 0-byte file is valid UTF-8).
    case text(String)
    /// Something is there but could not be turned into text. Never treat this
    /// as empty: a later write would replace the user's notes with nothing.
    case failure(ScratchpadLoadFailure)
}

/// Why a scratchpad file that exists could not be loaded.
public enum ScratchpadLoadFailure: Error {
    /// The file could not be read (permissions, I/O, a directory in its place…).
    case unreadable(Error)
    /// The bytes were read but are not valid UTF-8.
    case undecodable
}

/// On-disk home of the always-available scratchpad (T15.1).
///
/// Deliberately *not* a crash draft: `DraftStore` exists only while a window's
/// buffer differs from disk and is wiped on a deliberate quit, whereas this file
/// is a notebook the user expects to find untouched next launch — nothing but an
/// explicit `clear()` (graduating the text into a real file) ever removes it, and
/// a file that cannot be decoded is only ever renamed aside, never emptied (R02).
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

    /// Reads the pad, keeping "nothing written yet" apart from "could not read
    /// it" (R02). The two used to collapse into `""`, and the next flush then
    /// wrote that empty string over notes that were merely unreadable.
    ///
    /// `.missing` only for a genuine absence: no such file, or a path component
    /// that is not a directory (so `content.txt` cannot exist either). Every
    /// other read error is `.unreadable`. A 0-byte file is `.text("")`.
    public func load() -> ScratchpadLoadResult {
        let data: Data
        do {
            data = try Data(contentsOf: contentURL)
        } catch {
            return Self.isNoSuchFile(error) ? .missing : .failure(.unreadable(error))
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return .failure(.undecodable)
        }
        return .text(text)
    }

    /// Sets an undecodable `content.txt` aside as
    /// `content.unreadable-<yyyyMMdd-HHmmss>.txt` in the same directory, so the
    /// pad can start empty without its next write destroying the old bytes.
    ///
    /// A plain `rename(2)` with `RENAME_EXCL` — never copy-and-delete, never
    /// overwriting: when the name is taken (an earlier preservation in the same
    /// second) a `-2`, `-3`, … suffix is tried instead. Returns the new URL.
    public func preserveUndecodableContent(date: Date = Date()) -> Result<URL, Error> {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: date)
        let source = contentURL
        for attempt in 1...1000 {
            let suffix = attempt == 1 ? "" : "-\(attempt)"
            let target = directory.appendingPathComponent("content.unreadable-\(stamp)\(suffix).txt")
            let status = source.withUnsafeFileSystemRepresentation { from in
                target.withUnsafeFileSystemRepresentation { to -> Int32 in
                    guard let from, let to else { return -1 }
                    return renamex_np(from, to, UInt32(RENAME_EXCL))
                }
            }
            if status == 0 { return .success(target) }
            let code = errno
            if code == EEXIST { continue }
            return .failure(POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO))
        }
        return .failure(POSIXError(.EEXIST))
    }

    private static func isNoSuchFile(_ error: Error) -> Bool {
        let nsError = error as NSError
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain {
            return underlying.code == Int(ENOENT) || underlying.code == Int(ENOTDIR)
        }
        if nsError.domain == NSPOSIXErrorDomain {
            return nsError.code == Int(ENOENT) || nsError.code == Int(ENOTDIR)
        }
        return nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError
    }

    /// Reports persistence failure so the owner can keep the only live copy.
    @discardableResult
    public func write(_ content: String) -> Result<Void, Error> {
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            try Data(content.utf8).write(to: contentURL, options: .atomic)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    /// Empties the pad — the text has graduated into a real file and must not
    /// come back the next time the panel opens.
    public func clear() {
        try? FileManager.default.removeItem(at: contentURL)
    }

    /// The pad's file, for error messages that need to name it.
    public var contentURL: URL {
        directory.appendingPathComponent(Self.contentFileName)
    }
}
