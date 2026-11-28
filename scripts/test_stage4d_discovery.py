#!/usr/bin/env python3
"""Stage 4D active-session discovery/decomposition tests on disposable PostgreSQL 17.12."""

from __future__ import annotations

import json
import os
import subprocess
import time
from pathlib import Path
from uuid import uuid4

ROOT = Path(__file__).resolve().parents[1]
MIGRATIONS = ROOT / "db" / "prototype"
DATABASE = "aep_stage4d_discovery"
HOST = os.environ.get("PGHOST", "127.0.0.1")
PORT = os.environ.get("PGPORT", "5432")
USER = os.environ.get("PGUSER", "postgres")
PASSWORD = os.environ.get("PGPASSWORD", "postgres")


def psql(sql: str | None = None, *, db: str = DATABASE,
         file: Path | None = None, check: bool = True) -> subprocess.CompletedProcess[str]:
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
    return json.loads(scalar(sql))


def setup_database() -> None:
    paths = sorted(MIGRATIONS.glob("*.sql"))
    versions = [int(path.name[:4]) for path in paths]
    if versions != list(range(1, 16)):
        raise SystemExit(f"Expected clean ordered migrations 0001..0015, got {versions}")
    psql(f"DROP DATABASE IF EXISTS {DATABASE} WITH (FORCE);", db="postgres")
    psql(f"CREATE DATABASE {DATABASE};", db="postgres")
    version = scalar("SELECT current_setting('server_version');")
    if not version.startswith("17.12"):
        raise AssertionError(f"Stage 4D requires PostgreSQL 17.12; got {version}")
    for path in paths:
        psql(file=path)
    print("PASS T26: clean ordered migrations 0001..0015 on PostgreSQL 17.12")


def setup_scope(*, access_mode: str = "write") -> tuple[str, str, str]:
    project_id = scalar(
        "INSERT INTO aep.projects(project_key,name) VALUES("
        f"{lit('stage4d-'+uuid4().hex[:12])},'Stage 4D fixture') RETURNING project_id;"
    )
    stable_id = "stage4d-" + uuid4().hex
    resource_id = scalar(
        "INSERT INTO aep.resources(provider,host,resource_type,stable_resource_id,canonical_key,display_name) "
        "VALUES('github','github.com','repository',"
        f"{lit(stable_id)},{lit('repository:'+stable_id)},'Stage 4D test repository') "
        "RETURNING resource_id;"
    )
    decision_id = ""
    if access_mode in ("write", "read_write"):
        decision_id = scalar(
            "INSERT INTO aep.owner_decisions("
            "scope_type,scope_key,decision_key,statement,decision_version,status,"
            "approval_source_kind,approval_source_ref,approver_principal,approval_provenance,approved_at"
            ") VALUES("
            f"'project',{lit(project_id)},'stage4d-write','Test-only discovery write grant',"
            "1,'approved','direct_owner_message','test://owner/stage4d','test-owner',"
            "jsonb_build_object('direct_owner_confirmation',true),clock_timestamp()"
            ") RETURNING decision_id;"
        )
    psql(
        "INSERT INTO aep.project_resources("
        "project_id,resource_id,access_mode,status,grant_version,grant_decision_id"
        ") VALUES("
        f"{lit(project_id)}::uuid,{lit(resource_id)}::uuid,{lit(access_mode)},'active',1,"
        f"{lit(decision_id) if decision_id else 'NULL'}::uuid);"
    )
    return project_id, resource_id, stable_id


def source_list(stable_id: str) -> list[dict]:
    return [{
        "source_kind": "issue",
        "source_prefix": f"github://github.com/{stable_id}/issues/",
    }]


def limits(**overrides: int) -> dict:
    result = {
        "max_depth": 2,
        "max_fanout": 8,
        "max_tool_calls": 20,
        "max_elapsed_ms": 600000,
        "max_tokens": 20000,
        "max_cost_micros": 1000000,
        "max_no_progress": 4,
    }
    result.update(overrides)
    return result


def start_pass(
    project_id: str, resource_id: str, stable_id: str, *,
    session_id: str | None = None, request_key: str | None = None,
    budget: dict | None = None, cursor: dict | None = None,
    resume_from: str | None = None,
) -> dict:
    session = session_id or str(uuid4())
    source_arg = json_sql(source_list(stable_id)) if resume_from is None else "NULL::jsonb"
    cursor_arg = json_sql(cursor or {"page": 1}) if resume_from is None else "NULL::jsonb"
    watermark_arg = json_sql({"observed_since": "fixture-start"}) if resume_from is None else "NULL::jsonb"
    return json_result(
        "SELECT aep.start_discovery_pass("
        f"{lit(project_id)}::uuid,{lit(resource_id)}::uuid,{lit(session)}::uuid,"
        f"{lit(request_key or ('pass-'+uuid4().hex))},"
        f"{source_arg},{cursor_arg},{watermark_arg},{json_sql(budget or limits())},"
        f"{lit(resume_from)+'::uuid' if resume_from else 'NULL::uuid'});"
    )


