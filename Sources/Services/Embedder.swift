import NaturalLanguage

/// On-device sentence embeddings for semantic search — uses Apple's built-in
/// NaturalLanguage model, so there's no network call and no model download.
struct Embedder {
    static let shared = Embedder()

    private let model = NLEmbedding.sentenceEmbedding(for: .english)

    var isAvailable: Bool { model != nil }

    /// Returns a semantic vector for the text, or nil if embeddings are unavailable
    /// or the text can't be embedded.
    func embed(_ text: String) -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let model, let v = model.vector(for: trimmed) else { return nil }
        return v.map { Float($0) }
    }
}
