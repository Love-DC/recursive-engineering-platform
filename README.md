# Recursive Engineering Platform

A cross-project AI engineering coordination platform designed around a canonical Work Registry, durable evidence, transactional execution coordination, and replaceable ChatGPT sessions.

## Current status

- **Architecture authority:** Current Design Snapshot v2.0 was accepted by the Owner as the overall architecture baseline on 2026-11-26. The durable provenance record is the coordinator's [Issue #1 acceptance reconciliation comment](https://github.com/Love-DC/recursive-engineering-platform/issues/1#issuecomment-7180060029). It records the Owner's direct confirmation in the ChatGPT conversation; it does not claim that the earlier Snapshot comment was authored by the Owner. D4 remains PROVISIONAL; D9, D13, D15, and D16 remain UNVERIFIED / OPEN.
- **Implementation delivered:** Stage 0 foundation, Stage 1A registration, and Stage 1B coordination data structures were integrated through [PR #9](https://github.com/Love-DC/recursive-engineering-platform/pull/9), now merged to `main`. The bounded final integration acceptance (Issue #32; [report](https://github.com/Love-DC/recursive-engineering-platform/pull/9#issuecomment-7182929171)) returned CHANGES_REQUIRED solely for duplicated, stale evidence pointers; that finding was resolved by documentation PRs #33–#35 and Issue #32 is closed completed. Post-merge Run #36 passed on the PR #9 merge commit. The [canonical evidence record](https://github.com/Love-DC/recursive-engineering-platform/pull/9#issuecomment-7183275628) tracks the exact main merge and current CI. CI success is not Owner acceptance of deferred gates.
- **Reviewed baseline at remediation start:** PR #9 HEAD was `5648ce0de9e3d9bd6460645819d75bffb35dd772`. This is a historical review target, not the final post-remediation candidate.
- **Historical CI evidence (not final candidate evidence):** Run #24 ([45734761932](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/45734761932)) passed for old SHA `d055fc1d6fbc7f83d83e35a43fefd6d89a90db43`. Run #27 ([45735069544](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/45735069544)) passed for review SHA `5648ce0de9e3d9bd6460645819d75bffb35dd772`. Neither is the final post-remediation candidate.
- **Canonical delivery evidence:** the PR #9 candidate commit/tree, main merge commit, exact-head/pre-merge and post-merge Actions runs, job results, T01 evidence, and disposable-database scope are maintained in the [canonical evidence record](https://github.com/Love-DC/recursive-engineering-platform/pull/9#issuecomment-7183275628). The prototype CI scope does not prove populated-database migration upgrades; no production deployment or deferred-gate acceptance is implied.
- **Stage 2A candidate:** [PR #38](https://github.com/Love-DC/recursive-engineering-platform/pull/38) contains the prototype atomic claim, resource reservation, lease/fencing, immutable Resource identity, and claim-time dependency eligibility implementation. Independent review returned `CHANGES_REQUIRED`; all three findings have been addressed in the candidate code/docs. The remediation code candidate at HEAD `cd107fa62377a46846731d1c6eba3ba0909d2374` / tree `30b4fcfb54be3472ec77e59af20b7cb0351a8bbc` passed [Run #61](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/45785205746). This documentation synchronization follows that verified code candidate; fresh exact-head CI and independent re-review are still pending. PR #38 remains Draft and unmerged.
- **Stage mapping:** Implementation Stages 1A/1B are preparatory slices of Architecture Snapshot Stage 1, not completion of it. Stage 2A is a candidate implementation slice; Stage 2B dependency mutation/DAG safety and later authorization guarantees remain outstanding.

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
