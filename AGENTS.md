# Agent entry and operating contract

This file is the repository-local entry contract for every AI session working in this repository.

## Read order

1. Read this file first.
2. Read [README.md](README.md) for the current verified delivery state.
3. Read and follow the [engineering standards](docs/ENGINEERING-STANDARDS.md).
4. Read [the accepted architecture baseline](docs/ARCHITECTURE-BASELINE.md).
5. Read [the decision register](docs/DECISION-REGISTER.md) before changing scope, permissions, deployment, or rollout.
6. Read [the implementation roadmap](docs/IMPLEMENTATION-ROADMAP.md) and [acceptance test map](docs/ACCEPTANCE-TEST-MAP.md).
7. Recover live work, PR, review, and CI state from [parent roadmap #2](https://github.com/Love-DC/recursive-engineering-platform/issues/2), its active linked Stage 4 work items ([umbrella #58](https://github.com/Love-DC/recursive-engineering-platform/issues/58), [T10/T11 #59](https://github.com/Love-DC/recursive-engineering-platform/issues/59), [Context Compiler #60](https://github.com/Love-DC/recursive-engineering-platform/issues/60), [T25 #61](https://github.com/Love-DC/recursive-engineering-platform/issues/61), [T19/T20 #62](https://github.com/Love-DC/recursive-engineering-platform/issues/62)), and the relevant linked PRs and exact-SHA Actions runs. Consult [Stage 3 implementation #48](https://github.com/Love-DC/recursive-engineering-platform/issues/48) and [Stage 3 documentation closeout #54](https://github.com/Love-DC/recursive-engineering-platform/issues/54) for historical delivery evidence; do not treat closed Stage 3 work as current work.

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

## Proportional engineering and autonomous execution

The binding repository-wide standard is [docs/ENGINEERING-STANDARDS.md](docs/ENGINEERING-STANDARDS.md). The primary principle is to reject over-defensive engineering: solve demonstrated problems with the smallest adequate change and scale controls to actual risk.

- A concern is not a blocker without a violated accepted requirement/current acceptance criterion and a concrete, evidence-backed failure or credible high-impact scenario.
- Classify gaps as current-scope blockers, future/pilot/production gates, accepted limitations, or optional improvements. Only current-scope blockers stop the current task.
- Do not import production-only gates into non-production work, demand zero risk, or add speculative services, identities, approval layers, abstractions, or test/review rounds.
- One complete exact-candidate review followed by focused re-review of concrete fixes is the normal path. Repeat passed checks only when the target or evidence changes, or a concrete defect justifies it.
- Continue routine work autonomously within the approved direction. Preserve accepted architecture/security invariants, explicit Owner gates, and project product boundaries.


## Current verified implementation

- **Stage 0 / Stage 1A / Stage 1B:** integrated through [PR #9](https://github.com/Love-DC/recursive-engineering-platform/pull/9), merged to main; the corresponding post-merge CI and evidence closeout are recorded in README and the roadmap.
- **Stage 2A:** [PR #38](https://github.com/Love-DC/recursive-engineering-platform/pull/38) is merged and post-merge verified. T04 and T05 are PASS; T06 remains PARTIAL because exclusion is whole-repository/branch-ref scoped, not path-overlap scoped.
- **Stage 2B:** [PR #43](https://github.com/Love-DC/recursive-engineering-platform/pull/43) is merged and post-merge verified for the tested PostgreSQL 17.12 prototype scope. T07/T08/T09/T23 are PASS for that scope.
- **Stage 3:** [implementation PR #49](https://github.com/Love-DC/recursive-engineering-platform/pull/49) was independently reviewed, merged at `ae3ff5ead7cf4fa3c0e8c47bb47b9beb24f9b18b`, and post-merge verified by [Run #104](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/45904771278). [Documentation closeout PR #55](https://github.com/Love-DC/recursive-engineering-platform/pull/55) was independently reviewed and merged at the current baseline `6047b2305e9c9fe173d2172e04331c01c8e3bda7`; [Run #106](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/45906829807) passed on that exact main commit. T12/T13/T14/T15/T21/T22 are PASS only for the tested disposable PostgreSQL 17.12 prototype scope. Stage 3 delivery/reconciliation must not be described as unimplemented.

The current repository prototype migration chain is 0001–0015. PR #101 added `0015_stage4a_recover_resource_claims.sql` and was merged at `0230528465cac25a8e86fd9ef7679cda6e979b56` from final candidate HEAD `6805fddaa4cdda15cc222761951bbdf6c7462a53`. The exact candidate passed [Run #282](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/46154977387), and the exact merge SHA passed post-merge [Run #283](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/46155210700); both passed Repository contract checks and the full PostgreSQL 17.12 Work Registry integration suite, including Stage 2A/2B/3, expired-claim, Stage 4A/4B/4C/4D and ResourceClaim recovery tests. This is disposable PostgreSQL prototype evidence only: the populated AEP Supabase Registry remains migrated through 0012; migrations 0013–0015 have not been applied there. No validated populated-database upgrade/preflight path exists, so do not describe migration 0015 or this recovery projection as deployed to the live Registry.

## Current prototype limits and Stage 4 scope

- The Stage 0/1 prototype must not mutate any existing Supabase project or database; the legacy RAE database remains untouched.
- **Stage 4A — fresh-session recovery (T10/T11):** implemented as a disposable PostgreSQL 17.12 prototype in [PR #65](https://github.com/Love-DC/recursive-engineering-platform/pull/65). After the initial independent review returned CHANGES_REQUIRED and its findings were remediated, the final candidate was independently reviewed and PR #65 was merged at `1ab52e5d46d9ceb4c3a3e580e538b2865b044095`. Post-merge [Run #45916067822](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/45916067822) passed on that exact merge SHA. The prototype covers the clean 0001–0009 migration chain, Stage 2A/2B/3 regressions, T10/T11, stale-session activity semantics, real `depends_on` graph edges with satisfied prerequisites, and all eleven related-collection truncation checks. The ProjectResource gate is not production authenticated session-to-project binding.
- **Stage 4B — implemented, independently reviewed, merged and post-merge verified as a disposable PostgreSQL 17.12 prototype:** PR #70 was squash-merged to `main` at `feac3eb3b740fbea86f984e4d5dafb85f0d10351`. Seventh-round independent documentation review returned PASS on candidate HEAD `65571a1cc6fe8e0f814170ec205ee956dba3d4da` ([Issue #77](https://github.com/Love-DC/recursive-engineering-platform/issues/77)); exact-head Run `#45946371750` passed. Exact-merge post-merge [Run #45948690687](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/45948690687) passed on the merge SHA, including Repository contract job `140339226637`, PostgreSQL integration job `140339226311`, and the Stage 4B Context Compiler/Context Pack test step. Four technical review rounds returned CHANGES_REQUIRED; the identified defects were remediated by bounded Evidence preselection, Resource→sorted Project advisory locking, MVCC-only authorization reads, transaction-wide sorted Work/Project dependency batch locking, and the shared gate rejecting non-READ COMMITTED transactions with SQLSTATE `25001` before locks or authorization reads. All three public Context RPCs share the gate; regressions establish REPEATABLE READ snapshots before source recording, compile and fetch, and exercise a READ COMMITTED control. Round five corrected historical/current SHA/CI provenance labels; round six corrected two stale lifecycle statements after the provenance correction passed. Review records: Issues #74–#77. This remains a disposable prototype only: ProjectResource is a trusted-single-Owner scope gate, not authenticated caller/session identity. It is not deployed to production Supabase and does not establish production authorization or production readiness. T25 is PASS for the tested disposable prototype through Stage 4C;
- **Stage 4C — evidence-derived memory (implemented, independently reviewed, merged and post-merge verified for the disposable PostgreSQL 17.12 prototype):** [PR #81](https://github.com/Love-DC/recursive-engineering-platform/pull/81) adds migration `0011_stage4c_derived_memory.sql`, deterministic/idempotent Evidence-derived projections, immutable provenance, source invalidation and Context Pack schema v2 consumption. Reviewed candidate HEAD `4fcb5bc5feea0142fb4a4b5bf28bc99a1bc34b76`; exact-head [Run #199](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/45956571676) passed repository-contract and PostgreSQL 17.12 integration jobs, including T25. Independent review returned PASS ([review record](https://github.com/Love-DC/recursive-engineering-platform/pull/81#pullrequestreview-6084735569)). PR #81 was squash-merged at `a303618092ba0c762c8f850603b9c57328b00035`; exact-merge [Run #200](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/45958199427) passed both jobs and the Stage 4C regression. T25 is PASS for this tested prototype scope. ProjectResource remains a trusted-single-Owner scope gate, not authenticated production caller/session identity; the SQL extractor is deterministic and `model_version` is metadata, not evidence of an LLM run. No production Supabase or legacy RAE database was changed or deployed.
- **Stage 4D — bounded empty-queue discovery (T19/T20 implemented, coordinator-reviewed, merged and post-merge verified for the disposable PostgreSQL 17.12 prototype):** [PR #84](https://github.com/Love-DC/recursive-engineering-platform/pull/84) adds migration `0012_stage4d_bounded_discovery.sql` and reuses the sole `aep.register_work` registry. Candidate HEAD `647c56da4e763e3174a977c7e24bef1ea066acc7` passed exact-head [Run #45967867851](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/45967867851); coordinator review returned PASS ([record](https://github.com/Love-DC/recursive-engineering-platform/pull/84#pullrequestreview-6085558387)); PR #84 squash-merged at `78f942d9c60fe28b20757aeb71644f350d0ec15a`; exact-merge [Run #45968284136](https://github.com/Love-DC/recursive-engineering-platform/actions/runs/45968284136) passed both Repository contract and PostgreSQL integration jobs. T19/T20 are PASS for this tested prototype: concurrent discovery converges on one canonical Work; possible-duplicate links do not merge Work; tool/time/token/cost/depth/fan-out/no-progress budgets stop with durable cursors; fresh sessions resume safely and late reads are fenced; Owner-retained candidates remain `approval_required`. A0 remains active-session-triggered: no background worker or LLM runtime was added. The review was performed by the same connected GitHub principal, not a separate authenticated approver. ProjectResource remains a trusted-single-Owner prototype gate; session ID is provenance, and token/cost accounting is caller-reported. No production Supabase or legacy RAE database was changed or deployed.
- T06 remains PARTIAL: exclusion is conservative at whole-repository/branch-ref granularity; path-overlap/narrower write-set exclusion is not implemented.
- T16 remains PARTIAL for actual Owner event verification/supersede enforcement. T17/T18 remain PARTIAL for authenticated production project authorization, cross-project retrieval isolation, and a complete production role/security audit. T24 remains PARTIAL for versioned transition/replay protocol.
- The connected GitHub session surface does not provide an independently authenticated native-approval principal. Process Review COMMENTED is not GitHub Native Approval APPROVED. Deployment is unsupported.
- No production coordination write path, production authorization boundary, production pilot, task import, or legacy RAE cutover is established. The two selected pilot Projects/Resources are active only in the isolated non-production AEP Supabase project; the legacy RAE Supabase project and unrelated existing Supabase projects remain untouched.
- There is no always-on LLM runtime. Continue A0 active-session-triggered recovery, discovery, and execution only; GitHub Actions is CI/validation, not a ChatGPT session trigger or background model consumer.
- The Context Compiler is a logical capability by default, not a separately deployed service. Authorization must precede retrieval; Context Packs and derived memory are disposable, source-pinned projections, never authorities.
- Keep D4 PROVISIONAL and D9/D15/D16 UNVERIFIED / OPEN. D13 is OWNER-APPROVED: `Love-DC/Hexa-Game-Kernel` was selected as the first heterogeneous pilot on 2026-11-27 and its AEP Project plus GitHub Resource are active with a read_write grant in the isolated non-production Supabase instance. `Love-DC/Unbroken-Frontier` was separately Owner-selected as the second pilot and its Project and GitHub Resource are also active with a read_write grant. Project registration is complete; Stage 5 pilot acceptance remains in progress and must be supported by exact-scope core-suite and adapter evidence. Do not infer production readiness, production authorization, approval-policy changes, mobile device compatibility, or legacy cutover from registration or green CI.

Do not advance a stage merely because its documentation, schema, or tables exist. Use the acceptance criteria and exact-SHA evidence required by the roadmap. Deployment, pilot selection, and legacy cutover remain separately gated by the Decision Register.
