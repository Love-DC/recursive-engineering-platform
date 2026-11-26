#!/usr/bin/env python3
"""Adversarial Stage 2B dependency graph tests on a disposable PostgreSQL 17.12 database."""

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
DATABASE = "aep_stage2b_test"
HOST = os.environ.get("PGHOST", "127.0.0.1")
PORT = os.environ.get("PGPORT", "5432")
USER = os.environ.get("PGUSER", "postgres")
PASSWORD = os.environ.get("PGPASSWORD", "postgres")
CMD = [
    "psql", "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1",
    "-h", HOST, "-p", PORT, "-U", USER, "-d", DATABASE,
]


def psql(sql: str | None = None, *, db: str = DATABASE, check: bool = True,
         file: Path | None = None) -> subprocess.CompletedProcess[str]:
    cmd = [
        "psql", "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1",
        "-h", HOST, "-p", PORT, "-U", USER, "-d", db,
    ]
    cmd.extend(["-f", str(file)] if file else ["-c", sql or ""])
    env = os.environ.copy()
    env["PGPASSWORD"] = PASSWORD
    result = subprocess.run(cmd, text=True, capture_output=True, env=env, check=False)
    if check and result.returncode:
        raise RuntimeError(f"psql failed:\n{result.stdout}\n{result.stderr}")
    return result


