#!/usr/bin/env python3
"""Disposable PostgreSQL integration tests for the Work Registry prototype."""

from __future__ import annotations

import json
import os
import re
import select
import subprocess
import time
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


def expect_constraint(sql: str, constraint_name: str, description: str) -> None:
    result = psql(sql, check=False)
    if result.returncode == 0 or constraint_name not in result.stderr:
        raise AssertionError(
            f"{description}: expected rejection from {constraint_name}; "
            f"returncode={result.returncode}; stderr={result.stderr}"
        )


def expect_unique_declaration(table: str, definition: str) -> None:
    found = scalar(
        "SELECT count(*) FROM pg_constraint "
        f"WHERE conrelid={lit(table)}::regclass AND contype='u' "
        f"AND convalidated AND pg_get_constraintdef(oid)={lit(definition)};"
    )
    if found != "1":
        raise AssertionError(f"Required unique constraint declaration missing: {table} {definition}")


def register(project_id: str, request_key: str, identity_key: str, *, title: str = "prototype",
             identity_kind: str = "test", identity_version: int = 1,
             session_id: str | None = None, external: dict[str, str] | None = None) -> str:
    session = session_id or str(uuid4())
    ext = "NULL::jsonb" if external is None else lit(json.dumps(external)) + "::jsonb"
    return (
        "SELECT work_id::text || '|' || outcome FROM aep.register_work("
        f"{lit(project_id)}::uuid,{lit(request_key)},{lit(session)}::uuid,"
        f"{lit(identity_kind)},{lit(identity_key)},{identity_version},"
        f"'implementation',{lit(title)},'{{}}'::jsonb,{ext});"
    )


def scalar(sql: str) -> str:
    return psql(sql).stdout.strip()


