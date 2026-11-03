import SwiftUI

/// Quick capture: jot (or dictate) a thought and append it to today's daily note.
struct CaptureView: View {
    @EnvironmentObject var vault: VaultStore
    @EnvironmentObject var settings: Settings
    @Environment(\.dismiss) private var dismiss
    @StateObject private var speech = SpeechRecognizer()
    @State private var text = ""
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Capture a thought…", text: $text, axis: .vertical)
                        .lineLimit(3...10)
                    Button {
                        if speech.isRecording { speech.stop() } else { text = ""; speech.start() }
                    } label: {
                        Label(speech.isRecording ? "Stop dictation" : "Dictate",
                              systemImage: speech.isRecording ? "stop.circle.fill" : "mic.fill")
                            .foregroundStyle(speech.isRecording ? Color.red : Color.accentColor)
                    }
                } footer: {
                    Text("Saves a new note in your capture folder (default: EZVault).")
                }
            }
            .navigationTitle("New Capture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { speech.stop(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                }
            }
            .onChange(of: speech.transcript) { _, newValue in
                if speech.isRecording { text = newValue }
            }
        }
    }

    private func save() {
        saving = true
        let captured = text
        speech.stop()
        Task {
            vault.captureFolder = settings.captureFolder
            _ = await vault.captureNote(captured)
            saving = false
            dismiss()
        }
    }
}
