# Architecture Baseline — AEP v2.0

**Status:** Owner-accepted architecture baseline, 2026-11-26. This approval establishes the overall architecture direction; it does not approve every open deployment or rollout choice in the decision register.

**Primary source:** [Architecture RFC #1 — Current Design Snapshot v2.0](https://github.com/Love-DC/recursive-engineering-platform/issues/1#issuecomment-7161657103)

**Implementation state:** Not implemented by virtue of this document. Runtime schema, transaction protocols, concurrency behavior, security isolation, and adapters require code and executable verification.

## 1. Product objective

Build a general AI engineering platform that can eventually replace the legacy RAE system as the single engineering coordination and execution entry point for registered projects.

The platform must support heterogeneous projects while keeping project code, governance, evidence, private knowledge, and product decisions isolated unless an explicit grant allows sharing.

## 2. Minimal physical deployment

The recommended minimum physical shape is intentionally small, subject to the still-provisional D4 consistency-domain decision:

- one coordinating PostgreSQL consistency domain (PROVISIONAL until D4 is resolved);
- one canonical Work Registry;
- replaceable, active ChatGPT Web sessions;
- thin GitHub and GitHub Actions adapters;
- project-local governance and capability declarations;
- a logical Context Compiler, not a separately deployed service by default.

Supabase is a candidate PostgreSQL hosting form, not an automatic production-write approval. Stage 1 must first validate the design in an isolated non-production database.

Logical responsibilities such as Project Registry, Resource Registry, Execution Coordinator, Evidence Ledger, Discovery, Review, and Context Compiler do not require one service or database each.

## 3. Work Registry is the sole work authority

All work sources must register or link to a canonical work record before becoming executable: Owner goals, discoveries, GitHub Issues, PRs, CI failures, reviews, child work, and repair work.

GitHub Issue numbers, PR numbers, CI run IDs, and Supabase row IDs are not interchangeable with the canonical platform work_id. They are linked through typed external references.

### Exact identity, idempotency, and semantic similarity

These are separate mechanisms:

1. Canonical exact identity is enforced by a database unique constraint and an atomic register-or-link operation.
2. Request idempotency records operation scope, key, payload hash, and result. Same key/same payload replays the result; same key/different payload conflicts.
3. Canonical uniqueness must still hold when two sessions use different idempotency keys.
4. Semantic similarity creates a possible-duplicate relationship or review candidate. It must not become a blocking LLM admission gate or automatically merge records.
5. Each external object has a separate unique ExternalRef identity.
6. Terminal history is retained; re-opened or recurring work follows explicit lifecycle rules rather than having history overwritten.

## 4. Identity model

| Identity | Meaning | Not equivalent to |
|---|---|---|
| work_id | Canonical identity of a unit of work | GitHub Issue ID or task title |
| session_id | Provenance of one ChatGPT conversation | Authentication identity or proof of liveness |
| execution_id | One attempt to perform a work item | Session or logical worker |
| actor_key / agent_label | Optional role/provenance label | Authorization or independent principal |
| GitHub/Supabase principal | Actual external authenticated principal | A different session_id or actor label |

A stable agent_id / Agent Registry is an optional future capability. It is not an MVP prerequisite. A session may execute multiple work items; a work item may have multiple sequential attempts; every takeover creates a new execution_id.

## 5. Project authorization and physical resources

Project namespace governs authorization, context, and work identity. A canonical physical Resource identity (provider, host, stable repository/resource ID) governs conflicts over the real underlying resource.

The same physical repository cannot be written concurrently through two project aliases when the refs or write sets conflict. MVP may use whole-repository/ref exclusion; narrower path-level concurrency requires separate safety evidence.

Caller-supplied project IDs, session IDs, labels, or prompt text are not authorization proof. Database grants and RLS must be audited together. SECURITY DEFINER functions, ownership, search_path, EXECUTE grants, and bypass-capable roles are part of the security boundary.

## 6. Dependencies and readiness

Two relationships must remain distinct:

- parent_child expresses decomposition and aggregation; it does not imply execution order.
- depends_on expresses execution prerequisites and must form a DAG.

By default, dependencies stay inside one project dependency namespace. Cross-project dependencies require explicit sharing grants and a common dependency_graph_id with graph-level concurrency coordination.

Every edge mutation must use one enforced transactional path with a common graph lock or SERIALIZABLE transaction plus bounded retries. READY is a recomputable eligibility projection, not cached truth. Claim must re-check dependencies and all current eligibility conditions.

## 7. Atomic claim, lease, and fencing

A claim transaction must re-check work status, dependencies, OwnerDecision scope/version, project state, authorization, and physical resource conflicts. It then atomically creates an execution attempt, advances a monotonic fence, sets the current execution and lease, and reserves the conflicting resource set.

Takeover creates a new execution_id and higher fence. State writes from an old attempt must be rejected using work_id, execution_id, fence, and expected version.

Lease expiry means only that takeover may be considered. It does not prove a ChatGPT window has closed and cannot revoke shared GitHub or MCP credentials. Continuous heartbeat during model reasoning is not an MVP requirement.

## 8. GitHub delivery and external side effects

Every execution attempt receives its own branch/ref and PR identity, for example:

~~~text
work/<work_id>/execution/<execution_id>
~~~

Do not reuse task-level delivery branches across retries.

PostgreSQL and GitHub do not share an ACID transaction. External operations therefore use:

~~~text
operation intent → external operation → receipt → reconciliation
~~~

A database fence cannot universally stop a stale session from completing a GitHub side effect with shared credentials. The platform must detect and record stale/out-of-band changes, invalidate affected base SHA, CI, review, and Context Pack evidence, then revalidate or repair.

PR HEAD SHA, CI evidence, process review, merge SHA, post-merge validation, deployment, and Owner acceptance are separate facts.

## 9. Review model under one principal

Where multiple ChatGPT sessions share one GitHub principal, an independently operating session can inspect the exact target SHA and submit a COMMENTED review plus a platform-level decision.

This is a process review record. It is not a GitHub native APPROVE and must never be represented as satisfying native required approval. If a repository's branch rules require native approval, the adapter must report blocked/unsupported until a separate Owner decision resolves that requirement.

## 10. Evidence, memory, and Context Compiler

Maintain a one-way evidence relationship:

~~~text
source evidence → append-only evidence ledger → rebuildable derived memory → disposable Context Pack
~~~

Authorization filtering occurs before retrieval. A Context Pack binds the authorized project, work, dependencies, pinned repository/tree SHA, relevant decision versions, provenance, and token budget.

Code search/index artifacts are derived and rebuildable. Any index is pinned to stable repository identity, commit/tree SHA, and indexer/config version. Select tools by demonstrated capability; do not deploy an always-on index service by default.

## 11. Autonomy levels

- **A0 — initial mode:** active-session-triggered discovery and execution. Empty queue prompts the active session to scan evidence, apply exact identity and duplicate screening, register work atomically, and perform bounded decomposition.
- **A1 — future:** event/schedule intake. Requires actual deployed triggers and observable execution.
- **A2 — future:** unattended LLM execution. Requires a real model runtime, credentials, workers, monitoring, budgets, and recovery.

Do not claim A1 or A2 from the presence of GitHub Actions or a database alone.

Discovery and decomposition must have bounded depth, fan-out, tool/time/token/cost budgets, and no-progress detection.

## 12. Legacy RAE migration

The old RAE repository and database remain separate and unchanged while the new platform is built and validated.

Migration is selective and read-only first: inventory sources, record exact source identities and hashes, map only necessary work and external references, shadow-compare, freeze writes for one selected project, then cut over only after explicit Owner approval and rollback evidence.

Do not wholesale-copy the old database, dual-write the same work to two registries, or silently repair anomalous legacy records during import. The old system becomes read-only only after each authorized project cutover.

## 13. Acceptance

The architecture is accompanied by tests T01–T26 in [the acceptance map](ACCEPTANCE-TEST-MAP.md). The complete source and definitions remain in the Snapshot v2.0 source issue comment.

No runtime behavior is considered accepted until the corresponding executable test or explicitly defined external acceptance check has passed against the exact candidate commit and environment.