def lit(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def scalar(sql: str) -> str:
    return psql(sql).stdout.strip()


def expect_error(sql: str, needle: str, label: str) -> None:
    result = psql(sql, check=False)
    if result.returncode == 0 or needle not in result.stderr:
        raise AssertionError(
            f"{label}: expected {needle!r}; rc={result.returncode}; "
            f"stdout={result.stdout}; stderr={result.stderr}"
        )


def create_project(name: str) -> str:
    return scalar(
        "INSERT INTO aep.projects(project_key,name) VALUES("
        f"{lit(name)},{lit(name)}) RETURNING project_id;"
    )


def register_work(project_id: str, identity: str, title: str | None = None) -> str:
    return scalar(
        "SELECT work_id::text FROM aep.register_work("
        f"{lit(project_id)}::uuid,{lit(str(uuid4()))},{lit(str(uuid4()))}::uuid,"
        f"'stage2b',{lit(identity)},1,'implementation',"
        f"{lit(title or identity)},'{}'::jsonb,NULL);"
    )


def ready_work(project_id: str, identity: str) -> str:
    work_id = register_work(project_id, identity)
    result = scalar(
        f"SELECT work_status FROM aep.set_work_ready({lit(work_id)}::uuid);"
    )
    if result != "ready":
        raise AssertionError(f"new Work without prerequisites did not become READY: {result}")
    return work_id


def graph_for(project_id: str) -> str:
    return scalar(
        "SELECT graph_id::text FROM aep.dependency_graphs "
        f"WHERE owner_project_id={lit(project_id)}::uuid AND is_default;"
    )


def owner_decision(project_id: str, graph_id: str, access: str, suffix: str = "") -> str:
    key = "dependency_graph:" + graph_id + ":" + access
    version = scalar(
        "SELECT (COALESCE(max(decision_version),0)+1)::text "
        "FROM aep.owner_decisions WHERE scope_type='project' "
        f"AND scope_key={lit(project_id)} AND decision_key={lit(key)};"
    )
    return scalar(
        "INSERT INTO aep.owner_decisions("
        "scope_type,scope_key,decision_key,statement,decision_version,status,"
        "approval_source_kind,approval_source_ref,approver_principal,"
        "approval_provenance,approved_at"
        ") VALUES("
        f"'project',{lit(project_id)},{lit(key)},"
        f"{lit('Approved '+access+' access '+suffix)},{version},'approved',"
        "'direct_owner_message','test://owner/aep-stage2b','test-owner',"
        "jsonb_build_object('direct_owner_confirmation',true),clock_timestamp()"
        ") RETURNING decision_id;"
    )


def create_shared_graph(owner_project: str) -> str:
    return scalar(
        f"SELECT aep.create_dependency_graph({lit(owner_project)}::uuid);"
    )


def set_member(graph_id: str, project_id: str, access: str) -> str:
    decision = owner_decision(project_id, graph_id, access, project_id)
    return scalar(
        "SELECT aep.set_dependency_graph_member("
        f"{lit(graph_id)}::uuid,{lit(project_id)}::uuid,"
        f"{lit(access)},{lit(decision)}::uuid);"
    )


def mutate_sql(graph_id: str, request_key: str, operations: list[dict[str, str]]) -> str:
    import json
    payload = json.dumps(operations, separators=(",", ":"))
    return (
        "SELECT aep.mutate_dependencies("
        f"{lit(graph_id)}::uuid,{lit(request_key)},{lit(payload)}::jsonb);"
    )


def op(action: str, source: str, target: str) -> dict[str, str]:
    return {"op": action, "source_work_id": source, "target_work_id": target}


def claim(work_id: str) -> tuple[str, int, int, int]:
    raw = scalar(
        "SELECT execution_id::text || '|' || attempt_no::text || '|' "
        "|| fence::text || '|' || work_version::text "
        f"FROM aep.claim_work({lit(work_id)}::uuid,{lit(str(uuid4()))}::uuid,60);"
    )
    execution_id, attempt, fence, version = raw.split("|")
    return execution_id, int(attempt), int(fence), int(version)


def finish_success(work_id: str, claimed: tuple[str, int, int, int]) -> str:
    execution_id, _, fence, version = claimed
    return scalar(
        "SELECT work_status FROM aep.finish_execution("
        f"{lit(work_id)}::uuid,{lit(execution_id)}::uuid,{fence},{version},"
        "'succeeded','{}'::jsonb);"
    )


def complete_work(work_id: str) -> None:
    state = finish_success(work_id, claim(work_id))
    if state != "delivered":
        raise AssertionError(f"expected delivered Work, got {state}")


def install_mutation_rendezvous() -> None:
    psql("""
      CREATE OR REPLACE FUNCTION public.aep_test_mutate_rendezvous(
        p_graph_id uuid, p_request_key text, p_operations jsonb
      ) RETURNS jsonb
      LANGUAGE plpgsql
      SET search_path=pg_catalog,aep,public
      AS $test$
      BEGIN
        PERFORM pg_advisory_xact_lock_shared(21473,98122);
        RETURN aep.mutate_dependencies(p_graph_id,p_request_key,p_operations);
      END
      $test$;
    """)


def race_mutations(graph_id: str, operations: list[list[dict[str, str]]]) -> list[subprocess.CompletedProcess[str]]:
    """Release two independent PostgreSQL sessions from a database-side barrier."""
    install_mutation_rendezvous()
    env = os.environ.copy()
    env["PGPASSWORD"] = PASSWORD
    controller = subprocess.Popen(
        CMD, text=True, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, env=env, bufsize=1,
    )
    workers: list[subprocess.Popen[str]] = []
    try:
        assert controller.stdin is not None and controller.stdout is not None
        controller.stdin.write(
            "SELECT pg_backend_pid(); SELECT pg_advisory_lock(21473,98122);\n"
        )
        controller.stdin.flush()
        ready, _, _ = select.select([controller.stdout], [], [], 10)
        if not ready:
            raise AssertionError("mutation race controller did not return PID")
        controller_pid = int(controller.stdout.readline().strip())

        for batch in operations:
            sql = (
                "SELECT public.aep_test_mutate_rendezvous("
                f"{lit(graph_id)}::uuid,{lit(str(uuid4()))},"
                f"{lit(__import__('json').dumps(batch,separators=(',',':')))}::jsonb);"
            )
            workers.append(subprocess.Popen(
                CMD + ["-c", sql], text=True, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, env=env,
            ))

        deadline = time.monotonic() + 15
        waiting = "0"
        while time.monotonic() < deadline:
            if any(proc.poll() is not None for proc in workers):
                raise AssertionError("mutation worker exited before reaching advisory barrier")
            waiting = scalar(
                "SELECT count(*) FROM pg_stat_activity "
                f"WHERE pid <> {controller_pid} AND datname=current_database() "
                "AND wait_event_type='Lock' AND wait_event='advisory' "
                "AND query LIKE '%aep_test_mutate_rendezvous%';"
            )
            if waiting == str(len(workers)):
                break
            time.sleep(0.05)
        if waiting != str(len(workers)):
            raise AssertionError(f"expected {len(workers)} sessions at barrier, found {waiting}")

        controller.stdin.close()
        controller.wait(timeout=10)
        controller.stdout.read()
        controller.stderr.read()

        results = []
        for worker in workers:
            out, err = worker.communicate(timeout=30)
            results.append(subprocess.CompletedProcess(worker.args, worker.returncode, out, err))
        return results
    finally:
        if controller.poll() is None:
            controller.terminate()
            controller.wait(timeout=5)
        for worker in workers:
            if worker.poll() is None:
                worker.terminate()
                worker.communicate(timeout=5)
        psql(
            "DROP FUNCTION IF EXISTS public.aep_test_mutate_rendezvous(uuid,text,jsonb);",
            check=False,
        )


def race_lock_then_waiter(graph_id: str, holder_lock: str, holder_action: str,
                          waiter_sql: str, waiter_fragment: str) -> tuple[subprocess.CompletedProcess[str], subprocess.CompletedProcess[str]]:
    """Hold the graph lock, observe a competing RPC waiting, then release the holder."""
    env = os.environ.copy()
    env["PGPASSWORD"] = PASSWORD
    key_class, key_object = 21473, 98123
    holder_sql = (
        "BEGIN; "
        f"{holder_lock}; "
        f"SELECT pg_advisory_lock({key_class},{key_object}); "
        "SELECT pg_sleep(0.6); "
        f"{holder_action}; "
        "COMMIT;"
    )
    holder = subprocess.Popen(
        CMD + ["-c", holder_sql], text=True, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, env=env,
    )
    waiter = None
    try:
        deadline = time.monotonic() + 10
        lock_seen = False
        while time.monotonic() < deadline:
            if holder.poll() is not None:
                out, err = holder.communicate()
                raise AssertionError(f"graph-lock holder exited early: {out}\n{err}")
            lock_seen = scalar(
                "SELECT count(*) FROM pg_locks "
                "WHERE locktype='advisory' AND classid=21473 AND objid=98123 "
                "AND granted;"
            ) == "1"
            if lock_seen:
                break
            time.sleep(0.02)
        if not lock_seen:
            raise AssertionError("graph-lock holder did not publish its advisory rendezvous")

        waiter = subprocess.Popen(
            CMD + ["-c", waiter_sql], text=True, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, env=env,
        )
        deadline = time.monotonic() + 10
        waiting = False
        while time.monotonic() < deadline:
            if waiter.poll() is not None:
                out, err = waiter.communicate()
                raise AssertionError(f"competing RPC did not wait for the graph lock: {out}\n{err}")
            waiting = scalar(
                "SELECT count(*) FROM pg_stat_activity "
                "WHERE datname=current_database() AND wait_event_type='Lock' "
                f"AND query LIKE {lit('%'+waiter_fragment+'%')};"
            ) != "0"
            if waiting:
                break
            time.sleep(0.02)
        if not waiting:
            raise AssertionError("competing RPC did not enter a PostgreSQL lock wait")

        holder_out, holder_err = holder.communicate(timeout=15)
        holder_result = subprocess.CompletedProcess(holder.args, holder.returncode, holder_out, holder_err)
        waiter_out, waiter_err = waiter.communicate(timeout=15)
        waiter_result = subprocess.CompletedProcess(waiter.args, waiter.returncode, waiter_out, waiter_err)
        return holder_result, waiter_result
    finally:
        if holder.poll() is None:
            holder.terminate()
            holder.communicate(timeout=5)
        if waiter is not None and waiter.poll() is None:
            waiter.terminate()
            waiter.communicate(timeout=5)


def main() -> None:
    migration_paths = sorted(MIGRATIONS.glob("*.sql"))
    versions = []
    for path in migration_paths:
        match = re.fullmatch(r"(\d{4})_[a-z0-9_]+\.sql", path.name)
        if not match:
            raise SystemExit(f"Invalid migration filename: {path.name}")
        versions.append(int(match.group(1)))
    if versions != list(range(1, 7)):
        raise SystemExit(f"Expected contiguous migrations 0001..0006, got {versions}")

    psql("DROP DATABASE IF EXISTS aep_stage2b_test WITH (FORCE);", db="postgres")
    psql("CREATE DATABASE aep_stage2b_test;", db="postgres")
    version = scalar("SELECT current_setting('server_version');")
    if not version.startswith("17.12"):
        raise AssertionError(f"Stage 2B requires PostgreSQL 17.12; got {version}")
    for path in migration_paths:
        psql(file=path)
    print("PASS Stage 2B clean migration chain 0001-0006 on PostgreSQL 17.12")

    # T07: two independent opposite-edge writers serialize on the graph root.
    project = create_project("stage2b-t07")
    graph = graph_for(project)
    work_a = register_work(project, "t07-a")
    work_b = register_work(project, "t07-b")
    install_mutation_rendezvous()
    results = race_mutations(
        graph,
        [[op("add", work_a, work_b)], [op("add", work_b, work_a)]],
    )
    successes = [r for r in results if r.returncode == 0]
    failures = [r for r in results if r.returncode != 0]
    if len(successes) != 1 or len(failures) != 1:
        raise AssertionError(
            "T07 expected one committed edge and one rejected opposite edge: "
            + repr([(r.returncode, r.stdout, r.stderr) for r in results])
        )
    if "directed cycle" not in failures[0].stderr:
        raise AssertionError(f"T07 loser was not rejected by cycle detection: {failures[0].stderr}")
    if scalar(
        f"SELECT count(*) FROM aep.work_relations WHERE dependency_graph_id={lit(graph)}::uuid "
        "AND relation_type='depends_on' AND status='active';"
    ) != "1" or scalar(
        f"SELECT graph_version::text FROM aep.dependency_graphs WHERE graph_id={lit(graph)}::uuid;"
    ) != "2":
        raise AssertionError("T07 produced a cycle, duplicate edge, or non-monotonic graph version")
    print("PASS T07: independent opposite-edge transactions cannot both commit a cycle")

    # T08: concurrent multi-edge batches cannot create a longer cycle; losing
    # batch rolls back every earlier edge in that batch.
    project8 = create_project("stage2b-t08")
    graph8 = graph_for(project8)
    a, b, c, d = [register_work(project8, f"t08-{name}") for name in "abcd"]
    batch_left = [op("add", a, b), op("add", b, c)]
    batch_right = [op("add", c, d), op("add", d, a)]
    results8 = race_mutations(graph8, [batch_left, batch_right])
    success8 = [r for r in results8 if r.returncode == 0]
    failure8 = [r for r in results8 if r.returncode != 0]
    if len(success8) != 1 or len(failure8) != 1 or "directed cycle" not in failure8[0].stderr:
        raise AssertionError(
            "T08 expected exactly one multi-edge batch to commit: "
            + repr([(r.returncode, r.stdout, r.stderr) for r in results8])
        )
    count8 = scalar(
        f"SELECT count(*) FROM aep.work_relations WHERE dependency_graph_id={lit(graph8)}::uuid "
        "AND relation_type='depends_on' AND status='active';"
    )
    version8 = scalar(
        f"SELECT graph_version::text FROM aep.dependency_graphs WHERE graph_id={lit(graph8)}::uuid;"
    )
    if count8 != "2" or version8 != "2":
        raise AssertionError(f"T08 partial batch or bad graph version: edges={count8}, version={version8}")

    # A failed batch after its first valid edge must roll back the first edge too.
    rollback_a, rollback_b, rollback_c = [
        register_work(project8, f"t08-rollback-{name}") for name in "abc"
    ]
    before = scalar(
        f"SELECT graph_version::text FROM aep.dependency_graphs WHERE graph_id={lit(graph8)}::uuid;"
    )
    expect_error(
        mutate_sql(graph8, str(uuid4()), [
            op("add", rollback_a, rollback_b),
            op("add", rollback_b, rollback_c),
            op("add", rollback_c, rollback_a),
        ]),
        "directed cycle",
        "T08 atomic three-edge cycle batch",
    )
    if scalar(
        "SELECT count(*) FROM aep.work_relations "
        f"WHERE source_work_id IN ({lit(rollback_a)}::uuid,{lit(rollback_b)}::uuid,{lit(rollback_c)}::uuid) "
        "AND status='active' AND relation_type='depends_on';"
    ) != "0" or scalar(
        f"SELECT graph_version::text FROM aep.dependency_graphs WHERE graph_id={lit(graph8)}::uuid;"
    ) != before:
        raise AssertionError("T08 failed multi-edge batch left partial relations or incremented graph version")
    print("PASS T08: concurrent multi-edge batches and cycle failures roll back atomically")

    # Idempotent replay/no-op behavior and graph-scoped edge uniqueness.
    replay_source, replay_target = register_work(project8, "t08-replay-source"), register_work(project8, "t08-replay-target")
    replay_key = str(uuid4())
    replay_sql = mutate_sql(graph8, replay_key, [op("add", replay_source, replay_target)])
    first_result = scalar(replay_sql)
    version_after_first = scalar(
        f"SELECT graph_version::text FROM aep.dependency_graphs WHERE graph_id={lit(graph8)}::uuid;"
    )
    replay_result = scalar(replay_sql)
    if first_result != replay_result:
        raise AssertionError("identical dependency request replay did not return its original result")
    expect_error(
        mutate_sql(graph8, replay_key, [op("add", replay_target, replay_source)]),
        "reused with a different payload",
        "dependency request key payload mismatch",
    )
    duplicate_result = scalar(
        mutate_sql(graph8, str(uuid4()), [op("add", replay_source, replay_target)])
    )
    version_after_duplicate = scalar(
        f"SELECT graph_version::text FROM aep.dependency_graphs WHERE graph_id={lit(graph8)}::uuid;"
    )
    if version_after_first != version_after_duplicate or '"changed": false' not in duplicate_result:
        raise AssertionError("duplicate edge no-op incorrectly incremented graph version")
    remove_result = scalar(
        mutate_sql(graph8, str(uuid4()), [op("remove", replay_source, replay_target)])
    )
    if '"removed": 1' not in remove_result or scalar(
        "SELECT status FROM aep.work_relations "
        f"WHERE source_work_id={lit(replay_source)}::uuid "
        f"AND target_work_id={lit(replay_target)}::uuid "
        "AND relation_type='depends_on' ORDER BY created_at DESC LIMIT 1;"
    ) != "removed":
        raise AssertionError("dependency removal did not preserve an append-only removed relation row")
    version_removed = scalar(
        f"SELECT graph_version::text FROM aep.dependency_graphs WHERE graph_id={lit(graph8)}::uuid;"
    )
    scalar(mutate_sql(graph8, str(uuid4()), [op("add", replay_source, replay_target)]))
    if scalar(
        "SELECT count(*) FROM aep.work_relations "
        f"WHERE source_work_id={lit(replay_source)}::uuid "
        f"AND target_work_id={lit(replay_target)}::uuid "
        "AND relation_type='depends_on' AND status='removed';"
    ) != "1":
        raise AssertionError("re-adding an edge rewrote or deleted its removed history")

    # The same Work pair may be an edge in two independent shared graph namespaces.
    other_graph = create_shared_graph(project8)
    scalar(mutate_sql(other_graph, str(uuid4()), [op("add", replay_source, replay_target)]))
    if scalar(
        "SELECT count(*) FROM aep.work_relations "
        f"WHERE source_work_id={lit(replay_source)}::uuid "
        f"AND target_work_id={lit(replay_target)}::uuid "
        "AND relation_type='depends_on' AND status='active';"
    ) != "2":
        raise AssertionError("dependency edge uniqueness leaked across independent graph namespaces")

    # T08 shared graph authorization and READY invalidation after grant changes.
    owner_project = create_project("stage2b-shared-owner")
    read_project = create_project("stage2b-shared-read")
    write_project = create_project("stage2b-shared-write")
    nonmember_project = create_project("stage2b-shared-nonmember")
    shared = create_shared_graph(owner_project)
    read_version = set_member(shared, read_project, "read")
    write_version = set_member(shared, write_project, "write")
    if int(write_version) <= int(read_version):
        raise AssertionError("shared graph version did not increase monotonically on member changes")

    prerequisite = ready_work(read_project, "shared-prerequisite")
    complete_work(prerequisite)
    shared_source = ready_work(write_project, "shared-source")
    scalar(mutate_sql(shared, str(uuid4()), [op("add", shared_source, prerequisite)]))
    if scalar(
        f"SELECT status FROM aep.works WHERE work_id={lit(shared_source)}::uuid;"
    ) != "ready":
        raise AssertionError("authorized, completed cross-project prerequisite did not remain eligible")

    read_only_source = register_work(read_project, "shared-readonly-source")
    owner_target = register_work(owner_project, "shared-owner-target")
    expect_error(
        mutate_sql(shared, str(uuid4()), [op("add", read_only_source, owner_target)]),
        "does not authorize this edge",
        "read-only project cannot write a shared dependency edge",
    )
    outsider_source = register_work(nonmember_project, "shared-outsider-source")
    expect_error(
        mutate_sql(shared, str(uuid4()), [op("add", outsider_source, owner_target)]),
        "actively belong to the graph",
        "non-member project cannot create a shared dependency edge",
    )

    # Revocation marks all mapped Works removed and blocks a previously-ready
    # dependent; a fresh exact OwnerDecision rejoin recomputes READY.
    scalar(
        "SELECT aep.set_dependency_graph_member("
        f"{lit(shared)}::uuid,{lit(read_project)}::uuid,NULL,NULL);"
    )
    state_after_revoke = scalar(
        f"SELECT status || '|' || dependency_blocked::text FROM aep.works "
        f"WHERE work_id={lit(shared_source)}::uuid;"
    )
    if state_after_revoke != "blocked|true":
        raise AssertionError(f"shared grant revocation did not invalidate READY: {state_after_revoke}")
    psql(
        "UPDATE aep.owner_decisions SET status='revoked' "
        "WHERE scope_type='project' AND scope_key=" + lit(read_project) +
        " AND decision_key=" + lit("dependency_graph:"+shared+":read") +
        " AND status='approved';"
    )
    set_member(shared, read_project, "read")
    state_after_rejoin = scalar(
        f"SELECT status || '|' || dependency_blocked::text FROM aep.works "
        f"WHERE work_id={lit(shared_source)}::uuid;"
    )
    if state_after_rejoin != "ready|false":
        raise AssertionError(f"shared membership rejoin did not restore dependency eligibility: {state_after_rejoin}")
    print("PASS T08 shared authorization: approved graph grants gate writes; revoke/rejoin invalidates and restores READY")

    # T09: force the graph-root ordering in both directions. If claim owns SHARE
    # first, a mutator must wait and then reject RUNNING source Work. If mutation
    # owns UPDATE first, claim waits and then rejects the dependency-blocked Work.
    project9 = create_project("stage2b-t09")
    graph9 = graph_for(project9)
    source9 = ready_work(project9, "t09-source")
    prerequisite9 = register_work(project9, "t09-prerequisite")

    claim_first_holder = (
        "SELECT 1 FROM aep.dependency_graphs "
        f"WHERE graph_id={lit(graph9)}::uuid FOR SHARE"
    )
    claim_first_action = (
        "SELECT execution_id FROM aep.claim_work("
        f"{lit(source9)}::uuid,{lit(str(uuid4()))}::uuid,60)"
    )
    mutation_waiter = mutate_sql(graph9, str(uuid4()), [op("add", source9, prerequisite9)])
    holder_result, waiter_result = race_lock_then_waiter(
        graph9, claim_first_holder, claim_first_action, mutation_waiter, "aep.mutate_dependencies"
    )
    if holder_result.returncode != 0 or waiter_result.returncode == 0:
        raise AssertionError(
            f"T09 claim-first ordering failed: holder={holder_result.stderr}, waiter={waiter_result.stderr}"
        )
    if "running or terminal" not in waiter_result.stderr and "unless the source Work is proposed" not in waiter_result.stderr:
        raise AssertionError(f"T09 mutation was not rejected after claim won: {waiter_result.stderr}")
    if scalar(
        f"SELECT status FROM aep.works WHERE work_id={lit(source9)}::uuid;"
    ) != "running" or scalar(
        "SELECT count(*) FROM aep.work_relations "
        f"WHERE source_work_id={lit(source9)}::uuid AND status='active' AND relation_type='depends_on';"
    ) != "0":
        raise AssertionError("T09 claim-first ordering left a running Work with a new prerequisite edge")

    project9b = create_project("stage2b-t09b")
    graph9b = graph_for(project9b)
    source9b = ready_work(project9b, "t09b-source")
    prerequisite9b = register_work(project9b, "t09b-prerequisite")
    mutation_first_holder = (
        "SELECT 1 FROM aep.dependency_graphs "
        f"WHERE graph_id={lit(graph9b)}::uuid FOR UPDATE"
    )
    mutation_first_action = mutate_sql(
        graph9b, str(uuid4()), [op("add", source9b, prerequisite9b)]
    )
    claim_waiter = (
        "SELECT * FROM aep.claim_work("
        f"{lit(source9b)}::uuid,{lit(str(uuid4()))}::uuid,60)"
    )
    holder_result2, waiter_result2 = race_lock_then_waiter(
        graph9b, mutation_first_holder, mutation_first_action, claim_waiter, "aep.claim_work"
    )
    if holder_result2.returncode != 0 or waiter_result2.returncode == 0:
        raise AssertionError(
            f"T09 mutation-first ordering failed: holder={holder_result2.stderr}, waiter={waiter_result2.stderr}"
        )
    state9b = scalar(
        f"SELECT status || '|' || dependency_blocked::text || '|' "
        f"|| (SELECT count(*) FROM aep.executions WHERE work_id={lit(source9b)}::uuid)::text "
        f"FROM aep.works WHERE work_id={lit(source9b)}::uuid;"
    )
    if state9b != "blocked|true|0":
        raise AssertionError(f"T09 mutation-first ordering allowed an invalid claim: {state9b}")
    print("PASS T09: both graph-lock interleavings prevent RUNNING with an unmet prerequisite")

    # T23: required children block parent success; optional children do not.
    project23 = create_project("stage2b-t23")
    parent_required = ready_work(project23, "t23-parent-required")
    required_child = register_work(project23, "t23-required-child")
    psql(
        "INSERT INTO aep.work_relations(source_work_id,target_work_id,relation_type,required) "
        f"VALUES({lit(parent_required)}::uuid,{lit(required_child)}::uuid,'parent_child',true);"
    )
    parent_claim = claim(parent_required)
    parent_execution, _, parent_fence, parent_version = parent_claim
    expect_error(
        "SELECT * FROM aep.finish_execution("
        f"{lit(parent_required)}::uuid,{lit(parent_execution)}::uuid,{parent_fence},{parent_version},"
        "'succeeded','{}'::jsonb);",
        "unfinished required child",
        "T23 parent completion with unfinished required child",
    )
    if scalar(
        f"SELECT status FROM aep.works WHERE work_id={lit(parent_required)}::uuid;"
    ) != "running":
        raise AssertionError("failed required-child finish did not preserve the live parent execution")
    child_ready = scalar(
        f"SELECT work_status FROM aep.set_work_ready({lit(required_child)}::uuid);"
    )
    if child_ready != "ready":
        raise AssertionError(f"required child did not become READY: {child_ready}")
    complete_work(required_child)
    if finish_success(parent_required, parent_claim) != "delivered":
        raise AssertionError("parent could not finish after its required child succeeded")

    parent_optional = ready_work(project23, "t23-parent-optional")
    optional_child = register_work(project23, "t23-optional-child")
    psql(
        "INSERT INTO aep.work_relations(source_work_id,target_work_id,relation_type,required) "
        f"VALUES({lit(parent_optional)}::uuid,{lit(optional_child)}::uuid,'parent_child',false);"
    )
    complete_work(parent_optional)
    if scalar(
        f"SELECT status FROM aep.works WHERE work_id={lit(optional_child)}::uuid;"
    ) != "proposed":
        raise AssertionError("optional child was unexpectedly advanced with its parent")
    print("PASS T23: required children gate parent success; optional children do not")

    # Direct runtime access remains RPC-only for the new graph tables.
    runtime = scalar("""
      SELECT
        has_function_privilege('aep_runtime','aep.create_dependency_graph(uuid)','EXECUTE')::text
        || '|' || has_function_privilege('aep_runtime','aep.set_dependency_graph_member(uuid,uuid,text,uuid)','EXECUTE')::text
        || '|' || has_function_privilege('aep_runtime','aep.mutate_dependencies(uuid,text,jsonb)','EXECUTE')::text
        || '|' || has_function_privilege('aep_runtime','aep.set_work_ready(uuid)','EXECUTE')::text
        || '|' || has_table_privilege('aep_runtime','aep.dependency_graph_works','SELECT')::text
        || '|' || has_table_privilege('aep_runtime','aep.dependency_graph_operations','SELECT')::text;
    """)
    if runtime != "true|true|true|true|false|false":
        raise AssertionError(f"Stage2B runtime grants are not RPC-only: {runtime}")
    print("PASS Stage 2B runtime grants: graph RPCs executable; internal graph tables inaccessible")

    print("PASS Stage 2B PostgreSQL 17.12 protocol suite: T07, T08, T09 and T23")


if __name__ == "__main__":
    main()
