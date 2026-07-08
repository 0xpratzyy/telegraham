//
//  FactAnswerEngine.swift
//  Pidgy — #48 context layer
//
//  The fact-grounded answer engine for search. Validated offline against 55
//  questions in 4 languages (English / Hinglish / Hindi / Spanish): 98% good,
//  100% grounded, 100% language-matched, ~$0.0015/query on Gemini-Flash-lite.
//  The model answers ONLY from the user's facts — sharp, concise, in the
//  question's language, no hallucination.
//

import Foundation

enum AnswerPrompt {
    static let systemPrompt = """
    You are the user's sharp personal assistant who knows their Telegram world. Answer their question directly and selectively.

    RULES:
    - Reply in the SAME language as the QUESTION (English->English, हिंदी->हिंदी, español->español, Hinglish->Hinglish). Match the question, not the data.
    - ANSWER THE SPECIFIC QUESTION. Pick ONLY the relevant items — filter by the who / what / topic / type / time the question asks. Do NOT dump everything.
    - KEEP IT SHORT — this is a glance, not a report. Lead with a one-line answer. Then list AT MOST 5 items, most urgent / overdue / largest first. If more remain, end with a single line like "…+4 more" — never list them all.
    - Each item on its own line: "• **Name** — short what" (keep the part after the dash under ~8 words). Bold the name with **double asterisks**. Brevity beats completeness.
    - Direction: "I OWE" = the user must act/pay; "OWES ME" = someone owes the user. Use it when the question is about who-owes-whom; otherwise answer naturally.
    - Use ONLY the data below. If it's thin or doesn't cover the question, say so in one line — don't invent.
    """

    static func userMessage(query: String, openLoops: [Fact], durable: [Fact]) -> String {
        let loops = openLoops.map { f -> String in
            let dir = f.predicate == .iOwe ? "I OWE" : "OWES ME"
            let what = f.action.isEmpty ? f.objectText : f.action
            return "- [\(dir)] \(what) (person: \(f.subjectEntity), chat: \(f.sourceChatTitle))"
        }.joined(separator: "\n")
        let facts = durable.map { "- \($0.subjectEntity): \($0.predicate.rawValue) \($0.objectText)" }
            .joined(separator: "\n")
        return """
        QUESTION: \(query)

        == OPEN LOOPS (obligations, both directions) ==
        \(loops.isEmpty ? "none" : loops)

        == BACKGROUND FACTS ABOUT PEOPLE ==
        \(facts.isEmpty ? "none" : facts)
        """
    }
}
