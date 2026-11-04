import SwiftUI

/// Instant "jump to a note" — searches the local index (no API call) and opens the note.
/// When the field is empty, shows recent searches and recently-opened notes, each of which
/// you can delete individually (swipe) or clear entirely.
struct QuickSwitcherView: View {
    @EnvironmentObject var vault: VaultStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [(path: String, title: String)] = []
    @State private var recentSearches: [String] = RecentSearches.all()
    @State private var recentNotes: [String] = RecentNotes.all()
    @State private var path: [NoteRef] = []

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if trimmedQuery.isEmpty && !recentSearches.isEmpty {
                    Section("Recent searches") {
                        ForEach(recentSearches, id: \.self) { term in
                            Button { query = term } label: {
                                Label(term, systemImage: "clock.arrow.circlepath").foregroundStyle(.primary)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    RecentSearches.remove(term)
                                    recentSearches = RecentSearches.all()
                                } label: { Label("Delete", systemImage: "trash") }
                            }
                        }
                        Button(role: .destructive) {
                            RecentSearches.clear(); recentSearches = []
                        } label: { Label("Clear recent searches", systemImage: "trash") }
                    }
                }

                if trimmedQuery.isEmpty && !recentNotes.isEmpty {
                    Section("Recently opened") {
                        ForEach(recentNotes, id: \.self) { p in
                            Button { open(p) } label: { noteRow(p) }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        RecentNotes.remove(p)
                                        recentNotes = RecentNotes.all()
                                    } label: { Label("Delete", systemImage: "trash") }
                                }
                        }
                        Button(role: .destructive) {
                            RecentNotes.clear(); recentNotes = []
                        } label: { Label("Clear recently opened", systemImage: "trash") }
                    }
                }

                if !trimmedQuery.isEmpty {
                    Section("Notes") {
                        if results.isEmpty {
                            Text("No matches.").foregroundStyle(.secondary)
                        } else {
                            ForEach(results, id: \.path) { item in
                                Button { open(item.path) } label: { noteRow(item.path, title: item.title) }
                            }
                        }
                    }
                } else if recentNotes.isEmpty {
                    Section("Recent notes") {
                        if results.isEmpty {
                            Text("No notes yet.").foregroundStyle(.secondary)
                        } else {
                            ForEach(results, id: \.path) { item in
                                Button { open(item.path) } label: { noteRow(item.path, title: item.title) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Open Note")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search your notes")
            .navigationDestination(for: NoteRef.self) { NoteContentView(ref: $0) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .task(id: query) { results = await vault.quickFind(query) }
        }
        .environment(\.openURL, OpenURLAction { url in
            guard let ref = NoteRef(url: url) else { return .systemAction }
            path.append(ref)
            return .handled
        })
    }

    private func noteRow(_ p: String, title: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title ?? (p as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: ""))
                .foregroundStyle(.primary)
            Text(p).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func open(_ notePath: String) {
        if !trimmedQuery.isEmpty {
            RecentSearches.add(trimmedQuery)
            recentSearches = RecentSearches.all()
        }
        RecentNotes.add(notePath)
        recentNotes = RecentNotes.all()
        path.append(NoteRef(raw: notePath, isWiki: false))
    }
}
