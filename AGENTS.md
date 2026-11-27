# Agent entry and operating contract

This file is the repository-local entry contract for every AI session working in this repository.

## Read order

1. Read this file first.
2. Read [README.md](README.md) for the current verified delivery state.
3. Read [the accepted architecture baseline](docs/ARCHITECTURE-BASELINE.md).
4. Read [the decision register](docs/DECISION-REGISTER.md) before changing scope, permissions, deployment, or rollout.
5. Read [the implementation roadmap](docs/IMPLEMENTATION-ROADMAP.md) and [acceptance test map](docs/ACCEPTANCE-TEST-MAP.md).
6. Recover live work, PR, review, and CI state from [parent roadmap #2](https://github.com/Love-DC/recursive-engineering-platform/issues/2), its active linked Stage 4 work items ([umbrella #58](https://github.com/Love-DC/recursive-engineering-platform/issues/58), [T10/T11 #59](https://github.com/Love-DC/recursive-engineering-platform/issues/59), [Context Compiler #60](https://github.com/Love-DC/recursive-engineering-platform/issues/60), [T25 #61](https://github.com/Love-DC/recursive-engineering-platform/issues/61), [T19/T20 #62](https://github.com/Love-DC/recursive-engineering-platform/issues/62)), and the relevant linked PRs and exact-SHA Actions runs. Consult [Stage 3 implementation #48](https://github.com/Love-DC/recursive-engineering-platform/issues/48) and [Stage 3 documentation closeout #54](https://github.com/Love-DC/recursive-engineering-platform/issues/54) for historical delivery evidence; do not treat closed Stage 3 work as current work.

The authoritative design source is [Architecture RFC #1, Current Design Snapshot v2.0](https://github.com/Love-DC/recursive-engineering-platform/issues/1#issuecomment-7161657103). Its Owner-acceptance provenance and preserved open decisions are recorded in [Issue #1 comment #7180060029](https://github.com/Love-DC/recursive-engineering-platform/issues/1#issuecomment-7180060029). Repository documents summarize the baseline; they must not silently weaken or expand it.

`AGENTS.md` is the actual session entry file in the current repository tree. Do not assume that a separate `docs/SESSION-START.md` exists unless it is added and verified in the repository.

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

An Owner-approved architecture baseline does not implicitly approve unresolved deployment, resource, pilot, or migration choices. See docs/DECISION-REGISTER.md.

## Execution discipline

- Recover repository, issue, PR, CI, and database state before acting; never rely solely on an old chat transcript.
- Work from a dedicated branch and deliver changes through a PR.
- Keep task scope bounded. Do not silently absorb unrelated work.
- Preserve a clear single-writer boundary for files under active parallel work.
- Record exact commit SHA, CI run/result, review evidence, and external receipts.
- Test the behavior being claimed. Documentation or a successful file write is not proof that runtime behavior works.
- If verification fails, diagnose and repair or clearly record the blocker. Do not report unrun tests as passed.
- Never expose tokens, credentials, private source code, personal information, or private project data in this public repository.

## Current verified implementation

- **Stage 0 / Stage 1A / Stage 1B:** integrated through [PR #9](https://github.com/Love-DC/recursive-engineering-platform/pull/9), merged to main; the corresponding post-merge CI and evidence closeout are recorded in README and the roadmap.
- **Stage 2A:** [PR #38](https://github.com/Love-DC/recursive-engineering-platform/pull/38) is merged and post-merge verified. T04 and T05 are PASS; T06 remains PARTIAL because exclusion is whole-repository/branch-ref scoped, not path-overlap scoped.
- **Stage 2B:** [PR #43](https://github.com/Love-DC/recursive-engineering-platform/pull/43) is merged and post-merge verified for the tested PostgreSQL 17.12 prototype scope. T07/T08/T09/T23 are PASS for that scope.
- **Stage 3:** [implementation PR #49](https://github.com/Love-DC/recursive-engineering-platform/pull/49) was independently reviewed, merged at `ae3ff5ead7cf4fa3c0e8c47bb47b9beb24f9b18b`, and post-merge verified by [Run #104](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/45904771278). [Documentation closeout PR #55](https://github.com/Love-DC/recursive-engineering-platform/pull/55) was independently reviewed and merged at the current baseline `6047b2305e9c9fe173d2172e04331c01c8e3bda7`; [Run #106](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/45906829807) passed on that exact main commit. T12/T13/T14/T15/T21/T22 are PASS only for the tested disposable PostgreSQL 17.12 prototype scope. Stage 3 delivery/reconciliation must not be described as unimplemented.

Main currently contains migrations 0001–0010, merged and verified as the Stage 4B prototype. Stage 4C migration `0011_stage4c_derived_memory.sql` is a PR #81 candidate and is exercised only against disposable GitHub Actions PostgreSQL 17.12. These files are not production Supabase deployment migrations or a production schema.

## Current prototype limits and Stage 4 scope

- The Stage 0/1 prototype must not mutate any existing Supabase project or database; the legacy RAE database remains untouched.
- **Stage 4A — fresh-session recovery (T10/T11):** implemented as a disposable PostgreSQL 17.12 prototype in [PR #65](https://github.com/Love-DC/recursive-engineering-platform/pull/65). After the initial independent review returned CHANGES_REQUIRED and its findings were remediated, the final candidate was independently reviewed and PR #65 was merged at `1ab52e5d46d9ceb4c3a3e580e538b2865b044095`. Post-merge [Run #45916067822](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/45916067822) passed on that exact merge SHA. The prototype covers the clean 0001–0009 migration chain, Stage 2A/2B/3 regressions, T10/T11, stale-session activity semantics, real `depends_on` graph edges with satisfied prerequisites, and all eleven related-collection truncation checks. The ProjectResource gate is not production authenticated session-to-project binding.
- **Stage 4C — implementation and exact-head CI verified; independent review pending:** [PR #81](https://github.com/Love-DC/recursive-engineering-platform/pull/81) adds migration `0011`, deterministic Evidence-derived projections, source/version-bound rebuilding, Evidence/repository/dependency/resource source invalidation, and Context Pack schema v2 integration. Work state, OwnerDecision and ProjectResource authorization remain separate authorities; every memory read still passes the existing authorization gate. Exact-head [Run #198](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/45956194641) passed on `674e0065dd1f6d8ee883ca702257c5e07caf50b4`, including clean migrations 0001–0011 and T25. Independent review, merge and post-merge verification remain pending.
- **Stage 4B — implemented, independently reviewed, merged and post-merge verified as a disposable PostgreSQL 17.12 prototype:** PR #70 was squash-merged to `main` at `feac3eb3b740fbea86f984e4d5dafb85f0d10351`. Seventh-round independent documentation review returned PASS on candidate HEAD `65571a1cc6fe8e0f814170ec205ee956dba3d4da` ([Issue #77](https://github.com/Love-DC/recursive-engineering-platform/issues/77)); exact-head Run `#45946371750` passed. Exact-merge post-merge [Run #45948690687](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/45948690687) passed on the merge SHA, including Repository contract job `140339226637`, PostgreSQL integration job `140339226311`, and the Stage 4B Context Compiler/Context Pack test step. Four technical review rounds returned CHANGES_REQUIRED; the identified defects were remediated by bounded Evidence preselection, Resource→sorted Project advisory locking, MVCC-only authorization reads, transaction-wide sorted Work/Project dependency batch locking, and the shared gate rejecting non-READ COMMITTED transactions with SQLSTATE `25001` before locks or authorization reads. All three public Context RPCs share the gate; regressions establish REPEATABLE READ snapshots before source recording, compile and fetch, and exercise a READ COMMITTED control. Round five corrected historical/current SHA/CI provenance labels; round six corrected two stale lifecycle statements after the provenance correction passed. Review records: Issues #74–#77. This remains a disposable prototype only: ProjectResource is a trusted-single-Owner scope gate, not authenticated caller/session identity. It is not deployed to production Supabase and does not establish production authorization or production readiness. T25 [PR #81](https://github.com/Love-DC/recursive-engineering-platform/pull/81) passed exact-head [Run #198](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/45956194641) on `674e0065dd1f6d8ee883ca702257c5e07caf50b4`; independent review is pending before merge and acceptance. T19/T20 bounded discovery remains outstanding.
- T06 remains PARTIAL: exclusion is conservative at whole-repository/branch-ref granularity; path-overlap/narrower write-set exclusion is not implemented.
- T16 remains PARTIAL for actual Owner event verification/supersede enforcement. T17/T18 remain PARTIAL for authenticated production project authorization, cross-project retrieval isolation, and a complete production role/security audit. T24 remains PARTIAL for versioned transition/replay protocol.
- The connected GitHub session surface does not provide an independently authenticated native-approval principal. Process Review COMMENTED is not GitHub Native Approval APPROVED. Deployment is unsupported.
- No production coordination write path, production authorization boundary, pilot, task import, or legacy RAE cutover is established. No existing Supabase project or legacy RAE database may be changed as part of prototype work.
- There is no always-on LLM runtime. Continue A0 active-session-triggered recovery, discovery, and execution only; GitHub Actions is CI/validation, not a ChatGPT session trigger or background model consumer.
- The Context Compiler is a logical capability by default, not a separately deployed service. Authorization must precede retrieval; Context Packs and derived memory are disposable, source-pinned projections, never authorities.
- Keep D4 PROVISIONAL and D9/D13/D15/D16 UNVERIFIED / OPEN. Do not infer pilot, production, approval-policy, or cutover authorization from merged code or green CI.

Do not advance a stage merely because its documentation, schema, or tables exist. Use the acceptance criteria and exact-SHA evidence required by the roadmap. Deployment, pilot selection, and legacy cutover remain separately gated by the Decision Register.
