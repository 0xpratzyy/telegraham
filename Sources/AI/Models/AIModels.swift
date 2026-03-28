import Foundation
import SwiftUI

// MARK: - Privacy-Safe Message Representation

/// A privacy-filtered message snippet safe to send to AI providers.
/// Contains only message ID, first name, text, relative timestamp, chat ID, and chat name.
/// Never includes phone numbers, user IDs, session tokens, or media files.
struct MessageSnippet: Codable {
    let messageId: Int64
    let senderFirstName: String
    let text: String
    let relativeTimestamp: String
    let chatId: Int64
    let chatName: String

    static func fromMessages(_ messages: [TGMessage], chatTitle: String? = nil) -> [MessageSnippet] {
        messages.compactMap { msg in
            guard let text = msg.textContent, !text.isEmpty else { return nil }
            let firstName = msg.senderName?.split(separator: " ").first.map(String.init) ?? "Unknown"
            return MessageSnippet(
                messageId: msg.id,
                senderFirstName: firstName,
                text: text,
                relativeTimestamp: msg.relativeDate,
                chatId: msg.chatId,
                chatName: chatTitle ?? msg.chatTitle ?? "Unknown"
            )
        }
    }

    /// Truncate an array of snippets to stay within ~4000 tokens (~16000 chars).
    static func truncateToTokenBudget(_ snippets: [MessageSnippet], maxChars: Int = AppConstants.AI.maxTokenBudgetChars) -> [MessageSnippet] {
        var totalChars = 0
        var result: [MessageSnippet] = []
        for snippet in snippets {
            let snippetChars =
                String(snippet.messageId).count +
                snippet.senderFirstName.count +
                snippet.text.count +
                snippet.relativeTimestamp.count +
                String(snippet.chatId).count +
                snippet.chatName.count + 20
            if totalChars + snippetChars > maxChars { break }
            totalChars += snippetChars
            result.append(snippet)
        }
        return result
    }
}

// MARK: - Query Intent

enum QueryIntent: String, Codable {
    case messageSearch = "message_search"
    case semanticSearch = "semantic_search"
}

// MARK: - Semantic Search

struct SemanticSearchResult: Identifiable {
    let chatId: Int64
    let chatTitle: String
    let reason: String
    let relevance: Relevance
    let matchingMessages: [String]

    var id: Int64 { chatId }

    enum Relevance: String {
        case high, medium

        var color: Color {
            switch self {
            case .high: return .purple
            case .medium: return .blue
            }
        }
    }
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
