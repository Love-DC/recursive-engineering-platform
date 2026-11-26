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
    paths = sorted(MIGRATIONS.glob("*.sql"))
    versions: list[int] = []
    for path in paths:
        match = re.fullmatch(r"(\d{4})_[a-z0-9_]+\.sql", path.name)
        if not match:
            raise SystemExit(f"Invalid migration filename: {path.name}")
        versions.append(int(match.group(1)))
    if versions != list(range(1, 10)):
        raise SystemExit(f"Expected contiguous migrations 0001..0009, got {versions}")

    psql(f"DROP DATABASE IF EXISTS {DATABASE} WITH (FORCE);", db="postgres")
    psql(f"CREATE DATABASE {DATABASE};", db="postgres")
    version = scalar("SELECT current_setting('server_version');")
    if not version.startswith("17.12"):
        raise AssertionError(f"Stage 4A requires PostgreSQL 17.12; got {version}")
    for path in paths:
        psql(file=path)
    print("PASS T26: clean migrations 0001..0009 on PostgreSQL 17.12")


def setup_project(manifest: dict) -> tuple[str, str, str]:
    project_id = scalar(
        "INSERT INTO aep.projects(project_key,name) "
        "VALUES('stage4-recovery-' || substr(gen_random_uuid()::text,1,8),"
        "'Stage 4 recovery fixture') RETURNING project_id;"
    )
    resource_id = str(uuid4())
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
    return project_id, resource_id, repository_id


def create_running_work(project_id: str, session_id: str) -> tuple[str, str, int]:
    work_id = scalar(
        "SELECT work_id::text FROM aep.register_work("
        f"{lit(project_id)}::uuid,{lit('stage4-request-'+str(uuid4()))},"
        f"{lit(session_id)}::uuid,'stage4_recovery',{lit('work-'+str(uuid4()))},"
        "1,'implementation','Recoverable Stage 4 fixture',"
        "'{\"acceptance\":[\"recover execution\",\"recover delivery\"]}'::jsonb,NULL);"
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
    return work_id, execution_id, int(fence)


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


def recover(project_id: str, new_session_id: str, work_limit: int = 100) -> dict:
    raw = scalar(
        "SELECT aep.recover_session_state("
        f"{lit(project_id)}::uuid,{lit(new_session_id)}::uuid,{work_limit},200)::text;"
    )
    return json.loads(raw)


def test_recovery_without_prior_session_context(
    project_id: str, resource_id: str, repository_id: str, manifest: dict,
) -> tuple[str, str, int, str, str]:
    session_a = str(uuid4())
    session_b = str(uuid4())
    work_id, execution_a, fence_a = create_running_work(project_id, session_a)

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
        "'pull_request_create',{lit(resource_id)}::uuid,{lit(branch)},"
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
    return work_id, execution_a, fence_a, session_a, session_b


def test_expiry_takeover_and_stale_checkpoint(
    project_id: str, work_id: str, execution_a: str, fence_a: int, session_a: str,
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
    if old_row["status"] != "superseded" or new_row["is_current"] is not True:
        raise AssertionError("recovery did not preserve both old and current execution attempts")
    if not any(row["execution_id"] == execution_a for row in snapshot["deliveries"]):
        raise AssertionError("takeover discarded the prior per-execution delivery record")
    if not any(row["execution_id"] == execution_a and row["status"] == "uncertain"
               for row in snapshot["operation_receipts"]):
        raise AssertionError("takeover discarded an ambiguous old-execution receipt")
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
    project_id, resource_id, repository_id = setup_project(manifest)
    work_id, execution_a, fence_a, session_a, _session_b = test_recovery_without_prior_session_context(
        project_id, resource_id, repository_id, manifest
    )
    test_expiry_takeover_and_stale_checkpoint(
        project_id, work_id, execution_a, fence_a, session_a
    )
    test_authorization_gate_and_limits(project_id)
    print("PASS Stage 4A PostgreSQL 17.12 session recovery prototype: T10, T11")


if __name__ == "__main__":
    main()
