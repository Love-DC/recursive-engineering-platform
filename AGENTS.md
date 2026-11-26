# Agent entry and operating contract

This file is the repository-local entry contract for every AI session working in this repository.

## Read order

1. Read this file.
2. Read [README.md](README.md) for current project status.
3. Read [the accepted architecture baseline](docs/ARCHITECTURE-BASELINE.md).
4. Read [the decision register](docs/DECISION-REGISTER.md) before changing scope, permissions, deployment, or rollout.
5. Read [the implementation roadmap](docs/IMPLEMENTATION-ROADMAP.md).
6. Recover the live task, PR, and CI state from [roadmap #2](https://github.com/Love-DC/recursive-engineering-platform/issues/2), [Stage 2A #10](https://github.com/Love-DC/recursive-engineering-platform/issues/10), [Stage 2B #11](https://github.com/Love-DC/recursive-engineering-platform/issues/11), [Stage 2A PR #38](https://github.com/Love-DC/recursive-engineering-platform/pull/38), and [Stage 2B PR #43](https://github.com/Love-DC/recursive-engineering-platform/pull/43).

The authoritative design source is [Architecture RFC #1, Current Design Snapshot v2.0](https://github.com/Love-DC/recursive-engineering-platform/issues/1#issuecomment-7161657103). Repository documents summarize it; they must not silently weaken or expand it.

## Mission

Build a general AI engineering coordination platform that can eventually become the single coordination and execution entry point for registered projects, replacing the legacy Recursive AI Engineering (RAE) system only after a verified, project-by-project cutover.

## Non-negotiable design constraints

- The canonical Work Registry is the only authority for platform work state. GitHub Issues, PRs, CI runs, and external objects are linked references or delivery surfaces, not competing work registries.
- Keep work identity, session provenance, and execution-attempt identity distinct: work_id, session_id, execution_id.
- A stable agent_id, permanent GPT identity, second human account, or always-on Worker is not an MVP prerequisite.
- PostgreSQL constraints and transactional protocols enforce exact uniqueness and atomic claims. A read-before-write query or LLM self-discipline is not a concurrency guarantee.
- Every execution attempt owns an isolated delivery ref. A database fence cannot revoke shared GitHub credentials or prevent every stale external side effect; reconciliation is required.
- Project authorization and physical resource identity are separate. Never use a session label, project_id supplied by a caller, or agent label as authorization proof.
- Review, merge, post-merge verification, deployment, and Owner acceptance are distinct lifecycle facts.
- Context and derived indexes must be project-authorized, source-pinned, and rebuildable from evidence.
- The initial operating mode is session-triggered. Do not claim background AI execution unless it is actually deployed and verified.

## Decision hygiene

Use the status vocabulary consistently:

- OWNER-APPROVED: explicit direct Owner decision for the stated scope/version.
- EVIDENCE-SUPPORTED: supported by a reproducible source or test; not necessarily an Owner choice.
- PROVISIONAL: recommended but not yet approved or validated.
- UNVERIFIED / OPEN: unresolved decision, missing evidence, or untested behavior.

An Owner-approved architecture baseline does not implicitly approve unresolved deployment, resource, pilot, or migration decisions. See docs/DECISION-REGISTER.md.

## Execution discipline

- Recover repository, issue, PR, CI, and database state before acting; never rely solely on an old chat transcript.
- Work from a dedicated branch and deliver changes through a PR.
- Keep task scope bounded. Do not silently absorb unrelated work.
- Preserve a clear single-writer boundary for files under active parallel work.
- Record exact commit SHA, CI run/result, review evidence, and external receipts.
- Test the behavior being claimed. Documentation or a successful file write is not proof that runtime behavior works.
- If verification fails, diagnose and repair or clearly record the blocker. Do not report unrun tests as passed.
- Never expose tokens, credentials, private source code, personal information, or private project data in this public repository.

## Current implementation boundary

- Stage 0, Stage 1A, and Stage 1B are merged to `main` through PR #9.
- Stage 2A claim, lease/takeover, fencing, resource reservation, and claim-time eligibility are merged through PR #38. Post-merge Run #72 passed; T04/T05 are PASS and T06 remains PARTIAL because exclusion is whole-repository/branch-ref scoped, not path-overlap scoped.
- Stage 2B dependency graph membership, authorization checks, atomic DAG mutation, cycle prevention, graph-wide serialization, READY invalidation, and required/optional parent-child completion are merged through PR #43. Independent focused remediation confirmation passed; exact source-head Run #85 and post-merge Run #86 passed. T07/T08/T09/T23 are PASS for the tested PostgreSQL 17.12 prototype scope.
- All database migrations under `db/prototype` run only against disposable GitHub Actions PostgreSQL 17.12. They are not Supabase deployment migrations or a production schema.

The current prototype still has explicit limits:
- the Stage 0/1 prototype must not mutate any existing Supabase project or database; the legacy RAE database remains untouched;
- no production coordination write path or production credentials;
- no pilot registration, task import, or legacy cutover;
- no always-on LLM runtime; operation remains A0 session-triggered;
- authenticated production project authorization and cross-project retrieval isolation are not complete;
- path-overlap/narrower write-set resource exclusion is not implemented (T06 PARTIAL);
- GitHub delivery adapter, per-execution delivery lifecycle, external-operation receipt reconciliation, and stale-side-effect reconciliation are not implemented (Stage 3);
- fresh-session recovery, Context Compiler, bounded discovery, and evidence-derived memory are not implemented (Stage 4).

Do not advance a stage merely because its documentation or tables exist. Use the acceptance criteria and exact-SHA evidence required by the roadmap. Deployment, pilot selection, and legacy cutover remain separately gated by the Decision Register.
