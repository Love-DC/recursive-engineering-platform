# Legacy RAE Portfolio Inventory and Migration Preparation

- Snapshot date: 2026-11-26
- Tracking issue: [AEP #39](https://github.com/Love-DC/recursive-engineering-platform/issues/39)
- Authority: read-only inventory; no project cutover or task replay is authorized.
- Evidence source: legacy RAE Supabase registry/task metadata queried read-only; GitHub repository metadata, governance files, PRs, reviews, commits and available commit-status contexts.
- AEP baseline used for this report: `57cdbb1814fa967c6237e013d0e4415590fb1b0f`.

## 1. Executive status

AEP is not yet ready to take over project execution. Its Stage 0–1B Work Registry foundation is merged and post-merge CI was recorded as passing, but atomic execution coordination and dependency/DAG safety are still being implemented.

The workstreams therefore remain:

1. **AEP platform work:** continue Stage 2A, then Stage 2B, followed by Stage 3 delivery/reconciliation and Stage 4 session recovery/discovery.
2. **Legacy portfolio inventory:** proceed in parallel as a read-only evidence task.
3. **Project code migration:** do not start until the core AEP acceptance suite is proven. Begin only with a single Owner-selected pilot, then migrate project-by-project.

This document does not authorize a pilot, production write path, legacy data import, dual-write, or cutover.

## 2. AEP readiness baseline

AEP's roadmap tracker [Issue #2](https://github.com/Love-DC/recursive-engineering-platform/issues/2) records:

| Stage | State at snapshot |
|---|---|
| Stage 0 — repository foundation | Merged and post-merge CI verified |
| Stage 1A — canonical Work registration | Merged and tested |
| Stage 1B — coordination data model | Merged and schema-tested |
| Stage 2A — atomic claim, leases, takeover, fencing and resource reservation | Active implementation: [Issue #10](https://github.com/Love-DC/recursive-engineering-platform/issues/10); independent review work package [#37](https://github.com/Love-DC/recursive-engineering-platform/issues/37) |
| Stage 2B — atomic dependency graph mutation and READY eligibility | [Issue #11](https://github.com/Love-DC/recursive-engineering-platform/issues/11), intentionally sequenced after Stage 2A |
| Stage 3 — GitHub delivery adapter and external reconciliation | Not started |
| Stage 4 — session recovery, context compiler and bounded discovery | Not started |
| Stage 5 — heterogeneous pilot | Blocked on core acceptance and Owner decision D13 |
| Stage 6 — project-by-project legacy cutover | Blocked on explicit cutover decision and rollback evidence |

The roadmap status update records Stage 0–1B on main at `57cdbb1814fa967c6237e013d0e4415590fb1b0f`, with post-merge Actions Run #38 passing both Repository contract validation and PostgreSQL 17 Work Registry integration.

Current AEP boundaries remain: disposable PostgreSQL CI only; no legacy RAE database or project migration; no production write path; no background Worker runtime. D4 is provisional; D9, D13, D15 and D16 remain open. D13 is the pilot-selection gate, D15 the production write-entry gate, and D16 the native GitHub approval policy gate.

## 3. Registered project inventory

The legacy RAE registry returned four registered projects. The old registry's `active` status is historical routing metadata; it is not continuing authorization after the Owner retired RAE.

| Legacy project | Repository | Current main SHA | Repository state and governing boundary |
|---|---|---|---|
| RAE | [Love-DC/recursive-ai-engineering](https://github.com/Love-DC/recursive-ai-engineering) | `81d6095606ed534e1e4c4e111505bc113cb76750` | Retired platform repository; historical task/PR state only. Do not resume RAE execution. |
| Colony Sim | [Love-DC/colony-sim](https://github.com/Love-DC/colony-sim) | `94874f478b3b4098100dff1f7bb4e711499e0fe4` | Active game project with strict Owner control over gameplay, balance, world rules, UX and player experience. Engineering work must preserve approved design. |
| Lambent | [Love-DC/Lambent](https://github.com/Love-DC/Lambent) | `53140e6aa12da083c45321cd84024dec92deb76f` | Intentionally reset to an empty initial state. Do not reconstruct former code, assets or product direction from memory. Project autonomy is paused. |
| Hexa Game Kernel | [Love-DC/Hexa-Game-Kernel](https://github.com/Love-DC/Hexa-Game-Kernel) | `0a055090a6ba7f4b0ac8cdb289da463ff38389aa` | Controlled engineering scope is P4 Save & Compatibility only. P5/P6/P7 and production operation are not authorized by the P4 task card. |

All SHAs above are the latest default-branch commits observed during this snapshot. Every future task must refresh the relevant branch SHA and governance manifest before acting.

### 3.1 Repository-local governance

**Colony Sim**
- Manifest: `rae-governance.json`; entrypoints include `AGENTS.md`, `docs/ai/AI_START_HERE.md`, and `docs/ai/WEB_GITHUB_WORKFLOW.md`; required policy includes `AUTONOMY_POLICY.md`, `DEVELOPMENT_PROTOCOL.md`, `ISSUE_BASED_WORKER_DISPATCH.md`, `AI_PR_REVIEW_AND_MERGE.md`, and `DECISIONS.md`.
- Engineering autonomy is bounded to manually started active ChatGPT sessions and approved engineering work. The repository reserves all gameplay and player-experience decisions to the Owner.
- Validation uses the external public runner in `Love-DC/ai-project-governance`. The documented exact-head trigger accepts a PR number, full SHA and suite selector.
- Search snapshot: at least 40 open Issues were returned in the first 40-item page and 27 open PRs were returned. Open Issues #425 and #426 concern engineering self-check/acceptance and stale collaboration-state cleanup; they are not migration authorization.

**Lambent**
- Manifest requires only `AGENTS.md` and `README.md`.
- The repository explicitly says product/source implementation is empty by design and future project scope must come from the Owner.
- External runner checks only the manifest and required governance files. The current main SHA reports `external-ci/lambent-governance: success` at [run 45377658975](https://github.com/Love-DC/ai-project-governance/actions/runs/45377658975).
- No open Issues or PRs were returned in the inventory query. The legacy project autonomy setting is paused.
- This is suitable for a future registration/governance smoke test only, not a meaningful code implementation pilot without a new Owner objective.

**Hexa Game Kernel**
- Manifest and `AGENTS.md` preserve the P4 Save & Compatibility boundary and the distinction between local acceptance, GitHub Actions, Gitee Go, and cross-platform evidence.
- `planning/49-P4-阶段本地最终验收报告.md` records a local P4 acceptance pass (Windows, pinned Rust toolchain, format/Clippy/tests and demo). It explicitly says Gitee Go/Linux was not run and does not claim full v1.0 Save or production readiness.
- The controlled P4 task card `planning/22-P4-存档兼容与重放任务卡草案.md` was moved into controlled status on 2026-11-25. It does not authorize P5/P6/P7, runtime-permission expansion, or production operations.
- No open Issues or PRs were returned in the inventory query. No commit status contexts were returned for current main by the available combined-status query; that is an evidence gap, not proof that CI never ran.

**Legacy RAE**
- The current main manifest still declares a large legacy set of required/entrypoint governance files. The proposed slim startup change is on PR #82, not main.
- Six open Issues were returned (#81, #5, #9, #4, #3, #10) and two open PRs (#82, #26).
- PR #82 remains open at head `6a03adbcc63f9aa5c986ec5e3569032c820c10e3`. Four recorded workflows passed on that exact head (repository governance, shell static, PostgreSQL lifecycle, Initiative lifecycle), but its Coordinator review returned **CHANGES_REQUIRED** for missing conditional-reference regression coverage and ambiguous cross-repository SHA wording. It must not be resumed now that RAE is retired.
- PR #26 remains open/unmerged; no review submission was returned. Leave it historical and untouched.
- The current main SHA returned no status contexts from the available combined-status query. Do not infer current-main CI success from older runs.

## 4. Legacy task and delivery reconciliation

The legacy database contains non-terminal task and execution records. They are not safe inputs for replay. Migration must reconstruct current work from repository truth and preserve legacy references as historical provenance.

### 4.1 Submitted tasks outside RAE

| Project | Legacy submitted records | GitHub evidence | Migration classification |
|---|---:|---|---|
| Colony Sim | 3 | All three point to [PR #432](https://github.com/Love-DC/colony-sim/pull/432), actually merged 2026-11-24 at `c224b92224a7a8a2a7c147006d143698a9e192fd`. Exact head `83ae650f69895d897bf25b600ae46420a9c6fd6a` has `external-ci/ai-context: success` at [run 45458027363](https://github.com/Love-DC/ai-project-governance/actions/runs/45458027363); Godot was skipped because this was documentation-only. | Legacy task statuses are stale relative to PR merge. Preserve as history; do not replay or infer task acceptance from merge alone. |
| Hexa Game Kernel | 1 | Points to [PR #5](https://github.com/Love-DC/Hexa-Game-Kernel/pull/5), merged at `a76c335f632d49978a67b13a41dc7afb3d70ebaf`. Exact PR head `6f6040b945710294fda93b46c9e18b3af262ecfb`; stored Actions run [45486328667](https://github.com/Love-DC/Hexa-Game-Kernel/actions/runs/45486328667) passed Ubuntu 24.04 and Windows 2025 format, Clippy and workspace tests. | Legacy task status is stale relative to PR merge and stored exact-head CI. Preserve as history; do not re-execute. |
| Lambent | 0 | No pending/running/submitted task row was returned. | No active legacy work identified in this snapshot. Do not create work to populate the intentionally empty repository. |

### 4.2 RAE's 19 submitted task records

The 19 rows partition by their recorded GitHub destination:

**12 rows reference merged RAE PRs**
- PR #77 — integrity-monitor coverage for JSON task prerequisites.
- PR #76 — Problem Inbox authorization documentation.
- PR #64 — Owner-scoped project activation config and its follow-up.
- PR #59 — two task rows for bounded active-session autonomy and cap/pause regression fixes.
- PR #45 — Problem Inbox review remediation.
- PR #43 — submitted-delivery reassignment regression.
- PR #27 — four task rows covering resource-inventory refresh, read-only batch authorization, cleanup guard regression and task-reference/pagination validation.
- PR #15 — concurrent claim test across Worker routing.

These are merged delivery artifacts, not 12 accepted task records. Their original task-level acceptance states remain historical and are not rewritten here.

**5 rows reference closed, unmerged RAE PRs**
- PR #28 — two task rows (recursive engineering tree and multi-session contract reconciliation).
- PR #34 — two task rows (stacked documentation/Initiative lifecycle reconciliation).
- PR #32 — stacked-branch PostgreSQL task-lifecycle CI coverage.

These PRs must not be reopened or replayed as part of migration. Their branches/diffs may be retained as historical evidence only.

**2 rows reference a separate public governance repository**
- Both point to [Love-DC/ai-project-governance PR #14](https://github.com/Love-DC/ai-project-governance/pull/14), which is **closed, not merged**.
- This repository is not one of the four registered projects. Treat the references as external historical dependencies, not AEP project work.

### 4.3 RAE's one running task

The legacy row `[RAE] Reinitialize a lean execution core and reduce mandatory startup overhead` points to Issue #81 and PR #82.

- Its task lease expired at **2026-11-25 18:30 UTC**.
- Its current Execution row still reports `running`; last heartbeat was **2026-11-25 18:20 UTC**, with no finish timestamp.
- PR #82 remains open on exact head `6a03adbcc63f9aa5c986ec5e3569032c820c10e3`; Coordinator review is **CHANGES_REQUIRED**.
- Four exact-head workflows passed, but they do not override the blocking review findings.

Classification: stale/expired execution with inconsistent non-terminal task/execution state. Because RAE is retired, do not renew, reclaim, complete, fail, or otherwise mutate this execution.

The legacy execution summary also contains non-terminal `running` and `submitted` execution rows across registered projects. AEP must not copy these states into a new active queue.

## 5. Risk-ranked pilot candidates (recommendation only)

No pilot is selected by this report. D13 remains an Owner decision.

| Candidate | Assessment | Recommendation |
|---|---|---|
| Hexa Game Kernel | Strongest current candidate for a bounded engineering pilot: narrow controlled P4 scope, explicit tests and acceptance documents, recent merged GitHub Actions evidence. Current-main status evidence must be refreshed; P4 scope must remain unchanged. | **Preferred candidate for D13 consideration**, once AEP core acceptance passes and current-head validation is refreshed. |
| Lambent | Lowest-risk governance/registration smoke test, but codebase is deliberately empty and autonomy paused. No meaningful engineering task exists without a new objective. | Use only for non-destructive registration/context smoke testing if an explicit objective and pilot authority are later granted. |
| Colony Sim | Highest complexity: at least 40 open Issues in first page, 27 open PRs, extensive dependencies and strict game-design/UX Owner gates. Current main checks are green, but backlog and product boundary raise migration risk. | Defer until AEP has demonstrated delivery/reconciliation on a smaller project. Preserve every existing approved gameplay contract. |
| Legacy RAE | It is the system being retired, not a product pilot. Contains stale task/execution state and unresolved/closed PR history. | Historical-only. Do not migrate RAE as an active target project. |

## 6. Recommended migration sequence

1. **Finish and accept AEP core:** Stage 2A and 2B, then Stage 3 GitHub delivery/receipt/reconciliation and Stage 4 session recovery/discovery. Require exact-head tests, adversarial concurrency/failure tests, independent review, merge and post-merge evidence.
2. **Resolve pilot gates:** Owner resolves D13; resolve D15 before production write-path use and D16 where native GitHub required approval is relevant. Do not infer these decisions from architecture approval or a green CI run.
3. **Prepare one pilot in shadow/read-only mode:** pin its current repository SHA; validate the repository governance manifest; map open/terminal Issues and PRs, dependencies, branch ownership, exact CI and project-local decision gates. Compare AEP's proposed Work registry against live GitHub truth without writes to the legacy pool.
4. **Cut over one project only:** freeze legacy writes for that selected project, import only explicitly mapped active work as new AEP Work records with legacy links retained as provenance, verify no duplicates and no lost PR/branch ownership, then enable AEP as the sole write/claim entry.
5. **Prove rollback before expanding:** record how to stop AEP claims, return that one project to its prior authorized operating mode, and preserve all AEP/legacy evidence. Expand to the next project only after the first project's full lifecycle has passed.

Do not dual-write task state between RAE and AEP. Do not wholesale-copy the old Supabase schema or historical task/execution tables into AEP. Legacy task statuses are not authoritative for new Work state.

## 7. Explicit non-actions and unresolved evidence

- No legacy Supabase task, execution, project or Worker row was changed.
- No legacy GitHub repository, Issue, PR, branch, workflow or deployment was modified.
- No task was imported into AEP and no pilot was registered.
- No legacy status was rewritten as accepted merely because a linked PR is merged.
- Current-main status contexts were not returned for RAE and Hexa by the available combined-status query; refresh through their applicable CI systems before pilot activation.
- This report is a dated inventory snapshot. Refresh all repository SHAs, governance manifests, project policies, PRs and CI immediately before any real pilot or cutover.

## 8. Acceptance checklist

- [x] All four registered projects accounted for.
- [x] Current default-branch SHAs and major governance boundaries recorded.
- [x] Available current-main CI status evidence recorded without overstating missing statuses.
- [x] All 3 Colony Sim submitted task rows reconciled to PR #432.
- [x] The Hexa submitted task row reconciled to PR #5.
- [x] All 19 RAE submitted task rows grouped by exact GitHub PR destination and current PR disposition.
- [x] The RAE running task's expired lease, still-running execution pointer and CHANGES_REQUIRED PR #82 review recorded.
- [x] Pilot candidates risk-ranked without selecting a pilot or resolving D13.
- [x] No legacy task replay, database mutation, project change or cutover performed.
- [ ] Independent AEP repository review of this inventory report.
- [ ] Future pilot selection and cutover authorization remain separate Owner decisions.