def reserve(
    project_id: str, resource_id: str, stable_id: str, pass_id: str, session_id: str, *,
    call_key: str | None = None, cursor: dict | None = None,
    estimated_tokens: int = 100, estimated_cost: int = 100,
) -> dict:
    return json_result(
        "SELECT aep.reserve_discovery_call("
        f"{lit(project_id)}::uuid,{lit(resource_id)}::uuid,{lit(pass_id)}::uuid,"
        f"{lit(session_id)}::uuid,{lit(call_key or ('call-'+uuid4().hex))},"
        "'github_fetch_issue','issue',"
        f"{lit(f'github://github.com/{stable_id}/issues/{uuid4().hex[:8]}')},"
        f"{json_sql(cursor or {'page':1})},{estimated_tokens},{estimated_cost});"
    )


def complete_sql(
    project_id: str, resource_id: str, pass_id: str, session_id: str,
    call_key: str, source_ref: str, *,
    cursor_after: dict, resume_cursor: dict,
    candidate: dict | None,
    source_revision: str | None = None,
    content_hash: str | None = None,
    actual_tokens: int = 50, actual_cost: int = 40,
) -> str:
    return (
        "SELECT aep.complete_discovery_call("
        f"{lit(project_id)}::uuid,{lit(resource_id)}::uuid,{lit(pass_id)}::uuid,"
        f"{lit(session_id)}::uuid,{lit(call_key)},"
        f"{lit(source_revision or 'fixture-revision-1')},"
        f"{lit(content_hash or ('a'*64))},"
        f"{json_sql({'provider':'github-session-tools','verification':'fixture-read'})},"
        f"{json_sql({'title':'Observed issue','body':'Reproducible source observation'})},"
        f"{actual_tokens},{actual_cost},{json_sql(cursor_after)},"
        f"{json_sql(resume_cursor)},{json_sql(candidate) if candidate is not None else 'NULL::jsonb'}"
        ");"
    )


def record_call(
    project_id: str, resource_id: str, stable_id: str, pass_id: str, session_id: str, *,
    key: str, cursor_before: dict, cursor_after: dict, candidate: dict | None,
    parent_observation_id: str | None = None,
    estimated_tokens: int = 100, estimated_cost: int = 100,
    actual_tokens: int = 50, actual_cost: int = 40,
) -> tuple[dict, dict, str]:
    source_ref = f"github://github.com/{stable_id}/issues/{uuid4().hex[:8]}"
    r = json_result(
        "SELECT aep.reserve_discovery_call("
        f"{lit(project_id)}::uuid,{lit(resource_id)}::uuid,{lit(pass_id)}::uuid,"
        f"{lit(session_id)}::uuid,{lit(key)},'github_fetch_issue','issue',"
        f"{lit(source_ref)},{json_sql(cursor_before)},{estimated_tokens},{estimated_cost});"
    )
    if r.get("status") != "reserved":
        return r, {}, source_ref
    if candidate is not None and parent_observation_id is not None:
        candidate = dict(candidate)
        candidate["parent_observation_id"] = parent_observation_id
    c = json_result(complete_sql(
        project_id,resource_id,pass_id,session_id,key,source_ref,
        cursor_after=cursor_after,resume_cursor=cursor_after,candidate=candidate,
        actual_tokens=actual_tokens,actual_cost=actual_cost,
    ))
    return r,c,source_ref


def assert_status(result: dict, expected: str, label: str) -> None:
    if result.get("status") != expected:
        raise AssertionError(f"{label}: expected {expected!r}, got {result!r}")


def candidate(key: str, title: str, **extra) -> dict:
    return {
        "action": "accept",
        "candidate_key": key,
        "title": title,
        "work_type": "implementation",
        "acceptance": {"test": "canonical identity and exact source evidence"},
        **extra,
    }


def test_runtime_boundary() -> None:
    functions = [
        "aep.get_discovery_state(uuid,uuid,integer)",
        "aep.start_discovery_pass(uuid,uuid,uuid,text,jsonb,jsonb,jsonb,jsonb,uuid)",
        "aep.reserve_discovery_call(uuid,uuid,uuid,uuid,text,text,text,text,jsonb,integer,bigint)",
        "aep.complete_discovery_call(uuid,uuid,uuid,uuid,text,text,text,jsonb,jsonb,integer,bigint,jsonb,jsonb,jsonb)",
        "aep.finish_discovery_pass(uuid,uuid,uuid,uuid)",
        "aep.yield_discovery_pass(uuid,uuid,uuid,uuid,jsonb)",
    ]
    grants = [scalar(
        "SELECT has_function_privilege('aep_runtime',"
        f"{lit(function)},'EXECUTE')::text;"
    ) for function in functions]
    tables = [scalar(
        "SELECT has_table_privilege('aep_runtime',"
        f"{lit('aep.'+name)},'SELECT')::text;"
    ) for name in ("discovery_passes","discovery_observations","discovery_pass_events")]
    if grants != ["true"] * len(functions):
        raise AssertionError(f"Discovery runtime RPC grants are wrong: {grants}")
    if tables != ["false"] * 3:
        raise AssertionError(f"Runtime has direct Discovery table access: {tables}")


