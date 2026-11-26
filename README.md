# Recursive Engineering Platform

A cross-project AI engineering coordination platform designed around a canonical Work Registry, durable evidence, transactional execution coordination, and replaceable ChatGPT sessions.

## Current status

- Architecture baseline: v2.0 accepted by the Owner on 2026-11-26.
- Implementation: Stage 0 foundation and the first Stage 1 Work Registry slice are in PR #7.
- Candidate PR head: `148b173e97212b2216323a6107861459dc98d137`.
- GitHub Actions run #9 passed on the PR candidate: repository contract checks and PostgreSQL 17.12 integration tests.
- PR #7 is not merged and has no independent review yet.
- Runtime scope currently covers prototype registration only. Atomic claim, lease/fencing, DAG, GitHub delivery, discovery, and production integration are not implemented.

## Start here

- [Implementation roadmap](https://github.com/Love-DC/recursive-engineering-platform/issues/2)
- [Stage 1 Work Registry implementation](https://github.com/Love-DC/recursive-engineering-platform/issues/6)
- [Integrated Stage 0–1 PR](https://github.com/Love-DC/recursive-engineering-platform/pull/7)
- [Accepted architecture baseline and evidence](https://github.com/Love-DC/recursive-engineering-platform/issues/1#issuecomment-7161657103)

## Prototype safety boundary

The PostgreSQL schema under `db/prototype` is exercised only against an ephemeral CI database. It is not a Supabase deployment migration, production schema, or multi-tenant authorization interface. The prototype uses a trusted single-Owner test boundary; a caller-supplied `project_id` is routing data, not proof of project authorization. No existing Supabase project or legacy RAE database has been changed.

The old Recursive AI Engineering (RAE) system remains separate and unchanged.
