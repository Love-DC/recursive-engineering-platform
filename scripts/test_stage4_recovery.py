#!/usr/bin/env python3
"""Stage 4A fresh-session recovery tests on disposable PostgreSQL 17.12."""

from __future__ import annotations

import json
import os
import re
import subprocess
from pathlib import Path
from uuid import uuid4

ROOT = Path(__file__).resolve().parents[1]
MIGRATIONS = ROOT / "db" / "prototype"
DATABASE = "aep_stage4_recovery"
HOST = os.environ.get("PGHOST", "127.0.0.1")
PORT = os.environ.get("PGPORT", "5432")
USER = os.environ.get("PGUSER", "postgres")
PASSWORD = os.environ.get("PGPASSWORD", "postgres")
MANIFEST_PATH = ROOT / "adapters" / "github-session-tools.json"


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


def json_sql(value: dict) -> str:
    return lit(json.dumps(value, sort_keys=True, separators=(",", ":"))) + "::jsonb"


def scalar(sql: str, *, db: str = DATABASE) -> str:
    return psql(sql, db=db).stdout.strip()


def expect_error(sql: str, needle: str, label: str) -> None:
    result = psql(sql, check=False)
    if result.returncode == 0 or needle.lower() not in result.stderr.lower():
        raise AssertionError(
            f"{label}: expected {needle!r}; rc={result.returncode}; "
            f"stdout={result.stdout}; stderr={result.stderr}"
        )


def setup_database() -> None:
    all_paths = sorted(MIGRATIONS.glob("*.sql"))
    paths: list[Path] = []
    versions: list[int] = []
    for path in all_paths:
        match = re.fullmatch(r"(\d{4})_[a-z0-9_]+\.sql", path.name)
        if not match:
            raise SystemExit(f"Invalid migration filename: {path.name}")
        version = int(match.group(1))
        if version <= 10:
            paths.append(path)
            versions.append(version)
    if versions != list(range(1, 11)):
        raise SystemExit(f"Expected contiguous migrations 0001..0010, got {versions}")

    psql(f"DROP DATABASE IF EXISTS {DATABASE} WITH (FORCE);", db="postgres")
    psql(f"CREATE DATABASE {DATABASE};", db="postgres")
    version = scalar("SELECT current_setting('server_version');")
    if not version.startswith("17.12"):
        raise AssertionError(f"Stage 4A requires PostgreSQL 17.12; got {version}")
    for path in paths:
        if int(path.name[:4]) <= 9:
            psql(file=path)
    print("PASS Stage 4A baseline: clean migrations 0001..0009 on PostgreSQL 17.12 (0010 is tested by Stage 4B)")


