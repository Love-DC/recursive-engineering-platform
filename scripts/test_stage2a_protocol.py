#!/usr/bin/env python3
"""Adversarial Stage 2A protocol tests on a disposable PostgreSQL database."""

from __future__ import annotations

import os
import re
import select
import subprocess
import time
from pathlib import Path
from uuid import uuid4

ROOT = Path(__file__).resolve().parents[1]
MIGRATIONS = ROOT / "db" / "prototype"
DATABASE = "aep_stage2a_test"
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
        raise RuntimeError(f"psql failed: {result.stdout}\n{result.stderr}")
    return result


def lit(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def scalar(sql: str) -> str:
    return psql(sql).stdout.strip()


def expect_error(sql: str, needle: str, label: str) -> None:
    result = psql(sql, check=False)
    if result.returncode == 0 or needle not in result.stderr:
        raise AssertionError(
            f"{label}: expected error containing {needle!r}; "
            f"returncode={result.returncode}; stdout={result.stdout}; stderr={result.stderr}"
        )


def register_work(project_id: str, identity: str) -> str:
    request = str(uuid4())
    result = scalar(
        "SELECT work_id::text || '|' || outcome FROM aep.register_work("
        f"{lit(project_id)}::uuid,{lit(request)},{lit(str(uuid4()))}::uuid,"
        f"'stage2a',{lit(identity)},1,'implementation',{lit(identity)},'{{}}'::jsonb,NULL);"
    )
    return result.split("|", 1)[0]


def ready_work(project_id: str, identity: str) -> str:
    work_id = register_work(project_id, identity)
    psql(f"UPDATE aep.works SET status='ready' WHERE work_id={lit(work_id)}::uuid;")
    return work_id


def approved_project_grant(project_id: str, resource_id: str, label: str) -> str:
    decision_id = scalar(
        "INSERT INTO aep.owner_decisions("
        "scope_type,scope_key,decision_key,statement,decision_version,status,"
        "approval_source_kind,approval_source_ref,approver_principal,"
        "approval_provenance,approved_at"
        ") VALUES("
        f"'project',{lit(project_id)},{lit('stage2a-write-'+label)},"
        f"{lit('Approved write access for '+label)},1,'approved',"
        "'direct_owner_message','test://owner/stage2a-write','test-owner',"
        "jsonb_build_object('direct_owner_confirmation',true),clock_timestamp()"
        ") RETURNING decision_id;"
    )
    psql(
        "INSERT INTO aep.project_resources(project_id,resource_id,access_mode,status,"
        "grant_version,grant_decision_id) VALUES("
        f"{lit(project_id)}::uuid,{lit(resource_id)}::uuid,'write','active',1,"
        f"{lit(decision_id)}::uuid);"
    )
    return decision_id


def add_resource(resource_id: str, stable_id: str) -> None:
    psql(
        "INSERT INTO aep.resources(resource_id,provider,host,resource_type,"
        "stable_resource_id,canonical_key,display_name) VALUES("
        f"{lit(resource_id)}::uuid,'github','github.com','repository',"
        f"{lit(stable_id)},{lit('repository:'+stable_id)},{lit('Stage 2A '+stable_id)});"
    )


def add_requirement(project_id: str, work_id: str, resource_id: str, ref: str) -> None:
    psql(
        "INSERT INTO aep.work_resource_requirements("
        "project_id,work_id,resource_id,resource_ref,write_set_kind,conflict_key"
        ") VALUES("
        f"{lit(project_id)}::uuid,{lit(work_id)}::uuid,{lit(resource_id)}::uuid,"
        f"{lit(ref)},'repository_ref','*');"
    )


def claim_sql(work_id: str, session_id: str, seconds: int) -> str:
    return (
        "SELECT execution_id::text || '|' || attempt_no::text || '|' || fence::text "
        "|| '|' || lease_until::text || '|' || work_version::text "
        "FROM aep.claim_work("
        f"{lit(work_id)}::uuid,{lit(session_id)}::uuid,{seconds});"
    )


def install_rendezvous() -> None:
    psql("""
      CREATE OR REPLACE FUNCTION public.aep_test_claim_rendezvous(
        p_work_id uuid, p_session_id uuid, p_lease_seconds integer
      ) RETURNS TABLE(
        execution_id uuid, attempt_no integer, fence bigint,
        lease_until timestamptz, work_version bigint
      )
      LANGUAGE plpgsql
      SET search_path=pg_catalog,aep,public
      AS $test$
      BEGIN
        PERFORM pg_advisory_xact_lock_shared(21473,98121);
        RETURN QUERY SELECT * FROM aep.claim_work(
          p_work_id,p_session_id,p_lease_seconds
        );
      END
      $test$;
    """)


def race_claims(work_ids: list[str], lease_seconds: int = 60, *, serializable: bool = False) -> list[subprocess.CompletedProcess[str]]:
    """Release two independent PostgreSQL connections from one DB-side barrier."""
    env = os.environ.copy()
    env["PGPASSWORD"] = PASSWORD
    cmd = ["psql", "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1",
           "-h", HOST, "-p", PORT, "-U", USER, "-d", DATABASE]
    controller = subprocess.Popen(
        cmd, text=True, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, env=env, bufsize=1,
    )
    workers: list[subprocess.Popen[str]] = []
    results: list[subprocess.CompletedProcess[str]] = []
    try:
        assert controller.stdin is not None and controller.stdout is not None
        controller.stdin.write(
            "SELECT pg_backend_pid(); SELECT pg_advisory_lock(21473,98121);\n"
        )
        controller.stdin.flush()
        ready, _, _ = select.select([controller.stdout], [], [], 10)
        if not ready:
            raise AssertionError("claim race controller did not return its backend PID")
        pid_text = controller.stdout.readline().strip()
        if not pid_text.isdigit():
            raise AssertionError(f"claim race controller returned invalid PID: {pid_text!r}")
        controller_pid = int(pid_text)

        for work_id in work_ids:
            sql = (
                "SELECT execution_id::text || '|' || attempt_no::text || '|' "
                "|| fence::text || '|' || lease_until::text || '|' || work_version::text "
                "FROM public.aep_test_claim_rendezvous("
                f"{lit(work_id)}::uuid,{lit(str(uuid4()))}::uuid,{lease_seconds});"
            )
            if serializable:
                sql = "BEGIN ISOLATION LEVEL SERIALIZABLE; " + sql + " COMMIT;"
            workers.append(subprocess.Popen(
                cmd + ["-c", sql], text=True, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, env=env,
            ))

        deadline = time.monotonic() + 15
        waiting = "0"
        while time.monotonic() < deadline:
            if any(proc.poll() is not None for proc in workers):
                raise AssertionError("a claim worker exited before reaching the rendezvous")
            waiting = scalar(
                "SELECT count(*) FROM pg_stat_activity "
                f"WHERE pid <> {controller_pid} AND datname=current_database() "
                "AND wait_event_type='Lock' AND wait_event='advisory' "
                "AND query LIKE '%aep_test_claim_rendezvous%';"
            )
            if waiting == str(len(workers)):
                break
            time.sleep(0.05)
        if waiting != str(len(workers)):
            raise AssertionError(
                f"expected {len(workers)} independent connections at advisory barrier; saw {waiting}"
            )

        controller.stdin.close()
        controller.wait(timeout=10)
        controller.stdout.read()
        controller.stderr.read()

        for proc in workers:
            out, err = proc.communicate(timeout=30)
            results.append(subprocess.CompletedProcess(proc.args, proc.returncode, out, err))
    finally:
        if controller.poll() is None:
            controller.terminate()
            controller.wait(timeout=5)
        for proc in workers:
            if proc.poll() is None:
                proc.terminate()
                proc.communicate(timeout=5)
    return results


def parse_claim(result: subprocess.CompletedProcess[str]) -> tuple[str, int, int, str, int]:
    if result.returncode != 0:
        raise AssertionError(f"claim unexpectedly failed: {result.stderr}")
    rows = [line.strip() for line in result.stdout.splitlines() if "|" in line]
    if len(rows) != 1:
        raise AssertionError(f"expected one claim row, got {result.stdout!r}")
    execution_id, attempt, fence, lease_until, work_version = rows[0].split("|", 4)
    return execution_id, int(attempt), int(fence), lease_until, int(work_version)

def test_live_lease_boundary_race(work_id: str, current: tuple[str, int, int, str, int]) -> None:
    """Queue renewal and takeover behind one Work lock, then release after expiry."""
    env = os.environ.copy()
    env["PGPASSWORD"] = PASSWORD
    cmd = ["psql", "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1",
           "-h", HOST, "-p", PORT, "-U", USER, "-d", DATABASE]
    holder = subprocess.Popen(
        cmd, text=True, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, env=env, bufsize=1,
    )
    renew = None
    takeover = None
    try:
        assert holder.stdin is not None and holder.stdout is not None
        holder.stdin.write(
            "BEGIN; "
            f"SELECT work_id::text FROM aep.works WHERE work_id={lit(work_id)}::uuid FOR UPDATE;\n"
        )
        holder.stdin.flush()
        ready, _, _ = select.select([holder.stdout], [], [], 10)
        if not ready:
            raise AssertionError("Work lock holder did not return the locked Work ID")
        locked_work = holder.stdout.readline().strip()
        if locked_work != work_id:
            raise AssertionError(f"Work lock holder returned unexpected Work ID: {locked_work!r}")

        renew_sql = (
            "SELECT work_version::text FROM aep.renew_execution("
            f"{lit(work_id)}::uuid,{lit(current[0])}::uuid,{current[2]},"
            f"{current[4]},60);"
        )
        takeover_sql = claim_sql(work_id, str(uuid4()), 60)
        renew = subprocess.Popen(cmd + ["-c", renew_sql], text=True,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        takeover = subprocess.Popen(cmd + ["-c", takeover_sql], text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)

        deadline = time.monotonic() + 10
        blocked = "0"
        while time.monotonic() < deadline:
            blocked = scalar(
                "SELECT count(*) FROM pg_stat_activity "
                "WHERE datname=current_database() AND wait_event_type='Lock' "
                "AND (query LIKE '%renew_execution%' OR query LIKE '%claim_work%');"
            )
            if blocked == "2":
                break
            if renew.poll() is not None or takeover.poll() is not None:
                renew_out, renew_err = renew.communicate(timeout=5)
                takeover_out, takeover_err = takeover.communicate(timeout=5)
                raise AssertionError(
                    "lease-boundary contender exited while Work lock was held: "
                    f"renew={renew.returncode}/{renew_out}/{renew_err}; "
                    f"takeover={takeover.returncode}/{takeover_out}/{takeover_err}"
                )
            time.sleep(0.05)
        if blocked != "2":
            raise AssertionError(f"expected renewal and takeover to wait on Work row; saw {blocked}")

        # Do not release the Work lock until PostgreSQL confirms the stored lease
        # has actually crossed the expiry boundary.
        deadline = time.monotonic() + 10
        expired = "f"
        while time.monotonic() < deadline:
            expired = scalar(
                "SELECT (lease_until <= clock_timestamp())::text "
                f"FROM aep.executions WHERE execution_id={lit(current[0])}::uuid;"
            )
            if expired == "true":
                break
            time.sleep(0.05)
        if expired != "true":
            raise AssertionError("the queued Work lease did not reach its expiry boundary")

        holder.stdin.write("COMMIT;\n")
        holder.stdin.flush()
        holder.stdin.close()
        holder.wait(timeout=10)
        holder.stdout.read()
        holder.stderr.read()

        renew_out, renew_err = renew.communicate(timeout=10)
        takeover_out, takeover_err = takeover.communicate(timeout=10)
        if renew.returncode == 0 or not any(
            reason in renew_err
            for reason in (
                "expired lease",
                "stale, superseded",
                "Work version changed",
            )
        ):
            raise AssertionError(f"expired/stale renewal was not rejected: {renew_out}/{renew_err}")
        if takeover.returncode != 0:
            raise AssertionError(f"expired lease takeover failed: {takeover_out}/{takeover_err}")
        new_claim = parse_claim(subprocess.CompletedProcess(
            takeover.args, takeover.returncode, takeover_out, takeover_err
        ))
        if new_claim[2] != current[2] + 1 or new_claim[0] == current[0]:
            raise AssertionError(f"lease-boundary takeover did not advance the fence: {current}/{new_claim}")
        state = scalar(
            "SELECT status || '|' || current_execution_id::text || '|' "
            "|| fence_generation::text || '|' || version::text "
            f"FROM aep.works WHERE work_id={lit(work_id)}::uuid;"
        )
        if state != f"running|{new_claim[0]}|{new_claim[2]}|{new_claim[4]}":
            raise AssertionError(f"lease-boundary race produced incoherent Work state: {state}")
        print("PASS lease boundary: after expiry, serialized takeover wins and queued renewal is rejected")
    finally:
        if holder.poll() is None:
            holder.terminate()
            holder.wait(timeout=5)
        if holder.stdin is not None and not holder.stdin.closed:
            holder.stdin.close()
        if holder.stdout is not None:
            holder.stdout.close()
        if holder.stderr is not None:
            holder.stderr.close()
        for proc in (renew, takeover):
            if proc is not None and proc.poll() is None:
                proc.terminate()
                proc.communicate(timeout=5)


def main() -> None:
    migration_paths = sorted(MIGRATIONS.glob("*.sql"))
    versions = []
    for path in migration_paths:
        match = re.fullmatch(r"(\d{4})_[a-z0-9_]+\.sql", path.name)
        if not match:
            raise SystemExit(f"Invalid migration filename: {path.name}")
        versions.append(int(match.group(1)))
    if versions != list(range(1, len(versions) + 1)) or versions[-1] != 5:
        raise SystemExit(f"Expected contiguous migrations 0001..0005, got {versions}")

    psql("DROP DATABASE IF EXISTS aep_stage2a_test WITH (FORCE);", db="postgres")
    psql("CREATE DATABASE aep_stage2a_test;", db="postgres")
    version = scalar("SELECT current_setting('server_version');")
    if not version.startswith("17.12"):
        raise AssertionError(f"Stage 2A requires the CI-pinned PostgreSQL 17.12 image; got {version}")
    print(f"INFO Stage 2A disposable database: PostgreSQL {version}")
    for path in migration_paths:
        psql(file=path)
    print("PASS T26: clean ordered migration chain 0001-0005 applied on PostgreSQL 17.12")

    project_a = scalar(
        "INSERT INTO aep.projects(project_key,name) VALUES('stage2a-a','Stage 2A A') RETURNING project_id;"
    )
    project_b = scalar(
        "INSERT INTO aep.projects(project_key,name) VALUES('stage2a-b','Stage 2A B') RETURNING project_id;"
    )
    install_rendezvous()

    # T04: two independent connections start together and contend for one READY Work.
    t04_work = ready_work(project_a, "t04-single-work")
    t04_results = race_claims([t04_work, t04_work], lease_seconds=60)
    t04_successes = [result for result in t04_results if result.returncode == 0]
    t04_failures = [result for result in t04_results if result.returncode != 0]
    if len(t04_successes) != 1 or len(t04_failures) != 1:
        raise AssertionError(
            "T04 requires exactly one winner and one rejected claimant: "
            + repr([(x.returncode, x.stdout, x.stderr) for x in t04_results])
        )
    if "live execution lease" not in t04_failures[0].stderr:
        raise AssertionError(f"T04 losing connection did not observe the live lease: {t04_failures[0].stderr}")
    t04_claim = parse_claim(t04_successes[0])
    t04_state = scalar(
        "SELECT work_row.status || '|' || work_row.current_execution_id::text || '|' "
        "|| work_row.fence_generation::text || '|' || count(execution_row.execution_id)::text "
        "FROM aep.works AS work_row JOIN aep.executions AS execution_row "
        "ON execution_row.work_id=work_row.work_id AND execution_row.status IN ('claimed','running') "
        f"WHERE work_row.work_id={lit(t04_work)}::uuid "
        "GROUP BY work_row.status,work_row.current_execution_id,work_row.fence_generation;"
    )
    if t04_state != f"running|{t04_claim[0]}|1|1":
        raise AssertionError(f"T04 Work/current execution/fence projection is incoherent: {t04_state}")
    print("PASS T04: two independent PostgreSQL connections produced exactly one current execution")

    # A renewal and takeover both queue behind a Work-row lock. Before the lease
    # expiry, the renewal may extend it but the takeover must never steal it.
    boundary_work = ready_work(project_a, "lease-boundary-race")
    boundary_claim = parse_claim(psql(claim_sql(boundary_work, str(uuid4()), 1)))
    test_live_lease_boundary_race(boundary_work, boundary_claim)

    # Under SERIALIZABLE, a stale-snapshot worker aborts with 40001. Retry a whole
    # new transaction; it must observe the single committed current owner.
    serializable_work = ready_work(project_a, "serializable-claim-race")
    serializable_results = race_claims([serializable_work, serializable_work], lease_seconds=60, serializable=True)
    serializable_successes = [result for result in serializable_results if result.returncode == 0]
    serializable_failures = [result for result in serializable_results if result.returncode != 0]
    if len(serializable_successes) != 1 or len(serializable_failures) != 1:
        raise AssertionError("SERIALIZABLE race did not leave exactly one committed claim")
    if "could not serialize access" not in serializable_failures[0].stderr.lower():
        raise AssertionError(f"SERIALIZABLE loser did not return retryable 40001: {serializable_failures[0].stderr}")
    retry_result = psql(claim_sql(serializable_work, str(uuid4()), 60), check=False)
    if retry_result.returncode == 0 or "live execution lease" not in retry_result.stderr:
        raise AssertionError("whole-transaction retry did not observe the single current lease")
    if scalar(f"SELECT count(*) FROM aep.executions WHERE work_id={lit(serializable_work)}::uuid;") != "1":
        raise AssertionError("SERIALIZABLE retry created a duplicate Execution")
    print("PASS isolation: SERIALIZABLE conflict returns retryable 40001; whole-transaction retry observes the committed owner")

    # T05: expiry is checked after locking; takeover increments fence, and the old
    # execution cannot renew or finish even when supplied the latest Work version.
    t05_resource = "00000000-0000-0000-0000-000000000100"
    add_resource(t05_resource, "stage2a-takeover-100")
    approved_project_grant(project_a, t05_resource, "takeover-100")
    t05_work = ready_work(project_a, "t05-takeover")
    add_requirement(project_a, t05_work, t05_resource, "refs/heads/t05-takeover")
    initial = parse_claim(
        psql(claim_sql(t05_work, str(uuid4()), 1))
    )
    time.sleep(1.15)
    expect_error(
        "SELECT * FROM aep.renew_execution("
        f"{lit(t05_work)}::uuid,{lit(initial[0])}::uuid,{initial[2]},"
        f"{initial[4]},60);",
        "expired lease",
        "T05 expired execution renewal",
    )
    takeover = parse_claim(
        psql(claim_sql(t05_work, str(uuid4()), 60))
    )
    if takeover[1] != 2 or takeover[2] != initial[2] + 1 or takeover[0] == initial[0]:
        raise AssertionError(f"T05 takeover did not create a new attempt and monotonic fence: {initial}/{takeover}")
    old_status = scalar(
        f"SELECT status FROM aep.executions WHERE execution_id={lit(initial[0])}::uuid;"
    )
    if old_status != "expired":
        raise AssertionError(f"T05 prior execution was not marked expired: {old_status}")
    old_claim_status = scalar(
        f"SELECT status || '|' || (released_at IS NOT NULL)::text FROM aep.resource_claims "
        f"WHERE execution_id={lit(initial[0])}::uuid;"
    )
    new_claim_status = scalar(
        f"SELECT status FROM aep.resource_claims WHERE execution_id={lit(takeover[0])}::uuid;"
    )
    if old_claim_status != "expired|true" or new_claim_status != "active":
        raise AssertionError(f"T05 takeover did not expire/recreate resource claims: {old_claim_status}/{new_claim_status}")
    expect_error(
        "SELECT * FROM aep.renew_execution("
        f"{lit(t05_work)}::uuid,{lit(initial[0])}::uuid,{initial[2]},"
        f"{takeover[4]},60);",
        "stale, superseded",
        "T05 stale renewal after takeover",
    )
    expect_error(
        "SELECT * FROM aep.finish_execution("
        f"{lit(t05_work)}::uuid,{lit(initial[0])}::uuid,{initial[2]},"
        f"{takeover[4]},'succeeded','{{}}'::jsonb);",
        "stale, superseded",
        "T05 stale completion after takeover",
    )
    renewed_text = scalar(
        "SELECT lease_until::text || '|' || work_version::text "
        "FROM aep.renew_execution("
        f"{lit(t05_work)}::uuid,{lit(takeover[0])}::uuid,{takeover[2]},"
        f"{takeover[4]},60);"
    )
    renewed_lease, renewed_version_text = renewed_text.split("|", 1)
    renewed_version = int(renewed_version_text)
    if renewed_version != takeover[4] + 1:
        raise AssertionError(f"T05 valid renewal did not advance Work version: {renewed_text}")
    completed = scalar(
        "SELECT work_status || '|' || work_version::text "
        "FROM aep.finish_execution("
        f"{lit(t05_work)}::uuid,{lit(takeover[0])}::uuid,{takeover[2]},"
        f"{renewed_version},'succeeded',jsonb_build_object('test','T05'));"
    )
    if not completed.startswith("delivered|"):
        raise AssertionError(f"T05 current-fence completion failed: {completed}")
    final_t05 = scalar(
        f"SELECT status || '|' || COALESCE(current_execution_id::text,'null') "
        f"|| '|' || fence_generation::text FROM aep.works WHERE work_id={lit(t05_work)}::uuid;"
    )
    if final_t05 != f"delivered|null|{takeover[2]}":
        raise AssertionError(f"T05 terminal Work projection is incorrect: {final_t05}")
    if scalar(
        f"SELECT status || '|' || (lease_until IS NULL)::text || '|' || (released_at IS NOT NULL)::text "
        f"FROM aep.resource_claims WHERE execution_id={lit(takeover[0])}::uuid;"
    ) != "released|true|true":
        raise AssertionError("T05 successful completion did not release the current resource claim")
    print("PASS T05: expired takeover advances fence; stale renewal/completion rejected; current renew/complete accepted")

    # Resource fixtures use ordered UUIDs so the test can reverse requirement
    # insertion order while the protocol must still acquire locks canonically.
    resource_1 = "00000000-0000-0000-0000-000000000101"
    resource_2 = "00000000-0000-0000-0000-000000000102"
    add_resource(resource_1, "stage2a-shared-101")
    add_resource(resource_2, "stage2a-shared-102")
    for project_id, suffix in ((project_a, "a"), (project_b, "b")):
        approved_project_grant(project_id, resource_1, "shared-101-"+suffix)
        approved_project_grant(project_id, resource_2, "shared-102-"+suffix)

    t06_a = ready_work(project_a, "t06-resource-race-a")
    t06_b = ready_work(project_b, "t06-resource-race-b")
    add_requirement(project_a, t06_a, resource_1, "refs/heads/stage-2a-conflict")
    add_requirement(project_a, t06_a, resource_2, "refs/heads/stage-2a-conflict")
    # Reverse declaration order. Claim must still lock resources by UUID.
    add_requirement(project_b, t06_b, resource_2, "refs/heads/stage-2a-conflict")
    add_requirement(project_b, t06_b, resource_1, "refs/heads/stage-2a-conflict")

    # T06: two different Work/projects contend for the same two physical resources.
    t06_results = race_claims([t06_a, t06_b], lease_seconds=60)
    t06_successes = [result for result in t06_results if result.returncode == 0]
    t06_failures = [result for result in t06_results if result.returncode != 0]
    if len(t06_successes) != 1 or len(t06_failures) != 1:
        raise AssertionError(
            "T06 requires exactly one physical-resource winner: "
            + repr([(x.returncode, x.stdout, x.stderr) for x in t06_results])
        )
    if "already reserved" not in t06_failures[0].stderr:
        raise AssertionError(f"T06 loser did not observe the physical resource conflict: {t06_failures[0].stderr}")
    t06_claim = parse_claim(t06_successes[0])
    winner_work = t06_a if scalar(
        f"SELECT current_execution_id::text FROM aep.works WHERE work_id={lit(t06_a)}::uuid;"
    ) == t06_claim[0] else t06_b
    loser_work = t06_b if winner_work == t06_a else t06_a
    if scalar(
        "SELECT count(*) FROM aep.resource_claims "
        f"WHERE execution_id={lit(t06_claim[0])}::uuid AND status='active';"
    ) != "2":
        raise AssertionError("T06 winner did not atomically reserve the complete two-resource set")
    loser_state = scalar(
        "SELECT status || '|' || COALESCE(current_execution_id::text,'null') "
        "|| '|' || fence_generation::text || '|' || "
        "(SELECT count(*)::text FROM aep.executions WHERE work_id=works.work_id) "
        f"FROM aep.works WHERE work_id={lit(loser_work)}::uuid;"
    )
    if loser_state != "ready|null|0|0":
        raise AssertionError(f"T06 losing Work contains partial Execution/state/fence: {loser_state}")
    print("PASS T06: cross-project physical-resource race has one winner; reversed resource order does not deadlock")

    # Rollback fault injection fails on the second ResourceClaim INSERT, after the
    # function has inserted Execution and updated Work. All changes must roll back.
    rollback_resource_1 = "00000000-0000-0000-0000-000000000103"
    rollback_resource_2 = "00000000-0000-0000-0000-000000000104"
    add_resource(rollback_resource_1, "stage2a-rollback-103")
    add_resource(rollback_resource_2, "stage2a-rollback-104")
    approved_project_grant(project_a, rollback_resource_1, "rollback-103")
    approved_project_grant(project_a, rollback_resource_2, "rollback-104")
    rollback_work = ready_work(project_a, "resource-reservation-forced-rollback")
    add_requirement(project_a, rollback_work, rollback_resource_1, "refs/heads/first-reservation")
    add_requirement(project_a, rollback_work, rollback_resource_2, "refs/heads/force-failure")
    psql("""
      CREATE FUNCTION public.aep_test_reject_second_claim()
      RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog
      AS $test$
      BEGIN
        IF NEW.resource_ref = 'refs/heads/force-failure' THEN
          RAISE EXCEPTION 'forced second reservation failure';
        END IF;
        RETURN NEW;
      END
      $test$;
      CREATE TRIGGER aep_test_reject_second_claim
      BEFORE INSERT ON aep.resource_claims
      FOR EACH ROW EXECUTE FUNCTION public.aep_test_reject_second_claim();
    """)
    expect_error(
        claim_sql(rollback_work, str(uuid4()), 60),
        "forced second reservation failure",
        "resource reservation fault injection",
    )
    psql(
        "DROP TRIGGER aep_test_reject_second_claim ON aep.resource_claims; "
        "DROP FUNCTION public.aep_test_reject_second_claim();"
    )
    rollback_state = scalar(
        "SELECT status || '|' || COALESCE(current_execution_id::text,'null') "
        "|| '|' || fence_generation::text || '|' || "
        "(SELECT count(*)::text FROM aep.executions WHERE work_id=works.work_id) "
        f"FROM aep.works WHERE work_id={lit(rollback_work)}::uuid;"
    )
    rollback_claims = scalar(
        "SELECT count(*) FROM aep.resource_claims "
        f"WHERE work_id={lit(rollback_work)}::uuid;"
    )
    if rollback_state != "ready|null|0|0" or rollback_claims != "0":
        raise AssertionError(
            f"failed reservation left partial state: {rollback_state}; claims={rollback_claims}"
        )
    print("PASS rollback: failure on the second reservation rolls back Execution, Work status, fence, and all claims")

    # An execution with active reservations releases the complete set atomically
    # when failed. This is also the current-execution failure path for T06.
    winner_version = int(scalar(
        f"SELECT version FROM aep.works WHERE work_id={lit(winner_work)}::uuid;"
    ))
    failed = scalar(
        "SELECT work_status || '|' || work_version::text "
        "FROM aep.finish_execution("
        f"{lit(winner_work)}::uuid,{lit(t06_claim[0])}::uuid,{t06_claim[2]},"
        f"{winner_version},'failed',jsonb_build_object('test','T06-failure'));"
    )
    if not failed.startswith("failed|"):
        raise AssertionError(f"current execution failure transition failed: {failed}")
    released = scalar(
        "SELECT count(*) FROM aep.resource_claims "
        f"WHERE execution_id={lit(t06_claim[0])}::uuid AND status='released' "
        "AND lease_until IS NULL AND released_at IS NOT NULL;"
    )
    winner_status = scalar(
        f"SELECT status FROM aep.works WHERE work_id={lit(winner_work)}::uuid;"
    )
    if released != "2" or winner_status != "failed":
        raise AssertionError(
            f"failure did not atomically release every reservation: released={released}; work={winner_status}"
        )
    print("PASS lifecycle: current-fence failure releases every physical resource claim atomically")

    # Active write links cannot be created without a currently approved and
    # correctly-scoped OwnerDecision. Requirements cannot request unsupported
    # path overlap or provider-undefined refs.
    invalid_resource = "00000000-0000-0000-0000-000000000105"
    add_resource(invalid_resource, "stage2a-invalid-grant-105")
    expect_error(
        "INSERT INTO aep.project_resources(project_id,resource_id,access_mode) VALUES("
        f"{lit(project_a)}::uuid,{lit(invalid_resource)}::uuid,'write');",
        "Active write ProjectResource requires an approved, correctly-scoped OwnerDecision",
        "unapproved ProjectResource write grant",
    )
    invalid_work = ready_work(project_a, "invalid-requirement-contract")
    expect_error(
        "INSERT INTO aep.work_resource_requirements(project_id,work_id,resource_id,resource_ref,"
        "write_set_kind,conflict_key) VALUES("
        f"{lit(project_a)}::uuid,{lit(invalid_work)}::uuid,{lit(invalid_resource)}::uuid,"
        "'main','repository_ref','*');",
        "WorkResourceRequirement requires an active GitHub repository and canonical fully-qualified branch ref",
        "non-canonical required branch ref",
    )
    expect_error(
        "INSERT INTO aep.work_resource_requirements(project_id,work_id,resource_id,resource_ref,"
        "write_set_kind,conflict_key) VALUES("
        f"{lit(project_a)}::uuid,{lit(invalid_work)}::uuid,{lit(invalid_resource)}::uuid,"
        "'refs/heads/paths','path_set','path:/src');",
        "work_resource_requirements_write_set_kind_check",
        "unsupported path-overlap requirement",
    )
    psql(
        "UPDATE aep.owner_decisions SET status='revoked' "
        "WHERE decision_key='stage2a-write-shared-101-a';"
    )
    invalid_grant_work = ready_work(project_a, "revoked-resource-grant")
    # The revoked ProjectResource link remains structurally present; claim must
    # fail closed before creating an Execution.
    add_requirement(project_a, invalid_grant_work, resource_1, "refs/heads/revoked-grant")
    expect_error(
        claim_sql(invalid_grant_work, str(uuid4()), 60),
        "not approved or is out of scope",
        "claim with revoked ProjectResource OwnerDecision",
    )
    if scalar(
        "SELECT count(*) FROM aep.executions "
        f"WHERE work_id={lit(invalid_grant_work)}::uuid;"
    ) != "0":
        raise AssertionError("revoked grant failure left an Execution row")
    print("PASS authorization: active ProjectResource and approved scoped grant required; unsupported write sets fail closed")

    # Security-definer entry points are narrowly exposed; every definer routine
    # has the non-bypass owner and a fixed search_path, with RLS forced on tables.
    security = scalar("""
      SELECT count(*) FROM pg_proc AS proc
      JOIN pg_namespace AS ns ON ns.oid=proc.pronamespace
      JOIN pg_roles AS owner_role ON owner_role.oid=proc.proowner
      WHERE ns.nspname='aep'
        AND proc.proname IN (
          'claim_work','renew_execution','finish_execution',
          'guard_work_resource_requirement','guard_project_resource_write_grant',
          'guard_approved_grant_decision_mutation','guard_resource_archive'
        )
        AND proc.prosecdef
        AND owner_role.rolname='aep_owner'
        AND NOT owner_role.rolsuper
        AND NOT owner_role.rolbypassrls
        AND replace(array_to_string(proc.proconfig,','),' ','')='search_path=pg_catalog,aep'
        AND NOT COALESCE((
          SELECT bool_or(acl.grantee=0 AND acl.privilege_type='EXECUTE')
          FROM aclexplode(COALESCE(proc.proacl,acldefault('f',proc.proowner))) AS acl
        ),false);
    """)
    if security != "7":
        raise AssertionError(f"SECURITY DEFINER owner/search_path/PUBLIC audit failed: {security}/7")
    all_definers = scalar("""
      SELECT count(*) FROM pg_proc AS proc
      JOIN pg_namespace AS ns ON ns.oid=proc.pronamespace
      JOIN pg_roles AS owner_role ON owner_role.oid=proc.proowner
      WHERE ns.nspname='aep' AND proc.prosecdef
        AND owner_role.rolname='aep_owner'
        AND NOT owner_role.rolsuper AND NOT owner_role.rolbypassrls
        AND replace(array_to_string(proc.proconfig,','),' ','')='search_path=pg_catalog,aep'
        AND NOT COALESCE((
          SELECT bool_or(acl.grantee=0 AND acl.privilege_type='EXECUTE')
          FROM aclexplode(COALESCE(proc.proacl,acldefault('f',proc.proowner))) AS acl
        ),false);
    """)
    if all_definers != "8":
        raise AssertionError(f"Not every SECURITY DEFINER in schema aep meets owner/path/PUBLIC rules: {all_definers}/8")
    runtime_grants = scalar("""
      SELECT
        has_function_privilege('aep_runtime','aep.set_work_resource_requirements(uuid,jsonb)','EXECUTE')::text
        || '|' || has_function_privilege('aep_runtime','aep.claim_work(uuid,uuid,integer)','EXECUTE')::text
        || '|' || has_function_privilege('aep_runtime','aep.renew_execution(uuid,uuid,bigint,bigint,integer)','EXECUTE')::text
        || '|' || has_function_privilege('aep_runtime','aep.finish_execution(uuid,uuid,bigint,bigint,text,jsonb)','EXECUTE')::text
        || '|' || has_function_privilege('aep_runtime','aep.guard_work_resource_requirement()','EXECUTE')::text
        || '|' || has_function_privilege('aep_runtime','aep.guard_project_resource_write_grant()','EXECUTE')::text
        || '|' || has_function_privilege('aep_runtime','aep.guard_approved_grant_decision_mutation()','EXECUTE')::text
        || '|' || has_function_privilege('aep_runtime','aep.guard_resource_archive()','EXECUTE')::text
        || '|' || has_table_privilege('aep_runtime','aep.work_resource_requirements','SELECT')::text
        || '|' || has_table_privilege('aep_runtime','aep.executions','SELECT')::text
        || '|' || has_table_privilege('aep_runtime','aep.resource_claims','SELECT')::text
        || '|' || (
          SELECT bool_and(relrowsecurity AND relforcerowsecurity)::text
          FROM pg_class
          WHERE oid IN (
            'aep.work_resource_requirements'::regclass,
            'aep.works'::regclass,
            'aep.executions'::regclass,
            'aep.resource_claims'::regclass
          )
        );
    """)
    if runtime_grants != "true|true|true|true|false|false|false|false|false|false|false|true":
        raise AssertionError(f"Runtime grants/RLS boundary failed: {runtime_grants}")
    runtime_work = ready_work(project_a, "runtime-rpc-only")
    runtime_requirement_count = scalar(
        "SET ROLE aep_runtime; "
        "SELECT aep.set_work_resource_requirements("
        f"{lit(runtime_work)}::uuid,"
        f"jsonb_build_array(jsonb_build_object('resource_id',{lit(resource_2)},"
        "'resource_ref','refs/heads/runtime-rpc'))); RESET ROLE;"
    )
    if runtime_requirement_count != "1":
        raise AssertionError(f"runtime requirement declaration RPC did not create one row: {runtime_requirement_count}")
    expect_error(
        "SET ROLE aep_runtime; "
        "SELECT aep.set_work_resource_requirements("
        f"{lit(runtime_work)}::uuid,"
        f"jsonb_build_array(jsonb_build_object('resource_id',{lit(resource_2)},"
        "'resource_ref','refs/heads/a-valid'),"
        f"jsonb_build_object('resource_id',{lit(resource_2)},'resource_ref','refs/heads/z-invalid.'))); RESET ROLE;",
        "work_resource_requirements_github_branch_ref_ck",
        "atomic rollback of invalid WorkResourceRequirement set replacement",
    )
    if scalar(
        "SELECT count(*) FROM aep.work_resource_requirements "
        f"WHERE work_id={lit(runtime_work)}::uuid "
        "AND resource_ref='refs/heads/runtime-rpc';"
    ) != "1":
        raise AssertionError("failed requirement replacement did not roll back the original declared set")
    runtime_result = scalar(
        "SET ROLE aep_runtime; "
        f"SELECT execution_id::text || '|' || fence::text || '|' || work_version::text "
        f"FROM aep.claim_work({lit(runtime_work)}::uuid,{lit(str(uuid4()))}::uuid,60); "
        "RESET ROLE;"
    )
    runtime_execution, runtime_fence_text, runtime_version_text = runtime_result.split("|", 2)
    runtime_fence = int(runtime_fence_text)
    runtime_version = int(runtime_version_text)
    runtime_renewed = scalar(
        "SET ROLE aep_runtime; "
        "SELECT work_version::text FROM aep.renew_execution("
        f"{lit(runtime_work)}::uuid,{lit(runtime_execution)}::uuid,{runtime_fence},"
        f"{runtime_version},60); RESET ROLE;"
    )
    runtime_version = int(runtime_renewed)
    runtime_finished = scalar(
        "SET ROLE aep_runtime; "
        "SELECT work_status FROM aep.finish_execution("
        f"{lit(runtime_work)}::uuid,{lit(runtime_execution)}::uuid,{runtime_fence},"
        f"{runtime_version},'succeeded','{{}}'::jsonb); RESET ROLE;"
    )
    if runtime_finished != "delivered":
        raise AssertionError(f"aep_runtime could not complete using the current execution fence: {runtime_finished}")
    # The runtime can call the returned narrow RPC but cannot inspect canonical tables.
    direct_read = psql("SET ROLE aep_runtime; SELECT count(*) FROM aep.works;", check=False)
    if direct_read.returncode == 0 or "permission denied" not in direct_read.stderr:
        raise AssertionError("aep_runtime unexpectedly received direct canonical-table access")
    print("PASS security: SECURITY DEFINER ownership, fixed paths, PUBLIC revocation, runtime EXECUTE, forced RLS and no direct reads")

    # Requirement declarations cannot be edited after the first claim attempt.
    expect_error(
        "DELETE FROM aep.work_resource_requirements "
        f"WHERE work_id={lit(winner_work)}::uuid;",
        "immutable after execution begins",
        "requirement mutation after execution",
    )
    print("PASS immutability: requirement set cannot be changed after execution starts")

    psql("DROP FUNCTION public.aep_test_claim_rendezvous(uuid,uuid,integer);")
    print("All Stage 2A PostgreSQL protocol tests passed.")


if __name__ == "__main__":
    main()
