#!/usr/bin/env python3
"""Populated-database upgrade preflight for prototype migrations 0013..0015.

This test deliberately upgrades an existing, populated 0001..0012 database.
It runs only against a disposable PostgreSQL 17.12 database created by this
script; it never connects to a hosted Supabase project.
"""

from __future__ import annotations

import atexit
import hashlib
import json
import os
import re
import subprocess
from pathlib import Path
from uuid import uuid4

ROOT = Path(__file__).resolve().parents[1]
MIGRATIONS = ROOT / "db" / "prototype"
MANIFEST_PATH = ROOT / "adapters" / "github-session-tools.json"
DATABASE = "aep_populated_upgrade_preflight_" + uuid4().hex[:8]
# This destructive fixture is intentionally pinned to the CI-local loopback
# service. Do not allow PGHOST/PGHOSTADDR/PGSERVICE to redirect DROP DATABASE
# to a hosted or otherwise shared Registry.
HOST = "127.0.0.1"
PORT = "5432"
USER = "postgres"
PASSWORD = os.environ.get("PGPASSWORD", "postgres")
REPOSITORY_ID = "999990001"
REPOSITORY_NAME = "Love-DC/aep-populated-upgrade-fixture"
BASE_SHA = "a" * 40
PR_HEAD_SHA = "b" * 40


