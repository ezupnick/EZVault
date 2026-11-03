import SwiftUI

struct ChatView: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var vault: VaultStore
    @StateObject private var vm = ChatViewModel()
    @State private var input = ""
    @State private var showSettings = false
    @State private var noteToOpen: NoteRef?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                messageList
                if let activity = vm.activity { activityRow(activity) }
                inputBar
            }
            .navigationTitle("EZVault")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text("EZVault").font(.headline)
                        if let name = vault.vaultName {
                            Text(vault.isIndexing ? "Indexing \(name)…" : "\(name) · \(vault.indexedCount) notes")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environmentObject(settings)
                    .environmentObject(vault)
            }
            .onAppear { if !settings.hasKey { showSettings = true } }
            .sheet(item: $noteToOpen) { note in
                NoteViewerView(ref: note).environmentObject(vault)
            }
            // Route tapped note citations and [[wikilinks]] to the note viewer.
            .environment(\.openURL, OpenURLAction { url in
                guard let ref = NoteRef(url: url) else { return .systemAction }
                noteToOpen = ref
                return .handled
            })
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(vm.messages) { msg in
                        MessageBubble(message: msg).id(msg.id)
                    }
                    if let err = vm.errorText {
                        Text(err)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
            }
            .onChange(of: vm.messages.last?.text) { _, _ in
                if let last = vm.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private func activityRow(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(text).font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.bottom, 4)
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask your vault…", text: $input, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.title)
            }
            .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || vm.isStreaming)
        }
        .padding()
    }

    private func send() {
        guard settings.hasKey else { showSettings = true; return }
        let text = input
        input = ""
        vm.send(text, settings: settings, vault: vault)
    }
}
