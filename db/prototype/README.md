# Work Registry, coordination model, and Stage 2A–Stage 4B protocol prototypes

This directory contains disposable PostgreSQL experiments for the Stage 1A/1B data model and the Stage 2A, Stage 2B, Stage 3, Stage 4A recovery, and Stage 4B Context Compiler/Context Pack protocol prototypes.

## Implemented

- Canonical active Work identity uniqueness, request idempotency, ExternalRef linking, and append-only registration events.
- Physical Resource identity independent of Project namespace, ProjectResource grant provenance, Execution attempts, ResourceClaims, typed WorkRelations, dependency graph descriptors, OwnerDecision provenance, Evidence, and OperationReceipt records.
- Stage 2A migration `0005_stage2a_atomic_execution_coordination.sql`:
  - atomic Work claim and all-or-nothing physical resource reservation;
  - expired-lease takeover, monotonic per-Work fencing, renewal, fenced finish/failure, and atomic reservation release;
  - immutable WorkResourceRequirement declarations after execution begins;
  - immutable physical Resource identity tuple (`provider`, `host`, `resource_type`, `stable_resource_id`, `canonical_key`); a changed target must receive a new `resource_id`;
  - permanent physical Resource identity lifecycle: `DELETE` is rejected even when no ProjectResource link or active claim remains; retire the row with `status='archived'`, and never reuse its `resource_id`;
  - claim-time validation that each required Resource remains an active GitHub repository and each ref is a canonical fully-qualified GitHub branch ref;
  - claim-time re-check of active `depends_on` prerequisites. Stage 2A accepts only completed (`delivered`) prerequisites in an active, same-project dependency graph owned by that project. Incomplete prerequisites, archived graphs, and shared/cross-project graph scope fail closed.
- The Stage 2A test harness exercises independent PostgreSQL sessions, claim/takeover races, lease boundary behavior, resource conflicts, rollback, grant authorization, Resource identity immutability and non-reuse, dependency eligibility, runtime RPC grants, and SECURITY DEFINER inventory.

## Verification

