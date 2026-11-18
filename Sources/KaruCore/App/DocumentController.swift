import Foundation
import CryptoKit

/// UI-independent document state model.
///
/// Tracks the on-disk location, the dirty flag, and performs plain UTF-8
/// text load/save. It deliberately knows nothing about AppKit: the actual
/// panels (NSOpenPanel/NSSavePanel) and text storage live in the window
/// controller layer, which drives this object. This keeps the state machine
/// unit-testable without a running app.
public final class DocumentController {
    /// Location on disk, or `nil` for an untitled (never-saved) document.
    public private(set) var fileURL: URL?

    /// `true` once the in-memory text diverges from what is on disk.
    public private(set) var isDirty: Bool = false

    /// SHA-256 of the last known on-disk contents (a fixed 32-byte summary — no
    /// full-text copy is retained, honouring the resident-memory red line).
    /// Used by `matchesBaseline` so a close/discard prompt can be skipped when
    /// the current text is byte-for-byte the saved contents (e.g. edited then
    /// undone). Seeded with the digest of the empty string so a fresh untitled
    /// document treats "" as its baseline.
    private var baselineDigest: SHA256.Digest = SHA256.hash(data: Data())

    /// What the file looked like on disk at the last load / reload / save
    /// (R01): `stat` stamp plus SHA-256 of the raw bytes. `nil` until the
    /// document has been read from or written to disk. Used by the pre-save
    /// conflict check and `externalChange()`.
    public private(set) var diskState: DiskState?

