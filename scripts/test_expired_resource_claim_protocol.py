#!/usr/bin/env python3
"""Regression tests for expired ResourceClaims across different Work items."""

from __future__ import annotations

import os
import re
import subprocess
import time
from pathlib import Path
from uuid import uuid4

ROOT = Path(__file__).resolve().parents[1]
MIGRATIONS = ROOT / "db" / "prototype"
DATABASE = "aep_expired_resource_claim_test"
HOST = os.environ.get("PGHOST", "127.0.0.1")
PORT = os.environ.get("PGPORT", "5432")
USER = os.environ.get("PGUSER", "postgres")
PASSWORD = os.environ.get("PGPASSWORD", "postgres")


def start_psql(sql: str, *, db: str = DATABASE) -> subprocess.Popen[str]:
    command = [
        "psql", "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1",
        "-h", HOST, "-p", PORT, "-U", USER, "-d", db,
        "-c", sql,
    ]
    environment = os.environ.copy()
    environment["PGPASSWORD"] = PASSWORD
    return subprocess.Popen(
        command,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=environment,
    )


def psql(
    sql: str | None = None,
    *,
    db: str = DATABASE,
    file: Path | None = None,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    command = [
        "psql", "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1",
        "-h", HOST, "-p", PORT, "-U", USER, "-d", db,
    ]
    command.extend(["-f", str(file)] if file else ["-c", sql or ""])
    environment = os.environ.copy()
    environment["PGPASSWORD"] = PASSWORD
    result = subprocess.run(
        command, text=True, capture_output=True, env=environment, check=False
    )
    if check and result.returncode:
        raise RuntimeError(f"psql failed:\n{result.stdout}\n{result.stderr}")
    return result


def lit(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def scalar(sql: str, *, db: str = DATABASE) -> str:
    return psql(sql, db=db).stdout.strip()


def expect_error(sql: str, needle: str, label: str) -> None:
    result = psql(sql, check=False)
    if result.returncode == 0 or needle.lower() not in result.stderr.lower():
        raise AssertionError(
            f"{label}: expected {needle!r}; rc={result.returncode}; "
            f"stdout={result.stdout}; stderr={result.stderr}"
        )


def register_work(project_id: str, identity_key: str) -> str:
    return scalar(
        "SELECT work_id::text FROM aep.register_work("
        f"{lit(project_id)}::uuid,{lit('request-' + str(uuid4()))},"
        f"{lit(str(uuid4()))}::uuid,'expired_claim_test',"
        f"{lit(identity_key)},1,'fix',{lit(identity_key)},'{{}}'::jsonb,NULL);"
    )


def prepare_work(project_id: str, resource_id: str, identity: str, resource_ref: str) -> str:
    work_id = register_work(project_id, identity)
    count = scalar(
        "SELECT aep.set_work_resource_requirements("
        f"{lit(work_id)}::uuid,jsonb_build_array(jsonb_build_object("
        f"'resource_id',{lit(resource_id)},'resource_ref',{lit(resource_ref)})));"
    )
    if count != "1":
        raise AssertionError(f"{identity}: expected one resource requirement, got {count}")
    status = scalar(
        f"SELECT work_status FROM aep.set_work_ready({lit(work_id)}::uuid);"
    )
    if status != "ready":
        raise AssertionError(f"{identity}: Work did not become READY: {status}")
    return work_id


def claim(work_id: str, lease_seconds: int = 600) -> tuple[str, int]:
    result = scalar(
        "SET ROLE aep_runtime; "
        "SELECT execution_id::text || '|' || fence::text "
        "FROM aep.claim_work("
        f"{lit(work_id)}::uuid,{lit(str(uuid4()))}::uuid,{lease_seconds});"
    )
    execution_id, fence_text = result.split("|", 1)
    return execution_id, int(fence_text)


def verify_renewal_serializes_with_resource_reclaim(
    work_id: str, execution_id: str, fence: int, resource_id: str
) -> None:
    expected_version = scalar(
        f"SELECT version FROM aep.works WHERE work_id={lit(work_id)}::uuid;"
    )
    application_name = "aep-expired-claim-renew-lock-test"
    blocker_sql = (
        f"SET application_name={lit(application_name)}; "
        "BEGIN; "
        "SELECT resource_id FROM aep.resources "
        f"WHERE resource_id={lit(resource_id)}::uuid FOR UPDATE; "
        "SELECT pg_sleep(4); "
        "COMMIT;"
    )
    blocker = start_psql(blocker_sql)
    try:
        lock_held = False
        for _ in range(60):
            if scalar(
                "SELECT EXISTS (SELECT 1 FROM pg_stat_activity "
                f"WHERE application_name={lit(application_name)} "
                "AND state='active' AND query LIKE '%pg_sleep(4)%')::text;"
            ) == "true":
                lock_held = True
                break
            if blocker.poll() is not None:
                break
            time.sleep(0.05)
        if not lock_held:
            stdout, stderr = blocker.communicate(timeout=5)
            raise AssertionError(
                "resource lock blocker did not reach its sleep statement: "
                f"stdout={stdout}; stderr={stderr}"
            )

        # Start the short lease only after the blocker is confirmed to hold
        # the physical Resource row, so the renewal begins with a live lease.
        psql(
            "UPDATE aep.executions "
            "SET lease_until=clock_timestamp()+interval '3 seconds' "
            f"WHERE execution_id={lit(execution_id)}::uuid; "
            "UPDATE aep.resource_claims "
            "SET lease_until=clock_timestamp()+interval '3 seconds' "
            f"WHERE execution_id={lit(execution_id)}::uuid AND status='active';"
        )

        renewal_sql = (
            "SET ROLE aep_runtime; "
            "SELECT * FROM aep.renew_execution("
            f"{lit(work_id)}::uuid,{lit(execution_id)}::uuid,{fence},"
            f"{expected_version}::bigint,600);"
        )
        renewal = start_psql(renewal_sql)
        time.sleep(0.25)
        if renewal.poll() is not None:
            stdout, stderr = renewal.communicate(timeout=5)
            raise AssertionError(
                "renew_execution completed while another transaction held the "
                "physical Resource lock; lease renewal is not serialized: "
                f"stdout={stdout}; stderr={stderr}"
            )

        blocker_stdout, blocker_stderr = blocker.communicate(timeout=7)
        if blocker.returncode != 0:
            raise RuntimeError(
                f"resource lock blocker failed: {blocker_stdout}; {blocker_stderr}"
            )
        renewal_stdout, renewal_stderr = renewal.communicate(timeout=7)
        if renewal.returncode == 0 or "expired lease" not in renewal_stderr.lower():
            raise AssertionError(
                "renewal should re-check the lease after waiting for the Resource "
                f"lock; rc={renewal.returncode}; stdout={renewal_stdout}; "
                f"stderr={renewal_stderr}"
            )
    finally:
        if blocker.poll() is None:
            blocker.terminate()
            blocker.communicate(timeout=5)
    print("PASS renewal/reclaim serialization: renewal waits on ordered Resource lock and rejects after lease expiry")

def main() -> None:
    migration_paths = sorted(MIGRATIONS.glob("*.sql"))
    versions: list[int] = []
    for path in migration_paths:
        match = re.fullmatch(r"(\d{4})_[a-z0-9_]+\.sql", path.name)
        if not match:
            raise SystemExit(f"Invalid migration filename: {path.name}")
        versions.append(int(match.group(1)))
    expected = list(range(1, 16))
    if versions != expected:
        raise SystemExit(f"Expected contiguous migrations 0001..0015, got {versions}")

    psql(f"DROP DATABASE IF EXISTS {DATABASE} WITH (FORCE);", db="postgres")
    psql(f"CREATE DATABASE {DATABASE};", db="postgres")
    version = scalar("SELECT current_setting('server_version');")
    if not version.startswith("17.12"):
        raise AssertionError(f"PostgreSQL 17.12 is required; got {version}")
    for path in migration_paths:
        psql(file=path)
    print("PASS clean migration chain: 0001..0015 on PostgreSQL 17.12")

    runtime_surface = scalar(
        "SELECT has_function_privilege('aep_runtime',"
        "'aep.claim_work(uuid,uuid,integer)','EXECUTE')::text "
        "|| '|' || has_function_privilege('aep_runtime',"
        "'aep.renew_execution(uuid,uuid,bigint,bigint,integer)','EXECUTE')::text "
        "|| '|' || has_table_privilege('aep_runtime',"
        "'aep.resource_claims','SELECT')::text;"
    )
    if runtime_surface != "true|true|false":
        raise AssertionError(
            f"replacement did not preserve the narrow runtime surface: {runtime_surface}"
        )
    print("PASS runtime surface: claim/renew RPCs executable; ResourceClaims remain unreadable")

    project_id = scalar(
        "INSERT INTO aep.projects(project_key,name) "
        "VALUES('expired-resource-claim-test','Expired ResourceClaim test') "
        "RETURNING project_id;"
    )
    resource_id = str(uuid4())
    stable_id = "aep-expired-resource-claim-test"
    psql(
        "INSERT INTO aep.resources("
        "resource_id,provider,host,resource_type,stable_resource_id,canonical_key,display_name"
        ") VALUES("
        f"{lit(resource_id)}::uuid,'github','github.com','repository',"
        f"{lit(stable_id)},{lit('repository:' + stable_id)},'Expired ResourceClaim test repo');"
    )
    decision_id = scalar(
        "INSERT INTO aep.owner_decisions("
        "scope_type,scope_key,decision_key,statement,decision_version,status,"
        "approval_source_kind,approval_source_ref,approver_principal,"
        "approval_provenance,approved_at"
        ") VALUES("
        f"'project',{lit(project_id)},{lit('test-write-' + str(uuid4()))},"
        "'Test-only approved repository write access',1,'approved',"
        "'direct_owner_message','test://owner/expired-resource-claim',"
        "'test-owner',jsonb_build_object('direct_owner_confirmation',true),clock_timestamp()"
        ") RETURNING decision_id;"
    )
    psql(
        "INSERT INTO aep.project_resources("
        "project_id,resource_id,access_mode,status,grant_version,grant_decision_id"
        ") VALUES("
        f"{lit(project_id)}::uuid,{lit(resource_id)}::uuid,'write','active',1,"
        f"{lit(decision_id)}::uuid);"
    )

    shared_ref = "refs/heads/expired-claim-shared"
    unrelated_ref = "refs/heads/expired-claim-unrelated"
    owner_work = prepare_work(project_id, resource_id, "expired-claim-owner", shared_ref)
    contender_work = prepare_work(project_id, resource_id, "expired-claim-contender", shared_ref)
    unrelated_work = prepare_work(project_id, resource_id, "unrelated-ref-contender", unrelated_ref)

    owner_execution, _ = claim(owner_work)
    expect_error(
        f"SELECT * FROM aep.claim_work({lit(contender_work)}::uuid,{lit(str(uuid4()))}::uuid,600);",
        "already reserved",
        "live ResourceClaim must block another Work",
    )
    owner_live = scalar(
        "SELECT status || '|' || (lease_until > clock_timestamp())::text "
        f"FROM aep.resource_claims WHERE execution_id={lit(owner_execution)}::uuid;"
    )
    contender_state = scalar(
        "SELECT status || '|' || COALESCE(current_execution_id::text,'null') || '|' "
        "|| fence_generation::text || '|' || "
        "(SELECT count(*)::text FROM aep.executions WHERE work_id=works.work_id) "
        f"FROM aep.works WHERE work_id={lit(contender_work)}::uuid;"
    )
    if owner_live != "active|true" or contender_state != "ready|null|0|0":
        raise AssertionError(
            f"live conflict was not fail-closed/atomic: owner={owner_live}; "
            f"contender={contender_state}"
        )
    print("PASS live exclusion: a non-expired ResourceClaim blocks without partial Work/Execution writes")

    verify_renewal_serializes_with_resource_reclaim(
        owner_work, owner_execution, 1, resource_id
    )

    # Simulate an elapsed Execution lease and its still-active ResourceClaim.
    # The unrelated ref can proceed, but must not clean a claim for another ref.
    psql(
        "UPDATE aep.executions SET lease_until=clock_timestamp()-interval '1 second' "
        f"WHERE execution_id={lit(owner_execution)}::uuid; "
        "UPDATE aep.resource_claims SET lease_until=clock_timestamp()-interval '1 second' "
        f"WHERE execution_id={lit(owner_execution)}::uuid AND status='active';"
    )
    unrelated_execution, _ = claim(unrelated_work)
    owner_still_recorded = scalar(
        f"SELECT status FROM aep.resource_claims WHERE execution_id={lit(owner_execution)}::uuid;"
    )
    if owner_still_recorded != "active":
        raise AssertionError(
            "claiming an unrelated branch ref must not expire another ref's historical reservation"
        )

    # The same physical Resource/ref is now reusable. claim_work must expire
    # only the matching stale reservation before checking the active conflict index.
    contender_execution, _ = claim(contender_work)
    old_claim = scalar(
        "SELECT status || '|' || (lease_until IS NULL)::text || '|' "
        "|| (released_at IS NOT NULL)::text "
        f"FROM aep.resource_claims WHERE execution_id={lit(owner_execution)}::uuid;"
    )
    new_claim = scalar(
        "SELECT status || '|' || (lease_until > clock_timestamp())::text "
        f"FROM aep.resource_claims WHERE execution_id={lit(contender_execution)}::uuid;"
    )
    if old_claim != "expired|true|true" or new_claim != "active|true":
        raise AssertionError(
            f"expired claim was not safely replaced: old={old_claim}; new={new_claim}"
        )
    print("PASS stale reclaim: expired claim is released only for the exact Resource/ref/conflict key")

    # A subsequent live or NULL-lease reservation remains a conflict.
    blocked_work = prepare_work(project_id, resource_id, "live-claim-blocked-work", shared_ref)
    expect_error(
        f"SELECT * FROM aep.claim_work({lit(blocked_work)}::uuid,{lit(str(uuid4()))}::uuid,600);",
        "already reserved",
        "live ResourceClaim must continue to block after stale cleanup",
    )
    psql(
        "UPDATE aep.resource_claims SET lease_until=NULL "
        f"WHERE execution_id={lit(contender_execution)}::uuid AND status='active';"
    )
    null_lease_work = prepare_work(project_id, resource_id, "null-lease-claim-blocked-work", shared_ref)
    expect_error(
        f"SELECT * FROM aep.claim_work({lit(null_lease_work)}::uuid,{lit(str(uuid4()))}::uuid,600);",
        "already reserved",
        "NULL-lease ResourceClaim must remain a conservative conflict",
    )
    for work_id in (blocked_work, null_lease_work):
        state = scalar(
            "SELECT status || '|' || COALESCE(current_execution_id::text,'null') || '|' "
            "|| fence_generation::text || '|' || "
            "(SELECT count(*)::text FROM aep.executions WHERE work_id=works.work_id) "
            f"FROM aep.works WHERE work_id={lit(work_id)}::uuid;"
        )
        if state != "ready|null|0|0":
            raise AssertionError(f"blocked Work was partially mutated: {work_id}: {state}")
    print("PASS conservative block: live and NULL-lease claims remain blocking without partial writes")

    # Keep the unrelated branch execution valid while confirming both active
    # executions coexist only on non-overlapping exact refs.
    unrelated_state = scalar(
        "SELECT count(*) FROM aep.resource_claims "
        f"WHERE execution_id={lit(unrelated_execution)}::uuid AND status='active';"
    )
    if unrelated_state != "1":
        raise AssertionError("unrelated-ref claim was not retained")
    print("All expired ResourceClaim regression tests passed.")


if __name__ == "__main__":
    main()
