import Foundation

/// Stores recently-opened note paths (most recent first), in UserDefaults.
enum RecentNotes {
    private static let key = "recent_notes"
    private static let maxCount = 25

    static func all() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func add(_ path: String) {
        let p = path.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return }
        var list = all().filter { $0 != p }
        list.insert(p, at: 0)
        UserDefaults.standard.set(Array(list.prefix(maxCount)), forKey: key)
    }

    static func remove(_ path: String) {
        UserDefaults.standard.set(all().filter { $0 != path }, forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
