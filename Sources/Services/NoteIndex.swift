import Foundation
import SQLite3

// SQLite wants to know whether a bound string can be freed; TRANSIENT = make a copy.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// On-device index of the vault: SQLite FTS5 for keyword search plus a per-note
/// semantic vector for similarity search. Lives off the main thread as an actor.
actor NoteIndex {
    private var db: OpaquePointer?

    /// Loaded note vectors, cached in memory for fast cosine scoring. Invalidated on writes.
    private var vectorCache: [(path: String, vec: [Float])]?

    /// Bump to force a full rebuild when the stored shape changes (e.g. adding vectors).
    private static let schemaVersion: Int32 = 2

    init() { db = NoteIndex.prepare() }

    // MARK: Schema

    private static func dbURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("vault-index.sqlite")
    }

    /// Opens the database and ensures the schema/triggers exist. Nonisolated so it can
    /// run from the actor's initializer. External-content FTS5 mirrors `files`.
    private static func prepare() -> OpaquePointer? {
        var handle: OpaquePointer?
        guard sqlite3_open(dbURL().path, &handle) == SQLITE_OK else { return nil }
        sqlite3_exec(handle, "PRAGMA journal_mode=WAL;", nil, nil, nil)

        // If the stored schema predates vectors, drop and rebuild (one-time re-index).
        var version: Int32 = 0
        var vstmt: OpaquePointer?
        if sqlite3_prepare_v2(handle, "PRAGMA user_version;", -1, &vstmt, nil) == SQLITE_OK,
           sqlite3_step(vstmt) == SQLITE_ROW {
            version = sqlite3_column_int(vstmt, 0)
        }
        sqlite3_finalize(vstmt)
        if version < schemaVersion {
            sqlite3_exec(handle, "DROP TABLE IF EXISTS notes_fts;", nil, nil, nil)
            sqlite3_exec(handle, "DROP TABLE IF EXISTS files;", nil, nil, nil)
        }

        let statements = [
            """
            CREATE TABLE IF NOT EXISTS files(
                path  TEXT PRIMARY KEY,
                mtime REAL NOT NULL,
                title TEXT NOT NULL,
                body  TEXT NOT NULL,
                vec   BLOB
            );
            """,
            "CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts USING fts5(title, body, content='files', content_rowid='rowid');",
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
        sqlite3_exec(handle, "PRAGMA user_version=\(schemaVersion);", nil, nil, nil)
        return handle
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    // MARK: Writes

    func beginBatch() { exec("BEGIN;") }
    func endBatch()   { exec("COMMIT;"); vectorCache = nil }

    func mtime(forPath path: String) -> Double? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT mtime FROM files WHERE path=?;", -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_double(stmt, 0) : nil
    }

    func upsert(path: String, mtime: Double, title: String, body: String, vec: [Float]?) {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = """
            INSERT INTO files(path,mtime,title,body,vec) VALUES(?,?,?,?,?)
            ON CONFLICT(path) DO UPDATE SET mtime=excluded.mtime, title=excluded.title, body=excluded.body, vec=excluded.vec;
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 2, mtime)
        sqlite3_bind_text(stmt, 3, title, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, body, -1, SQLITE_TRANSIENT)
        if let vec, !vec.isEmpty {
            let data = vec.withUnsafeBytes { Data($0) }
            data.withUnsafeBytes { raw in
                _ = sqlite3_bind_blob(stmt, 5, raw.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
            }
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        sqlite3_step(stmt)
        vectorCache = nil
    }

    func removeMissing(keep: Set<String>) {
        let gone = allPaths().subtracting(keep)
        for path in gone { delete(path: path) }
        if !gone.isEmpty { vectorCache = nil }
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

    /// Keyword (FTS/bm25) search, title-weighted.
    func search(_ ftsQuery: String, limit: Int) -> [Hit] {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = """
            SELECT f.path, f.title, snippet(notes_fts, 1, '', '', '…', 12)
            FROM notes_fts JOIN files f ON f.rowid = notes_fts.rowid
            WHERE notes_fts MATCH ?
            ORDER BY bm25(notes_fts, 10.0, 1.0)
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

    /// Hybrid search: fuse keyword (FTS) and semantic (vector) results with
    /// reciprocal-rank fusion, so each catches what the other misses.
    func hybrid(ftsQuery: String, queryVector: [Float]?, limit: Int) -> [Hit] {
        let pool = max(limit * 3, 15)
        let ftsHits = search(ftsQuery, limit: pool)
        let ftsByPath = Dictionary(ftsHits.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })

        var score: [String: Double] = [:]
        for (i, h) in ftsHits.enumerated() { score[h.path, default: 0] += 1.0 / Double(60 + i) }
        if let queryVector {
            for (i, s) in semanticRanked(queryVector: queryVector, limit: pool).enumerated() {
                score[s.path, default: 0] += 1.0 / Double(60 + i)
            }
        }

        let ordered = score.sorted { $0.value > $1.value }.prefix(limit)
        return ordered.compactMap { entry in
            if let hit = ftsByPath[entry.key] { return hit }
            guard let te = titleAndExcerpt(path: entry.key) else { return nil }
            return Hit(path: entry.key, title: te.title, snippet: te.excerpt)
        }
    }

    func body(forPath path: String) -> String? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT body FROM files WHERE path=?;", -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: c)
    }

    /// Resolves a wikilink target (note name, title, or path) to a note path.
    func pathForName(_ name: String) -> String? {
        var clean = name.trimmingCharacters(in: .whitespaces)
        if clean.lowercased().hasSuffix(".md") { clean = String(clean.dropLast(3)) }
        let lower = clean.lowercased()
        // 1) exact path, or basename match in any folder
        if let p = queryOne("SELECT path FROM files WHERE lower(path)=? OR lower(path) LIKE ? ORDER BY length(path) LIMIT 1;",
                            binds: [lower + ".md", "%/" + lower + ".md"]) { return p }
        // 2) exact title (from a leading # heading)
        if let p = queryOne("SELECT path FROM files WHERE lower(title)=? LIMIT 1;", binds: [lower]) { return p }
        // 3) loose path contains
        return queryOne("SELECT path FROM files WHERE lower(path) LIKE ? ORDER BY length(path) LIMIT 1;",
                        binds: ["%" + lower + "%"])
    }

    private func queryOne(_ sql: String, binds: [String]) -> String? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        for (i, b) in binds.enumerated() { sqlite3_bind_text(stmt, Int32(i + 1), b, -1, SQLITE_TRANSIENT) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: c)
    }

    private func titleAndExcerpt(path: String) -> (title: String, excerpt: String)? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT title, substr(body,1,160) FROM files WHERE path=?;", -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let title = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
        let excerpt = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
        return (title, excerpt)
    }

    struct Listing { let paths: [String]; let total: Int }

    /// Lists note paths, newest-first by default; also returns the total match count
    /// so callers can tell the model when the list was truncated.
    func list(prefix: String?, limit: Int, recentFirst: Bool) -> Listing {
        let total = countFiles(prefix: prefix)
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let order = recentFirst ? "mtime DESC" : "path ASC"
        let sql = prefix == nil
            ? "SELECT path FROM files ORDER BY \(order) LIMIT ?;"
            : "SELECT path FROM files WHERE path LIKE ? ORDER BY \(order) LIMIT ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return Listing(paths: [], total: total) }
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
        return Listing(paths: out, total: total)
    }

    private func countFiles(prefix: String?) -> Int {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = prefix == nil
            ? "SELECT count(*) FROM files;"
            : "SELECT count(*) FROM files WHERE path LIKE ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        if let prefix { sqlite3_bind_text(stmt, 1, prefix + "%", -1, SQLITE_TRANSIENT) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    // MARK: Semantic scoring

    private func semanticRanked(queryVector: [Float], limit: Int) -> [(path: String, score: Float)] {
        let qNorm = sqrt(queryVector.reduce(Float(0)) { $0 + $1 * $1 })
        guard qNorm > 0 else { return [] }
        var scored: [(String, Float)] = []
        for (path, v) in loadVectors() where v.count == queryVector.count {
            var dot: Float = 0, vNorm2: Float = 0
            for i in 0..<v.count {
                dot += v[i] * queryVector[i]
                vNorm2 += v[i] * v[i]
            }
            let denom = qNorm * sqrt(vNorm2)
            if denom > 0 { scored.append((path, dot / denom)) }
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map { (path: $0.0, score: $0.1) }
    }

    private func loadVectors() -> [(path: String, vec: [Float])] {
        if let vectorCache { return vectorCache }
        var out: [(String, [Float])] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        if sqlite3_prepare_v2(db, "SELECT path, vec FROM files WHERE vec IS NOT NULL;", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let pc = sqlite3_column_text(stmt, 0), let raw = sqlite3_column_blob(stmt, 1) else { continue }
                let path = String(cString: pc)
                let bytes = Int(sqlite3_column_bytes(stmt, 1))
                let count = bytes / MemoryLayout<Float>.size
                guard count > 0 else { continue }
                // Copy out (blob storage isn't guaranteed aligned for direct Float access).
                let data = Data(bytes: raw, count: bytes)
                var floats = [Float](repeating: 0, count: count)
                _ = floats.withUnsafeMutableBytes { data.copyBytes(to: $0) }
                out.append((path, floats))
            }
        }
        let result = out.map { (path: $0.0, vec: $0.1) }
        vectorCache = result
        return result
    }
}
