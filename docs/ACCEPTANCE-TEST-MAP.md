# Acceptance Test Map — T01–T26

Authoritative behavioral definitions are in [Snapshot v2.0](https://github.com/Love-DC/recursive-engineering-platform/issues/1#issuecomment-7161657103). PASS and PARTIAL distinguish a tested schema/prototype slice from the complete end-to-end architecture guarantee.

| ID | Required proof | Planned stage | Status |
|---|---|---:|---|
| T01 | Concurrent canonical registration yields one Work | 1A–2 | PASS — two independent PostgreSQL sessions are synchronized at a database advisory-lock rendezvous; the controller releases only after both are observed waiting, then one canonical Work is committed and linked. Exact integrated evidence: see the [canonical PR #9 exact-HEAD evidence record](https://github.com/Love-DC/recursive-engineering-platform/pull/9#issuecomment-7183275628), maintained in place as the candidate advances. |
| T02 | Idempotency replay and payload conflict | 1A–2 | PASS — replay returns same work_id; changed payload with same key conflicts |
| T03 | Lost registration response recovers without duplicate Work/ExternalRef | 1A–3 | PARTIAL — Work registration retry from a new session passed; external operation receipt reconciliation is not implemented |
| T04 | Concurrent claim race yields one current execution | 2A | PASS — the atomic claim RPC serializes two independent PostgreSQL connections; exactly one current Execution, Work pointer, and fence are committed. Run #54 is historical evidence for the pre-remediation candidate; the amended PR #38 requires fresh exact-HEAD CI and independent re-review. |
| T05 | Lease takeover advances fence and rejects stale writes | 2A | PASS — expired takeover creates a higher-fence attempt; the superseded attempt cannot renew or complete, while current renewal/completion succeeds. Lease-boundary and stale-attempt scenarios passed in historical Run #54; fresh exact-HEAD CI and independent re-review of amended PR #38 remain pending. |
| T06 | Same physical resource/ref/write set is mutually excluded across projects | 2A | PARTIAL — atomic claim reserves all requirements for the exact physical Resource/ref/conflict key across projects; supported GitHub repository refs use conservative whole-repository exclusion (`conflict_key='*'`). Path-overlap and narrower write-set concurrency remain unsupported. Historical Run #54 passed T06; amended-candidate exact-HEAD CI/re-review are pending. |
| T07 | Concurrent two-node dependency insertion cannot create a cycle | 2 | PARTIAL — typed depends_on relation and graph reference constraints tested; graph locking/atomic cycle prevention not implemented |
| T08 | Cross-project graph writes require authorized shared graph | 2 | PARTIAL — shared graph membership and non-null write grant reference are modeled; approved-grant checks and graph mutation authorization not implemented |
| T09 | READY invalidation after dependency/authority change | 2 | NOT IMPLEMENTED |
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
| T23 | Parent completion aggregates required/optional children | 2 | NOT IMPLEMENTED |
| T24 | Event/handover/ack replay is idempotent and stale versions rejected | 2–4 | PARTIAL — Work/evidence/receipt event append-only constraints tested; versioned transition and replay protocol not implemented |
| T25 | Derived memory/index rebuilds from source evidence | 4 | NOT IMPLEMENTED |
| T26 | Clean database migration chain has unique ordered versions | 1A–1B | PASS — both migrations applied to clean PostgreSQL 17.12 in CI |

## Stage 2A candidate status — not merged

- Implementation candidate: [PR #38](https://github.com/Love-DC/recursive-engineering-platform/pull/38), intentionally kept Open + Draft.
- Initial reviewed source: base `57cdbb1814fa967c6237e013d0e4415590fb1b0f`, HEAD `285dbc092744cb5d0f88ab391e25a84257298919`, tree `8e1593768c08a5b96901f6af88a4d9d1cf1946b0`.
- Initial exact-HEAD Run #54 passed both PostgreSQL 17.12 integration/protocol tests and repository contract checks.
- Independent review on that exact source returned `CHANGES_REQUIRED`: resource identity retargeting, missing claim-time dependency eligibility checks, and stale Stage 2A documentation.
- Remediation now adds immutable physical Resource identity, claim-time GitHub repository/ref revalidation, same-project active dependency prerequisite checks with shared/inactive graph fail-closed behavior, and adversarial tests. The amended HEAD still requires a fresh exact-HEAD CI run and another independent review. Run #54 is not evidence for the amended HEAD.
- PR #38 remains unmerged; Issue #10 remains open. No Supabase deployment or production write path is implied.

## Evidence history and current-candidate slot

- Integrated PR: [#9](https://github.com/Love-DC/recursive-engineering-platform/pull/9) — **merged to `main`**. Issue #32's CHANGES_REQUIRED finding was limited to stale duplicated evidence pointers and was resolved by PRs #33–#35; Issue #32 is closed completed. Post-merge Actions Run #36 passed on the merge commit. The exact commit/tree, CI evidence and scope are maintained in the [canonical evidence record](https://github.com/Love-DC/recursive-engineering-platform/pull/9#issuecomment-7183275628). This does not reopen accepted database or architecture reviews.
- Historical Run #24 ([45734761932](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/45734761932)): success for old SHA `d055fc1d6fbc7f83d83e35a43fefd6d89a90db43`.
- Historical Run #27 ([45735069544](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/45735069544)): success for reviewed SHA `5648ce0de9e3d9bd6460645819d75bffb35dd772`.
- These are historical run records, not evidence for the final post-remediation candidate.
- **Current integrated commit/tree and matching validation:** recorded in the [canonical PR #9 evidence record](https://github.com/Love-DC/recursive-engineering-platform/pull/9#issuecomment-7183275628). It distinguishes pre-merge candidate validation from post-merge main validation; earlier candidate runs remain historical evidence only.

Schema-only partial results are not end-to-end protocol passes. Successful CI is not acceptance. The complete architecture Stage 1 guarantees mapped to implementation Stage 2, and the later Stage 3–4 behavior, remain outstanding.
