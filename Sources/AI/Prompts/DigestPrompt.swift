import Foundation

enum DigestPrompt {
    static func systemPrompt(period: DigestPeriod) -> String {
        """
        You are generating a \(period.rawValue.lowercased()) digest of Telegram activity. \
        Given recent messages from multiple chats, create a structured summary.

        Organize the digest into 3-5 sections. Each section should have:
        - An emoji prefix
        - A short title
        - 2-4 bullet points summarizing key activity

        Respond with a JSON array of sections:
        [
          {
            "emoji": "💬",
            "title": "Active Discussions",
            "content": "- Team discussed the new feature rollout\\n- Design review scheduled for Thursday"
          },
          {
            "emoji": "📋",
            "title": "Action Items",
            "content": "- 3 messages awaiting your reply\\n- Budget proposal needs review"
          }
        ]

        Rules:
        - Keep each section concise (2-4 bullet points)
        - Use markdown bullet points (- ) for content
        - Don't include user IDs or phone numbers
        - Focus on what matters, skip trivial messages
        - If activity is low, produce fewer sections
        """
    }

    static func userMessage(snippets: [MessageSnippet]) -> String {
        let formatted = snippets.map { "[\($0.chatName)] [\($0.relativeTimestamp)] \($0.senderFirstName): \($0.text)" }
            .joined(separator: "\n")
        return "Messages to summarize:\n\(formatted)"
    }

    static func parseResponse(_ response: String, period: DigestPeriod) throws -> DigestResult {
        let jsonString = extractJSON(from: response)
        guard let data = jsonString.data(using: .utf8) else {
            throw AIError.parsingError("Could not convert digest response to data")
        }

        struct SectionDTO: Codable {
            let emoji: String
            let title: String
            let content: String
        }

        let sections: [SectionDTO]
        do {
            sections = try JSONDecoder().decode([SectionDTO].self, from: data)
        } catch {
            throw AIError.parsingError("Failed to parse digest sections: \(error.localizedDescription)")
        }

        let digestSections = sections.map { dto in
            DigestSection(emoji: dto.emoji, title: dto.title, content: dto.content)
        }

        return DigestResult(period: period, sections: digestSections, generatedAt: Date())
    }

    private static func extractJSON(from text: String) -> String {
        if let jsonStart = text.range(of: "```json"),
           let jsonEnd = text.range(of: "```", range: jsonStart.upperBound..<text.endIndex) {
            return String(text[jsonStart.upperBound..<jsonEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let jsonStart = text.range(of: "```"),
           let jsonEnd = text.range(of: "```", range: jsonStart.upperBound..<text.endIndex) {
            return String(text[jsonStart.upperBound..<jsonEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let bracketStart = text.firstIndex(of: "["),
           let bracketEnd = text.lastIndex(of: "]") {
            return String(text[bracketStart...bracketEnd])
        }
        return text
    }
}