    /// Performs the identity-preserving write. Internal so tests can inject the
    /// writer's `beforeReplace` seam.
    var writer = SafeFileWriter()

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL
    }

    /// Records `text` as the new on-disk baseline. Called only at low-frequency
    /// moments (load / reload / save), never per keystroke.
    private func setBaseline(text: String) {
        baselineDigest = SHA256.hash(data: Data(text.utf8))
    }

    /// `true` when `text` hashes to the current baseline — i.e. it is identical
    /// to the last loaded/saved contents. Computed on demand (close/confirm
    /// time) so no digest work happens on the typing hot path.
    public func matchesBaseline(_ text: String) -> Bool {
        SHA256.hash(data: Data(text.utf8)) == baselineDigest
    }

    /// The baseline digest as a plain 32-byte value, for comparisons made off
    /// the main thread (R05: the crash-draft job hashes its own snapshot and
    /// compares it against this). Same bytes `matchesBaseline` compares with.
    public var baselineSHA256: Data {
        Data(baselineDigest)
    }

    /// Title suitable for a window: the file name, or "Untitled".
    public var displayName: String {
        fileURL?.lastPathComponent ?? "Untitled"
    }

    public enum DocumentError: Error, Equatable {
        /// A plain `save` was requested but the document has no URL yet.
        case noFileURL
        /// A manual "Reopen with Encoding" failed: the chosen encoding could not
        /// decode the file's bytes.
        case decodingFailed
        /// The file on disk changed (different bytes) since it was last loaded
        /// or saved; nothing was written. Retry with
        /// `save(text:overwritingExternalChanges: true)` to overwrite.
        case changedOnDisk
    }

    /// Result of `externalChange()`.
    public enum ExternalChange: Equatable, Sendable {
        /// The file still holds the bytes last loaded/saved (or there is
        /// nothing to compare against).
        case none
        /// The file's bytes differ from the last loaded/saved bytes.
        case modified
        /// Nothing exists at the file's path any more.
        case removed
    }

    /// Failure modes of `rename(to:)`. Kept a distinct type so the UI layer can
    /// map each case onto its own localized alert (T11.4). `Equatable` so tests
    /// can assert the exact branch taken.
    public enum RenameError: Error, Equatable {
        /// The document has never been saved, so there is nothing on disk to move.
        case noFileURL
        /// The proposed name was empty (or all whitespace).
        case emptyName
        /// The proposed name contained a path separator ("/").
        case invalidName
        /// A different file already occupies the target name in the same folder.
        case targetExists
        /// The move itself failed (permissions, I/O, …); carries the underlying
        /// error's description for the alert.
        case moveFailed(String)
    }

    // MARK: - Dirty state machine

    /// Called by the editor whenever the text changes.
    public func markEdited() {
        isDirty = true
    }

    // MARK: - Load / save (UTF-8 plain text)

    /// Reads `url` as text, adopts it as the current file, and clears the
    /// dirty flag. Returns the loaded contents for the editor to display.
    ///
    /// Encoding: UTF-8 first (the format we save), then Foundation's own
    /// detection (`usedEncoding` — catches UTF-16/32 BOMs and more), then the
    /// common CJK legacy encodings (GB18030, Shift-JIS, Big5). Whatever the
    /// source encoding was, the document is saved back as UTF-8.
    @discardableResult
    public func load(from url: URL) throws -> String {
        // Disk state first, decode second: if the file is replaced in between,
        // the recorded state describes the *older* bytes, so the next save sees
        // a conflict rather than silently overwriting text never shown.
        // Non-throwing so `decodeText` keeps producing exactly today's errors.
        let state = try? DiskState.read(url)
        let text = try Self.decodeText(from: url)
        fileURL = url
        isDirty = false
        setBaseline(text: text)
        diskState = state
        return text
    }

    /// Decoding strategy shared by `load`; internal so tests can exercise it.
    static func decodeText(from url: URL) throws -> String {
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
            return utf8
        }
        // BOM-based detection. `usedEncoding` never really fails (it happily
        // "decodes" anything as Latin-1 / MacRoman), so only trust it when it
        // identified an actual Unicode variant — i.e. the file carried a BOM.
        var detected: String.Encoding = .utf8
        if let sniffed = try? String(contentsOf: url, usedEncoding: &detected),
           [.utf16, .utf16BigEndian, .utf16LittleEndian,
            .utf32, .utf32BigEndian, .utf32LittleEndian].contains(detected) {
            return sniffed
        }
        // Statistical detection for legacy encodings (GB18030 / Shift-JIS /
        // Big5 / Latin-1, …). Trying them in a fixed order would mis-decode:
        // GB18030 accepts nearly every byte sequence, so Shift-JIS files turn
        // to mojibake. `stringEncoding(for:)` weighs the candidates instead.
        let data = try Data(contentsOf: url)
        var converted: NSString?
        let encoding = NSString.stringEncoding(
            for: data,
            encodingOptions: [.allowLossyKey: false],
            convertedString: &converted,
            usedLossyConversion: nil
        )
        if encoding != 0, let converted {
            return converted as String
        }
        throw CocoaError(.fileReadInapplicableStringEncoding,
                         userInfo: [NSFilePathErrorKey: url.path])
    }

    // MARK: - Manual encoding override (Reopen with Encoding)

    /// Pure forced decode: interprets `data` strictly as `encoding`, returning
    /// `nil` when the bytes are not valid in that encoding. Non-lossy — a byte
    /// sequence that cannot be represented fails rather than substituting
    /// replacement characters. Kept static and side-effect-free so tests can
    /// exercise it with raw `Data` + `encoding` pairs.
    static func decode(_ data: Data, encoding: String.Encoding) -> String? {
        String(data: data, encoding: encoding)
    }

    /// Re-reads the current (or given) file from disk and force-decodes it with
    /// `encoding`, adopting the URL and clearing the dirty flag on success.
    /// Throws `DocumentError.decodingFailed` if the bytes are invalid for the
    /// chosen encoding. Used by File ▸ Reopen with Encoding.
    @discardableResult
    public func reload(from url: URL, encoding: TextEncoding) throws -> String {
        // Stamp before reading (same reasoning as `load`); the digest is of the
        // very bytes decoded, so no second read is needed here.
        let stamp = DiskState.Stamp.of(url)
        let data = try Data(contentsOf: url)
        guard let text = Self.decode(data, encoding: encoding.encoding) else {
            throw DocumentError.decodingFailed
        }
        fileURL = url
        isDirty = false
        setBaseline(text: text)
        diskState = stamp.map { DiskState(stamp: $0, digest: DiskState.digest(of: data)) }
        return text
    }

    /// Writes `text` to the current file. Fails if there is no file yet.
    ///
    /// Unless `overwritingExternalChanges` is set, first checks that the file
    /// still holds the bytes last loaded/saved: an unchanged `stat` stamp, or a
    /// changed stamp with an identical SHA-256 (touch / identical rewrite), lets
    /// the write proceed; different bytes throw `DocumentError.changedOnDisk`
    /// and write nothing (dirty flag, baseline and `diskState` untouched). A
    /// missing file is re-created, not a conflict.
    public func save(text: String, overwritingExternalChanges: Bool = false) throws {
        guard let url = fileURL else { throw DocumentError.noFileURL }
        let expectation: SafeFileWriter.Expectation
        if overwritingExternalChanges {
            expectation = .unchecked
        } else {
            expectation = try preSaveCheck(url)
        }
        try write(text, to: url, expecting: expectation)
    }

    /// Writes `text` to `url`, adopts it as the current file, and clears the
    /// dirty flag. Implements "Save As…". No conflict check (the save panel has
    /// already confirmed replacing), but the same identity-preserving write.
    public func save(text: String, to url: URL) throws {
        try write(text, to: url, expecting: .unchecked)
        fileURL = url
    }

    /// Conflict check against `diskState`. Returns what the writer must still
    /// find at replace time.
    private func preSaveCheck(_ url: URL) throws -> SafeFileWriter.Expectation {
        guard let recorded = diskState else { return .unchecked }
        let target = SafeFileWriter.resolveSymlinks(url)
        guard let stamp = DiskState.Stamp.of(target) else { return .missing }
        if stamp == recorded.stamp { return .stamp(stamp) }
        let current = try DiskState.read(target)
        guard current.digest == recorded.digest else { throw DocumentError.changedOnDisk }
        // Same bytes, only metadata moved; the writer must see *this* stamp.
        return .stamp(current.stamp)
    }

    private func write(_ text: String, to url: URL,
                       expecting expectation: SafeFileWriter.Expectation) throws {
        let data = Data(text.utf8)
        let stamp = try writer.write(data, to: url, expecting: expectation)
        isDirty = false
        setBaseline(text: text)
        diskState = DiskState(stamp: stamp, digest: DiskState.digest(of: data))
    }

    // MARK: - External change query

    /// Whether the file changed on disk since the last load / reload / save.
    /// `stat` first; the bytes are read and hashed only when the stamp
    /// differs. A metadata-only change (same bytes) returns `.none` and adopts
    /// the new stamp so later checks are cheap again. One-shot: no watcher,
    /// timer or observer.
    public func externalChange() -> ExternalChange {
        guard let url = fileURL, let recorded = diskState else { return .none }
        let target = SafeFileWriter.resolveSymlinks(url)
        guard let stamp = DiskState.Stamp.of(target) else { return .removed }
        if stamp == recorded.stamp { return .none }
        guard let current = try? DiskState.read(target) else { return .modified }
        guard current.digest == recorded.digest else { return .modified }
        diskState = DiskState(stamp: current.stamp, digest: recorded.digest)
        return .none
    }

    // MARK: - Rename

    /// Renames the current file, in its existing folder, to `newName` (which
    /// includes the extension) and adopts the new URL. Returns the new URL.
    ///
    /// Validation (all surfaced as `RenameError` so the UI can localize them):
    /// - the document must have a URL (`noFileURL`);
    /// - the trimmed name must be non-empty (`emptyName`);
    /// - the name must not contain a path separator (`invalidName`);
    /// - a *different* existing file must not already occupy the target
    ///   (`targetExists`).
    ///
    /// Renaming to the current name is a no-op that succeeds (returns the
    /// unchanged URL). The dirty flag is untouched — a rename neither loses nor
    /// commits pending edits.
    @discardableResult
    public func rename(to newName: String) throws -> URL {
        guard let current = fileURL else { throw RenameError.noFileURL }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RenameError.emptyName }
        guard !trimmed.contains("/") else { throw RenameError.invalidName }

        let target = current.deletingLastPathComponent().appendingPathComponent(trimmed)

        // No change (same name) → succeed without touching the filesystem.
        if target.standardizedFileURL == current.standardizedFileURL {
            return current
        }

        if FileManager.default.fileExists(atPath: target.path) {
            throw RenameError.targetExists
        }

        do {
            try FileManager.default.moveItem(at: current, to: target)
        } catch {
            throw RenameError.moveFailed(error.localizedDescription)
        }
        fileURL = target
        return target
    }
}
