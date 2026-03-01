import Foundation

/// Shared utility for extracting and parsing JSON from AI provider responses.
/// AI providers often wrap JSON in markdown code blocks — this handles all common formats.
enum JSONExtractor {
    /// Extracts raw JSON string from AI response text that may be wrapped in markdown code blocks.
    static func extractJSON(from text: String) -> String {
        // Try ```json ... ``` blocks first
        if let jsonStart = text.range(of: "```json"),
           let jsonEnd = text.range(of: "```", range: jsonStart.upperBound..<text.endIndex) {
            return String(text[jsonStart.upperBound..<jsonEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Try generic ``` ... ``` blocks
        if let jsonStart = text.range(of: "```"),
           let jsonEnd = text.range(of: "```", range: jsonStart.upperBound..<text.endIndex) {
            return String(text[jsonStart.upperBound..<jsonEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Try raw JSON array
        if let bracketStart = text.firstIndex(of: "["),
           let bracketEnd = text.lastIndex(of: "]") {
            return String(text[bracketStart...bracketEnd])
        }
        // Try raw JSON object
        if let braceStart = text.firstIndex(of: "{"),
           let braceEnd = text.lastIndex(of: "}") {
            return String(text[braceStart...braceEnd])
        }
        return text
    }

    /// Parses a Decodable type from an AI response string.
    static func parseJSON<T: Decodable>(_ response: String) throws -> T {
        let jsonString = extractJSON(from: response)
        guard let data = jsonString.data(using: .utf8) else {
            throw AIError.parsingError("Could not convert response to data")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw AIError.parsingError(error.localizedDescription)
        }
    }
}
