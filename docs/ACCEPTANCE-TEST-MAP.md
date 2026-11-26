# Acceptance Test Map — T01–T26

Authoritative behavioral definitions are in [Snapshot v2.0](https://github.com/Love-DC/recursive-engineering-platform/issues/1#issuecomment-7161657103). PASS and PARTIAL distinguish a tested schema/prototype slice from the complete end-to-end architecture guarantee.

| ID | Required proof | Planned stage | Status |
|---|---|---:|---|
| T01 | Concurrent canonical registration yields one Work | 1A–2 | PASS — two independent PostgreSQL sessions are synchronized at a database advisory-lock rendezvous; the controller releases only after both are observed waiting, then one canonical Work is committed and linked. Exact integrated evidence: see the [canonical PR #9 exact-HEAD evidence record](https://github.com/Love-DC/recursive-engineering-platform/pull/9#issuecomment-7183275628), maintained in place as the candidate advances. |
| T02 | Idempotency replay and payload conflict | 1A–2 | PASS — replay returns same work_id; changed payload with same key conflicts |
| T03 | Lost registration response recovers without duplicate Work/ExternalRef | 1A–3 | PARTIAL — Work registration retry from a new session passed; external operation receipt reconciliation is not implemented |
| T04 | Concurrent claim race yields one current execution | 2A | PASS — two independent PostgreSQL connections produced exactly one current Execution, Work pointer, and fence. The Stage 2A candidate passed exact-head Run #71, final focused independent review, and post-merge Run #72 on merge commit `4d3b52195e0fdcd0a20f96dedb18eb97f88a1131`. |
| T05 | Lease takeover advances fence and rejects stale writes | 2A | PASS — lease-boundary, expired takeover, monotonic fence, stale renewal/completion rejection, and current completion passed in the Stage 2A protocol suite. Exact-head Run #71, final focused independent review, and post-merge Run #72 on merge commit `4d3b52195e0fdcd0a20f96dedb18eb97f88a1131` passed. |
| T06 | Same physical resource/ref/write set is mutually excluded across projects | 2A | PARTIAL — exact physical Resource/ref/conflict-key claims are atomically excluded across projects; exact-head Run #67 passed the whole-repository/branch-ref scenario. The third independent review confirmed the conservative exclusion behavior. Path-overlap and narrower write-set concurrency remain unsupported. |
| T07 | Concurrent two-node dependency insertion cannot create a cycle | 2B | PASS — independent PostgreSQL sessions exercise opposing dependency-edge insertion under the graph lock; exact source-head Run #85 and post-merge Run #86 passed on `f222267e015bd3ab6058eb34464b370a5e405171`. |
| T08 | Cross-project graph writes require authorized shared graph | 2B | PASS — tested shared-graph membership, exact approved direct-Owner grant scope, write/read separation, revoke/rejoin, concurrent batches, idempotency/version/history, and rollback in the Stage 2B protocol suite; Run #85 and post-merge Run #86 passed. |
| T09 | READY invalidation after dependency/authority change | 2B | PASS — both claim-vs-dependency-mutation lock interleavings and readiness recomputation/invalidation cases passed in Stage 2B protocol tests on Run #85 and post-merge Run #86. |
| T10 | Fresh session recovers durable work/execution/delivery/lease state | 4 | NOT IMPLEMENTED |
| T11 | Recovery does not rely on prior chat transcript | 4 | NOT IMPLEMENTED |
| T12 | Retry/takeover receives an independent delivery ref | 3 | PARTIAL — Execution stores delivery branch/base/head/PR fields; per-attempt delivery lifecycle is not implemented |
| T13 | Stale external merge is reconciled and evidence invalidated | 3 | NOT IMPLEMENTED |
| T14 | Same-principal process review is distinct from native approval | 3 | NOT IMPLEMENTED |
| T15 | Exact-SHA CI, merge SHA validation and deployment remain distinct | 3 | NOT IMPLEMENTED |
| T16 | OwnerDecision requires direct provenance and scope/version | 1B–2 | PARTIAL — approved status requires explicit direct-Owner provenance fields; actual Owner event verification/supersede enforcement is not implemented |
| T17 | Project authorization and cross-project retrieval isolation | 1B–2 | PARTIAL — composite FKs block mismatched Work/project links; authenticated read/search authorization is not implemented |
| T18 | GRANT/RLS/SECURITY DEFINER/search_path/bypass roles audited | 1A–2 | PARTIAL — prototype tests verify selected role/function properties, non-bypass object owner, forced RLS, no direct runtime table read, and append-only triggers; production project authorization and Supabase role audit are not implemented |
| T19 | Empty queue and source evidence create one canonical Work | 4 | NOT IMPLEMENTED |
| T20 | Discovery/decomposition stops at budgets and detects no progress | 4 | NOT IMPLEMENTED |
| T21 | External operation receipt loss reconciles without duplicate side effect | 1A–3 | PARTIAL — ExternalRef uniqueness/link/conflict rollback and unique OperationReceipt key/event ledger tested; external operation execution/receipt reconciliation not implemented |
| T22 | Adapter capabilities truthfully declare unsupported operations | 3 | NOT IMPLEMENTED |
| T23 | Parent completion aggregates required/optional children | 2B | PASS — active required children gate parent success, optional children do not; Stage 2B test passed on exact source-head Run #85 and post-merge Run #86. |
| T24 | Event/handover/ack replay is idempotent and stale versions rejected | 2–4 | PARTIAL — Work/evidence/receipt event append-only constraints tested; versioned transition and replay protocol not implemented |
| T25 | Derived memory/index rebuilds from source evidence | 4 | NOT IMPLEMENTED |
| T26 | Clean database migration chain has unique ordered versions | 1A–1B | PASS — both migrations applied to clean PostgreSQL 17.12 in CI |

## Stage 2A delivery status — merged and post-merge verified

- Implementation PR: [#38](https://github.com/Love-DC/recursive-engineering-platform/pull/38) — merged to `main` on 2026-11-26.
- Source candidate: HEAD `b1a3590e8792355d8330cf52e7e30decc700e9d3`, tree `b88e60222483e9396508c6b621d669198cf61074`.
- Merge commit: `4d3b52195e0fdcd0a20f96dedb18eb97f88a1131`.
- Pre-merge exact-head [Run #71](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/45794893367) passed both repository contract and PostgreSQL 17.12 integration/protocol jobs. The fourth-review final focused independent confirmation returned [PASS](https://github.com/Love-DC/recursive-engineering-platform/issues/37#issuecomment-7188779525).
- Post-merge exact-commit [Run #72](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/45798073719) passed:
  - Repository contract checks — job `139833783581`, success.
  - PostgreSQL 17 Work Registry integration tests — job `139833784253`, success; clean-database/concurrency and Stage 2A atomic coordination steps passed on PostgreSQL 17.12.
- Resource identity is permanent: DELETE is rejected; archival is the retirement path; UUID reuse is blocked by the regression test.
- T04 PASS and T05 PASS. T06 remains PARTIAL by design: the tested conservative whole-repository/branch-ref exclusion works; path-overlap/narrower write-set concurrency is not implemented.
- The Stage 2A prototype implementation is integrated and post-merge verified. This does not complete all remaining Architecture Snapshot Stage 1 guarantees or imply production deployment, authenticated project authorization, production writes, pilot, or legacy RAE cutover.
- Stage 2B is implemented and merged through [PR #43](https://github.com/Love-DC/recursive-engineering-platform/pull/43). The focused upgrade-remediation review returned [PASS](https://github.com/Love-DC/recursive-engineering-platform/pull/43#issuecomment-7191498260). Source-head Run #85 passed the populated migration-upgrade regression; post-merge [Run #86](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/45817835143) passed both repository contract and PostgreSQL 17.12 integration jobs on main merge commit `f222267e015bd3ab6058eb34464b370a5e405171`. T07/T08/T09/T23 are PASS for this disposable prototype scope; production project authorization, GitHub delivery/reconciliation, and session recovery are not thereby implemented.

## Stage 2B delivery evidence

- Implementation PR: [#43](https://github.com/Love-DC/recursive-engineering-platform/pull/43) — merged to `main`.
- Source HEAD: `94c4bfb15e34bd93a48c23ab4eeb007f7e40aa25`; source tree: `f3a91bc529efa7403be9ac1b3b57046aa5018fc1`.
- Exact source-head [Run #85](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/45813047865) passed repository contract checks and PostgreSQL 17.12 Work Registry integration tests. The run includes the populated 0001–0005→0006 migration-upgrade regression, T07/T08/T09/T23, and runtime grants/RLS checks.
- Independent focused migration-upgrade confirmation: [PASS](https://github.com/Love-DC/recursive-engineering-platform/pull/43#issuecomment-7191498260), tracked by [Issue #45](https://github.com/Love-DC/recursive-engineering-platform/issues/45), now closed.
- Merge commit: `f222267e015bd3ab6058eb34464b370a5e405171`; exact post-merge [Run #86](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/45817835143) passed both Repository contract checks and PostgreSQL 17.12 Work Registry integration tests. The latter executed the clean-database/concurrency suite, Stage 2A protocol tests, and Stage 2B dependency graph protocol tests.
- This is a disposable PostgreSQL prototype validation. It is not evidence of a production Supabase migration, production coordination write path, pilot, or legacy RAE cutover.

## Remaining acceptance gaps

- T06 remains PARTIAL: repository/ref-level exclusion is implemented; path-overlap and narrower write-set locking are not.
- T03/T12–T22/T24–T25 retain the PARTIAL or NOT IMPLEMENTED statuses above where external delivery reconciliation, authenticated production authorization, session recovery, discovery, and derived memory are not yet implemented.
- T16–T18 remain PARTIAL for their explicitly stated production/Owner-event and authenticated authorization limitations. Passing prototype RPC/RLS checks must not be represented as a production security audit.

Schema-only partial results remain distinct from end-to-end passes. Successful CI is evidence for the exact tested prototype behavior, not automatic Owner acceptance of deferred decisions or production readiness.
