# Engineering Standards

## Primary principle: reject over-defensive engineering

AEP exists to help projects discover, execute, verify, and deliver real engineering work. The goal is not to eliminate every imaginable risk, maximize process, or make every prototype production-grade.

Prefer the smallest adequate solution that satisfies the accepted architecture and the task's actual requirements. Accept reasonable, bounded engineering risk. Do not turn hypothetical future scenarios, style preferences, or optional hardening into blockers.

## Evidence before blockers

Before blocking work or requesting more controls, state:

1. The specific accepted requirement, invariant, or current task acceptance criterion at stake.
2. The concrete failure or threat scenario and the affected behavior.
3. Reproducible evidence, or a technically specific explanation of why the high-impact scenario is credible.

If these cannot be stated, the concern is not a current blocker. Record it as an optional improvement only when it has practical value.

Classify findings accurately:

- **Current-scope blocker:** prevents the requested work from safely or correctly meeting its current acceptance criteria.
- **Future/pilot/production gate:** matters only before the named higher-risk use; it does not block an appropriately bounded prototype or non-production task.
- **Accepted limitation:** known, explicit, and compatible with the current use.
- **Optional improvement:** useful but not required for correctness, security, or current acceptance.

Only current-scope blockers stop the current task. Keep future gates visible without importing them into today's scope.

## Controls proportional to risk

Scale design, tests, review, and approval to the change's actual impact:

- Low-risk documentation, wording, and routine maintenance need focused checks. Do not attach production security audits or repeated technical reviews to them.
- Ordinary implementation changes need the relevant automated tests and one complete review of the exact candidate.
- Changes involving authorization, sensitive data, destructive migrations, production writes, or other high-impact boundaries justify stronger targeted verification and the approvals already required by the accepted baseline.

Do not add a service, registry, identity, approval layer, abstraction, test layer, report, or process step for a hypothetical need. Add one only when a demonstrated requirement or failure needs it and the benefit outweighs the complexity.

## Review and verification

- Normally perform one complete review against the exact implementation candidate, then focused re-review of concrete fixes.
- Repeat a full review only after material code/architecture changes or a newly demonstrated defect that changes the review surface.
- Do not re-review already-passed areas because of documentation wording, provenance updates, or unrelated changes.
- Run the tests relevant to the changed behavior. Re-run passed checks only when their target changed, evidence was invalidated, or a concrete reason makes the prior result unreliable.
- Bind reported CI and review results to the exact commit SHA. Never claim an unrun check passed.

## Preserve real boundaries

This standard does not waive the accepted architecture, security invariants, project isolation requirements, explicit Owner decision gates, or product/gameplay boundaries. It prevents those boundaries from being expanded into unrelated or premature controls.

Do not infer production readiness, deployment, native approval, or legacy cutover from prototype success. Equally, do not use a production-only gap to prevent a non-production task that stays within its approved boundary.

Proceed autonomously with routine engineering work inside the approved scope. Ask the Owner only for a genuine product-direction choice, a reserved decision, an irreversible/high-impact action, or a missing permission/resource.

## Definition of good engineering

A good result solves the demonstrated problem, passes the checks appropriate to its risk, records material limitations honestly, and delivers usable value without unnecessary machinery.
