# Exact Lookup Benchmark Sheet V2

Last updated: 2026-04-12

This is the grounded handle/username and person-scoped exact-lookup benchmark focused on outgoing local SQLite evidence.

Canonical oracle:

- [exact_lookup_oracle_v2.json](/Users/pratyushrungta/telegraham/evals/exact_lookup_oracle_v2.json)

Comparator script:

- [exact_lookup_answer_bench.py](/Users/pratyushrungta/telegraham/tools/exact_lookup_answer_bench.py)

## Goal

This benchmark checks whether exact lookup can recover the right outgoing message when the user asks for:

- a handle or username they mentioned
- a person-scoped exact message
- a direct handle-targeted instruction or update

## Coverage

The v2 oracle includes `12` grounded hit cases:

- direct handle mentions like `@Inaaralakhani`, `@deeksharungta`, and `@Saxenasaheb`
- person-scoped operational asks like `add thoughts`, `post this on the main group`, and `ship the cap thingy`
- multi-handle nudges like `@jackdishman` and `@emma_neynar`

## Strong Candidates

| Query | Message ID | Chat ID | Why |
| --- | ---: | ---: | --- |
| `Where did I say I was running 5 min late to @Inaaralakhani?` | `446497292288` | `-5146948443` | Outgoing person-scoped handle mention with a concrete status update. |
| `Where did I thank @Inaaralakhani for the call?` | `446520360960` | `-5146948443` | Outgoing handle mention paired with a specific call context and shared links. |
| `Where did I cc @deeksharungta?` | `450828959744` | `-5274014299` | Minimal outgoing handle-only exact lookup. |
| `Where did I say moving our chat here to @abhitejsingh?` | `450173599744` | `-5072846231` | Explicit chat migration intent. |
| `Where did I say I can run AI stuff on FD to @Saxenasaheb?` | `448734953472` | `-4207340164` | Operational handle mention, not just a name drop. |
| `Where did I ask @DacoitRahul to add thoughts?` | `436606074880` | `-5240871539` | Direct outgoing instruction to a specific handle. |
| `Where did I ask @akhil_bvs to post this on the main group and pin it?` | `152943198208` | `-4207340164` | Group instruction with explicit handle ownership. |
| `Where did I ask @priyanshuratnakar to add me to the test group?` | `316652126208` | `-4928512323` | Action request to a named handle in a noisy group thread. |
| `Where did I ask @chiiyoobot to research the China hardware AI scene?` | `422761725952` | `52504489` | Bot handle request with concrete artifact-like context. |
| `Where did I ask @jackdishman and @emma_neynar to bump this?` | `452273897472` | `-5217898121` | Multi-handle nudge, useful for exact handle recovery. |
| `Where did I ask @qed_k to keep checking if there was more?` | `317860085760` | `-4928512323` | Handle mention with follow-up/ownership context. |
| `Where did I ask @utkarsh to ship the cap thingy?` | `188063154176` | `865924605` | Very specific action request with a handle. |

## How To Run

```bash
/usr/bin/python3 /Users/pratyushrungta/telegraham/tools/exact_lookup_answer_bench.py --oracle /Users/pratyushrungta/telegraham/evals/exact_lookup_oracle_v2.json
```

## Suggested Next Step

Once this v2 oracle is accepted, expand with a few more:

- `@handle` queries that are not simple `cc` or `bumping`
- person-scoped exact lookups with multiple names in the same row
- a couple of strict no-result cases to keep false positives honest