def main() -> None:
    migrations = sorted(path for path in MIGRATIONS.glob("*.sql") if path.name[:4] <= "0006")
    versions: list[int] = []
    for path in migrations:
        match = re.fullmatch(r"(\d{4})_[a-z0-9_]+\.sql", path.name)
        if not match:
            raise SystemExit(f"Invalid prototype migration filename: {path.name}")
        versions.append(int(match.group(1)))
    if versions != list(range(1, 7)):
        raise SystemExit(f"Expected the Stage 1B baseline migrations 0001..0006, got {versions}")

    psql("DROP DATABASE IF EXISTS aep_test WITH (FORCE);", db="postgres")
    psql("CREATE DATABASE aep_test;", db="postgres")
    env_info = scalar(
        "SELECT current_setting('server_version') || '; LC_COLLATE=' || datcollate "
        "|| '; LC_CTYPE=' || datctype FROM pg_database WHERE datname=current_database();"
    )
    print(f"INFO PostgreSQL integration environment: {env_info}")
    for path in migrations:
        psql(file=path)
    project_id = scalar(
        "INSERT INTO aep.projects(project_key,name) VALUES('prototype','Prototype project') RETURNING project_id;"
    )
    expect_constraint(
        "INSERT INTO aep.projects(project_key,name) VALUES('prototype','Duplicate project key');",
        "projects_project_key_key",
        "Project key uniqueness",
    )
    # These composite unique keys are referenced by foreign keys and include
    # a primary-key column, so duplicate-row probes would be masked by the PK.
    # Verify the exact unique declarations and exercise their referencing FKs below.
    expect_unique_declaration("aep.works", "UNIQUE (project_id, work_id)")
    expect_unique_declaration(
        "aep.work_requests", "UNIQUE (project_id, work_id, request_id)"
    )
    expect_unique_declaration(
        "aep.executions", "UNIQUE (work_id, execution_id)"
    )
    print("PASS schema: composite unique FK targets exist and are validated")
    print("PASS T26: clean PostgreSQL 17 migration and project bootstrap")

    # T01 deterministic rendezvous: both registration sessions must reach a
    # database-side lock barrier before either is allowed into the insert path.
    barrier_key_1 = 21473
    barrier_key_2 = 98121
    psql(f"""
      CREATE FUNCTION public.aep_test_identity_rendezvous() RETURNS trigger
      LANGUAGE plpgsql SET search_path=pg_catalog AS $$
      BEGIN
        IF NEW.identity_key='race-key' THEN
          PERFORM pg_advisory_xact_lock_shared({barrier_key_1}, {barrier_key_2});
        END IF;
        RETURN NEW;
      END $$;
      CREATE TRIGGER aep_test_identity_rendezvous
      BEFORE INSERT ON aep.works
      FOR EACH ROW EXECUTE FUNCTION public.aep_test_identity_rendezvous();
    """)
    env = os.environ.copy()
    env["PGPASSWORD"] = PASSWORD
    psql_cmd = ["psql","-X","-q","-A","-t","-v","ON_ERROR_STOP=1",
                "-h",HOST,"-p",PORT,"-U",USER,"-d",DATABASE]
    controller = subprocess.Popen(
        psql_cmd, text=True, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, env=env, bufsize=1,
    )
    race_procs: list[subprocess.Popen[str]] = []
    outputs: list[str] = []
    try:
        assert controller.stdin is not None and controller.stdout is not None
        controller.stdin.write(
            f"SELECT pg_backend_pid(); SELECT pg_advisory_lock({barrier_key_1}, {barrier_key_2});\n"
        )
        controller.stdin.flush()
        ready, _, _ = select.select([controller.stdout], [], [], 10)
        if not ready:
            raise AssertionError("T01 barrier controller did not return its backend PID")
        controller_pid_text = controller.stdout.readline().strip()
        if not controller_pid_text.isdigit():
            raise AssertionError(f"T01 barrier controller returned invalid PID: {controller_pid_text!r}")
        controller_pid = int(controller_pid_text)

        lock_deadline = time.monotonic() + 10
        while True:
            granted = scalar(
                "SELECT count(*) FROM pg_locks "
                f"WHERE locktype='advisory' AND pid={controller_pid} AND granted "
                f"AND classid={barrier_key_1}::oid AND objid={barrier_key_2}::oid AND objsubid=2;"
            )
            if granted == "1":
                break
            if time.monotonic() >= lock_deadline:
                raise AssertionError("T01 barrier controller did not acquire its advisory lock")
            time.sleep(0.05)

        race_sql = [
            register(project_id, "request-a", "race-key", title="concurrent work"),
            register(project_id, "request-b", "race-key", title="concurrent work"),
        ]
        race_procs = [
            subprocess.Popen(
                psql_cmd + ["-c", sql],
                text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env,
            )
            for sql in race_sql
        ]

        rendezvous_deadline = time.monotonic() + 15
        waiting_sessions = "0"
        while time.monotonic() < rendezvous_deadline:
            if any(proc.poll() is not None for proc in race_procs):
                raise AssertionError("A T01 registration session exited before reaching the rendezvous")
            waiting_sessions = scalar(
                "SELECT count(*) FROM pg_stat_activity "
                f"WHERE pid <> {controller_pid} AND datname=current_database() "
                "AND wait_event_type='Lock' AND wait_event='advisory' "
                "AND query LIKE '%race-key%';"
            )
            if waiting_sessions == "2":
                break
            time.sleep(0.05)
        if waiting_sessions != "2":
            raise AssertionError(
                f"T01 expected two sessions waiting at the database barrier, saw {waiting_sessions}"
            )

        # Closing the controller connection releases the session lock only after
        # both worker backends have demonstrably reached the same rendezvous.
        controller.stdin.close()
        controller.wait(timeout=10)
        controller.stdout.read()
        controller.stderr.read()

        for proc in race_procs:
            out, err = proc.communicate(timeout=20)
            if proc.returncode:
                raise RuntimeError(f"concurrent registration failed: {out}\n{err}")
            outputs.extend(line for line in out.splitlines() if "|" in line)
    finally:
        if controller.poll() is None:
            controller.terminate()
            controller.wait(timeout=5)
        for proc in race_procs:
            if proc.poll() is None:
                proc.terminate()
                proc.communicate(timeout=5)
        psql(
            "DROP TRIGGER IF EXISTS aep_test_identity_rendezvous ON aep.works; "
            "DROP FUNCTION IF EXISTS public.aep_test_identity_rendezvous();",
            check=False,
        )

    ids = {line.split("|",1)[0] for line in outputs}
    outcomes = {line.split("|",1)[1] for line in outputs}
    count = scalar("SELECT count(*) FROM aep.works WHERE identity_key='race-key';")
    if len(ids) != 1 or count != "1" or outcomes != {"created","linked"}:
        raise AssertionError(f"T01 failed: {outputs}; ids={ids}; count={count}")
    print("PASS T01: two sessions reached a DB rendezvous before one canonical Work was committed")

    first = scalar(register(project_id,"same-key","same-key-identity",title="stable title"))
    replay = scalar(register(project_id,"same-key","same-key-identity",title="stable title"))
    if first.split("|")[0] != replay.split("|")[0] or not first.endswith("|created") or not replay.endswith("|replayed"):
        raise AssertionError(f"T02 replay failed: {first}, {replay}")
    changed = psql(register(project_id,"same-key","same-key-identity",title="changed payload"),check=False)
    if changed.returncode == 0 or "idempotency key reused with different payload" not in changed.stderr:
        raise AssertionError(f"T02 payload conflict not enforced: {changed.stderr}")
    expect_constraint(
        "INSERT INTO aep.work_requests(project_id,operation,idempotency_key,request_payload) "
        f"VALUES({lit(project_id)}::uuid,'register_work','same-key','{{}}'::jsonb);",
        "work_requests_project_id_operation_idempotency_key_key",
        "WorkRequest idempotency-key uniqueness",
    )
    print("PASS T02: idempotency replay, payload mismatch, and request-key uniqueness")

    # The first response is intentionally discarded; retry uses a new session_id.
    psql(register(project_id,"lost-response","lost-response-identity",title="lost response"))
    recovered = scalar(register(project_id,"lost-response","lost-response-identity",
                                title="lost response",session_id=str(uuid4())))
    if not recovered.endswith("|replayed") or scalar(
        "SELECT count(*) FROM aep.works WHERE identity_key='lost-response-identity';"
    ) != "1":
        raise AssertionError(f"T03 lost-response recovery failed: {recovered}")
    expect_constraint(
        "INSERT INTO aep.works(project_id,identity_kind,identity_key,identity_version,work_type,title) "
        f"VALUES({lit(project_id)}::uuid,'test','same-key-identity',1,'implementation','duplicate identity');",
        "works_active_identity_uq",
        "Active canonical Work identity uniqueness",
    )
    padded_identity = psql(
        register(project_id,"padded-identity"," same-key-identity ",title="padded alias"),
        check=False,
    )
    padded_kind = psql(
        register(project_id,"padded-kind","kind-identity",identity_kind=" test ",title="padded kind"),
        check=False,
    )
    unsupported_identity_version = psql(
        register(project_id,"unsupported-identity-version","versioned-key",
                 identity_version=2,title="unsupported identity version"),
        check=False,
    )
    if padded_identity.returncode == 0 or padded_kind.returncode == 0 or unsupported_identity_version.returncode == 0:
        raise AssertionError("Work registration accepted padded identity input or an undefined identity version")

    case_upper_work = scalar(
        register(project_id, "case-upper", "CaseSensitiveIdentity", title="case upper")
    ).split("|", 1)[0]
    case_lower_work = scalar(
        register(project_id, "case-lower", "casesensitiveidentity", title="case lower")
    ).split("|", 1)[0]
    if case_upper_work == case_lower_work:
        raise AssertionError("Work identity v1 unexpectedly case-folded distinct identity keys")

    nfc_work = scalar(
        register(project_id, "unicode-nfc", "\u00e9", title="Unicode NFC identity")
    ).split("|", 1)[0]
    nfd_work = scalar(
        register(project_id, "unicode-nfd", "e\u0301", title="Unicode NFD identity")
    ).split("|", 1)[0]
    if nfc_work == nfd_work:
        raise AssertionError("Work identity v1 unexpectedly normalized Unicode NFC/NFD identity keys")
    if scalar(
        "SELECT count(*) FROM aep.works "
        "WHERE project_id=" + lit(project_id) + "::uuid "
        "AND identity_kind='test' AND identity_key='same-key-identity' AND identity_version=1;"
    ) != "1":
        raise AssertionError("Padded Work identity alias created a second active Work")
    direct_padded = psql(
        "INSERT INTO aep.works(project_id,identity_kind,identity_key,identity_version,work_type,title) "
        f"VALUES({lit(project_id)}::uuid,'test',' padded-direct ',1,'implementation','padded direct');",
        check=False,
    )
    if direct_padded.returncode == 0:
        raise AssertionError("Direct Work insert bypassed canonical identity input constraints")
    print("PASS Stage 1 identity invariants: edge whitespace rejected; exact case and Unicode NFC/NFD text preserved")

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
    work_rollback_count = scalar("SELECT count(*) FROM aep.works WHERE identity_key='different-work';")
    request_rollback_count = scalar(
        "SELECT count(*) FROM aep.work_requests WHERE project_id=" + lit(project_id) +
        "::uuid AND idempotency_key='ext-conflict';"
    )
    unemitted_event_count = scalar(
        "SELECT count(*) FROM aep.work_events WHERE event_payload->>'request_key'='ext-conflict';"
    )
    if (
        conflict.returncode == 0
        or work_rollback_count != "0"
        or request_rollback_count != "0"
        or unemitted_event_count != "0"
    ):
        raise AssertionError(
            "T21 ExternalRef conflict must roll back Work and WorkRequest and emit no WorkEvent "
            f"(counts={work_rollback_count}/{request_rollback_count}/{unemitted_event_count})"
        )
    external_ref_unique_name = scalar(
        "SELECT conname FROM pg_constraint "
        "WHERE conrelid='aep.external_refs'::regclass AND contype='u' "
        "AND pg_get_constraintdef(oid)='UNIQUE (provider, host, resource_key, object_type, external_id)';"
    )
    if not external_ref_unique_name:
        raise AssertionError("ExternalRef composite unique constraint is missing")
    expect_constraint(
        "INSERT INTO aep.external_refs(provider,host,resource_key,object_type,external_id,work_id) "
        f"VALUES('github','github.com','repo:1471589776','issue','600001',{lit(ext_a.split('|')[0])}::uuid);",
        external_ref_unique_name,
        "ExternalRef physical external-object uniqueness",
    )
    print("PASS T21 slice: ExternalRef uniqueness; Work and WorkRequest rollback; no WorkEvent emitted")

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
        || '|' || has_function_privilege('aep_runtime','aep.create_dependency_graph(uuid)','EXECUTE')::text
        || '|' || has_function_privilege('aep_runtime','aep.set_dependency_graph_member(uuid,uuid,text,uuid)','EXECUTE')::text
        || '|' || has_function_privilege('aep_runtime','aep.mutate_dependencies(uuid,text,jsonb)','EXECUTE')::text
        || '|' || has_function_privilege('aep_runtime','aep.set_work_ready(uuid)','EXECUTE')::text
        || '|' || (NOT has_table_privilege('aep_runtime','aep.works','SELECT'))::text
        || '|' || (NOT has_table_privilege('aep_runtime','aep.dependency_graph_works','SELECT'))::text
        || '|' || (NOT has_table_privilege('aep_runtime','aep.dependency_graph_operations','SELECT'))::text
        || '|' || (SELECT bool_and(relrowsecurity AND relforcerowsecurity)::text
                   FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
                   WHERE n.nspname='aep' AND c.relkind='r');
    """)
    security_flags = security.split("|")
    expected = ["true", "true", "search_path=pg_catalog,aep", "true", "true", "true", "true", "true", "true", "true", "true", "true", "true"]
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
        "VALUES('github','github.com','repository','1471589776','repository:1471589776','recursive-engineering-platform') "
        "RETURNING resource_id;"
    )
    psql(
        f"INSERT INTO aep.project_resources(project_id,resource_id,access_mode) VALUES "
        f"({lit(project_id)}::uuid,{lit(resource_id)}::uuid,'read'),"
        f"({lit(project2)}::uuid,{lit(resource_id)}::uuid,'read');"
    )
    if scalar(f"SELECT count(*) FROM aep.project_resources WHERE resource_id={lit(resource_id)}::uuid;") != "2":
        raise AssertionError("One physical resource could not be referenced by two project namespaces")
    missing_project_grant = psql(
        f"INSERT INTO aep.project_resources(project_id,resource_id,access_mode) "
        f"VALUES({lit(project2)}::uuid,{lit(resource_id)}::uuid,'write');",
        check=False,
    )
    if missing_project_grant.returncode == 0:
        raise AssertionError("ProjectResource accepted write access without an OwnerDecision reference")
    duplicate_resource = psql(
        "INSERT INTO aep.resources(provider,host,resource_type,stable_resource_id,canonical_key) "
        "VALUES('github','github.com','repository','1471589776','repository:1471589776');",
        check=False,
    )
    if duplicate_resource.returncode == 0 or "resources_normalized_physical_identity_uq" not in duplicate_resource.stderr:
        raise AssertionError(
            "Duplicate provider-stable Resource identity was not rejected by normalized physical uniqueness: "
            f"{duplicate_resource.stderr}"
        )
    expect_constraint(
        "INSERT INTO aep.resources(provider,host,resource_type,stable_resource_id,canonical_key) "
        "VALUES('GitHub','github.com','repository','case-provider','repository:case-provider');",
        "resources_provider_canonical_ck",
        "Resource provider canonical form",
    )
    expect_constraint(
        "INSERT INTO aep.resources(provider,host,resource_type,stable_resource_id,canonical_key) "
        "VALUES('github','GITHUB.COM','repository','case-host','repository:case-host');",
        "resources_host_canonical_ck",
        "Resource host canonical form",
    )
    expect_constraint(
        "INSERT INTO aep.resources(provider,host,resource_type,stable_resource_id,canonical_key) "
        "VALUES('github','github.com','Repository','case-type','Repository:case-type');",
        "resources_type_canonical_ck",
        "Resource type canonical form",
    )
    expect_constraint(
        "INSERT INTO aep.resources(provider,host,resource_type,stable_resource_id,canonical_key) "
        "VALUES('githubé','github.com','repository','non-ascii-provider','repository:non-ascii-provider');",
        "resources_provider_canonical_ck",
        "Non-ASCII Resource provider is rejected by its named canonical constraint",
    )
    expect_constraint(
        "INSERT INTO aep.resources(provider,host,resource_type,stable_resource_id,canonical_key) "
        "VALUES('github','github.com','repositoryé','non-ascii-type','repositoryé:non-ascii-type');",
        "resources_type_canonical_ck",
        "Non-ASCII Resource type is rejected by its named canonical constraint",
    )
    expect_constraint(
        "INSERT INTO aep.resources(provider,host,resource_type,stable_resource_id,canonical_key) "
        "VALUES('github','githubé.com','repository','non-ascii-host','repository:non-ascii-host');",
        "resources_host_canonical_ck",
        "Non-ASCII Resource host label is rejected by its named canonical constraint",
    )
    expect_constraint(
        "INSERT INTO aep.resources(provider,host,resource_type,stable_resource_id,canonical_key) "
        "VALUES('github','github.com','repository','opaque-id','repository:contradictory-id');",
        "resources_canonical_key_matches_identity_ck",
        "Resource canonical_key projection",
    )
    opaque_case_one = scalar(
        "INSERT INTO aep.resources(provider,host,resource_type,stable_resource_id,canonical_key) "
        "VALUES('github','github.com','repository','CaseSensitiveID','repository:CaseSensitiveID') "
        "RETURNING resource_id;"
    )
    opaque_case_two = scalar(
        "INSERT INTO aep.resources(provider,host,resource_type,stable_resource_id,canonical_key) "
        "VALUES('github','github.com','repository','casesensitiveid','repository:casesensitiveid') "
        "RETURNING resource_id;"
    )
    if opaque_case_one == opaque_case_two:
        raise AssertionError("Opaque stable_resource_id values were incorrectly case-folded")
    duplicate_project_resource = psql(
        "INSERT INTO aep.project_resources(project_id,resource_id,access_mode) "
        f"VALUES({lit(project_id)}::uuid,{lit(resource_id)}::uuid,'read');",
        check=False,
    )
    if duplicate_project_resource.returncode == 0 or "project_resources_pkey" not in duplicate_project_resource.stderr:
        raise AssertionError("ProjectResource primary-key uniqueness was not independently exercised")
    owner_access = scalar(
        "SET ROLE aep_owner; SELECT "
        "(SELECT count(*) FROM aep.owner_decisions) + "
        "(SELECT count(*) FROM aep.resources) + "
        "(SELECT count(*) FROM aep.project_resources) + "
        "(SELECT count(*) FROM aep.dependency_graphs) + "
        "(SELECT count(*) FROM aep.dependency_graph_members) + "
        "(SELECT count(*) FROM aep.executions) + "
        "(SELECT count(*) FROM aep.resource_claims) + "
        "(SELECT count(*) FROM aep.work_relations) + "
        "(SELECT count(*) FROM aep.dependency_graph_works) + "
        "(SELECT count(*) FROM aep.dependency_graph_operations) + "
        "(SELECT count(*) FROM aep.evidence) + "
        "(SELECT count(*) FROM aep.operation_receipts) + "
        "(SELECT count(*) FROM aep.operation_receipt_events); RESET ROLE;"
    )
    if not owner_access.isdigit():
        raise AssertionError(f"Non-bypass owner role could not access all RLS-protected Stage 1B tables: {owner_access}")
    print("PASS Stage 1B: non-bypass owner role owns and accesses all new RLS-protected tables")
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
    owner_version_constraint = scalar(
        "SELECT conname FROM pg_constraint WHERE conrelid='aep.owner_decisions'::regclass "
        "AND contype='u' "
        "AND pg_get_constraintdef(oid)='UNIQUE (scope_type, scope_key, decision_key, decision_version)';"
    )
    if not owner_version_constraint:
        raise AssertionError("OwnerDecision scoped-version unique constraint is missing")
    expect_constraint(
        "INSERT INTO aep.owner_decisions(scope_type,scope_key,decision_key,statement,decision_version,status) "
        "VALUES('project','prototype','future-write-grant','Duplicate version',1,'proposed');",
        owner_version_constraint,
        "OwnerDecision scoped-version uniqueness",
    )
    psql(
        "INSERT INTO aep.owner_decisions(scope_type,scope_key,decision_key,statement,decision_version,status,"
        "approval_source_kind,approval_source_ref,approver_principal,approval_provenance,approved_at) "
        "VALUES('project','prototype','single-approval','Approved v1',1,'approved',"
        "'direct_owner_message','test://owner-approval','test-owner',"
        "jsonb_build_object('direct_owner_confirmation',true),now());"
    )
    expect_constraint(
        "INSERT INTO aep.owner_decisions(scope_type,scope_key,decision_key,statement,decision_version,status,"
        "approval_source_kind,approval_source_ref,approver_principal,approval_provenance,approved_at) "
        "VALUES('project','prototype','single-approval','Approved v2',2,'approved',"
        "'direct_owner_message','test://owner-approval-v2','test-owner',"
        "jsonb_build_object('direct_owner_confirmation',true),now());",
        "owner_decisions_one_current_approval_uq",
        "One current OwnerDecision approval per scoped decision",
    )
    print("PASS Stage 1B: OwnerDecision unique version and one-current-approval constraints")

    # Shared graph membership is added through the RPC and carries an exact
    # graph/project/access-scoped direct-Owner grant, including read access.
    graph_id = scalar(
        "SELECT aep.create_dependency_graph("
        f"{lit(project_id)}::uuid);"
    )
    read_decision = scalar(
        "INSERT INTO aep.owner_decisions("
        "scope_type,scope_key,decision_key,statement,decision_version,status,"
        "approval_source_kind,approval_source_ref,approver_principal,"
        "approval_provenance,approved_at"
        ") VALUES("
        f"'project',{lit(project2)},{lit('dependency_graph:'+graph_id+':read')},"
        "'Approved read access to the shared dependency graph',1,'approved',"
        "'direct_owner_message','test://owner/dependency-graph-read','test-owner',"
        "jsonb_build_object('direct_owner_confirmation',true),clock_timestamp()"
        ") RETURNING decision_id;"
    )
    psql(
        "SELECT aep.set_dependency_graph_member("
        f"{lit(graph_id)}::uuid,{lit(project2)}::uuid,'read',{lit(read_decision)}::uuid);"
    )
    expect_constraint(
        "INSERT INTO aep.dependency_graph_members(graph_id,project_id,access_mode) "
        f"VALUES({lit(graph_id)}::uuid,{lit(project_id)}::uuid,'owner');",
        "dependency_graph_members_pkey",
        "DependencyGraphMember pair uniqueness",
    )
    project3 = scalar(
        "INSERT INTO aep.projects(project_key,name) VALUES('prototype-three','Third project') RETURNING project_id;"
    )
    expect_constraint(
        "INSERT INTO aep.dependency_graph_members(graph_id,project_id,access_mode) "
        f"VALUES({lit(graph_id)}::uuid,{lit(project3)}::uuid,'owner');",
        "dependency_graph_one_owner_uq",
        "One owner membership per dependency graph",
    )
    missing_graph_grant = psql(
        f"UPDATE aep.dependency_graph_members "
        f"SET access_mode='write',grant_decision_id=NULL "
        f"WHERE graph_id={lit(graph_id)}::uuid AND project_id={lit(project2)}::uuid;",
        check=False,
    )
    if missing_graph_grant.returncode == 0:
        raise AssertionError("Shared graph write membership was accepted without a grant reference")

    work_one = scalar(register(project_id,"model-work-one","model-work-one",title="Model work one")).split("|")[0]
    work_two = scalar(register(project2,"model-work-two","model-work-two",title="Model work two")).split("|")[0]
    work_child = scalar(register(project_id,"model-work-child","model-work-child",title="Model child")).split("|")[0]
    # Composite project/work references prevent cross-project request and event rows.
    wrong_request_scope = psql(
        "INSERT INTO aep.work_requests(project_id,operation,idempotency_key,request_payload,work_id) VALUES "
        f"({lit(project2)}::uuid,'register_work','forged-work-link','{{}}'::jsonb,{lit(work_one)}::uuid);",
        check=False,
    )
    wrong_event_scope = psql(
        "INSERT INTO aep.work_events(project_id,work_id,event_type,session_id) VALUES "
        f"({lit(project2)}::uuid,{lit(work_one)}::uuid,'work_registered',{lit(str(uuid4()))}::uuid);",
        check=False,
    )
    if wrong_request_scope.returncode == 0 or wrong_event_scope.returncode == 0:
        raise AssertionError("WorkRequest or WorkEvent accepted a cross-project Work reference")
    work_one_request = scalar(
        "SELECT request_id::text FROM aep.work_requests WHERE idempotency_key='model-work-one';"
    )
    work_child_request = scalar(
        "SELECT request_id::text FROM aep.work_requests WHERE idempotency_key='model-work-child';"
    )
    psql(
        "INSERT INTO aep.work_events(project_id,work_id,request_id,event_type,session_id) VALUES "
        f"({lit(project_id)}::uuid,{lit(work_one)}::uuid,{lit(work_one_request)}::uuid,"
        f"'request_replayed',{lit(str(uuid4()))}::uuid);"
    )
    null_request_event = scalar(
        "INSERT INTO aep.work_events(project_id,work_id,request_id,event_type,session_id) VALUES "
        f"({lit(project_id)}::uuid,{lit(work_one)}::uuid,NULL,'request_replayed',{lit(str(uuid4()))}::uuid) "
        "RETURNING event_id;"
    )
    if not null_request_event:
        raise AssertionError("A valid WorkEvent with NULL request_id was not accepted")
    expect_constraint(
        "INSERT INTO aep.work_events(project_id,work_id,request_id,event_type,session_id) VALUES "
        f"({lit(project_id)}::uuid,{lit(work_one)}::uuid,{lit(work_child_request)}::uuid,"
        f"'request_replayed',{lit(str(uuid4()))}::uuid);",
        "work_events_project_work_request_fk",
        "WorkEvent request must belong to the same Work",
    )
    print("PASS Stage 1B: WorkEvent request scope is enforced; valid WorkEvent with NULL request_id remains allowed")

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
    wrong_current_execution = psql(
        f"UPDATE aep.works SET current_execution_id={lit(execution_two)}::uuid WHERE work_id={lit(work_one)}::uuid;",
        check=False,
    )
    if wrong_current_execution.returncode == 0:
        raise AssertionError("Work accepted an Execution belonging to a different Work")

    duplicate_attempt_no = psql(
        "INSERT INTO aep.executions(work_id,session_id,attempt_no,status,fence,finished_at) VALUES "
        f"({lit(work_one)}::uuid,{lit(str(uuid4()))}::uuid,1,'failed',99,now());",
        check=False,
    )
    if duplicate_attempt_no.returncode == 0 or "executions_work_id_attempt_no_key" not in duplicate_attempt_no.stderr:
        raise AssertionError(
            "T05 did not independently exercise UNIQUE(work_id, attempt_no): "
            f"{duplicate_attempt_no.stderr}"
        )
    duplicate_fence = psql(
        "INSERT INTO aep.executions(work_id,session_id,attempt_no,status,fence,finished_at) VALUES "
        f"({lit(work_one)}::uuid,{lit(str(uuid4()))}::uuid,99,'failed',1,now());",
        check=False,
    )
    if duplicate_fence.returncode == 0 or "executions_work_id_fence_key" not in duplicate_fence.stderr:
        raise AssertionError(
            "T05 did not independently exercise UNIQUE(work_id, fence): "
            f"{duplicate_fence.stderr}"
        )
    second_active = psql(
        "INSERT INTO aep.executions(work_id,session_id,attempt_no,status,lease_until,fence) VALUES "
        f"({lit(work_one)}::uuid,{lit(str(uuid4()))}::uuid,2,'claimed',now()+interval '5 minutes',2);",
        check=False,
    )
    if second_active.returncode == 0 or "executions_one_active_per_work_uq" not in second_active.stderr:
        raise AssertionError("More than one active Execution was not rejected by its partial unique index")
    print("PASS Stage 1B: per-Work attempt/fence uniqueness independently tested outside the active index")

    other_provider_resource = scalar(
        "INSERT INTO aep.resources(provider,host,resource_type,stable_resource_id,canonical_key) "
        "VALUES('gitlab','gitlab.com','repository','project-42','repository:project-42') "
        "RETURNING resource_id;"
    )
    psql(
        "INSERT INTO aep.project_resources(project_id,resource_id,access_mode) "
        f"VALUES({lit(project_id)}::uuid,{lit(other_provider_resource)}::uuid,'read');"
    )
    expect_constraint(
        "INSERT INTO aep.resource_claims(project_id,resource_id,work_id,execution_id,resource_ref,write_set_kind,conflict_key,status,lease_until,fence) "
        f"VALUES({lit(project_id)}::uuid,{lit(other_provider_resource)}::uuid,{lit(work_one)}::uuid,{lit(execution_one)}::uuid,'refs/heads/main','repository_ref','*','reserved',now()+interval '5 minutes',1);",
        "resource_claims_repository_ref_provider_supported_ck",
        "Unspecified provider ref contracts fail closed rather than using Git normalization",
    )
    psql(
        "INSERT INTO aep.resource_claims(project_id,resource_id,work_id,execution_id,resource_ref,write_set_kind,conflict_key,status,lease_until,fence) VALUES "
        f"({lit(project_id)}::uuid,{lit(resource_id)}::uuid,{lit(work_one)}::uuid,{lit(execution_one)}::uuid,'refs/heads/main','repository_ref','*','active',now()+interval '5 minutes',1);"
    )
    # Git permits a component to end in a dot when the complete ref does not.
    # Exercise the INSERT trigger, not only the validator function.
    psql(
        "INSERT INTO aep.resource_claims(project_id,resource_id,work_id,execution_id,resource_ref,write_set_kind,conflict_key,status,lease_until,fence) VALUES "
        f"({lit(project_id)}::uuid,{lit(resource_id)}::uuid,{lit(work_one)}::uuid,{lit(execution_one)}::uuid,'refs/heads/foo./bar','repository_ref','*','active',now()+interval '5 minutes',1);"
    )
    # U+0085 is a non-ASCII Unicode character accepted by Git; it must not be
    # rejected merely because the database locale classifies it as control-like.
    psql(
        "INSERT INTO aep.resource_claims(project_id,resource_id,work_id,execution_id,resource_ref,write_set_kind,conflict_key,status,lease_until,fence) VALUES "
        f"({lit(project_id)}::uuid,{lit(resource_id)}::uuid,{lit(work_one)}::uuid,{lit(execution_one)}::uuid,{lit('refs/heads/foo\u0085bar')},'repository_ref','*','active',now()+interval '5 minutes',1);"
    )
    # Build ASCII control characters with chr() so the SQL test source remains
    # printable while exercising the INSERT trigger boundary.
    expect_constraint(
        "INSERT INTO aep.resource_claims(project_id,resource_id,work_id,execution_id,resource_ref,write_set_kind,conflict_key,status,lease_until,fence) "
        f"VALUES({lit(project2)}::uuid,{lit(resource_id)}::uuid,{lit(work_two)}::uuid,{lit(execution_two)}::uuid,'refs/heads/ascii-' || chr(1) || '-control','repository_ref','*','active',now()+interval '5 minutes',1);",
        "resource_claims_github_branch_ref_canonical_ck",
        "ASCII C0 control U+0001 is rejected by the ResourceClaim INSERT trigger",
    )
    expect_constraint(
        "INSERT INTO aep.resource_claims(project_id,resource_id,work_id,execution_id,resource_ref,write_set_kind,conflict_key,status,lease_until,fence) "
        f"VALUES({lit(project2)}::uuid,{lit(resource_id)}::uuid,{lit(work_two)}::uuid,{lit(execution_two)}::uuid,'refs/heads/ascii-' || chr(127) || '-del','repository_ref','*','active',now()+interval '5 minutes',1);",
        "resource_claims_github_branch_ref_canonical_ck",
        "ASCII DEL U+007F is rejected by the ResourceClaim INSERT trigger",
    )
    expect_constraint(
        "INSERT INTO aep.resource_claims(project_id,resource_id,work_id,execution_id,resource_ref,write_set_kind,conflict_key,status,lease_until,fence) "
        f"VALUES({lit(project2)}::uuid,{lit(resource_id)}::uuid,{lit(work_two)}::uuid,{lit(execution_two)}::uuid,'refs/heads/foo.','repository_ref','*','active',now()+interval '5 minutes',1);",
        "resource_claims_github_branch_ref_canonical_ck",
        "Git rejects a branch ref whose complete ref ends with a dot",
    )
    # The active fully-qualified branch claim above represents the same physical
    # ref as the shorthand alias "main". The alias cannot create a second
    # reserved/active claim because the database rejects non-canonical refs.
    expect_constraint(
        "INSERT INTO aep.resource_claims(project_id,resource_id,work_id,execution_id,resource_ref,write_set_kind,conflict_key,status,lease_until,fence) "
        f"VALUES({lit(project2)}::uuid,{lit(resource_id)}::uuid,{lit(work_two)}::uuid,{lit(execution_two)}::uuid,'main','repository_ref','*','reserved',now()+interval '5 minutes',1);",
        "resource_claims_github_branch_ref_canonical_ck",
        "GitHub branch shorthand alias cannot coexist with an active full-ref claim",
    )
    expect_constraint(
        "INSERT INTO aep.resource_claims(project_id,resource_id,work_id,execution_id,resource_ref,write_set_kind,conflict_key,status,lease_until,fence) "
        f"VALUES({lit(project2)}::uuid,{lit(resource_id)}::uuid,{lit(work_two)}::uuid,{lit(execution_two)}::uuid,'HEAD','repository_ref','*','active',now()+interval '5 minutes',1);",
        "resource_claims_github_branch_ref_canonical_ck",
        "Git symbolic HEAD alias is rejected",
    )
    expect_constraint(
        "INSERT INTO aep.resource_claims(project_id,resource_id,work_id,execution_id,resource_ref,write_set_kind,conflict_key,status,lease_until,fence) "
        f"VALUES({lit(project2)}::uuid,{lit(resource_id)}::uuid,{lit(work_two)}::uuid,{lit(execution_two)}::uuid,'refs/remotes/origin/HEAD','repository_ref','*','active',now()+interval '5 minutes',1);",
        "resource_claims_github_branch_ref_canonical_ck",
        "Git remote symbolic HEAD alias is rejected",
    )
    expect_constraint(
        "INSERT INTO aep.resource_claims(project_id,resource_id,work_id,execution_id,resource_ref,write_set_kind,conflict_key,status,lease_until,fence) "
        f"VALUES({lit(project2)}::uuid,{lit(resource_id)}::uuid,{lit(work_two)}::uuid,{lit(execution_two)}::uuid,'refs/heads/feature..invalid','repository_ref','*','active',now()+interval '5 minutes',1);",
        "resource_claims_github_branch_ref_canonical_ck",
        "Malformed fully-qualified Git refs are rejected",
    )
    if scalar(
        "SELECT count(*) FROM aep.resource_claims "
        f"WHERE resource_id={lit(resource_id)}::uuid AND resource_ref='refs/heads/main' "
        "AND status IN ('reserved','active');"
    ) != "1":
        raise AssertionError("A shorthand/symbolic alias created a second reserved/active claim for the same GitHub branch")
    resource_race = psql(
        "INSERT INTO aep.resource_claims(project_id,resource_id,work_id,execution_id,resource_ref,write_set_kind,conflict_key,status,lease_until,fence) VALUES "
        f"({lit(project2)}::uuid,{lit(resource_id)}::uuid,{lit(work_two)}::uuid,{lit(execution_two)}::uuid,'refs/heads/main','repository_ref','*','active',now()+interval '5 minutes',1);",
        check=False,
    )
    if resource_race.returncode == 0 or "resource_claims_active_exact_conflict_uq" not in resource_race.stderr:
        raise AssertionError(
            "Two projects were not excluded by the active whole-ref ResourceClaim unique index: "
            f"{resource_race.stderr}"
        )
    expect_constraint(
        "INSERT INTO aep.resource_claims(project_id,resource_id,work_id,execution_id,resource_ref,write_set_kind,conflict_key,status,lease_until,fence) "
        f"VALUES({lit(project2)}::uuid,{lit(resource_id)}::uuid,{lit(work_two)}::uuid,{lit(execution_two)}::uuid,'refs/heads/other-key','repository_ref','other','active',now()+interval '5 minutes',1);",
        "resource_claims_repository_ref_whole_key_ck",
        "Repository-ref claims cannot choose a bypass conflict_key",
    )
    expect_constraint(
        "INSERT INTO aep.resource_claims(project_id,resource_id,work_id,execution_id,resource_ref,write_set_kind,conflict_key,status,lease_until,fence) "
        f"VALUES({lit(project2)}::uuid,{lit(resource_id)}::uuid,{lit(work_two)}::uuid,{lit(execution_two)}::uuid,'refs/heads/main','path_set','path:/src','active',now()+interval '5 minutes',1);",
        "resource_claims_active_requires_repository_ref_ck",
        "Active path_set claims are rejected until overlap locking exists",
    )
    expect_constraint(
        "INSERT INTO aep.resource_claims(project_id,resource_id,work_id,execution_id,resource_ref,write_set_kind,conflict_key,status,lease_until,fence) "
        f"VALUES({lit(project2)}::uuid,{lit(resource_id)}::uuid,{lit(work_two)}::uuid,{lit(execution_two)}::uuid,'refs/heads/main','path_set','path:/src','reserved',now()+interval '5 minutes',1);",
        "resource_claims_active_requires_repository_ref_ck",
        "Reserved path_set claims are rejected until overlap locking exists",
    )
    expect_constraint(
        "INSERT INTO aep.resource_claims(project_id,resource_id,work_id,execution_id,resource_ref,write_set_kind,conflict_key,status,lease_until,fence) "
        f"VALUES({lit(project2)}::uuid,{lit(opaque_case_one)}::uuid,{lit(work_two)}::uuid,{lit(execution_two)}::uuid,'refs/heads/fk-project-resource','repository_ref','*','active',now()+interval '5 minutes',1);",
        "resource_claims_project_id_resource_id_fkey",
        "ResourceClaim must reference a ProjectResource pair",
    )
    expect_constraint(
        "INSERT INTO aep.resource_claims(project_id,resource_id,work_id,execution_id,resource_ref,write_set_kind,conflict_key,status,lease_until,fence) "
        f"VALUES({lit(project2)}::uuid,{lit(resource_id)}::uuid,{lit(work_one)}::uuid,{lit(execution_one)}::uuid,'refs/heads/fk-project-work','repository_ref','*','active',now()+interval '5 minutes',1);",
        "resource_claims_project_id_work_id_fkey",
        "ResourceClaim Work must belong to its project",
    )
    expect_constraint(
        "INSERT INTO aep.resource_claims(project_id,resource_id,work_id,execution_id,resource_ref,write_set_kind,conflict_key,status,lease_until,fence) "
        f"VALUES({lit(project_id)}::uuid,{lit(resource_id)}::uuid,{lit(work_one)}::uuid,{lit(execution_two)}::uuid,'refs/heads/fk-work-execution','repository_ref','*','active',now()+interval '5 minutes',1);",
        "resource_claims_work_id_execution_id_fkey",
        "ResourceClaim Execution must belong to its Work",
    )
    print("PASS Stage 1B: whole-ref exclusion, no path_set overclaim, and all three ResourceClaim composite FKs")

    # Relation types are distinct: parent-child metadata and dependency graph edges.
    psql(
        "INSERT INTO aep.work_relations(source_work_id,target_work_id,relation_type,required) VALUES "
        f"({lit(work_one)}::uuid,{lit(work_child)}::uuid,'parent_child',true);"
    )
    expect_constraint(
        "INSERT INTO aep.work_relations(source_work_id,target_work_id,relation_type,required) VALUES "
        f"({lit(work_one)}::uuid,{lit(work_child)}::uuid,'parent_child',false);",
        "work_relations_active_exact_uq",
        "Active WorkRelation exact uniqueness",
    )
    invalid_parent = psql(
        "INSERT INTO aep.work_relations(source_work_id,target_work_id,relation_type) VALUES "
        f"({lit(work_one)}::uuid,{lit(work_child)}::uuid,'parent_child');",
        check=False,
    )
    if invalid_parent.returncode == 0:
        raise AssertionError("parent_child relation accepted a missing required/optional value")
    psql(
        "SELECT aep.mutate_dependencies("
        f"{lit(graph_id)}::uuid,{lit(str(uuid4()))},"
        "jsonb_build_array(jsonb_build_object("
        "'op','add',"
        f"'source_work_id',{lit(work_child)},"
        f"'target_work_id',{lit(work_one)}"
        ")));"
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

    intent_payload = lit(json.dumps({"head": "deadbeef"})) + "::jsonb"
    receipt_id = scalar(
        "INSERT INTO aep.operation_receipts(work_id,execution_id,provider,operation_key,operation_type,request_payload_sha256,intent_payload) VALUES "
        f"({lit(work_one)}::uuid,{lit(execution_one)}::uuid,'github','create-pr-001','create_pull_request',{lit(digest)},{intent_payload}) "
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
    if duplicate_receipt.returncode == 0 or "operation_receipts_provider_operation_key_key" not in duplicate_receipt.stderr:
        raise AssertionError(
            "OperationReceipt provider/operation_key uniqueness was not independently exercised: "
            f"{duplicate_receipt.stderr}"
        )
    valid_work_only_receipt = scalar(
        "INSERT INTO aep.operation_receipts(work_id,execution_id,provider,operation_key,operation_type,request_payload_sha256,intent_payload) "
        f"VALUES({lit(work_one)}::uuid,NULL,'github','create-pr-work-only','create_pull_request',{lit(digest)},'{{}}'::jsonb) "
        "RETURNING operation_receipt_id;"
    )
    if not valid_work_only_receipt:
        raise AssertionError("OperationReceipt with an existing Work and NULL execution_id was rejected")
    missing_work_receipt = psql(
        "INSERT INTO aep.operation_receipts(work_id,execution_id,provider,operation_key,operation_type,request_payload_sha256,intent_payload) "
        f"VALUES('00000000-0000-0000-0000-000000000001'::uuid,NULL,'github','missing-work','create_pull_request',{lit(digest)},'{{}}'::jsonb);",
        check=False,
    )
    if missing_work_receipt.returncode == 0 or "operation_receipts_work_exists_fk" not in missing_work_receipt.stderr:
        raise AssertionError(
            "OperationReceipt accepted a non-existent Work with NULL execution_id: "
            f"{missing_work_receipt.stderr}"
        )
    mismatched_work_execution_receipt = psql(
        "INSERT INTO aep.operation_receipts(work_id,execution_id,provider,operation_key,operation_type,request_payload_sha256,intent_payload) "
        f"VALUES({lit(work_one)}::uuid,{lit(execution_two)}::uuid,'github','mismatched-execution','create_pull_request',{lit(digest)},'{{}}'::jsonb);",
        check=False,
    )
    if mismatched_work_execution_receipt.returncode == 0 or "operation_receipts_work_id_execution_id_fkey" not in mismatched_work_execution_receipt.stderr:
        raise AssertionError(
            "OperationReceipt accepted an Execution belonging to another Work: "
            f"{mismatched_work_execution_receipt.stderr}"
        )
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
