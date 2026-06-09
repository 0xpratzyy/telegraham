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
    let inputTokens: Int
    let outputTokens: Int
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

    func estimatedCostUSD(inputTokens: Int, outputTokens: Int) -> Double {
        (Double(inputTokens) / 1_000_000 * inputUSDPerMillionTokens) +
        (Double(outputTokens) / 1_000_000 * outputUSDPerMillionTokens)
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
                outputUSDPerMillionTokens: 0.60
            )
        case (.openAI, "gpt-5-mini"):
            return AIModelPricing(
                family: family,
                inputUSDPerMillionTokens: 0.25,
                outputUSDPerMillionTokens: 2.00
            )
        case (.openAI, "gpt-5"):
            return AIModelPricing(
                family: family,
                inputUSDPerMillionTokens: 1.25,
                outputUSDPerMillionTokens: 10.00
            )
        case (.claude, "claude-sonnet-4"):
            return AIModelPricing(
                family: family,
                inputUSDPerMillionTokens: 3.00,
                outputUSDPerMillionTokens: 15.00
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
