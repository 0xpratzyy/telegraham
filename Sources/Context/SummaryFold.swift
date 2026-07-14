//
//  SummaryFold.swift
//  Pidgy — entity memory (M1: chat rolling summaries)
//
//  A chat's summary is a FOLD, never a recompute: old summary + the new
//  messages a pass just consumed → updated summary. Cost stays O(new
//  messages), quality compounds, and each version is kept as a dated
//  snapshot (bi-temporal, like facts: supersede, never overwrite) so
//  "what was going on last month" stays answerable.
//

import Foundation

enum SummaryFoldPrompt {
    static let systemPrompt = """
    You maintain a ROLLING SUMMARY of one Telegram chat for its owner ([ME]). Fold the NEW messages into the OLD summary and return the UPDATED summary — nothing else.

    Rules:
    - At most 130 words. Plain text, 2–4 tight lines or bullets. No headers, no markdown emphasis.
    - Shape: what this chat IS (one phrase — keep from the old summary unless it changed); the current threads (what's being worked on, decided, pending, owed); anything notable from the newest messages.
    - Carry forward what is still true from the OLD summary. Drop what the new messages resolve or make stale. NEVER invent — if the new messages are trivial, the update is minimal.
    - Be concrete: names, amounts, dates. No filler like "the conversation continues".
    - Write in English regardless of the messages' language.
    - Output ONLY the summary text.
    """

    static func userMessage(
        chatTitle: String,
        chatType: String,
        myName: String,
        oldSummary: String?,
        transcript: String
    ) -> String {
        """
        Chat: \(chatTitle) (\(chatType)). The user is [ME] (name: \(myName)).

        == OLD SUMMARY ==
        \(oldSummary?.isEmpty == false ? oldSummary! : "none — this is the first fold")

        == NEW MESSAGES ==
        \(transcript)
        """
    }
}
