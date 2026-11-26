# Work Registry prototype boundary

This directory contains an executable PostgreSQL experiment for the first Stage 1 slice.

## What it proves

The CI test applies the migration to a clean PostgreSQL 17.12 database and checks:

- exact active identity uniqueness under two independent concurrent connections;
- request idempotency replay and same-key/different-payload rejection;
- retry after a simulated lost response from a different session;
- ExternalRef uniqueness, linking, and conflict rollback;
- migration filename version uniqueness/order and fresh database application;
- selected role/function/RLS properties of the prototype.

See [the integration test](../../scripts/test_postgres_prototype.py) and [the candidate CI run](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/45733155916).

## Security and deployment limitations

This is a **trusted single-Owner test prototype**, not a production Supabase migration and not a hostile multi-tenant authorization design.

- The `aep_runtime` role has no direct table privileges and can call only the narrow registration function.
- The function runs as the non-superuser, non-BYPASSRLS `aep_owner` role with a fixed search_path and forced RLS policies.
- However, the function currently accepts a caller-supplied `project_id` and checks only that the project is active. There is no project membership/grant table or authenticated caller-to-project binding. Therefore `project_id` is routing input, not authorization proof.
- Tests simulate the runtime role with `SET ROLE` from the ephemeral database owner. They do not prove authentication or authorization in a real Supabase/MCP environment.
- The role creation DDL assumes a disposable PostgreSQL administrator connection. It is not intended to run unchanged against an existing Supabase project.
- No existing Supabase project or legacy RAE database is accessed or mutated.

Do not deploy or expose this function as a production write API. Before production use, the platform must choose and test an actual caller authorization boundary, project grants, role ownership/EXECUTE grants, Data API exposure, RLS, and the production write path. D4 remains provisional; D9 and D15 remain open.

## Current scope

Implemented only: initial Project records, canonical Work registration, request idempotency, ExternalRef uniqueness, and append-only registration events.

Not implemented here: atomic claim, lease/fencing, dependency DAG, physical ResourceClaims, GitHub delivery/receipts/reconciliation, Context Compiler, memory, discovery, or production cutover.
