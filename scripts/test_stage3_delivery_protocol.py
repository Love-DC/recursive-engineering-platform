#!/usr/bin/env python3
"""Stage 3 delivery protocol tests using disposable PostgreSQL 17.12 and a faultable provider fake."""

from __future__ import annotations

import json
import os
import re
import subprocess
from pathlib import Path
import sys
from uuid import uuid4

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from aep_delivery.adapter import FakeGitHubProvider, GitHubCapabilityManifest, LostProviderResponse

MIGRATIONS = ROOT / "db" / "prototype"
DATABASE = "aep_stage3_test"
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


def manifest_registration_sql(resource_id: str, manifest: dict) -> str:
    return (
        "SELECT aep.register_delivery_adapter_manifest("
        f"{lit(resource_id)}::uuid,{json_sql(manifest)},NULL);"
    )


def evidence_rpc_sql(
    execution_id: str, kind: str, sha: str, source: str,
    actor: str | None, payload: dict,
) -> str:
    actor_sql = "NULL" if actor is None else lit(actor)
    return (
        "SELECT aep.record_delivery_evidence("
        f"{lit(execution_id)}::uuid,{lit(kind)},{lit(sha)},{lit(source)},"
        f"{actor_sql},{json_sql(payload)});"
    )


def test_manifest_sql_validation(resource_id: str, manifest: dict) -> None:
    malformed = json.loads(json.dumps(manifest))
    malformed.pop("schema_version")
    expect_error(
        manifest_registration_sql(resource_id, malformed),
        "schema_version must be numeric 1",
        "SQL RPC rejects missing manifest schema version",
    )

    malformed = json.loads(json.dumps(manifest))
    malformed["schema_version"] = "1"
    expect_error(
        manifest_registration_sql(resource_id, malformed),
        "schema_version must be numeric 1",
        "SQL RPC rejects non-numeric manifest schema version",
    )

    malformed = json.loads(json.dumps(manifest))
    malformed["schema_version"] = None
    expect_error(
        manifest_registration_sql(resource_id, malformed),
        "schema_version must be numeric 1",
        "SQL RPC rejects JSON-null manifest schema version",
    )

    status_mutations = (
        ("missing", lambda capability: capability.pop("status")),
        ("JSON null", lambda capability: capability.update(status=None)),
        ("non-string", lambda capability: capability.update(status=7)),
        ("unsupported", lambda capability: capability.update(status="unknown")),
    )
    for label, mutate in status_mutations:
        malformed = json.loads(json.dumps(manifest))
        mutate(malformed["operations"]["ci_lookup"])
        expect_error(
            manifest_registration_sql(resource_id, malformed),
            "Invalid capability status",
            f"SQL RPC rejects {label} capability status",
        )

    malformed = json.loads(json.dumps(manifest))
    malformed["operations"]["ci_lookup"] = "supported"
    expect_error(
        manifest_registration_sql(resource_id, malformed),
        "Capability ci_lookup must be an object",
        "SQL RPC rejects a non-object capability",
    )
    print("PASS Stage 3 SQL manifest RPC: numeric schema version and capability shape/status fail closed")


def expect_missing_capability_status(
    resource_id: str, manifest: dict, capability: str,
    execution_id: str, kind: str, sha: str, source: str,
    actor: str | None, payload: dict, error: str,
) -> None:
    path = "{operations," + capability + "}"
    psql(
        "UPDATE aep.delivery_adapter_manifests "
        "SET manifest = jsonb_set(manifest,"
        f"{lit(path)},{'(manifest #> ' + lit(path) + ') - ' + lit('status')}) "
        f"WHERE resource_id={lit(resource_id)}::uuid;"
    )
    expect_error(
        evidence_rpc_sql(execution_id, kind, sha, source, actor, payload),
        error,
        f"SQL RPC rejects missing {capability} capability status",
    )
    psql(
        "UPDATE aep.delivery_adapter_manifests "
        f"SET manifest={json_sql(manifest)} "
        f"WHERE resource_id={lit(resource_id)}::uuid;"
    )


def setup_database() -> list[Path]:
    # This regression includes its additive hardening migration at 0013, so
    # apply the complete ordered prototype chain through that migration.
    paths = sorted(path for path in MIGRATIONS.glob("*.sql") if path.name[:4] <= "0013")
    versions: list[int] = []
    for path in paths:
        match = re.fullmatch(r"(\d{4})_[a-z0-9_]+\.sql", path.name)
        if not match:
            raise SystemExit(f"Invalid migration filename: {path.name}")
        versions.append(int(match.group(1)))
    if versions != list(range(1, 14)):
        raise SystemExit(f"Expected contiguous migrations 0001..0013, got {versions}")

    psql(f"DROP DATABASE IF EXISTS {DATABASE} WITH (FORCE);", db="postgres")
    psql(f"CREATE DATABASE {DATABASE};", db="postgres")
    version = scalar("SELECT current_setting('server_version');")
    if not version.startswith("17.12"):
        raise AssertionError(f"Stage 3 requires PostgreSQL 17.12; got {version}")
    for path in paths:
        psql(file=path)
    print("PASS T26: clean additive migration chain 0001-0013 on PostgreSQL 17.12")
    return paths


