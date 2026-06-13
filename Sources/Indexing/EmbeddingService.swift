import Foundation

/// Façade over the embedding providers. Owns the active-model decision:
/// the multilingual e5 retrieval model when it loads, the legacy
/// NLEmbedding sentence model otherwise. All text normalization and the
/// minimum-length gate live here so every provider sees identical input.
///
/// History: NLContextualEmbedding was tried as the active model and
/// failed the retrieval bench (anisotropic — mean-pooled vectors sit in
/// a ~0.7-cosine cone, 0% hit@1). Its provider is retained only so any
/// leftover contextual-tagged vectors can still be queried during the
/// re-embed to e5; it is no longer an active choice.
actor EmbeddingService {
    static let shared = EmbeddingService()

    private let legacyProvider = AppleSentenceEmbeddingProvider()
    private let contextualProvider = AppleContextualEmbeddingProvider()
    private let e5Provider = E5EmbeddingProvider()
    private var e5Ready: Bool?

    static var legacyModelVersion: String { "apple-sentence-v1" }

    /// The model version new vectors are written with. e5 when it loads,
    /// legacy otherwise (cached after the first attempt; a failed model
    /// download is retried next launch, not in a loop).
    var activeModelVersion: String {
        get async {
            await ensureE5Prepared()
                ? e5Provider.modelVersion
                : legacyProvider.modelVersion
        }
    }

    func embed(text: String, isQuery: Bool = false) async -> [Double]? {
        let normalized = Self.normalizedText(text)
        guard normalized.count >= AppConstants.Indexing.minEmbeddingTextLength else {
            return nil
        }
        if await ensureE5Prepared() {
            return await e5Provider.embed(text: normalized, isQuery: isQuery)
        }
        return await legacyProvider.embed(text: normalized, isQuery: isQuery)
    }

    /// Embed with a SPECIFIC model version — used by search when it must
    /// query against vectors written by a different model than the
    /// currently active one (e.g. mid-re-embed).
    func embed(text: String, modelVersion: String, isQuery: Bool = false) async -> [Double]? {
        let normalized = Self.normalizedText(text)
        guard normalized.count >= AppConstants.Indexing.minEmbeddingTextLength else {
            return nil
        }
        switch modelVersion {
        case e5Provider.modelVersion:
            guard await ensureE5Prepared() else { return nil }
            return await e5Provider.embed(text: normalized, isQuery: isQuery)
        case contextualProvider.modelVersion:
            guard await contextualProvider.prepare() else { return nil }
            return await contextualProvider.embed(text: normalized, isQuery: isQuery)
        case legacyProvider.modelVersion:
            return await legacyProvider.embed(text: normalized, isQuery: isQuery)
        default:
            return nil
        }
    }

    /// Batch-embed indexed documents (passages, never queries).
    func embedBatch(texts: [String]) async -> [[Double]?] {
        var vectors: [[Double]?] = []
        vectors.reserveCapacity(texts.count)
        for text in texts {
            vectors.append(await embed(text: text, isQuery: false))
        }
        return vectors
    }

    private func ensureE5Prepared() async -> Bool {
        if let e5Ready { return e5Ready }
        let ready = await e5Provider.prepare()
        e5Ready = ready
        if !ready {
            print("[Embedding] e5 model unavailable — staying on legacy sentence embeddings")
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
