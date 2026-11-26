# Contributing

## Before making changes

Read [AGENTS.md](AGENTS.md), the [architecture baseline](docs/ARCHITECTURE-BASELINE.md), the [decision register](docs/DECISION-REGISTER.md), and the [implementation roadmap](docs/IMPLEMENTATION-ROADMAP.md).

Check the linked GitHub issue and current PR state. Confirm that the task is in scope for the current stage.

## Branch and pull request rules

- Use a focused branch for one bounded work item.
- Do not make routine implementation commits directly to the default branch.
- Link the implementing PR to its issue.
- State the exact scope, changed files, tests run, CI result, known limitations, and follow-up work in the PR body.
- Keep PRs reviewable. Split unrelated concerns.
- Do not merge based solely on an AI assertion; preserve independent review evidence and exact-head-SHA verification.

## Database and migration rules

- No database changes are permitted during Stage 0.
- Later database work must target an explicitly approved isolated non-production database first.
- Every schema change must be represented by a versioned migration and tested against a clean database.
- Never rewrite an applied migration. Add a new migration.
- Check uniqueness of migration versions and dependency order in CI.
- Treat RLS, grants, role attributes, SECURITY DEFINER ownership, search_path, and EXECUTE privileges as security boundaries, not implementation details.
- Never place service-role credentials or database connection secrets in repository files or prompts.

## Evidence and status reporting

Distinguish these facts in every task and PR:
1. implemented;
2. locally or remotely tested;
3. independently reviewed;
4. merged;
5. deployed;
6. Owner-accepted.

A checkmark for one does not imply the others. Include the tested commit SHA and link to CI evidence where available.

## Documentation changes

- Keep decisions in docs/DECISION-REGISTER.md.
- Keep stage status and gates in docs/IMPLEMENTATION-ROADMAP.md.
- Keep the architecture baseline aligned with the accepted Snapshot v2.0.
- Mark recommendations as PROVISIONAL until their decision/evidence gate is satisfied.
- Do not copy large portions of legacy RAE implementation or governance without showing why the behavior remains necessary.
