# Work Registry and coordination-model prototype boundary

This directory contains a PostgreSQL experiment for Stage 1A/1B.

## What is implemented

- Canonical active Work identity uniqueness, separate from request idempotency.
- Transactional register-or-link function with same-key replay and payload mismatch conflict.
- ExternalRef exact uniqueness/linking.
- Append-only Work registration events.
- Physical Resource identity independent of Project namespace, with ProjectResource grant reference and mode constraints.
- Execution attempt identity, per-Work attempt/fence uniqueness, one-active-Execution index, and same-Work current-execution foreign key.
- ResourceClaim identity tied by composite foreign keys to the Work's project, the ProjectResource link, and the matching Execution/Work pair.
- Typed parent_child, depends_on, and possible_duplicate relation records.
- OwnerDecision status/provenance columns with a check preventing approved state unless direct-Owner provenance fields are present.
- Project-scoped Evidence foreign keys and append-only evidence / operation receipt event tables.
- Unique OperationReceipt key per provider.

## Verification

CI applies the ordered migrations to a clean PostgreSQL 17.12 database and exercises the prototype integration tests. PR [#9](https://github.com/Love-DC/recursive-engineering-platform/pull/9) remains open and unmerged; database and documentation remediation has been integrated, and refreshed independent final acceptance is pending.

Historical evidence (not final candidate evidence):
- Run #24 ([45734761932](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/45734761932)) passed for old SHA `d055fc1d6fbc7f83d83e35a43fefd6d89a90db43`.
- Run #27 ([45735069544](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/45735069544)) passed for review SHA `5648ce0de9e3d9bd6460645819d75bffb35dd772`.
- Final post-remediation candidate: PR #9 HEAD `de713207ebabcd20efe84df912f781985f6156fb`; [Actions run #31](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/45756309441) passed on that exact SHA. PostgreSQL 17.12 reports T01 rendezvous success. The run uses a clean disposable database; it does not test populated-database upgrades.

See [the test harness](../../scripts/test_postgres_prototype.py).

## What these tests do not prove

These are schema and prototype-slice tests, not complete protocol acceptance:

- No atomic claim RPC, lease renewal/takeover, monotonic fence transition, or stale execution write rejection.
- No atomic resource reservation API; ResourceClaim currently enforces an exact resource/ref/conflict_key uniqueness model. Path overlap and normalized write-set conflicts are not implemented.
- No atomic DAG insertion/cycle prevention. Shared graph write grants are represented by references, but status/scope validation and cross-project graph authorization are not implemented by a protocol function.
- No current-execution status/fence/lease transition validation beyond declared foreign keys, uniqueness, and checks.
- OwnerDecision provenance fields are a structural requirement, not cryptographic proof or a live check that an actual Owner message occurred.
- No external GitHub operation executor or intent/receipt/reconciliation state machine.
- No authenticated caller-to-project binding. A caller-supplied project_id is routing data, not authorization proof.
- No production Supabase/MCP role or RLS audit.

## Security and deployment limitations

This is a **trusted single-Owner test prototype**, not a production Supabase migration and not a hostile multi-tenant authorization design.

- Runtime access in Stage 1A is limited to the narrow register_work function; direct table grants are revoked.
- Tables are owned by a non-superuser, non-BYPASSRLS aep_owner role and use FORCE RLS with owner policies in the ephemeral database.
- Tests verify function ownership/search_path/EXECUTE and that the runtime role cannot directly read canonical tables.
- Role creation DDL assumes a disposable PostgreSQL administrator connection. It is not intended to run unchanged against an existing Supabase project.
- No existing Supabase project or legacy RAE database has been accessed or modified.

Do not deploy or expose these prototype functions as production write APIs. D4 remains PROVISIONAL; D9, D13, D15, and D16 remain UNVERIFIED / OPEN.
- This prototype has not been deployed to production Supabase. No legacy RAE project/database or pilot has been modified.
