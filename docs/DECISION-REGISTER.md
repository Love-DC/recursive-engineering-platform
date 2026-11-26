# Decision Register

This register separates approval of the architecture baseline from approval of specific deployment, pilot, and migration choices.

Primary source: [Current Design Snapshot v2.0](https://github.com/Love-DC/recursive-engineering-platform/issues/1#issuecomment-7161657103).

## Status vocabulary

- **OWNER-APPROVED** — direct Owner decision for the stated scope/version.
- **EVIDENCE-SUPPORTED** — supported by reproducible evidence; not necessarily an Owner choice.
- **PROVISIONAL** — recommended but not yet approved or validated.
- **UNVERIFIED / OPEN** — unresolved Owner choice or missing implementation evidence.

## Accepted baseline

| Decision | Status | Scope |
|---|---|---|
| Build a general platform that can eventually replace old RAE as the single engineering coordination and execution entry point | OWNER-APPROVED | Product direction; not a cutover authorization |
| Current environment uses one human Owner/GitHub principal, multiple temporary ChatGPT Web sessions, GitHub MCP, Supabase MCP, and GitHub Actions | OWNER-APPROVED | Environment constraint |
| Do not require permanent GPT identity, a second human account, or stable agent_id for MVP | OWNER-APPROVED | MVP identity boundary |
| Accept Current Design Snapshot v2.0 as the overall architecture baseline | OWNER-APPROVED | Architecture direction accepted 2026-11-26; unresolved gates below remain open |

## Provisional technical recommendations

| ID | Decision | Status | Current handling |
|---|---|---|---|
| D4 | One PostgreSQL strong-consistency domain for canonical Work registration and coordination | PROVISIONAL | Use as the architecture hypothesis; prove with transactional/concurrency tests before production reliance |
| D14 | A0 session-triggered MVP; A1 event intake and A2 unattended execution remain future capabilities | PROVISIONAL | Stage 0/1 must not imply background execution |

## Owner decisions still open

| ID | Decision | Status | Gate |
|---|---|---|---|
| D9 | Explicit acceptance of shared Owner principal / credentials and residual stale external side-effect risk | UNVERIFIED / OPEN | Before relying on this risk model for production-critical delivery |
| D13 | Exact first heterogeneous pilot repositories/projects | UNVERIFIED / OPEN | Before pilot registration or project-specific adapter work |
| D15 | Production coordination write entry: current Supabase MCP surface versus a controlled operation endpoint | UNVERIFIED / OPEN | Before production writes / production cutover |
| D16 | Whether any pilot requires native GitHub required approval rather than same-principal COMMENTED process review | UNVERIFIED / OPEN | Before enabling merge for a repo with such branch rules |

## Technical matters delegated to engineering evidence

The following are implementation choices, not Owner questionnaires unless they introduce a new risk or change the approved scope:

- unique index and canonical identity encoding;
- transaction and lock design, retry bounds, and isolation level;
- DAG reachability implementation;
- resource identity normalization and conflict granularity;
- schema decomposition, indexes, and query plans;
- CI test harness and exact-SHA evidence handling;
- Context Compiler retrieval/cache keys and indexer selection.

## Change protocol

Any change to an OWNER-APPROVED decision requires an explicit Owner decision. A provisional decision may be changed by engineering evidence while remaining within the accepted scope. An open Owner gate must remain open until the required direct decision is recorded with scope and version.

Never infer Owner approval from a PR, merge, CI run, repository file, AI comment, or silence.
