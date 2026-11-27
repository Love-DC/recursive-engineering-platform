#!/usr/bin/env python3
"""Stage 4B authorized Context Compiler tests on disposable PostgreSQL 17.12."""

from __future__ import annotations

import json
import os
import re
import subprocess
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
    resource_id = str(uuid4())
    repository_id = "1471589776"
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
    assert_status(unchanged, "recorded", "second session recording same pinned revision")
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
    insert_evidence(
        project_id, work_id, "artifact://stage4b/large-source",
        "LARGE_SOURCE_CONTENT_" * 900,
        "large-source-v1",
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


def main() -> None:
    setup_database()
    project_id, resource_id, work_id, dependency_id, graph_id, grant_decision_id, _ = setup_fixture()
    session_id = str(uuid4())
    pack_id = test_compilation_cache_and_provenance(
        project_id, resource_id, work_id, dependency_id, session_id
    )
    test_state_invalidation(
        project_id, resource_id, work_id, dependency_id,
        session_id, pack_id, grant_decision_id
    )
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
