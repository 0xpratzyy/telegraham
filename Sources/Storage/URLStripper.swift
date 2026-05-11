import Foundation

/// Removes URL substrings from a message body before it lands in the FTS
/// index or the embedding pipeline. Display still shows the original text
/// — this is purely for retrieval.
///
/// Without this, common URL path components like `status`, `update`,
/// `thread`, `post`, `comment` poison every multi-word search whenever
/// the corpus contains shared tweets / X.com links (e.g. `/status/123`).
/// Stripping the URL substring keeps real English text searchable while
/// dropping the noise.
enum URLStripper {
    /// Anything starting with `http://`, `https://`, `ftp://`, `tg://`,
    /// or `mailto:` up to the next whitespace boundary. Conservative on
    /// purpose — we'd rather miss the occasional bare `www.foo.com` than
    /// accidentally chew up a normal word. Telegram in-app links
    /// (`tg://`) and email addresses are stripped because they share
    /// the same "noisy substrings inside opaque strings" problem.
    private static let pattern: NSRegularExpression = {
        let raw = #"(?i)\b(?:https?://|ftp://|tg://|mailto:)\S+"#
        // Force-unwrap is safe — this pattern is fixed at compile time.
        return try! NSRegularExpression(pattern: raw)
    }()

    static func strip(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let range = NSRange(text.startIndex..., in: text)
        let stripped = pattern.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: " "
        )
        // Collapse the whitespace runs the removal left behind so the
        // tokenizer doesn't see double-spaces. Trim trailing/leading
        // whitespace too — empty FTS rows are fine, but ragged ones
        // confuse bm25.
        return stripped
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
