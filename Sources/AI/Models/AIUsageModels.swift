import Foundation

enum AIRequestKind: String, Codable, CaseIterable {
    case semanticSearch
    case agenticSearch
    case queryPlanning
    case followUpSuggestion
    case pipelineTriage
    case replyQueueTriage
    case dashboardTopicDiscovery
    case dashboardTaskTriage
    case dashboardTaskExtraction
    case personProfile
    case summary

    var label: String {
        switch self {
        case .semanticSearch:
            return "Semantic Search"
        case .agenticSearch:
            return "Agentic Search"
        case .queryPlanning:
            return "Query Planning"
        case .followUpSuggestion:
            return "Follow-Up Suggestion"
        case .pipelineTriage:
            return "Pipeline Triage"
        case .replyQueueTriage:
            return "Reply Queue Triage"
        case .dashboardTopicDiscovery:
            return "Dashboard Topics"
        case .dashboardTaskTriage:
            return "Dashboard Task Triage"
        case .dashboardTaskExtraction:
            return "Dashboard Tasks"
        case .personProfile:
            return "Person Profile"
        case .summary:
            return "Summary"
        }
    }
}

enum AIUsageProvider: String, Codable, CaseIterable {
    case openAI = "OpenAI"
    case claude = "Claude"

    var label: String { rawValue }
}

struct AIProviderUsage {
    /// TOTAL input tokens, including any cached / cache-read portion.
    let inputTokens: Int
    let outputTokens: Int
    /// The cached (OpenAI) / cache-read (Anthropic) portion of `inputTokens`,
    /// billed at a discount. Providers normalize so this is always ⊆ input.
    var cachedInputTokens: Int = 0
}

struct AIUsageMetrics: Codable, Equatable {
    var requestCount: Int
    var inputTokens: Int
    var outputTokens: Int
    var estimatedCostUSD: Double
    var unpricedRequestCount: Int
    var unmeteredRequestCount: Int

    static let zero = AIUsageMetrics(
        requestCount: 0,
        inputTokens: 0,
        outputTokens: 0,
        estimatedCostUSD: 0,
        unpricedRequestCount: 0,
        unmeteredRequestCount: 0
    )
}

struct DailyAIUsageRecord: Codable, Hashable {
    let dayStart: Date
    let provider: AIUsageProvider
    let model: String
    let requestKind: AIRequestKind
    var requestCount: Int
    var meteredRequestCount: Int
    var inputTokens: Int
    var outputTokens: Int
    /// Cached/cache-read input tokens (subset of `inputTokens`). Optional so
    /// older persisted records (which lack the field) still decode.
    var cachedInputTokens: Int? = nil

    var id: String {
        "\(dayStart.timeIntervalSince1970)|\(provider.rawValue)|\(model)|\(requestKind.rawValue)"
    }
}

struct AIUsageBreakdownRow: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String?
    let metrics: AIUsageMetrics
}

/// One calendar day's rolled-up usage, for the day-by-day cost view.
struct DailyUsagePoint: Identifiable, Equatable {
    let dayStart: Date
    let metrics: AIUsageMetrics
    var id: Date { dayStart }
}

struct AIUsageOverview: Equatable {
    let last30Days: AIUsageMetrics
    let lifetime: AIUsageMetrics
    let byFeature30Days: [AIUsageBreakdownRow]
    let byModel30Days: [AIUsageBreakdownRow]
    /// One entry per calendar day, oldest → newest, covering the trailing 30
    /// days. Days with no usage are included as zero so the series is continuous.
    let daily30Days: [DailyUsagePoint]

    var hasUsage: Bool {
        lifetime.requestCount > 0
    }

    static let empty = AIUsageOverview(
        last30Days: .zero,
        lifetime: .zero,
        byFeature30Days: [],
        byModel30Days: [],
        daily30Days: []
    )
}

struct AIModelPricing {
    let family: String
    let inputUSDPerMillionTokens: Double
    let outputUSDPerMillionTokens: Double
    /// Fraction of the input price charged for cached / cache-read input
    /// tokens. OpenAI bills cached prompt prefixes at 50%; Anthropic cache
    /// reads are ~10% of input. 1.0 means the model has no caching discount.
    var cachedInputMultiplier: Double = 1.0

