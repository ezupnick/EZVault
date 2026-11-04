import SwiftUI

/// Instant "jump to a note" — searches the local index (no API call) and opens the note.
/// When the field is empty, shows recent searches (swipe to delete, or Clear) and recent notes.
struct QuickSwitcherView: View {
    @EnvironmentObject var vault: VaultStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [(path: String, title: String)] = []
    @State private var recents: [String] = RecentSearches.all()
    @State private var path: [NoteRef] = []

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if trimmedQuery.isEmpty && !recents.isEmpty {
                    Section("Recent searches") {
                        ForEach(recents, id: \.self) { term in
                            Button { query = term } label: {
                                Label(term, systemImage: "clock.arrow.circlepath")
                                    .foregroundStyle(.primary)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    RecentSearches.remove(term)
                                    recents = RecentSearches.all()
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                        Button(role: .destructive) {
                            RecentSearches.clear()
                            recents = []
                        } label: {
                            Label("Clear recent searches", systemImage: "trash")
                        }
                    }
                }

                Section(trimmedQuery.isEmpty ? "Recent notes" : "Notes") {
                    if results.isEmpty {
                        Text(trimmedQuery.isEmpty ? "No notes yet." : "No matches.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(results, id: \.path) { item in
                            Button { open(item.path) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).foregroundStyle(.primary)
                                    Text(item.path).font(.caption2).foregroundStyle(.secondary)
                                }
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
            .task(id: query) {
                results = await vault.quickFind(query)
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            guard let ref = NoteRef(url: url) else { return .systemAction }
            path.append(ref)
            return .handled
        })
    }

    private func open(_ notePath: String) {
        if !trimmedQuery.isEmpty {
            RecentSearches.add(trimmedQuery)
            recents = RecentSearches.all()
        }
        path.append(NoteRef(raw: notePath, isWiki: false))
    }
}
