import SwiftUI

/// The Claude models the app can talk to. Phase 1 exposes a simple two-way toggle.
enum ClaudeModel: String, CaseIterable, Identifiable {
    case opus = "claude-opus-4-8"
    case haiku = "claude-haiku-5-5"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .opus:  return "Opus 4.8 — best quality"
        case .haiku: return "Haiku 5.5 — fastest"
        }
    }
}

/// App-wide settings. The API key is kept in the Keychain; the model choice in UserDefaults.
@MainActor
final class Settings: ObservableObject {
    @Published var apiKey: String {
        didSet { KeychainStore.save(apiKey, for: Self.apiKeyAccount) }
    }
    @Published var model: ClaudeModel {
        didSet { UserDefaults.standard.set(model.rawValue, forKey: Self.modelKey) }
    }
    @Published var allowNoteEditing: Bool {
        didSet { UserDefaults.standard.set(allowNoteEditing, forKey: Self.editKey) }
    }
    @Published var dailyNoteFolder: String {
        didSet { UserDefaults.standard.set(dailyNoteFolder, forKey: Self.dailyFolderKey) }
    }

    private static let apiKeyAccount = "anthropic_api_key"
    private static let modelKey = "model"
    private static let editKey = "allow_note_editing"
    private static let dailyFolderKey = "daily_note_folder"

    init() {
        self.apiKey = KeychainStore.load(for: Self.apiKeyAccount) ?? ""
        let saved = UserDefaults.standard.string(forKey: Self.modelKey) ?? ClaudeModel.opus.rawValue
        self.model = ClaudeModel(rawValue: saved) ?? .opus
        self.allowNoteEditing = (UserDefaults.standard.object(forKey: Self.editKey) as? Bool) ?? true
        self.dailyNoteFolder = UserDefaults.standard.string(forKey: Self.dailyFolderKey) ?? ""
    }

    var hasKey: Bool { !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
