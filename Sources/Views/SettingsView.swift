import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var vault: VaultStore
    @Environment(\.dismiss) private var dismiss
    @State private var keyDraft = ""
    @State private var showImporter = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Anthropic API Key") {
                    SecureField("sk-ant-…", text: $keyDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Stored only on this device, in the Keychain.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Obsidian Vault") {
                    if let name = vault.vaultName {
                        LabeledContent("Folder", value: name)
                        if vault.isIndexing {
                            ProgressView(value: vault.progress) { Text("Indexing…") }
                        } else {
                            Text("\(vault.indexedCount) notes indexed")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Pick your vault folder so Claude can search your notes.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Button(vault.vaultName == nil ? "Choose Vault Folder…" : "Change Folder…") {
                        showImporter = true
                    }
                    if vault.vaultName != nil {
                        Button("Re-index") { Task { await vault.reindex() } }
                            .disabled(vault.isIndexing)
                    }
                    if let err = vault.lastError {
                        Text(err).font(.footnote).foregroundStyle(.red)
                    }
                }

                Section("Model") {
                    Picker("Model", selection: $settings.model) {
                        ForEach(ClaudeModel.allCases) { Text($0.displayName).tag($0) }
                    }
                }

                Section {
                    Toggle("Allow Claude to edit notes", isOn: $settings.allowNoteEditing)
                } footer: {
                    Text("Lets Claude append to or create notes when you ask. It never deletes or overwrites existing notes.")
                }

                Section {
                    TextField("Daily notes folder (optional)", text: $settings.dailyNoteFolder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Quick capture")
                } footer: {
                    Text("Where new daily notes (YYYY-MM-DD) are created, e.g. \"Dailies\". Blank = vault root.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { settings.apiKey = keyDraft; dismiss() }
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result {
                    Task { await vault.setVault(url) }
                }
            }
            .onAppear { keyDraft = settings.apiKey }
        }
    }
}