    /// `inputTokens` is TOTAL input (cached + uncached); `cachedInputTokens` is
    /// the cached portion, billed at `cachedInputMultiplier` of the input rate.
    /// Passing 0 cached reproduces full list pricing.
    func estimatedCostUSD(inputTokens: Int, cachedInputTokens: Int = 0, outputTokens: Int) -> Double {
        let cached = min(max(0, cachedInputTokens), max(0, inputTokens))
        let uncached = max(0, inputTokens - cached)
        let inputCost = (Double(uncached) + Double(cached) * cachedInputMultiplier) / 1_000_000 * inputUSDPerMillionTokens
        let outputCost = Double(outputTokens) / 1_000_000 * outputUSDPerMillionTokens
        return inputCost + outputCost
    }
}

enum AIUsagePricingCatalog {
    static func pricing(for provider: AIUsageProvider, model: String) -> AIModelPricing? {
        guard let family = canonicalFamily(for: provider, model: model) else { return nil }

        switch (provider, family) {
        case (.openAI, "gpt-4o-mini"):
            return AIModelPricing(
                family: family,
                inputUSDPerMillionTokens: 0.15,
                outputUSDPerMillionTokens: 0.60,
                cachedInputMultiplier: 0.5
            )
        case (.openAI, "gpt-5-mini"):
            return AIModelPricing(
                family: family,
                inputUSDPerMillionTokens: 0.25,
                outputUSDPerMillionTokens: 2.00,
                cachedInputMultiplier: 0.5
            )
        case (.openAI, "gpt-5"):
            return AIModelPricing(
                family: family,
                inputUSDPerMillionTokens: 1.25,
                outputUSDPerMillionTokens: 10.00,
                cachedInputMultiplier: 0.5
            )
        case (.claude, "claude-sonnet-4"):
            return AIModelPricing(
                family: family,
                inputUSDPerMillionTokens: 3.00,
                outputUSDPerMillionTokens: 15.00,
                cachedInputMultiplier: 0.1
            )
        case (.openAI, "gemini-3-flash"):
            // Managed plan runs Gemini 3 Flash through the proxy's Vertex path,
            // so it's recorded under the .openAI provider (the app speaks the
            // OpenAI-compatible API). Vertex list price (verified 2026-06):
            // $0.50/1M in, $3.00/1M out. cachedInputMultiplier left at 1.0 — we
            // don't yet trust Gemini's cache-token reporting, so bill full rate
            // (conservative for $300 burn tracking) until confirmed.
            return AIModelPricing(
                family: family,
                inputUSDPerMillionTokens: 0.50,
                outputUSDPerMillionTokens: 3.00
            )
        case (.openAI, "gemini-3.1-flash-lite"):
            // Current managed model. Vertex list price (2026-06).
            return AIModelPricing(
                family: family,
                inputUSDPerMillionTokens: 0.25,
                outputUSDPerMillionTokens: 1.50
            )
        case (.openAI, "gemini-3.5-flash"):
            // GA, top-quality fallback — roughly gpt-5 pricing.
            return AIModelPricing(
                family: family,
                inputUSDPerMillionTokens: 1.50,
                outputUSDPerMillionTokens: 9.00
            )
        case (.openAI, "gemini-2.5-flash"):
            // GA, regional, cheapest reliable fallback.
            return AIModelPricing(
                family: family,
                inputUSDPerMillionTokens: 0.30,
                outputUSDPerMillionTokens: 2.50
            )
        default:
            return nil
        }
    }

    static func canonicalFamily(for provider: AIUsageProvider, model: String) -> String? {
        let normalized = model
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !normalized.isEmpty else { return nil }

        switch provider {
        case .openAI:
            // Managed plan: Gemini via the OpenAI-compat proxy path is recorded
            // under .openAI with a `google/gemini-*` model id. Check the more
            // specific variants first (3.1-flash-lite before 3-flash, etc).
            if normalized.contains("gemini-3.1-flash-lite") { return "gemini-3.1-flash-lite" }
            if normalized.contains("gemini-3.5-flash") { return "gemini-3.5-flash" }
            if normalized.contains("gemini-3-flash") { return "gemini-3-flash" }
            if normalized.contains("gemini-2.5-flash") { return "gemini-2.5-flash" }
            if normalized == "gpt-4o-mini" {
                return "gpt-4o-mini"
            }
            if normalized.hasPrefix("gpt-5-mini") {
                return "gpt-5-mini"
            }
            // gpt-5 full (not mini/nano). Matched last so the more specific
            // mini branch takes precedence on its longer name.
            if normalized == "gpt-5" {
                return "gpt-5"
            }
        case .claude:
            if normalized.contains("claude-sonnet-4") || normalized.contains("sonnet-4") {
                return "claude-sonnet-4"
            }
        }

        return nil
    }
}
