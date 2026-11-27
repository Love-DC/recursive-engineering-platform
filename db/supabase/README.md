# Non-production Supabase A0 installation

This is the supported installation path for the **trusted single-Owner A0 pilot only**. It is not a production deployment guide, production authorization boundary, or public write API.

## Preconditions

- Use a separate, empty, isolated Supabase project running PostgreSQL 17.
- Confirm the project ID and `ACTIVE_HEALTHY` status before applying DDL.
- Do not use the retired RAE Supabase project.
- Do not use this path on a populated database; populated-database upgrade/preflight safety is not established.
- The project must have Supabase's `pgcrypto` extension available in the `extensions` schema.

## Installation order

1. Apply [0000_supabase_compat.sql](0000_supabase_compat.sql) once as the Supabase `postgres` role. It creates the non-login `aep_owner` and `aep_runtime` roles if absent, grants the Supabase `postgres` role membership so it can explicitly `SET ROLE`, and installs a restricted `public.digest(bytea,text)` wrapper over `extensions.digest`.
2. Apply the existing prototype migrations in numeric order, without editing their contents:
   - `db/prototype/0001_work_registry.sql`
   - `db/prototype/0002_coordination_data_model.sql`
   - `db/prototype/0003_stage1_invariant_remediation.sql`
   - `db/prototype/0004_resource_claim_canonical_refs.sql`
   - `db/prototype/0005_stage2a_atomic_execution_coordination.sql`
   - `db/prototype/0006_stage2b_dependency_graph_protocol.sql`
   - `db/prototype/0007_stage3_github_delivery_reconciliation.sql`
   - `db/prototype/0008_stage3_external_receipt_reconciliation.sql`
   - `db/prototype/0009_stage4_session_recovery.sql`
   - `db/prototype/0010_stage4b_context_compiler.sql`
   - `db/prototype/0011_stage4c_derived_memory.sql`
   - `db/prototype/0012_stage4d_bounded_discovery.sql`
3. Only after installation, bootstrap the explicitly Owner-selected Project, Resource, OwnerDecision, ProjectResource grant, and repository adapter manifest. Do not place project-specific seed data in the shared schema migrations.

Use distinct migration history names, for example `aep_supabase_compat` followed by `aep_0001_work_registry` through `aep_0012_stage4d_bounded_discovery`.

## Runtime use

- `aep_owner` owns the AEP schema objects and is a non-login role.
- `aep_runtime` has schema usage and execute rights on the intended RPC surface, but no direct table SELECT rights.
- The bootstrap does **not** grant `aep_runtime` to Supabase `anon`, `authenticated`, or `service_role`; do not expose the prototype RPCs through the Data API.
- For a direct, explicitly scoped Supabase MCP operation, use a transaction-local role switch, for example:

```sql
BEGIN;
SET LOCAL ROLE aep_runtime;
SELECT aep.recover_session_state(
  '<project_id>',
  '<new_session_id>',
  20,
  20
);
COMMIT;
```

Use the privileged `postgres` connection only for installation and explicit Owner/bootstrap operations. Reset the transaction after each runtime operation; `SET LOCAL ROLE` does not persist beyond commit/rollback.

## Supabase-specific compatibility

- The hosted project already provides `pgcrypto` in `extensions`. The prototype calls `public.digest(bytea,text)`; the bootstrap creates a narrow wrapper and grants execution only to `aep_owner`. It does not move the extension into `public` and does not expose the wrapper to `PUBLIC`, `anon`, `authenticated`, or `service_role`.
- Supabase `postgres` is not a PostgreSQL superuser and must be granted membership in `aep_owner` before prototype migrations transfer schema/table/function ownership. The bootstrap performs this grant.
- The prototype migrations enable and force RLS on AEP tables. RLS is defense-in-depth here; the ProjectResource gate remains a trusted single-Owner prototype boundary, not authenticated multi-tenant authorization.

## Validation evidence and limits

This path was exercised on an isolated Supabase PostgreSQL 17.12 project on 2026-11-27:

- Compatibility bootstrap and all migrations 0001–0012 applied successfully.
- 31 AEP tables had RLS enabled and forced.
- `aep_runtime` had zero direct table SELECT privileges and execute access to 29 SECURITY DEFINER RPCs.
- The adapter manifest was registered; an AEP Work was registered, made READY, claimed, and recovered from a new session ID.
- Exact repository revision evidence was recorded and the Stage 4B Context Pack compiled successfully.
- A real low-risk Hexa Game Kernel documentation Work was delivered through PR, exact-head CI, process review, merge, and post-merge verification.

These results establish a working **non-production A0 pilot**, not production readiness. Authenticated caller-to-project binding, hostile multi-tenant isolation, production write-path authorization, independent-principal GitHub approval, deployment, and unattended LLM execution remain outside this path. The retired RAE Supabase project was not accessed or modified.
