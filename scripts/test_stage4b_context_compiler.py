#!/usr/bin/env python3
"""Stage 4B authorized Context Compiler tests on disposable PostgreSQL 17.12."""

from __future__ import annotations

import json
import os
import re
import subprocess
import time
from pathlib import Path
from uuid import uuid4

ROOT = Path(__file__).resolve().parents[1]
MIGRATIONS = ROOT / "db" / "prototype"
DATABASE = "aep_stage4b_context"
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
    if versions != list(range(1, 11)):
        raise SystemExit(f"Expected contiguous migrations 0001..0010, got {versions}")

    psql(f"DROP DATABASE IF EXISTS {DATABASE} WITH (FORCE);", db="postgres")
    psql(f"CREATE DATABASE {DATABASE};", db="postgres")
    version = scalar("SELECT current_setting('server_version');")
    if not version.startswith("17.12"):
        raise AssertionError(f"Stage 4B requires PostgreSQL 17.12; got {version}")
    for path in paths:
        psql(file=path)
    print("PASS T26: clean migrations 0001..0010 on PostgreSQL 17.12")


def test_runtime_access_boundary() -> None:
    functions = (
        "aep.record_context_source_revision(uuid,uuid,uuid,text,uuid,text,text,text,jsonb)",
        "aep.compile_context_pack(uuid,uuid,uuid,text,uuid,integer,text,text,text)",
        "aep.get_context_pack(uuid,uuid,integer,text,text,text)",
    )
    checks = [
        scalar(
            "SELECT has_function_privilege("
            f"'aep_runtime',{lit(function)},'EXECUTE')::text;"
        )
        for function in functions
    ]
    table_checks = [
        scalar(
            "SELECT has_table_privilege('aep_runtime',"
            f"{lit('aep.'+table)},'SELECT')::text;"
        )
        for table in ("context_source_heads","context_evidence_sizes","context_packs","context_retrieval_events")
    ]
    if checks != ["true","true","true"]:
        raise AssertionError(f"Runtime RPC grants are incorrect: {checks}")
    if table_checks != ["false","false","false","false"]:
        raise AssertionError(f"Runtime role has direct Context table access: {table_checks}")


def test_authorization_locks(project_id: str, resource_id: str, grant_decision_id: str) -> None:
    """A shared project advisory lock serializes grant/decision writers through commit."""
    cmd = [
        "psql", "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1",
        "-h", HOST, "-p", PORT, "-U", USER, "-d", DATABASE,
    ]
    env = os.environ.copy()
    env["PGPASSWORD"] = PASSWORD
    sql = (
        "BEGIN;\n"
        "SELECT aep.context_project_resource_allowed("
        f"{lit(project_id)}::uuid,{lit(resource_id)}::uuid);\n"
        "SELECT pg_sleep(2);\n"
        "COMMIT;\n"
    )
    holder = subprocess.Popen(
        cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, bufsize=1, env=env,
    )
    assert holder.stdin is not None and holder.stdout is not None
    holder.stdin.write(sql)
    holder.stdin.flush()
    holder.stdin.close()
    authorization_result = holder.stdout.readline().strip()
    if authorization_result != "t":
        holder.kill()
        holder.wait()
        raise AssertionError(
            f"authorization holder did not acquire an approved grant: {authorization_result!r}"
        )

    grant_revoke = psql(
        "SET lock_timeout='150ms'; "
        "UPDATE aep.project_resources SET status='revoked',"
        "revoked_at=clock_timestamp(),grant_version=grant_version+1 "
        f"WHERE project_id={lit(project_id)}::uuid "
        f"AND resource_id={lit(resource_id)}::uuid;",
        check=False,
    )
    decision_revoke = psql(
        "SET lock_timeout='150ms'; "
        "UPDATE aep.owner_decisions SET status='rejected' "
        f"WHERE decision_id={lit(grant_decision_id)}::uuid;",
        check=False,
    )
    holder.wait(timeout=10)
    holder_stdout = holder.stdout.read()
    holder_stderr = holder.stderr.read() if holder.stderr else ""
    if holder.returncode != 0:
        raise RuntimeError(f"authorization holder failed: {holder_stdout} {holder_stderr}")
    for label, attempt in (("ProjectResource revoke",grant_revoke),("OwnerDecision revoke",decision_revoke)):
        if attempt.returncode == 0 or "lock timeout" not in attempt.stderr.lower():
            raise AssertionError(
                f"{label} was not serialized behind the active authorized retrieval: "
                f"exit={attempt.returncode}, stderr={attempt.stderr}"
            )
    if scalar(
        "SELECT status FROM aep.project_resources "
        f"WHERE project_id={lit(project_id)}::uuid AND resource_id={lit(resource_id)}::uuid;"
    ) != "active":
        raise AssertionError("ProjectResource revoke unexpectedly committed during authorized retrieval")
    if scalar(
        "SELECT status FROM aep.owner_decisions "
        f"WHERE decision_id={lit(grant_decision_id)}::uuid;"
    ) != "approved":
        raise AssertionError("OwnerDecision revoke unexpectedly committed during authorized retrieval")


