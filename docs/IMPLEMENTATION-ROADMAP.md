# Implementation Roadmap

Parent tracker: [GitHub Issue #2](https://github.com/Love-DC/recursive-engineering-platform/issues/2)  
Current task: [Stage 0 — repository foundation, Issue #3](https://github.com/Love-DC/recursive-engineering-platform/issues/3)

## Current state

**Stage 0 — in progress.** The repository entry point has been initialized. Governance files and CI are being added through a dedicated branch and PR.

No runtime service, Supabase schema, production adapter, pilot, or legacy migration is implemented by this repository bootstrap.

## Stages and gates

| Stage | Scope | Exit evidence | Current state |
|---|---|---|---|
| 0 | Repository governance, architecture baseline, decision register, migration/test conventions, minimal CI | PR reviewed; CI passes exact head SHA; new-session entry check succeeds | IN PROGRESS |
| 1 | Minimal coordination data model in isolated non-production PostgreSQL | Clean-database migration; role/RLS audit; schema and uniqueness tests | NOT STARTED |
| 2 | Atomic register/claim, dependency DAG, lease/fencing, resource reservations, idempotent recovery | Adversarial multi-connection concurrency and failure tests | NOT STARTED |
| 3 | GitHub/Actions adapter, per-attempt refs, receipts and reconciliation, exact-SHA lifecycle | Adapter contract tests and stale external side-effect reconciliation test | NOT STARTED |
| 4 | Session recovery, authorized Context Compiler, evidence-derived memory, bounded discovery | Fresh-session E2E and empty-queue discovery T19/T20 | NOT STARTED |
| 5 | Heterogeneous project pilot | Owner-selected pilot(s), passed core suite, adapter capability evidence | BLOCKED ON D13 |
| 6 | Selective legacy mapping, shadow comparison, project-by-project cutover | Migration reconciliation, rollback evidence, explicit Owner cutover decision | BLOCKED ON OWNER DECISION |

## Operating rules

- The old RAE remains the operational system until a separately authorized cutover.
- No production writes are introduced as a side effect of Stage 0 or Stage 1.
- Stage 1 begins in an explicitly isolated non-production database. Do not assume that an existing empty project is disposable solely because it has no tables.
- Each stage gets its own scoped issue, PR, test evidence, and independent review.
- Stage completion is based on evidence against exact SHAs, not document existence or a narrative status claim.
- Production authority, pilot selection, and legacy cutover are separate gates; they are not implied by acceptance of the architecture baseline.