def setup_project(manifest: dict) -> tuple[str, str, str, str, str, str]:
    project_id = scalar(
        "INSERT INTO aep.projects(project_key,name) "
        "VALUES('stage4-recovery-' || substr(gen_random_uuid()::text,1,8),"
        "'Stage 4 recovery fixture') RETURNING project_id;"
    )
    resource_id = str(uuid4())
    read_resource_id = str(uuid4())
    repository_id = "1471589776"
    psql(
        "INSERT INTO aep.resources(resource_id,provider,host,resource_type,"
        "stable_resource_id,canonical_key,display_name) VALUES("
        f"{lit(resource_id)}::uuid,'github','github.com','repository',"
        f"{lit(repository_id)},{lit('repository:'+repository_id)},'Stage 4 recovery test repository');"
    )
    decision_id = scalar(
        "INSERT INTO aep.owner_decisions("
        "scope_type,scope_key,decision_key,statement,decision_version,status,"
        "approval_source_kind,approval_source_ref,approver_principal,"
        "approval_provenance,approved_at"
        ") VALUES("
        f"'project',{lit(project_id)},'stage4-recovery-write','Test-only repository grant',"
        "1,'approved','direct_owner_message','test://owner/stage4-recovery','test-owner',"
        "jsonb_build_object('direct_owner_confirmation',true),clock_timestamp()"
        ") RETURNING decision_id;"
    )
    psql(
        "INSERT INTO aep.project_resources("
        "project_id,resource_id,access_mode,status,grant_version,grant_decision_id"
        ") VALUES("
        f"{lit(project_id)}::uuid,{lit(resource_id)}::uuid,'write','active',1,"
        f"{lit(decision_id)}::uuid);"
    )
    psql(
        "SELECT aep.register_delivery_adapter_manifest("
        f"{lit(resource_id)}::uuid,{json_sql(manifest)},{lit(str(uuid4()))}::uuid);"
    )

    # A second read-only resource proves that recovery includes multiple active
    # project grants and a capability manifest for each linked resource.
    psql(
        "INSERT INTO aep.resources(resource_id,provider,host,resource_type,"
        "stable_resource_id,canonical_key,display_name) VALUES("
        f"{lit(read_resource_id)}::uuid,'github','github.com','repository',"
        "'1471589777','repository:1471589777','Stage 4 read-only fixture repository');"
    )
    psql(
        "INSERT INTO aep.project_resources("
        "project_id,resource_id,access_mode,status,grant_version,grant_decision_id"
        ") VALUES("
        f"{lit(project_id)}::uuid,{lit(read_resource_id)}::uuid,'read','active',2,NULL);"
    )
    psql(
        "SELECT aep.register_delivery_adapter_manifest("
        f"{lit(read_resource_id)}::uuid,{json_sql(manifest)},{lit(str(uuid4()))}::uuid);"
    )
    observation_decision_id = scalar(
        "INSERT INTO aep.owner_decisions("
        "scope_type,scope_key,decision_key,statement,decision_version,status"
        ") VALUES("
        f"'project',{lit(project_id)},'stage4-recovery-observation',"
        "'Test-only recovery observation decision',1,'proposed'"
        ") RETURNING decision_id;"
    )
    return project_id, resource_id, repository_id, read_resource_id, decision_id, observation_decision_id


def create_running_work(project_id: str, session_id: str) -> tuple[str, str, int, str, list[str]]:
    work_id = scalar(
        "SELECT work_id::text FROM aep.register_work("
        f"{lit(project_id)}::uuid,{lit('stage4-request-'+str(uuid4()))},"
        f"{lit(session_id)}::uuid,'stage4_recovery',{lit('work-'+str(uuid4()))},"
        "1,'implementation','Recoverable Stage 4 fixture',"
        "'{\"acceptance\":[\"recover execution\",\"recover delivery\"]}'::jsonb,NULL);"
    )
    dependency_ids = [
        scalar(
            "SELECT work_id::text FROM aep.register_work("
            f"{lit(project_id)}::uuid,{lit('stage4-dependency-request-'+str(uuid4()))},"
            f"{lit(str(uuid4()))}::uuid,'stage4_recovery',{lit('dependency-'+str(uuid4()))},"
            "1,'implementation','Recovery dependency fixture','{}'::jsonb,NULL);"
        )
        for _ in range(2)
    ]
    graph_id = scalar(
        "SELECT graph_id::text FROM aep.dependency_graphs "
        f"WHERE owner_project_id={lit(project_id)}::uuid AND is_default;"
    )
    for dependency_id in dependency_ids:
        # The two prerequisite Works are terminal fixtures. This lets the root
        # Work enter READY while retaining real depends_on edges in the project DAG.
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
    state = scalar(f"SELECT work_status FROM aep.set_work_ready({lit(work_id)}::uuid);")
    if state != "ready":
        raise AssertionError(f"Work did not become ready: {state}")
    claimed = scalar(
        "SELECT execution_id::text || '|' || fence::text "
        "FROM aep.claim_work("
        f"{lit(work_id)}::uuid,{lit(session_id)}::uuid,600);"
    )
    execution_id, fence = claimed.split("|")
    return work_id, execution_id, int(fence), graph_id, dependency_ids


