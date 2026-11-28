#!/usr/bin/env python3
"""Stage 4A ResourceClaim recovery regression on the complete prototype migration chain."""

from __future__ import annotations

import json
import os
import re
import subprocess
from pathlib import Path
from uuid import uuid4

ROOT = Path(__file__).resolve().parents[1]
MIGRATIONS = ROOT / "db" / "prototype"
DATABASE = "aep_stage4a_claim_recovery"
HOST = os.environ.get("PGHOST", "127.0.0.1")
PORT = os.environ.get("PGPORT", "5432")
USER = os.environ.get("PGUSER", "postgres")
PASSWORD = os.environ.get("PGPASSWORD", "postgres")


def psql(sql: str | None = None, *, db: str = DATABASE, file: Path | None = None,
         check: bool = True) -> subprocess.CompletedProcess[str]:
    cmd = ["psql", "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1",
           "-h", HOST, "-p", PORT, "-U", USER, "-d", db]
    cmd.extend(["-f", str(file)] if file else ["-c", sql or ""])
    env = os.environ.copy()
    env["PGPASSWORD"] = PASSWORD
    result = subprocess.run(cmd, text=True, capture_output=True, env=env, check=False)
    if check and result.returncode:
        raise RuntimeError(f"psql failed:\n{result.stdout}\n{result.stderr}")
    return result


