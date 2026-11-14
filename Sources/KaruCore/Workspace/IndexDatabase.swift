import Foundation
import SQLite3

/// One project folder's index database (M17 T17.12, plan §10 "存储与常驻").
///
/// File: `<root>/Index/<hash>.sqlite` (`IndexDatabase.fileURL`), system
/// SQLite, WAL journal, page cache capped at `cacheKiB`, no memory mapping,
/// prepared statements kept per connection.
///
/// Schema (`schemaVersion`, stored in `PRAGMA user_version`):
/// ```
/// meta(key TEXT PRIMARY KEY, value TEXT)            -- schema, folder path
/// files(id INTEGER PRIMARY KEY, path TEXT UNIQUE,   -- relative to the folder
///       language TEXT, size INTEGER, mtime INTEGER, -- mtime in ns since 1970
///       indexed_at INTEGER)                         -- s since 1970
/// symbols(file_id INTEGER, name TEXT, folded TEXT,  -- folded: CaseFold per UTF-16 unit
///         kind INTEGER, container TEXT, location INTEGER, line INTEGER,
///         signature TEXT)                           -- nullable summary
/// INDEX symbols(folded), symbols(file_id)
/// ```
/// No file contents and no ordinary words are stored. A version or folder
/// mismatch, or an unreadable file, is handled by deleting and recreating
/// the database (migration by rebuild); the index is derived data.
///
/// Not thread-safe: the owner (`WorkspaceIndex`) serialises access.
final class IndexDatabase {
    static let schemaVersion: Int32 = 1
    /// Page-cache cap per connection (plan §11 ④: ≤ 2 MB per open database).
    static let cacheKiB = 1024

    enum Failure: Error {
        case open(String)
        case sql(String)
    }

    struct FileRecord: Equatable {
        let id: Int64
        let size: Int64
        let mtime: Int64
    }

    struct SymbolRow {
        let path: String
        let language: String
        let name: String
        let kind: Int
        let container: String?
        let location: Int
        let line: Int
        let signature: String?
    }

