import SwiftUI

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isStreaming = false
    @Published var activity: String?      // e.g. "Searching notes: …"
    @Published var errorText: String?

    private var streamTask: Task<Void, Never>?

    /// Cancels an in-progress response (the Stop button).
    func stop() {
        streamTask?.cancel()
    }

    func send(_ text: String, settings: Settings, vault: VaultStore) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }

        messages.append(ChatMessage(role: .user, text: trimmed))
        let assistantIndex = messages.count
        messages.append(ChatMessage(role: .assistant, text: ""))
        isStreaming = true
        activity = nil
        errorText = nil

        // Everything up to (but not including) the empty assistant placeholder.
        let history = Array(messages.prefix(assistantIndex))

        streamTask = Task {
            do {
                if vault.isReady {
                    vault.writingEnabled = settings.allowNoteEditing
                    let agent = VaultAgent(apiKey: settings.apiKey, model: settings.model.rawValue, tools: vault)
                    for try await event in agent.run(history: history) {
                        guard assistantIndex < messages.count else { break }
                        switch event {
                        case .text(let t):
                            activity = nil
                            messages[assistantIndex].text += t
                        case .activity(let a):
                            activity = a
                        }
                    }
                } else {
                    let client = AnthropicClient(apiKey: settings.apiKey, model: settings.model.rawValue)
                    for try await delta in client.streamMessage(history: history) {
                        guard assistantIndex < messages.count else { break }
                        messages[assistantIndex].text += delta
                    }
                }
            } catch {
                // A user-initiated stop surfaces as cancellation — don't show it as an error.
                if !Task.isCancelled { errorText = error.localizedDescription }
            }
            // Drop an empty assistant bubble (error before any text, or stopped immediately).
            if assistantIndex < messages.count, messages[assistantIndex].text.isEmpty {
                messages.remove(at: assistantIndex)
            }
            activity = nil
            isStreaming = false
        }
    }
}