def test_concurrent_canonical_registration(project_id: str, resource_id: str, stable_id: str) -> None:
    session_a, session_b = str(uuid4()), str(uuid4())
    pass_a = start_pass(project_id,resource_id,stable_id,session_id=session_a)
    pass_b = start_pass(project_id,resource_id,stable_id,session_id=session_b)
    assert_status(pass_a,"running","first concurrent scan start")
    assert_status(pass_b,"running","second concurrent scan start")

    candidate_key = "issue:42:correct-resource-accounting"
    candidate_value = candidate(candidate_key,"Correct resource accounting")
    call_key_a, call_key_b = "concurrent-call-a", "concurrent-call-b"
    source_a = f"github://github.com/{stable_id}/issues/42"
    source_b = f"github://github.com/{stable_id}/issues/42"
    for pass_value,session,key,source in (
        (pass_a,session_a,call_key_a,source_a),(pass_b,session_b,call_key_b,source_b)
    ):
        result = json_result(
            "SELECT aep.reserve_discovery_call("
            f"{lit(project_id)}::uuid,{lit(resource_id)}::uuid,{lit(pass_value['pass_id'])}::uuid,"
            f"{lit(session)}::uuid,{lit(key)},'github_fetch_issue','issue',"
            f"{lit(source)},{json_sql({'page':1})},100,100);"
        )
        assert_status(result,"reserved","concurrent scan reservation")

    sql_a = complete_sql(
        project_id,resource_id,pass_a["pass_id"],session_a,call_key_a,source_a,
        cursor_after={"page":2},resume_cursor={"page":2},candidate=candidate_value,
    )
    sql_b = complete_sql(
        project_id,resource_id,pass_b["pass_id"],session_b,call_key_b,source_b,
        cursor_after={"page":2},resume_cursor={"page":2},candidate=candidate_value,
    )
    env = os.environ.copy()
    env["PGPASSWORD"] = PASSWORD
    cmd = ["psql","-X","-q","-A","-t","-v","ON_ERROR_STOP=1",
           "-h",HOST,"-p",PORT,"-U",USER,"-d",DATABASE]
    first = subprocess.Popen(cmd+["-c",sql_a],text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env)
    second = subprocess.Popen(cmd+["-c",sql_b],text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env)
    out_a,err_a = first.communicate(timeout=20)
    out_b,err_b = second.communicate(timeout=20)
    if first.returncode or second.returncode:
        raise AssertionError(f"Concurrent completion failed: A={out_a} {err_a}; B={out_b} {err_b}")
    result_a,result_b = json.loads(out_a.strip()),json.loads(out_b.strip())
    if {result_a["decision"],result_b["decision"]} != {"accepted","linked"}:
        raise AssertionError(f"Concurrent canonical identity did not converge: {result_a}, {result_b}")
    count = scalar(
        "SELECT count(*) FROM aep.works WHERE project_id="
        f"{lit(project_id)}::uuid AND identity_kind='discovery_candidate_v1' "
        f"AND identity_key={lit(result_a['candidate_fingerprint'])};"
    )
    if count != "1":
        raise AssertionError(f"Concurrent discovery created {count} canonical Work rows, expected one")

    # The same completed call/result replays without another Evidence or Work row.
    replay = json_result(complete_sql(
        project_id,resource_id,pass_a["pass_id"],session_a,call_key_a,source_a,
        cursor_after={"page":2},resume_cursor={"page":2},candidate=candidate_value,
    ))
    if replay.get("idempotent_replay") is not True:
        raise AssertionError(f"Completed discovery call did not replay idempotently: {replay}")
    evidence_count = scalar(
        "SELECT count(*) FROM aep.evidence WHERE project_id="
        f"{lit(project_id)}::uuid AND evidence_type='discovery_observation';"
    )
    if evidence_count != "2":
        raise AssertionError(f"Concurrent two-source scan should persist two observations, got {evidence_count}")
    timestamp_alignment = scalar(
        "SELECT count(*) FROM aep.discovery_observations o "
        "JOIN aep.evidence e ON e.evidence_id=o.evidence_id "
        "WHERE o.project_id="
        f"{lit(project_id)}::uuid AND o.status='completed' "
        "AND o.observed_at IS NOT NULL AND o.observed_at=e.observed_at;"
    )
    if timestamp_alignment != "2":
        raise AssertionError(
            f"Each immutable observation must align with its Evidence observed_at; got {timestamp_alignment}"
        )
    external = scalar(
        "SELECT (SELECT count(*) FROM aep.external_refs)::text || ':' || "
        "(SELECT count(*) FROM aep.operation_receipts)::text;"
    )
    if external != "0:0":
        raise AssertionError(f"Discovery unexpectedly wrote external side-effect records: {external}")


