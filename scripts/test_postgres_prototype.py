#!/usr/bin/env python3
"""Disposable PostgreSQL integration tests for the Work Registry prototype."""

from __future__ import annotations

import json
import os
import re
import subprocess
from pathlib import Path
from uuid import uuid4

ROOT = Path(__file__).resolve().parents[1]
MIGRATIONS = ROOT / "db" / "prototype"
DATABASE = os.environ.get("PGDATABASE", "aep_test")
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


def register(project_id: str, request_key: str, identity_key: str, *, title: str = "prototype",
             session_id: str | None = None, external: dict[str, str] | None = None) -> str:
    session = session_id or str(uuid4())
    ext = "NULL::jsonb" if external is None else lit(json.dumps(external)) + "::jsonb"
    return (
        "SELECT work_id::text || '|' || outcome FROM aep.register_work("
        f"{lit(project_id)}::uuid,{lit(request_key)},{lit(session)}::uuid,"
        f"'test',{lit(identity_key)},1,'implementation',{lit(title)},'{{}}'::jsonb,{ext});"
    )


def scalar(sql: str) -> str:
    return psql(sql).stdout.strip()


def main() -> None:
    migrations = sorted(MIGRATIONS.glob("*.sql"))
    versions: list[int] = []
    for path in migrations:
        match = re.fullmatch(r"(\d{4})_[a-z0-9_]+\.sql", path.name)
        if not match:
            raise SystemExit(f"Invalid prototype migration filename: {path.name}")
        versions.append(int(match.group(1)))
    if not migrations or versions != sorted(set(versions)):
        raise SystemExit(f"Missing, duplicate, or unordered migrations: {versions}")

    psql("DROP DATABASE IF EXISTS aep_test WITH (FORCE);", db="postgres")
    psql("CREATE DATABASE aep_test;", db="postgres")
    for path in migrations:
        psql(file=path)
    project_id = scalar(
        "INSERT INTO aep.projects(project_key,name) VALUES('prototype','Prototype project') RETURNING project_id;"
    )
    print("PASS T26: clean PostgreSQL 17 migration and project bootstrap")

    # Widen the collision window so two independent connections contend at the unique index.
    psql("""
      CREATE FUNCTION public.aep_test_pause_identity() RETURNS trigger
      LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
      BEGIN
        IF NEW.identity_key='race-key' THEN PERFORM pg_sleep(0.5); END IF;
        RETURN NEW;
      END $$;
      CREATE TRIGGER aep_test_pause_identity BEFORE INSERT ON aep.works
      FOR EACH ROW EXECUTE FUNCTION public.aep_test_pause_identity();
    """)
    race_sql = [
        register(project_id, "request-a", "race-key", title="concurrent work"),
        register(project_id, "request-b", "race-key", title="concurrent work"),
    ]
    env = os.environ.copy()
    env["PGPASSWORD"] = PASSWORD
    procs = [
        subprocess.Popen(
            ["psql","-X","-q","-A","-t","-v","ON_ERROR_STOP=1",
             "-h",HOST,"-p",PORT,"-U",USER,"-d",DATABASE,"-c",sql],
            text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env
        )
        for sql in race_sql
    ]
    outputs = []
    for proc in procs:
        out, err = proc.communicate(timeout=20)
        if proc.returncode:
            raise RuntimeError(f"concurrent registration failed: {out}\n{err}")
        outputs.extend(line for line in out.splitlines() if "|" in line)
    psql("DROP TRIGGER aep_test_pause_identity ON aep.works; DROP FUNCTION public.aep_test_pause_identity();")
    ids = {line.split("|",1)[0] for line in outputs}
    outcomes = {line.split("|",1)[1] for line in outputs}
    count = scalar("SELECT count(*) FROM aep.works WHERE identity_key='race-key';")
    if len(ids) != 1 or count != "1" or outcomes != {"created","linked"}:
        raise AssertionError(f"T01 failed: {outputs}; ids={ids}; count={count}")
    print("PASS T01: concurrent canonical registration returns one work_id")

    first = scalar(register(project_id,"same-key","same-key-identity",title="stable title"))
    replay = scalar(register(project_id,"same-key","same-key-identity",title="stable title"))
    if first.split("|")[0] != replay.split("|")[0] or not first.endswith("|created") or not replay.endswith("|replayed"):
        raise AssertionError(f"T02 replay failed: {first}, {replay}")
    changed = psql(register(project_id,"same-key","same-key-identity",title="changed payload"),check=False)
    if changed.returncode == 0 or "idempotency key reused with different payload" not in changed.stderr:
        raise AssertionError(f"T02 payload conflict not enforced: {changed.stderr}")
    print("PASS T02: idempotency replay and payload mismatch conflict")

    # The first response is intentionally discarded; retry uses a new session_id.
    psql(register(project_id,"lost-response","lost-response-identity",title="lost response"))
    recovered = scalar(register(project_id,"lost-response","lost-response-identity",
                                title="lost response",session_id=str(uuid4())))
    if not recovered.endswith("|replayed") or scalar(
        "SELECT count(*) FROM aep.works WHERE identity_key='lost-response-identity';"
    ) != "1":
        raise AssertionError(f"T03 lost-response recovery failed: {recovered}")
    print("PASS T03: lost response recovered across sessions")

    external = {
        "provider":"github","host":"github.com","resource_key":"repo:1471589776",
        "object_type":"issue","external_id":"600001","observed_revision":"initial"
    }
    ext_a = scalar(register(project_id,"ext-a","external-identity",title="external work",external=external))
    ext_b = scalar(register(project_id,"ext-b","external-identity",title="external work",external=external))
    ext_count = scalar(
        "SELECT count(*) FROM aep.external_refs WHERE provider='github' AND host='github.com' "
        "AND resource_key='repo:1471589776' AND object_type='issue' AND external_id='600001';"
    )
    if ext_a.split("|")[0] != ext_b.split("|")[0] or not ext_b.endswith("|linked") or ext_count != "1":
        raise AssertionError(f"T21 ExternalRef linking failed: {ext_a}, {ext_b}, count={ext_count}")
    conflict = psql(register(project_id,"ext-conflict","different-work",title="rollback",
                             external=external),check=False)
    rollback_count = scalar("SELECT count(*) FROM aep.works WHERE identity_key='different-work';")
    if conflict.returncode == 0 or rollback_count != "0":
        raise AssertionError("T21 conflicting ExternalRef did not roll back the candidate Work")
    print("PASS T21 slice: external reference uniqueness and conflict rollback")

    function = "'aep.register_work(uuid,text,uuid,text,text,integer,text,text,jsonb,jsonb)'::regprocedure"
    security = scalar(f"""
      SELECT
        (SELECT (NOT rolsuper AND NOT rolbypassrls)::text FROM pg_roles WHERE rolname='aep_owner')
        || '|' || (SELECT prosecdef::text FROM pg_proc WHERE oid={function})
        || '|' || (SELECT replace(array_to_string(proconfig,','),' ','')
                   FROM pg_proc WHERE oid={function})
        || '|' || (SELECT NOT COALESCE(bool_or(x.grantee=0 AND x.privilege_type='EXECUTE'),false)
                   FROM pg_proc p, LATERAL aclexplode(COALESCE(p.proacl,acldefault('f',p.proowner))) x
                   WHERE p.oid={function})::text
        || '|' || has_function_privilege('aep_runtime',{function},'EXECUTE')::text
        || '|' || (NOT has_table_privilege('aep_runtime','aep.works','SELECT'))::text
        || '|' || (SELECT bool_and(relrowsecurity AND relforcerowsecurity)::text
                   FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
                   WHERE n.nspname='aep' AND c.relkind='r');
    """)
    security_flags = security.split("|")
    expected = ["true", "true", "search_path=pg_catalog,aep", "true", "true", "true", "true"]
    if security_flags != expected:
        raise AssertionError(f"Security contract flags differ: actual={security_flags}, expected={expected}")
    denied = psql("SET ROLE aep_runtime; SELECT count(*) FROM aep.works;",check=False)
    if denied.returncode == 0 or "permission denied" not in denied.stderr:
        raise AssertionError("Runtime role has unexpected direct table access")
    api_result = scalar(
        "SET ROLE aep_runtime; " +
        register(project_id,"runtime-api","runtime-api-work",title="runtime API") +
        " RESET ROLE;"
    )
    if not api_result.endswith("|created"):
        raise AssertionError(f"Runtime API call failed: {api_result}")
    mutation = psql("UPDATE aep.work_events SET event_payload='{}'::jsonb;",check=False)
    if mutation.returncode == 0 or "append-only" not in mutation.stderr:
        raise AssertionError("work_events accepted mutation")
    print("PASS security slice: fixed SECURITY DEFINER path, non-bypass owner, forced RLS, narrow grants, append-only events")
    # Stage 1B: physical resources are independent of project namespace.
    project2 = scalar(
        "INSERT INTO aep.projects(project_key,name) VALUES('prototype-two','Second project') RETURNING project_id;"
    )
    resource_id = scalar(
        "INSERT INTO aep.resources(provider,host,resource_type,stable_resource_id,canonical_key,display_name) "
        "VALUES('github','github.com','repository','1471589776','repo:1471589776','recursive-engineering-platform') "
        "RETURNING resource_id;"
    )
    psql(
        f"INSERT INTO aep.project_resources(project_id,resource_id,access_mode) VALUES "
        f"({lit(project_id)}::uuid,{lit(resource_id)}::uuid,'read_write'),"
        f"({lit(project2)}::uuid,{lit(resource_id)}::uuid,'read_write');"
    )
    if scalar(f"SELECT count(*) FROM aep.project_resources WHERE resource_id={lit(resource_id)}::uuid;") != "2":
        raise AssertionError("One physical resource could not be referenced by two project namespaces")
    duplicate_resource = psql(
        "INSERT INTO aep.resources(provider,host,resource_type,stable_resource_id,canonical_key) "
        "VALUES('github','github.com','repository','1471589776','repo:duplicate');",
        check=False,
    )
    if duplicate_resource.returncode == 0:
        raise AssertionError("Duplicate provider-stable Resource identity was accepted")
    print("PASS Stage 1B: physical Resource identity is distinct from ProjectResource links")

    # OwnerDecision approval shape requires explicit direct-owner provenance fields.
    invalid_approval = psql(
        "INSERT INTO aep.owner_decisions(scope_type,scope_key,decision_key,statement,decision_version,status) "
        "VALUES('project','prototype','release','Approve release',1,'approved');",
        check=False,
    )
    if invalid_approval.returncode == 0:
        raise AssertionError("OwnerDecision accepted approved status without direct Owner provenance")
    decision_id = scalar(
        "INSERT INTO aep.owner_decisions(scope_type,scope_key,decision_key,statement,decision_version,status,proposed_by_session_id) "
        f"VALUES('project','prototype','future-write-grant','Future write grant',1,'proposed',{lit(str(uuid4()))}::uuid) "
        "RETURNING decision_id;"
    )
    if not decision_id:
        raise AssertionError("OwnerDecision proposal was not created")
    print("PASS Stage 1B: OwnerDecision approval cannot omit provenance fields")

    # Create a graph descriptor. Shared graph write membership requires a grant reference.
    graph_id = scalar(
        "INSERT INTO aep.dependency_graphs(graph_scope,owner_project_id) "
        f"VALUES('shared',{lit(project_id)}::uuid) RETURNING graph_id;"
    )
    psql(
        f"INSERT INTO aep.dependency_graph_members(graph_id,project_id,access_mode) "
        f"VALUES({lit(graph_id)}::uuid,{lit(project_id)}::uuid,'owner'),"
        f"({lit(graph_id)}::uuid,{lit(project2)}::uuid,'read');"
    )
    missing_graph_grant = psql(
        f"UPDATE aep.dependency_graph_members SET access_mode='write' "
        f"WHERE graph_id={lit(graph_id)}::uuid AND project_id={lit(project2)}::uuid;",
        check=False,
    )
    if missing_graph_grant.returncode == 0:
        raise AssertionError("Shared graph write membership was accepted without a grant reference")

    work_one = scalar(register(project_id,"model-work-one","model-work-one",title="Model work one")).split("|")[0]
    work_two = scalar(register(project2,"model-work-two","model-work-two",title="Model work two")).split("|")[0]
    work_child = scalar(register(project_id,"model-work-child","model-work-child",title="Model child")).split("|")[0]
    execution_one = str(uuid4())
    execution_two = str(uuid4())
    session_one = str(uuid4())
    session_two = str(uuid4())
    psql(
        "INSERT INTO aep.executions(execution_id,work_id,session_id,attempt_no,status,lease_until,fence) VALUES "
        f"({lit(execution_one)}::uuid,{lit(work_one)}::uuid,{lit(session_one)}::uuid,1,'running',now()+interval '5 minutes',1),"
        f"({lit(execution_two)}::uuid,{lit(work_two)}::uuid,{lit(session_two)}::uuid,1,'running',now()+interval '5 minutes',1);"
    )
    psql(
        f"UPDATE aep.works SET current_execution_id={lit(execution_one)}::uuid,fence_generation=1 "
        f"WHERE work_id={lit(work_one)}::uuid;"
    )
    if scalar(f"SELECT current_execution_id::text || '|' || fence_generation::text FROM aep.works WHERE work_id={lit(work_one)}::uuid;") != f"{execution_one}|1":
        raise AssertionError("Work current execution/fence projection did not retain the same-work Execution")
    second_active = psql(
        "INSERT INTO aep.executions(work_id,session_id,attempt_no,status,lease_until,fence) VALUES "
        f"({lit(work_one)}::uuid,{lit(str(uuid4()))}::uuid,2,'claimed',now()+interval '5 minutes',2);",
        check=False,
    )
    if second_active.returncode == 0:
        raise AssertionError("More than one active Execution was accepted for one Work")
    print("PASS Stage 1B: Execution attempts, attempt sequence, single-active index, and current Work pointer")

    psql(
        "INSERT INTO aep.resource_claims(resource_id,work_id,execution_id,resource_ref,write_set_kind,conflict_key,status,lease_until,fence) VALUES "
        f"({lit(resource_id)}::uuid,{lit(work_one)}::uuid,{lit(execution_one)}::uuid,'refs/heads/main','repository_ref','*','active',now()+interval '5 minutes',1);"
    )
    resource_race = psql(
        "INSERT INTO aep.resource_claims(resource_id,work_id,execution_id,resource_ref,write_set_kind,conflict_key,status,lease_until,fence) VALUES "
        f"({lit(resource_id)}::uuid,{lit(work_two)}::uuid,{lit(execution_two)}::uuid,'refs/heads/main','repository_ref','*','active',now()+interval '5 minutes',1);",
        check=False,
    )
    if resource_race.returncode == 0:
        raise AssertionError("Two projects claimed the same physical repository/ref conflict key")
    print("PASS Stage 1B: exact physical ResourceClaim uniqueness across two Project namespaces")

    # Relation types are distinct: parent-child metadata and dependency graph edges.
    psql(
        "INSERT INTO aep.work_relations(source_work_id,target_work_id,relation_type,required) VALUES "
        f"({lit(work_one)}::uuid,{lit(work_child)}::uuid,'parent_child',true);"
    )
    invalid_parent = psql(
        "INSERT INTO aep.work_relations(source_work_id,target_work_id,relation_type) VALUES "
        f"({lit(work_one)}::uuid,{lit(work_child)}::uuid,'parent_child');",
        check=False,
    )
    if invalid_parent.returncode == 0:
        raise AssertionError("parent_child relation accepted a missing required/optional value")
    psql(
        "INSERT INTO aep.work_relations(source_work_id,target_work_id,relation_type,dependency_graph_id) VALUES "
        f"({lit(work_one)}::uuid,{lit(work_child)}::uuid,'depends_on',{lit(graph_id)}::uuid);"
    )
    duplicate_left = min(work_one, work_two)
    duplicate_right = max(work_one, work_two)
    psql(
        "INSERT INTO aep.work_relations(source_work_id,target_work_id,relation_type) VALUES "
        f"({lit(duplicate_left)}::uuid,{lit(duplicate_right)}::uuid,'possible_duplicate');"
    )
    print("PASS Stage 1B: typed WorkRelation constraints keep parent_child and depends_on distinct")

    digest = "a" * 64
    evidence_id = scalar(
        "INSERT INTO aep.evidence(project_id,work_id,execution_id,evidence_type,source_ref,source_revision,content_sha256,provenance,payload) VALUES "
        f"({lit(project_id)}::uuid,{lit(work_one)}::uuid,{lit(execution_one)}::uuid,'test_result','ci://run/1','head-sha',{lit(digest)},'{{}}'::jsonb,'{{}}'::jsonb) "
        "RETURNING evidence_id;"
    )
    cross_project_evidence = psql(
        "INSERT INTO aep.evidence(project_id,work_id,evidence_type,source_ref) VALUES "
        f"({lit(project2)}::uuid,{lit(work_one)}::uuid,'test_result','ci://forged-cross-project');",
        check=False,
    )
    if cross_project_evidence.returncode == 0:
        raise AssertionError("Evidence accepted a Work belonging to a different Project")
    evidence_mutation = psql(
        f"UPDATE aep.evidence SET payload='{{}}'::jsonb WHERE evidence_id={lit(evidence_id)}::uuid;",
        check=False,
    )
    if evidence_mutation.returncode == 0 or "append-only" not in evidence_mutation.stderr:
        raise AssertionError("Evidence ledger accepted mutation")
    print("PASS Stage 1B: project-scoped Evidence foreign keys and append-only source ledger")

    receipt_id = scalar(
        "INSERT INTO aep.operation_receipts(work_id,execution_id,provider,operation_key,operation_type,request_payload_sha256,intent_payload) VALUES "
        f"({lit(work_one)}::uuid,{lit(execution_one)}::uuid,'github','create-pr-001','create_pull_request',{lit(digest)},'{{\"head\":\"deadbeef\"}}'::jsonb) "
        "RETURNING operation_receipt_id;"
    )
    psql(
        "INSERT INTO aep.operation_receipt_events(operation_receipt_id,event_type,event_payload) VALUES "
        f"({lit(receipt_id)}::uuid,'intent_created','{{}}'::jsonb);"
    )
    duplicate_receipt = psql(
        "INSERT INTO aep.operation_receipts(work_id,execution_id,provider,operation_key,operation_type,request_payload_sha256,intent_payload) VALUES "
        f"({lit(work_one)}::uuid,{lit(execution_one)}::uuid,'github','create-pr-001','create_pull_request',{lit(digest)},'{{}}'::jsonb);",
        check=False,
    )
    if duplicate_receipt.returncode == 0:
        raise AssertionError("OperationReceipt accepted duplicate provider/operation_key")
    receipt_event_mutation = psql(
        f"UPDATE aep.operation_receipt_events SET event_payload='{{}}'::jsonb WHERE operation_receipt_id={lit(receipt_id)}::uuid;",
        check=False,
    )
    if receipt_event_mutation.returncode == 0 or "append-only" not in receipt_event_mutation.stderr:
        raise AssertionError("OperationReceipt event ledger accepted mutation")
    print("PASS Stage 1B: unique external operation intent and append-only receipt events")

    print("All PostgreSQL prototype tests passed.")


if __name__ == "__main__":
    main()
