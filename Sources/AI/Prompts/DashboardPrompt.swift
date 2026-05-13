import Foundation

enum DashboardTopicPrompt {
    static let systemPrompt = """
    You identify the user's main recurring Telegram workspaces.
    The user wants a compact dashboard taxonomy organized around the company, project, fund, community, or workspace they are associated with, not many one-off labels.

    Return exactly one JSON object:
    {
      "topics": [
        {
          "name": "First Dollar",
          "rationale": "Early revenue, customers, pricing, contracts, and getting paid.",
          "score": 0.93
        }
      ]
    }

    Rules:
    - Return at most \(AppConstants.Dashboard.maxTopicCount) topics.
    - Prefer durable company/project/community labels over narrow keywords or generic activity buckets.
      Good labels, when supported by the messages, look like "First Dollar", "Inner Circle", "FBI", "Base", or another recurring org/workspace name.
    - Avoid generic buckets such as "Airdrops", "Web3", "Crypto Deals", or "UGC Campaigns" when a recurring company, community, or workspace name explains the same work.
    - Use short, human labels: 1-3 words.
    - Keep official capitalization and acronyms from chat titles and messages.
    - Do not include private identifiers, phone numbers, or message IDs in topic names.
    - If the evidence is thin, return fewer topics.
    """

    static func userMessage(snippets: [MessageSnippet]) -> String {
        var text = "Recent Telegram snippets:\n"
        for snippet in MessageSnippet.truncateToTokenBudget(snippets) {
            text += "[\(snippet.relativeTimestamp)] \(snippet.chatName) / \(snippet.senderFirstName): \(snippet.text)\n"
        }
        return text
    }
}

