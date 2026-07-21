import Foundation

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

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL
    }

    /// Title suitable for a window: the file name, or "Untitled".
    public var displayName: String {
        fileURL?.lastPathComponent ?? "Untitled"
    }

    public enum DocumentError: Error {
        /// A plain `save` was requested but the document has no URL yet.
        case noFileURL
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
        let text = try Self.decodeText(from: url)
        fileURL = url
        isDirty = false
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

    /// Writes `text` to the current file. Fails if there is no file yet.
    public func save(text: String) throws {
        guard let url = fileURL else { throw DocumentError.noFileURL }
        try write(text, to: url)
        isDirty = false
    }

    /// Writes `text` to `url`, adopts it as the current file, and clears the
    /// dirty flag. Implements "Save As…".
    public func save(text: String, to url: URL) throws {
        try write(text, to: url)
        fileURL = url
        isDirty = false
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
    }
}
