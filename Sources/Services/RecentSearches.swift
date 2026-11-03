import Foundation

/// Stores the quick-switcher's recent search terms (most recent first), in UserDefaults.
enum RecentSearches {
    private static let key = "recent_searches"
    private static let maxCount = 12

    static func all() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func add(_ term: String) {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        var list = all().filter { $0.caseInsensitiveCompare(t) != .orderedSame }
        list.insert(t, at: 0)
        UserDefaults.standard.set(Array(list.prefix(maxCount)), forKey: key)
    }

    static func remove(_ term: String) {
        UserDefaults.standard.set(all().filter { $0 != term }, forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