def test_authorization_lock_order(
    project_id: str, resource_id: str, grant_decision_id: str,
) -> None:
    """Prove resource→project readers cannot deadlock tuple-first resource writers."""
    cmd = [
        "psql", "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1",
        "-h", HOST, "-p", PORT, "-U", USER, "-d", DATABASE,
    ]

    def run_case(label: str, writer_sql: str) -> None:
        reader_env = os.environ.copy()
        reader_env["PGPASSWORD"] = PASSWORD
        reader = subprocess.Popen(
            cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, bufsize=1, env=reader_env,
        )
        assert reader.stdin is not None and reader.stdout is not None
        reader.stdin.write(
            "BEGIN;\n"
            "DO $ctx$ BEGIN "
            "PERFORM pg_advisory_xact_lock_shared(hashtextextended("
            f"'aep.context-resource:' || {lit(resource_id)}::text,0)); "
            "PERFORM pg_advisory_xact_lock_shared(hashtextextended("
            f"'aep.context-project:' || {lit(project_id)}::text,0)); "
            "END $ctx$;\n"
            "SELECT 'reader_ready';\n"
        )
        reader.stdin.flush()
        ready = reader.stdout.readline().strip()
        if ready != "reader_ready":
            reader.kill()
            reader.wait()
            raise AssertionError(f"{label}: reader failed to acquire shared project lock: {ready!r}")

        writer_app = "stage4b_lock_order_" + str(uuid4()).replace("-", "")
        writer_env = os.environ.copy()
        writer_env["PGPASSWORD"] = PASSWORD
        writer_env["PGAPPNAME"] = writer_app
        writer = subprocess.Popen(
            cmd + ["-c", writer_sql],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=writer_env,
        )

        try:
            deadline = time.monotonic() + 8
            waiting = False
            while time.monotonic() < deadline:
                if writer.poll() is not None:
                    out, err = writer.communicate()
                    raise AssertionError(
                        f"{label}: writer completed instead of waiting for the reader lock; "
                        f"exit={writer.returncode}, stdout={out}, stderr={err}"
                    )
                wait_count = scalar(
                    "SELECT count(*) FROM pg_stat_activity "
                    f"WHERE application_name={lit(writer_app)} "
                    "AND wait_event_type='Lock' AND wait_event='advisory';"
                )
                if wait_count == "1":
                    waiting = True
                    break
                time.sleep(0.05)
            if not waiting:
                writer.kill()
                writer.wait()
                raise AssertionError(f"{label}: writer never reached the expected advisory-lock wait")

            # The writer now owns its target tuple and waits on the exclusive
            # Resource lock. The reader already holds shared Resource then shared
            # Project locks, matching the production Context gate. Authorization
            # must use MVCC reads and never wait on the writer-held tuple.
            reader.stdin.write(
                "SELECT aep.context_project_resource_allowed("
                f"{lit(project_id)}::uuid,{lit(resource_id)}::uuid);\n"
                "COMMIT;\n"
            )
            reader.stdin.flush()
            reader.stdin.close()
            reader.wait(timeout=6)
            reader_output = reader.stdout.read()
            reader_error = reader.stderr.read() if reader.stderr else ""
            if reader.returncode != 0 or "t" not in reader_output.split():
                raise AssertionError(
                    f"{label}: authorization reader deadlocked or denied unexpectedly; "
                    f"exit={reader.returncode}, stdout={reader_output}, stderr={reader_error}"
                )

            writer.wait(timeout=6)
            writer_output = writer.stdout.read() if writer.stdout else ""
            writer_error = writer.stderr.read() if writer.stderr else ""
            if writer.returncode != 0:
                raise AssertionError(
                    f"{label}: queued writer failed after reader commit; "
                    f"exit={writer.returncode}, stdout={writer_output}, stderr={writer_error}"
                )
        finally:
            if reader.poll() is None:
                reader.kill()
                reader.wait()
            if writer.poll() is None:
                writer.kill()
                writer.wait()

    run_case(
        "ProjectResource tuple-lock ordering",
        "UPDATE aep.project_resources SET grant_version=grant_version "
        f"WHERE project_id={lit(project_id)}::uuid "
        f"AND resource_id={lit(resource_id)}::uuid;",
    )
    run_case(
        "OwnerDecision tuple-lock ordering",
        "UPDATE aep.owner_decisions SET statement=statement "
        f"WHERE decision_id={lit(grant_decision_id)}::uuid;",
    )



def _start_psql(
    application_name: str, sql: str, *, keep_stdin_open: bool = False,
) -> subprocess.Popen[str]:
    cmd = [
        "psql", "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1",
        "-h", HOST, "-p", PORT, "-U", USER, "-d", DATABASE,
    ]
    env = os.environ.copy()
    env["PGPASSWORD"] = PASSWORD
    env["PGAPPNAME"] = application_name
    proc = subprocess.Popen(
        cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, bufsize=1, env=env,
    )
    assert proc.stdin is not None
    proc.stdin.write(sql)
    proc.stdin.flush()
    if not keep_stdin_open:
        proc.stdin.close()
    return proc


