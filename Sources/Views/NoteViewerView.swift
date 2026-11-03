import SwiftUI

/// Identifies a note to open in the viewer sheet (from a tapped citation link).
struct NotePath: Identifiable {
    let id = UUID()
    let path: String
}

/// Read-only viewer for a single note, shown when a citation link is tapped.
struct NoteViewerView: View {
    let path: String
    @EnvironmentObject var vault: VaultStore
    @Environment(\.dismiss) private var dismiss
    @State private var content: String?
    @State private var loading = true

    private var title: String {
        (path as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if loading {
                    ProgressView().padding(.top, 40)
                } else if let content, !content.isEmpty {
                    MarkdownText(text: content)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                } else {
                    Text("Couldn't load this note.")
                        .foregroundStyle(.secondary)
                        .padding(.top, 40)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task {
                content = await vault.noteBody(path)
                loading = false
            }
        }
    }
}