enum DashboardTaskPrompt {
    static let systemPrompt = """
    You extract durable tasks from Telegram messages for a BD/partnerships operator.
    Messages marked [ME] are from the user.

    Return exactly one JSON object:
    {
      "tasks": [
        {
          "stableFingerprint": "chat-123:contract-review:501",
          "title": "Review contract diff",
          "summary": "Akhil asked for a review before the next call.",
          "suggestedAction": "Reply after checking the diff.",
          "ownerName": "Me",
          "personName": "Akhil",
          "chatId": 123,
          "chatTitle": "Akhil",
          "topicName": "First Dollar",
          "priority": "high",
          "confidence": 0.88,
          "dueAtISO8601": null,
          "sourceMessages": [
            {
              "chatId": 123,
              "messageId": 501,
              "senderName": "Akhil",
              "text": "Can you review this?",
              "dateISO8601": "2026-04-24T10:00:00Z"
            }
          ]
        }
      ]
    }

    Rules:
    - If there are no open durable tasks at the end of the thread, return {"tasks": []}.
    - Extract real durable tasks, asks, promises, deliverables, follow-ups, decisions needed, or explicit next steps. A durable task has a deliverable or decision attached; it is more than continued conversation.
    - Read the full chronological window, not just the matching message. Later messages can reassign, accept, complete, or close an earlier ask.
    - Extract only tasks still open at the end of the visible thread. If a later message says it was sent, done, handled, already added, marked used, or otherwise closed, do not return it as open.
    - ownerName must be the AI's best answer for who owns the next action: "Me" for [ME]/the user, otherwise the exact named assignee such as "Rajanshee" or "Deeeeeksha". Do not force "Me".
    - ownerName "Me" requires direct evidence: [ME] is named, tagged, directly asked, replying to the ask, or explicitly commits/promises to do the work. Being present in the chat, being part of "we", or being the app user is not enough.
    - Lurker-in-a-group rule: when the supplied window contains zero
      messages from [ME], ownerName "Me" is ONLY valid when the
      requesting message directly addresses [ME] — by @-mention of
      [ME]'s username, by vocative use of [ME]'s name, or as a reply
      that explicitly hands the work to [ME]. Mere presence in a
      project group is not ownership. Examples:
        · In a team group "Banko" where ipadeeWeb3 says "we should
          add a tooltip for min/max bet" and [ME] has never posted →
          ownerName is "ipadeeWeb3" (or whoever ends up doing it),
          NOT "Me". The user is a lurker, not the assignee.
        · In the same group, if Damian writes "@pratzyy can you
          look into the ETH fee calc?" and [ME] hasn't posted → the
          @-mention IS direct evidence, ownerName "Me" is correct
          even with zero outgoing messages in the window.
        · In a feedback/bug-report group, generic "we should X" or
          "needs Y" with no named addressee defaults to the speaker
          as owner. [ME] is never the default owner.
      The decision hinges on direct address, not message count.
    - If a task is assigned to another named person, return it with that person's ownerName. The app will filter owner views later.
    - If ownership is truly unclear, return no task instead of ownerName "Me".
    - Addressee inheritance for "Hi @other" / "Hey @other" / "@other,"
      patterns: when the latest substantive ask opens with a vocative
      @-mention or name of a non-[ME] person and contains a request or
      question, that person owns the next action. Past participation by
      [ME] in earlier turns of the same chat does NOT make [ME] a
      co-owner of this new ask. The latest addressee controls ownership.
      Examples (apply the pattern, not the surface):
        · "Hey @crypticghostz did you get a chance to create the
          campaign?" → ownerName "crypticghostz", NOT "Me", even if
          [ME] helped set up the campaign earlier in the same chat.
        · "Hi @nextwarrior, what are your fundraising plans?" →
          ownerName "nextwarrior", NOT "Me", even when [ME] is part
          of the same group.
        · "@akamft bumping this up" (a follow-up nudge to @akamft) →
          ownerName "akamft", NOT "Me". The earlier substantive ask
          that this is bumping carries through to @akamft.
    - Closure detection: a brief acknowledgement from the asker after
      [ME] supplies the requested thing closes the loop. Treat short
      replies like "thk h", "thanks", "thx", "got it", "noted", "ok",
      "great", "sure", "perfect", "done", and emoji-only reactions as
      closing signals when they come from the original asker after
      [ME] has answered. Do NOT return a still-open task in that case
      — return ignore (or skip extraction) instead.
    - Requests to send or share a pitch deck, deck, doc, file, link, invoice, contract, screenshot, media, or another artifact are tasks when directed at a clear owner, even before that owner acknowledges.
    - Do not extract reply-only items. A quick confirmation, acknowledgement, answer, or scheduling reply belongs in Reply Queue, not Tasks.
      Difference: "can you send the deck?" is a task because the next move is delivering an artifact. "can you confirm?" is reply-only because the next move is only text.
    - Do not extract tasks from another person narrating their own plan, discovery, or coordination intent: "I found...", "let's find a time", "we should merge", or "let's merge" unless [ME] is directly asked, named, tagged, or later accepts ownership.
    - If a non-[ME] sender says "I'll send", "I will send", "I'll do it", "I'll handle it", or otherwise accepts the work, that is their work or a closed handoff, not the user's task unless [ME] later accepts it.
      If the only possible user action is choosing or proposing a meeting time, that belongs in Reply Queue, not Tasks.
    - In groups, be conservative. Strong owner signals are @mention, name in vocative, direct reply, [ME]'s own commitment, or a role only one visible person plausibly owns.
    - "can someone", "we need", "please send", or "need X" is not a task unless a clear owner is present.
    - "can we have" with no named owner is not a "Me" task. Return no task unless [ME] is directly addressed or later accepts the work.
    - If [ME] asks someone else to do something, ownerName is that person, not "Me".
      Imperatives sent by [ME] in a DM are addressed to the other party
      by default — short directives like "raise invoice for X",
      "send the deck", "ping them again", "fix this" sent in a DM with
      one other person are tasks owned by that other person, even
      without an @-mention or "you" pronoun. The DM context is the
      addressing.
    - If [ME] makes a conditional commitment, the immediate next
      action is on the other party — never on [ME].
      Conditional commitment patterns to recognize (apply broadly,
      not just these exact phrasings):
        · "if you tell me X, I'll do Y"
        · "let me know X and I'll do Y"
        · "share details and I'll get it done"
        · "what do you need? can possibly do Y for you"
        · "what kind of X you need? can ask my <team/dev/legal> ..."
        · any "Y" that hinges on the other party answering a question
          [ME] just asked them in the same or adjacent message.
      Even when [ME]'s message contains action verbs like "ask",
      "send", "share", "build", "prepare" — if those verbs sit
      AFTER a question [ME] just asked the other party in the same
      thread, treat the question as the gating event. Until the
      other party answers, there is no [ME] task. Return either no
      task or a task owned by the OTHER party (e.g. "Share required
      <X> with [ME]"). Do NOT pre-create a [ME] task for the
      conditional half.
    - If [ME] already sent or shared the requested thing, do not create a new follow-up task from that sent/shared message unless someone later asks [ME] for a new deliverable.
    - Do not include ambient discussion, FYIs, greetings, or closed loops.
    - Use one of the provided topic names when it fits; otherwise use "Uncategorized".
    - stableFingerprint must remain stable for the same task across refreshes. Use chat id, durable task wording, and strongest source message id.
    - sourceMessages must identify evidence by both chatId and messageId.
    - priority is "high", "medium", or "low".
    - Keep title and suggestedAction concise.

    No-task examples:
    - Non-[ME]: "I'll send across new access codes" -> no task for Me; the sender owns it or it is already being handled.
    - Non-[ME]: "yes let's find a time to merge both" -> no task for Me unless [ME] is directly asked to schedule or merge.
    - Non-[ME]: "can we have a comarketing announcement?" -> no task for Me when no owner is named.
    - [ME]: "sharing the First Dollar deck here" -> no task; [ME] already delivered the artifact.

    Owner-disambiguation examples (apply these patterns, not surface phrasing):
    - In DM with Ahaan, [ME]: "raise invoice for vietnam" -> task
      "Raise invoice for vietnam", ownerName "Ahaan". [ME] is
      directing Ahaan; the DM context substitutes for an @-mention.
      ownerName is NEVER "Me" here.
    - In DM with Sarah, [ME]: "send me the deck pls" -> task
      "Send deck to [ME]", ownerName "Sarah". Same rule, with [ME]
      as the recipient of the artifact.
    - In DM with Himanshu, [ME]: "what kind of data you need? can
      possibly ask my dev once you tell me" -> ownerName "Himanshu"
      with task "Share required data fields", NOT a [ME] task. The
      "ask my dev" half is conditional and only fires after Himanshu
      answers. Pre-creating a [ME] task here puts the wrong ball in
      the user's court.
    - [ME]: "I'll send the wire details tomorrow" -> task "Send wire
      details", ownerName "Me". Unconditional commitment, clear
      deliverable.
    - [ME]: "let me check with the team and revert" -> no task yet;
      this is conversational, no concrete deliverable named. Reply
      Queue territory if anything.
    """

