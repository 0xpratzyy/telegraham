import Foundation

/// Façade over the embedding providers. Owns the active-model decision:
/// the contextual model when its assets load, the legacy sentence model
/// otherwise. All text normalization and the minimum-length gate live
/// here so every provider sees identical input.
actor EmbeddingService {
    static let shared = EmbeddingService()

    private let legacyProvider = AppleSentenceEmbeddingProvider()
    private let contextualProvider = AppleContextualEmbeddingProvider()
    private var contextualReady: Bool?

    static var legacyModelVersion: String { "apple-sentence-v1" }

    /// The model version new vectors are written with. Resolved after
    /// attempting to prepare the contextual model (cached after the
    /// first attempt; a failed download is retried on next launch, not
    /// in a loop).
    var activeModelVersion: String {
        get async {
            await ensureContextualPrepared()
                ? contextualProvider.modelVersion
                : legacyProvider.modelVersion
        }
    }

    func embed(text: String) async -> [Double]? {
        let normalized = Self.normalizedText(text)
        guard normalized.count >= AppConstants.Indexing.minEmbeddingTextLength else {
            return nil
        }
        if await ensureContextualPrepared() {
            return await contextualProvider.embed(text: normalized)
        }
        return await legacyProvider.embed(text: normalized)
    }

    /// Embed with a SPECIFIC model version — used by search when it has
    /// to query against vectors that were written by a different (older)
    /// model than the currently active one.
    func embed(text: String, modelVersion: String) async -> [Double]? {
        let normalized = Self.normalizedText(text)
        guard normalized.count >= AppConstants.Indexing.minEmbeddingTextLength else {
            return nil
        }
        switch modelVersion {
        case contextualProvider.modelVersion:
            guard await ensureContextualPrepared() else { return nil }
            return await contextualProvider.embed(text: normalized)
        case legacyProvider.modelVersion:
            return await legacyProvider.embed(text: normalized)
        default:
            return nil
        }
    }

    func embedBatch(texts: [String]) async -> [[Double]?] {
        var vectors: [[Double]?] = []
        vectors.reserveCapacity(texts.count)
        for text in texts {
            vectors.append(await embed(text: text))
        }
        return vectors
    }

    private func ensureContextualPrepared() async -> Bool {
        if let contextualReady { return contextualReady }
        let ready = await contextualProvider.prepare()
        contextualReady = ready
        if !ready {
            print("[Embedding] contextual model unavailable — staying on legacy sentence embeddings")
        }
        return ready
    }

    static func normalizedText(_ text: String) -> String {
        // Strip URLs before embedding for the same reason FTS does:
        // `https://x.com/.../status/123` ends up dominating the
        // sentence embedding with vocabulary that has nothing to do
        // with what the user actually wrote.
        let stripped = URLStripper.strip(text)
        return stripped
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}
