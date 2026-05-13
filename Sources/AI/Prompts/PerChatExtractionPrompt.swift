import Foundation

/// Prompt for the MAP step of summary search.
///
/// Sent once per candidate chat, in parallel. The AI's job is narrow:
/// look at this one chat's recent messages and pull out anything
/// relevant to the user's query, or declare the chat irrelevant.
///
/// Cheap (small model, single-chat context), parallelizable, cited-by-
/// construction (each output is bound to a known chat). The synthesis
/// (REDUCE) step then runs over the small set of non-null extracts —
/// which is much easier for the model than reasoning about 6 chats
/// stuffed into one prompt simultaneously.
///
/// Why this matters: the old single-shot approach asked the model to
/// (a) figure out which chats are relevant AND (b) write a coherent
/// cross-chat answer in one pass. Production RAG systems (Slack AI,
/// Glean, LlamaIndex multi-doc patterns) all use map-reduce instead
/// because single-shot has well-documented failure modes — order
/// sensitivity, hallucinated synthesis when no info is present, and
/// (the one that bit us) the model bailing with "no clear context" if
/// the irrelevant chats outnumber the relevant ones.
enum PerChatExtractionPrompt {
    static func systemPrompt(query: String, chatName: String) -> String {
        """
        You're extracting relevant content from ONE Telegram chat for a
        user query.

        User query: "\(query)"
        Chat name: "\(chatName)"

        Read the messages provided in the user message. Decide:

        - If ANYTHING in these messages relates to the query, write 1-3
          short sentences capturing what was said. Quote specific
          phrases, numbers, or names when useful. "Relates" is
          permissive: discussion of the topic counts even if nothing
          was decided. A passing mention of the named person counts if
          the query is about that person.

        - If NOTHING in these messages relates to the query at all,
          respond with exactly: NOT_RELEVANT

        Rules:
        - Plain text. No markdown, no JSON, no chat-name headers.
        - Stay grounded in the actual message text. Don't invent dates,
          decisions, or facts.
        - Be specific: prefer concrete names/numbers/quotes over
          generic phrases like "the team discussed pricing".
        - Mirror the language of the messages (Hindi/Hinglish stays
          Hinglish, etc.).
        - Don't include the chat name in the extract — the caller will
          attach it.
        - Don't ask clarifying questions or refuse. Either summarize
          or say NOT_RELEVANT.

        Examples:

        Query: "what did we decide with Akhil on email"
        Messages: Akhil sent the v3 email copy on May 3 and asked for
        feedback before sending to the partner.
        Extract: Akhil sent v3 of the email copy May 3 and is waiting
        on feedback before sending it to the partner. No final
        approval visible.

        Query: "pricing"
        Messages: Talked about Goa trip in October. Cheap flights.
        Extract: NOT_RELEVANT
        """
    }
}
