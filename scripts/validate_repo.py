#!/usr/bin/env python3
"""Fast, dependency-free repository contract checks for Stage 0."""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

REQUIRED_FILES = (
    "README.md",
    "AGENTS.md",
    "CONTRIBUTING.md",
    "docs/ARCHITECTURE-BASELINE.md",
    "docs/DECISION-REGISTER.md",
    "docs/IMPLEMENTATION-ROADMAP.md",
    "docs/ACCEPTANCE-TEST-MAP.md",
)

REQUIRED_DECISIONS = ("D4", "D9", "D13", "D14", "D15", "D16")
REQUIRED_TEST_IDS = tuple(f"T{i:02d}" for i in range(1, 27))


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> int:
    missing = [path for path in REQUIRED_FILES if not (ROOT / path).is_file()]
    if missing:
        fail("missing required files: " + ", ".join(missing))

    baseline = (ROOT / "docs/ARCHITECTURE-BASELINE.md").read_text(encoding="utf-8")
    decisions = (ROOT / "docs/DECISION-REGISTER.md").read_text(encoding="utf-8")
    test_map = (ROOT / "docs/ACCEPTANCE-TEST-MAP.md").read_text(encoding="utf-8")
    agents = (ROOT / "AGENTS.md").read_text(encoding="utf-8")

    for term in ("Work Registry", "work_id", "session_id", "execution_id", "fence", "Context Compiler"):
        if term.lower() not in baseline.lower():
            fail(f"architecture baseline is missing required concept: {term}")

    for decision in REQUIRED_DECISIONS:
        if not re.search(rf"\b{decision}\b", decisions):
            fail(f"decision register is missing {decision}")

    for test_id in REQUIRED_TEST_IDS:
        if not re.search(rf"\b{test_id}\b", test_map):
            fail(f"acceptance test map is missing {test_id}")

    if "stable agent_id" not in agents or "not an MVP prerequisite" not in agents:
        fail("agent identity boundary is missing from AGENTS.md")

    lowered_agents = agents.lower()
    supabase_boundary_phrases = (
        "must not mutate any existing supabase project or database",
        "no existing supabase project or database is modified",
    )
    if not any(phrase in lowered_agents for phrase in supabase_boundary_phrases):
        fail("Stage 0/1 existing-Supabase mutation boundary is missing")

    workflow = ROOT / ".github/workflows/ci.yml"
    if not workflow.is_file():
        fail("missing GitHub Actions CI workflow")

    print("Repository contract validation passed.")
    print(f"Required documents: {len(REQUIRED_FILES)}")
    print(f"Decision gates: {', '.join(REQUIRED_DECISIONS)}")
    print(f"Acceptance tests mapped: {len(REQUIRED_TEST_IDS)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
