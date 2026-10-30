import Foundation
import SQLite3

// SQLite wants to know whether a bound string can be freed; TRANSIENT = make a copy.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// On-device full-text index of the vault, backed by the system SQLite (FTS5).
/// Lives off the main thread as an actor; all note storage/search goes through here.
actor NoteIndex {
    private var db: OpaquePointer?

    init() {
        db = NoteIndex.prepare()
    }

    // MARK: Schema

    private static func dbURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("vault-index.sqlite")
    }

    /// Opens the database and ensures the schema/triggers exist. Nonisolated so it can
    /// run from the actor's initializer without crossing isolation (Swift 6-clean).
    /// External-content FTS5: the index mirrors `files`, kept in sync by triggers.
    private static func prepare() -> OpaquePointer? {
        var handle: OpaquePointer?
        guard sqlite3_open(dbURL().path, &handle) == SQLITE_OK else { return nil }
        let statements = [
            "PRAGMA journal_mode=WAL;",
            """
            CREATE TABLE IF NOT EXISTS files(
                path  TEXT PRIMARY KEY,
                mtime REAL NOT NULL,
                title TEXT NOT NULL,
                body  TEXT NOT NULL
            );
            """,
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts USING fts5(
                title, body, content='files', content_rowid='rowid'
            );
            """,
            """
            CREATE TRIGGER IF NOT EXISTS files_ai AFTER INSERT ON files BEGIN
              INSERT INTO notes_fts(rowid,title,body) VALUES(new.rowid,new.title,new.body);
            END;
            """,
            """
            CREATE TRIGGER IF NOT EXISTS files_ad AFTER DELETE ON files BEGIN
              INSERT INTO notes_fts(notes_fts,rowid,title,body) VALUES('delete',old.rowid,old.title,old.body);
            END;
            """,
            """
            CREATE TRIGGER IF NOT EXISTS files_au AFTER UPDATE ON files BEGIN
              INSERT INTO notes_fts(notes_fts,rowid,title,body) VALUES('delete',old.rowid,old.title,old.body);
              INSERT INTO notes_fts(rowid,title,body) VALUES(new.rowid,new.title,new.body);
            END;
            """
        ]
        for sql in statements { sqlite3_exec(handle, sql, nil, nil, nil) }
        return handle
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    // MARK: Writes

    func beginBatch() { exec("BEGIN;") }
    func endBatch()   { exec("COMMIT;") }

    func mtime(forPath path: String) -> Double? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT mtime FROM files WHERE path=?;", -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_double(stmt, 0) : nil
    }

    func upsert(path: String, mtime: Double, title: String, body: String) {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = """
            INSERT INTO files(path,mtime,title,body) VALUES(?,?,?,?)
            ON CONFLICT(path) DO UPDATE SET mtime=excluded.mtime, title=excluded.title, body=excluded.body;
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 2, mtime)
        sqlite3_bind_text(stmt, 3, title, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, body, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    func removeMissing(keep: Set<String>) {
        for path in allPaths().subtracting(keep) { delete(path: path) }
    }

    private func delete(path: String) {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "DELETE FROM files WHERE path=?;", -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    // MARK: Reads

    func count() -> Int {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM files;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    private func allPaths() -> Set<String> {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        var out = Set<String>()
        guard sqlite3_prepare_v2(db, "SELECT path FROM files;", -1, &stmt, nil) == SQLITE_OK else { return out }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { out.insert(String(cString: c)) }
        }
        return out
    }

    struct Hit { let path: String; let title: String; let snippet: String }

    func search(_ ftsQuery: String, limit: Int) -> [Hit] {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = """
            SELECT f.path, f.title, snippet(notes_fts, 1, '', '', '…', 12)
            FROM notes_fts JOIN files f ON f.rowid = notes_fts.rowid
            WHERE notes_fts MATCH ?
            ORDER BY rank
            LIMIT ?;
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(stmt, 1, ftsQuery, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        var out: [Hit] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let path = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let title = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let snip = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            out.append(Hit(path: path, title: title, snippet: snip))
        }
        return out
    }

    func body(forPath path: String) -> String? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT body FROM files WHERE path=?;", -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: c)
    }

    func paths(prefix: String?, limit: Int) -> [String] {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = prefix == nil
            ? "SELECT path FROM files ORDER BY path LIMIT ?;"
            : "SELECT path FROM files WHERE path LIKE ? ORDER BY path LIMIT ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        if let prefix {
            sqlite3_bind_text(stmt, 1, prefix + "%", -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(limit))
        } else {
            sqlite3_bind_int(stmt, 1, Int32(limit))
        }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { out.append(String(cString: c)) }
        }
        return out
    }
}