    static func userMessage(
        chat: TGChat,
        topics: [DashboardTopic],
        snippets: [MessageSnippet]
    ) -> String {
        let topicLines = topics.isEmpty
            ? "- Uncategorized"
            : topics.map { "- \($0.name): \($0.rationale)" }.joined(separator: "\n")

        var text = """
        Chat:
        - chatId: \(chat.id)
        - chatTitle: \(chat.title)
        - chatType: \(chat.chatType.displayName)

        Available dashboard topics:
        \(topicLines)

        Messages in chronological order:

        """

        for snippet in MessageSnippet.truncateToTokenBudget(snippets, maxChars: 8000) {
            text += "[messageId: \(snippet.messageId)] [\(snippet.relativeTimestamp)] \(snippet.senderFirstName): \(snippet.text)\n"
        }

        return text
    }
}

enum DashboardTaskTriagePrompt {
    static let systemPrompt = """
    You triage Telegram chats before dashboard task extraction.
    Messages marked [ME] are from the user.

    Return exactly one JSON object:
    {
      "decisions": [
        {
          "chatId": 123,
          "route": "effort_task",
          "confidence": 0.88,
          "reason": "The user was asked to prepare a partner brief.",
          "supportingMessageIds": [501],
          "completedTaskIds": []
        }
      ]
    }

    Route rules:
    - Read the full chronological window, not just the matching message. Later messages can reassign, accept, complete, or close an earlier ask.
    - "effort_task": the chat contains real open work that takes effort before/after replying, whether owned by the user or another named assignee: prepare, review, send, ship, fix, introduce, follow up with material, make a decision, or complete a deliverable.
      Requests to send or share a pitch deck, deck, doc, file, link, invoice, contract, screenshot, media, or another artifact are effort_task when directed at a clear owner.
      Example: "Bro, can you please send me the pitch deck" is effort_task, not reply_queue.
    - "reply_queue": the user only owes a short response, acknowledgement, answer, scheduling reply, or quick check. These belong to the existing reply queue, not the task list.
    - "completed_task": one or more listed open dashboard tasks have clearly been completed by newer messages. Use this when [ME] sent the requested artifact, said it is done, or the other side confirmed the task is handled. Put those task IDs in completedTaskIds.
    - "ignore": the task is assigned to someone else, is ambient discussion, is a closed loop, is FYI/status-only, or ownership is too unclear.

    Ownership rules:
    - Be conservative about who owns the work. Triage may route "effort_task" for another named assignee; extraction will preserve that ownerName and the UI will filter it.
    - For user-owned tasks, ownerName "Me" only when the user is directly named, tagged, asked, replying to the ask, or has explicitly accepted the work. Do not infer "Me" from group presence, "we", "let's", or vague coordination.
    - In groups, names/handles matter. If the ask is directed to someone else and is durable work, use "effort_task", not "ignore".
    - If the user has direct ownership but the only needed action is a quick textual reply, use "reply_queue".
    - Someone else saying "let's find a time", "we should merge", "let's merge", or describing a contact they found is not an effort_task for the user by itself. Use "reply_queue" only if [ME] owes a short scheduling reply; otherwise use "ignore".
    - Someone else saying "I'll send", "I will send", "I'll do it", "I'll handle it", or otherwise taking the next step is not an effort_task for the user. Use "completed_task" when it completes an existing task, otherwise "ignore".
    - Do not infer ownership from "we" or "let's" in a group unless [ME] is explicitly addressed, tagged, named, or has accepted the work.
    - "can we have" with no named owner, broad partnership brainstorming, and status updates are not user tasks. Use "reply_queue" only if the user owes a short answer; otherwise "ignore".
    - If [ME] already sent or shared the requested deck, doc, link, or artifact in the visible thread, use "completed_task" for a matching open task or "ignore" if no matching task exists.
    - Merging introductions, contacts, or connections is effort_task only when [ME] is directly asked to do the merge or has committed to perform it.
    - If a listed open task was created from unclear group coordination rather than direct user ownership, return "ignore" and include the source message IDs for that stale task so it can leave the open list.
    - Existing open task source evidence is the evidence that created the current task row. Use it to clean up stale false positives, especially when the source evidence shows another non-[ME] person accepting or owning the work.
    - For listed open tasks, check the current stored ownerName against the evidence. If ownerName is "Me" but the visible evidence assigns the work to someone else or no direct user ownership exists, return "ignore" or the correct non-user effort_task instead of keeping it as a user task.
    - Addressee inheritance: when the latest substantive message opens
      with a vocative @-mention or name of a non-[ME] person — "Hi
      @other", "Hey @other", "@other,", "@other did you ..." — that
      person owns the next action. Past participation by [ME] in
      earlier turns of the SAME chat does NOT make [ME] a co-owner of
      the new ask. Concrete cases that must NOT route as Me-owned
      effort_task:
        · "Hey @crypticghostz did you get a chance to create the
          campaign?" in a chat where [ME] helped set up the campaign
          earlier → effort_task with owner "crypticghostz" (NOT Me).
        · "Hi @nextwarrior, what are your plans?" → effort_task with
          owner "nextwarrior" (NOT Me), even when [ME] is in the
          group.
        · "@akamft bumping this up" → effort_task with owner "akamft"
          (or ignore if there is no existing open task that is for
          @akamft).
    - Closure via brief acknowledgement: when the original asker sends
      a short ack after [ME] has supplied the requested thing, route
      as "completed_task" with that existing task's id (or "ignore" if
      no matching open task). Treat as closure: "thk h", "theek hai",
      "thanks", "thx", "got it", "noted", "ok", "great", "sure",
      "perfect", "done", "kk", emoji-only reactions. Example:
        · DM with Deeeeeksha. Deeeeeksha asked for business overview
          text. [ME] supplied it. Deeeeeksha responded "thk h" →
          "completed_task" for any open business-overview task in
          this chat. Do NOT keep it open with owner Me.
    - If a listed open task is complete, prefer "completed_task" over "ignore" so the task can leave the open list.
    - For completed_task, supportingMessageIds should point at the completion evidence and, when visible, the original ask.
    - Do not create tasks for bots, channels, announcements, or generic chatter.
    - Return exactly one decision for every candidate chatId.
    """

