import Foundation
import SwiftUI

// MARK: - Privacy-Safe Message Representation

/// A privacy-filtered message snippet safe to send to AI providers.
/// Contains only first name, text, relative timestamp, and chat name.
/// Never includes phone numbers, user IDs, session tokens, or media files.
struct MessageSnippet: Codable {
    let senderFirstName: String
    let text: String
    let relativeTimestamp: String
    let chatName: String

    static func fromMessages(_ messages: [TGMessage], chatTitle: String? = nil) -> [MessageSnippet] {
        messages.compactMap { msg in
            guard let text = msg.textContent, !text.isEmpty else { return nil }
            let firstName = msg.senderName?.split(separator: " ").first.map(String.init) ?? "Unknown"
            return MessageSnippet(
                senderFirstName: firstName,
                text: text,
                relativeTimestamp: msg.relativeDate,
                chatName: chatTitle ?? msg.chatTitle ?? "Unknown"
            )
        }
    }

    /// Truncate an array of snippets to stay within ~4000 tokens (~16000 chars).
    static func truncateToTokenBudget(_ snippets: [MessageSnippet], maxChars: Int = AppConstants.AI.maxTokenBudgetChars) -> [MessageSnippet] {
        var totalChars = 0
        var result: [MessageSnippet] = []
        for snippet in snippets {
            let snippetChars = snippet.senderFirstName.count + snippet.text.count + snippet.relativeTimestamp.count + snippet.chatName.count + 20
            if totalChars + snippetChars > maxChars { break }
            totalChars += snippetChars
            result.append(snippet)
        }
        return result
    }
}

// MARK: - Query Intent

enum QueryIntent: String, Codable {
    case groupDiscovery = "group_discovery"
    case dmIntelligence = "dm_intelligence"
    case actionItems = "action_items"
    case digest = "digest"
    case messageSearch = "message_search"
}

// MARK: - DM Categorization

enum DMCategory: String, CaseIterable, Codable {
    case needsReply = "Needs Reply"
    case fyi = "FYI"
    case resolved = "Resolved"
    case business = "Business"

    var icon: String {
        switch self {
        case .needsReply: return "exclamationmark.bubble"
        case .fyi: return "info.circle"
        case .resolved: return "checkmark.circle"
        case .business: return "briefcase"
        }
    }

    var color: Color {
        switch self {
        case .needsReply: return .red
        case .fyi: return .blue
        case .resolved: return .green
        case .business: return .orange
        }
    }
}

struct CategorizedMessage: Identifiable {
    let id: Int64
    let message: TGMessage
    let category: DMCategory
    let reason: String
    let chatTitle: String
}

// MARK: - Action Items

struct ActionItem: Identifiable {
    let id = UUID()
    let chatTitle: String
    let senderName: String
    let summary: String
    let suggestedAction: String
    let urgency: Urgency
    let originalMessages: [TGMessage]

    enum Urgency: String, Codable, CaseIterable {
        case high, medium, low

        var color: Color {
            switch self {
            case .high: return .red
            case .medium: return .yellow
            case .low: return .green
            }
        }

        var icon: String {
            switch self {
            case .high: return "exclamationmark.triangle.fill"
            case .medium: return "exclamationmark.circle.fill"
            case .low: return "arrow.down.circle.fill"
            }
        }
    }
}

// MARK: - Digest

enum DigestPeriod: String, CaseIterable {
    case daily = "Daily"
    case weekly = "Weekly"
}

struct DigestSection: Identifiable {
    let id = UUID()
    let emoji: String
    let title: String
    let content: String
}

struct DigestResult {
    let period: DigestPeriod
    let sections: [DigestSection]
    let generatedAt: Date
}

// MARK: - AI Configuration

struct AIProviderConfig {
    let providerType: ProviderType
    let apiKey: String
    let model: String

    enum ProviderType: String, CaseIterable {
        case claude = "Claude"
        case openai = "OpenAI"
        case none = "None"

        var defaultModel: String {
            switch self {
            case .claude: return AppConstants.AI.defaultClaudeModel
            case .openai: return AppConstants.AI.defaultOpenAIModel
            case .none: return ""
            }
        }
    }
}

// MARK: - Errors

enum AIError: LocalizedError {
    case noAPIKey
    case invalidResponse
    case httpError(Int, String)
    case networkError(Error)
    case parsingError(String)
    case providerNotConfigured

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "No API key configured"
        case .invalidResponse: return "Invalid response from AI provider"
        case .httpError(let code, let msg): return "HTTP \(code): \(msg)"
        case .networkError(let err): return "Network error: \(err.localizedDescription)"
        case .parsingError(let detail): return "Failed to parse AI response: \(detail)"
        case .providerNotConfigured: return "AI provider not configured"
        }
    }
}