def test_budgets_and_resume(project_id: str, resource_id: str, stable_id: str) -> None:
    # Tool-call cap stops before a second provider read and resumes from the stored cursor.
    session = str(uuid4())
    p = start_pass(project_id,resource_id,stable_id,session_id=session,
                   request_key="idempotent-start",budget=limits(max_tool_calls=1))
    replayed_start = start_pass(project_id,resource_id,stable_id,session_id=session,
                                request_key="idempotent-start",budget=limits(max_tool_calls=1))
    if replayed_start.get("pass_id") != p.get("pass_id") or replayed_start.get("idempotent_replay") is not True:
        raise AssertionError(f"Same-session start did not replay idempotently: {replayed_start}")
    call,done,_ = record_call(project_id,resource_id,stable_id,p["pass_id"],session,
        key="one-call",cursor_before={"page":1},cursor_after={"page":2},
        candidate={"action":"skip","reason":"non_actionable"})
    assert_status(call,"reserved","tool cap reservation")
    assert_status(done,"stopped","tool cap completion")
    if done.get("stop_reason")!="tool_call_budget" or done.get("resume_cursor")!={"page":2}:
        raise AssertionError(f"Tool-call cap lost durable cursor: {done}")
    resumed = start_pass(project_id,resource_id,stable_id,session_id=str(uuid4()),
        budget=limits(max_tool_calls=3),resume_from=p["pass_id"])
    assert_status(resumed,"running","resume stopped pass")
    if (resumed.get("tool_calls_used") != 1 or resumed.get("tokens_used") != 50
            or resumed.get("cost_used_micros") != 40):
        raise AssertionError(f"Resume must carry cumulative usage counters: {resumed}")
    state = json_result(
        "SELECT aep.get_discovery_state("
        f"{lit(project_id)}::uuid,{lit(resource_id)}::uuid,10);"
    )
    if not any(item["pass_id"]==p["pass_id"] and item["resume_cursor"]=={"page":2}
               for item in state["passes"]):
        raise AssertionError("Fresh-session discovery state did not recover the stopped cursor")

    # Token overrun is recorded atomically and stops subsequent calls.
    session2 = str(uuid4())
    p2 = start_pass(project_id,resource_id,stable_id,session_id=session2,budget=limits(max_tokens=128))
    _,token_result,_ = record_call(project_id,resource_id,stable_id,p2["pass_id"],session2,
        key="token-overrun",cursor_before={"page":1},cursor_after={"page":2},
        candidate={"action":"skip"},estimated_tokens=128,actual_tokens=129)
    if token_result.get("stop_reason")!="token_budget":
        raise AssertionError(f"Token overrun did not stop and persist: {token_result}")

    # Cost overrun is recorded atomically and stops subsequent calls.
    session3 = str(uuid4())
    p3 = start_pass(project_id,resource_id,stable_id,session_id=session3,budget=limits(max_cost_micros=1))
    _,cost_result,_ = record_call(project_id,resource_id,stable_id,p3["pass_id"],session3,
        key="cost-overrun",cursor_before={"page":1},cursor_after={"page":2},
        candidate={"action":"skip"},estimated_cost=1,actual_cost=2)
    if cost_result.get("stop_reason")!="cost_budget":
        raise AssertionError(f"Cost overrun did not stop and persist: {cost_result}")

    # Elapsed-time cap is enforced before starting another external read.
    session4 = str(uuid4())
    p4 = start_pass(project_id,resource_id,stable_id,session_id=session4,budget=limits(max_elapsed_ms=1000))
    time.sleep(1.1)
    time_stop = reserve(project_id,resource_id,stable_id,p4["pass_id"],session4,cursor={"page":1})
    if time_stop.get("reason")!="elapsed_budget":
        raise AssertionError(f"Elapsed-time budget did not stop the next tool call: {time_stop}")

    # No-progress guard stops after repeated skips; the next session resumes after the skipped item.
    session5 = str(uuid4())
    p5 = start_pass(project_id,resource_id,stable_id,session_id=session5,budget=limits(max_no_progress=1))
    _,no_progress,_ = record_call(project_id,resource_id,stable_id,p5["pass_id"],session5,
        key="no-progress",cursor_before={"page":1},cursor_after={"page":2},
        candidate={
            "action":"skip","candidate_key":"candidate:skip-not-actionable",
            "reason":"duplicate_or_not_actionable"
        })
    if (no_progress.get("stop_reason")!="no_progress"
            or no_progress.get("resume_cursor")!={"page":2}
            or not no_progress.get("candidate_fingerprint")):
        raise AssertionError(f"Skipped candidate fingerprint/no-progress state was not persisted: {no_progress}")
    blocked_session = str(uuid4())
    blocked_resume = start_pass(project_id,resource_id,stable_id,session_id=blocked_session,
        budget=limits(max_no_progress=1),resume_from=p5["pass_id"])
    blocked_call = reserve(project_id,resource_id,stable_id,blocked_resume["pass_id"],
        blocked_session,cursor={"page":2})
    if blocked_call.get("reason")!="no_progress":
        raise AssertionError(f"Exhausted no-progress budget must stop before another read: {blocked_call}")

    resumed_session = str(uuid4())
    resumed_no_progress = start_pass(project_id,resource_id,stable_id,session_id=resumed_session,
        budget=limits(max_no_progress=2),resume_from=p5["pass_id"])
    if resumed_no_progress.get("no_progress_count") != 1:
        raise AssertionError(f"Resume reset the cumulative no-progress count: {resumed_no_progress}")
    _,no_progress_again,_ = record_call(project_id,resource_id,stable_id,
        resumed_no_progress["pass_id"],resumed_session,
        key="no-progress-again",cursor_before={"page":2},cursor_after={"page":3},
        candidate={"action":"skip","reason":"same_candidate_no_progress"})
    if no_progress_again.get("stop_reason")!="no_progress" or no_progress_again.get("no_progress_count") != 2:
        raise AssertionError(f"Repeated no-progress across sessions did not stop: {no_progress_again}")

    # Repeated exact child fingerprints link to the canonical Work, then stop
    # when no new eligible Work is created.
    duplicate_session = str(uuid4())
    duplicate_pass = start_pass(project_id,resource_id,stable_id,
        session_id=duplicate_session,budget=limits(max_no_progress=1))
    repeated = candidate("child:repeat-this-fingerprint","Repeated child candidate")
    _,first_candidate,_ = record_call(
        project_id,resource_id,stable_id,duplicate_pass["pass_id"],duplicate_session,
        key="repeat-first",cursor_before={"page":1},cursor_after={"page":2},
        candidate=repeated
    )
    if first_candidate.get("decision")!="accepted":
        raise AssertionError(f"First child fingerprint should create the canonical Work: {first_candidate}")
    _,repeated_candidate,_ = record_call(
        project_id,resource_id,stable_id,duplicate_pass["pass_id"],duplicate_session,
        key="repeat-second",cursor_before={"page":2},cursor_after={"page":3},
        candidate=repeated
    )
    if (repeated_candidate.get("decision")!="linked"
            or repeated_candidate.get("stop_reason")!="no_progress"
            or repeated_candidate.get("candidate_fingerprint")!=first_candidate.get("candidate_fingerprint")):
        raise AssertionError(f"Repeated child fingerprint must link and stop for no progress: {repeated_candidate}")
    repeated_work_count = scalar(
        "SELECT count(*) FROM aep.works WHERE project_id="
        f"{lit(project_id)}::uuid AND identity_kind='discovery_candidate_v1' "
        f"AND identity_key={lit(first_candidate['candidate_fingerprint'])};"
    )
    if repeated_work_count!="1":
        raise AssertionError(f"Repeated child fingerprint created {repeated_work_count} canonical Work rows")



