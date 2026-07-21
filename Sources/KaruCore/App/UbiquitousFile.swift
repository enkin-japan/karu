import Foundation

/// Pure, AppKit-free helpers for the iCloud-file open path (T10.4).
///
/// These back the two behaviours the window/app layer wires up:
///   1. de-duplicating a Finder "open" against an already-open window, and
///   2. deciding whether a ubiquitous item still needs to be downloaded before
///      it can be read.
///
/// Everything here is a static function over plain values so it is unit-testable
/// without a running app or a live iCloud account (there is no test iCloud
/// environment): the AppKit wiring in `AppDelegate` / `EditorWindowController`
/// only fetches the resource values and feeds them in.
enum UbiquitousFile {

    // MARK: - URL identity (de-duplication)

    /// True when two file URLs point at the same on-disk item, tolerating the
    /// different spellings the same path can arrive in (trailing slash, `..`,
    /// `/tmp` → `/private/tmp` symlinks, etc.). Both sides are standardized and
    /// symlink-resolved so the comparison is spelling-independent.
    static func sameFile(_ a: URL, _ b: URL) -> Bool {
        canonicalPath(a) == canonicalPath(b)
    }

    /// The canonical path string used for identity comparison.
    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    // MARK: - iCloud placeholder names

    /// A Finder iCloud placeholder is the hidden sibling `.<realname>.icloud`
    /// living next to where the real file will land. True for that spelling.
    static func isPlaceholder(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.hasPrefix(".") && name.hasSuffix(".icloud")
            && name.count > (1 + placeholderSuffix.count)
    }

    private static let placeholderSuffix = ".icloud"

    /// Maps an iCloud placeholder URL (`…/.Report.pages.icloud`) back to the
    /// real file URL (`…/Report.pages`). A URL that is not a placeholder is
    /// returned unchanged, so this is safe to call on every incoming open.
    static func resolvedURL(for url: URL) -> URL {
        guard isPlaceholder(url) else { return url }
        let name = url.lastPathComponent
        // Drop the leading "." and the trailing ".icloud".
        let real = String(name.dropFirst().dropLast(placeholderSuffix.count))
        guard !real.isEmpty else { return url }
        return url.deletingLastPathComponent().appendingPathComponent(real)
    }

    // MARK: - Download decision

    /// Whether the item must be downloaded from iCloud before it can be read.
    ///
    /// A non-ubiquitous (ordinary local) file never needs downloading. A
    /// ubiquitous item needs downloading unless a usable copy is already on
    /// disk — i.e. its status is `.current` (up to date) or `.downloaded`
    /// (an older-but-present version); only `.notDownloaded` forces the
    /// download-and-wait path.
    static func needsDownload(isUbiquitous: Bool,
                              status: URLUbiquitousItemDownloadingStatus?) -> Bool {
        guard isUbiquitous, let status else { return false }
        return status != .current && status != .downloaded
    }

    /// Whether a polled download has produced a readable copy on disk. `nil`
    /// (the file is no longer reported as ubiquitous) is treated as "ready" so
    /// the caller stops polling and lets a normal read/report take over.
    static func isDownloadComplete(status: URLUbiquitousItemDownloadingStatus?) -> Bool {
        guard let status else { return true }
        return status == .current || status == .downloaded
    }
}
