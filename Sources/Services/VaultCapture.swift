import Foundation

/// Standalone vault capture used by App Intents (Siri/Shortcuts), which run outside the
/// VaultStore instance. Reads the vault bookmark the app saved and writes a new note to
/// the capture folder. Returns the relative path on success, or nil on failure.
enum VaultCapture {
    static func save(text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: "vault_bookmark") else { return nil }

        var stale = false
        guard let root = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale),
              root.startAccessingSecurityScopedResource() else { return nil }
        defer { root.stopAccessingSecurityScopedResource() }

        let folderRaw = defaults.string(forKey: "capture_folder") ?? "EZVault"
        let folder = folderRaw.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
        let base = folder.isEmpty ? "EZVault" : folder

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd-HHmmss"
        let rel = "\(base)/\(fmt.string(from: Date())).md"
        let url = root.appendingPathComponent(rel)

        var ok = false
        var coordError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordError) { u in
            do {
                try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                try trimmed.write(to: u, atomically: true, encoding: .utf8)
                ok = true
            } catch {}
        }
        return ok ? rel : nil
    }
}