def test_interrupted_reservation_recovery(
    project_id: str, resource_id: str, stable_id: str
) -> None:
    old_session = str(uuid4())
    old_pass = start_pass(project_id,resource_id,stable_id,session_id=old_session)
    call_key = "interrupted-read"
    source_ref = f"github://github.com/{stable_id}/issues/77"
    reservation = json_result(
        "SELECT aep.reserve_discovery_call("
        f"{lit(project_id)}::uuid,{lit(resource_id)}::uuid,{lit(old_pass['pass_id'])}::uuid,"
        f"{lit(old_session)}::uuid,{lit(call_key)},'github_fetch_issue','issue',"
        f"{lit(source_ref)},{json_sql({'page':1})},100,80);"
    )
    assert_status(reservation,"reserved","interrupted tool-call reservation")

    evidence_before = scalar(
        "SELECT count(*) FROM aep.evidence WHERE project_id="
        f"{lit(project_id)}::uuid AND evidence_type='discovery_observation';"
    )
    new_session = str(uuid4())
    resumed = start_pass(
        project_id,resource_id,stable_id,session_id=new_session,
        request_key="resume-interrupted-read",
        budget=limits(max_tool_calls=10),resume_from=old_pass["pass_id"]
    )
    assert_status(resumed,"running","new-session recovery of in-flight read")
    replayed = start_pass(
        project_id,resource_id,stable_id,session_id=new_session,
        request_key="resume-interrupted-read",
        budget=limits(max_tool_calls=10),resume_from=old_pass["pass_id"]
    )
    if replayed.get("pass_id")!=resumed.get("pass_id") or replayed.get("idempotent_replay") is not True:
        raise AssertionError(f"Lost recovery response must replay the same resumed pass: {replayed}")
    if (resumed.get("tool_calls_used") != 1 or resumed.get("tokens_used") != 100
            or resumed.get("cost_used_micros") != 80
            or resumed.get("resume_cursor") != {"page":1}):
        raise AssertionError(f"Recovery must retain reserved budget and retry the pre-read cursor: {resumed}")

    late_reservation_replay = json_result(
        "SELECT aep.reserve_discovery_call("
        f"{lit(project_id)}::uuid,{lit(resource_id)}::uuid,{lit(old_pass['pass_id'])}::uuid,"
        f"{lit(old_session)}::uuid,{lit(call_key)},'github_fetch_issue','issue',"
        f"{lit(source_ref)},{json_sql({'page':1})},100,80);"
    )
    assert_status(late_reservation_replay,"stopped","old-session reservation replay after takeover")

    # The old session may still return, but its stopped pass fences the late result
    # before it can append Evidence or create/link canonical Work.
    late_result = json_result(complete_sql(
        project_id,resource_id,old_pass["pass_id"],old_session,call_key,source_ref,
        cursor_after={"page":2},resume_cursor={"page":2},
        candidate=candidate("late-result:must-be-ignored","Late result"),
    ))
    assert_status(late_result,"stopped","late completion from superseded session")
    evidence_after_late = scalar(
        "SELECT count(*) FROM aep.evidence WHERE project_id="
        f"{lit(project_id)}::uuid AND evidence_type='discovery_observation';"
    )
    if evidence_after_late != evidence_before:
        raise AssertionError("A late result from the superseded session created Evidence")

    late_fingerprint = __import__("hashlib").sha256(
        f"{project_id}|discovery_candidate_v1|late-result:must-be-ignored".encode()
    ).hexdigest()
    late_work_count = scalar(
        "SELECT count(*) FROM aep.works WHERE project_id="
        f"{lit(project_id)}::uuid AND identity_kind='discovery_candidate_v1' "
        f"AND identity_key={lit(late_fingerprint)};"
    )
    if late_work_count != "0":
        raise AssertionError("A late result from the superseded session created canonical Work")

    _,retry_result,_ = record_call(
        project_id,resource_id,stable_id,resumed["pass_id"],new_session,
        key="retry-interrupted-read",cursor_before={"page":1},cursor_after={"page":2},
        candidate={"action":"skip","reason":"replayed_read_after_session_recovery"}
    )
    if retry_result.get("status") not in ("recorded","stopped") or retry_result.get("decision")!="skipped":
        raise AssertionError(f"New session could not retry the interrupted read: {retry_result}")


