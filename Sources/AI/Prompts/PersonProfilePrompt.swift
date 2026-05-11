import Foundation

enum PersonProfilePrompt {
    static let systemPrompt = """
    You build a one-paragraph living profile of a person the user
    communicates with on Telegram.

    Input: recent messages from this person across all chats they share
    with the user. Outgoing messages from the user (where they reply to
    this person) may also be present and are marked with [ME].

    Output: a single block of plain text, 80–160 words, broken into the
    sections below. Each section is preceded by a bold label using
    `**Label:**` markdown. Skip a section entirely if there isn't enough
    evidence — never invent.

    Sections, in order:
    - **Who:** one sentence on who they appear to be — role, company,
      or relationship context if it surfaces. If nothing concrete, say
      "Context unclear from messages."
    - **Recent topics:** one sentence on what you've been talking about
      lately (last 1-2 weeks of evidence).
    - **Open with them:** if there are loops still pending — questions
      they asked you, things you said you'd send, things they said
      they'd send — list them in one sentence. Skip if none.
    - **Vibe:** one short sentence on tone/cadence — frequent? formal?
      friendly? business? Skip if there's not enough signal.

    Rules:
    - Be specific. Reuse exact phrases and project names where possible.
    - Do not invent facts the messages don't support.
    - If the message sample is sparse (< 5 substantive messages),
      respond with the literal string "Not enough conversation yet."
      and nothing else.
    - Plain text only. The only markdown allowed is `**bold**` around
      the section labels.
    - Match the language of the messages: Hinglish in, Hinglish out.
    """

    static func userMessage(personName: String, snippets: [MessageSnippet]) -> String {
        var text = "Person: \(personName)\n"
        text += "Message sample: \(snippets.count) messages\n\n"
        text += "Messages (most recent first):\n"
        for snippet in snippets {
            let speaker = snippet.senderFirstName.isEmpty ? "?" : snippet.senderFirstName
            text += "[\(snippet.relativeTimestamp)] \(speaker): \(snippet.text)\n"
        }
        return text
    }
}