def psql(
    sql: str | None = None,
    *,
    db: str = DATABASE,
    file: Path | None = None,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    cmd = [
        "psql", "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1",
        "-h", HOST, "-p", PORT, "-U", USER, "-d", db,
    ]
    cmd.extend(["-f", str(file)] if file else ["-c", sql or ""])
    env = os.environ.copy()
    env.pop("PGHOSTADDR", None)
    env.pop("PGSERVICE", None)
    env.pop("PGSERVICEFILE", None)
    env["PGHOST"] = HOST
    env["PGPORT"] = PORT
    env["PGUSER"] = USER
    env["PGPASSWORD"] = PASSWORD
    result = subprocess.run(
        cmd, text=True, capture_output=True, env=env, check=False
    )
    if check and result.returncode:
        raise RuntimeError(
            f"psql failed (database={db}):\n{result.stdout}\n{result.stderr}"
        )
    return result


def lit(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def json_sql(value: dict | list) -> str:
    return lit(json.dumps(value, sort_keys=True, separators=(",", ":"))) + "::jsonb"


def scalar(sql: str, *, db: str = DATABASE) -> str:
    return psql(sql, db=db).stdout.strip()


def json_result(sql: str) -> dict:
    return json.loads(scalar(sql))


def expect_error(sql: str, needle: str, label: str) -> None:
    result = psql(sql, check=False)
    if result.returncode == 0 or needle.lower() not in result.stderr.lower():
        raise AssertionError(
            f"{label}: expected error containing {needle!r}; "
            f"rc={result.returncode}; stdout={result.stdout}; stderr={result.stderr}"
        )


def migration_paths() -> list[Path]:
    paths = sorted(MIGRATIONS.glob("*.sql"))
    versions: list[int] = []
    for path in paths:
        match = re.fullmatch(r"(\d{4})_[a-z0-9_]+\.sql", path.name)
        if not match:
            raise SystemExit(f"Invalid migration filename: {path.name}")
        versions.append(int(match.group(1)))
    if versions != list(range(1, 16)):
        raise SystemExit(f"Expected contiguous migrations 0001..0015, got {versions}")
    return paths


def cleanup_database() -> None:
    try:
        # The database name is unique to this process, so cleanup cannot
        # remove a pre-existing database or another test's fixture.
        psql(f"DROP DATABASE IF EXISTS {DATABASE};", db="postgres")
    except Exception as exc:  # cleanup must not hide the original test failure
        print(f"WARNING: unable to remove disposable database {DATABASE}: {exc}")


def setup_database(paths: list[Path]) -> None:
    psql(f"CREATE DATABASE {DATABASE};", db="postgres")
    atexit.register(cleanup_database)
    version = scalar("SELECT current_setting('server_version');")
    if not version.startswith("17.12"):
        raise AssertionError(
            f"Populated upgrade preflight requires PostgreSQL 17.12; got {version}"
        )
    # First create the exact already-installed baseline, then seed it before
    # running the three additive/follow-up migrations as an in-place upgrade.
    for path in paths[:12]:
        psql(file=path)
    print("PASS pre-upgrade baseline: clean migrations 0001..0012 on PostgreSQL 17.12")


def setup_repository(manifest: dict) -> tuple[str, str, str]:
    project_id = scalar(
        "INSERT INTO aep.projects(project_key,name) VALUES("
        "'populated-upgrade-preflight','Populated upgrade preflight') "
        "RETURNING project_id::text;"
    )
    resource_id = scalar(
        "INSERT INTO aep.resources(provider,host,resource_type,stable_resource_id,"
        "canonical_key,display_name) VALUES("
        f"'github','github.com','repository',{lit(REPOSITORY_ID)},"
        f"{lit('repository:' + REPOSITORY_ID)},'Populated upgrade fixture repository') "
        "RETURNING resource_id::text;"
    )
    decision_id = scalar(
        "INSERT INTO aep.owner_decisions("
        "scope_type,scope_key,decision_key,statement,decision_version,status,"
        "approval_source_kind,approval_source_ref,approver_principal,"
        "approval_provenance,approved_at"
        ") VALUES("
        f"'project',{lit(project_id)},'populated-upgrade-write',"
        "'Test-only write grant for populated migration upgrade',"
        "1,'approved','direct_owner_message',"
        "'test://owner/populated-upgrade-preflight','test-owner',"
        "jsonb_build_object('direct_owner_confirmation',true),clock_timestamp()"
        ") RETURNING decision_id::text;"
    )
    psql(
        "INSERT INTO aep.project_resources("
        "project_id,resource_id,access_mode,status,grant_version,grant_decision_id"
        ") VALUES("
        f"{lit(project_id)}::uuid,{lit(resource_id)}::uuid,"
        f"'read_write','active',1,{lit(decision_id)}::uuid);"
    )
    psql(
        "SELECT aep.register_delivery_adapter_manifest("
        f"{lit(resource_id)}::uuid,{json_sql(manifest)},NULL);"
    )
    return project_id, resource_id, decision_id


def create_work(
    project_id: str,
    resource_id: str,
    identity: str,
    resource_ref: str,
) -> str:
    request_key = "request-" + uuid4().hex
    session_id = str(uuid4())
    work_id = scalar(
        "SELECT work_id::text FROM aep.register_work("
        f"{lit(project_id)}::uuid,{lit(request_key)},{lit(session_id)}::uuid,"
        f"'populated_upgrade_preflight',{lit(identity)},1,'implementation',"
        f"{lit('Populated upgrade fixture: ' + identity)},"
        f"{json_sql({'acceptance': ['preserve populated state across 0012 to 0015']})},"
        "NULL);"
    )
    psql(
        "SELECT aep.set_work_resource_requirements("
        f"{lit(work_id)}::uuid,"
        f"{json_sql([{'resource_id': resource_id, 'resource_ref': resource_ref}])});"
    )
    status = scalar(
        f"SELECT work_status FROM aep.set_work_ready({lit(work_id)}::uuid);"
    )
    if status != "ready":
        raise AssertionError(f"{identity}: expected READY, got {status}")
    return work_id


def claim_work(work_id: str, lease_seconds: int = 3600) -> tuple[str, int]:
    session_id = str(uuid4())
    raw = scalar(
        "SELECT execution_id::text || '|' || fence::text "
        "FROM aep.claim_work("
        f"{lit(work_id)}::uuid,{lit(session_id)}::uuid,{lease_seconds});"
    )
    execution_id, fence_text = raw.split("|")
    return execution_id, int(fence_text)


def allocate_delivery(
    work_id: str,
    execution_id: str,
    fence: int,
    resource_id: str,
    base_ref: str,
) -> str:
    raw = scalar(
        "SELECT aep.allocate_execution_delivery("
        f"{lit(work_id)}::uuid,{lit(execution_id)}::uuid,{fence},"
        f"{lit(resource_id)}::uuid,'github.com',{lit(REPOSITORY_ID)},"
        f"{lit(REPOSITORY_NAME)},{lit(base_ref)},{lit(BASE_SHA)});"
    )
    return json.loads(raw)["delivery_branch"]


def seed_delivery_and_history(
    project_id: str,
    resource_id: str,
    work_id: str,
    execution_id: str,
    fence: int,
    branch: str,
) -> None:
    # Seed delivery, PR HEAD, exact-SHA CI evidence, and an externally observed
    # operation receipt while still on the 0012 schema.
    psql(
        "SELECT aep.record_delivery_pr_state("
        f"{lit(execution_id)}::uuid,901,"
        f"{lit('https://github.com/Love-DC/aep-populated-upgrade-fixture/pull/901')},"
        f"{lit(PR_HEAD_SHA)},'github://fixture/pr/901');"
    )
    psql(
        "SELECT aep.record_delivery_evidence("
        f"{lit(execution_id)}::uuid,'ci',{lit(PR_HEAD_SHA)},"
        "'github://fixture/actions/run/901',NULL,"
        f"{json_sql({'tested_sha': PR_HEAD_SHA, 'conclusion': 'success'})});"
    )
    payload = {
        "head": branch,
        "base": "main",
        "title": "Populated upgrade fixture PR",
    }
    receipt_id = scalar(
        "SELECT aep.create_external_operation_intent("
        f"{lit(work_id)}::uuid,{lit(execution_id)}::uuid,{fence},"
        f"{lit('populated-upgrade-pr-' + execution_id)},'pull_request_create',"
        f"{lit(resource_id)}::uuid,'github.com',{lit(REPOSITORY_ID)},"
        f"{lit(branch)},{json_sql(payload)});"
    )
    receipt_payload = {
        "external_object_type": "pull_request",
        "external_id": "901",
        "revision": "fixture-pr-901",
    }
    psql(
        "SELECT aep.record_external_operation_receipt("
        f"{lit(receipt_id)}::uuid,'pull_request','901','fixture-pr-901',"
        f"{json_sql(receipt_payload)});"
    )
    content = b"seeded source evidence must survive the populated migration upgrade"
    content_hash = hashlib.sha256(content).hexdigest()
    psql(
        "INSERT INTO aep.evidence("
        "project_id,work_id,execution_id,evidence_type,source_ref,source_revision,"
        "content_sha256,provenance,payload"
        ") VALUES("
        f"{lit(project_id)}::uuid,{lit(work_id)}::uuid,{lit(execution_id)}::uuid,"
        "'test_result','test://populated-upgrade/source','fixture-revision-1',"
        f"{lit(content_hash)},"
        f"{json_sql({'source': 'populated-upgrade-fixture', 'sha256': content_hash})},"
        f"{json_sql({'fixture': True, 'preserve': 'source evidence'})});"
    )


# Table name, primary-key ordering columns. These are deliberately explicit so
# the snapshot fails loudly if a covered table's identity model changes.
SNAPSHOT_TABLES: tuple[tuple[str, tuple[str, ...]], ...] = (
    ("projects", ("project_id",)),
    ("resources", ("resource_id",)),
    ("owner_decisions", ("decision_id",)),
    ("project_resources", ("project_id", "resource_id")),
    ("delivery_adapter_manifests", ("resource_id",)),
    ("works", ("work_id",)),
    ("work_resource_requirements", ("requirement_id",)),
    ("executions", ("execution_id",)),
    ("resource_claims", ("resource_claim_id",)),
    ("execution_deliveries", ("delivery_id",)),
    ("execution_delivery_evidence", ("evidence_id",)),
    ("operation_receipts", ("operation_receipt_id",)),
    ("operation_receipt_events", ("receipt_event_id",)),
    ("work_events", ("event_id",)),
    ("evidence", ("evidence_id",)),
)


def populated_snapshot() -> dict[str, list[dict]]:
    snapshot: dict[str, list[dict]] = {}
    for table, keys in SNAPSHOT_TABLES:
        order = ", ".join(f"row_item.{key}" for key in keys)
        raw = scalar(
            "SELECT COALESCE(jsonb_agg(to_jsonb(row_item) ORDER BY "
            f"{order})::text,'[]') FROM aep.{table} AS row_item;"
        )
        snapshot[table] = json.loads(raw)
    return snapshot


def assert_0013_complete_claim_guard(
    work_id: str,
    execution_id: str,
    fence: int,
    resource_id: str,
    branch: str,
) -> None:
    # Existing delivery replay succeeds with its intact complete claim set.
    replay_branch = allocate_delivery(
        work_id, execution_id, fence, resource_id, "refs/heads/main"
    )
    if replay_branch != branch:
        raise AssertionError("0013 migration changed the pre-existing delivery identity")

    # An 'active' row with an elapsed claim lease must not authorize allocation.
    psql(
        "UPDATE aep.resource_claims "
        "SET lease_until=clock_timestamp()-interval '1 second' "
        f"WHERE execution_id={lit(execution_id)}::uuid AND status='active';"
    )
    expect_error(
        "SELECT aep.allocate_execution_delivery("
        f"{lit(work_id)}::uuid,{lit(execution_id)}::uuid,{fence},"
        f"{lit(resource_id)}::uuid,'github.com',{lit(REPOSITORY_ID)},"
        f"{lit(REPOSITORY_NAME)},'refs/heads/main',{lit(BASE_SHA)});",
        "reservation set is incomplete",
        "0013 rejects an expired member of a populated Execution claim set",
    )
    psql(
        "UPDATE aep.resource_claims SET lease_until=("
        "SELECT lease_until FROM aep.executions "
        f"WHERE execution_id={lit(execution_id)}::uuid) "
        f"WHERE execution_id={lit(execution_id)}::uuid AND status='active';"
    )
    print("PASS 0013: populated exact delivery replays; expired claim member fails closed")


def assert_0014_matching_stale_claim_expiry(
    work_a: str,
    execution_a: str,
    work_b: str,
    execution_c: str,
) -> tuple[str, int]:
    # Expire A (same Resource/ref as B) and C (same physical Resource, different
    # ref). Claiming B must expire only A's matching stale reservation.
    psql(
        "UPDATE aep.executions SET lease_until=clock_timestamp()-interval '1 second' "
        f"WHERE execution_id IN ({lit(execution_a)}::uuid,{lit(execution_c)}::uuid);"
        "UPDATE aep.resource_claims SET lease_until=clock_timestamp()-interval '1 second' "
        f"WHERE execution_id IN ({lit(execution_a)}::uuid,{lit(execution_c)}::uuid) "
        "AND status='active';"
    )
    execution_b, fence_b = claim_work(work_b)
    a_state = scalar(
        "SELECT concat(status, '|', (lease_until IS NULL)::text, '|', "
        "(released_at IS NOT NULL)::text) FROM aep.resource_claims "
        f"WHERE execution_id={lit(execution_a)}::uuid;"
    )
    c_state = scalar(
        "SELECT status || '|' || (lease_until<=clock_timestamp())::text "
        f"FROM aep.resource_claims WHERE execution_id={lit(execution_c)}::uuid;"
    )
    b_state = scalar(
        "SELECT status || '|' || (lease_until>clock_timestamp())::text "
        f"FROM aep.resource_claims WHERE execution_id={lit(execution_b)}::uuid;"
    )
    if a_state != "expired|true|true":
        raise AssertionError(f"0014 did not expire only the matching stale claim: {a_state}")
    if c_state != "active|true":
        raise AssertionError(
            "0014 expired a stale claim belonging to a different ref on the same physical Resource: "
            f"{c_state}"
        )
    if b_state != "active|true":
        raise AssertionError(f"0014 did not create the contender's live claim: {b_state}")
    print("PASS 0014: stale ResourceClaim expiry is limited to the matching physical Resource/ref/conflict key")
    return execution_b, fence_b


def assert_0015_recovery_projection(
    project_id: str,
    work_a: str,
    execution_a: str,
    fence_a: int,
    work_b: str,
    execution_b: str,
    fence_b: int,
    work_c: str,
    execution_c: str,
    fence_c: int,
    resource_id: str,
) -> None:
    snapshot = json_result(
        "SELECT aep.recover_session_state("
        f"{lit(project_id)}::uuid,{lit(str(uuid4()))}::uuid,100,250)::text;"
    )
    if snapshot.get("authorization", {}).get(
        "checked_before_resource_claim_retrieval"
    ) is not True:
        raise AssertionError("0015 recovery did not report its pre-retrieval authorization gate")
    claims = snapshot.get("resource_claims")
    if not isinstance(claims, list):
        raise AssertionError("0015 recovery omitted the resource_claims collection")

    by_execution = {row["execution_id"]: row for row in claims}
    expected_ids = {execution_a, execution_b, execution_c}
    if set(by_execution) != expected_ids:
        raise AssertionError(
            f"0015 recovery returned the wrong claim history: "
            f"expected {expected_ids}, got {set(by_execution)}"
        )

    for execution_id, work_id, fence, expected_status, expired, current, expected_ref in (
        (execution_a, work_a, fence_a, "expired", False, True, "refs/heads/main"),
        (execution_b, work_b, fence_b, "active", False, True, "refs/heads/main"),
        (execution_c, work_c, fence_c, "active", True, True, "refs/heads/upgrade-unrelated"),
    ):
        row = by_execution[execution_id]
        if (
            row["project_id"] != project_id
            or row["work_id"] != work_id
            or row["resource_id"] != resource_id
            or row["resource_ref"] != expected_ref
            or row["fence"] != fence
            or row["status"] != expected_status
            or row["lease_expired"] is not expired
            or row["is_current_execution"] is not current
        ):
            raise AssertionError(
                f"0015 recovery identity/status mismatch for {execution_id}: {row}"
            )
        if expected_status == "expired" and row["lease_until"] is not None:
            raise AssertionError(f"Expired historical claim retained a lease: {row}")
        if expected_status == "active" and not row["lease_until"]:
            raise AssertionError(f"Active recovered claim has no lease: {row}")

    execution_rows = {row["execution_id"]: row for row in snapshot["executions"]}
    for execution_id in (execution_a, execution_b, execution_c):
        row = execution_rows.get(execution_id)
        if row is None:
            raise AssertionError(f"0015 recovery omitted Execution {execution_id}")
        if row["old_session_may_still_be_active"] is not True:
            raise AssertionError("Recovery must not infer session termination from persisted lease state")
        if row["session_termination_observed"] is not False:
            raise AssertionError("Recovery must retain the explicit unknown-session-termination boundary")
    if len(snapshot.get("resource_claims", [])) > 250:
        raise AssertionError("0015 recovery exceeded the requested related-data bound")
    print("PASS 0015: populated current/history Claims recover with exact project/Work/Execution/ref/fence/lease data")


def main() -> None:
    paths = migration_paths()
    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    setup_database(paths)
    project_id, resource_id, _ = setup_repository(manifest)

    work_a = create_work(project_id, resource_id, "same-ref-owner", "refs/heads/main")
    execution_a, fence_a = claim_work(work_a)
    branch_a = allocate_delivery(
        work_a, execution_a, fence_a, resource_id, "refs/heads/main"
    )
    seed_delivery_and_history(
        project_id, resource_id, work_a, execution_a, fence_a, branch_a
    )

    # A second READY Work competes for the same physical ref. A third Work
    # shares the physical repository but targets an independent branch ref.
    work_b = create_work(project_id, resource_id, "same-ref-contender", "refs/heads/main")
    work_c = create_work(
        project_id, resource_id, "unrelated-ref-owner", "refs/heads/upgrade-unrelated"
    )
    execution_c, fence_c = claim_work(work_c)

    before = populated_snapshot()
    row_counts_before = {name: len(rows) for name, rows in before.items()}
    if not all(row_counts_before[name] > 0 for name in (
        "projects", "resources", "owner_decisions", "project_resources",
        "delivery_adapter_manifests", "works", "work_resource_requirements",
        "executions", "resource_claims", "execution_deliveries",
        "execution_delivery_evidence", "operation_receipts",
        "operation_receipt_events", "work_events", "evidence",
    )):
        raise AssertionError(f"Fixture did not populate every required state family: {row_counts_before}")
    print("PASS populated fixture: Project, grant, Work, Execution, Claims, Delivery, Evidence and Receipt rows exist before upgrade")

    for path in paths[12:15]:
        psql(file=path)
    print("PASS in-place upgrade: migrations 0013..0015 applied over populated 0001..0012 state")

    after = populated_snapshot()
    if before != after:
        changed = [
            name for name in before
            if before[name] != after.get(name)
        ]
        raise AssertionError(
            "0013..0015 changed pre-existing populated rows: " + ", ".join(changed)
        )
    print("PASS preservation: all seeded rows and exact identities survived the 0012-to-0015 upgrade unchanged")

    assert_0013_complete_claim_guard(
        work_a, execution_a, fence_a, resource_id, branch_a
    )
    execution_b, fence_b = assert_0014_matching_stale_claim_expiry(
        work_a, execution_a, work_b, execution_c
    )
    assert_0015_recovery_projection(
        project_id,
        work_a, execution_a, fence_a,
        work_b, execution_b, fence_b,
        work_c, execution_c, fence_c,
        resource_id,
    )
    print("PASS populated Registry migration-upgrade preflight: 0012 -> 0015")
    

if __name__ == "__main__":
    main()