def test_depth_and_fanout(project_id: str, resource_id: str, stable_id: str) -> None:
    # A depth stop preserves the current source cursor; a later pass can accept it.
    session = str(uuid4())
    root_pass = start_pass(project_id,resource_id,stable_id,session_id=session)
    root_res,root_done,_ = record_call(project_id,resource_id,stable_id,root_pass["pass_id"],session,
        key="root-candidate",cursor_before={"page":1},cursor_after={"page":2},
        candidate=candidate("root:initiative","Root initiative"))
    if root_done.get("decision")!="accepted":
        raise AssertionError(f"Root discovery candidate was not accepted: {root_done}")
    root_id = root_res["observation_id"]

    limited_session = str(uuid4())
    limited = start_pass(project_id,resource_id,stable_id,session_id=limited_session,
                         budget=limits(max_depth=0))
    _,pending,_ = record_call(project_id,resource_id,stable_id,limited["pass_id"],limited_session,
        key="too-deep",cursor_before={"page":1},cursor_after={"page":2},
        candidate=candidate("child:too-deep","Child blocked by depth"),
        parent_observation_id=root_id)
    if pending.get("decision")!="pending" or pending.get("stop_reason")!="depth_budget":
        raise AssertionError(f"Depth limit did not persist pending candidate: {pending}")
    if pending.get("resume_cursor")!={"page":1}:
        raise AssertionError(f"Depth limit must resume at the pending candidate: {pending}")

    resumed_session = str(uuid4())
    resumed = start_pass(project_id,resource_id,stable_id,session_id=resumed_session,
                         budget=limits(max_depth=2),resume_from=limited["pass_id"])
    _,accepted,_ = record_call(project_id,resource_id,stable_id,resumed["pass_id"],resumed_session,
        key="retry-too-deep",cursor_before={"page":1},cursor_after={"page":2},
        candidate=candidate("child:too-deep","Child now within depth"),
        parent_observation_id=root_id)
    if accepted.get("decision")!="accepted":
        raise AssertionError(f"Resumed pending candidate did not register: {accepted}")

    # Fan-out limit is checked against active parent_child relations, not similarity.
    fan_session = str(uuid4())
    fan = start_pass(project_id,resource_id,stable_id,session_id=fan_session,
                     budget=limits(max_fanout=1))
    parent_r,parent_done,_ = record_call(project_id,resource_id,stable_id,fan["pass_id"],fan_session,
        key="fan-parent",cursor_before={"page":1},cursor_after={"page":2},
        candidate=candidate("fan:parent","Fan-out parent"))
    child_r,child_done,_ = record_call(project_id,resource_id,stable_id,fan["pass_id"],fan_session,
        key="fan-child-one",cursor_before={"page":2},cursor_after={"page":3},
        candidate=candidate("fan:child-one","First child"),parent_observation_id=parent_r["observation_id"])
    if child_done.get("decision")!="accepted":
        raise AssertionError(f"First child should fit fan-out budget: {child_done}")
    _,fan_stop,_ = record_call(project_id,resource_id,stable_id,fan["pass_id"],fan_session,
        key="fan-child-two",cursor_before={"page":3},cursor_after={"page":4},
        candidate=candidate("fan:child-two","Second child"),parent_observation_id=parent_r["observation_id"])
    if fan_stop.get("decision")!="pending" or fan_stop.get("stop_reason")!="fanout_budget":
        raise AssertionError(f"Fan-out guard did not persist pending candidate: {fan_stop}")


