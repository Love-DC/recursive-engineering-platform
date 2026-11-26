# Agent entry and operating contract

This file is the repository-local entry contract for every AI session working in this repository.

## Read order

1. Read this file.
2. Read [README.md](README.md) for current project status.
3. Read [the accepted architecture baseline](docs/ARCHITECTURE-BASELINE.md).
4. Read [the decision register](docs/DECISION-REGISTER.md) before changing scope, permissions, deployment, or rollout.
5. Read [the implementation roadmap](docs/IMPLEMENTATION-ROADMAP.md).
6. Recover the live task and PR state from [roadmap #2](https://github.com/Love-DC/recursive-engineering-platform/issues/2), [Stage 0 #3](https://github.com/Love-DC/recursive-engineering-platform/issues/3), [Stage 1A #6](https://github.com/Love-DC/recursive-engineering-platform/issues/6), [Stage 1B #8](https://github.com/Love-DC/recursive-engineering-platform/issues/8), and [the integrated delivery PR #9](https://github.com/Love-DC/recursive-engineering-platform/pull/9).

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

Stage 0 foundation and Stage 1A/1B schema prototype are combined in PR #9. The database is created only in disposable GitHub Actions PostgreSQL 17.12 jobs.

Stage 1 prototype limitations:
- no existing Supabase project or database is modified;
- no old RAE repository or database is modified;
- no production credentials or production write gateway;
- no pilot repository selection or legacy cutover;
- no always-on LLM runtime;
- no authenticated project authorization protocol;
- no atomic claim/lease/fence transition functions;
- no atomic dependency graph mutation or cycle-prevention protocol;
- no path-overlap resource locking or GitHub operation reconciliation implementation.

The registration function accepts project_id as routing input only. The Stage 1B schema's grant, execution, relation, evidence, and receipt records are data structures; they do not imply that the related enforcement protocols are complete.

Do not advance a stage merely because its documentation or tables exist. Use the acceptance criteria and evidence required by the roadmap.
