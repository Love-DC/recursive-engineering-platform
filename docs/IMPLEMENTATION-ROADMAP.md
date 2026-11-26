# Implementation Roadmap

Parent tracker: [GitHub Issue #2](https://github.com/Love-DC/recursive-engineering-platform/issues/2)  
Current integrated delivery: [PR #9 — Stage 0–1B](https://github.com/Love-DC/recursive-engineering-platform/pull/9)  
Stage 1A registration: [Issue #6](https://github.com/Love-DC/recursive-engineering-platform/issues/6)  
Stage 1B data model: [Issue #8](https://github.com/Love-DC/recursive-engineering-platform/issues/8)

## Current state

**Stage 0 — implementation merged to `main` through PR #9; post-merge CI verified.** Repository governance, architecture/decision docs, session entry contract, and repository CI are present. The bounded final integration acceptance's sole documentation evidence-pointer finding was resolved by PRs #33–#35 and Issue #32 is closed completed. The post-merge main validation is recorded in the [canonical evidence record](https://github.com/Love-DC/recursive-engineering-platform/pull/9#issuecomment-7183275628). No deferred Owner gate or production readiness is implied.

**Stage 1A — canonical Work registration implemented and tested in PR #9.** Active canonical identity uniqueness, request idempotency, ExternalRef uniqueness, append-only Work events, and the register-or-link transaction passed the named tests.

**Stage 1B — minimum coordination data model implemented and schema-tested in PR #9.** Physical Resource / ProjectResource, Execution, ResourceClaim, dependency graph descriptors/membership, typed WorkRelations, OwnerDecision provenance, Evidence, and OperationReceipt/event records are present as additive migration 0002. CI validates per-Work attempt_no and fence uniqueness with targeted terminal-Execution probes, the exact active ResourceClaim conflict, each of the three composite ResourceClaim foreign keys with a distinct negative test, selected RLS/table-ownership properties, and other integrity constraints. These are tested schema slices, not the Stage 2A/2B protocols.

**Stage 2A — implemented, merged and post-merge verified.** [PR #38](https://github.com/Love-DC/recursive-engineering-platform/pull/38) merged source HEAD `b1a3590e8792355d8330cf52e7e30decc700e9d3` / tree `b88e60222483e9396508c6b621d669198cf61074` to `main` at merge commit `4d3b52195e0fdcd0a20f96dedb18eb97f88a1131`. The final focused independent confirmation was PASS ([Issue #37 report](https://github.com/Love-DC/recursive-engineering-platform/issues/37#issuecomment-7188779525)). Pre-merge exact-head Run #71 and post-merge exact-commit [Run #72](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/45798073719) both passed Repository contract checks and PostgreSQL 17.12 integration/Stage 2A protocol tests. T04 PASS, T05 PASS, T06 PARTIAL (conservative whole-repository/branch-ref exclusion only; path-overlap locking remains unsupported). This is prototype implementation/verification, not production authorization or deployment.

**Stage 2B — implemented, independently reviewed, merged and post-merge verified.** [PR #43](https://github.com/Love-DC/recursive-engineering-platform/pull/43) merged source HEAD `94c4bfb15e34bd93a48c23ab4eeb007f7e40aa25` / tree `f3a91bc529efa7403be9ac1b3b57046aa5018fc1` to `main` at `f222267e015bd3ab6058eb34464b370a5e405171`. The focused independent migration-upgrade confirmation returned [PASS](https://github.com/Love-DC/recursive-engineering-platform/pull/43#issuecomment-7191498260). Exact source-head [Run #85](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/45813047865) passed, including the populated-upgrade regression; post-merge [Run #86](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/45817835143) passed both repository contract and PostgreSQL 17.12 integration jobs, including T07/T08/T09/T23. This is prototype evidence only, not production Supabase deployment.

**Stage 3 — implementation and behavior tests are present in Draft PR #49; independent review pending.** Additive migrations 0007–0008, the connected-session adapter capability manifest, Fake GitHub Provider, and PostgreSQL 17.12 tests for T12/T13/T14/T15/T21/T22 are retained. The exact synchronized candidate HEAD/Tree and matching CI result are maintained in live PR #49 and [Issue #48](https://github.com/Love-DC/recursive-engineering-platform/issues/48); independent review is tracked separately in [Issue #50](https://github.com/Love-DC/recursive-engineering-platform/issues/50). PR #49 remains Draft and unmerged; this prototype is not a production GitHub gateway or deployment.

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
| 2A | Atomic claim, resource reservation, lease/fencing, stale-attempt rejection, resource identity integrity, and read-only prerequisite eligibility | T04–T06 plus claim-time prerequisite/resource adversarial tests | MERGED TO MAIN; FINAL FOCUSED REVIEW PASS; PRE-MERGE RUN #71 AND POST-MERGE RUN #72 PASSED; T04 PASS / T05 PASS / T06 PARTIAL (WHOLE-REPOSITORY/BRANCH-REF EXCLUSION; NO PATH-OVERLAP LOCKING) |
| 2B | Dependency graph membership, atomic DAG mutation, cycle prevention, graph-wide concurrency, authorization, READY invalidation, and required/optional parent-child completion | Exact-head and post-merge PostgreSQL 17.12 CI; independent review; populated-upgrade regression; T07/T08/T09/T23 | IMPLEMENTED, INDEPENDENTLY REVIEWED, MERGED AND POST-MERGE VERIFIED — PR #43; merge `f222267e015bd3ab6058eb34464b370a5e405171`; Run #85 and Run #86 passed |
| 3 | GitHub/Actions adapter, per-attempt refs, receipts and reconciliation, exact-SHA lifecycle | Adapter contract and PostgreSQL behavior tests T12–T15/T21/T22; independent review and merge gates | IMPLEMENTATION + BEHAVIOR TESTS IN DRAFT PR #49; EXACT-HEAD CI TRACKED IN PR/ISSUE; INDEPENDENT REVIEW PENDING; NOT MERGED |
| 4 | Session recovery, authorized Context Compiler, evidence-derived memory, bounded discovery | Fresh-session E2E and empty-queue discovery T10/T11/T19/T20/T25 | NOT STARTED |
| 5 | Heterogeneous project pilot | Owner-selected pilot(s), passed core suite, adapter capability evidence | BLOCKED ON D13 |
| 6 | Selective legacy mapping, shadow comparison, project-by-project cutover | Migration reconciliation, rollback evidence, explicit Owner cutover decision | BLOCKED ON OWNER DECISION |

## Operating rules

- Old RAE remains operational until a separately authorized cutover.
- No existing Supabase project or production write path is modified during prototype work.
- Stage 1 migrations run only in disposable GitHub Actions PostgreSQL 17.12.
- Stage completion requires exact-SHA CI evidence and independent review; same-session self-review is not independent. The exact current branch-tip SHA and its Actions run are recorded in the live PR/Issue evidence record, rather than embedded in the commit being validated.
- The Stage 1B schema records durable identities. Stage 2A claim/lease/fencing/resource reservation and claim-time prerequisite eligibility are implemented in PR #38 and merged to main. Final focused review passed; Run #71 validated the exact pre-merge candidate and post-merge Run #72 validated merge commit `4d3b52195e0fdcd0a20f96dedb18eb97f88a1131`. T04/T05 are PASS and T06 remains PARTIAL with conservative whole-repository/branch-ref exclusion only. Stage 2B graph membership, atomic DAG mutation, graph authorization, READY invalidation, parent/child aggregation, and migration-upgrade compatibility are implemented in PR #43; independent review PASS, exact-head Run #85 and post-merge Run #86 passed on merge commit `f222267e015bd3ab6058eb34464b370a5e405171`. T07/T08/T09/T23 are PASS for the tested PostgreSQL prototype. Stage 3 adapter/reconciliation is implemented and behavior-tested in Draft PR #49, with independent review pending; Stage 4 recovery/discovery remains outstanding. Production authorization/deployment, pilot, and legacy cutover remain separate gates.
- D4 remains provisional. D9/D13/D15/D16 remain open and are not resolved by this PR.
- Production authority, pilot selection, and legacy cutover are separate gates, not implied by architecture acceptance.
