# Acceptance Test Map — T01–T26

This is a planning map. A row marked NOT IMPLEMENTED is not a passing test. Authoritative behavioral definitions are in [Snapshot v2.0](https://github.com/Love-DC/recursive-engineering-platform/issues/1#issuecomment-7161657103).

| ID | Required proof | Planned stage | Status |
|---|---|---:|---|
| T01 | Concurrent canonical registration of identical work yields one canonical Work | 1–2 | NOT IMPLEMENTED |
| T02 | Idempotency replay returns prior result; payload mismatch conflicts | 1–2 | NOT IMPLEMENTED |
| T03 | Registration response loss and retry finds the same Work / ExternalRef | 1–2 | NOT IMPLEMENTED |
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
| T18 | Database roles, GRANT/RLS, SECURITY DEFINER, search_path, EXECUTE, and bypass roles are audited | 1 | NOT IMPLEMENTED |
| T19 | Empty queue + reproducible source issue leads to one atomically registered Work | 4 | NOT IMPLEMENTED |
| T20 | Discovery/decomposition stops at configured budgets and detects no progress | 4 | NOT IMPLEMENTED |
| T21 | Lost external operation receipt is recovered by reconciliation without duplicate external creation | 3 | NOT IMPLEMENTED |
| T22 | Adapter capabilities are declared honestly; unsupported operations are blocked, not claimed | 3 | NOT IMPLEMENTED |
| T23 | Parent completion correctly aggregates required/optional child outcomes | 2 | NOT IMPLEMENTED |
| T24 | Event, handover, and acknowledgement replay is idempotent and stale versions cannot transition state | 2–4 | NOT IMPLEMENTED |
| T25 | Derived memory/index can be rebuilt from original evidence without changing provenance or isolation | 4 | NOT IMPLEMENTED |
| T26 | Clean database migration validates unique versions and complete dependency order | 1 | NOT IMPLEMENTED |

## Current Stage 0 checks

Stage 0 does not claim any T01–T26 runtime test as complete. It establishes the documentation and CI mechanisms needed to implement and report them without losing their definitions.
