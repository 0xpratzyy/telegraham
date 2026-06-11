import Foundation

/// Language-agnostic function-word detection for the engines'
/// term-extraction filters — with NO hand-maintained vocabulary.
///
/// Two layers, by design:
///  1. The AI planner is the authoritative layer: it extracts content
///     terms from queries in ANY language, and its terms override
///     local tokenization wherever it ran (see the agentic matcher
///     and the engines' planner-hint handling).
///  2. This corpus-derived tier guards the no-AI fallback path:
///     tokens appearing in ≥1% of the user's own messages are
///     function words by definition, whatever languages they chat
///     in (mined from the FTS vocabulary, refreshed by the index
///     scheduler, self-tuning as the corpus evolves).
///
/// A hand-coded per-language list was considered and deliberately
/// rejected: it can never be complete ("batao" has a dozen romanized
/// spellings), it covers one language at a time, and corpus
/// statistics provably can't replace it below the ~1% tier ("batao"
/// 0.14% < "contract" 0.21% in the live corpus) — the LLM layer is
/// the only component that genuinely understands every language.
enum SearchStopWords {
    static func isFunctionWord(_ token: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return corpusDerived.contains(token)
    }

    /// Swap in the latest corpus-frequency tier (computed off the FTS
    /// vocabulary by the index scheduler).
    static func updateCorpusDerived(_ tokens: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        corpusDerived = tokens
    }

    static var corpusDerivedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return corpusDerived.count
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var corpusDerived: Set<String> = []
}