def checkpoint(
    work_id: str, execution_id: str, fence: int, session_id: str,
    event_key: str, event_type: str, payload: dict,
) -> tuple[str, str]:
    result = scalar(
        "SELECT event_id::text || '|' || outcome FROM aep.record_session_checkpoint("
        f"{lit(work_id)}::uuid,{lit(execution_id)}::uuid,{fence},"
        f"{lit(session_id)}::uuid,{lit(event_key)},{lit(event_type)},"
        f"{json_sql(payload)},'stage4-test-session');"
    )
    event_id, outcome = result.split("|")
    return event_id, outcome


def recover(
    project_id: str, new_session_id: str, work_limit: int = 100, related_limit: int = 200,
) -> dict:
    raw = scalar(
        "SELECT aep.recover_session_state("
        f"{lit(project_id)}::uuid,{lit(new_session_id)}::uuid,{work_limit},{related_limit})::text;"
    )
    return json.loads(raw)


def test_recovery_without_prior_session_context(
    project_id: str, resource_id: str, repository_id: str,
    read_resource_id: str, owner_decision_id: str, observation_decision_id: str, manifest: dict,
) -> tuple[str, str, int, str, str, str, str, str, str, list[str]]:
    session_a = str(uuid4())
    session_b = str(uuid4())
    work_id, execution_a, fence_a, graph_id, dependency_ids = create_running_work(project_id, session_a)

    delivery = json.loads(scalar(
        "SELECT aep.allocate_execution_delivery("
        f"{lit(work_id)}::uuid,{lit(execution_a)}::uuid,{fence_a},"
        f"{lit(resource_id)}::uuid,'github.com',{lit(repository_id)},"
        "'Love-DC/recursive-engineering-platform','refs/heads/main',"
        f"{lit('a'*40)});"
    ))
    branch = delivery["delivery_branch"]
    pr_sha = "b" * 40
    psql(
        "SELECT aep.record_delivery_pr_state("
        f"{lit(execution_a)}::uuid,707,"
        f"{lit('https://github.com/Love-DC/recursive-engineering-platform/pull/707')},"
        f"{lit(pr_sha)},'github://test/pr/707');"
    )
    psql(
        "SELECT aep.record_delivery_evidence("
        f"{lit(execution_a)}::uuid,'ci',{lit(pr_sha)},'github://actions/test/707',NULL,"
        f"{json_sql({'tested_sha':pr_sha,'conclusion':'success','run_id':707})});"
    )

    psql(
        "INSERT INTO aep.evidence("
        "project_id,work_id,execution_id,evidence_type,source_ref,source_revision,"
        "content_sha256,provenance,payload"
        ") VALUES("
        f"{lit(project_id)}::uuid,{lit(work_id)}::uuid,{lit(execution_a)}::uuid,"
        "'session_checkpoint_ref','artifact://stage4/checkpoint/707','rev-1',"
        f"{lit('c'*64)},"
        f"{json_sql({'session_id':session_a,'execution_id':execution_a,'fence':fence_a})},"
        f"{json_sql({'resume_cursor':'step-4','artifact_kind':'checkpoint'})});"
    )


    psql(
        "INSERT INTO aep.evidence("
        "project_id,work_id,execution_id,evidence_type,source_ref,source_revision,"
        "content_sha256,provenance,payload"
        ") VALUES("
        f"{lit(project_id)}::uuid,{lit(work_id)}::uuid,{lit(execution_a)}::uuid,"
        "'source_observation','artifact://stage4/source/second','rev-2',"
        f"{lit('f'*64)},"
        f"{json_sql({'observed_by_session':session_a,'execution_id':execution_a,'fence':fence_a})},"
        f"{json_sql({'observation':'second source-derived fact'})});"
    )

    checkpoint_payload = {
        "checkpoint_ref": "artifact://stage4/checkpoint/707",
        "resume_cursor": "step-4",
        "source_sha": "a" * 40,
    }
    checkpoint_id, first_outcome = checkpoint(
        work_id, execution_a, fence_a, session_a,
        "checkpoint-707", "session_checkpoint", checkpoint_payload
    )
    replay_id, replay_outcome = checkpoint(
        work_id, execution_a, fence_a, session_a,
        "checkpoint-707", "session_checkpoint", checkpoint_payload
    )
    if checkpoint_id != replay_id or (first_outcome, replay_outcome) != ("created", "replayed"):
        raise AssertionError("T10 checkpoint idempotency failed")

    handoff_payload = {
        "to": "fresh-session",
        "checkpoint_ref": "artifact://stage4/checkpoint/707",
        "reason": "session context rotation",
    }
    checkpoint(
        work_id, execution_a, fence_a, session_a,
        "handoff-707", "session_handoff", handoff_payload
    )
    expect_error(
        "SELECT aep.record_session_checkpoint("
        f"{lit(work_id)}::uuid,{lit(execution_a)}::uuid,{fence_a},"
        f"{lit(session_a)}::uuid,'checkpoint-707','session_checkpoint',"
        f"{json_sql({**checkpoint_payload, 'resume_cursor':'step-5'})},NULL);",
        "reused with a different",
        "checkpoint idempotency key cannot change its payload",
    )

    receipt_id = scalar(
        "INSERT INTO aep.operation_receipts("
        "work_id,execution_id,provider,operation_key,operation_type,target_resource_id,"
        "target_ref,request_payload_sha256,intent_payload,status,reconciliation_status,"
        "execution_fence,target_host,target_repository_id"
        ") VALUES("
        f"{lit(work_id)}::uuid,{lit(execution_a)}::uuid,'github','lost-pr--response-707',"
        f"'pull_request_create',{lit(resource_id)}::uuid,{lit(branch)},"
        f"{lit('d'*64)},"
        f"{json_sql({'head':branch,'base':'main'})},"
        "'uncertain','pending',"
        f"{fence_a},'github.com',{lit(repository_id)}"
        ") RETURNING operation_receipt_id::text;"
    )
    psql(
        "INSERT INTO aep.operation_receipt_events(operation_receipt_id,event_type,event_payload) "
        f"VALUES({lit(receipt_id)}::uuid,'reconciliation_started',"
        f"{json_sql({'reason':'provider response lost','lookup_required':True})});"
    )

    # This session UUID does not exist in any prior Execution or event. The
    # function receives no transcript, summary, old session id, or chat object.
    if scalar(
        "SELECT count(*) FROM aep.executions "
        f"WHERE session_id={lit(session_b)}::uuid;"
    ) != "0":
        raise AssertionError("fresh-session fixture unexpectedly has historical execution state")
    snapshot = recover(project_id, session_b)
    if snapshot["recovery_session_id"] != session_b:
        raise AssertionError("recovery did not bind the new session provenance")
    if snapshot["authorization"]["checked_before_work_and_evidence_retrieval"] is not True:
        raise AssertionError("project grant gate was not recorded as preceding retrieval")
    if snapshot["authorization"]["session_id_is_authentication"] is not False:
        raise AssertionError("session_id was misrepresented as authentication")

    work_row = next(row for row in snapshot["work_items"] if row["work_id"] == work_id)
    if work_row["status"] != "running" or work_row["current_execution_id"] != execution_a:
        raise AssertionError(f"T10 Work/current Execution was not recovered: {work_row}")
    execution_row = next(row for row in snapshot["executions"] if row["execution_id"] == execution_a)
    if execution_row["session_id"] != session_a or execution_row["fence"] != fence_a:
        raise AssertionError("T10 original execution/session/fence provenance was not recovered")
    if execution_row["lease_expired"] is not False or not execution_row["lease_until"]:
        raise AssertionError("T10 live lease was not recovered")
    if not any(row["delivery_branch"] == branch and row["pull_request_number"] == 707
               and row["pr_head_sha"] == pr_sha for row in snapshot["deliveries"]):
        raise AssertionError("T10 PR delivery identity, URL, or exact head was not recovered")
    if not any(row["evidence_kind"] == "ci" and row["subject_sha"] == pr_sha and row["is_valid"]
               for row in snapshot["delivery_evidence"]):
        raise AssertionError("T10 exact-SHA delivery evidence was not recovered")
    if not any(row["evidence_type"] == "session_checkpoint_ref"
               and row["source_ref"] == "artifact://stage4/checkpoint/707"
               for row in snapshot["evidence"]):
        raise AssertionError("T10 source evidence/checkpoint reference was not recovered")
    root_dependencies = [
        row for row in snapshot["dependencies"]
        if row["source_work_id"] == work_id and row["relation_type"] == "depends_on"
    ]
    if (
        len(root_dependencies) != 2
        or {row["target_work_id"] for row in root_dependencies} != set(dependency_ids)
        or any(
            row["dependency_graph_id"] != graph_id or row["target_status"] != "delivered"
            for row in root_dependencies
        )
    ):
        raise AssertionError(
            "T10 dependency projection did not recover the exact default graph and prerequisite Work IDs"
        )
    if work_row["dependencies_satisfied"] is not True:
        raise AssertionError("T10 recovery did not reconstruct satisfied dependency eligibility")
    if not any(row["resource_id"] == resource_id and row["access_mode"] == "write"
               and row["grant_version"] == 1
               and row["grant_decision_id"] == owner_decision_id
               for row in snapshot["project_resources"]):
        raise AssertionError("T10 primary ProjectResource grant and version were not recovered")
    if not any(row["resource_id"] == read_resource_id and row["access_mode"] == "read"
               and row["grant_version"] == 2
               and row["grant_decision_id"] is None
               for row in snapshot["project_resources"]):
        raise AssertionError("T10 read-only ProjectResource grant and version were not recovered")
    if not any(row["decision_id"] == owner_decision_id and row["decision_version"] == 1
               and row["status"] == "approved"
               for row in snapshot["owner_decisions"]):
        raise AssertionError("T10 approved OwnerDecision version/provenance was not recovered")
    if not any(row["decision_id"] == observation_decision_id
               and row["decision_version"] == 1 and row["status"] == "proposed"
               for row in snapshot["owner_decisions"]):
        raise AssertionError("T10 proposed OwnerDecision version was not recovered")
    if not any(row["resource_id"] == resource_id
               and row["adapter_key"] == "github-session-tools"
               and row["schema_version"] == 1
               and row["manifest"] == manifest
               for row in snapshot["adapter_capabilities"]):
        raise AssertionError("T10 primary adapter capability manifest was not recovered")
    if not any(row["resource_id"] == read_resource_id
               and row["adapter_key"] == "github-session-tools"
               and row["manifest"] == manifest
               for row in snapshot["adapter_capabilities"]):
        raise AssertionError("T10 read-resource adapter capability manifest was not recovered")
    if not any(row["operation_receipt_id"] == receipt_id
               and row["status"] == "uncertain"
               and row["reconciliation_status"] == "pending"
               for row in snapshot["operation_receipts"]):
        raise AssertionError("T10 ambiguous external operation receipt was not recovered")
    if not any(row["operation_receipt_id"] == receipt_id
               and row["event_type"] == "reconciliation_started"
               for row in snapshot["operation_receipt_events"]):
        raise AssertionError("T10 operation receipt event history was not recovered")
    event_types = {row["event_type"] for row in snapshot["work_events"]}
    if not {"session_checkpoint", "session_handoff"}.issubset(event_types):
        raise AssertionError(f"T10 checkpoint/handoff events missing: {event_types}")
    if "conversation_history" in snapshot or "chat_messages" in snapshot:
        raise AssertionError("T11 recovery returned or depended on chat transcript content")
    definition = scalar(
        "SELECT pg_get_functiondef('aep.recover_session_state(uuid,uuid,integer,integer)'::regprocedure);"
    )
    if "chat_messages" in definition or "conversation_history" in definition or "transcript" in definition:
        raise AssertionError("T11 recovery function contains a chat transcript dependency")

    print("PASS T10: fresh session reconstructs Work, dependencies, Execution/fence/lease, delivery, evidence, checkpoints and receipts")
    print("PASS T11: recovery uses only durable PostgreSQL state and requires no prior chat transcript")
    return (work_id, execution_a, fence_a, session_a, session_b, receipt_id,
            branch, pr_sha, graph_id, dependency_ids)


