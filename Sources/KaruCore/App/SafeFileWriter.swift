import Foundation

/// Writes a document's bytes without losing the file's identity (N01) and
/// without overwriting a change that appeared after the caller's conflict check
/// (R01).
///
/// - Symlinks are resolved first, so the *target* receives the bytes and the
///   link stays a link.
/// - A missing target is simply created (atomic write).
/// - An existing target is replaced by a temp file written in the **same
///   directory** (created exclusively) via `FileManager.replaceItemAt`, which
///   carries over the original's extended attributes, ACL and permission bits.
///   The inode changes, so hard links to the old file are not kept.
/// - Just before replacing, the target is `stat`'ed once more and compared with
///   the state the caller's pre-save check saw; a mismatch deletes the temp file
///   and throws `DocumentError.changedOnDisk`.
/// - The re-check and the replace run inside an `NSFileCoordinator` write, so
///   writers that coordinate (iCloud Drive, other well-behaved apps) are
///   serialized with us.
///
/// Limitation, stated plainly: a writer that does **not** use file coordination
/// can still modify the file in the few milliseconds between the final `stat`
/// and the replace; that change would be overwritten. This narrows the window,
/// it does not eliminate it.
///
/// If `replaceItemAt` itself fails (a volume without that capability), the
/// write falls back to a plain rename over the target: the text is saved, but
/// the original's extended attributes are then not carried over. Verified to
/// be unnecessary on APFS, exFAT and FAT32; network shares were not tested.
///
/// On any failure the temp file is removed and the original is left untouched.
/// An unwritable directory fails with the underlying Cocoa error (no in-place
/// fallback).
struct SafeFileWriter {
    /// What the target must still look like at replace time.
    enum Expectation: Equatable {
        /// No check (Save As: the save panel already asked about replacing).
        case unchecked
        /// The pre-save check found no file there.
        case missing
        /// The pre-save check saw this stamp.
        case stamp(DiskState.Stamp)
    }

    /// Test seam: runs inside the coordinated write, after the temp file is
    /// written and before the final `stat` + replace. Never set in production.
    var beforeReplace: ((URL) -> Void)?

    /// Test seam: the replace step itself (`original`, `replacement`).
    /// Production always uses `FileManager.replaceItemAt`.
    var replaceItem: (URL, URL) throws -> Void = { original, replacement in
        _ = try FileManager.default.replaceItemAt(original, withItemAt: replacement)
    }

    init(beforeReplace: ((URL) -> Void)? = nil) {
        self.beforeReplace = beforeReplace
    }

    /// Prefix of the temp files this writer creates (hidden, next to the target).
    static let tempPrefix = ".karu-save-"

    /// Writes `data` to the real file behind `url` and returns the fresh stamp
    /// of the written file.
    @discardableResult
    func write(_ data: Data, to url: URL, expecting expectation: Expectation) throws -> DiskState.Stamp {
        let target = Self.resolveSymlinks(url)
        var coordinationError: NSError?
        var result: Result<DiskState.Stamp, Error> = .failure(CocoaError(.fileWriteUnknown))
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: target, options: .forReplacing, error: &coordinationError
        ) { coordinated in
            result = Result { try writeCoordinated(data, to: coordinated, expecting: expectation) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    private func writeCoordinated(_ data: Data, to target: URL,
                                  expecting expectation: Expectation) throws -> DiskState.Stamp {
        guard DiskState.Stamp.of(target) != nil else {
            // No file (any more): re-create it, as before. A file that was
            // expected but deleted is not a conflict. Only a file that the
            // pre-check saw as missing and that appeared since is one.
            beforeReplace?(target)
            if expectation == .missing, DiskState.Stamp.of(target) != nil {
                throw DocumentController.DocumentError.changedOnDisk
            }
            try data.write(to: target, options: .atomic)
            return try freshStamp(target)
        }

        let directory = target.deletingLastPathComponent()
        // The temp name deliberately leaves the document's own name out: a
        // prefix plus a long file name could exceed NAME_MAX and fail a save
        // that the plain atomic write used to manage.
        let temp = directory.appendingPathComponent("\(Self.tempPrefix)\(UUID().uuidString)")
        // `.withoutOverwriting` creates the file exclusively (O_EXCL).
        try data.write(to: temp, options: .withoutOverwriting)
        var tempNeedsCleanup = true
        defer { if tempNeedsCleanup { try? FileManager.default.removeItem(at: temp) } }

        beforeReplace?(target)

        let current = DiskState.Stamp.of(target)
        switch expectation {
        case .unchecked:
            break
        case .missing:
            if current != nil { throw DocumentController.DocumentError.changedOnDisk }
        case .stamp(let expected):
            if current != expected { throw DocumentController.DocumentError.changedOnDisk }
        }

        if current == nil {
            // Vanished between the checks: nothing to preserve, just move in place.
            try FileManager.default.moveItem(at: temp, to: target)
        } else {
            do {
                try replaceItem(target, temp)
            } catch {
                // A volume that cannot do the metadata-preserving replace must
                // not make the document unsavable. Fall back to a plain
                // `rename(2)` over the target, which is what the atomic write
                // did before: the text is saved, the original's extended
                // attributes are not carried over. Only when the target is
                // still exactly what was checked; otherwise report the failure.
                guard FileManager.default.fileExists(atPath: temp.path),
                      DiskState.Stamp.of(target) == current,
                      rename(temp.path, target.path) == 0 else { throw error }
            }
        }
        // On success the temp item has been consumed by the move/replace.
        tempNeedsCleanup = false
        return try freshStamp(target)
    }

    private func freshStamp(_ url: URL) throws -> DiskState.Stamp {
        guard let stamp = DiskState.Stamp.of(url) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        return stamp
    }

    /// Follows a chain of symlinks at the *last* path component (relative links
    /// resolve against the link's directory). Unlike `resolvingSymlinksInPath`
    /// this also resolves a dangling link to its intended target, so writing
    /// re-creates the target instead of replacing the link with a regular file.
    static func resolveSymlinks(_ url: URL) -> URL {
        var current = url.standardizedFileURL
        for _ in 0..<32 {
            guard let destination = try? FileManager.default
                .destinationOfSymbolicLink(atPath: current.path) else { return current }
            if destination.hasPrefix("/") {
                current = URL(fileURLWithPath: destination).standardizedFileURL
            } else {
                current = current.deletingLastPathComponent()
                    .appendingPathComponent(destination).standardizedFileURL
            }
        }
        return current
    }
}
