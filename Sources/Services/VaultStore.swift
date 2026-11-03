import SwiftUI
import UniformTypeIdentifiers

/// Owns the picked vault folder (via a security-scoped bookmark), keeps the local
/// index in sync, and serves Claude's tool calls against it.
@MainActor
final class VaultStore: ObservableObject {
    @Published private(set) var vaultName: String?
    @Published private(set) var isIndexing = false
    @Published private(set) var indexedCount = 0
    @Published private(set) var progress: Double = 0      // 0...1 while indexing
    @Published var lastError: String?

    private let index = NoteIndex()
    private var vaultURL: URL?
    private let bookmarkKey = "vault_bookmark"

    /// Ready to answer from notes once a folder is picked and something is indexed.
    var isReady: Bool { vaultURL != nil && indexedCount > 0 }

    init() {
        Task { await restore() }
    }

    // MARK: Folder selection / persistence

    func restore() async {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else {
            lastError = "Couldn't find your vault folder. It may have been moved or deleted — please pick it again."
            return
        }
        guard url.startAccessingSecurityScopedResource() else {
            lastError = "Lost permission to access \(url.lastPathComponent). Please pick the vault folder again."
            return
        }
        if stale, let fresh = try? url.bookmarkData(options: .minimalBookmark) {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey)
        }
        vaultURL = url
        vaultName = url.lastPathComponent
        indexedCount = await index.count()
        await reindex()
    }

    func setVault(_ url: URL) async {
        guard url.startAccessingSecurityScopedResource() else {
            lastError = "Couldn't access that folder."
            return
        }
        // Release the previous vault only once the new one is open, so a failed pick keeps the old vault usable.
        vaultURL?.stopAccessingSecurityScopedResource()
        if let data = try? url.bookmarkData(options: .minimalBookmark) {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        }
        vaultURL = url
        vaultName = url.lastPathComponent
        await reindex()
    }

    // MARK: Indexing

    func reindex() async {
        guard let root = vaultURL, !isIndexing else { return }
        isIndexing = true
        progress = 0
        lastError = nil
        let idx = index

        await Task.detached(priority: .utility) {
            // Access is reference-counted; hold our own claim for the whole background pass.
            let accessing = root.startAccessingSecurityScopedResource()
            defer { if accessing { root.stopAccessingSecurityScopedResource() } }
            await VaultStore.performIndex(root: root, index: idx) { done, total in
                await MainActor.run { self.progress = total == 0 ? 1 : Double(done) / Double(total) }
            }
        }.value

        indexedCount = await index.count()
        progress = 1
        isIndexing = false
    }

    /// Heavy work: enumerate markdown files, read changed ones, update the index.
    /// Runs off the main actor. iCloud placeholders are downloaded on demand.
    private nonisolated static func performIndex(
        root: URL,
        index: NoteIndex,
        progress: @escaping (Int, Int) async -> Void
    ) async {
        let files = markdownFiles(in: root)
        let total = files.count
        var kept = Set<String>()

        await index.beginBatch()
        for (i, url) in files.enumerated() {
            let rel = relativePath(of: url, under: root)
            kept.insert(rel)
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate)?.timeIntervalSince1970 ?? 0
            if await index.mtime(forPath: rel) != mtime, let body = readContent(url) {
                await index.upsert(path: rel, mtime: mtime, title: noteTitle(rel: rel, body: body), body: body)
            }
            if i % 50 == 0 { await progress(i, total) }
        }
        await index.endBatch()
        await index.removeMissing(keep: kept)
        await progress(total, total)
    }

    // MARK: File helpers (background)

    private nonisolated static func markdownFiles(in root: URL) -> [URL] {
        let fm = FileManager.default
        guard let en = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]   // skips .obsidian and other dotfiles
        ) else { return [] }
        var out: [URL] = []
        for case let url as URL in en where url.pathExtension.lowercased() == "md" {
            out.append(url)
        }
        return out
    }

    private nonisolated static func relativePath(of url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let p = url.standardizedFileURL.path
        guard p.hasPrefix(rootPath) else { return url.lastPathComponent }
        return String(p.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private nonisolated static func noteTitle(rel: String, body: String) -> String {
        for line in body.prefix(2000).split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("# ") { return String(t.dropFirst(2)) }
        }
        return (rel as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "")
    }

    private nonisolated static func readContent(_ url: URL) -> String? {
        ensureDownloaded(url)
        var text: String?
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { u in
            text = try? String(contentsOf: u, encoding: .utf8)
        }
        return text
    }

    /// iCloud offloads files it thinks are unused; pull them down before reading.
    private nonisolated static func ensureDownloaded(_ url: URL) {
        let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            .ubiquitousItemDownloadingStatus
        guard let status, status != .current else { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        for _ in 0..<50 {   // best-effort wait, ~5s
            let s = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
                .ubiquitousItemDownloadingStatus
            if s == .current { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    // MARK: FTS query sanitisation

    /// Turn free text into a safe FTS5 query: each token becomes a quoted phrase, AND-ed.
    private static func ftsQuery(_ raw: String) -> String {
        let tokens = raw.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard !tokens.isEmpty else {
            return "\"\(raw.replacingOccurrences(of: "\"", with: ""))\""
        }
        // OR the tokens for recall; bm25 (title-weighted) ranks the best matches first.
        return tokens.map { "\"\($0)\"" }.joined(separator: " OR ")
    }
}

// MARK: - Claude tool execution

extension VaultStore: ToolRunner {
    func run(name: String, input: [String: Any]) async -> String {
        switch name {
        case "search_notes":
            let query = (input["query"] as? String) ?? ""
            let limit = max(1, min((input["limit"] as? Int) ?? 8, 20))
            let hits = await index.search(Self.ftsQuery(query), limit: limit)
            guard !hits.isEmpty else { return "No notes matched \"\(query)\"." }
            return hits.map {
                "- \($0.title)\n  link: \(Self.citation(title: $0.title, path: $0.path))\n  path: \($0.path)\n  excerpt: …\($0.snippet)…"
            }.joined(separator: "\n")

        case "read_note":
            let path = (input["path"] as? String) ?? ""
            guard let body = await index.body(forPath: path) else {
                return "No note found at path \(path)."
            }
            let cap = 24_000
            return body.count > cap ? String(body.prefix(cap)) + "\n\n[truncated]" : body

        case "list_notes":
            let folder = input["folder"] as? String
            let recentFirst = (input["sort"] as? String) != "name"   // default: newest first
            let limit = max(1, min((input["limit"] as? Int) ?? 300, 1000))
            let listing = await index.list(prefix: folder, limit: limit, recentFirst: recentFirst)
            guard !listing.paths.isEmpty else { return "No notes found." }
            let order = recentFirst ? "newest modified first" : "by name"
            var header = "\(listing.total) note(s)\(folder.map { " under \"\($0)\"" } ?? ""), \(order):"
            if listing.paths.count < listing.total {
                header += " (showing first \(listing.paths.count) — narrow with a folder prefix, or use search_notes)"
            }
            return header + "\n" + listing.paths.joined(separator: "\n")

        default:
            return "Unknown tool \(name)."
        }
    }

    /// Fetches a note's full text for the in-app viewer.
    func noteBody(_ path: String) async -> String? {
        await index.body(forPath: path)
    }

    /// A tappable Markdown citation link for a note, for the model to drop into answers.
    static func citation(title: String, path: String) -> String {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return "[\(title)](ezvault://note/\(encoded))"
    }
}
