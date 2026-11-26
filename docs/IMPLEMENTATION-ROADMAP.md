# Implementation Roadmap

Parent tracker: [GitHub Issue #2](https://github.com/Love-DC/recursive-engineering-platform/issues/2)  
Current implementation: [Stage 1 — Work Registry registration, Issue #6](https://github.com/Love-DC/recursive-engineering-platform/issues/6)  
Current delivery: [PR #7 — integrated Stage 0–1](https://github.com/Love-DC/recursive-engineering-platform/pull/7)

## Current state

**Stage 0 — implementation delivered in PR #7; acceptance pending.** Repository governance and CI are included in the integrated candidate. The PR is not merged and the independent review requirement remains open.

**Stage 1 — first executable slice implemented in PR #7; candidate CI passed.** The prototype provides canonical active-work registration, request idempotency, ExternalRef uniqueness, append-only events, and a narrow runtime function grant. The CI run used ephemeral PostgreSQL 17.12 and passed T01, T02, T03 (Work registration retry slice), T21 (ExternalRef uniqueness/conflict slice), T26, and prototype security-boundary checks. It is not a production Supabase deployment or a complete T18 security acceptance.

Candidate PR head SHA: `60e10aa129be85754cab2025580f7fed65bdf7a9`  
Exact-SHA CI: [run #45733477038 — success](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/45733477038)

## Stages and gates

| Stage | Scope | Exit evidence | Current state |
|---|---|---|---|
| 0 | Repository governance, architecture baseline, decision register, migration/test conventions, minimal CI | PR merged after independent review; CI passes exact head; fresh-session entry succeeds | IMPLEMENTED IN PR #7; REVIEW / MERGE PENDING |
| 1 | Minimal coordination data model, canonical Work registration and request idempotency in isolated PostgreSQL | Clean migration, T01–T03, ExternalRef slice, role/RLS checks; then full T18 scope audit | REGISTRATION SLICE IMPLEMENTED; EXTENDED MODEL / REVIEW PENDING |
| 2 | Atomic claim, dependency DAG, lease/fencing, resource reservations, idempotent recovery | Adversarial multi-connection and failure tests | NOT STARTED |
| 3 | GitHub/Actions adapter, per-attempt refs, receipts and reconciliation, exact-SHA lifecycle | Adapter contract tests and stale external side-effect reconciliation test | NOT STARTED |
| 4 | Session recovery, authorized Context Compiler, evidence-derived memory, bounded discovery | Fresh-session E2E and empty-queue discovery T19/T20 | NOT STARTED |
| 5 | Heterogeneous project pilot | Owner-selected pilot(s), passed core suite, adapter capability evidence | BLOCKED ON D13 |
| 6 | Selective legacy mapping, shadow comparison, project-by-project cutover | Migration reconciliation, rollback evidence, explicit Owner cutover decision | BLOCKED ON OWNER DECISION |

## Operating rules

- The old RAE remains the operational system until a separately authorized cutover.
- No existing Supabase project or production write path is modified during the prototype.
- Stage 1 prototype tests use disposable PostgreSQL created by GitHub Actions; an existing empty Supabase project is not presumed disposable.
- Every stage gets scoped issues, PRs, test evidence, and review evidence; same-session self-review is not represented as an independent review.
- Stage completion is based on evidence against exact SHAs, not document existence or a narrative status claim.
- D4 remains provisional. D9/D13/D15/D16 remain open and are not resolved by this PR.
- Production authority, pilot selection, and legacy cutover are separate gates; they are not implied by acceptance of the architecture baseline.
