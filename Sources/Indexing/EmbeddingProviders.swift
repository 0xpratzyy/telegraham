import Foundation
import NaturalLanguage
import Embeddings

/// A versioned source of text embeddings.
///
/// Vectors from different models live in incomparable spaces, so every
/// stored vector is stamped with its provider's `modelVersion` and
/// search never cosine-compares across versions. Swapping models is
/// therefore: add a provider, make it active, let the backfill re-embed
/// — old vectors keep serving search until the new ones land.
protocol EmbeddingProvider: Sendable {
    var modelVersion: String { get }
    /// Load model assets. Safe to call repeatedly; returns whether the
    /// provider is usable.
    func prepare() async -> Bool
    /// Embed normalized text. `isQuery` lets asymmetric models (e5 uses
    /// distinct "query:"/"passage:" prefixes) embed search queries and
    /// indexed documents differently; symmetric models ignore it. Nil
    /// when the model can't produce a vector.
    func embed(text: String, isQuery: Bool) async -> [Double]?
}

/// The original NLEmbedding sentence model — English-only, kept as the
/// legacy provider so existing vectors remain searchable while the
/// contextual backfill runs, and as the fallback if contextual assets
/// can't be loaded.
actor AppleSentenceEmbeddingProvider: EmbeddingProvider {
    nonisolated let modelVersion = "apple-sentence-v1"

    private let embedding = NLEmbedding.sentenceEmbedding(for: .english)

    func prepare() async -> Bool {
        embedding != nil
    }

    func embed(text: String, isQuery: Bool) async -> [Double]? {
        guard let embedding else { return nil }
        return embedding.vector(for: text)
    }
}

/// Apple's transformer-based contextual embedding (Latin-script model,
/// macOS 14+). Substantially stronger than the legacy sentence model
/// and covers the Latin-script languages in one space — including
/// romanized Hindi/Hinglish mechanically. Known limits (verified against
/// Apple's WWDC23 session): per-script models mean no cross-script
/// matching, and native Devanagari is not covered; if evals demand more,
/// the next rung is a multilingual open model behind this same protocol.
///
/// The model's assets are downloaded once from Apple's servers on first
/// use (an OS-level model fetch — no user content is involved).
actor AppleContextualEmbeddingProvider: EmbeddingProvider {
    nonisolated let modelVersion = "apple-contextual-latin-v1"

    private let embedding = NLContextualEmbedding(script: .latin)
    private var isLoaded = false

    func prepare() async -> Bool {
        if isLoaded { return true }
        guard let embedding else { return false }

        if !embedding.hasAvailableAssets {
            let available = await withCheckedContinuation { continuation in
                embedding.requestAssets { result, _ in
                    continuation.resume(returning: result == .available)
                }
            }
            guard available else { return false }
        }

        do {
            try embedding.load()
            isLoaded = true
            return true
        } catch {
            print("[Embedding] contextual model load failed: \(error.localizedDescription)")
            return false
        }
    }

    func embed(text: String, isQuery: Bool) async -> [Double]? {
        guard isLoaded, let embedding else { return nil }
        do {
            let result = try embedding.embeddingResult(for: text, language: nil)
            // Contextual models emit per-token vectors; mean-pool into a
            // single sentence vector (cosine downstream is norm-invariant,
            // so no extra normalization needed).
            var sum = [Double](repeating: 0, count: embedding.dimension)
            var tokenCount = 0
            result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
                for (index, value) in vector.enumerated() where index < sum.count {
                    sum[index] += value
                }
                tokenCount += 1
                return true
            }
            guard tokenCount > 0 else { return nil }
            return sum.map { $0 / Double(tokenCount) }
        } catch {
            return nil
        }
    }
}

/// intfloat/multilingual-e5-small via swift-embeddings (XLM-RoBERTa on
/// Apple MLTensor). A real retrieval model — 100+ languages in one
/// shared space, cross-lingual, and unlike NLContextualEmbedding it
/// produces vectors that actually rank under cosine.
///
/// Two e5 contracts that MUST hold or quality collapses:
///   1. mean pooling + L2 normalization (the XLMRoberta default is CLS
///      pooling — wrong for e5), set explicitly below.
///   2. asymmetric prefixes: "query: " for searches, "passage: " for
///      indexed text.
///
/// Model weights (~120MB) download once from Hugging Face on first use
/// and cache on disk — weights only; no message content leaves.
actor E5EmbeddingProvider: EmbeddingProvider {
    nonisolated let modelVersion = "e5-multilingual-small-v1"

    private static let modelId = "intfloat/multilingual-e5-small"
    private var bundle: XLMRoberta.ModelBundle?
    private var loadFailed = false

    private var encodeOptions: EncodeOptions {
        EncodeOptions(maxLength: 512, postProcess: .meanPool(normalize: true))
    }

    func prepare() async -> Bool {
        if bundle != nil { return true }
        if loadFailed { return false }
        do {
            bundle = try await XLMRoberta.loadModelBundle(from: Self.modelId)
            return true
        } catch {
            loadFailed = true
            print("[Embedding] e5 model load failed: \(error.localizedDescription)")
            return false
        }
    }

    func embed(text: String, isQuery: Bool) async -> [Double]? {
        guard let bundle else { return nil }
        let prefixed = (isQuery ? "query: " : "passage: ") + text
        do {
            let encoded = try bundle.encode(prefixed, options: encodeOptions)
            let floats = await encoded.cast(to: Float.self).shapedArray(of: Float.self).scalars
            guard !floats.isEmpty else { return nil }
            return floats.map(Double.init)
        } catch {
            // Content-free: never log the message text (privacy).
            print("[Embedding] e5 encode failed: \(type(of: error))")
            return nil
        }
    }
}
