import SwiftUI

/// A reference to a note to open — either a direct path or an Obsidian wikilink name.
struct NoteRef: Identifiable, Hashable {
    let id = UUID()
    let raw: String
    let isWiki: Bool

    init(raw: String, isWiki: Bool) {
        self.raw = raw
        self.isWiki = isWiki
    }

    /// Builds a reference from an ezvault://note/<path> or ezvault://wiki/<name> URL.
    init?(url: URL) {
        guard url.scheme == "ezvault" else { return nil }
        let value = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        switch url.host {
        case "note": self.init(raw: value, isWiki: false)
        case "wiki": self.init(raw: value, isWiki: true)
        default: return nil
        }
    }

    var displayName: String {
        isWiki ? raw : (raw as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "")
    }
}

/// Read-only note viewer shown from a tapped link. Wikilinks inside the note are
/// themselves tappable and push further notes onto the stack (Obsidian-style).
struct NoteViewerView: View {
    let ref: NoteRef
    @EnvironmentObject var vault: VaultStore
    @Environment(\.dismiss) private var dismiss
    @State private var path: [NoteRef] = []

    var body: some View {
        NavigationStack(path: $path) {
            NoteContentView(ref: ref)
                .navigationDestination(for: NoteRef.self) { NoteContentView(ref: $0) }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
        .environment(\.openURL, OpenURLAction { url in
            guard let next = NoteRef(url: url) else { return .systemAction }
            path.append(next)
            return .handled
        })
    }
}

struct NoteContentView: View {
    let ref: NoteRef
    @EnvironmentObject var vault: VaultStore
    @State private var content: String?
    @State private var resolvedTitle: String?
    @State private var backlinks: [String] = []
    @State private var related: [String] = []
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                } else if let content, !content.isEmpty {
                    MarkdownText(text: content)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Couldn't find this note.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.top, 40)
                }
                linkSection("Related", related)
                linkSection("Linked from", backlinks)
            }
            .padding()
        }
        .navigationTitle(resolvedTitle ?? ref.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let path = ref.isWiki ? await vault.resolveWikilink(ref.raw) : ref.raw
            if let path {
                RecentNotes.add(path)
                let name = (path as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "")
                resolvedTitle = name
                content = await vault.noteBody(path)
                related = await vault.relatedNotes(toPath: path)
                backlinks = await vault.backlinks(toNoteNamed: name)
            }
            loading = false
        }
    }

    @ViewBuilder
    private func linkSection(_ title: String, _ paths: [String]) -> some View {
        if !paths.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                ForEach(paths, id: \.self) { p in
                    MarkdownText(text: "[[\((p as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: ""))]]")
                }
            }
        }
    }
}
