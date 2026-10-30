import Foundation

struct AnthropicError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Talks to the Anthropic Messages API and streams the reply back as text deltas.
struct AnthropicClient {
    var apiKey: String
    var model: String

    /// Streams incremental text as it arrives. Phase 1: plain text, no tools yet.
    func streamMessage(history: [ChatMessage], system: String? = nil) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
                    request.httpMethod = "POST"
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    request.setValue("application/json", forHTTPHeaderField: "content-type")

                    var body: [String: Any] = [
                        "model": model,
                        "max_tokens": 4096,
                        "stream": true,
                        "messages": history.map {
                            ["role": $0.role == .user ? "user" : "assistant", "content": $0.text]
                        }
                    ]
                    if let system { body["system"] = system }
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        var data = Data()
                        for try await byte in bytes { data.append(byte) }
                        let detail = String(data: data, encoding: .utf8) ?? ""
                        throw AnthropicError(message: "API error (\(http.statusCode)). \(detail)")
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                        guard !payload.isEmpty, payload != "[DONE]",
                              let data = payload.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let type = obj["type"] as? String else { continue }

                        switch type {
                        case "content_block_delta":
                            if let delta = obj["delta"] as? [String: Any],
                               let text = delta["text"] as? String {
                                continuation.yield(text)
                            }
                        case "error":
                            let message = (obj["error"] as? [String: Any])?["message"] as? String
                            throw AnthropicError(message: message ?? "Unknown streaming error.")
                        case "message_stop":
                            continuation.finish()
                            return
                        default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