def _wait_for_advisory_wait(application_name: str, timeout: float = 8.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if scalar(
            "SELECT count(*) FROM pg_stat_activity "
            f"WHERE application_name={lit(application_name)} "
            "AND wait_event_type='Lock' AND wait_event='advisory';"
        ) == "1":
            return
        time.sleep(0.05)
    raise AssertionError(f"{application_name} did not wait on an advisory lock")


def _new_resource() -> str:
    resource_id = str(uuid4())
    stable_id = "stage4b-resource-race-" + str(uuid4())
    psql(
        "INSERT INTO aep.resources(resource_id,provider,host,resource_type,"
        "stable_resource_id,canonical_key,display_name) VALUES("
        f"{lit(resource_id)}::uuid,'github','github.com','repository',"
        f"{lit(stable_id)},{lit('repository:'+stable_id)},'Resource race fixture');"
    )
    return resource_id


def _new_resource_decision(resource_id: str) -> str:
    return scalar(
        "INSERT INTO aep.owner_decisions("
        "scope_type,scope_key,decision_key,statement,decision_version,status,"
        "approval_source_kind,approval_source_ref,approver_principal,"
        "approval_provenance,approved_at"
        ") VALUES("
        f"'resource',{lit(resource_id)},'stage4b-resource-grant',"
        "'Temporary resource-scoped grant',1,'approved','direct_owner_message',"
        "'test://owner/stage4b-resource-race','test-owner',"
        "jsonb_build_object('direct_owner_confirmation',true),clock_timestamp()"
        ") RETURNING decision_id;"
    )


def test_resource_scope_serialization(existing_project_id: str) -> None:
    """Resource decision revocation and Resource updates serialize with new links."""
    resource_one = _new_resource()
    decision_one = _new_resource_decision(resource_one)
    psql(
        "INSERT INTO aep.project_resources("
        "project_id,resource_id,access_mode,status,grant_version,grant_decision_id"
        ") VALUES("
        f"{lit(existing_project_id)}::uuid,{lit(resource_one)}::uuid,"
        f"'write','active',1,{lit(decision_one)}::uuid);"
    )
    project_two = scalar(
        "INSERT INTO aep.projects(project_key,name) "
        "VALUES('stage4b-association-' || substr(gen_random_uuid()::text,1,8),"
        "'Stage 4B resource association race') RETURNING project_id;"
    )
    work_two = create_work(project_two, "Resource association race Work")
    session_two = str(uuid4())
    revoker_app = "stage4b_revoke_" + str(uuid4()).replace("-", "")
    assoc_app = "stage4b_assoc_" + str(uuid4()).replace("-", "")
    reader_app = "stage4b_assoc_reader_" + str(uuid4()).replace("-", "")

    revoker = _start_psql(
        revoker_app,
        "BEGIN;\n"
        "UPDATE aep.owner_decisions SET status='revoked' "
        f"WHERE decision_id={lit(decision_one)}::uuid;\n"
        "SELECT 'resource_decision_revoker_holds_lock';\n"
        "SELECT pg_sleep(2);\n"
        "COMMIT;\n",
    )
    assert revoker.stdout is not None
    if revoker.stdout.readline().strip() != "resource_decision_revoker_holds_lock":
        revoker.kill()
        revoker.wait()
        raise AssertionError("resource-scoped OwnerDecision update did not acquire its Resource lock")

    association = _start_psql(
        assoc_app,
        "BEGIN;\n"
        "INSERT INTO aep.project_resources("
        "project_id,resource_id,access_mode,status,grant_version,grant_decision_id"
        ") VALUES("
        f"{lit(project_two)}::uuid,{lit(resource_one)}::uuid,'write','active',1,"
        f"{lit(decision_one)}::uuid);\n"
        "SELECT 'resource_association_inserted';\nCOMMIT;\n",
    )
    reader = None
    try:
        _wait_for_advisory_wait(assoc_app)
        reader = _start_psql(
            reader_app,
            "SELECT aep.compile_context_pack("
            f"{lit(project_two)}::uuid,{lit(work_two)}::uuid,{lit(resource_one)}::uuid,"
            f"'refs/heads/main',{lit(session_two)}::uuid,8192,"
            "'context-compiler/1','evidence-json/1','default/1')->>'status';\n",
        )
        _wait_for_advisory_wait(reader_app)
        revoker.wait(timeout=8)
        if revoker.returncode != 0:
            raise RuntimeError(revoker.stderr.read() if revoker.stderr else "revoker failed")
        association.wait(timeout=8)
        assoc_out = association.stdout.read() if association.stdout else ""
        assoc_err = association.stderr.read() if association.stderr else ""
        if association.returncode != 0 or "resource_association_inserted" not in assoc_out:
            raise AssertionError(f"ProjectResource insert failed after revocation: {assoc_out} {assoc_err}")
        reader.wait(timeout=8)
        read_out = reader.stdout.read() if reader.stdout else ""
        read_err = reader.stderr.read() if reader.stderr else ""
        if reader.returncode != 0 or "denied" not in read_out.split():
            raise AssertionError(
                f"Context compile authorized after resource-scoped OwnerDecision revocation: "
                f"{read_out} {read_err}"
            )
    finally:
        for proc in (revoker, association, reader):
            if proc is not None and proc.poll() is None:
                proc.kill()
                proc.wait()

    resource_two = _new_resource()
    psql(
        "INSERT INTO aep.project_resources("
        "project_id,resource_id,access_mode,status,grant_version,grant_decision_id"
        ") VALUES("
        f"{lit(existing_project_id)}::uuid,{lit(resource_two)}::uuid,'read','active',1,NULL);"
    )
    project_three = scalar(
        "INSERT INTO aep.projects(project_key,name) "
        "VALUES('stage4b-resource-update-' || substr(gen_random_uuid()::text,1,8),"
        "'Stage 4B Resource state race') RETURNING project_id;"
    )
    work_three = create_work(project_three, "Resource update race Work")
    session_three = str(uuid4())
    resource_app = "stage4b_archive_" + str(uuid4()).replace("-", "")
    assoc_app_two = "stage4b_archive_assoc_" + str(uuid4()).replace("-", "")
    reader_app_two = "stage4b_archive_reader_" + str(uuid4()).replace("-", "")
    archiver = _start_psql(
        resource_app,
        "BEGIN;\n"
        f"UPDATE aep.resources SET status='archived' WHERE resource_id={lit(resource_two)}::uuid;\n"
        "SELECT 'resource_archiver_holds_lock';\n"
        "SELECT pg_sleep(2);\nCOMMIT;\n",
    )
    assert archiver.stdout is not None
    if archiver.stdout.readline().strip() != "resource_archiver_holds_lock":
        archiver.kill()
        archiver.wait()
        raise AssertionError("Resource archive did not acquire its Resource lock")
    association_two = _start_psql(
        assoc_app_two,
        "BEGIN;\n"
        "INSERT INTO aep.project_resources("
        "project_id,resource_id,access_mode,status,grant_version,grant_decision_id"
        ") VALUES("
        f"{lit(project_three)}::uuid,{lit(resource_two)}::uuid,'read','active',1,NULL);\n"
        "SELECT 'archived_resource_link_inserted';\nCOMMIT;\n",
    )
    reader_two = None
    try:
        _wait_for_advisory_wait(assoc_app_two)
        reader_two = _start_psql(
            reader_app_two,
            "SELECT aep.compile_context_pack("
            f"{lit(project_three)}::uuid,{lit(work_three)}::uuid,{lit(resource_two)}::uuid,"
            f"'refs/heads/main',{lit(session_three)}::uuid,8192,"
            "'context-compiler/1','evidence-json/1','default/1')->>'status';\n",
        )
        _wait_for_advisory_wait(reader_app_two)
        archiver.wait(timeout=8)
        if archiver.returncode != 0:
            raise RuntimeError(archiver.stderr.read() if archiver.stderr else "archiver failed")
        association_two.wait(timeout=8)
        assoc_out = association_two.stdout.read() if association_two.stdout else ""
        assoc_err = association_two.stderr.read() if association_two.stderr else ""
        if association_two.returncode != 0 or "archived_resource_link_inserted" not in assoc_out:
            raise AssertionError(f"ProjectResource insert failed after Resource archive: {assoc_out} {assoc_err}")
        reader_two.wait(timeout=8)
        read_out = reader_two.stdout.read() if reader_two.stdout else ""
        read_err = reader_two.stderr.read() if reader_two.stderr else ""
        if reader_two.returncode != 0 or "denied" not in read_out.split():
            raise AssertionError(f"Context compile authorized archived Resource: {read_out} {read_err}")
    finally:
        for proc in (archiver, association_two, reader_two):
            if proc is not None and proc.poll() is None:
                proc.kill()
                proc.wait()



def _approved_graph_member_decision(project_id: str, graph_id: str) -> str:
    decision_key = f"dependency_graph:{graph_id}:write"
    return scalar(
        "INSERT INTO aep.owner_decisions("
        "scope_type,scope_key,decision_key,statement,decision_version,status,"
        "approval_source_kind,approval_source_ref,approver_principal,"
        "approval_provenance,approved_at"
        ") VALUES("
        f"'project',{lit(project_id)},{lit(decision_key)},"
        "'Test-only shared dependency graph write membership',1,'approved',"
        "'direct_owner_message','test://owner/stage4b-batch','test-owner',"
        "jsonb_build_object('direct_owner_confirmation',true),clock_timestamp()"
        ") RETURNING decision_id;"
    )


def test_dependency_batch_lock_order(project_ids: list[str]) -> None:
    """Force reversed multi-edge batches to contend after their first edge lock set."""
    project_a, project_b, project_c = sorted(project_ids)
    graph_one = scalar(
        "SELECT aep.create_dependency_graph("
        f"{lit(project_a)}::uuid);"
    )
    graph_two = scalar(
        "SELECT aep.create_dependency_graph("
        f"{lit(project_a)}::uuid);"
    )
    for graph_id in (graph_one, graph_two):
        for project_id in (project_b, project_c):
            decision_id = _approved_graph_member_decision(project_id, graph_id)
            scalar(
                "SELECT aep.set_dependency_graph_member("
                f"{lit(graph_id)}::uuid,{lit(project_id)}::uuid,'write',"
                f"{lit(decision_id)}::uuid);"
            )

    groups: list[tuple[str,list[dict[str,str]]]] = []
    for index, graph_id in enumerate((graph_one,graph_two)):
        a_work = create_work(project_a, f"Batch {index} project A source")
        b_work = create_work(project_b, f"Batch {index} project B source")
        c_work = create_work(project_c, f"Batch {index} project C target")
        edge_a = {"op":"add","source_work_id":a_work,"target_work_id":c_work}
        edge_b = {"op":"add","source_work_id":b_work,"target_work_id":c_work}
        groups.append((graph_id,[edge_a,edge_b] if index == 0 else [edge_b,edge_a]))

    barrier_key = int(uuid4().hex[:15],16)
    controller = _start_psql(
        "stage4b_dependency_batch_barrier",
        f"SELECT pg_advisory_lock({barrier_key}::bigint);\n"
        "SELECT 'dependency_batch_barrier_ready';\n",
        keep_stdin_open=True,
    )
    assert controller.stdin is not None and controller.stdout is not None
    if controller.stdout.readline().strip() != "dependency_batch_barrier_ready":
        controller.kill()
        controller.wait()
        raise AssertionError("dependency batch test could not acquire its advisory barrier")

    first_app = "stage4b_batch_first_" + str(uuid4()).replace("-", "")
    second_app = "stage4b_batch_second_" + str(uuid4()).replace("-", "")
    pause_function = "ctx_test_pause_" + str(uuid4()).replace("-", "")
    pause_trigger = "zz_test_pause_" + str(uuid4()).replace("-", "")
    psql(
        f"CREATE FUNCTION aep.{pause_function}() RETURNS trigger "
        "LANGUAGE plpgsql SET search_path=pg_catalog,aep AS $function$ "
        f"BEGIN IF current_setting('application_name',true)={lit(first_app)} "
        f"THEN PERFORM pg_advisory_xact_lock({barrier_key}::bigint); END IF; "
        "RETURN NEW; END $function$;"
        f"CREATE TRIGGER {pause_trigger} BEFORE INSERT ON aep.work_relations "
        f"FOR EACH ROW EXECUTE FUNCTION aep.{pause_function}();"
    )

    def start_batch(app: str, graph_id: str, operations: list[dict[str,str]]) -> subprocess.Popen[str]:
        request_key = "stage4b-batch-" + str(uuid4())
        return _start_psql(
            app,
            "SELECT aep.mutate_dependencies("
            f"{lit(graph_id)}::uuid,{lit(request_key)},{json_sql(operations)});\n",
        )

    first = start_batch(first_app,groups[0][0],groups[0][1])
    second = None
    try:
        # The test trigger fires after the normal per-edge project locks.
        _wait_for_advisory_wait(first_app)
        second = start_batch(second_app,groups[1][0],groups[1][1])
        # With per-edge lock accumulation, the second batch owns B while
        # waiting on C; the first then waits for B on its second edge.
        # The wrapper must instead have the second batch wait before taking B.
        _wait_for_advisory_wait(second_app)
        controller.stdin.write(f"SELECT pg_advisory_unlock({barrier_key}::bigint);\n")
        controller.stdin.flush()
        controller.stdin.close()
        controller.wait(timeout=5)

        first.wait(timeout=12)
        second.wait(timeout=12)
        first_out = first.stdout.read() if first.stdout else ""
        first_err = first.stderr.read() if first.stderr else ""
        second_out = second.stdout.read() if second.stdout else ""
        second_err = second.stderr.read() if second.stderr else ""
        if first.returncode != 0 or second.returncode != 0:
            raise AssertionError(
                "Reversed dependency batches deadlocked or failed: "
                f"first={first.returncode} {first_out} {first_err}; "
                f"second={second.returncode} {second_out} {second_err}"
            )
        for output in (first_out,second_out):
            try:
                result = json.loads(output.strip())
            except json.JSONDecodeError as exc:
                raise AssertionError(f"Dependency mutation returned invalid JSON: {output}") from exc
            if result.get("added") != 2:
                raise AssertionError(f"Dependency batch did not add both edges: {result}")
    finally:
        for proc in (controller,first,second):
            if proc is not None and proc.poll() is None:
                proc.kill()
                proc.wait()
        psql(f"DROP TRIGGER IF EXISTS {pause_trigger} ON aep.work_relations;")
        psql(f"DROP FUNCTION IF EXISTS aep.{pause_function}();")


def create_work(project_id: str, title: str, *, key: str | None = None) -> str:
    session_id = str(uuid4())
    work_id = scalar(
        "SELECT work_id::text FROM aep.register_work("
        f"{lit(project_id)}::uuid,{lit('stage4b-request-'+str(uuid4()))},"
        f"{lit(session_id)}::uuid,'stage4b_context',{lit(key or ('work-'+str(uuid4())) )},"
        f"1,'implementation',{lit(title)},'{{}}'::jsonb,NULL);"
    )
    return work_id


def setup_fixture() -> tuple[str, str, str, str, str, str, str]:
    project_id = scalar(
        "INSERT INTO aep.projects(project_key,name) "
        "VALUES('stage4b-' || substr(gen_random_uuid()::text,1,8),"
        "'Stage 4B Context Compiler fixture') RETURNING project_id;"
    )
    repository_id = "1471589776"
    # Physical Resource identity is global and shared between projects. Reuse
    # the same repository in the second fixture, then create a separate
    # ProjectResource grant for that project.
    resource_id = scalar(
        "SELECT resource_id::text FROM aep.resources "
        "WHERE provider='github' AND host='github.com' "
        f"AND resource_type='repository' AND stable_resource_id={lit(repository_id)} LIMIT 1;"
    )
    if not resource_id:
        resource_id = str(uuid4())
        psql(
            "INSERT INTO aep.resources(resource_id,provider,host,resource_type,"
            "stable_resource_id,canonical_key,display_name) VALUES("
            f"{lit(resource_id)}::uuid,'github','github.com','repository',"
            f"{lit(repository_id)},{lit('repository:'+repository_id)},'Stage 4B test repository');"
        )
    grant_decision_id = scalar(
        "INSERT INTO aep.owner_decisions("
        "scope_type,scope_key,decision_key,statement,decision_version,status,"
        "approval_source_kind,approval_source_ref,approver_principal,"
        "approval_provenance,approved_at"
        ") VALUES("
        f"'project',{lit(project_id)},'stage4b-repository-write','Test-only repository grant',"
        "1,'approved','direct_owner_message','test://owner/stage4b','test-owner',"
        "jsonb_build_object('direct_owner_confirmation',true),clock_timestamp()"
        ") RETURNING decision_id;"
    )
    psql(
        "INSERT INTO aep.project_resources("
        "project_id,resource_id,access_mode,status,grant_version,grant_decision_id"
        ") VALUES("
        f"{lit(project_id)}::uuid,{lit(resource_id)}::uuid,'write','active',1,"
        f"{lit(grant_decision_id)}::uuid);"
    )

    work_id = create_work(project_id, "Stage 4B Context Compiler root Work")
    dependency_id = create_work(project_id, "Stage 4B prerequisite Work")
    graph_id = scalar(
        "SELECT graph_id::text FROM aep.dependency_graphs "
        f"WHERE owner_project_id={lit(project_id)}::uuid AND is_default;"
    )
    psql(
        "UPDATE aep.works SET status='delivered' "
        f"WHERE work_id={lit(dependency_id)}::uuid;"
    )
    psql(
        "INSERT INTO aep.work_relations("
        "source_work_id,target_work_id,relation_type,dependency_graph_id,status"
        ") VALUES("
        f"{lit(work_id)}::uuid,{lit(dependency_id)}::uuid,"
        f"'depends_on',{lit(graph_id)}::uuid,'active');"
    )
    psql(
        "SELECT aep.set_work_resource_requirements("
        f"{lit(work_id)}::uuid,"
        f"{json_sql([{'resource_id':resource_id,'resource_ref':'refs/heads/main'}])});"
    )
    context_decision_id = scalar(
        "INSERT INTO aep.owner_decisions("
        "scope_type,scope_key,decision_key,statement,decision_version,status"
        ") VALUES("
        f"'work',{lit(work_id)},'context-guidance','Proposed project-scoped guidance',"
        "1,'proposed') RETURNING decision_id;"
    )
    return project_id, resource_id, work_id, dependency_id, graph_id, grant_decision_id, context_decision_id


def record_source(project_id: str, work_id: str, resource_id: str, session_id: str,
                  commit_sha: str, tree_sha: str, content_sha: str) -> dict:
    return json_result(
        "SELECT aep.record_context_source_revision("
        f"{lit(project_id)}::uuid,{lit(work_id)}::uuid,{lit(resource_id)}::uuid,"
        f"'refs/heads/main',{lit(session_id)}::uuid,{lit(commit_sha)},"
        f"{lit(tree_sha)},{lit(content_sha)},{json_sql({'adapter':'test-github-ref-reader','method':'verified-ref-and-tree-read'})});"
    )


def compile_pack(project_id: str, work_id: str, resource_id: str, session_id: str,
                 budget: int = 8192, compiler: str = "context-compiler/1",
                 indexer: str = "evidence-json/1", config: str = "default/1") -> dict:
    return json_result(
        "SELECT aep.compile_context_pack("
        f"{lit(project_id)}::uuid,{lit(work_id)}::uuid,{lit(resource_id)}::uuid,"
        f"'refs/heads/main',{lit(session_id)}::uuid,{budget},"
        f"{lit(compiler)},{lit(indexer)},{lit(config)});"
    )


def fetch_pack(pack_id: str, session_id: str, budget: int = 8192,
               compiler: str = "context-compiler/1",
               indexer: str = "evidence-json/1", config: str = "default/1") -> dict:
    return json_result(
        "SELECT aep.get_context_pack("
        f"{lit(pack_id)}::uuid,{lit(session_id)}::uuid,{budget},"
        f"{lit(compiler)},{lit(indexer)},{lit(config)});"
    )


def insert_evidence(project_id: str, work_id: str, source_ref: str,
                    text_value: str, source_revision: str = "fixture-v1") -> None:
    payload = {"kind": "source_observation", "text": text_value}
    content_hash = scalar(
        "SELECT encode(public.digest(convert_to("
        f"{lit(json.dumps(payload,sort_keys=True,separators=(',',':')))}"
        "::text,'UTF8'),'sha256'),'hex');"
    )
    psql(
        "INSERT INTO aep.evidence("
        "project_id,work_id,evidence_type,source_ref,source_revision,"
        "content_sha256,provenance,payload"
        ") VALUES("
        f"{lit(project_id)}::uuid,{lit(work_id)}::uuid,'source_observation',"
        f"{lit(source_ref)},{lit(source_revision)},{lit(content_hash)},"
        f"{json_sql({'provider':'test-fixture','observation':'recorded-before-compilation'})},"
        f"{json_sql(payload)});"
    )


def assert_status(result: dict, expected: str, label: str) -> None:
    actual = result.get("status")
    if actual != expected:
        raise AssertionError(f"{label}: expected {expected!r}, got {actual!r}: {result}")


def test_compilation_cache_and_provenance(
    project_id: str, resource_id: str, work_id: str, dependency_id: str, session_id: str,
) -> str:
    insert_evidence(project_id, work_id, "artifact://stage4b/source/one", "first source fact")
    source_a = record_source(
        project_id, work_id, resource_id, session_id,
        "a" * 40, "b" * 40, "c" * 64,
    )
    assert_status(source_a, "recorded", "first repository observation")
    if source_a["source_version"] != 1:
        raise AssertionError("first source revision must start at version 1")

    unchanged = record_source(
        project_id, work_id, resource_id, str(uuid4()),
        "a" * 40, "b" * 40, "c" * 64,
    )
    assert_status(unchanged, "unchanged", "second session recording same pinned revision")
    if unchanged["source_version"] != 1:
        raise AssertionError("same SHA/tree/hash/provenance should not create a new source version")

    compiled = compile_pack(project_id, work_id, resource_id, session_id)
    assert_status(compiled, "ready", "authorized context compilation")
    pack_id = compiled["pack_id"]
    payload = compiled["payload"]
    if payload["project"]["project_id"] != project_id:
        raise AssertionError("Context Pack is not bound to the authorized project")
    if payload["work"]["work_id"] != work_id:
        raise AssertionError("Context Pack is not bound to the requested Work")
    if payload["repository"]["resource"]["resource_id"] != resource_id:
        raise AssertionError("Context Pack is not bound to the physical repository resource")
    revision = payload["repository"]["repository_revision"]
    if (revision["commit_sha"], revision["tree_sha"], revision["source_version"]) != (
        "a" * 40, "b" * 40, 1
    ):
        raise AssertionError("Context Pack does not pin the exact observed commit/tree/version")
    if revision["content_sha256"] != "c" * 64 or "method" not in revision["provenance"]:
        raise AssertionError("Context Pack lost source content hash or observation provenance")
    if not any(
        row["target_work_id"] == dependency_id and row["dependency_graph_id"]
        for row in payload["dependencies"]
    ):
        raise AssertionError("Context Pack does not carry its exact Work dependency")
    if not any(
        row["source_ref"] == "artifact://stage4b/source/one"
        and row["content_sha256"] and row["payload_sha256"]
        for row in payload["source_evidence"]
    ):
        raise AssertionError("Context Pack omitted a source reference/content hash")
    if not any(
        row["decision_key"] == "context-guidance"
        and row["decision_version"] == 1 and row["status"] == "proposed"
        for row in payload["decisions"]
    ):
        raise AssertionError("Context Pack omitted relevant decision ID/version/status")
    if payload["token_budget"] != 8192 or compiled["estimated_tokens"] > 8192:
        raise AssertionError("Context Pack did not declare and respect its token budget")
    if compiled["content_sha256"] != scalar(
        "SELECT encode(public.digest(convert_to("
        f"(SELECT payload::text FROM aep.context_packs WHERE pack_id={lit(pack_id)}::uuid),"
        "'UTF8'),'sha256'),'hex');"
    ):
        raise AssertionError("Context Pack content SHA-256 does not match its stored payload")

    replay = compile_pack(project_id, work_id, resource_id, str(uuid4()))
    assert_status(replay, "ready", "same source/version cache reuse")
    if replay["pack_id"] != pack_id or replay["cache_hit"] is not True:
        raise AssertionError("same source/version/cache dimensions did not reuse the same Pack")
    reused = fetch_pack(pack_id, str(uuid4()))
    assert_status(reused, "ready", "authorized cached pack retrieval")
    if reused["payload"] != payload:
        raise AssertionError("cached pack retrieval changed the compiled content")

    unknown_pack = fetch_pack(str(uuid4()), str(uuid4()))
    assert_status(unknown_pack, "denied", "unknown Pack ID does not reveal Pack existence")
    if "payload" in unknown_pack:
        raise AssertionError("unknown Pack ID returned a Context Pack payload")

    stale_compiler = fetch_pack(pack_id, str(uuid4()), compiler="context-compiler/2")
    assert_status(stale_compiler, "stale", "compiler version invalidation")
    stale_indexer = fetch_pack(pack_id, str(uuid4()), indexer="evidence-json/2")
    assert_status(stale_indexer, "stale", "indexer version invalidation")
    stale_config = fetch_pack(pack_id, str(uuid4()), config="default/2")
    assert_status(stale_config, "stale", "compiler config invalidation")
    stale_budget = fetch_pack(pack_id, str(uuid4()), budget=4096)
    assert_status(stale_budget, "stale", "token budget invalidation")
    for stale in (stale_compiler, stale_indexer, stale_config, stale_budget):
        if "payload" in stale:
            raise AssertionError("stale cache response leaked old Context Pack content")
    return pack_id


def test_snapshot_write_serialization(
    project_id: str, resource_id: str, work_id: str, dependency_id: str,
    pack_id: str, session_id: str,
) -> None:
    """Hold a real Pack fetch transaction open and prove all snapshot writers wait."""
    graph_id = scalar(
        "SELECT dependency_graph_id::text FROM aep.work_relations "
        f"WHERE source_work_id={lit(work_id)}::uuid "
        "AND relation_type='depends_on' AND status='active' LIMIT 1;"
    )
    decision_id = scalar(
        "SELECT decision_id::text FROM aep.owner_decisions "
        f"WHERE scope_type='work' AND scope_key={lit(work_id)} "
        "AND decision_key='context-guidance';"
    )
    cmd = [
        "psql", "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1",
        "-h", HOST, "-p", PORT, "-U", USER, "-d", DATABASE,
    ]
    env = os.environ.copy()
    env["PGPASSWORD"] = PASSWORD
    sql = (
        "BEGIN;\n"
        "SELECT aep.get_context_pack("
        f"{lit(pack_id)}::uuid,{lit(str(uuid4()))}::uuid,8192,"
        "'context-compiler/1','evidence-json/1','default/1')->>'status';\n"
        "SELECT pg_sleep(4);\n"
        "COMMIT;\n"
    )
    reader = subprocess.Popen(
        cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, bufsize=1, env=env,
    )
    assert reader.stdin is not None and reader.stdout is not None
    reader.stdin.write(sql)
    reader.stdin.flush()
    reader.stdin.close()
    status = reader.stdout.readline().strip()
    if status != "ready":
        reader.kill()
        reader.wait()
        raise AssertionError(f"snapshot reader did not return a validated Pack: {status!r}")

    writer_statements = [
        ("Work update",
         "UPDATE aep.works SET title=title || ' concurrent mutation',version=version+1 "
         f"WHERE work_id={lit(work_id)}::uuid;"),
        ("Dependency edge update",
         "UPDATE aep.work_relations SET status='removed',removed_at=clock_timestamp() "
         f"WHERE source_work_id={lit(work_id)}::uuid "
         f"AND target_work_id={lit(dependency_id)}::uuid;"),
        ("Dependency graph update",
         "UPDATE aep.dependency_graphs SET graph_version=graph_version+1 "
         f"WHERE graph_id={lit(graph_id)}::uuid;"),
        ("OwnerDecision update",
         "UPDATE aep.owner_decisions SET statement=statement || ' concurrent mutation' "
         f"WHERE decision_id={lit(decision_id)}::uuid;"),
        ("Evidence insert",
         "INSERT INTO aep.evidence(project_id,work_id,evidence_type,source_ref,"
         "content_sha256,provenance,payload) VALUES("
         f"{lit(project_id)}::uuid,{lit(work_id)}::uuid,'source_observation',"
         "'artifact://concurrency/blocked',"
         f"{lit('a'*64)},'{{}}'::jsonb,'{{\"blocked\":true}}'::jsonb);"),
        ("ProjectResource grant update",
         "UPDATE aep.project_resources SET grant_version=grant_version+1 "
         f"WHERE project_id={lit(project_id)}::uuid "
         f"AND resource_id={lit(resource_id)}::uuid;"),
        ("Repository source revision",
         "SELECT aep.record_context_source_revision("
         f"{lit(project_id)}::uuid,{lit(work_id)}::uuid,{lit(resource_id)}::uuid,"
         f"'refs/heads/main',{lit(session_id)}::uuid,{lit('4'*40)},"
         f"{lit('5'*40)},{lit('6'*64)},'{{\"adapter\":\"concurrency-test\"}}'::jsonb);"),
    ]
    for label, statement in writer_statements:
        attempt = psql("SET lock_timeout='150ms'; " + statement, check=False)
        if attempt.returncode == 0 or "lock timeout" not in attempt.stderr.lower():
            reader.kill()
            reader.wait()
            raise AssertionError(
                f"{label} was not serialized behind the Pack snapshot transaction: "
                f"exit={attempt.returncode}, stdout={attempt.stdout}, stderr={attempt.stderr}"
            )

    reader.wait(timeout=10)
    output = reader.stdout.read()
    error = reader.stderr.read() if reader.stderr else ""
    if reader.returncode != 0:
        raise RuntimeError(f"snapshot reader failed: {output} {error}")


def test_state_invalidation(
    project_id: str, resource_id: str, work_id: str, dependency_id: str,
    session_id: str, pack_id: str, grant_decision_id: str,
) -> None:
    decision_id = scalar(
        "SELECT decision_id::text FROM aep.owner_decisions "
        f"WHERE scope_type='work' AND scope_key={lit(work_id)} "
        "AND decision_key='context-guidance';"
    )
    psql(
        "UPDATE aep.owner_decisions SET status='rejected' "
        f"WHERE decision_id={lit(decision_id)}::uuid;"
    )
    assert_status(fetch_pack(pack_id, str(uuid4())), "stale", "decision status change")
    pack_id = compile_pack(project_id, work_id, resource_id, session_id)["pack_id"]

    psql(
        "UPDATE aep.works SET title='Updated prerequisite',version=version+1 "
        f"WHERE work_id={lit(dependency_id)}::uuid;"
    )
    assert_status(fetch_pack(pack_id, str(uuid4())), "stale", "dependency version change")
    pack_id = compile_pack(project_id, work_id, resource_id, session_id)["pack_id"]

    source_b = record_source(
        project_id, work_id, resource_id, str(uuid4()),
        "d" * 40, "e" * 40, "f" * 64,
    )
    assert_status(source_b, "recorded", "changed repository source observation")
    if source_b["source_version"] != 2:
        raise AssertionError("changed repository SHA/tree/hash did not advance source_version")
    assert_status(fetch_pack(pack_id, str(uuid4())), "stale", "repository source SHA/tree invalidation")
    pack_id = compile_pack(project_id, work_id, resource_id, session_id)["pack_id"]

    psql(
        "UPDATE aep.project_resources SET grant_version=grant_version+1 "
        f"WHERE project_id={lit(project_id)}::uuid AND resource_id={lit(resource_id)}::uuid;"
    )
    assert_status(fetch_pack(pack_id, str(uuid4())), "stale", "grant version change")
    pack_id = compile_pack(project_id, work_id, resource_id, session_id)["pack_id"]

    psql(
        "UPDATE aep.project_resources SET status='revoked',revoked_at=clock_timestamp(),"
        "grant_version=grant_version+1 "
        f"WHERE project_id={lit(project_id)}::uuid AND resource_id={lit(resource_id)}::uuid;"
    )
    denied = fetch_pack(pack_id, str(uuid4()))
    assert_status(denied, "denied", "grant revocation before cached content read")
    if "payload" in denied:
        raise AssertionError("revoked grant still returned Context Pack content")
    audit = json.loads(scalar(
        "SELECT to_jsonb(event_row)::text FROM aep.context_retrieval_events AS event_row "
        f"WHERE event_row.operation='fetch' AND event_row.outcome='denied' "
        f"AND event_row.pack_id={lit(pack_id)}::uuid ORDER BY occurred_at DESC LIMIT 1;"
    ))
    if audit["source_count"] != 0 or audit["source_bytes"] != 0:
        raise AssertionError("grant-revoked retrieval trace contains source rows or bytes")
    if "source_ref" in audit or "payload" in audit:
        raise AssertionError("retrieval audit trace contains source references or payload")


def test_denied_project_is_rejected_before_retrieval(
    allowed_resource_id: str, existing_session_id: str,
) -> None:
    denied_project = scalar(
        "INSERT INTO aep.projects(project_key,name) "
        "VALUES('stage4b-denied-' || substr(gen_random_uuid()::text,1,8),"
        "'Denied Context fixture') RETURNING project_id;"
    )
    denied_work = create_work(denied_project, "Secret Work that must not be retrieved")
    insert_evidence(
        denied_project, denied_work, "private://denied/secret-source",
        "PRIVATE_SOURCE_SENTINEL_MUST_NOT_APPEAR",
    )
    denied = compile_pack(
        denied_project, denied_work, allowed_resource_id, existing_session_id
    )
    assert_status(denied, "denied", "caller-supplied project/resource/session cannot grant access")
    if any(key in denied for key in ("payload","source_evidence","source_ref","Secret Work")):
        raise AssertionError("denied compile response exposed project Work or evidence content")

    source_denied = json_result(
        "SELECT aep.record_context_source_revision("
        f"{lit(denied_project)}::uuid,{lit(denied_work)}::uuid,"
        f"{lit(allowed_resource_id)}::uuid,'refs/heads/main',"
        f"{lit(existing_session_id)}::uuid,{lit('1'*40)},{lit('2'*40)},"
        f"{lit('3'*64)},{json_sql({'adapter':'unauthorized-test'})});"
    )
    assert_status(source_denied, "denied", "source observation authorization")
    if scalar(
        "SELECT count(*)::text FROM aep.context_packs "
        f"WHERE project_id={lit(denied_project)}::uuid;"
    ) != "0":
        raise AssertionError("denied project unexpectedly received a Context Pack")

    trace = scalar(
        "SELECT jsonb_agg(to_jsonb(event_row))::text "
        "FROM aep.context_retrieval_events AS event_row "
        f"WHERE event_row.project_id={lit(denied_project)}::uuid "
        "AND event_row.outcome='denied';"
    )
    if not trace or "PRIVATE_SOURCE_SENTINEL" in trace or "private://denied" in trace:
        raise AssertionError("denied-project retrieval trace contains source rows/bytes")
    rows = json.loads(trace)
    if len(rows) != 2 or any(
        row["source_count"] != 0 or row["source_bytes"] != 0
        for row in rows
    ):
        raise AssertionError("denied source/compile audit must contain zero retrieved rows and bytes")


def test_budget_truncation(
    project_id: str, resource_id: str, work_id: str, session_id: str,
) -> None:
    # Seed 25 oversized payloads plus 140 small records in two INSERTs.
    # The snapshot builder must choose from byte metadata before fetching any payload.
    psql(
        "WITH fixtures AS ("
        "SELECT 'artifact://stage4b/large/' || n::text AS source_ref,"
        "'large-' || n::text AS source_revision,"
        "jsonb_build_object('kind','source_observation',"
        "'text',repeat('LARGE_SOURCE_CONTENT_' || n::text,900)) AS payload "
        "FROM generate_series(1,25) AS series(n) "
        "UNION ALL "
        "SELECT repeat('界',1500) || '/' || n::text,"
        "CASE WHEN n <= 10 THEN repeat('OVERSIZED_REVISION_',600) "
        "ELSE 'small-' || n::text END,"
        "jsonb_build_object('kind','source_observation','text','small fact ' || n::text) "
        "FROM generate_series(1,140) AS series(n)"
        ") INSERT INTO aep.evidence("
        "project_id,work_id,evidence_type,source_ref,source_revision,content_sha256,"
        "provenance,payload"
        ") SELECT "
        f"{lit(project_id)}::uuid,{lit(work_id)}::uuid,'source_observation',"
        "fixtures.source_ref,fixtures.source_revision,"
        "encode(public.digest(convert_to(fixtures.payload::text,'UTF8'),'sha256'),'hex'),"
        "jsonb_build_object('provider','test-fixture','observation','bounded-size-fixture'),"
        "fixtures.payload FROM fixtures;"
    )
    compiled = compile_pack(
        project_id, work_id, resource_id, session_id, budget=3000
    )
    assert_status(compiled, "ready", "budget-bounded context compilation")
    payload = compiled["payload"]
    if payload["truncated"] is not True:
        raise AssertionError("large evidence was not truncated to respect the token budget")
    if payload["source_evidence_truncated_count"] < 1:
        raise AssertionError("Context Pack did not report omitted source evidence")
    if compiled["estimated_tokens"] > 3000 or payload["estimated_tokens"] > 3000:
        raise AssertionError("truncated Context Pack exceeded its declared token budget")
    if "LARGE_SOURCE_CONTENT_" in json.dumps(payload):
        raise AssertionError("truncated source content leaked into the returned Context Pack")
    selection = payload["source_evidence_selection"]
    if selection["total_count"] != 165 or selection["oversized_count"] != 35:
        raise AssertionError(f"bounded selection summary is incorrect: {selection}")
    if selection["candidate_count"] > 128 or selection["selected_count"] > 128:
        raise AssertionError("Evidence metadata candidate/selection count exceeded 128")
    if selection["selected_materialized_bytes"] > 262144:
        raise AssertionError("complete Evidence materialization exceeded 256 KiB")
    materialized_sum = 0
    for evidence in payload["source_evidence"]:
        if evidence["payload_bytes"] > 16384 or evidence["provenance_bytes"] > 8192:
            raise AssertionError("oversized Evidence payload/provenance reached the Context Pack")
        serialized_source_ref = len(
            json.dumps(evidence["source_ref"], ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        )
        serialized_source_revision = len(
            json.dumps(evidence["source_revision"], ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        )
        serialized_evidence_type = len(
            json.dumps(evidence["evidence_type"], ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        )
        if evidence["source_ref_bytes"] != serialized_source_ref:
            raise AssertionError("source_ref serialized UTF-8 byte accounting is incorrect")
        if evidence["source_revision_bytes"] != serialized_source_revision:
            raise AssertionError("source_revision serialized UTF-8 byte accounting is incorrect")
        if evidence["evidence_type_bytes"] != serialized_evidence_type:
            raise AssertionError("evidence_type serialized UTF-8 byte accounting is incorrect")
        if (evidence["source_ref_bytes"] > 8192
                or evidence["source_revision_bytes"] > 8192
                or evidence["evidence_type_bytes"] > 400):
            raise AssertionError("oversized Evidence metadata reached the Context Pack")
        expected_bytes = (
            evidence["payload_bytes"] + evidence["provenance_bytes"]
            + evidence["source_ref_bytes"] + evidence["source_revision_bytes"]
            + evidence["evidence_type_bytes"] + 512
        )
        if evidence["materialized_bytes"] != expected_bytes:
            raise AssertionError("Evidence materialization omitted source metadata")
        materialized_sum += expected_bytes
    if materialized_sum != selection["selected_materialized_bytes"]:
        raise AssertionError("selected Evidence summary does not match the selected rows")
    if any(
        "OVERSIZED_REVISION_" in (evidence["source_revision"] or "")
        for evidence in payload["source_evidence"]
    ):
        raise AssertionError("oversized source_revision was materialized into the Context Pack")
    if payload["source_evidence_count"] != 165:
        raise AssertionError("Context Pack did not preserve total Evidence count");


def main() -> None:
    setup_database()
    test_runtime_access_boundary()
    project_id, resource_id, work_id, dependency_id, graph_id, grant_decision_id, _ = setup_fixture()
    test_authorization_locks(project_id, resource_id, grant_decision_id)
    test_authorization_lock_order(project_id, resource_id, grant_decision_id)
    test_resource_scope_serialization(project_id)
    session_id = str(uuid4())
    pack_id = test_compilation_cache_and_provenance(
        project_id, resource_id, work_id, dependency_id, session_id
    )
    test_snapshot_write_serialization(
        project_id, resource_id, work_id, dependency_id,
        pack_id, session_id
    )
    test_state_invalidation(
        project_id, resource_id, work_id, dependency_id,
        session_id, pack_id, grant_decision_id
    )
    batch_projects = [
        scalar(
            "INSERT INTO aep.projects(project_key,name) "
            "VALUES('stage4b-batch-' || substr(gen_random_uuid()::text,1,8),"
            "'Stage 4B dependency batch fixture') RETURNING project_id;"
        )
        for _ in range(3)
    ]
    test_dependency_batch_lock_order(batch_projects)
    # Run the budget test before deliberately revoking the project/resource grant.
    # A fresh independent fixture keeps the denied-project attack path isolated.
    project_2, resource_2, work_2, _, _, _, _ = setup_fixture()
    session_2 = str(uuid4())
    record_source(
        project_2, work_2, resource_2, session_2,
        "9" * 40, "8" * 40, "7" * 64,
    )
    test_budget_truncation(project_2, resource_2, work_2, session_2)
    test_denied_project_is_rejected_before_retrieval(resource_2, session_2)
    print("PASS Stage 4B Context Compiler: authorization-before-retrieval, source/decision/dependency/grant invalidation, cache binding, provenance and budget truncation")


if __name__ == "__main__":
    main()