def setup_repository_target(manifest: dict) -> tuple[str, str, str, str]:
    project_id = scalar(
        "INSERT INTO aep.projects(project_key,name) "
        "VALUES('stage3-delivery-project','Stage 3 delivery project') RETURNING project_id;"
    )
    resource_id = str(uuid4())
    repository_id = "1471589776"
    psql(
        "INSERT INTO aep.resources(resource_id,provider,host,resource_type,"
        "stable_resource_id,canonical_key,display_name) VALUES("
        f"{lit(resource_id)}::uuid,'github','github.com','repository',"
        f"{lit(repository_id)},{lit('repository:'+repository_id)},'AEP Stage 3 test target');"
    )
    decision_id = scalar(
        "INSERT INTO aep.owner_decisions("
        "scope_type,scope_key,decision_key,statement,decision_version,status,"
        "approval_source_kind,approval_source_ref,approver_principal,"
        "approval_provenance,approved_at"
        ") VALUES("
        f"'project',{lit(project_id)},'stage3-write-target','Stage 3 isolated prototype write grant',"
        "1,'approved','direct_owner_message','test://owner/stage3-write','test-owner',"
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
    test_manifest_sql_validation(resource_id, manifest)
    psql(manifest_registration_sql(resource_id, manifest))
    return project_id, resource_id, repository_id, "Love-DC/recursive-engineering-platform"


def create_running_work(
    project_id: str, identity: str, resource_id: str | None = None,
    resource_ref: str = "refs/heads/main",
) -> tuple[str, str, int]:
    work_id = scalar(
        "SELECT work_id::text FROM aep.register_work("
        f"{lit(project_id)}::uuid,{lit(str(uuid4()))},{lit(str(uuid4()))}::uuid,"
        f"'stage3',{lit(identity)},1,'implementation',{lit(identity)},'{{}}'::jsonb,NULL);"
    )
    if resource_id is not None:
        psql(
            "SELECT aep.set_work_resource_requirements("
            f"{lit(work_id)}::uuid,jsonb_build_array(jsonb_build_object("
            f"'resource_id',{lit(resource_id)}::uuid,'resource_ref',{lit(resource_ref)})));"
        )
    status = scalar(f"SELECT work_status FROM aep.set_work_ready({lit(work_id)}::uuid);")
    if status != "ready":
        raise AssertionError(f"Work did not become READY: {status}")
    claim = scalar(
        "SELECT execution_id::text || '|' || fence::text "
        "FROM aep.claim_work("
        f"{lit(work_id)}::uuid,{lit(str(uuid4()))}::uuid,3600);"
    )
    execution_id, fence = claim.split("|")
    return work_id, execution_id, int(fence)


def takeover(work_id: str, execution_id: str) -> tuple[str, int]:
    psql(
        "UPDATE aep.executions SET lease_until=clock_timestamp()-interval '1 second' "
        f"WHERE execution_id={lit(execution_id)}::uuid;"
    )
    claim = scalar(
        "SELECT execution_id::text || '|' || fence::text "
        "FROM aep.claim_work("
        f"{lit(work_id)}::uuid,{lit(str(uuid4()))}::uuid,3600);"
    )
    next_execution_id, fence = claim.split("|")
    return next_execution_id, int(fence)


def allocate_sql(
    work_id: str, execution_id: str, fence: int, resource_id: str,
    repository_id: str, repository_full_name: str,
    base_ref: str = "refs/heads/main",
) -> str:
    return (
        "SELECT aep.allocate_execution_delivery("
        f"{lit(work_id)}::uuid,{lit(execution_id)}::uuid,{fence},"
        f"{lit(resource_id)}::uuid,'github.com',{lit(repository_id)},"
        f"{lit(repository_full_name)},{lit(base_ref)},{lit('a'*40)});"
    )


def allocate(
    work_id: str, execution_id: str, fence: int, resource_id: str,
    repository_id: str, repository_full_name: str,
    base_ref: str = "refs/heads/main",
) -> str:
    return json.loads(scalar(allocate_sql(
        work_id, execution_id, fence, resource_id, repository_id,
        repository_full_name, base_ref
    )))["delivery_branch"]


def release_resource_claims(execution_id: str) -> None:
    psql(
        "UPDATE aep.resource_claims SET status='released', lease_until=NULL, "
        "released_at=clock_timestamp() "
        f"WHERE execution_id={lit(execution_id)}::uuid AND status IN ('reserved','active');"
    )


def finish_work(work_id: str, execution_id: str, fence: int) -> None:
    version = scalar(
        f"SELECT version::text FROM aep.works WHERE work_id={lit(work_id)}::uuid;"
    )
    result = scalar(
        "SELECT work_status FROM aep.finish_execution("
        f"{lit(work_id)}::uuid,{lit(execution_id)}::uuid,{fence},"
        f"{version},'succeeded','{{}}'::jsonb);"
    )
    if result != "delivered":
        raise AssertionError(f"Execution did not finish as delivered: {result}")


def create_intent(
    work_id: str, execution_id: str, fence: int, key: str, operation_type: str,
    resource_id: str, repository_id: str, target_ref: str, payload: dict,
) -> str:
    return scalar(
        "SELECT aep.create_external_operation_intent("
        f"{lit(work_id)}::uuid,{lit(execution_id)}::uuid,{fence},"
        f"{lit(key)},{lit(operation_type)},{lit(resource_id)}::uuid,"
        f"'github.com',{lit(repository_id)},{lit(target_ref)},{json_sql(payload)});"
    )


def record_receipt(receipt_id: str, response: dict) -> None:
    psql(
        "SELECT aep.record_external_operation_receipt("
        f"{lit(receipt_id)}::uuid,{lit(response['external_object_type'])},"
        f"{lit(response['external_id'])},{lit(response['revision'])},{json_sql(response)});"
    )


def reconcile(receipt_id: str, observation: dict) -> dict:
    result = scalar(
        "SELECT aep.reconcile_external_operation("
        f"{lit(receipt_id)}::uuid,{json_sql(observation)});"
    )
    return json.loads(result)


def record_evidence(
    execution_id: str, kind: str, sha: str, source: str,
    actor: str | None, payload: dict,
) -> str:
    return scalar(evidence_rpc_sql(execution_id, kind, sha, source, actor, payload))


def create_branch_provider_operation(
    provider: FakeGitHubProvider, work_id: str, execution_id: str, fence: int,
    resource_id: str, repository_id: str, branch: str,
) -> None:
    key = "branch:" + execution_id
    payload = {"branch": branch, "base_sha": "a" * 40}
    receipt_id = create_intent(
        work_id, execution_id, fence, key, "branch_ref_create",
        resource_id, repository_id, branch, payload
    )
    response = provider.execute(key, "branch_ref_create", payload)
    record_receipt(receipt_id, response)
    result = reconcile(receipt_id, provider.observe(key))
    if result["status"] != "reconciled":
        raise AssertionError(f"branch-ref operation was not reconciled: {result}")


def create_pr_provider_operation(
    provider: FakeGitHubProvider, work_id: str, execution_id: str, fence: int,
    resource_id: str, repository_id: str, branch: str, *, lose_response: bool,
) -> tuple[str, dict]:
    key = "pr:" + execution_id
    payload = {"head": branch, "base": "main", "title": "Stage 3 attempt " + execution_id}
    receipt_id = create_intent(
        work_id, execution_id, fence, key, "pull_request_create",
        resource_id, repository_id, branch, payload
    )
    if lose_response:
        provider.lose_next_response = True
        try:
            provider.execute(key, "pull_request_create", payload)
        except LostProviderResponse:
            pass
        else:
            raise AssertionError("fake provider did not inject the requested lost response")
        psql(
            "SELECT aep.mark_external_operation_uncertain("
            f"{lit(receipt_id)}::uuid,'connection dropped after provider side effect');"
        )
        observation = provider.observe(key)
        if not observation.get("found"):
            raise AssertionError("provider lookup did not recover the already-created PR")
        result = reconcile(receipt_id, observation)
    else:
        response = provider.execute(key, "pull_request_create", payload)
        record_receipt(receipt_id, response)
        result = reconcile(receipt_id, provider.observe(key))
    if result["status"] != "reconciled":
        raise AssertionError(f"PR create operation was not reconciled: {result}")
    return receipt_id, provider.observe(key)


def test_manifest_contract(manifest: dict) -> None:
    contract = GitHubCapabilityManifest(manifest)
    for name in GitHubCapabilityManifest.REQUIRED:
        contract.capability(name) if manifest["operations"][name]["status"] == "supported" else None
    if manifest["operations"]["deployment"]["status"] != "unsupported":
        raise AssertionError("T22 deployment must remain explicitly unsupported")
    if manifest["operations"]["native_approval"]["status"] != "supported":
        raise AssertionError("native GitHub APPROVE tool surface is available and must be declared")
    if manifest["operations"]["native_approval"]["independent_principal"] != "unavailable":
        raise AssertionError("the connected account cannot represent a separate native approver")
    if manifest["operations"]["process_review"]["identity"] != "same_authenticated_principal":
        raise AssertionError("process review must disclose the shared principal")
    try:
        contract.require("deployment")
    except Exception as exc:
        if "unsupported" not in str(exc):
            raise
    else:
        raise AssertionError("adapter must refuse deployment")

    temporarily_unavailable = json.loads(json.dumps(manifest))
    temporarily_unavailable["operations"]["branch_ref"]["status"] = "unavailable"
    unavailable_contract = GitHubCapabilityManifest(temporarily_unavailable)
    try:
        unavailable_contract.require("branch_ref")
    except Exception as exc:
        if "unavailable" not in str(exc):
            raise
    else:
        raise AssertionError("adapter must distinguish temporary unavailability from support")

    malformed = json.loads(json.dumps(manifest))
    malformed["operations"]["native_approval"]["independent_principal"] = "supported"
    try:
        GitHubCapabilityManifest(malformed)
    except ValueError:
        pass
    else:
        raise AssertionError("manifest must reject claims of an independent approver principal")
    print("PASS T22: supported, unsupported, unavailable, and single-principal limitations are explicit")


def create_secondary_repository_resource(project_id: str, primary_resource_id: str) -> tuple[str, str, str]:
    repository_id = "999990001"
    grant_decision_id = scalar(
        "SELECT grant_decision_id::text FROM aep.project_resources "
        f"WHERE project_id={lit(project_id)}::uuid "
        f"AND resource_id={lit(primary_resource_id)}::uuid;"
    )
    resource_id = scalar(
        "INSERT INTO aep.resources(provider,host,resource_type,stable_resource_id,canonical_key,display_name) "
        f"VALUES('github','github.com','repository',{lit(repository_id)},"
        f"{lit('repository:'+repository_id)},'Unclaimed test target') RETURNING resource_id;"
    )
    psql(
        "INSERT INTO aep.project_resources("
        "project_id,resource_id,access_mode,status,grant_version,grant_decision_id) VALUES("
        f"{lit(project_id)}::uuid,{lit(resource_id)}::uuid,'write','active',1,"
        f"{lit(grant_decision_id)}::uuid);"
    )
    return resource_id, repository_id, "Love-DC/unclaimed-test-target"


def test_delivery_requires_resource_claim(
    project_id: str, resource_id: str, repository_id: str, repository_full_name: str,
) -> None:
    # A project write grant alone must not authorize allocation without a
    # Work-declared repository/ref requirement.
    work, execution, fence = create_running_work(
        project_id, "t-claim-guard-no-requirement"
    )
    expect_error(
        allocate_sql(work, execution, fence, resource_id, repository_id, repository_full_name),
        "matching Work ResourceRequirement",
        "delivery allocation rejects a Work with no ResourceRequirement",
    )

    # A requirement for a different branch ref cannot authorize main.
    work, execution, fence = create_running_work(
        project_id, "t-claim-guard-wrong-ref", resource_id, "refs/heads/develop"
    )
    expect_error(
        allocate_sql(work, execution, fence, resource_id, repository_id, repository_full_name),
        "matching Work ResourceRequirement",
        "delivery allocation rejects a mismatched repository ref",
    )
    release_resource_claims(execution)

    # An active execution without its still-live exact claim must fail closed.
    work, execution, fence = create_running_work(
        project_id, "t-claim-guard-missing-claim", resource_id
    )
    release_resource_claims(execution)
    expect_error(
        allocate_sql(work, execution, fence, resource_id, repository_id, repository_full_name),
        "reservation set is incomplete",
        "delivery allocation rejects a missing ResourceClaim",
    )

    # Expired leases are not usable even when the claim row still says active.
    work, execution, fence = create_running_work(
        project_id, "t-claim-guard-expired-claim", resource_id
    )
    psql(
        "UPDATE aep.resource_claims SET lease_until=clock_timestamp()-interval '1 second' "
        f"WHERE execution_id={lit(execution)}::uuid AND status='active';"
    )
    expect_error(
        allocate_sql(work, execution, fence, resource_id, repository_id, repository_full_name),
        "reservation set is incomplete",
        "delivery allocation rejects an expired ResourceClaim",
    )
    release_resource_claims(execution)

    # A claim with a fence other than the current Execution fence is stale.
    work, execution, fence = create_running_work(
        project_id, "t-claim-guard-stale-fence", resource_id
    )
    psql(
        f"UPDATE aep.resource_claims SET fence={fence + 1} "
        f"WHERE execution_id={lit(execution)}::uuid AND status='active';"
    )
    expect_error(
        allocate_sql(work, execution, fence, resource_id, repository_id, repository_full_name),
        "reservation set is incomplete",
        "delivery allocation rejects a stale-fence ResourceClaim",
    )
    release_resource_claims(execution)

    # A claim redirected to another authorized physical repository must not
    # satisfy the original repository requirement, even when the Work remains
    # fenced and the redirected Resource is granted to the same Project.
    other_id, _, _ = create_secondary_repository_resource(project_id, resource_id)
    work, execution, fence = create_running_work(
        project_id, "t-claim-guard-wrong-resource-claim", resource_id
    )
    psql(
        "UPDATE aep.resource_claims SET resource_id="
        f"{lit(other_id)}::uuid WHERE execution_id={lit(execution)}::uuid "
        f"AND resource_id={lit(resource_id)}::uuid AND status='active';"
    )
    expect_error(
        allocate_sql(work, execution, fence, resource_id, repository_id, repository_full_name),
        "reservation set is incomplete",
        "delivery allocation rejects a ResourceClaim redirected to another repository",
    )
    release_resource_claims(execution)

    print("PASS T27: delivery allocation requires a Work requirement and a complete current fenced ResourceClaim set")


def test_execution_delivery_and_lost_response(
    project_id: str, resource_id: str, repository_id: str, repository_full_name: str,
    provider: FakeGitHubProvider,
) -> tuple[str, str, int, str, str, dict]:
    work_id, execution_a, fence_a = create_running_work(
        project_id, "t12-independent-attempts", resource_id
    )
    branch_a = allocate(
        work_id, execution_a, fence_a, resource_id, repository_id, repository_full_name
    )
    if branch_a != f"work/{work_id}/execution/{execution_a}":
        raise AssertionError(f"T12 branch identity is not execution-scoped: {branch_a}")
    if allocate(
        work_id, execution_a, fence_a, resource_id, repository_id, repository_full_name
    ) != branch_a:
        raise AssertionError("same execution did not replay its own delivery identity")
    create_branch_provider_operation(
        provider, work_id, execution_a, fence_a, resource_id, repository_id, branch_a
    )
    _, pr_a = create_pr_provider_operation(
        provider, work_id, execution_a, fence_a, resource_id, repository_id,
        branch_a, lose_response=False
    )

    execution_b, fence_b = takeover(work_id, execution_a)
    if execution_b == execution_a or fence_b <= fence_a:
        raise AssertionError("T12 takeover did not allocate a new execution and higher fence")
    branch_b = allocate(
        work_id, execution_b, fence_b, resource_id, repository_id, repository_full_name
    )
    if branch_a == branch_b or not branch_b.endswith("/execution/" + execution_b):
        raise AssertionError("T12 retry/takeover reused the prior execution delivery ref")
    create_branch_provider_operation(
        provider, work_id, execution_b, fence_b, resource_id, repository_id, branch_b
    )
    receipt_b, pr_b = create_pr_provider_operation(
        provider, work_id, execution_b, fence_b, resource_id, repository_id,
        branch_b, lose_response=True
    )
    if pr_a["pull_request_number"] == pr_b["pull_request_number"]:
        raise AssertionError("T12 separate executions reused one PR identity")

    key_b = "pr:" + execution_b
    payload_b = {"head": branch_b, "base": "main", "title": "Stage 3 attempt " + execution_b}
    replay = create_intent(
        work_id, execution_b, fence_b, key_b, "pull_request_create",
        resource_id, repository_id, branch_b, payload_b
    )
    if replay != receipt_b:
        raise AssertionError("T21 same key/same payload did not replay the reconciled receipt")
    expect_error(
        "SELECT aep.create_external_operation_intent("
        f"{lit(work_id)}::uuid,{lit(execution_b)}::uuid,{fence_b},"
        f"{lit(key_b)},'pull_request_create',{lit(resource_id)}::uuid,"
        f"'github.com',{lit(repository_id)},{lit(branch_b)},"
        f"{json_sql({'head': branch_b, 'base': 'develop'})});",
        "different payload",
        "T21 same-key different-payload conflict",
    )
    if provider.calls.get(key_b) != 1:
        raise AssertionError(f"T21 response-loss recovery created duplicate provider side effects: {provider.calls}")
    if scalar(
        "SELECT status || '|' || reconciliation_status FROM aep.operation_receipts "
        f"WHERE operation_receipt_id={lit(receipt_b)}::uuid;"
    ) != "reconciled|reconciled":
        raise AssertionError("T21 receipt was not durably reconciled")

    print("PASS T12: each Execution owns an independent branch and PR identity")
    print("PASS T21: lost PR response is recovered by provider lookup without duplicate side effect")
    return work_id, execution_b, fence_b, branch_b, pr_b["pr_head_sha"], pr_b


def test_exact_sha_lifecycle(
    work_id: str, execution_id: str, fence: int, branch: str, pr_observation: dict,
    resource_id: str, repository_id: str, provider: FakeGitHubProvider, manifest: dict,
) -> None:
    pr_sha = pr_observation["pr_head_sha"]
    pr_number = pr_observation["pull_request_number"]
    expect_error(
        "SELECT aep.record_delivery_evidence("
        f"{lit(execution_id)}::uuid,'ci',{lit('0'*40)},'github://ci/wrong-sha',NULL,"
        f"{json_sql({'tested_sha':'0'*40,'conclusion':'success'})});",
        "current exact pr head",
        "T15 CI exact-SHA mismatch",
    )
    expect_missing_capability_status(
        resource_id, manifest, "ci_lookup", execution_id, "ci", pr_sha,
        "github://ci/missing-capability", None,
        {"tested_sha": pr_sha, "conclusion": "success"},
        "CI lookup is not supported",
    )
    expect_error(
        evidence_rpc_sql(
            execution_id, "ci", pr_sha, "github://ci/missing-tested-sha", None,
            {"conclusion": "success"},
        ),
        "exact tested SHA and conclusion",
        "SQL RPC rejects CI evidence missing tested_sha",
    )
    expect_error(
        evidence_rpc_sql(
            execution_id, "ci", pr_sha, "github://ci/missing-conclusion", None,
            {"tested_sha": pr_sha},
        ),
        "exact tested SHA and conclusion",
        "SQL RPC rejects CI evidence missing conclusion",
    )
    record_evidence(
        execution_id, "ci", pr_sha, "github://actions/pr-head", None,
        {"tested_sha": pr_sha, "conclusion": "success", "run_id": 501}
    )

    expect_missing_capability_status(
        resource_id, manifest, "process_review", execution_id, "process_review", pr_sha,
        "github://review/missing-capability", "Love-DC",
        {"github_review_state": "COMMENTED"},
        "Process Review requires",
    )
    expect_error(
        evidence_rpc_sql(
            execution_id, "process_review", pr_sha, "github://review/missing-state",
            "Love-DC", {"review_id": 604},
        ),
        "Process Review requires",
        "SQL RPC rejects Process Review missing github_review_state",
    )
    record_evidence(
        execution_id, "process_review", pr_sha, "github://review/commented",
        "Love-DC", {"github_review_state": "COMMENTED", "review_id": 601}
    )
    expect_missing_capability_status(
        resource_id, manifest, "native_approval", execution_id, "native_approval", pr_sha,
        "github://approval/missing-capability", "Love-DC",
        {"github_review_state": "APPROVED", "native_event": True},
        "Native Approval requires",
    )
    expect_error(
        evidence_rpc_sql(
            execution_id, "native_approval", pr_sha, "github://approval/missing-state",
            "Love-DC", {"native_event": True},
        ),
        "Native Approval requires",
        "SQL RPC rejects Native Approval missing github_review_state",
    )
    expect_error(
        evidence_rpc_sql(
            execution_id, "native_approval", pr_sha, "github://approval/missing-event",
            "Love-DC", {"github_review_state": "APPROVED"},
        ),
        "Native Approval requires",
        "SQL RPC rejects Native Approval missing native_event",
    )
    expect_error(
        evidence_rpc_sql(
            execution_id, "native_approval", pr_sha, "github://review/commented",
            "Love-DC", {"github_review_state": "COMMENTED", "native_event": True},
        ),
        "Native Approval requires",
        "T14 Process Review cannot satisfy Native Approval",
    )
    record_evidence(
        execution_id, "native_approval", pr_sha, "github://review/approved",
        "Love-DC", {"github_review_state": "APPROVED", "native_event": True, "review_id": 602}
    )

    next_sha = "b" * 40
    psql(
        "SELECT aep.record_delivery_pr_state("
        f"{lit(execution_id)}::uuid,{pr_number},"
        f"{lit(pr_observation['pull_request_url'])},{lit(next_sha)},"
        "'github://pull-request/head-updated');"
    )
    invalidated = scalar(
        "SELECT count(*) FROM aep.execution_delivery_evidence_current "
        f"WHERE execution_id={lit(execution_id)}::uuid AND subject_sha={lit(pr_sha)} "
        "AND evidence_kind IN ('ci','process_review','native_approval') AND NOT is_valid;"
    )
    if invalidated != "3":
        raise AssertionError(f"PR HEAD movement did not invalidate all affected exact-SHA evidence: {invalidated}")
    record_evidence(
        execution_id, "ci", next_sha, "github://actions/new-head", None,
        {"tested_sha": next_sha, "conclusion": "success", "run_id": 502}
    )
    record_evidence(
        execution_id, "process_review", next_sha, "github://review/new-head",
        "Love-DC", {"github_review_state": "COMMENTED", "review_id": 603}
    )

    merge_key = "merge:" + execution_id
    merge_payload = {"pull_request_number": pr_number, "expected_head_sha": next_sha}
    receipt_id = create_intent(
        work_id, execution_id, fence, merge_key, "merge", resource_id,
        repository_id, str(pr_number), merge_payload
    )
    merge_response = provider.execute(merge_key, "merge", merge_payload)
    record_receipt(receipt_id, merge_response)
    merged = reconcile(receipt_id, provider.observe(merge_key))
    if merged["status"] != "reconciled" or merged["stale"]:
        raise AssertionError(f"T15 current merge did not reconcile cleanly: {merged}")
    merge_sha = merged["merge_sha"]

    expect_error(
        "SELECT aep.record_delivery_evidence("
        f"{lit(execution_id)}::uuid,'post_merge_ci',{lit(next_sha)},"
        "'github://actions/wrong-merge-sha',NULL,"
        f"{json_sql({'tested_sha':next_sha,'conclusion':'success'})});",
        "exact merge sha",
        "T15 post-merge CI must target merge SHA",
    )
    expect_missing_capability_status(
        resource_id, manifest, "post_merge_verification", execution_id, "post_merge_ci",
        merge_sha, "github://post-merge-ci/missing-capability", None,
        {"tested_sha": merge_sha, "conclusion": "success"},
        "Post-merge verification is not supported",
    )
    expect_error(
        evidence_rpc_sql(
            execution_id, "post_merge_ci", merge_sha,
            "github://post-merge-ci/missing-tested-sha", None,
            {"conclusion": "success"},
        ),
        "exact tested SHA and conclusion",
        "SQL RPC rejects post-merge CI missing tested_sha",
    )
    expect_error(
        evidence_rpc_sql(
            execution_id, "post_merge_ci", merge_sha,
            "github://post-merge-ci/missing-conclusion", None,
            {"tested_sha": merge_sha},
        ),
        "exact tested SHA and conclusion",
        "SQL RPC rejects post-merge CI missing conclusion",
    )
    record_evidence(
        execution_id, "post_merge_ci", merge_sha, "github://actions/merge-sha", None,
        {"tested_sha": merge_sha, "conclusion": "success", "run_id": 503}
    )

    deployment_key = "deployment:" + execution_id
    expect_error(
        "SELECT aep.create_external_operation_intent("
        f"{lit(work_id)}::uuid,{lit(execution_id)}::uuid,{fence},"
        f"{lit(deployment_key)},'deployment',{lit(resource_id)}::uuid,"
        f"'github.com',{lit(repository_id)},{lit(merge_sha)},'{{}}'::jsonb);",
        "unsupported",
        "T15/T22 unsupported deployment operation",
    )
    expect_missing_capability_status(
        resource_id, manifest, "deployment", execution_id, "deployment", merge_sha,
        "github://deployment/missing-capability", None, {},
        "Deployment is unsupported",
    )
    expect_error(
        "SELECT aep.record_delivery_evidence("
        f"{lit(execution_id)}::uuid,'deployment',{lit(merge_sha)},"
        "'github://deployment/none',NULL,'{}'::jsonb);",
        "deployment is unsupported",
        "T15 deployment evidence cannot be fabricated",
    )
    expect_error(
        evidence_rpc_sql(
            execution_id, "owner_acceptance", merge_sha,
            "owner://acceptance/missing-confirmation", "Love-DC",
            {"decision_ref": "test-only"},
        ),
        "Owner acceptance requires direct confirmation",
        "SQL RPC rejects Owner Acceptance missing direct_owner_confirmation",
    )
    record_evidence(
        execution_id, "owner_acceptance", merge_sha, "owner://acceptance/stage3-test",
        "Love-DC", {"direct_owner_confirmation": True, "decision_ref": "test-only"}
    )

    kinds = scalar(
        "SELECT string_agg(DISTINCT evidence_kind, ',' ORDER BY evidence_kind) "
        "FROM aep.execution_delivery_evidence_current "
        f"WHERE execution_id={lit(execution_id)}::uuid AND is_valid;"
    )
    required = {"ci", "process_review", "merge", "post_merge_ci", "owner_acceptance"}
    if not required.issubset(set(kinds.split(","))):
        raise AssertionError(f"T15 lifecycle facts were not kept distinct: {kinds}")
    if "deployment" in kinds:
        raise AssertionError("Unsupported deployment appeared as lifecycle evidence")
    print("PASS T14: COMMENTED process review and native GitHub APPROVED evidence are distinct")
    print("PASS T15: PR HEAD CI, merge SHA, post-merge CI, deployment boundary, and Owner acceptance are distinct")
    finish_work(work_id, execution_id, fence)


def test_stale_external_merge(
    project_id: str, resource_id: str, repository_id: str, repository_full_name: str,
    provider: FakeGitHubProvider,
) -> None:
    work_id, execution_old, fence_old = create_running_work(
        project_id, "t13-stale-merge", resource_id
    )
    branch = allocate(
        work_id, execution_old, fence_old, resource_id, repository_id, repository_full_name
    )
    pr_sha = "c" * 40
    pr_number = 880
    pr_url = "https://github.com/Love-DC/recursive-engineering-platform/pull/880"
    psql(
        "SELECT aep.record_delivery_pr_state("
        f"{lit(execution_old)}::uuid,{pr_number},{lit(pr_url)},{lit(pr_sha)},"
        "'github://test/pr-head');"
    )
    record_evidence(
        execution_old, "ci", pr_sha, "github://test/ci", None,
        {"tested_sha": pr_sha, "conclusion": "success", "run_id": 880}
    )
    record_evidence(
        execution_old, "process_review", pr_sha, "github://test/review",
        "Love-DC", {"github_review_state": "COMMENTED", "review_id": 880}
    )
    record_evidence(
        execution_old, "native_approval", pr_sha, "github://test/approval",
        "Love-DC", {"github_review_state": "APPROVED", "native_event": True, "review_id": 881}
    )

    key = "stale-merge:" + execution_old
    payload = {"pull_request_number": pr_number, "expected_head_sha": pr_sha}
    receipt_id = create_intent(
        work_id, execution_old, fence_old, key, "merge",
        resource_id, repository_id, str(pr_number), payload
    )
    provider.lose_next_response = True
    try:
        provider.execute(key, "merge", payload)
    except LostProviderResponse:
        pass
    else:
        raise AssertionError("stale merge fake did not lose its response")
    psql(
        "SELECT aep.mark_external_operation_uncertain("
        f"{lit(receipt_id)}::uuid,'merge succeeded externally but response was lost');"
    )

    execution_new, fence_new = takeover(work_id, execution_old)
    if execution_new == execution_old or fence_new <= fence_old:
        raise AssertionError("T13 stale merge setup did not create a newer fenced execution")
    observation = provider.observe(key)
    result = reconcile(receipt_id, observation)
    if result["status"] != "reconciled" or not result["stale"]:
        raise AssertionError(f"T13 stale merge was not recorded and marked stale: {result}")

    state = scalar(
        "SELECT stale_execution_detected::text || '|' || reconciliation_status "
        "FROM aep.operation_receipts "
        f"WHERE operation_receipt_id={lit(receipt_id)}::uuid;"
    )
    if state != "true|reconciled":
        raise AssertionError(f"T13 stale external receipt did not preserve actual side effect: {state}")
    delivery_state = scalar(
        "SELECT stale_external_side_effect::text || '|' || merge_sha "
        "FROM aep.execution_deliveries WHERE execution_id=" + lit(execution_old) + "::uuid;"
    )
    if delivery_state != "true|" + observation["merge_sha"]:
        raise AssertionError(f"T13 actual merge SHA was not recorded: {delivery_state}")
    invalidated = scalar(
        "SELECT count(*) FROM aep.execution_delivery_evidence_current "
        f"WHERE execution_id={lit(execution_old)}::uuid "
        "AND evidence_kind IN ('ci','process_review','native_approval') AND NOT is_valid;"
    )
    if invalidated != "3":
        raise AssertionError(f"T13 stale merge did not invalidate only its old evidence: {invalidated}")
    work_state = scalar(
        "SELECT status || '|' || current_execution_id::text || '|' || fence_generation::text "
        f"FROM aep.works WHERE work_id={lit(work_id)}::uuid;"
    )
    if work_state != f"running|{execution_new}|{fence_new}":
        raise AssertionError(f"T13 reconciliation falsely completed or rewound Work: {work_state}")
    finish_work(work_id, execution_new, fence_new)
    print("PASS T13: stale external merge is reconciled, actual merge SHA retained, and old review/CI evidence invalidated")


def main() -> None:
    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    test_manifest_contract(manifest)
    setup_database()
    project_id, resource_id, repository_id, repository_full_name = setup_repository_target(manifest)
    provider = FakeGitHubProvider()

    test_delivery_requires_resource_claim(
        project_id, resource_id, repository_id, repository_full_name
    )
    work_id, execution_id, fence, branch, _, pr_observation = test_execution_delivery_and_lost_response(
        project_id, resource_id, repository_id, repository_full_name, provider
    )
    test_exact_sha_lifecycle(
        work_id, execution_id, fence, branch, pr_observation,
        resource_id, repository_id, provider, manifest
    )
    test_stale_external_merge(
        project_id, resource_id, repository_id, repository_full_name, provider
    )
    print("PASS Stage 3 PostgreSQL 17.12 delivery protocol: T12, T13, T14, T15, T21, T22, T27")


if __name__ == "__main__":
    main()
