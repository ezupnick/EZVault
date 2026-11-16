import SwiftUI

/// Instant "jump to a note" — searches the local index (no API call) and opens the note.
/// Keeps no history: nothing is shown until you type.
struct QuickSwitcherView: View {
    @EnvironmentObject var vault: VaultStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [(path: String, title: String)] = []
    @State private var path: [NoteRef] = []

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack(path: $path) {
            List {
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
                }
            }
            .overlay {
                if trimmedQuery.isEmpty {
                    ContentUnavailableView("Search your notes", systemImage: "magnifyingglass",
                                           description: Text("Type a note title or folder name."))
                }
            }
            .navigationTitle("Open Note")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search your notes")
            .navigationDestination(for: NoteRef.self) { NoteContentView(ref: $0) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .task(id: query) { results = trimmedQuery.isEmpty ? [] : await vault.quickFind(query) }
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
        path.append(NoteRef(raw: notePath, isWiki: false))
    }
}
