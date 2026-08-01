//
//  FactAnswerEngine.swift
//  Pidgy — #48 context layer
//
//  The fact-grounded answer engine for search. The model answers ONLY from the
//  user's facts, in the question's language, with no hallucination.
//
//  Voice: prose, like a colleague who has read the material — not a dashboard.
//  It used to be the opposite: hard-capped at 5 bullets with "…+N more", each
//  under ~8 words, on the theory that an answer is a glance. In practice that
//  turned real answers into stubs and truncated the tail silently, so a
//  question with twelve relevant things reported five and hid the rest.
//  Length now follows the question instead of a constant.
//
//  The 55-question offline validation (4 languages, 98% good / 100% grounded /
//  100% language-matched, ~$0.0015/query on Gemini-Flash-lite) predates that
//  rewrite — grounding and language rules are unchanged, but the voice numbers
//  are stale until it is re-run.
//

import Foundation

enum AnswerPrompt {
    static let systemPrompt = """
    You are the user's sharp personal assistant who knows their Telegram world. Answer their question directly and selectively.

    RULES:
    - Reply in the SAME language as the QUESTION (English->English, हिंदी->हिंदी, español->español, Hinglish->Hinglish). Match the question, not the data.
    - ANSWER THE SPECIFIC QUESTION. Pick ONLY the relevant items — filter by the who / what / topic / type / time the question asks. Do NOT dump everything.
    - WRITE LIKE A SHARP COLLEAGUE, NOT A DASHBOARD. Answer in prose, and be brief — usually 2-4 sentences. Lead with the direct answer, then only what changes what the user does next: what is urgent, what has been sitting too long, what is blocked on someone else.
    - SELECT, don't survey. Name the few things that actually matter and leave the rest out — "a handful of smaller things with Rahul" is a better sentence than five more names. Never cram every item into one long paragraph: a wall of names is as unreadable as a wall of bullets, and the user will ask you to cut it.
    - Use a list only when the answer genuinely is a set of parallel things the user will act on one by one. Then let each line carry real substance, not an 8-word stub. Never truncate at a fixed count or trail off with "…+N more" — decide what belongs, say it, and stop.
    - Naming a person or chat: "[**Name**](pidgy://chat/ID)", inline in the sentence — link them the first time they come up, not every mention. The ID comes from that item's [id:...] tag in the data; clicking it opens that chat. Copy ids EXACTLY, never invent one; if an item has no [id:...], just bold the name without a link. Never show a raw id as visible text.
    - Do not pad. No preamble, no restating the question, no "here's what I found", no closing offer to help. Every sentence should carry information the user didn't have.
    - Direction: "I OWE" = the user must act/pay; "OWES ME" = someone owes the user. Use it when the question is about who-owes-whom; otherwise answer naturally.
    - Loop kinds: "I OWE · REPLY" = closable by just sending a message now; "I OWE · TASK" = needs real work first. When the question asks who to REPLY/respond to (any language: "kisko reply karna hai", "who do I owe replies"), list ONLY the REPLY items. When it asks about tasks / pending work, prefer the TASK items. Broad "what do I owe" questions may mix both.
    - Use ONLY the data below. If it's thin or doesn't cover the question, say so in one line — don't invent.
    """

    static func userMessage(
        query: String,
        openLoops: [Fact],
        durable: [Fact],
        summaries: [EntitySummary] = [],
        history: [(role: String, text: String)] = []
    ) -> String {
        let loops = openLoops.map { f -> String in
            // Carry the reply-vs-action split into the payload so "who should
            // I reply to" answers from REPLY loops only (the same distinction
            // that splits the Reply queue from Tasks). Unclassified i_owe
            // defaults to TASK — mirrors FactProjection's lane routing.
            let dir: String
            if f.predicate == .iOwe {
                dir = f.loopKind == .reply ? "I OWE · REPLY" : "I OWE · TASK"
            } else {
                dir = "OWES ME"
            }
            let what = f.action.isEmpty ? f.objectText : f.action
            return "- [\(dir)] \(what) (person: \(f.subjectEntity), chat: \(f.sourceChatTitle) [id:\(f.sourceChatId)])"
        }.joined(separator: "\n")
        let facts = durable.map { "- \($0.subjectEntity): \($0.predicate.rawValue) \($0.objectText) [id:\($0.sourceChatId)]" }
            .joined(separator: "\n")
        let context = summaries.map { "- \($0.entityTitle) [id:\($0.entityId)]: \($0.summary)" }
            .joined(separator: "\n")
        // Follow-up questions in the launcher chat: the prior turns resolve
        // pronouns ("uska kya hua", "and the payment?"). Cap so a long chat
        // can't crowd out the data sections.
        let convo = history.suffix(8)
            .map { "\($0.role == "user" ? "USER" : "ASSISTANT"): \($0.text)" }
            .joined(separator: "\n")
        let convoBlock = convo.isEmpty ? "" : """

        == CONVERSATION SO FAR (resolve "he/she/it/uska" etc. from here) ==
        \(convo)
        """
        return """
        QUESTION: \(query)
        \(convoBlock)
        == OPEN LOOPS (obligations, both directions) ==
        \(loops.isEmpty ? "none" : loops)

        == BACKGROUND FACTS ABOUT PEOPLE ==
        \(facts.isEmpty ? "none" : facts)

        == ROLLING CHAT SUMMARIES (what's currently going on, per chat) ==
        \(context.isEmpty ? "none" : context)
        """
    }
}