def test_expiry_takeover_and_stale_checkpoint(
    project_id: str, work_id: str, execution_a: str, fence_a: int, session_a: str,
    resource_id: str, repository_id: str, original_receipt_id: str,
    original_delivery_branch: str, original_pr_sha: str,
    expected_dependency_graph_id: str, expected_dependency_ids: list[str],
) -> None:
    psql(
        "UPDATE aep.executions SET lease_until=clock_timestamp()-interval '1 second' "
        f"WHERE execution_id={lit(execution_a)}::uuid;"
    )
    recovery_session = str(uuid4())
    expired_snapshot = recover(project_id, recovery_session)
    old = next(row for row in expired_snapshot["executions"] if row["execution_id"] == execution_a)
    if old["lease_expired"] is not True or old["old_session_may_still_be_active"] is not True:
        raise AssertionError("expired lease was incorrectly interpreted as proof that the old session stopped")
    if expired_snapshot["lease_semantics"]["expired_lease_proves_old_session_stopped"] is not False:
        raise AssertionError("lease semantics fail to disclose residual old-session activity risk")

    expect_error(
        "SELECT aep.record_session_checkpoint("
        f"{lit(work_id)}::uuid,{lit(execution_a)}::uuid,{fence_a},"
        f"{lit(session_a)}::uuid,'late-before-takeover','session_checkpoint',"
        f"{json_sql({'resume_cursor':'too-late'})},NULL);",
        "lease has expired",
        "expired lease cannot append a checkpoint",
    )

    session_c = str(uuid4())
    claimed = scalar(
        "SELECT execution_id::text || '|' || fence::text "
        "FROM aep.claim_work("
        f"{lit(work_id)}::uuid,{lit(session_c)}::uuid,600);"
    )
    execution_b, fence_b_text = claimed.split("|")
    fence_b = int(fence_b_text)
    if execution_b == execution_a or fence_b <= fence_a:
        raise AssertionError("lease takeover did not create a new execution and greater fence")

    delivery_b = json.loads(scalar(
        "SELECT aep.allocate_execution_delivery("
        f"{lit(work_id)}::uuid,{lit(execution_b)}::uuid,{fence_b},"
        f"{lit(resource_id)}::uuid,'github.com',{lit(repository_id)},"
        "'Love-DC/recursive-engineering-platform','refs/heads/main',"
        f"{lit('a'*40)});"
    ))
    pr_sha_b = "e" * 40
    psql(
        "SELECT aep.record_delivery_pr_state("
        f"{lit(execution_b)}::uuid,708,"
        f"{lit('https://github.com/Love-DC/recursive-engineering-platform/pull/708')},"
        f"{lit(pr_sha_b)},'github://test/pr/708');"
    )
    psql(
        "SELECT aep.record_delivery_evidence("
        f"{lit(execution_b)}::uuid,'ci',{lit(pr_sha_b)},'github://actions/test/708',NULL,"
        f"{json_sql({'tested_sha':pr_sha_b,'conclusion':'success','run_id':708})});"
    )
    receipt_b = scalar(
        "INSERT INTO aep.operation_receipts("
        "work_id,execution_id,provider,operation_key,operation_type,target_resource_id,"
        "target_ref,request_payload_sha256,intent_payload,status,reconciliation_status,"
        "execution_fence,target_host,target_repository_id"
        ") VALUES("
        f"{lit(work_id)}::uuid,{lit(execution_b)}::uuid,'github','lost-pr-response-after-takeover',"
        "'pull_request_create',"
        f"{lit(resource_id)}::uuid,{lit(delivery_b['delivery_branch'])},"
        f"{lit('9'*64)},"
        f"{json_sql({'head':delivery_b['delivery_branch'],'base':'main'})},"
        "'uncertain','pending',"
        f"{fence_b},'github.com',{lit(repository_id)}"
        ") RETURNING operation_receipt_id::text;"
    )
    psql(
        "INSERT INTO aep.operation_receipt_events(operation_receipt_id,event_type,event_payload) "
        f"VALUES({lit(receipt_b)}::uuid,'reconciliation_started',"
        f"{json_sql({'reason':'second ambiguous response','lookup_required':True})});"
    )
    expect_error(
        "SELECT aep.record_session_checkpoint("
        f"{lit(work_id)}::uuid,{lit(execution_a)}::uuid,{fence_a},"
        f"{lit(session_a)}::uuid,'late-after-takeover','session_checkpoint',"
        f"{json_sql({'resume_cursor':'stale'})},NULL);",
        "not the current running fence",
        "stale execution cannot append a checkpoint after takeover",
    )
    checkpoint(
        work_id, execution_b, fence_b, session_c,
        "new-execution-checkpoint", "session_checkpoint",
        {"resume_cursor":"new-attempt-start","recovered_from_execution":execution_a}
    )

    session_d = str(uuid4())
    snapshot = recover(project_id, session_d)
    work_row = next(row for row in snapshot["work_items"] if row["work_id"] == work_id)
    if work_row["current_execution_id"] != execution_b or work_row["fence_generation"] != fence_b:
        raise AssertionError("fresh recovery did not select the new execution/fence after takeover")
    old_row = next(row for row in snapshot["executions"] if row["execution_id"] == execution_a)
    new_row = next(row for row in snapshot["executions"] if row["execution_id"] == execution_b)
    if old_row["status"] != "expired" or new_row["is_current"] is not True:
        raise AssertionError("recovery did not preserve the expired prior attempt and current execution")
    if old_row["old_session_may_still_be_active"] is not True:
        raise AssertionError("takeover incorrectly implied that the expired old ChatGPT session had stopped")
    if old_row["session_termination_observed"] is not False:
        raise AssertionError("recovery fabricated a trusted old-session termination observation")
    if new_row["old_session_may_still_be_active"] is not True:
        raise AssertionError("recovery must remain conservative for the current session too")
    expected_deliveries = (
        (execution_a, original_delivery_branch, 707,
         "https://github.com/Love-DC/recursive-engineering-platform/pull/707", original_pr_sha),
        (execution_b, delivery_b["delivery_branch"], 708,
         "https://github.com/Love-DC/recursive-engineering-platform/pull/708", pr_sha_b),
    )
    for expected_execution, expected_branch, expected_pr, expected_url, expected_sha in expected_deliveries:
        delivery_row = next(
            (row for row in snapshot["deliveries"] if row["execution_id"] == expected_execution),
            None,
        )
        if delivery_row is None or (
            delivery_row["delivery_branch"], delivery_row["pull_request_number"],
            delivery_row["pull_request_url"], delivery_row["pr_head_sha"],
        ) != (expected_branch, expected_pr, expected_url, expected_sha):
            raise AssertionError(
                f"takeover recovery lost or changed delivery identity for execution {expected_execution}: "
                f"{delivery_row}"
            )
        if not any(
            row["execution_id"] == expected_execution and row["subject_sha"] == expected_sha
            and row["evidence_kind"] == "ci" and row["is_valid"] is True
            for row in snapshot["delivery_evidence"]
        ):
            raise AssertionError(
                f"takeover recovery lost exact-SHA CI evidence for execution {expected_execution}"
            )

    expected_receipts = (
        (original_receipt_id, execution_a), (receipt_b, execution_b),
    )
    for expected_receipt_id, expected_execution in expected_receipts:
        receipt_row = next(
            (row for row in snapshot["operation_receipts"]
             if row["operation_receipt_id"] == expected_receipt_id),
            None,
        )
        if receipt_row is None or (
            receipt_row["execution_id"] != expected_execution
            or receipt_row["status"] != "uncertain"
            or receipt_row["reconciliation_status"] != "pending"
        ):
            raise AssertionError(
                f"takeover recovery lost or changed ambiguous receipt {expected_receipt_id}: {receipt_row}"
            )
        if not any(
            row["operation_receipt_id"] == expected_receipt_id
            and row["event_type"] == "reconciliation_started"
            for row in snapshot["operation_receipt_events"]
        ):
            raise AssertionError(
                f"takeover recovery lost reconciliation event history for receipt {expected_receipt_id}"
            )

    recovered_dependencies = [
        row for row in snapshot["dependencies"]
        if row["source_work_id"] == work_id and row["relation_type"] == "depends_on"
    ]
    if (
        len(recovered_dependencies) != 2
        or {row["target_work_id"] for row in recovered_dependencies} != set(expected_dependency_ids)
        or any(
            row["dependency_graph_id"] != expected_dependency_graph_id
            or row["target_status"] != "delivered"
            for row in recovered_dependencies
        )
        or work_row["dependencies_satisfied"] is not True
    ):
        raise AssertionError("takeover recovery lost the exact default dependency graph and target Works")
    bounded_snapshot = recover(project_id, str(uuid4()), work_limit=100, related_limit=1)
    bounded_collections = (
        "dependencies", "executions", "work_events", "evidence", "deliveries",
        "delivery_evidence", "operation_receipts", "operation_receipt_events",
        "project_resources", "owner_decisions", "adapter_capabilities",
    )
    truncation_flags = bounded_snapshot["related_data_truncated"]
    for collection in bounded_collections:
        if len(bounded_snapshot[collection]) > 1:
            raise AssertionError(
                f"related_limit did not bound {collection}: {len(bounded_snapshot[collection])}"
            )
        if truncation_flags.get(collection) is not True:
            raise AssertionError(
                f"{collection} was not marked truncated although fixture rows exceed related_limit=1"
            )
    if bounded_snapshot["work_list_truncated"] is not False:
        raise AssertionError("recovery incorrectly reported the 100-item Work list as truncated")

    truncated_work_snapshot = recover(project_id, str(uuid4()), work_limit=1, related_limit=1)
    if len(truncated_work_snapshot["work_items"]) != 1:
        raise AssertionError("work_limit did not bound the Work list to one item")
    if truncated_work_snapshot["work_list_truncated"] is not True:
        raise AssertionError("Work-list truncation was not reported separately")
    print("PASS T10/T11: lease expiry is not session termination; takeover fences stale checkpoints and retains attempt history")
    return


