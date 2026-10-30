import Foundation

/// Anything that can execute a Claude tool call and return a text result.
protocol ToolRunner: AnyObject {
    func run(name: String, input: [String: Any]) async -> String
}

/// What the agent emits while working, so the UI can stream text and show activity.
enum AgentEvent {
    case text(String)
    case activity(String)
}

/// Runs a full agentic turn: Claude searches/reads the vault via tools, looping until
/// it produces a final answer. Text streams out as it arrives.
struct VaultAgent {
    var apiKey: String
    var model: String
    weak var tools: ToolRunner?

    private let maxRounds = 8

    private let system = """
        You help the user explore their personal Obsidian vault — a collection of Markdown notes.
        When a question could be answered from their notes, use the tools to search and read before \
        answering: start with search_notes to find candidates, then read_note for detail. \
        Cite the note titles you drew from. Be concise. If the vault has nothing relevant, say so \
        rather than guessing.
        """

    private var toolSpecs: [[String: Any]] {
        [
            ["name": "search_notes",
             "description": "Full-text search across the user's Obsidian notes. Returns matching titles, paths, and snippets.",
             "input_schema": ["type": "object",
                              "properties": ["query": ["type": "string", "description": "Keywords to search for."],
                                             "limit": ["type": "integer", "description": "Max results (default 8)."]],
                              "required": ["query"]]],
            ["name": "read_note",
             "description": "Read the full Markdown contents of one note by its path (as returned by search_notes).",
             "input_schema": ["type": "object",
                              "properties": ["path": ["type": "string"]],
                              "required": ["path"]]],
            ["name": "list_notes",
             "description": "List note paths, optionally filtered by a folder path prefix.",
             "input_schema": ["type": "object",
                              "properties": ["folder": ["type": "string"]],
                              "required": []]]
        ]
    }

    func run(history: [ChatMessage]) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var messages: [[String: Any]] = history.map {
                        ["role": $0.role == .user ? "user" : "assistant", "content": $0.text]
                    }

                    for round in 1...maxRounds {
                        let result = try await oneRound(messages: messages, continuation: continuation)
                        messages.append(["role": "assistant", "content": result.assistantContent])

                        guard result.stopReason == "tool_use", !result.toolUses.isEmpty else { break }

                        if round == maxRounds {
                            continuation.yield(.text("\n\n[Stopped after \(maxRounds) tool rounds.]"))
                            break
                        }

                        var toolResults: [[String: Any]] = []
                        for use in result.toolUses {
                            continuation.yield(.activity(Self.activityLabel(use)))
                            let output = await (tools?.run(name: use.name, input: use.input) ?? "No vault connected.")
                            toolResults.append(["type": "tool_result",
                                                "tool_use_id": use.id,
                                                "content": output])
                        }
                        messages.append(["role": "user", "content": toolResults])
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: One streamed request/response round

    private struct ToolUse { let id: String; let name: String; let input: [String: Any] }
    private struct RoundResult {
        var assistantContent: [[String: Any]]
        var toolUses: [ToolUse]
        var stopReason: String?
    }

    private func oneRound(
        messages: [[String: Any]],
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) async throws -> RoundResult {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "stream": true,
            "system": system,
            "tools": toolSpecs,
            "messages": messages
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            throw AnthropicError(message: "API error (\(http.statusCode)). \(String(data: data, encoding: .utf8) ?? "")")
        }

        // Accumulate streamed content blocks by their index.
        var blockType: [Int: String] = [:]
        var textByIndex: [Int: String] = [:]
        var toolMeta: [Int: (id: String, name: String)] = [:]
        var toolJSON: [Int: String] = [:]
        var stopReason: String?

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty, payload != "[DONE]",
                  let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String else { continue }

            switch type {
            case "content_block_start":
                let idx = obj["index"] as? Int ?? 0
                if let cb = obj["content_block"] as? [String: Any], let t = cb["type"] as? String {
                    blockType[idx] = t
                    if t == "tool_use" {
                        toolMeta[idx] = (cb["id"] as? String ?? "", cb["name"] as? String ?? "")
                        toolJSON[idx] = ""
                    } else if t == "text" {
                        textByIndex[idx] = ""
                    }
                }
            case "content_block_delta":
                let idx = obj["index"] as? Int ?? 0
                if let delta = obj["delta"] as? [String: Any] {
                    if let t = delta["text"] as? String {
                        textByIndex[idx, default: ""] += t
                        continuation.yield(.text(t))
                    } else if let pj = delta["partial_json"] as? String {
                        toolJSON[idx, default: ""] += pj
                    }
                }
            case "message_delta":
                if let delta = obj["delta"] as? [String: Any], let sr = delta["stop_reason"] as? String {
                    stopReason = sr
                }
            case "error":
                let message = (obj["error"] as? [String: Any])?["message"] as? String
                throw AnthropicError(message: message ?? "Streaming error.")
            case "message_stop":
                break
            default:
                break
            }
        }

        // Rebuild the assistant turn in block order (needed to send tool_use back).
        var content: [[String: Any]] = []
        var toolUses: [ToolUse] = []
        for idx in blockType.keys.sorted() {
            switch blockType[idx] {
            case "text":
                content.append(["type": "text", "text": textByIndex[idx] ?? ""])
            case "tool_use":
                let meta = toolMeta[idx] ?? ("", "")
                let input = (toolJSON[idx]?.data(using: .utf8))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                content.append(["type": "tool_use", "id": meta.id, "name": meta.name, "input": input])
                toolUses.append(ToolUse(id: meta.id, name: meta.name, input: input))
            default:
                break
            }
        }
        return RoundResult(assistantContent: content, toolUses: toolUses, stopReason: stopReason)
    }

    private static func activityLabel(_ use: ToolUse) -> String {
        switch use.name {
        case "search_notes": return "Searching notes: \(use.input["query"] as? String ?? "")"
        case "read_note":    return "Reading \(use.input["path"] as? String ?? "note")"
        case "list_notes":   return "Listing notes"
        default:             return "Using \(use.name)"
        }
    }
}