The initial Stage 2A candidate at HEAD `285dbc092744cb5d0f88ab391e25a84257298919` passed [Run #54](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/45781729538), then returned **CHANGES_REQUIRED** for protocol and documentation findings. Initial P1 protocol findings and the second-round Resource UUID DELETE/reuse P2 were corrected. The third independent review found no further reproducible Stage 2A protocol defect; Run #67 passed on protocol-code HEAD `8d5225f9b691ca6eb866b951d67217cd627538ee` / tree `a6ec86ef30d15f3bfabe0f91a27a2009c7945d75`. The fourth review's P2 omission of Run #69 was corrected; the final focused review on candidate HEAD `b1a3590e8792355d8330cf52e7e30decc700e9d3` / tree `b88e60222483e9396508c6b621d669198cf61074` returned PASS. PR #38 merged to `main` at `4d3b52195e0fdcd0a20f96dedb18eb97f88a1131`. Pre-merge [Run #71](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/45794893367) and post-merge exact-commit [Run #72](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/45798073719) both passed Repository contract checks and PostgreSQL 17.12 integration/Stage 2A protocol tests. T04 PASS, T05 PASS, T06 PARTIAL (whole-repository/branch-ref exclusion only; no path-overlap locking). The Stage 2A prototype is merged and post-merge verified; production Supabase, production writes, pilot and legacy RAE cutover remain out of scope.


**Stage 2B post-merge verification:** PR #43 merged to `main` at `f222267e015bd3ab6058eb34464b370a5e405171`. The focused independent migration-upgrade confirmation returned PASS; exact source-head Run #85 and post-merge Run #86 passed. T07/T08/T09/T23 are PASS for the tested disposable PostgreSQL 17.12 prototype scope.

**Post-merge verification:** PR #38 merge commit `4d3b52195e0fdcd0a20f96dedb18eb97f88a1131` is the current integrated Stage 2A delivery. [Run #72](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/45798073719) passed on that exact commit: Repository contract checks and PostgreSQL 17 Work Registry integration tests both succeeded; the latter completed clean migration/concurrency and Stage 2A atomic coordination tests on PostgreSQL 17.12.

**Current-tip evidence convention:** this file records completed runs for identified prior candidate SHAs. The exact-head CI result for the current tip is maintained in the live [PR #38](https://github.com/Love-DC/recursive-engineering-platform/pull/38) and [Issue #37](https://github.com/Love-DC/recursive-engineering-platform/issues/37) evidence record. A commit cannot record its own CI run because the run is created only after the commit; requiring it to do so would create an endless commit/run loop.

The Stage 1A/1B integrated baseline is merged through [PR #9](https://github.com/Love-DC/recursive-engineering-platform/pull/9). Its post-merge evidence, including disposable PostgreSQL 17.12 scope, remains in the [canonical evidence record](https://github.com/Love-DC/recursive-engineering-platform/pull/9#issuecomment-7183275628).

## Stage 3 — GitHub delivery and reconciliation prototype

Stage 3 is implemented additively in migrations:
- `0007_stage3_github_delivery_reconciliation.sql`: adapter capability manifests; one delivery identity per Execution; deterministic `work/<work_id>/execution/<execution_id>` branch; per-Execution PR identity; exact-SHA evidence; append-only evidence invalidation.
- `0008_stage3_external_receipt_reconciliation.sql`: persist provider receipts separately from reconciliation; resolve ambiguous outcomes from provider observations; permit retry only after authoritative not-found while the Execution remains current; stale outcomes are recorded instead of replayed.

The session adapter capability manifest is `adapters/github-session-tools.json`. Branch/ref, PR, Process Review COMMENT, Native GitHub APPROVE, merge, CI lookup, and post-merge verification are declared supported by the connected session-tool surface. Process Review records the same authenticated principal; separate ChatGPT sessions are not separate GitHub users. Native APPROVE is a real GitHub review action as the connected principal, but an independently authenticated approver is unavailable. Deployment is explicitly unsupported.

`aep_delivery/adapter.py` contains the contract parser and a deterministic Fake GitHub Provider. The fake can commit an external side effect and then drop the response; tests must query provider state before retrying. The database never calls GitHub and never treats its fence as revoking shared credentials. Stale merges are reconciled as actual external facts, marked stale, and invalidate affected old exact-HEAD evidence.

The Stage 3 PostgreSQL 17.12 test runner is `scripts/test_stage3_delivery_protocol.py` and covers T12, T13, T14, T15, T21, and T22. [PR #49](https://github.com/Love-DC/recursive-engineering-platform/pull/49) is independently reviewed, merged at `ae3ff5ead7cf4fa3c0e8c47bb47b9beb24f9b18b`, and post-merge verified by Run #104. [Issue #54](https://github.com/Love-DC/recursive-engineering-platform/issues/54) and docs closeout PR #55 are complete. This remains disposable PostgreSQL prototype evidence; it does not imply production deployment, production authorization, pilot, RAE cutover, or unattended execution.

## Stage 4A — fresh-session recovery prototype

Migration `0009_stage4_session_recovery.sql` adds:
- `aep.record_session_checkpoint`: append-only, idempotent checkpoint/handoff events bound to Work, current Execution, exact fence, originating session and a live lease. Stale or expired attempts cannot append.
- `aep.recover_session_state`: reconstructs a bounded project snapshot from persisted ProjectResource grants, Work/dependency state, Execution attempts and lease/fence, Work events, source evidence, per-attempt deliveries and exact-SHA evidence, operation receipts/events, relevant OwnerDecision versions and adapter capability manifests.
- The scope gate is checked before Work and evidence content retrieval. This is a trusted single-Owner prototype gate, not authenticated caller/session identity; T17 production authorization and D15 remain OPEN.
- The response explicitly states that expired lease does not prove the old ChatGPT session stopped and database fencing does not revoke shared GitHub/MCP credentials. Every Execution with a persisted session ID is conservatively marked `old_session_may_still_be_active=true`; `session_termination_observed=false` until a trustworthy termination ledger exists. A takeover status of `expired` is not a session-termination signal.
- `scripts/test_stage4_recovery.py` runs T10/T11 on disposable PostgreSQL 17.12. The final reviewed candidate HEAD `c5cc11f276ebd8b0b40e5913bc09b09af06a96a5` / Tree `db21cff07e9d4b80b7586105799a0eee4d312cc8` passed exact-head [Run #131](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/45912782823) and third-round independent review [PASS in Issue #68](https://github.com/Love-DC/recursive-engineering-platform/issues/68#issuecomment-7206302471). It verifies clean migrations 0001–0009, T10/T11, post-takeover session uncertainty, exact default dependency graph/targets, all eleven related-collection truncation assertions, Work-list truncation, ProjectResource grants, OwnerDecision versions, adapter manifests, both attempts' exact delivery/CI/receipt/event histories, and the Stage 2A/2B/3 regression suites. PR #65 merged to `main` at `1ab52e5d46d9ceb4c3a3e580e538b2865b044095`; exact-merge post-merge [Run #132](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/45916067822) passed Repository contract job `140235476995` and PostgreSQL 17 Work Registry integration job `140235476578`, including Stage 4A.

## What these tests do not prove

- Production-grade authenticated project authorization and cross-project retrieval isolation; Stage 2B graph authorization checks are prototype behavior, not a production authorization boundary.
- Path-overlap or normalized write-set conflict semantics; current resource exclusion is conservative exact whole-repository/branch-ref exclusion.
- Populated-database migration upgrade/preflight safety.
- A production Supabase deployment, production write API, authenticated caller-to-project binding, or hostile multi-tenant authorization.
- A production GitHub provider/runtime, production-grade authenticated caller/project binding, actual branch-protection approval by an independent principal, deployment, or legacy RAE cutover. Stage 3 CI validates protocol behavior using a controllable provider fake; it does not deploy or write to GitHub.
- An always-on LLM runtime or proof that an expired ChatGPT session has stopped acting. Stage 4A recovery only reconstructs persisted state and fences checkpoint writes; it does not terminate or authenticate sessions.

## Security and deployment limitations

This is a **trusted single-Owner test prototype**, not a production Supabase migration or production authorization interface.

- Disposable GitHub Actions PostgreSQL 17.12 only. No existing Supabase project or legacy RAE database has been accessed or modified.
- The permanent Resource DELETE trigger protects against ordinary runtime-role operations, not a privileged PostgreSQL administrator: a superuser or sufficiently privileged schema/table owner can deliberately disable triggers or alter the schema. The trusted single-Owner prototype does not defend against a hostile database administrator.
- Role creation assumes a disposable PostgreSQL administrator connection. It is not intended to run unchanged against an existing Supabase project.
- The database fence does not revoke shared GitHub/MCP credentials or prevent every stale external side effect.
- Do not deploy or expose these prototype functions as production write APIs. D4 remains PROVISIONAL; D9, D13, D15, and D16 remain UNVERIFIED / OPEN.


## Stage 4B — authorized Context Compiler and Context Packs

Migration `0010_stage4b_context_compiler.sql` adds a logical compiler API without introducing a separate service:

- `record_context_source_revision` records an adapter-observed repository ref pin (commit SHA, tree SHA and content SHA-256) against the append-only Evidence Ledger and advances a monotonic per-Work/project/resource/ref source version only when the observed pin or provenance changes.
- `compile_context_pack` checks an active ProjectResource grant before accessing Work, dependency, decision or Evidence content. It builds an immutable JSON projection with physical repository/ref identity, source pin, Work and dependency state, decision ID/version/status/provenance, evidence refs and hashes, compiler/indexer/config versions and token budget.
- `get_context_pack` resolves only pack routing IDs before the grant check; after the grant is confirmed it reloads source state and validates the cache fingerprint and compiler/indexer/config/budget dimensions before its first read of cached payload bytes. A changed source/decision/dependency/grant/compiler/indexer/config/budget returns `stale` with no payload; revoked access returns `denied` with zero source rows/bytes in the audit.
- Context Packs and cache rows are immutable disposable projections. Raw Evidence remains authoritative. The cache key binds the complete source snapshot and all compiler dimensions. ProjectResource grant version, Work version, dependency graph/target versions and decision version/status are inside the fingerprint.
- The budget limiter uses a deterministic ceiling of UTF-8 JSON bytes divided by four as an explicit estimate. It is deliberately not represented as an exact model tokenizer. Evidence entries are truncated deterministically and the response reports included/omitted counts.
- Explicit cross-project dependency retrieval fails closed. No vector database/index is introduced; `indexer_version` records which evidence projection strategy generated the pack.
- Run `python scripts/test_stage4b_context_compiler.py` against a disposable PostgreSQL 17.12 database to exercise this slice.

### Stage 4B prototype limitations

This is not a production authorization system. The ProjectResource row is a trusted-single-Owner scope gate; neither `session_id` nor the caller-supplied `project_id` authenticates a principal. The repository observation (commit/tree/content hash plus adapter provenance) is supplied by the calling GitHub session adapter; PostgreSQL does not independently authenticate the adapter or fetch GitHub content. Cross-project Context grants, production Supabase deployment/RLS review, native identity binding, a network retrieval adapter and model-specific tokenization remain outside this prototype. Do not deploy these functions as a production API.


### Stage 4B candidate verification

Exact PR HEAD `11136edb42fea4cbc4f431845f211e6038ecd29a` passed GitHub Actions [Run #45918619591](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/45918619591): Repository contract job `140243707885` and PostgreSQL 17.12 integration job `140243707465` both succeeded. Independent review is pending. This evidence applies only to the disposable prototype, not a production deployment or authenticated production identity boundary.
