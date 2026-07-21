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

    /// Reads `url` as UTF-8 text, adopts it as the current file, and clears
    /// the dirty flag. Returns the loaded contents for the editor to display.
    @discardableResult
    public func load(from url: URL) throws -> String {
        let text = try String(contentsOf: url, encoding: .utf8)
        fileURL = url
        isDirty = false
        return text
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