def test_read_only_owner_gate_and_queue(project_id: str, resource_id: str, stable_id: str) -> None:
    read_project,read_resource,read_stable = setup_scope(access_mode="read")
    session = str(uuid4())
    p = start_pass(read_project,read_resource,read_stable,session_id=session)
    _,result,_ = record_call(read_project,read_resource,read_stable,p["pass_id"],session,
        key="read-only-candidate",cursor_before={"page":1},cursor_after={"page":2},
        candidate=candidate("read-only:proposal","Proposal from read-only source"))
    if result.get("decision")!="approval_required" or result.get("reason")!="write_scope_required":
        raise AssertionError(f"Read-only Resource grant created executable Work: {result}")
    count = scalar(
        "SELECT count(*) FROM aep.works WHERE project_id="
        f"{lit(read_project)}::uuid AND identity_kind='discovery_candidate_v1';"
    )
    if count!="0":
        raise AssertionError(f"Read-only grant registered {count} Work rows")

    # Owner-retained/product decisions preserve candidate identity/evidence but do not
    # become executable implementation Work without an explicit Owner decision.
    owner_session = str(uuid4())
    owner_pass = start_pass(project_id,resource_id,stable_id,session_id=owner_session)
    _,owner_required,_ = record_call(
        project_id,resource_id,stable_id,owner_pass["pass_id"],owner_session,
        key="owner-retained-decision",cursor_before={"page":1},cursor_after={"page":2},
        candidate={
            "action":"approval_required",
            "candidate_key":"owner-retained:product-policy",
            "reason":"owner_retained_product_decision",
        }
    )
    if (owner_required.get("decision")!="approval_required"
            or owner_required.get("reason")!="owner_retained_product_decision"
            or not owner_required.get("candidate_fingerprint")
            or owner_required.get("work_id") is not None):
        raise AssertionError(f"Owner-retained candidate was not durably held for approval: {owner_required}")
    owner_evidence = scalar(
        "SELECT provenance->>'candidate_fingerprint' FROM aep.evidence WHERE evidence_id="
        f"{lit(owner_required['evidence_id'])}::uuid;"
    )
    if owner_evidence != owner_required["candidate_fingerprint"]:
        raise AssertionError("Approval-required Evidence did not preserve the candidate fingerprint")

    # The active Work queue blocks new discovery before any source call is reserved.
    ready_work = scalar(
        "SELECT work_id::text FROM aep.register_work("
        f"{lit(project_id)}::uuid,{lit('ready-'+uuid4().hex)},{lit(str(uuid4()))}::uuid,"
        "'stage4d_queue','ready-queue-fixture',1,'implementation','Ready queue fixture','{}'::jsonb,NULL);"
    )
    scalar(f"SELECT * FROM aep.set_work_ready({lit(ready_work)}::uuid);")
    denied = start_pass(project_id,resource_id,stable_id,request_key="queue-must-not-scan")
    assert_status(denied,"queue_not_empty","ready queue preflight")