def test_authorization_gate_and_limits(project_id: str) -> None:
    denied_project = scalar(
        "INSERT INTO aep.projects(project_key,name) "
        "VALUES('stage4-denied-' || substr(gen_random_uuid()::text,1,8),"
        "'No ProjectResource grant') RETURNING project_id;"
    )
    expect_error(
        "SELECT aep.recover_session_state("
        f"{lit(denied_project)}::uuid,{lit(str(uuid4()))}::uuid,100,200);",
        "no active readable ProjectResource grant",
        "recovery rejects project before returning Work/evidence without a grant",
    )
    expect_error(
        "SELECT aep.recover_session_state("
        f"{lit(project_id)}::uuid,{lit(str(uuid4()))}::uuid,101,200);",
        "work=1..100",
        "recovery work result is bounded",
    )
    print("PASS recovery scope: project grant gate and bounded result limits fail closed")


def main() -> None:
    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    setup_database()
    (project_id, resource_id, repository_id, read_resource_id,
     owner_decision_id, observation_decision_id) = setup_project(manifest)
    (work_id, execution_a, fence_a, session_a, _session_b, receipt_id,
     original_delivery_branch, original_pr_sha, dependency_graph_id, dependency_ids) = (
        test_recovery_without_prior_session_context(
            project_id, resource_id, repository_id, read_resource_id,
            owner_decision_id, observation_decision_id, manifest
        )
    )
    test_expiry_takeover_and_stale_checkpoint(
        project_id, work_id, execution_a, fence_a, session_a,
        resource_id, repository_id, receipt_id, original_delivery_branch,
        original_pr_sha, dependency_graph_id, dependency_ids
    )
    test_authorization_gate_and_limits(project_id)
    print("PASS Stage 4A PostgreSQL 17.12 session recovery prototype: T10, T11")


if __name__ == "__main__":
    main()
