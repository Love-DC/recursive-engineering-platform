# Work Registry, coordination model, and Stage 2A protocol prototype

This directory contains a PostgreSQL experiment for the Stage 1A/1B data model and the Stage 2A transactional execution protocol.

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

The initial Stage 2A candidate at HEAD `285dbc092744cb5d0f88ab391e25a84257298919` passed [Run #54](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/45781729538), then returned **CHANGES_REQUIRED** for protocol and documentation findings. The first remediation code candidate at HEAD `cd107fa62377a46846731d1c6eba3ba0909d2374` / tree `30b4fcfb54be3472ec77e59af20b7cb0351a8bbc` passed [Run #61](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/45785205746). The second independent review on HEAD `0ec2285108b6b116101afcda987da678d1de25f6` / tree `09eac0ecbe0441a39b06e4afd99f528e4d54af2d` returned **CHANGES_REQUIRED** for two P2 findings: Resource DELETE + UUID reuse with an old resource-scoped OwnerDecision, and stale status documentation. The permanent Resource identity fix rejects all Resource DELETE operations; its regression test removes ProjectResource, attempts Resource deletion, and attempts to insert a different physical repository with the same UUID. The third independent review locked base `57cdbb1814fa967c6237e013d0e4415590fb1b0f`, protocol-code HEAD `8d5225f9b691ca6eb866b951d67217cd627538ee`, and tree `a6ec86ef30d15f3bfabe0f91a27a2009c7945d75`. Exact-head [Run #67](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/45789379092) passed both Repository contract checks (job `139804250113`) and PostgreSQL 17.12 Work Registry integration/Stage 2A protocol tests (job `139804249611`). The review confirmed the Resource UUID lifecycle correction and found no additional reproducible Stage 2A protocol defect, but returned **CHANGES_REQUIRED** for one P2 documentation/evidence finding: the four status documents omitted Run #67 and did not clearly state the privileged database-administrator boundary. This documentation closeout records the exact evidence and boundary; a new exact-head CI run for this documentation-only candidate and another independent review are required before acceptance.

The Stage 1A/1B integrated baseline is merged through [PR #9](https://github.com/Love-DC/recursive-engineering-platform/pull/9). Its post-merge evidence, including disposable PostgreSQL 17.12 scope, remains in the [canonical evidence record](https://github.com/Love-DC/recursive-engineering-platform/pull/9#issuecomment-7183275628).

## What these tests do not prove

- Stage 2B atomic dependency-edge mutation, DAG cycle prevention, graph-wide concurrency, shared/cross-project dependency authorization, or READY invalidation after dependency/authority changes.
- Path-overlap or normalized write-set conflict semantics; current resource exclusion is conservative exact whole-repository/branch-ref exclusion.
- Populated-database migration upgrade/preflight safety.
- A production Supabase deployment, production write API, authenticated caller-to-project binding, or hostile multi-tenant authorization.
- GitHub adapter execution, external operation receipts/reconciliation, stale external side-effect prevention, or legacy RAE cutover.
- An always-on LLM runtime or proof that an expired ChatGPT session has stopped acting.

## Security and deployment limitations

This is a **trusted single-Owner test prototype**, not a production Supabase migration or production authorization interface.

- Disposable GitHub Actions PostgreSQL 17.12 only. No existing Supabase project or legacy RAE database has been accessed or modified.
- The permanent Resource DELETE trigger protects against ordinary runtime-role operations, not a privileged PostgreSQL administrator: a superuser or sufficiently privileged schema/table owner can deliberately disable triggers or alter the schema. The trusted single-Owner prototype does not defend against a hostile database administrator.
- Role creation assumes a disposable PostgreSQL administrator connection. It is not intended to run unchanged against an existing Supabase project.
- The database fence does not revoke shared GitHub/MCP credentials or prevent every stale external side effect.
- Do not deploy or expose these prototype functions as production write APIs. D4 remains PROVISIONAL; D9, D13, D15, and D16 remain UNVERIFIED / OPEN.