def test_possible_duplicate_is_nonblocking(
    project_id: str, resource_id: str, stable_id: str
) -> None:
    anchor_id = scalar(
        "SELECT work_id::text FROM aep.register_work("
        f"{lit(project_id)}::uuid,{lit('possible-duplicate-anchor-'+uuid4().hex)},"
        f"{lit(str(uuid4()))}::uuid,'stage4d_fixture','existing-distinct-work',1,"
        "'implementation','Existing distinct Work','{}'::jsonb,NULL);"
    )
    session = str(uuid4())
    pass_value = start_pass(project_id,resource_id,stable_id,session_id=session)
    _,result,_ = record_call(
        project_id,resource_id,stable_id,pass_value["pass_id"],session,
        key="possible-duplicate-candidate",cursor_before={"page":1},cursor_after={"page":2},
        candidate=candidate(
            "distinct-work:related-not-identical","Related but distinct Work",
            possible_duplicate_work_id=anchor_id
        )
    )
    if result.get("decision")!="accepted" or result.get("work_id")==anchor_id:
        raise AssertionError(f"Possible duplicate must not block canonical Work registration: {result}")
    relation_count = scalar(
        "SELECT count(*) FROM aep.work_relations "
        f"WHERE relation_type='possible_duplicate' "
        f"AND source_work_id=LEAST({lit(anchor_id)}::uuid,{lit(result['work_id'])}::uuid) "
        f"AND target_work_id=GREATEST({lit(anchor_id)}::uuid,{lit(result['work_id'])}::uuid);"
    )
    if relation_count!="1":
        raise AssertionError(f"Expected a non-merging possible_duplicate relation, got {relation_count}")
    work_count = scalar(
        "SELECT count(*) FROM aep.works WHERE project_id="
        f"{lit(project_id)}::uuid AND work_id IN ({lit(anchor_id)}::uuid,{lit(result['work_id'])}::uuid);"
    )
    if work_count!="2":
        raise AssertionError(f"Possible duplicate relation merged/lost a Work: {work_count}")


def test_revocation_before_payload_read() -> None:
    project_id,resource_id,stable_id = setup_scope(access_mode="write")
    session = str(uuid4())
    p = start_pass(project_id,resource_id,stable_id,session_id=session)
    call_key = "reserved-before-revocation"
    source_ref = f"github://github.com/{stable_id}/issues/99"
    reserved = json_result(
        "SELECT aep.reserve_discovery_call("
        f"{lit(project_id)}::uuid,{lit(resource_id)}::uuid,{lit(p['pass_id'])}::uuid,"
        f"{lit(session)}::uuid,{lit(call_key)},'github_fetch_issue','issue',"
        f"{lit(source_ref)},{json_sql({'page':1})},100,100);"
    )
    assert_status(reserved,"reserved","pre-revocation read reservation")
    before = scalar(
        "SELECT count(*) FROM aep.evidence WHERE project_id="
        f"{lit(project_id)}::uuid AND evidence_type='discovery_observation';"
    )
    psql(
        "UPDATE aep.project_resources SET status='revoked',revoked_at=clock_timestamp(),"
        "grant_version=grant_version+1 "
        f"WHERE project_id={lit(project_id)}::uuid AND resource_id={lit(resource_id)}::uuid;"
    )
    denied = json_result(complete_sql(
        project_id,resource_id,p["pass_id"],session,call_key,source_ref,
        cursor_after={"page":2},resume_cursor={"page":2},
        candidate=candidate("revoked:must-not-register","Must not register"),
    ))
    assert_status(denied,"denied","revoked complete call before payload read")
    state = json_result(
        "SELECT aep.get_discovery_state("
        f"{lit(project_id)}::uuid,{lit(resource_id)}::uuid,10);"
    )
    assert_status(state,"denied","revoked discovery state read")
    after = scalar(
        "SELECT count(*) FROM aep.evidence WHERE project_id="
        f"{lit(project_id)}::uuid AND evidence_type='discovery_observation';"
    )
    if before != after:
        raise AssertionError(
            f"Revoked resource scope persisted a source payload: Evidence count {before} -> {after}"
        )


def main() -> None:
    setup_database()
    test_runtime_boundary()
    project_id,resource_id,stable_id = setup_scope(access_mode="write")
    test_concurrent_canonical_registration(project_id,resource_id,stable_id)
    test_budgets_and_resume(project_id,resource_id,stable_id)
    test_interrupted_reservation_recovery(project_id,resource_id,stable_id)
    test_depth_and_fanout(project_id,resource_id,stable_id)
    test_possible_duplicate_is_nonblocking(project_id,resource_id,stable_id)
    test_read_only_owner_gate_and_queue(project_id,resource_id,stable_id)
    test_revocation_before_payload_read()
    print(
        "PASS T19: empty-queue discovery, reproducible Evidence, concurrent canonical "
        "register-or-link, and no duplicate Work; "
        "PASS T20: tool/time/token/cost/depth/fan-out/no-progress stops, durable cursors, "
        "fresh-session resume, authorization-before-retrieval, and no external writes"
    )


if __name__ == "__main__":
    main()
