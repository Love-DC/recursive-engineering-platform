#!/usr/bin/env python3
"""Stage 4C derived-memory tests on disposable PostgreSQL 17.12."""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path
from uuid import uuid4

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import test_stage4b_context_compiler as stage4b  # noqa: E402

DATABASE = "aep_stage4c_memory"
_original_psql = stage4b.psql


def psql(sql: str | None = None, *, db: str = stage4b.DATABASE,
         file: Path | None = None, check: bool = True):
    # Reuse the established Stage 4B connection/process helpers without touching
    # its independent 0001..0010 runner or database.
    target_db = DATABASE if db == stage4b.DATABASE else db
    return _original_psql(sql, db=target_db, file=file, check=check)


stage4b.psql = psql


def scalar(sql: str) -> str:
    return stage4b.scalar(sql)


def lit(value: str) -> str:
    return stage4b.lit(value)


def json_sql(value: dict | list) -> str:
    return stage4b.json_sql(value)


def json_result(sql: str) -> dict:
    return stage4b.json_result(sql)


def setup_database() -> None:
    paths = sorted((ROOT / "db" / "prototype").glob("*.sql"))
    versions = [int(path.name[:4]) for path in paths]
    if versions != list(range(1, 12)):
        raise AssertionError(f"Expected clean ordered migrations 0001..0011, got {versions}")

    psql(f"DROP DATABASE IF EXISTS {DATABASE} WITH (FORCE);", db="postgres")
    psql(f"CREATE DATABASE {DATABASE};", db="postgres")
    version = scalar("SELECT current_setting('server_version');")
    if not version.startswith("17.12"):
        raise AssertionError(f"Stage 4C requires PostgreSQL 17.12; got {version}")
    for path in paths:
        psql(file=path)
    print("PASS T26: clean migrations 0001..0011 on PostgreSQL 17.12")


def insert_source_evidence(
    project_id: str,
    work_id: str,
    source_ref: str,
    text_value: str,
    valid_at: str,
) -> str:
    payload = {"kind": "source_observation", "text": text_value}
    payload_sql = json_sql(payload)
    source_hash = hashlib.sha256(text_value.encode("utf-8")).hexdigest()
    return scalar(
        "INSERT INTO aep.evidence("
        "project_id,work_id,evidence_type,source_ref,source_revision,"
        "content_sha256,valid_at,provenance,payload"
        ") VALUES("
        f"{lit(project_id)}::uuid,{lit(work_id)}::uuid,'source_observation',"
        f"{lit(source_ref)},{lit('fixture-v1')},{lit(source_hash)},"
        f"{lit(valid_at)}::timestamptz,"
        f"{json_sql({'provider':'stage4c-test','immutable_fixture':True})},"
        f"{payload_sql}"
        ") RETURNING evidence_id::text;"
    )


def rebuild(
    project_id: str,
    work_id: str,
    resource_id: str,
    session_id: str,
    extractor: str = "evidence-projection/1",
    model: str = "none",
    schema: str = "derived-memory/1",
) -> dict:
    return json_result(
        "SELECT aep.rebuild_derived_memory("
        f"{lit(project_id)}::uuid,{lit(work_id)}::uuid,{lit(resource_id)}::uuid,"
        f"'refs/heads/main',{lit(session_id)}::uuid,"
        f"{lit(extractor)},{lit(model)},{lit(schema)});"
    )


def memory_row(memory_id: str) -> dict:
    raw = scalar(
        "SELECT to_jsonb(memory_row)::text FROM aep.derived_memories AS memory_row "
        f"WHERE derived_memory_id={lit(memory_id)}::uuid;"
    )
    if not raw:
        raise AssertionError(f"Derived memory row {memory_id} was not found")
    return json.loads(raw)


def assert_status(result: dict, expected: str, label: str) -> None:
    actual = result.get("status")
    if actual != expected:
        raise AssertionError(f"{label}: expected {expected!r}, got {actual!r}: {result}")


def assert_invalidated(memory_id: str, reason: str) -> None:
    row = memory_row(memory_id)
    if row["status"] != "invalidated":
        raise AssertionError(f"Memory {memory_id} was not invalidated: {row['status']}")
    if row["invalidation_reason"] != reason:
        raise AssertionError(
            f"Memory {memory_id} invalidation reason mismatch: "
            f"{row['invalidation_reason']!r} != {reason!r}"
        )
    if not row["invalidated_at"]:
        raise AssertionError(f"Memory {memory_id} has no invalidation timestamp")


