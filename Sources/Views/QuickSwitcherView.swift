import SwiftUI

/// Instant "jump to a note" — searches the local index (no API call) and opens the note.
struct QuickSwitcherView: View {
    @EnvironmentObject var vault: VaultStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [(path: String, title: String)] = []
    @State private var path: [NoteRef] = []

    var body: some View {
        NavigationStack(path: $path) {
            List(results, id: \.path) { item in
                Button {
                    path.append(NoteRef(raw: item.path, isWiki: false))
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).foregroundStyle(.primary)
                        Text(item.path).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if results.isEmpty {
                    ContentUnavailableView("No notes", systemImage: "magnifyingglass")
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
}
