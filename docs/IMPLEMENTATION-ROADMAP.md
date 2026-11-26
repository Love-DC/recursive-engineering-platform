# Implementation Roadmap

Parent tracker: [GitHub Issue #2](https://github.com/Love-DC/recursive-engineering-platform/issues/2)  
Current integrated delivery: [PR #9 — Stage 0–1B](https://github.com/Love-DC/recursive-engineering-platform/pull/9)  
Stage 1A registration: [Issue #6](https://github.com/Love-DC/recursive-engineering-platform/issues/6)  
Stage 1B data model: [Issue #8](https://github.com/Love-DC/recursive-engineering-platform/issues/8)

## Current state

**Stage 0 — implementation merged to `main` through PR #9; post-merge CI verified.** Repository governance, architecture/decision docs, session entry contract, and repository CI are present. The bounded final integration acceptance's sole documentation evidence-pointer finding was resolved by PRs #33–#35 and Issue #32 is closed completed. The post-merge main validation is recorded in the [canonical evidence record](https://github.com/Love-DC/recursive-engineering-platform/pull/9#issuecomment-7183275628). No deferred Owner gate or production readiness is implied.

**Stage 1A — canonical Work registration implemented and tested in PR #9.** Active canonical identity uniqueness, request idempotency, ExternalRef uniqueness, append-only Work events, and the register-or-link transaction passed the named tests.

**Stage 1B — minimum coordination data model implemented and schema-tested in PR #9.** Physical Resource / ProjectResource, Execution, ResourceClaim, dependency graph descriptors/membership, typed WorkRelations, OwnerDecision provenance, Evidence, and OperationReceipt/event records are present as additive migration 0002. CI validates per-Work attempt_no and fence uniqueness with targeted terminal-Execution probes, the exact active ResourceClaim conflict, each of the three composite ResourceClaim foreign keys with a distinct negative test, selected RLS/table-ownership properties, and other integrity constraints. These are tested schema slices, not the Stage 2A/2B protocols.

**Stage 2A — implementation candidate in [PR #38](https://github.com/Love-DC/recursive-engineering-platform/pull/38), still Open + Draft and unmerged.** Initial P1 protocol findings were corrected with immutable Resource identity, claim-time resource/ref checks, same-project prerequisite eligibility, and adversarial tests. The second review's P2 Resource DELETE/UUID reuse finding was corrected by rejecting all Resource DELETE operations and requiring archival. The third review confirmed that fix and found no further reproducible protocol defect, but requested documentation updates. The fourth review verified the docs-closeout HEAD `1d23644fd160fa17802afacba59be91f496999c6` / tree `c513fa9858b2e9bc55918ccbd8597a846d73b6cd` with [Run #69](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/45791612367); Repository contract checks (job `139811798601`) and PostgreSQL 17.12 Work Registry integration/Stage 2A tests (job `139811798988`) both passed. It found the docs omitted Run #69 and retained stale pending wording; this follow-up records Run #69 and clarifies the status. The current follow-up commit's exact-head CI is maintained in the live PR #38 / Issue #37 evidence record; a commit cannot embed the ID of the workflow run that validates itself. T04 PASS, T05 PASS, T06 PARTIAL (whole-repository/branch-ref exclusion only; no path-overlap semantics). Stage 2A remains unaccepted pending focused confirmation, merge and post-merge verification.

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
| 2A | Atomic claim, resource reservation, lease/fencing, stale-attempt rejection, resource identity integrity, and read-only prerequisite eligibility | T04–T06 plus claim-time prerequisite/resource adversarial tests | RESOURCE UUID LIFECYCLE FIX CONFIRMED; PROTOCOL-CODE RUN #67 PASSED; DOCS-CLOSEOUT RUN #69 PASSED ON ITS EXACT HEAD; FOURTH REVIEW FOUND STALE RUN-STATUS TEXT; THIS FOLLOW-UP RECORDS RUN #69; CURRENT TIP CI IS LINKED FROM PR #38 / ISSUE #37; FOCUSED CONFIRMATION AND MERGE GATES REMAIN |
| 2B | Dependency graph mutation, cycle prevention, graph-wide concurrency, READY invalidation, and dependency mutation authorization | Adversarial graph-lock/cycle/READY invalidation tests T07–T09 | NOT STARTED |
| 3 | GitHub/Actions adapter, per-attempt refs, receipts and reconciliation, exact-SHA lifecycle | Adapter contract tests and stale external side-effect reconciliation T12–T15/T21/T22 | NOT STARTED |
| 4 | Session recovery, authorized Context Compiler, evidence-derived memory, bounded discovery | Fresh-session E2E and empty-queue discovery T10/T11/T19/T20/T25 | NOT STARTED |
| 5 | Heterogeneous project pilot | Owner-selected pilot(s), passed core suite, adapter capability evidence | BLOCKED ON D13 |
| 6 | Selective legacy mapping, shadow comparison, project-by-project cutover | Migration reconciliation, rollback evidence, explicit Owner cutover decision | BLOCKED ON OWNER DECISION |

## Operating rules

- Old RAE remains operational until a separately authorized cutover.
- No existing Supabase project or production write path is modified during prototype work.
- Stage 1 migrations run only in disposable GitHub Actions PostgreSQL 17.12.
- Stage completion requires exact-SHA CI evidence and independent review; same-session self-review is not independent. The exact current branch-tip SHA and its Actions run are recorded in the live PR/Issue evidence record, rather than embedded in the commit being validated.
- The Stage 1B schema records durable identities; Stage 2A prototype claim/lease/fence/resource-reservation code, immutable Resource UUID lifecycle, and claim-time dependency checks are in PR #38. Run #67 passed on the reviewed protocol-code candidate; Run #69 passed on the reviewed documentation-closeout candidate. This follow-up records Run #69 and corrects the stale statement that its CI was still pending. The exact-head run for this follow-up commit is maintained in the live PR #38 / Issue #37 evidence record to avoid embedding a commit's own post-creation CI run in itself. Stage 2A remains pending focused confirmation, merge, and post-merge verification. Stage 2B graph mutation and cycle/READY protocols, Stage 3 adapters, and all production authorization/deployment gates remain separate.
- D4 remains provisional. D9/D13/D15/D16 remain open and are not resolved by this PR.
- Production authority, pilot selection, and legacy cutover are separate gates, not implied by architecture acceptance.
