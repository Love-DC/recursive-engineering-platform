# Acceptance Test Map — T01–T26

Authoritative behavioral definitions are in [Snapshot v2.0](https://github.com/Love-DC/recursive-engineering-platform/issues/1#issuecomment-7161657103). A PASS below means the listed slice was exercised against the exact PR candidate in ephemeral PostgreSQL CI; it does not imply a production deployment or a broader test not named.

| ID | Required proof | Planned stage | Status |
|---|---|---:|---|
| T01 | Concurrent canonical registration of identical work yields one canonical Work | 1–2 | PASS — prototype slice, PR #7 code SHA `148b173e97212b2216323a6107861459dc98d137` |
| T02 | Idempotency replay returns prior result; payload mismatch conflicts | 1–2 | PASS — prototype slice, PR #7 code SHA `148b173e97212b2216323a6107861459dc98d137` |
| T03 | Registration response loss and retry finds the same Work / ExternalRef | 1–2 | PARTIAL — Work retry across a fresh session passed; ExternalRef receipt-loss reconciliation is not implemented |
| T04 | Concurrent claim race yields one current execution | 2 | NOT IMPLEMENTED |
| T05 | Lease takeover advances execution/fence; stale state writes are rejected | 2 | NOT IMPLEMENTED |
| T06 | Conflicting writes to one physical resource are mutually excluded | 1–2 | NOT IMPLEMENTED |
| T07 | Concurrent dependency insertion cannot create a two-node cycle | 2 | NOT IMPLEMENTED |
| T08 | Bulk/multi-edge dependency mutation cannot introduce a larger cycle | 2 | NOT IMPLEMENTED |
| T09 | READY eligibility is invalidated/recomputed after dependency or authority changes | 2 | NOT IMPLEMENTED |
| T10 | Fresh session can recover current work/execution/delivery/lease state from durable records | 4 | NOT IMPLEMENTED |
| T11 | Recovery does not rely on the previous chat transcript | 4 | NOT IMPLEMENTED |
| T12 | Retry/takeover receives an independent delivery ref and old attempt cannot overwrite current delivery | 3 | NOT IMPLEMENTED |
| T13 | Stale external merge is detected, recorded, and triggers evidence invalidation/revalidation | 3 | NOT IMPLEMENTED |
| T14 | Same-principal process review is recorded as COMMENTED and is not misrepresented as native approval | 3 | NOT IMPLEMENTED |
| T15 | CI and post-merge validation are pinned to exact SHAs and remain distinct from deployment | 3 | NOT IMPLEMENTED |
| T16 | OwnerDecision requires direct provenance and version/scope; stale authorization is invalidated | 1–2 | NOT IMPLEMENTED |
| T17 | Cross-project reads/search and forged project/session labels cannot bypass authorization | 1–2 | NOT IMPLEMENTED |
| T18 | Database roles, GRANT/RLS, SECURITY DEFINER, search_path, EXECUTE, and bypass roles are audited | 1 | PARTIAL — prototype grants, function owner, search_path, forced RLS and direct-table denial checked; project authorization and production roles not audited |
| T19 | Empty queue + reproducible source issue leads to one atomically registered Work | 4 | NOT IMPLEMENTED |
| T20 | Discovery/decomposition stops at configured budgets and detects no progress | 4 | NOT IMPLEMENTED |
| T21 | Lost external operation receipt is recovered by reconciliation without duplicate external creation | 3 | PARTIAL — ExternalRef uniqueness, idempotent link and conflict rollback passed; external operation receipt reconciliation is not implemented |
| T22 | Adapter capabilities are declared honestly; unsupported operations are blocked, not claimed | 3 | NOT IMPLEMENTED |
| T23 | Parent completion correctly aggregates required/optional child outcomes | 2 | NOT IMPLEMENTED |
| T24 | Event, handover, and acknowledgement replay is idempotent and stale versions cannot transition state | 2–4 | NOT IMPLEMENTED |
| T25 | Derived memory/index can be rebuilt from original evidence without changing provenance or isolation | 4 | NOT IMPLEMENTED |
| T26 | Clean database migration validates unique versions and complete dependency order | 1 | PASS — single prototype migration applied to a clean PostgreSQL 17.12 database, PR #7 code SHA `148b173e97212b2216323a6107861459dc98d137` |

## Evidence

- PR: [#7](https://github.com/Love-DC/recursive-engineering-platform/pull/7)
- Code SHA tested: `148b173e97212b2216323a6107861459dc98d137`
- GitHub Actions: [run #45733155916](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/45733155916)

T01/T02/T03/T21/T26 are not all complete as end-to-end architecture guarantees. The labels above name precisely the tested prototype slices.