def assert_pack_contains_memory(pack: dict, memory_id: str) -> None:
    assert_status(pack, "ready", "Context Pack compilation")
    payload = pack.get("payload") or {}
    if payload.get("pack_schema_version") != 2:
        raise AssertionError("Context Pack did not advance to schema version 2")
    memories = payload.get("derived_memory")
    if not isinstance(memories, list):
        raise AssertionError("Context Pack omitted the derived_memory projection")
    if len(memories) != 1 or memories[0].get("derived_memory_id") != memory_id:
        raise AssertionError(f"Context Pack did not consume the current memory: {memories}")


def test_idempotency_determinism_and_provenance() -> tuple[str, str, str, str, str]:
    project_id, resource_id, work_id, dependency_id, _, _, decision_id = (
        stage4b.setup_fixture()
    )
    session_id = str(uuid4())
    valid_at = "2026-11-20T08:30:00Z"
    evidence_a = insert_source_evidence(
        project_id, work_id, "artifact://stage4c/alpha.txt",
        "Alpha finding: the source ledger is immutable.", valid_at,
    )
    evidence_b = insert_source_evidence(
        project_id, dependency_id, "artifact://stage4c/beta.txt",
        "Beta finding: dependencies contribute evidence.", valid_at,
    )
    source = stage4b.record_source(
        project_id, work_id, resource_id, session_id,
        "1" * 40, "2" * 40, "3" * 64,
    )
    assert_status(source, "recorded", "initial repository pin")

    first = rebuild(project_id, work_id, resource_id, session_id)
    assert_status(first, "ready", "initial derived-memory rebuild")
    if first.get("reused") is not False:
        raise AssertionError(f"First rebuild should create a projection: {first}")
    first_id = first["derived_memory_id"]
    first_sha = first["source_snapshot_sha256"]

    second = rebuild(project_id, work_id, resource_id, session_id)
    assert_status(second, "ready", "idempotent derived-memory rebuild")
    if second.get("reused") is not True or second["derived_memory_id"] != first_id:
        raise AssertionError("Identical source snapshot/version did not reuse the same memory row")
    if second["source_snapshot_sha256"] != first_sha:
        raise AssertionError("Identical rebuild did not produce an identical source snapshot hash")
    if second["memory_content"] != first["memory_content"]:
        raise AssertionError("Identical rebuild produced different memory content")

    original_memory = first["memory_content"]
    changed_version = rebuild(
        project_id, work_id, resource_id, session_id,
        extractor="evidence-projection/2",
    )
    assert_status(changed_version, "ready", "extractor version change")
    if changed_version["derived_memory_id"] == first_id:
        raise AssertionError("Extractor version change incorrectly reused an older projection")
    assert_invalidated(first_id, "source_snapshot_or_extractor_version_changed")

    restored = rebuild(project_id, work_id, resource_id, session_id)
    assert_status(restored, "ready", "deterministic rebuild after invalidation")
    if restored["source_snapshot_sha256"] != first_sha:
        raise AssertionError("Rebuilding an identical declared snapshot/version changed its hash")
    if restored["memory_content"] != original_memory:
        raise AssertionError("Rebuilding an identical declared snapshot/version changed its content")
    memory_id = restored["derived_memory_id"]
    row = memory_row(memory_id)

    expected_scope = {
        "project_id": project_id,
        "work_id": work_id,
        "resource_id": resource_id,
        "resource_ref": "refs/heads/main",
        "extractor_version": "evidence-projection/1",
        "model_version": "none",
        "schema_version": "derived-memory/1",
        "status": "ready",
    }
    for key, expected in expected_scope.items():
        if row[key] != expected:
            raise AssertionError(f"Derived memory {key} mismatch: {row[key]!r} != {expected!r}")

    if not row["observed_at"] or scalar(
        "SELECT (valid_at = '2026-11-20T08:30:00Z'::timestamptz)::text "
        f"FROM aep.derived_memories WHERE derived_memory_id={lit(memory_id)}::uuid;"
    ) != "true":
        raise AssertionError("Derived memory observed_at/valid_at timestamps are incomplete")
    if row["source_evidence_ids"] != [evidence_a, evidence_b] and set(
        row["source_evidence_ids"]
    ) != {evidence_a, evidence_b}:
        raise AssertionError("Derived memory does not retain exact source Evidence IDs")

    manifest = row["source_evidence_manifest"]
    manifest_by_id = {item["evidence_id"]: item for item in manifest}
    if set(manifest_by_id) != {evidence_a, evidence_b}:
        raise AssertionError("Source Evidence manifest omitted or added source IDs")
    expected_refs = {
        evidence_a: "artifact://stage4c/alpha.txt",
        evidence_b: "artifact://stage4c/beta.txt",
    }
    for evidence_id, ref in expected_refs.items():
        source_item = manifest_by_id[evidence_id]
        if source_item["source_ref"] != ref or not source_item.get("payload_sha256"):
            raise AssertionError(f"Evidence provenance is incomplete for {evidence_id}")
        if source_item.get("content_sha256") != hashlib.sha256(
            ("Alpha finding: the source ledger is immutable."
             if evidence_id == evidence_a
             else "Beta finding: dependencies contribute evidence.").encode("utf-8")
        ).hexdigest():
            raise AssertionError("Original Evidence content hash was not preserved")

    if dependency_id not in row["source_work_ids"] or work_id not in row["source_work_ids"]:
        raise AssertionError("Root/dependency project scope was not retained")
    if row["source_snapshot"]["repository_revision"]["commit_sha"] != "1" * 40:
        raise AssertionError("Repository commit pin is missing from the source snapshot")
    if row["source_snapshot"]["repository_revision"]["tree_sha"] != "2" * 40:
        raise AssertionError("Repository tree pin is missing from the source snapshot")
    if row["source_snapshot"]["repository_revision"]["content_sha256"] != "3" * 64:
        raise AssertionError("Repository content hash is missing from the source snapshot")
    if row["source_snapshot_sha256"] != scalar(
        "SELECT encode(public.digest(convert_to(jsonb_build_object("
        "'source_snapshot',source_snapshot,"
        "'extractor_version',extractor_version,"
        "'model_version',model_version,"
        "'schema_version',schema_version"
        ")::text,'UTF8'),'sha256'),'hex') "
        f"FROM aep.derived_memories WHERE derived_memory_id={lit(memory_id)}::uuid;"
    ):
        raise AssertionError("Persisted snapshot hash is not reproducible from its pinned input")

    if scalar(
        "SELECT (search_vector @@ plainto_tsquery('simple','alpha'))::text "
        f"FROM aep.derived_memories WHERE derived_memory_id={lit(memory_id)}::uuid;"
    ) != "true":
        raise AssertionError("PostgreSQL FTS index did not index derived memory text")

    # The database permits only invalidation updates; content/provenance changes
    # and physical deletion remain forbidden even to the prototype table owner.
    tamper = psql(
        "UPDATE aep.derived_memories SET memory_content='{\"tampered\":true}'::jsonb "
        f"WHERE derived_memory_id={lit(memory_id)}::uuid;",
        check=False,
    )
    if tamper.returncode == 0:
        raise AssertionError("Derived memory content mutation unexpectedly succeeded")
    deletion = psql(
        "DELETE FROM aep.derived_memories "
        f"WHERE derived_memory_id={lit(memory_id)}::uuid;",
        check=False,
    )
    if deletion.returncode == 0:
        raise AssertionError("Derived memory deletion unexpectedly succeeded")

    runtime_select = scalar(
        "SELECT has_table_privilege('aep_runtime','aep.derived_memories','SELECT')::text;"
    )
    runtime_execute = scalar(
        "SELECT has_function_privilege('aep_runtime',"
        "'aep.rebuild_derived_memory(uuid,uuid,uuid,text,uuid,text,text,text)',"
        "'EXECUTE')::text;"
    )
    if runtime_select != "false" or runtime_execute != "true":
        raise AssertionError("Runtime role boundary for derived memory is incorrect")

    # Context Pack consumes the active memory as a source-pinned projection.
    pack = stage4b.compile_pack(project_id, work_id, resource_id, session_id)
    assert_pack_contains_memory(pack, memory_id)
    fetched = stage4b.fetch_pack(pack["pack_id"], session_id)
    assert_pack_contains_memory(fetched, memory_id)

    return project_id, resource_id, work_id, session_id, memory_id


