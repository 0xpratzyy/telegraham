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
    /// When the last embed finished. The loaded model is enormous —
    /// measured 2026-07-26 on a live install: a 2.83 GB process footprint
    /// (peak 4.0 GB) of which ~2.2 GB was this model's heap
    /// (MetalPerformanceShadersGraph caches + sentencepiece) plus ~0.5 GB
    /// of GPU IOSurfaces. Everything else in the app — TDLib, the message
    /// store, SQLite's page cache — was rounding error next to it. Indexing
    /// is bursty, so holding all that resident forever is pure waste.
    private var lastUsedAt: Date?
    private var idleUnloadTask: Task<Void, Never>?
    /// Long enough that a burst of embeds (indexing pass, a few searches in
    /// a row) never pays the reload, short enough that a backgrounded app
    /// gives the memory back quickly. Reload costs ~1-2s, once.
    private static let idleUnloadAfter: TimeInterval = 120

    /// Where the e5 weights download to: ~/Library/Application Support/
    /// Pidgy/models. Passed explicitly to `loadModelBundle` so the Hugging
    /// Face Hub doesn't fall back to its ~/Documents/huggingface default —
    /// that default triggers a macOS "access your Documents folder" prompt
    /// and, if the user declines, the model can't load and search silently
    /// drops to the legacy embeddings. Pure (no I/O) so it's testable; the
    /// directory is created in `prepare()`.
    static var modelsDirectoryURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(AppConstants.Storage.appSupportFolderName, isDirectory: true)
            .appendingPathComponent(AppConstants.Storage.modelsDirectoryName, isDirectory: true)
    }

    private var encodeOptions: EncodeOptions {
        EncodeOptions(maxLength: 512, postProcess: .meanPool(normalize: true))
    }

    func prepare() async -> Bool {
        if bundle != nil { return true }
        if loadFailed { return false }
        do {
            let downloadBase = Self.modelsDirectoryURL
            try? FileManager.default.createDirectory(at: downloadBase, withIntermediateDirectories: true)
            bundle = try await XLMRoberta.loadModelBundle(from: Self.modelId, downloadBase: downloadBase)
            return true
        } catch {
            loadFailed = true
            print("[Embedding] e5 model load failed: \(error.localizedDescription)")
            return false
        }
    }

    func embed(text: String, isQuery: Bool) async -> [Double]? {
        guard let bundle else { return nil }
        lastUsedAt = Date()
        scheduleIdleUnload()
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

    /// Drop the model once embedding has been idle. Re-armed on every embed,
    /// so a run of calls keeps it warm and only a genuine lull unloads.
    private func scheduleIdleUnload() {
        idleUnloadTask?.cancel()
        idleUnloadTask = Task { [idleAfter = Self.idleUnloadAfter] in
            try? await Task.sleep(nanoseconds: UInt64(idleAfter * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self.unloadIfIdle()
        }
    }

    private func unloadIfIdle() {
        guard bundle != nil,
              let lastUsedAt,
              Date().timeIntervalSince(lastUsedAt) >= Self.idleUnloadAfter else { return }
        bundle = nil
        idleUnloadTask = nil
        // prepare() reloads on the next embed; loadFailed stays false so this
        // is a normal warm path, not a failure path.
        print("[Embedding] e5 model unloaded after idle — memory released")
    }
}

/// sentence-transformers/static-similarity-mrl-multilingual-v1 — a STATIC
/// embedding model: no transformer inference at all, just a trained token
/// lookup table that gets mean-pooled.
///
/// Why it is worth a bake-off against e5 (measured on this machine
/// 2026-07-26): e5 costs ~2.2 GB of heap (MetalPerformanceShadersGraph +
/// sentencepiece) plus ~0.5 GB of GPU surfaces while loaded, and 25-40%
/// CPU for the length of an indexing pass. Static models are reported at
/// ~92% of multilingual-e5-small's similarity quality while running
/// ~125x faster on CPU, in tens of megabytes, with no GPU at all.
///
/// If it holds up on THIS corpus (Hinglish, romanised Hindi, code-switched
/// chat — territory no public benchmark covers), the entire memory and CPU
/// problem disappears and embedding everything at Gmail/Slack scale becomes
/// affordable. That is what `RetrievalVectorAblationEval` decides; nothing
/// here is switched on by belief.
///
/// Symmetric model: no query/passage prefixes (that is an e5 contract).
///
/// Model2Vec `potion-multilingual-128M`, not the sentence-transformers
/// static model: the latter ships its tokenizer inside a
/// `0_StaticEmbedding/` module folder, and this package's loader expects a
/// flat repo, so it fails with "Required configuration file missing:
/// tokenizer.json" (hit on the first bake-off run). Model2Vec repos are
/// flat and load directly — and this one covers 101 languages.
actor StaticMultilingualEmbeddingProvider: EmbeddingProvider {
    nonisolated let modelVersion = "static-multilingual-v1"

    private static let modelId = "minishlab/potion-multilingual-128M"
    private var bundle: Model2Vec.ModelBundle?
    private var loadFailed = false

    func prepare() async -> Bool {
        if bundle != nil { return true }
        if loadFailed { return false }
        do {
            let downloadBase = E5EmbeddingProvider.modelsDirectoryURL
            try? FileManager.default.createDirectory(at: downloadBase, withIntermediateDirectories: true)
            bundle = try await Model2Vec.loadModelBundle(
                from: Self.modelId,
                downloadBase: downloadBase
            )
            return true
        } catch {
            loadFailed = true
            print("[Embedding] static model load failed: \(error.localizedDescription)")
            return false
        }
    }

    func embed(text: String, isQuery: Bool) async -> [Double]? {
        guard let bundle else { return nil }
        do {
            // normalize: true — the store cosine-compares raw vectors.
            let encoded = try bundle.encode(text, normalize: true)
            let floats = await encoded.cast(to: Float.self).shapedArray(of: Float.self).scalars
            guard !floats.isEmpty else { return nil }
            return floats.map(Double.init)
        } catch {
            print("[Embedding] static encode failed: \(type(of: error))")
            return nil
        }
    }
}
