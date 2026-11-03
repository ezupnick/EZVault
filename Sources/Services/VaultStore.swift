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

    /// Whether Claude may create/append notes (mirrors the Settings toggle).
    var writingEnabled = true

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
                let parsed = parseNote(rel: rel, body: body)
                let vec = Embedder.shared.embed(parsed.embedText)
                await index.upsert(path: rel, mtime: mtime, title: parsed.title, body: body, tags: parsed.tags, vec: vec)
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

    private nonisolated static func noteTitle(rel: String, frontmatter: String?, content: String) -> String {
        if let fm = frontmatter, let t = frontmatterValue("title", in: fm), !t.isEmpty { return t }
        for line in content.prefix(2000).split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("# ") { return String(t.dropFirst(2)) }
        }
        return (rel as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "")
    }

    /// Parses a note into its title, normalized tag string, and the text to embed —
    /// separating YAML frontmatter from the content so it doesn't pollute either.
    private nonisolated static func parseNote(rel: String, body: String) -> (title: String, tags: String, embedText: String) {
        let (fm, content) = splitFrontmatter(body)
        let title = noteTitle(rel: rel, frontmatter: fm, content: content)
        let tagList = extractTags(frontmatter: fm, content: content)
        let tags = tagList.isEmpty ? "" : " " + tagList.map { "#\($0)" }.joined(separator: " ") + " "
        let tagText = tagList.isEmpty ? "" : "\nTags: " + tagList.joined(separator: ", ")
        let embedText = title + "\n" + String(content.prefix(500)) + tagText
        return (title, tags, embedText)
    }

    /// Splits a leading YAML frontmatter block (--- … ---) from the note content.
    private nonisolated static func splitFrontmatter(_ body: String) -> (frontmatter: String?, content: String) {
        guard body.hasPrefix("---") else { return (nil, body) }
        let lines = body.components(separatedBy: "\n")
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else { return (nil, body) }
        for i in 1..<lines.count where lines[i].trimmingCharacters(in: .whitespaces) == "---" {
            let fm = lines[1..<i].joined(separator: "\n")
            let content = i + 1 < lines.count ? lines[(i + 1)...].joined(separator: "\n") : ""
            return (fm, content)
        }
        return (nil, body)
    }

    private nonisolated static func frontmatterValue(_ key: String, in fm: String) -> String? {
        for line in fm.components(separatedBy: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == key {
                let v = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                return v.isEmpty ? nil : v
            }
        }
        return nil
    }

    /// Tags from frontmatter (`tags:` inline or list) plus inline `#tags`, lowercased & de-duped.
    private nonisolated static func extractTags(frontmatter: String?, content: String) -> [String] {
        var tags = Set<String>()
        if let fm = frontmatter {
            let lines = fm.components(separatedBy: "\n")
            var i = 0
            while i < lines.count {
                let lower = lines[i].trimmingCharacters(in: .whitespaces).lowercased()
                if lower.hasPrefix("tags:") || lower.hasPrefix("tag:") {
                    let after = lines[i].drop(while: { $0 != ":" }).dropFirst().trimmingCharacters(in: .whitespaces)
                    if after.isEmpty {
                        var j = i + 1
                        while j < lines.count {
                            let l = lines[j].trimmingCharacters(in: .whitespaces)
                            if l.hasPrefix("- ") { tags.insert(normalizeTag(String(l.dropFirst(2)))); j += 1 } else { break }
                        }
                        i = j; continue
                    } else {
                        let cleaned = after.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
                        for t in cleaned.split(whereSeparator: { $0 == "," || $0 == " " }) { tags.insert(normalizeTag(String(t))) }
                    }
                }
                i += 1
            }
        }
        if let re = try? NSRegularExpression(pattern: "(?:^|\\s)#([A-Za-z0-9_][A-Za-z0-9_/-]*)") {
            let ns = content as NSString
            re.enumerateMatches(in: content, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                if let m, m.numberOfRanges > 1 { tags.insert(normalizeTag(ns.substring(with: m.range(at: 1)))) }
            }
        }
        return tags.filter { !$0.isEmpty }.sorted()
    }

    private nonisolated static func normalizeTag(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "#\"' ")).lowercased()
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
            let qvec = Embedder.shared.embed(query)
            let hits = await index.hybrid(ftsQuery: Self.ftsQuery(query), queryVector: qvec, limit: limit)
            guard !hits.isEmpty else { return "No notes matched \"\(query)\"." }
            return hits.map {
                let name = ($0.path as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "")
                let tags = $0.tags.trimmingCharacters(in: .whitespaces)
                let tagLine = tags.isEmpty ? "" : "\n  tags: \(tags)"
                return "- [[\(name)]] — \($0.title)\(tagLine)\n  path: \($0.path)\n  excerpt: …\($0.snippet)…"
            }.joined(separator: "\n")

        case "read_note":
            let path = (input["path"] as? String) ?? ""
            guard let body = await index.body(forPath: path) else {
                return "No note found at path \(path)."
            }
            let cap = 24_000
            return body.count > cap ? String(body.prefix(cap)) + "\n\n[truncated]" : body

        case "find_by_tag":
            let clean = ((input["tag"] as? String) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "# "))
            let limit = max(1, min((input["limit"] as? Int) ?? 50, 300))
            let paths = await index.notesWithTag(clean, limit: limit)
            guard !paths.isEmpty else { return "No notes tagged #\(clean)." }
            return "Notes tagged #\(clean):\n" + paths.joined(separator: "\n")

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

        case "append_note":
            return await appendToNote(path: (input["path"] as? String) ?? "", text: (input["text"] as? String) ?? "")

        case "create_note":
            return await createNote(path: (input["path"] as? String) ?? "", text: (input["text"] as? String) ?? "")

        case "edit_note":
            return await editNote(path: (input["path"] as? String) ?? "",
                                   find: (input["find"] as? String) ?? "",
                                   replace: (input["replace"] as? String) ?? "")

        default:
            return "Unknown tool \(name)."
        }
    }

    /// Fetches a note's full text for the in-app viewer.
    func noteBody(_ path: String) async -> String? {
        await index.body(forPath: path)
    }

    /// Resolves an Obsidian wikilink target (name/title/path) to a note path.
    func resolveWikilink(_ target: String) async -> String? {
        await index.pathForName(target)
    }

    /// A tappable Markdown citation link for a note, for the model to drop into answers.
    static func citation(title: String, path: String) -> String {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return "[\(title)](ezvault://note/\(encoded))"
    }

    // MARK: Writing to the vault (non-destructive: append / create-only)

    func appendToNote(path: String, text: String) async -> String {
        guard writingEnabled else { return Self.editingDisabled }
        guard let (url, rel) = resolve(path) else { return "Invalid note path \"\(path)\"." }
        var ok = false
        var coordError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordError) { u in
            let existing = (try? String(contentsOf: u, encoding: .utf8)) ?? ""
            let addition = text.hasSuffix("\n") ? text : text + "\n"
            let combined = existing.isEmpty ? addition
                : existing.trimmingCharacters(in: .newlines) + "\n\n" + addition
            do {
                try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                try combined.write(to: u, atomically: true, encoding: .utf8)
                ok = true
            } catch {}
        }
        guard ok else { return "Couldn't write to \(rel)." }
        await indexSingle(url: url, rel: rel)
        return "Appended to \(rel)."
    }

    func createNote(path: String, text: String) async -> String {
        guard writingEnabled else { return Self.editingDisabled }
        guard let (url, rel) = resolve(path) else { return "Invalid note path \"\(path)\"." }
        if FileManager.default.fileExists(atPath: url.path) {
            return "A note already exists at \(rel). Use append_note to add to it instead."
        }
        var ok = false
        var coordError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordError) { u in
            do {
                try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: u, atomically: true, encoding: .utf8)
                ok = true
            } catch {}
        }
        guard ok else { return "Couldn't create \(rel)." }
        await indexSingle(url: url, rel: rel)
        return "Created \(rel)."
    }

    /// Places or revises text anywhere in a note by replacing an exact, unique snippet.
    func editNote(path: String, find: String, replace: String) async -> String {
        guard writingEnabled else { return Self.editingDisabled }
        guard !find.isEmpty else { return "Provide the exact text to replace (`find`)." }
        guard let (url, rel) = resolve(path) else { return "Invalid note path \"\(path)\"." }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return "No note at \(rel). Use create_note to make it."
        }
        var result = "Couldn't write to \(rel)."
        var coordError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordError) { u in
            guard let existing = try? String(contentsOf: u, encoding: .utf8) else {
                result = "Couldn't read \(rel)."; return
            }
            let occurrences = existing.components(separatedBy: find).count - 1
            if occurrences == 0 {
                result = "Couldn't find that text in \(rel). Read the note and copy the exact snippet to replace."
                return
            }
            if occurrences > 1 {
                result = "That snippet appears \(occurrences) times in \(rel). Include more surrounding text so it matches once."
                return
            }
            let updated = existing.replacingOccurrences(of: find, with: replace)
            do { try updated.write(to: u, atomically: true, encoding: .utf8); result = "" } catch {}
        }
        guard result.isEmpty else { return result }
        await indexSingle(url: url, rel: rel)
        return "Edited \(rel)."
    }

    private static let editingDisabled =
        "Note editing is turned off. Ask the user to enable \"Allow Claude to edit notes\" in Settings."

    /// Validates a note path, keeps it inside the vault, and ensures a .md extension.
    private func resolve(_ path: String) -> (url: URL, rel: String)? {
        guard let root = vaultURL else { return nil }
        var rel = path.trimmingCharacters(in: .whitespaces)
        if rel.hasPrefix("/") { rel.removeFirst() }
        guard !rel.isEmpty, !rel.contains("..") else { return nil }
        if (rel as NSString).pathExtension.lowercased() != "md" { rel += ".md" }
        let url = root.appendingPathComponent(rel)
        guard url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path) else { return nil }
        return (url, rel)
    }

    /// Re-index a single note right after it's written, so it's immediately searchable.
    private func indexSingle(url: URL, rel: String) async {
        guard let body = Self.readContent(url) else { return }
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate)?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
        let parsed = Self.parseNote(rel: rel, body: body)
        let vec = Embedder.shared.embed(parsed.embedText)
        await index.upsert(path: rel, mtime: mtime, title: parsed.title, body: body, tags: parsed.tags, vec: vec)
        indexedCount = await index.count()
    }
}
