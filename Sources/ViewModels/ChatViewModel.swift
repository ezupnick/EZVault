import SwiftUI

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isStreaming = false
    @Published var activity: String?      // e.g. "Searching notes: …"
    @Published var errorText: String?

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

        Task {
            do {
                if vault.isReady {
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
                errorText = error.localizedDescription
                if assistantIndex < messages.count, messages[assistantIndex].text.isEmpty {
                    messages.remove(at: assistantIndex)
                }
            }
            activity = nil
            isStreaming = false
        }
    }
}