    let url: URL
    let folderPath: String
    private var db: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]
    /// True when `open` had to rebuild (schema / folder mismatch, corruption).
    private(set) var wasRebuilt = false

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// `<root>/Index/<16 hex FNV-1a of the standardized path>.sqlite`.
    static func fileURL(forFolder path: String, root: URL) -> URL {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let name = String(hash, radix: 16)
        let padded = String(repeating: "0", count: max(0, 16 - name.count)) + name
        return root.appendingPathComponent("Index", isDirectory: true)
            .appendingPathComponent(padded + ".sqlite")
    }

    /// The database file and its WAL / shared-memory companions.
    static func companionURLs(_ url: URL) -> [URL] {
        [url, URL(fileURLWithPath: url.path + "-wal"), URL(fileURLWithPath: url.path + "-shm"),
         URL(fileURLWithPath: url.path + "-journal")]
    }

    /// Deletes the database and its companions.
    static func remove(at url: URL) {
        for file in companionURLs(url) { try? FileManager.default.removeItem(at: file) }
    }

    /// Bytes on disk (database + WAL + shared memory).
    static func diskUsage(at url: URL) -> Int64 {
        companionURLs(url).reduce(0) { total, file in
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
            return total + size
        }
    }

    /// Opens (creating or rebuilding as needed) the database for `folderPath`.
    init(url: URL, folderPath: String) throws {
        self.url = url
        self.folderPath = folderPath
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try openConnection()
            if try !isCurrent() {
                close()
                Self.remove(at: url)
                wasRebuilt = true
                try openConnection()
            }
            try createSchemaIfNeeded()
        } catch {
            // Unreadable / corrupt: rebuild once.
            close()
            Self.remove(at: url)
            wasRebuilt = true
            try openConnection()
            try createSchemaIfNeeded()
        }
    }

    deinit { close() }

    private func openConnection() throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw Failure.open(message)
        }
        db = handle
        sqlite3_busy_timeout(handle, 2000)
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA synchronous=NORMAL")
        try exec("PRAGMA cache_size=-\(Self.cacheKiB)")
        try exec("PRAGMA mmap_size=0")
        try exec("PRAGMA temp_store=FILE")
    }

    /// Whether an existing database matches this schema and folder (an empty
    /// new file counts as current).
    private func isCurrent() throws -> Bool {
        let version = try scalarInt("PRAGMA user_version")
        if version == 0 {
            // Brand new (no tables) is fine; anything else is foreign.
            return try scalarInt("SELECT count(*) FROM sqlite_master") == 0
        }
        guard version == Int64(Self.schemaVersion) else { return false }
        return try metaValue("folder") == folderPath
    }

    private func createSchemaIfNeeded() throws {
        guard try scalarInt("PRAGMA user_version") == 0 else { return }
        try exec("BEGIN")
        try exec("""
            CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
            CREATE TABLE files(id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE, language TEXT NOT NULL,
                               size INTEGER NOT NULL, mtime INTEGER NOT NULL, indexed_at INTEGER NOT NULL);
            CREATE TABLE symbols(file_id INTEGER NOT NULL, name TEXT NOT NULL, folded TEXT NOT NULL,
                                 kind INTEGER NOT NULL, container TEXT, location INTEGER NOT NULL,
                                 line INTEGER NOT NULL, signature TEXT);
            CREATE INDEX symbols_folded ON symbols(folded);
            CREATE INDEX symbols_file ON symbols(file_id);
            """)
        for (key, value) in [("schema", String(Self.schemaVersion)), ("folder", folderPath)] {
            let insert = try prepare("INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)")
            bind(insert, 1, key)
            bind(insert, 2, value)
            try step(insert)
        }
        try exec("PRAGMA user_version=\(Self.schemaVersion)")
        try exec("COMMIT")
    }

    func close() {
        for statement in statements.values { sqlite3_finalize(statement) }
        statements.removeAll()
        if let db { sqlite3_close_v2(db) }
        db = nil
    }

    var isOpen: Bool { db != nil }

    // MARK: - Low level

    func exec(_ sql: String) throws {
        guard let db else { throw Failure.sql("closed") }
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(error)
            throw Failure.sql(message + " — " + String(sql.prefix(60)))
        }
    }

    /// A cached prepared statement (reset and unbound).
    private func prepare(_ sql: String) throws -> OpaquePointer {
        if let cached = statements[sql] {
            sqlite3_reset(cached)
            sqlite3_clear_bindings(cached)
            return cached
        }
        guard let db else { throw Failure.sql("closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Failure.sql(String(cString: sqlite3_errmsg(db)) + " — " + String(sql.prefix(60)))
        }
        statements[sql] = statement
        return statement
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(statement, index, value, -1, Self.transient)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: Int64) {
        sqlite3_bind_int64(statement, index, value)
    }

    private func step(_ statement: OpaquePointer) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            let sql = sqlite3_sql(statement).map { String(cString: $0) } ?? ""
            throw Failure.sql((db.map { String(cString: sqlite3_errmsg($0)) } ?? "step failed") + " — " + String(sql.prefix(60)))
        }
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }

    private func scalarInt(_ sql: String) throws -> Int64 {
        let statement = try prepare(sql)
        defer { sqlite3_reset(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(statement, 0)
    }

    func metaValue(_ key: String) throws -> String? {
        let statement = try prepare("SELECT value FROM meta WHERE key = ?")
        defer { sqlite3_reset(statement) }
        bind(statement, 1, key)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return text(statement, 0)
    }

    /// The `PRAGMA user_version` stored in the file.
    func storedSchemaVersion() throws -> Int64 { try scalarInt("PRAGMA user_version") }

    // MARK: - Files

    func fileRecord(path: String) throws -> FileRecord? {
        let statement = try prepare("SELECT id, size, mtime FROM files WHERE path = ?")
        defer { sqlite3_reset(statement) }
        bind(statement, 1, path)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return FileRecord(id: sqlite3_column_int64(statement, 0), size: sqlite3_column_int64(statement, 1),
                          mtime: sqlite3_column_int64(statement, 2))
    }

    /// Replaces `path`'s row and symbols in one transaction; returns its id.
    @discardableResult
    func replaceFile(path: String, language: String, size: Int64, mtime: Int64,
                     symbols: [IndexedSymbol]) throws -> Int64 {
        try exec("BEGIN IMMEDIATE")
        do {
            if let existing = try fileRecord(path: path) {
                try deleteSymbols(fileID: existing.id)
                let update = try prepare("UPDATE files SET language = ?, size = ?, mtime = ?, indexed_at = ? WHERE id = ?")
                bind(update, 1, language)
                bind(update, 2, size)
                bind(update, 3, mtime)
                bind(update, 4, Int64(Date().timeIntervalSince1970))
                bind(update, 5, existing.id)
                try step(update)
                try insertSymbols(symbols, fileID: existing.id)
                try exec("COMMIT")
                return existing.id
            }
            let insert = try prepare("INSERT INTO files(path, language, size, mtime, indexed_at) VALUES(?, ?, ?, ?, ?)")
            bind(insert, 1, path)
            bind(insert, 2, language)
            bind(insert, 3, size)
            bind(insert, 4, mtime)
            bind(insert, 5, Int64(Date().timeIntervalSince1970))
            try step(insert)
            let id = sqlite3_last_insert_rowid(db)
            try insertSymbols(symbols, fileID: id)
            try exec("COMMIT")
            return id
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func deleteSymbols(fileID: Int64) throws {
        let statement = try prepare("DELETE FROM symbols WHERE file_id = ?")
        bind(statement, 1, fileID)
        try step(statement)
    }

    private func insertSymbols(_ symbols: [IndexedSymbol], fileID: Int64) throws {
        guard !symbols.isEmpty else { return }
        let sql = "INSERT INTO symbols(file_id, name, folded, kind, container, location, line, signature) VALUES(?, ?, ?, ?, ?, ?, ?, ?)"
        for symbol in symbols {
            let statement = try prepare(sql)
            bind(statement, 1, fileID)
            bind(statement, 2, symbol.name)
            bind(statement, 3, Self.folded(symbol.name))
            bind(statement, 4, Int64(symbol.kind.rawValue))
            bind(statement, 5, symbol.container)
            bind(statement, 6, Int64(symbol.location))
            bind(statement, 7, Int64(symbol.line))
            bind(statement, 8, symbol.signature)
            try step(statement)
        }
    }

    /// Deletes the file at `path` and, when `includingDescendants`, every file
    /// below `path/`. Returns the number of files removed.
    @discardableResult
    func deleteFiles(path: String, includingDescendants: Bool) throws -> Int {
        var ids: [Int64] = []
        if let record = try fileRecord(path: path) { ids.append(record.id) }
        if includingDescendants { ids += try files(under: path).map(\.id) }
        try deleteFiles(ids: ids)
        return ids.count
    }

    func deleteFiles(ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try exec("BEGIN IMMEDIATE")
        do {
            for id in ids {
                try deleteSymbols(fileID: id)
                let statement = try prepare("DELETE FROM files WHERE id = ?")
                bind(statement, 1, id)
                try step(statement)
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Files strictly below directory `prefix` ("" = every file).
    func files(under prefix: String) throws -> [(id: Int64, path: String)] {
        let statement: OpaquePointer
        if prefix.isEmpty {
            statement = try prepare("SELECT id, path FROM files")
        } else {
            statement = try prepare("SELECT id, path FROM files WHERE path >= ? AND path < ?")
            bind(statement, 1, prefix + "/")
            bind(statement, 2, prefix + "0")   // "0" follows "/" in byte order
        }
        defer { sqlite3_reset(statement) }
        var out: [(Int64, String)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            out.append((sqlite3_column_int64(statement, 0), text(statement, 1) ?? ""))
        }
        return out
    }

    func fileCount() throws -> Int { Int(try scalarInt("SELECT count(*) FROM files")) }
    func symbolCount() throws -> Int { Int(try scalarInt("SELECT count(*) FROM symbols")) }

    // MARK: - Queries

    private static let symbolColumns = """
        SELECT f.path, f.language, s.name, s.kind, s.container, s.location, s.line, s.signature
        FROM symbols s JOIN files f ON f.id = s.file_id
        """

    private func readRows(_ statement: OpaquePointer, limit: Int, into rows: inout [SymbolRow]) {
        while rows.count < limit, sqlite3_step(statement) == SQLITE_ROW {
            rows.append(SymbolRow(path: text(statement, 0) ?? "", language: text(statement, 1) ?? "",
                                  name: text(statement, 2) ?? "", kind: Int(sqlite3_column_int(statement, 3)),
                                  container: text(statement, 4), location: Int(sqlite3_column_int64(statement, 5)),
                                  line: Int(sqlite3_column_int64(statement, 6)), signature: text(statement, 7)))
        }
    }

    /// Symbols whose folded name starts with `foldedPrefix`, excluding the file
    /// `excludingPath` (relative; nil = none), ordered by name, at most `limit`.
    func symbols(foldedPrefix: String, excludingPath: String?, limit: Int) throws -> [SymbolRow] {
        let statement = try prepare(Self.symbolColumns + """
             WHERE s.folded >= ?1 AND s.folded < ?2 AND (?3 IS NULL OR f.path <> ?3)
             ORDER BY s.folded, s.name, f.path, s.location LIMIT ?4
            """)
        defer { sqlite3_reset(statement) }
        bind(statement, 1, foldedPrefix)
        bind(statement, 2, foldedPrefix + "\u{10FFFF}")
        bind(statement, 3, excludingPath)
        bind(statement, 4, Int64(limit))
        var rows: [SymbolRow] = []
        readRows(statement, limit: limit, into: &rows)
        return rows
    }

    /// Symbols named exactly `name` (case-sensitive), at most `limit`.
    func symbols(named name: String, limit: Int) throws -> [SymbolRow] {
        let statement = try prepare(Self.symbolColumns + """
             WHERE s.folded = ?1 AND s.name = ?2 ORDER BY f.path, s.location LIMIT ?3
            """)
        defer { sqlite3_reset(statement) }
        bind(statement, 1, Self.folded(name))
        bind(statement, 2, name)
        bind(statement, 3, Int64(limit))
        var rows: [SymbolRow] = []
        readRows(statement, limit: limit, into: &rows)
        return rows
    }

    /// Every symbol of one file in document order.
    func symbols(inFile path: String) throws -> [SymbolRow] {
        let statement = try prepare(Self.symbolColumns + " WHERE f.path = ?1 ORDER BY s.location, s.rowid")
        defer { sqlite3_reset(statement) }
        bind(statement, 1, path)
        var rows: [SymbolRow] = []
        readRows(statement, limit: .max, into: &rows)
        return rows
    }

    /// Visits symbols whose folded name contains `units` as an ordered
    /// subsequence (SQL `LIKE '%a%b%'` on the folded column: a cheap filter
    /// for the fuzzy matcher). `body` returns false to stop.
    func forEachSymbol(subsequence folded: [UInt16], _ body: (SymbolRow) -> Bool) throws {
        var pattern = "%"
        for unit in folded {
            let character = String(utf16CodeUnits: [unit], count: 1)
            if character == "%" || character == "_" || character == "\\" { pattern += "\\" }
            pattern += character + "%"
        }
        let statement = try prepare(Self.symbolColumns + " WHERE s.folded LIKE ?1 ESCAPE '\\'")
        defer { sqlite3_reset(statement) }
        bind(statement, 1, pattern)
        var rows: [SymbolRow] = []
        while true {
            rows.removeAll(keepingCapacity: true)
            readRows(statement, limit: 1, into: &rows)
            guard let row = rows.first, body(row) else { return }
        }
    }

    // MARK: - Maintenance

    /// Truncates the WAL into the main file.
    func checkpoint() {
        guard let db else { return }
        sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
    }

    /// Frees as much of the connection's heap (page cache) as possible.
    func releaseMemory() {
        guard let db else { return }
        sqlite3_db_release_memory(db)
    }

    /// CaseFold per UTF-16 unit (the completion matcher's folding).
    static func folded(_ name: String) -> String {
        let units = CaseFold.folded(name)
        return String(utf16CodeUnits: units, count: units.count)
    }
}
