# Product Prompt Benchmark Sheet

Last updated: 2026-04-12

This is the main-thread GPT-5.4 benchmark sheet for product-style user inputs across all current routing families.

Canonical oracle:

- [product_prompt_oracle_v1.json](/Users/pratyushrungta/telegraham/evals/product_prompt_oracle_v1.json)

Comparator script:

- [product_prompt_oracle_bench.py](/Users/pratyushrungta/telegraham/tools/product_prompt_oracle_bench.py)

## Goal

Make routing robust for the kinds of things users will actually type in product, not just one canonical example per feature.

This sheet answers:

- what the user might type
- which family it should route to
- which engine it should prefer
- which runtime mode should execute
- why that judgment is correct

## Coverage

Exactly `50` product-style prompts:

- `10` exact lookup
- `10` topic search
- `10` reply queue
- `10` summary
- `10` relationship

## Families

| Family | Preferred engine | Runtime mode |
| --- | --- | --- |
| `exact_lookup` | `message_lookup` | `message_search` |
| `topic_search` | `semantic_retrieval` | `semantic_search` |
| `reply_queue` | `reply_triage` | `agentic_search` |
| `summary` | `summarize` | `summary_search` |
| `relationship` | `graph_crm` | `unsupported` |

## Prompt Set

### Exact Lookup

1. `Where did I share my wallet address with Rahul?`
2. `Find the link I sent for the deck last week`
3. `Which chat did I drop firstdollar.com in?`
4. `Where did I paste the @akhil_bvs handle?`
5. `Locate the contract address I shared with the builder group`
6. `Find the tx hash I sent to the team`
7. `Where did I send that 0x wallet for onboarding?`
8. `Show me the message where I shared the Google Doc link`
9. `Find the invite link I shared in support yesterday`
10. `Which group did I post this URL in: https://example.com/docs/onboarding?`

### Topic Search

1. `first dollar partnerships`
2. `messages about integrating with Stripe`
3. `discussions about onboarding new users for the beta`
4. `feedback on the product demo`
5. `fundraising or investor updates`
6. `conversations about hiring a growth lead`
7. `integration ideas with Notion or Slack`
8. `project Apollo launch planning`
9. `community partnerships`
10. `product-market fit and positioning`

### Reply Queue

1. `Who do I owe a reply to right now?`
2. `What is on me today?`
3. `Show me my pending follow-ups.`
4. `Who is waiting on me?`
5. `What unread chats need a response from me?`
6. `Which messages am I responsible for answering?`
7. `Give me my open DMs that need a reply.`
8. `Show only group chats where I still owe a response.`
9. `Who did I promise to get back to?`
10. `What is still sitting unread and waiting on my reply?`

### Summary

1. `Can you recap what I missed in the Rahul chat?`
2. `What did we decide with Maaz?`
3. `Catch me up on the First Dollar thread.`
4. `Summarize the latest context from the Deeksha conversation.`
5. `Give me a quick recap of my chats with Akhil.`
6. `What are the key takeaways from the last week with Piyush?`
7. `Summarize my chats with Rahul from yesterday.`
8. `Give me the latest context on the launch planning thread.`
9. `What did we decide in the partnership chat last Friday?`
10. `What’s the latest context on the onboarding project?`

### Relationship

1. `Who are my warmest contacts right now?`
2. `Show me stale contacts I should revive.`
3. `Which people have I talked to most this month?`
4. `Who are my strongest investor relationships?`
5. `Which builders have gone inactive lately?`
6. `What are my top people by relationship strength?`
7. `Which contacts haven’t replied in a while?`
8. `Who are the best leads in my network right now?`
9. `Which relationships are currently warm but not active?`
10. `What is the current state of my relationship with Rahul?`

## How To Use It

Compare routing behavior against the oracle:

```bash
/usr/bin/python3 /Users/pratyushrungta/telegraham/tools/product_prompt_oracle_bench.py
```

This will tell us, for each routing-rule variant:

- family coverage
- engine coverage
- runtime-mode coverage
- misses by family

## Why This Exists

We already had deep reply-queue prompt benchmarking, but that is only one product thesis.

This sheet broadens the benchmark to the product level:

- user phrasing first
- routing correctness second
- engine/prompt quality after that

That keeps us from overfitting one canonical query like `who do I need to reply to` while the rest of the product still breaks on natural phrasing.

## Current Script-Only Results

These are the current Python routing-rule variants scored against the `50`-input GPT-5.4 oracle.

| Variant | Family coverage | Notes |
| --- | ---: | --- |
| `current_v1` | `66%` (`33/50`) | Strong on exact lookup, topic search, and summary; weak on reply-style and relationship-style phrasings. |
| `product_coverage_v1` | `74%` (`37/50`) | Improved reply phrasing coverage, but still missed many relationship prompts and one summary phrasing. |
| `product_coverage_v2` | `100%` (`50/50`) | Current script-only winner. Covers all five routing families across the oracle prompt set. |

### Family Breakdown

#### `current_v1`

- `exact_lookup`: `10/10`
- `topic_search`: `9/10`
- `reply_queue`: `2/10`
- `summary`: `9/10`
- `relationship`: `3/10`

#### `product_coverage_v1`

- `exact_lookup`: `10/10`
- `topic_search`: `10/10`
- `reply_queue`: `5/10`
- `summary`: `9/10`
- `relationship`: `3/10`

#### `product_coverage_v2`

- `exact_lookup`: `10/10`
- `topic_search`: `10/10`
- `reply_queue`: `10/10`
- `summary`: `10/10`
- `relationship`: `10/10`

## Why `product_coverage_v2` Won

The winning Python-only ruleset adds:

- better domain-level exact lookup detection
  - example: `Which chat did I drop firstdollar.com in?`
- better reply-queue phrasing coverage
  - examples: `What is on me today?`, `Show me my pending follow-ups.`, `Who did I promise to get back to?`
- better summary phrasing coverage
  - example: `What are the key takeaways from the last week with Piyush?`
- better relationship/CRM detection
  - examples: `Who are my warmest contacts right now?`, `What is the current state of my relationship with Rahul?`
- a relationship override for stale-contact phrasings
  - example: `Which contacts haven’t replied in a while?`

## Current Recommendation

Use `product_coverage_v2` as the script-side routing benchmark winner.

Next workflow:

1. keep testing future prompt sets against this oracle first
2. only after a script-only rule variant proves itself here, consider porting it into Swift
