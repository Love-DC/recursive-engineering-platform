# Recursive Engineering Platform

A cross-project AI engineering coordination platform designed around a canonical Work Registry, durable evidence, transactional execution coordination, and replaceable ChatGPT sessions.

## Current status

- Architecture baseline: v2.0 accepted by the Owner on 2026-11-26.
- Stage 0 foundation, Stage 1A canonical Work registration, and Stage 1B minimum coordination data model are implemented in candidate [PR #9](https://github.com/Love-DC/recursive-engineering-platform/pull/9).
- Candidate head: `d055fc1d6fbc7f83d83e35a43fefd6d89a90db43`.
- [GitHub Actions run #24](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/45734761932) passed against that exact SHA using an ephemeral PostgreSQL 17.12 database.
- PR #9 is open and unmerged. Independent review and merge are pending.
- Atomic claim/lease/fencing behavior, dependency DAG concurrency, production authorization, GitHub delivery/reconciliation, session recovery, discovery, and production integration are not implemented.

## Start here

- [Implementation roadmap](https://github.com/Love-DC/recursive-engineering-platform/issues/2)
- [Stage 1A registration slice](https://github.com/Love-DC/recursive-engineering-platform/issues/6)
- [Stage 1B coordination data model](https://github.com/Love-DC/recursive-engineering-platform/issues/8)
- [Integrated Stage 0–1B PR](https://github.com/Love-DC/recursive-engineering-platform/pull/9)
- [Accepted architecture baseline](https://github.com/Love-DC/recursive-engineering-platform/issues/1#issuecomment-7161657103)

## Prototype safety boundary

The SQL under `db/prototype` is exercised only against an ephemeral CI database. It is not a Supabase deployment migration, production schema, or production authorization interface. The registration prototype uses a trusted single-Owner test boundary; caller-supplied `project_id` is routing data, not proof of project authorization. The identity key is treated as already normalized by its caller; the database enforces exact equality for the supplied identity version.

The Stage 1B tables model project/resource grants, execution attempts, resource claims, dependency graph membership, OwnerDecision provenance, evidence, and external operation receipts. Their existence is not proof that atomic claim/fencing, graph mutation authorization, path-overlap exclusion, or external reconciliation is implemented.

No existing Supabase project or legacy RAE database has been changed. The old RAE system remains separate and unchanged.