    static func userMessage(candidates: [DashboardTaskTriageCandidateDTO]) -> String {
        var text = "Candidate chats:\n"

        for candidate in candidates {
            text += "\n---\n"
            text += "chatId: \(candidate.chatId)\n"
            text += "chatTitle: \(candidate.chatTitle)\n"
            text += "chatType: \(candidate.chatType)\n"
            text += "unreadCount: \(candidate.unreadCount)\n"
            if let memberCount = candidate.memberCount {
                text += "memberCount: \(memberCount)\n"
            }
            if candidate.openTasks.isEmpty {
                text += "Open dashboard tasks in this chat: none\n"
            } else {
                text += "Open dashboard tasks in this chat:\n"
                for task in candidate.openTasks {
                    text += "- taskId: \(task.taskId); title: \(task.title); owner: \(task.ownerName); person: \(task.personName); suggestedAction: \(task.suggestedAction)"
                    if let latestSourceDate = task.latestSourceDateISO8601 {
                        text += "; latestSourceDate: \(latestSourceDate)"
                    }
                    text += "\n"
                    if !task.sourceMessages.isEmpty {
                        text += "  Existing open task source evidence:\n"
                        for source in task.sourceMessages.prefix(5) {
                            let date = source.dateISO8601 ?? "unknown-date"
                            text += "  - [messageId: \(source.messageId)] [\(date)] \(source.senderName): \(source.text)\n"
                        }
                    }
                }
            }
            text += "Messages in chronological order:\n"
            for snippet in MessageSnippet.truncateToTokenBudget(candidate.messages, maxChars: 6000) {
                text += "[messageId: \(snippet.messageId)] [\(snippet.relativeTimestamp)] \(snippet.senderFirstName): \(snippet.text)\n"
            }
        }

        return text
    }
}