def test_source_and_decision_invalidation(
    project_id: str, resource_id: str, work_id: str,
    session_id: str, memory_id: str,
) -> str:
    old_pack = stage4b.compile_pack(project_id, work_id, resource_id, session_id)
    assert_pack_contains_memory(old_pack, memory_id)

    # Repository source pin advances only when commit/tree/content/provenance changes.
    changed_source = stage4b.record_source(
        project_id, work_id, resource_id, session_id,
        "4" * 40, "5" * 40, "6" * 64,
    )
    assert_status(changed_source, "recorded", "repository source pin change")
    assert_invalidated(memory_id, "source_evidence_appended")
    stale = stage4b.fetch_pack(old_pack["pack_id"], session_id)
    assert_status(stale, "stale", "Context Pack after source change")

    empty_pack = stage4b.compile_pack(project_id, work_id, resource_id, session_id)
    assert_status(empty_pack, "ready", "Pack before rebuilding source memory")
    if empty_pack["payload"].get("derived_memory") != []:
        raise AssertionError("Invalidated memory leaked into a fresh Context Pack")

    rebuilt = rebuild(project_id, work_id, resource_id, session_id)
    assert_status(rebuilt, "ready", "rebuild after repository source change")
    if rebuilt["derived_memory_id"] == memory_id:
        raise AssertionError("Changed repository source pin reused the invalidated row")
    new_memory_id = rebuilt["derived_memory_id"]

    pack_after_rebuild = stage4b.compile_pack(project_id, work_id, resource_id, session_id)
    assert_pack_contains_memory(pack_after_rebuild, new_memory_id)

    # OwnerDecision changes invalidate the derived projection and the Pack.
    context_decision_id = scalar(
        "SELECT decision_id::text FROM aep.owner_decisions "
        f"WHERE scope_type='work' AND scope_key={lit(work_id)} "
        "AND decision_key='context-guidance' ORDER BY decision_version LIMIT 1;"
    )
    psql(
        "UPDATE aep.owner_decisions SET status='rejected' "
        f"WHERE decision_id={lit(context_decision_id)}::uuid;"
    )
    assert_invalidated(new_memory_id, "owner_decision_changed")
    assert_status(
        stage4b.fetch_pack(pack_after_rebuild["pack_id"], session_id),
        "stale",
        "Context Pack after OwnerDecision change",
    )
    decision_rebuild = rebuild(project_id, work_id, resource_id, session_id)
    assert_status(decision_rebuild, "ready", "rebuild after OwnerDecision change")
    if decision_rebuild["derived_memory_id"] == new_memory_id:
        raise AssertionError("Changed OwnerDecision reused the invalidated derived-memory row")
    return decision_rebuild["derived_memory_id"]


