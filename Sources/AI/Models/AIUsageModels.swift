import Foundation

enum AIRequestKind: String, Codable, CaseIterable {
    case semanticSearch
    case agenticSearch
    case followUpSuggestion
    case pipelineTriage
    case replyQueueTriage
    case summary

    var label: String {
        switch self {
        case .semanticSearch:
            return "Semantic Search"
        case .agenticSearch:
            return "Agentic Search"
        case .followUpSuggestion:
            return "Follow-Up Suggestion"
        case .pipelineTriage:
            return "Pipeline Triage"
        case .replyQueueTriage:
            return "Reply Queue Triage"
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

struct AIUsageOverview: Equatable {
    let last30Days: AIUsageMetrics
    let lifetime: AIUsageMetrics
    let byFeature30Days: [AIUsageBreakdownRow]
    let byModel30Days: [AIUsageBreakdownRow]

    var hasUsage: Bool {
        lifetime.requestCount > 0
    }

    static let empty = AIUsageOverview(
        last30Days: .zero,
        lifetime: .zero,
        byFeature30Days: [],
        byModel30Days: []
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
        case (.openAI, "gpt-5.4-mini"):
            return AIModelPricing(
                family: family,
                inputUSDPerMillionTokens: 0.75,
                outputUSDPerMillionTokens: 4.50
            )
        case (.openAI, "gpt-5.4-nano"):
            return AIModelPricing(
                family: family,
                inputUSDPerMillionTokens: 0.20,
                outputUSDPerMillionTokens: 1.25
            )
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
            if normalized == "gpt-5.4-mini" {
                return "gpt-5.4-mini"
            }
            if normalized == "gpt-5.4-nano" {
                return "gpt-5.4-nano"
            }
            if normalized == "gpt-4o-mini" {
                return "gpt-4o-mini"
            }
            if normalized.hasPrefix("gpt-5-mini") {
                return "gpt-5-mini"
            }
        case .claude:
            if normalized.contains("claude-sonnet-4") || normalized.contains("sonnet-4") {
                return "claude-sonnet-4"
            }
        }

        return nil
    }
}
