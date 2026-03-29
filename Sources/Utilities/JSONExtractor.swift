import Foundation

/// Shared utility for extracting and parsing JSON from AI provider responses.
/// AI providers often wrap JSON in markdown code blocks — this handles all common formats.
enum JSONExtractor {
    /// Extracts raw JSON string from AI response text that may be wrapped in markdown code blocks.
    static func extractJSON(from text: String) -> String {
        if let fenced = extractFencedBlocks(from: text).first {
            return fenced
        }
        if let fragment = balancedJSONFragments(in: text, maxCount: 1).first {
            return fragment
        }
        return text
    }

    /// Parses a Decodable type from an AI response string.
    static func parseJSON<T: Decodable>(_ response: String) throws -> T {
        let decoder = JSONDecoder()
        var lastError: Error?

        for candidate in candidateJSONStrings(from: response) {
            guard let data = candidate.data(using: .utf8) else { continue }
            do {
                return try decoder.decode(T.self, from: data)
            } catch {
                lastError = error
            }
        }

        throw AIError.parsingError(lastError?.localizedDescription ?? "Could not parse JSON from AI response")
    }

    private static func candidateJSONStrings(from text: String) -> [String] {
        var candidates: [String] = []

        func append(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if !candidates.contains(trimmed) {
                candidates.append(trimmed)
            }
        }

        append(text)

        for block in extractFencedBlocks(from: text) {
            append(block)
        }

        for fragment in balancedJSONFragments(in: text, maxCount: 32) {
            append(fragment)
        }

        return candidates
    }

    private static func extractFencedBlocks(from text: String) -> [String] {
        var blocks: [String] = []
        var cursor = text.startIndex

        while cursor < text.endIndex,
              let fenceStart = text.range(of: "```", range: cursor..<text.endIndex) {
            var contentStart = fenceStart.upperBound

            if let lineBreak = text[contentStart...].firstIndex(of: "\n") {
                let languageTag = text[contentStart..<lineBreak]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                if !languageTag.isEmpty && languageTag.count <= 12 {
                    contentStart = text.index(after: lineBreak)
                }
            }

            guard let fenceEnd = text.range(of: "```", range: contentStart..<text.endIndex) else {
                break
            }

            let block = String(text[contentStart..<fenceEnd.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !block.isEmpty {
                blocks.append(block)
            }

            cursor = fenceEnd.upperBound
        }

        return blocks
    }

    private static func balancedJSONFragments(in text: String, maxCount: Int) -> [String] {
        var fragments: [String] = []
        var index = text.startIndex

        while index < text.endIndex && fragments.count < maxCount {
            let ch = text[index]
            if ch == "[" || ch == "{" {
                if let fragment = extractBalancedFragment(in: text, startingAt: index) {
                    fragments.append(fragment)
                }
            }
            index = text.index(after: index)
        }

        return fragments
    }

    private static func extractBalancedFragment(in text: String, startingAt start: String.Index) -> String? {
        let opening = text[start]
        guard opening == "[" || opening == "{" else { return nil }

        var stack: [Character] = [opening]
        var index = text.index(after: start)
        var inString = false
        var escaping = false

        while index < text.endIndex {
            let ch = text[index]

            if inString {
                if escaping {
                    escaping = false
                } else if ch == "\\" {
                    escaping = true
                } else if ch == "\"" {
                    inString = false
                }
            } else {
                if ch == "\"" {
                    inString = true
                } else if ch == "[" || ch == "{" {
                    stack.append(ch)
                } else if ch == "]" || ch == "}" {
                    guard let last = stack.last else { return nil }
                    let matches = (last == "[" && ch == "]") || (last == "{" && ch == "}")
                    if !matches { return nil }
                    stack.removeLast()

                    if stack.isEmpty {
                        let fragment = String(text[start...index])
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        return fragment.count >= 2 ? fragment : nil
                    }
                }
            }

            index = text.index(after: index)
        }

        return nil
    }
}