def test_evidence_work_grant_resource_invalidation(
    project_id: str, resource_id: str, work_id: str,
    session_id: str, memory_id: str,
) -> None:
    # Appending source Evidence invalidates only the derived projection.
    valid_at = "2026-11-21T08:30:00Z"
    insert_source_evidence(
        project_id, work_id, "artifact://stage4c/gamma.txt",
        "Gamma finding: new evidence supersedes the derived projection.", valid_at,
    )
    assert_invalidated(memory_id, "source_evidence_appended")
    memory = rebuild(project_id, work_id, resource_id, session_id)
    assert_status(memory, "ready", "rebuild after Evidence append")
    memory_id = memory["derived_memory_id"]

    # Dependency Work state participates in the pinned source snapshot.
    dependency_id = scalar(
        "SELECT target_work_id::text FROM aep.work_relations "
        f"WHERE source_work_id={lit(work_id)}::uuid "
        "AND relation_type='depends_on' AND status='active' LIMIT 1;"
    )
    psql(
        "UPDATE aep.works SET title=title || ' changed',version=version+1 "
        f"WHERE work_id={lit(dependency_id)}::uuid;"
    )
    assert_invalidated(memory_id, "work_or_dependency_state_changed")
    memory = rebuild(project_id, work_id, resource_id, session_id)
    assert_status(memory, "ready", "rebuild after dependency Work change")
    memory_id = memory["derived_memory_id"]

    # Access/grant version is part of the authorized source scope.
    psql(
        "UPDATE aep.project_resources SET grant_version=grant_version+1 "
        f"WHERE project_id={lit(project_id)}::uuid AND resource_id={lit(resource_id)}::uuid;"
    )
    assert_invalidated(memory_id, "project_resource_grant_changed")
    memory = rebuild(project_id, work_id, resource_id, session_id)
    assert_status(memory, "ready", "rebuild after ProjectResource grant change")
    memory_id = memory["derived_memory_id"]

    psql(
        "UPDATE aep.resources SET display_name=display_name || ' changed' "
        f"WHERE resource_id={lit(resource_id)}::uuid;"
    )
    assert_invalidated(memory_id, "repository_resource_changed")
    memory = rebuild(project_id, work_id, resource_id, session_id)
    assert_status(memory, "ready", "rebuild after physical Resource change")
    memory_id = memory["derived_memory_id"]

    # Project state is a source input, and its changes invalidate the projection.
    psql(
        "UPDATE aep.projects SET name=name || ' changed' "
        f"WHERE project_id={lit(project_id)}::uuid;"
    )
    assert_invalidated(memory_id, "project_source_state_changed")
    memory = rebuild(project_id, work_id, resource_id, session_id)
    assert_status(memory, "ready", "rebuild after project state change")
    memory_id = memory["derived_memory_id"]

    # Revoke the existing grant using the supported status transition. The
    # immutable projection remains as invalidated provenance, but the rebuild
    # API must deny access before reading the Evidence or derived-memory rows.
    psql(
        "UPDATE aep.project_resources SET status='revoked',"
        "revoked_at=clock_timestamp(),grant_version=grant_version+1 "
        f"WHERE project_id={lit(project_id)}::uuid AND resource_id={lit(resource_id)}::uuid;"
    )
    assert_invalidated(memory_id, "project_resource_grant_changed")
    revoked_result = rebuild(project_id, work_id, resource_id, session_id)
    assert_status(revoked_result, "denied", "rebuild after project grant revocation")
    if revoked_result.get("source_count") != 0:
        raise AssertionError("Revoked project returned source rows during rebuild")
    if memory_row(memory_id)["status"] != "invalidated":
        raise AssertionError("Grant revocation removed the derived-memory provenance history")

    # Deleted or changed Evidence rows are rejected, never repaired in place.
    evidence_id = scalar(
        "SELECT evidence_id::text FROM aep.evidence "
        f"WHERE project_id={lit(project_id)}::uuid AND work_id={lit(work_id)}::uuid "
        "AND evidence_type='source_observation' ORDER BY observed_at LIMIT 1;"
    )
    update_source = psql(
        "UPDATE aep.evidence SET payload='{\"text\":\"rewritten\"}'::jsonb "
        f"WHERE evidence_id={lit(evidence_id)}::uuid;",
        check=False,
    )
    delete_source = psql(
        "DELETE FROM aep.evidence "
        f"WHERE evidence_id={lit(evidence_id)}::uuid;",
        check=False,
    )
    if update_source.returncode == 0 or delete_source.returncode == 0:
        raise AssertionError("Original Evidence was mutable/deletable")


