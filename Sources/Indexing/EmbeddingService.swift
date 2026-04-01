import Foundation
import NaturalLanguage

actor EmbeddingService {
    static let shared = EmbeddingService()

    private let embedding: NLEmbedding?

    init() {
        embedding = NLEmbedding.sentenceEmbedding(for: .english)
    }

    func embed(text: String) -> [Double]? {
        let normalized = normalizedText(text)
        guard normalized.count >= AppConstants.Indexing.minEmbeddingTextLength else {
            return nil
        }

        guard let embedding else { return nil }
        guard let vector = embedding.vector(for: normalized) else { return nil }
        return vector
    }

    func embedBatch(texts: [String]) -> [[Double]?] {
        texts.map { embed(text: $0) }
    }

    private func normalizedText(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}
