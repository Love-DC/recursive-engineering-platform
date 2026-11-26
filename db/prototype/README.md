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

The initial Stage 2A candidate at HEAD `285dbc092744cb5d0f88ab391e25a84257298919` passed [Run #54](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/45781729538), then returned **CHANGES_REQUIRED** for protocol and documentation findings. The first remediation code candidate at HEAD `cd107fa62377a46846731d1c6eba3ba0909d2374` / tree `30b4fcfb54be3472ec77e59af20b7cb0351a8bbc` passed [Run #61](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/45785205746). The second review identified the Resource DELETE/UUID-reuse P2; the fix permanently rejects Resource DELETE and the regression prevents reuse after ProjectResource unlink. The third review confirmed that fix and found no further reproducible protocol defect; its protocol-code HEAD `8d5225f9b691ca6eb866b951d0e4415590fb1b0f` / tree `a6ec86ef30d15f3bfabe0f91a27a2009c7945d75` passed [Run #67](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/45789379092) (jobs `139804250113` and `139804249611`, both success). The fourth review validated docs-closeout HEAD `1d23644fd160fa17802afacba59be91f496999c6` / tree `c513fa9858b2e9bc55918ccbd8597a846d73b6cd` with [Run #69](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/45791612367): Repository contract job `139811798601` and PostgreSQL 17.12 job `139811798988` both succeeded. It found these documents omitted Run #69 and still said exact-head CI was pending; this follow-up corrects that P2 evidence/status issue. The exact-head run for this follow-up commit is recorded in PR #38 / Issue #37 rather than embedded in the same commit, because the run is created only after commit creation and self-embedding would create an endless commit/CI loop.


**Current-tip evidence convention:** this file records completed runs for identified prior candidate SHAs. The exact-head CI result for the current tip is maintained in the live [PR #38](https://github.com/Love-DC/recursive-engineering-platform/pull/38) and [Issue #37](https://github.com/Love-DC/recursive-engineering-platform/issues/37) evidence record. A commit cannot record its own CI run because the run is created only after the commit; requiring it to do so would create an endless commit/run loop.

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