def test_project_isolation(project_resource_id: str) -> None:
    denied_project = scalar(
        "INSERT INTO aep.projects(project_key,name) "
        "VALUES('stage4c-denied-' || substr(gen_random_uuid()::text,1,8),"
        "'Stage 4C denied fixture') RETURNING project_id;"
    )
    denied_work = stage4b.create_work(denied_project, "Denied project secret Work")
    secret = "STAGE4C_PRIVATE_PROJECT_SENTINEL_DO_NOT_RETRIEVE"
    insert_source_evidence(
        denied_project, denied_work, "private://stage4c/secret.txt",
        secret, "2026-11-22T08:30:00Z",
    )

    result = rebuild(
        denied_project, denied_work, project_resource_id,
        str(uuid4()),
    )
    assert_status(result, "denied", "cross-project derived memory lookup")
    serialized = json.dumps(result, sort_keys=True)
    if secret in serialized or "private://stage4c" in serialized:
        raise AssertionError("Denied memory rebuild returned private source content")
    count = scalar(
        "SELECT count(*)::text FROM aep.derived_memories "
        f"WHERE project_id={lit(denied_project)}::uuid;"
    )
    if count != "0":
        raise AssertionError("Denied project received a derived-memory row")
    audit = scalar(
        "SELECT jsonb_build_object('source_count',source_count,"
        "'source_bytes',source_bytes)::text "
        "FROM aep.context_retrieval_events "
        f"WHERE operation='compile' AND outcome='denied' AND project_id={lit(denied_project)}::uuid "
        "ORDER BY occurred_at DESC LIMIT 1;"
    )
    if not audit or json.loads(audit) != {"source_count": 0, "source_bytes": 0}:
        raise AssertionError("Denied lookup audit contains retrieved source rows/bytes")

    denied_pack = stage4b.compile_pack(
        denied_project, denied_work, project_resource_id, str(uuid4())
    )
    assert_status(denied_pack, "denied", "denied-project Context Pack compilation")


def main() -> None:
    setup_database()
    project_id, resource_id, work_id, session_id, memory_id = (
        test_idempotency_determinism_and_provenance()
    )
    new_memory_id = test_source_and_decision_invalidation(
        project_id, resource_id, work_id, session_id, memory_id
    )
    test_evidence_work_grant_resource_invalidation(
        project_id, resource_id, work_id, session_id, new_memory_id
    )
    test_project_isolation(resource_id)
    print(
        "PASS T25: deterministic/idempotent rebuild, complete Evidence provenance, "
        "immutable source ledger, automatic invalidation, project isolation, "
        "PostgreSQL FTS, and fresh Context Pack consumption"
    )


if __name__ == "__main__":
    main()
