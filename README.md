# Recursive Engineering Platform

A cross-project AI engineering coordination platform designed around a canonical Work Registry, durable evidence, transactional execution coordination, and replaceable ChatGPT sessions.

## Current status

- **Architecture authority:** Current Design Snapshot v2.0 was accepted by the Owner as the overall architecture baseline on 2026-11-26. The durable provenance record is the coordinator's [Issue #1 acceptance reconciliation comment](https://github.com/Love-DC/recursive-engineering-platform/issues/1#issuecomment-7180060029). It records the Owner's direct confirmation in the ChatGPT conversation; it does not claim that the earlier Snapshot comment was authored by the Owner. D4 remains PROVISIONAL; D9, D13, D15, and D16 remain UNVERIFIED / OPEN.
- **Implementation candidate:** Stage 0 foundation, Stage 1A registration, and Stage 1B coordination data structures are integrated in [PR #9](https://github.com/Love-DC/recursive-engineering-platform/pull/9). The earlier database and documentation findings have been remediated in the integrated candidate. The bounded final integration acceptance (Issue #32; [report](https://github.com/Love-DC/recursive-engineering-platform/pull/9#issuecomment-7182929171)) returned **CHANGES_REQUIRED solely for stale evidence pointers and tracking-status text**. This documentation follow-up synchronizes those records. PR #9 remains open and unmerged; green CI is not Owner acceptance.
- **Reviewed baseline at remediation start:** PR #9 HEAD was `5648ce0de9e3d9bd6460645819d75bffb35dd772`. This is a historical review target, not the final post-remediation candidate.
- **Historical CI evidence (not final candidate evidence):** Run #24 ([45734761932](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/45734761932)) passed for old SHA `d055fc1d6fbc7f83d83e35a43fefd6d89a90db43`. Run #27 ([45735069544](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/45735069544)) passed for review SHA `5648ce0de9e3d9bd6460645819d75bffb35dd772`. Neither is the final post-remediation candidate.
- **Final integrated candidate evidence:** PR #9 HEAD `4b241ff7a9ae76db7780133e23f6ee1371344bf5` (tree `fbad3219ae197246e588a2d571e511b48c3233c9`); [Actions Run #32](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/45756670349) passed Repository contract validation and PostgreSQL 17.12 integration against that exact HEAD. The PostgreSQL log confirms both sessions reached the database rendezvous before one canonical Work was committed. Run #31 is historical evidence for its earlier SHA. Final integrated acceptance requires only the documentation synchronization recorded above; no Owner acceptance or production readiness is implied.
- **Stage mapping:** Implementation Stages 1A/1B are preparatory slices of Architecture Snapshot Stage 1, not completion of it. Atomic claim/resource reservation, lease/fencing, stale-write rejection, and project authorization remain outstanding in implementation Stage 2.

## Start here

- [Implementation roadmap](https://github.com/Love-DC/recursive-engineering-platform/issues/2)
- [Stage 1A registration slice](https://github.com/Love-DC/recursive-engineering-platform/issues/6)
- [Stage 1B coordination data model](https://github.com/Love-DC/recursive-engineering-platform/issues/8)
- [Integrated Stage 0–1B PR](https://github.com/Love-DC/recursive-engineering-platform/pull/9)
- [Accepted architecture baseline](https://github.com/Love-DC/recursive-engineering-platform/issues/1#issuecomment-7161657103)
- [Owner acceptance provenance record](https://github.com/Love-DC/recursive-engineering-platform/issues/1#issuecomment-7180060029)
- [PR #9 documentation remediation](https://github.com/Love-DC/recursive-engineering-platform/issues/13)

## Prototype safety boundary

The SQL under `db/prototype` is exercised only against an ephemeral CI database. It is not a Supabase deployment migration, production schema, or production authorization interface. The registration prototype uses a trusted single-Owner test boundary; caller-supplied `project_id` is routing data, not proof of project authorization. The identity key is treated as already normalized by its caller; the database enforces exact equality for the supplied identity version.

The Stage 1B tables model project/resource grants, execution attempts, resource claims, dependency graph membership, OwnerDecision provenance, evidence, and external operation receipts. Their existence is not proof that atomic claim/fencing, graph mutation authorization, path-overlap exclusion, or external reconciliation is implemented.

No existing Supabase project or legacy RAE database has been changed. The old RAE system remains separate and unchanged.
