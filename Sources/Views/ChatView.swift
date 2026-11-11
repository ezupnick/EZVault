import SwiftUI

struct ChatView: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var vault: VaultStore
    @StateObject private var vm = ChatViewModel()
    @State private var input = ""
    @State private var showSettings = false
    @State private var noteToOpen: NoteRef?
    @State private var showSwitcher = false
    @State private var showCapture = false
    @StateObject private var speech = SpeechRecognizer()

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
                ToolbarItemGroup(placement: .topBarLeading) {
                    if vault.isReady {
                        Button { showSwitcher = true } label: { Image(systemName: "magnifyingglass") }
                        Button { showCapture = true } label: { Image(systemName: "square.and.pencil") }
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
            .sheet(isPresented: $showSwitcher) {
                QuickSwitcherView().environmentObject(vault)
            }
            .sheet(isPresented: $showCapture) {
                CaptureView().environmentObject(vault).environmentObject(settings)
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
            .overlay {
                if vm.messages.isEmpty && vm.errorText == nil { greeting }
            }
            .onChange(of: vm.messages.last?.text) { _, _ in
                if let last = vm.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    /// Shown while the conversation is empty; refreshes each minute so it rolls over at the boundaries.
    private var greeting: some View {
        VStack(spacing: 28) {
            TimelineView(.everyMinute) { context in
                VStack(spacing: 6) {
                    Text(Self.greetingText(for: context.date))
                        .font(.largeTitle.weight(.semibold))
                    Text("What are you looking for?")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
            }
            .allowsHitTesting(false)

            if vault.isReady {
                HStack(spacing: 12) {
                    quickAction("Search notes", systemImage: "magnifyingglass") { showSwitcher = true }
                    quickAction("Quick capture", systemImage: "square.and.pencil") { showCapture = true }
                }
            }
        }
        .padding(.horizontal, 32)
    }

    private func quickAction(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemImage).font(.title2)
                Text(title).font(.subheadline.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private static func greetingText(for date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12:  return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default:      return "Hello, night owl"
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
            Button {
                if speech.isRecording { speech.stop() } else { input = ""; speech.start() }
            } label: {
                Image(systemName: speech.isRecording ? "mic.fill" : "mic")
                    .font(.title2)
                    .foregroundStyle(speech.isRecording ? Color.red : Color.secondary)
            }
            TextField("Ask your vault…", text: $input, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
            Button {
                if vm.isStreaming { vm.stop() } else { send() }
            } label: {
                Image(systemName: vm.isStreaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.title)
                    .foregroundStyle(vm.isStreaming ? Color.red : Color.accentColor)
            }
            .disabled(!vm.isStreaming && input.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding()
        .onChange(of: speech.transcript) { _, newValue in
            if speech.isRecording { input = newValue }
        }
    }

    private func send() {
        guard settings.hasKey else { showSettings = true; return }
        speech.stop()
        let text = input
        input = ""
        vm.send(text, settings: settings, vault: vault)
    }
}
