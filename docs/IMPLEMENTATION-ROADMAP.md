# Implementation Roadmap

Parent tracker: [GitHub Issue #2](https://github.com/Love-DC/recursive-engineering-platform/issues/2)  
Current integrated delivery: [PR #9 — Stage 0–1B](https://github.com/Love-DC/recursive-engineering-platform/pull/9)  
Stage 1A registration: [Issue #6](https://github.com/Love-DC/recursive-engineering-platform/issues/6)  
Stage 1B data model: [Issue #8](https://github.com/Love-DC/recursive-engineering-platform/issues/8)

## Current state

**Stage 0 — implementation merged to `main` through PR #9; post-merge CI verified.** Repository governance, architecture/decision docs, session entry contract, and repository CI are present. The bounded final integration acceptance's sole documentation evidence-pointer finding was resolved by PRs #33–#35 and Issue #32 is closed completed. The post-merge main validation is recorded in the [canonical evidence record](https://github.com/Love-DC/recursive-engineering-platform/pull/9#issuecomment-7183275628). No deferred Owner gate or production readiness is implied.

**Stage 1A — canonical Work registration implemented and tested in PR #9.** Active canonical identity uniqueness, request idempotency, ExternalRef uniqueness, append-only Work events, and the register-or-link transaction passed the named tests.

**Stage 1B — minimum coordination data model implemented and schema-tested in PR #9.** Physical Resource / ProjectResource, Execution, ResourceClaim, dependency graph descriptors/membership, typed WorkRelations, OwnerDecision provenance, Evidence, and OperationReceipt/event records are present as additive migration 0002. CI validates per-Work attempt_no and fence uniqueness with targeted terminal-Execution probes, the exact active ResourceClaim conflict, each of the three composite ResourceClaim foreign keys with a distinct negative test, selected RLS/table-ownership properties, and other integrity constraints. These are tested schema slices, not the Stage 2A/2B protocols.

**Stage 2A — remediation implementation candidate is in [PR #38](https://github.com/Love-DC/recursive-engineering-platform/pull/38), still Open + Draft.** The first independent review returned `CHANGES_REQUIRED` for mutable physical Resource identity, missing claim-time dependency eligibility, and stale status docs; these were addressed with immutable identity fields, claim-time resource/ref checks, read-only prerequisite eligibility, and adversarial tests. The second independent review on HEAD `0ec2285108b6b116101afcda987da678d1de25f6` / tree `09eac0ecbe0441a39b06e4afd99f528e4d54af2d` returned `CHANGES_REQUIRED` for (P2) Resource DELETE + UUID reuse preserving an old resource-scoped OwnerDecision, and (P2) four docs not recording Run #64. The lifecycle fix now rejects all Resource DELETE operations and requires archival; regression tests prove the UUID cannot be reused after ProjectResource unlink. Code candidate HEAD `f85324935b0884c6808bf16fcb775255dde38bc6` / tree `ba84cee32c4d46d38cccd865675993676a86b154` passed exact-head [Run #65](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/45789044131), including PostgreSQL 17.12 protocol tests and repository contract checks. This documentation synchronization records the actual review and code evidence; the latest docs-inclusive exact-head CI and a further independent re-review remain required. Not merged or accepted.

**Stage 2B — dependency graph mutation, cycle prevention, graph-wide concurrency, and READY invalidation remain unimplemented.**

### Historical CI evidence — not final candidate evidence

- Run #24 ([45734761932](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/45734761932)) passed for historical SHA `d055fc1d6fbc7f83d83e35a43fefd6d89a90db43`.
- Run #27 ([45735069544](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/45735069544)) passed for the review SHA `5648ce0de9e3d9bd6460645819d75bffb35dd772`.
- Both runs are retained as historical evidence only. Neither identifies the final post-remediation candidate.
- **Current exact-HEAD commit/tree and matching Actions run:** maintained in the [canonical PR #9 evidence record](https://github.com/Love-DC/recursive-engineering-platform/pull/9#issuecomment-7183275628).
- **T01:** PASS for the tested Stage 1A concurrency slice; the exact PostgreSQL rendezvous log and corresponding run are recorded in the canonical evidence record. This is not the complete architecture coordination guarantee.

PR #9 is merged to `main`. The bounded final integration acceptance's sole documentation evidence-pointer finding was resolved by PRs #33–#35; the canonical [evidence record](https://github.com/Love-DC/recursive-engineering-platform/pull/9#issuecomment-7183275628) is the single maintained pointer for the candidate and post-merge CI. CI success is not Owner acceptance of deferred gates, and no production readiness is claimed.

## Architecture-to-implementation stage crosswalk

The stage numbers describe two different planning views and must not be read as a one-to-one renumbering:

| Architecture Snapshot v2.0 | Implementation roadmap | Mapping |
|---|---|---|
| Stage 1 — Work registration and coordination, including the required atomic coordination and authorization guarantees | Stages 1A and 1B | Preparatory implementation slices: canonical Work registration and the minimum coordination data model. These slices do not complete architecture Stage 1. |
| Remaining architecture Stage 1 guarantees | Implementation Stage 2A + Stage 2B | Stage 2A implements transactional claim/resource reservation, lease/takeover/fencing, and claim-time eligibility checks. Stage 2B implements dependency mutation, DAG safety, graph-wide concurrency, and READY invalidation. |

Architecture stage definitions remain unchanged; implementation Stage 2A does not complete the remaining Stage 1 guarantees by itself.

## Stages and gates

| Stage | Scope | Exit evidence | Current state |
|---|---|---|---|
| 0 | Repository governance, architecture baseline, decision register, migration/test conventions, CI | PR merged after independent review; CI on exact head; fresh-session entry succeeds | IMPLEMENTED AND MERGED TO MAIN; EXACT-HEAD AND POST-MERGE CI VERIFIED |
| 1A | Project, canonical Work, exact active identity, ExternalRef, request idempotency, register-or-link | T01–T03, T21 mapping slice, clean migration | IMPLEMENTED AND MERGED TO MAIN; EXACT-HEAD AND POST-MERGE CI VERIFIED |
| 1B | Physical Resource, ProjectResource, Execution, ResourceClaim, relation graph, OwnerDecision, Evidence, OperationReceipt | Clean migration, FK/unique/check constraints, owner/RLS object checks | IMPLEMENTED AND MERGED TO MAIN; SCHEMA TESTS AND POST-MERGE CI VERIFIED |
| 2A | Atomic claim, resource reservation, lease/fencing, stale-attempt rejection, resource identity integrity, and read-only prerequisite eligibility | T04–T06 plus claim-time prerequisite/resource adversarial tests | RESOURCE UUID LIFECYCLE FIX IMPLEMENTED; CODE CANDIDATE EXACT-HEAD RUN #65 PASSED; FOUR STATUS DOCS SYNCHRONIZED; DOCS-INCLUSIVE CI AND INDEPENDENT RE-REVIEW PENDING |
| 2B | Dependency graph mutation, cycle prevention, graph-wide concurrency, READY invalidation, and dependency mutation authorization | Adversarial graph-lock/cycle/READY invalidation tests T07–T09 | NOT STARTED |
| 3 | GitHub/Actions adapter, per-attempt refs, receipts and reconciliation, exact-SHA lifecycle | Adapter contract tests and stale external side-effect reconciliation T12–T15/T21/T22 | NOT STARTED |
| 4 | Session recovery, authorized Context Compiler, evidence-derived memory, bounded discovery | Fresh-session E2E and empty-queue discovery T10/T11/T19/T20/T25 | NOT STARTED |
| 5 | Heterogeneous project pilot | Owner-selected pilot(s), passed core suite, adapter capability evidence | BLOCKED ON D13 |
| 6 | Selective legacy mapping, shadow comparison, project-by-project cutover | Migration reconciliation, rollback evidence, explicit Owner cutover decision | BLOCKED ON OWNER DECISION |

## Operating rules

- Old RAE remains operational until a separately authorized cutover.
- No existing Supabase project or production write path is modified during prototype work.
- Stage 1 migrations run only in disposable GitHub Actions PostgreSQL 17.12.
- Stage completion requires exact-SHA CI evidence and independent review; same-session self-review is not independent.
- The Stage 1B schema records the durable identities; Stage 2A prototype claim/lease/fence/resource-reservation code, immutable Resource UUID lifecycle, and claim-time dependency checks are in PR #38. The code candidate passed exact-head Run #65. Stage-status documents record the second review findings and remediation; exact docs-inclusive CI and independent re-review remain separate gates. Stage 2B graph mutation and cycle/READY protocols, Stage 3 adapters, and all production authorization/deployment gates remain separate.
- D4 remains provisional. D9/D13/D15/D16 remain open and are not resolved by this PR.
- Production authority, pilot selection, and legacy cutover are separate gates, not implied by architecture acceptance.