def lit(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def json_sql(value: dict | list) -> str:
    return lit(json.dumps(value, sort_keys=True, separators=(",", ":"))) + "::jsonb"


def scalar(sql: str, *, db: str = DATABASE) -> str:
    return psql(sql, db=db).stdout.strip()


def json_result(sql: str) -> dict:
    raw = scalar(sql)
    return json.loads(raw)


def setup_database() -> None:
    paths = sorted(MIGRATIONS.glob("*.sql"))
    versions: list[int] = []
    for path in paths:
        match = re.fullmatch(r"(\d{4})_[a-z0-9_]+\.sql", path.name)
        if not match:
            raise SystemExit(f"Invalid migration filename: {path.name}")
        versions.append(int(match.group(1)))
    if versions != list(range(1, 16)):
        raise SystemExit(f"Expected clean ordered migrations 0001..0015, got {versions}")
    psql(f"DROP DATABASE IF EXISTS {DATABASE} WITH (FORCE);", db="postgres")
    psql(f"CREATE DATABASE {DATABASE};", db="postgres")
    version = scalar("SELECT current_setting('server_version');")
    if not version.startswith("17.12"):
        raise AssertionError(f"Stage 4A ResourceClaim recovery requires PostgreSQL 17.12; got {version}")
    for path in paths:
        psql(file=path)
    print("PASS T26: clean ordered migrations 0001..0015 on PostgreSQL 17.12")


def setup_scope(label: str) -> tuple[str, str]:
    project_id = scalar(
        "INSERT INTO aep.projects(project_key,name) VALUES("
        f"{lit('stage4a-claim-'+label+'-'+uuid4().hex[:8])},"
        f"{lit('Stage 4A claim recovery '+label)}) RETURNING project_id::text;"
    )
    stable_id = "stage4a-claim-" + label + "-" + uuid4().hex
    resource_id = scalar(
        "INSERT INTO aep.resources(provider,host,resource_type,stable_resource_id,canonical_key,display_name) "
        "VALUES('github','github.com','repository',"
        f"{lit(stable_id)},{lit('repository:'+stable_id)},{lit('Stage 4A '+label+' repository')}) "
        "RETURNING resource_id::text;"
    )
    decision_id = scalar(
        "INSERT INTO aep.owner_decisions("
        "scope_type,scope_key,decision_key,statement,decision_version,status,"
        "approval_source_kind,approval_source_ref,approver_principal,approval_provenance,approved_at"
        ") VALUES("
        f"'project',{lit(project_id)},'stage4a-claim-write-{label}',"
        f"{lit('Test-only ResourceClaim recovery write grant')},"
        "1,'approved','direct_owner_message','test://owner/stage4a-claims','test-owner',"
        "jsonb_build_object('direct_owner_confirmation',true),clock_timestamp()"
        ") RETURNING decision_id::text;"
    )
    psql(
        "INSERT INTO aep.project_resources("
        "project_id,resource_id,access_mode,status,grant_version,grant_decision_id"
        ") VALUES("
        f"{lit(project_id)}::uuid,{lit(resource_id)}::uuid,'read_write','active',1,"
        f"{lit(decision_id)}::uuid);"
    )
    return project_id, resource_id


def create_claimed_work(project_id: str, resource_id: str, label: str) -> tuple[str, str, str, int]:
    session_id = str(uuid4())
    suffix = uuid4().hex
    work_id = scalar(
        "SELECT work_id::text FROM aep.register_work("
        f"{lit(project_id)}::uuid,{lit('request-'+suffix)},{lit(session_id)}::uuid,"
        f"'stage4a_claim_recovery',{lit('work-'+suffix)},1,'implementation',"
        f"{lit('Stage 4A claimed Work '+label)},"
        f"{json_sql({'acceptance':['recover exact resource claims']})},NULL);"
    )
    psql(
        "SELECT aep.set_work_resource_requirements("
        f"{lit(work_id)}::uuid,"
        f"{json_sql([{'resource_id':resource_id,'resource_ref':'refs/heads/main'}])});"
    )
    status = scalar(f"SELECT work_status FROM aep.set_work_ready({lit(work_id)}::uuid);")
    if status != "ready":
        raise AssertionError(f"{label}: expected READY Work, got {status}")
    claimed = scalar(
        "SELECT execution_id::text || '|' || fence::text FROM aep.claim_work("
        f"{lit(work_id)}::uuid,{lit(session_id)}::uuid,600);"
    )
    execution_id, fence_text = claimed.split("|")
    return work_id, session_id, execution_id, int(fence_text)


def recover(project_id: str, *, related_limit: int = 50) -> dict:
    return json_result(
        "SELECT aep.recover_session_state("
        f"{lit(project_id)}::uuid,{lit(str(uuid4()))}::uuid,100,{related_limit})::text;"
    )


def test_project_scoped_claim_recovery() -> None:
    project_a, resource_a = setup_scope("owner")
    project_b, resource_b = setup_scope("foreign")
    work_a, session_a, execution_a, fence_a = create_claimed_work(
        project_a, resource_a, "owner"
    )
    foreign_work, _, foreign_execution, _ = create_claimed_work(
        project_b, resource_b, "foreign"
    )

    # Simulate an observed elapsed Execution lease, then exercise the real
    # claim_work takeover path. The previous session is not treated as stopped.
    psql(
        "UPDATE aep.executions SET lease_until=clock_timestamp()-interval '1 second' "
        f"WHERE execution_id={lit(execution_a)}::uuid;"
        "UPDATE aep.resource_claims SET lease_until=clock_timestamp()-interval '1 second' "
        f"WHERE execution_id={lit(execution_a)}::uuid AND status='active';"
    )
    expired_snapshot = recover(project_a)
    expired_claim = next(
        row for row in expired_snapshot["resource_claims"] if row["execution_id"] == execution_a
    )
    expired_execution = next(
        row for row in expired_snapshot["executions"] if row["execution_id"] == execution_a
    )
    if (
        expired_claim["status"] != "active"
        or expired_claim["lease_expired"] is not True
        or expired_claim["is_current_execution"] is not True
        or expired_execution["lease_expired"] is not True
        or expired_execution["old_session_may_still_be_active"] is not True
        or expired_execution["session_termination_observed"] is not False
    ):
        raise AssertionError("Expired lease was not recovered as an active claim without implying session termination")

    takeover_session = str(uuid4())
    takeover = scalar(
        "SELECT execution_id::text || '|' || fence::text FROM aep.claim_work("
        f"{lit(work_a)}::uuid,{lit(takeover_session)}::uuid,600);"
    )
    execution_b, fence_b_text = takeover.split("|")
    fence_b = int(fence_b_text)
    if fence_b != fence_a + 1:
        raise AssertionError(f"takeover fence did not advance: {fence_a} -> {fence_b}")

    snapshot = recover(project_a)
    if snapshot["authorization"].get("checked_before_resource_claim_retrieval") is not True:
        raise AssertionError("ResourceClaim recovery did not report the project scope gate")
    claims = snapshot.get("resource_claims")
    if not isinstance(claims, list) or len(claims) != 2:
        raise AssertionError(f"Expected both current and prior Execution claims: {claims}")
    current = next((claim for claim in claims if claim["execution_id"] == execution_b), None)
    previous = next((claim for claim in claims if claim["execution_id"] == execution_a), None)
    if current is None or previous is None:
        raise AssertionError("Recovery omitted a current or historical Execution ResourceClaim")
    if (
        current["project_id"] != project_a
        or current["work_id"] != work_a
        or current["resource_id"] != resource_a
        or current["resource_ref"] != "refs/heads/main"
        or current["write_set_kind"] != "repository_ref"
        or current["conflict_key"] != "*"
        or current["normalized_write_set"] != []
        or current["status"] != "active"
        or current["fence"] != fence_b
        or current["lease_until"] is None
        or current["lease_expired"] is not False
        or current["is_current_execution"] is not True
    ):
        raise AssertionError(f"Current ResourceClaim identity/lease/fence mismatch: {current}")
    if (
        previous["status"] != "expired"
        or previous["lease_until"] is not None
        or previous["lease_expired"] is not False
        or previous["fence"] != fence_a
        or previous["is_current_execution"] is not False
    ):
        raise AssertionError(f"Previous ResourceClaim was not preserved as expired history: {previous}")
    old_execution = next(
        row for row in snapshot["executions"] if row["execution_id"] == execution_a
    )
    if (
        old_execution["session_id"] != session_a
        or old_execution["lease_expired"] is not True
        or old_execution["old_session_may_still_be_active"] is not True
        or old_execution["session_termination_observed"] is not False
    ):
        raise AssertionError("Expired claim recovery incorrectly implied old-session termination")
    if any(row["work_id"] == foreign_work for row in snapshot["work_items"]):
        raise AssertionError("Recovery exposed another project's Work")
    if any(
        row["project_id"] != project_a or row["work_id"] == foreign_work
        for row in snapshot["resource_claims"]
    ):
        raise AssertionError("Recovery exposed a ResourceClaim outside the selected project/Work scope")
    if any(row["execution_id"] == foreign_execution for row in snapshot["resource_claims"]):
        raise AssertionError("Recovery exposed another project's Execution ResourceClaim")

    bounded = recover(project_a, related_limit=1)
    if len(bounded["resource_claims"]) != 1:
        raise AssertionError("ResourceClaim projection did not respect related_limit")
    if bounded["related_data_truncated"].get("resource_claims") is not True:
        raise AssertionError("ResourceClaim truncation was not reported independently")

    print(
        "PASS T10: current and expired ResourceClaims recover with exact project/Work/"
        "Execution/resource/ref/fence identity; foreign-project claims remain isolated; "
        "claim history is bounded and truncation is explicit"
    )


def main() -> None:
    setup_database()
    test_project_scoped_claim_recovery()


if __name__ == "__main__":
    main()
