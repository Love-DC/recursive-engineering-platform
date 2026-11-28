-- Stage 3 hardening: GitHub delivery allocation must be backed by the
-- current Execution's complete, exact, live ResourceClaim set.
-- Additive prototype migration. Never apply to production Supabase or legacy RAE.

BEGIN;

CREATE OR REPLACE FUNCTION aep.allocate_execution_delivery(
  p_work_id uuid,
  p_execution_id uuid,
  p_fence bigint,
  p_resource_id uuid,
  p_host text,
  p_repository_id text,
  p_repository_full_name text,
  p_base_ref text,
  p_base_sha text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, aep
AS $function$
DECLARE
  v_project_id uuid;
  v_project_status text;
  v_work aep.works%ROWTYPE;
  v_execution aep.executions%ROWTYPE;
  v_resource_id uuid;
  v_resource aep.resources%ROWTYPE;
  v_requirement aep.work_resource_requirements%ROWTYPE;
  v_project_resource aep.project_resources%ROWTYPE;
  v_grant_decision aep.owner_decisions%ROWTYPE;
  v_claim aep.resource_claims%ROWTYPE;
  v_expected_claims bigint;
  v_active_claims bigint;
  v_graph_ids uuid[];
  v_current_graph_ids uuid[];
  v_now timestamptz;
  v_branch text;
  v_existing aep.execution_deliveries%ROWTYPE;
BEGIN
  IF p_work_id IS NULL OR p_execution_id IS NULL OR p_fence IS NULL
     OR p_resource_id IS NULL OR p_host IS NULL OR p_repository_id IS NULL
     OR p_repository_full_name IS NULL OR p_base_ref IS NULL OR p_base_sha IS NULL THEN
    RAISE EXCEPTION 'Execution delivery identity fields are required'
      USING ERRCODE = '22004';
  END IF;
  IF p_host <> lower(p_host) OR p_base_sha !~ '^[0-9a-f]{40}$'
     OR p_base_ref !~ '^refs/heads/[A-Za-z0-9._/-]+$' THEN
    RAISE EXCEPTION 'Repository host, base ref, or exact base SHA is not canonical'
      USING ERRCODE = '22023';
  END IF;

  -- Match claim_work/renew_execution lock order:
  -- Project SHARE -> DependencyGraph SHARE -> Work UPDATE -> Execution UPDATE
  -- -> physical Resources in UUID order -> ProjectResource/OwnerDecision SHARE
  -- -> ResourceClaim UPDATE -> delivery row.
  SELECT work_row.project_id INTO v_project_id
  FROM aep.works AS work_row
  WHERE work_row.work_id = p_work_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Work does not exist' USING ERRCODE = '23503';
  END IF;

  SELECT project_row.status INTO v_project_status
  FROM aep.projects AS project_row
  WHERE project_row.project_id = v_project_id
  FOR SHARE;
  IF NOT FOUND OR v_project_status <> 'active' THEN
    RAISE EXCEPTION 'Work project is not active' USING ERRCODE = '55000';
  END IF;

  v_graph_ids := aep.lock_work_dependency_graphs(p_work_id, 'share');

  SELECT work_row.* INTO v_work
  FROM aep.works AS work_row
  WHERE work_row.work_id = p_work_id
  FOR UPDATE;
  IF NOT FOUND OR v_work.project_id IS DISTINCT FROM v_project_id THEN
    RAISE EXCEPTION 'Work project changed while acquiring dependency locks; retry'
      USING ERRCODE = '40001';
  END IF;

  v_current_graph_ids := aep.current_work_dependency_graphs(p_work_id);
  IF v_current_graph_ids IS DISTINCT FROM v_graph_ids THEN
    RAISE EXCEPTION 'Work dependency graph membership changed; retry the transaction'
      USING ERRCODE = '40001';
  END IF;

  SELECT execution_row.* INTO v_execution
  FROM aep.executions AS execution_row
  WHERE execution_row.work_id = p_work_id
    AND execution_row.execution_id = p_execution_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Execution does not belong to Work' USING ERRCODE = '23503';
  END IF;

  v_now := clock_timestamp();
  IF v_work.status <> 'running'
     OR v_work.current_execution_id IS DISTINCT FROM p_execution_id
     OR v_work.fence_generation <> p_fence
     OR v_execution.fence <> p_fence
     OR v_execution.status <> 'running'
     OR v_execution.lease_until IS NULL
     OR v_execution.lease_until <= v_now THEN
    RAISE EXCEPTION 'Execution delivery requires the current running execution, fence, and live lease'
      USING ERRCODE = '55000';
  END IF;

  SELECT requirement_row.* INTO v_requirement
  FROM aep.work_resource_requirements AS requirement_row
  WHERE requirement_row.project_id = v_project_id
    AND requirement_row.work_id = p_work_id
    AND requirement_row.resource_id = p_resource_id
    AND requirement_row.resource_ref = p_base_ref
  ORDER BY requirement_row.requirement_id
  LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Execution has no matching Work ResourceRequirement for the target repository ref'
      USING ERRCODE = '55000';
  END IF;

  SELECT count(*) INTO v_expected_claims
  FROM aep.work_resource_requirements AS requirement_row
  WHERE requirement_row.work_id = p_work_id;
  IF v_expected_claims = 0 THEN
    RAISE EXCEPTION 'Execution has no declared physical ResourceRequirements'
      USING ERRCODE = '55000';
  END IF;

  -- Lock all required physical repositories in the same stable order used by
  -- claim_work. A different project cannot race a new claim into this Resource
  -- while this delivery is being allocated.
  FOR v_resource_id IN
    SELECT DISTINCT requirement_row.resource_id
    FROM aep.work_resource_requirements AS requirement_row
    WHERE requirement_row.work_id = p_work_id
    ORDER BY requirement_row.resource_id
  LOOP
    SELECT resource_row.* INTO v_resource
    FROM aep.resources AS resource_row
    WHERE resource_row.resource_id = v_resource_id
    FOR UPDATE;

    IF NOT FOUND
       OR v_resource.status <> 'active'
       OR v_resource.provider IS DISTINCT FROM 'github'
       OR v_resource.resource_type IS DISTINCT FROM 'repository' THEN
      RAISE EXCEPTION 'Required physical Resource is not an active GitHub repository'
        USING ERRCODE = '55000';
    END IF;
  END LOOP;

  -- Revalidate each current write grant while holding the same rows used by
  -- claim_work. A revoked or out-of-scope grant cannot authorize a new delivery.
  FOR v_requirement IN
    SELECT requirement_row.*
    FROM aep.work_resource_requirements AS requirement_row
    WHERE requirement_row.work_id = p_work_id
    ORDER BY requirement_row.resource_id, requirement_row.resource_ref,
             requirement_row.requirement_id
  LOOP
    IF NOT aep.is_canonical_github_branch_ref(v_requirement.resource_ref) THEN
      RAISE EXCEPTION 'Required Resource ref is not a canonical GitHub branch ref'
        USING ERRCODE = '55000';
    END IF;

    SELECT project_resource.* INTO v_project_resource
    FROM aep.project_resources AS project_resource
    WHERE project_resource.project_id = v_project_id
      AND project_resource.resource_id = v_requirement.resource_id
    FOR SHARE;

    IF NOT FOUND
       OR v_project_resource.status <> 'active'
       OR v_project_resource.access_mode NOT IN ('write', 'read_write')
       OR v_project_resource.grant_decision_id IS NULL THEN
      RAISE EXCEPTION 'Required Resource lacks an active write ProjectResource link'
        USING ERRCODE = '55000';
    END IF;

    SELECT decision.* INTO v_grant_decision
    FROM aep.owner_decisions AS decision
    WHERE decision.decision_id = v_project_resource.grant_decision_id
    FOR SHARE;

    IF NOT FOUND
       OR v_grant_decision.status <> 'approved'
       OR NOT (
         (v_grant_decision.scope_type = 'resource'
           AND v_grant_decision.scope_key = v_requirement.resource_id::text)
         OR
         (v_grant_decision.scope_type = 'project'
           AND v_grant_decision.scope_key = v_project_id::text)
       ) THEN
      RAISE EXCEPTION 'Required Resource write grant is not approved or is out of scope'
        USING ERRCODE = '55000';
    END IF;
  END LOOP;

  SELECT resource_row.* INTO v_resource
  FROM aep.resources AS resource_row
  WHERE resource_row.resource_id = p_resource_id;
  IF NOT FOUND
     OR v_resource.provider IS DISTINCT FROM 'github'
     OR v_resource.resource_type IS DISTINCT FROM 'repository'
     OR v_resource.host IS DISTINCT FROM p_host
     OR v_resource.stable_resource_id IS DISTINCT FROM p_repository_id THEN
    RAISE EXCEPTION 'Execution delivery target does not match its declared physical Resource'
      USING ERRCODE = '42501';
  END IF;

  -- Require a complete set: every declared requirement has one live claim
  -- owned by this exact Execution and fence, with the same ref/write-set and
  -- lease deadline. Extra, stale-fence, expired, or mismatched claims do not count.
  SELECT count(*) INTO v_active_claims
  FROM aep.resource_claims AS claim_row
  WHERE claim_row.project_id = v_project_id
    AND claim_row.work_id = p_work_id
    AND claim_row.execution_id = p_execution_id
    AND claim_row.status = 'active'
    AND claim_row.fence = p_fence
    AND claim_row.lease_until = v_execution.lease_until
    AND claim_row.lease_until > v_now;

  IF v_expected_claims <> v_active_claims OR EXISTS (
    SELECT 1
    FROM aep.work_resource_requirements AS requirement_row
    WHERE requirement_row.work_id = p_work_id
      AND NOT EXISTS (
        SELECT 1
        FROM aep.resource_claims AS claim_row
        WHERE claim_row.project_id = requirement_row.project_id
          AND claim_row.resource_id = requirement_row.resource_id
          AND claim_row.work_id = requirement_row.work_id
          AND claim_row.execution_id = p_execution_id
          AND claim_row.resource_ref = requirement_row.resource_ref
          AND claim_row.write_set_kind = requirement_row.write_set_kind
          AND claim_row.conflict_key = requirement_row.conflict_key
          AND claim_row.normalized_write_set = requirement_row.normalized_write_set
          AND claim_row.status = 'active'
          AND claim_row.fence = p_fence
          AND claim_row.lease_until = v_execution.lease_until
          AND claim_row.lease_until > v_now
      )
  ) THEN
    RAISE EXCEPTION 'Execution resource reservation set is incomplete, expired, or stale'
      USING ERRCODE = '55000';
  END IF;

  SELECT claim_row.* INTO v_claim
  FROM aep.resource_claims AS claim_row
  WHERE claim_row.project_id = v_project_id
    AND claim_row.resource_id = p_resource_id
    AND claim_row.work_id = p_work_id
    AND claim_row.execution_id = p_execution_id
    AND claim_row.resource_ref = p_base_ref
    AND claim_row.write_set_kind = v_requirement.write_set_kind
    AND claim_row.conflict_key = v_requirement.conflict_key
    AND claim_row.normalized_write_set = v_requirement.normalized_write_set
    AND claim_row.status = 'active'
    AND claim_row.fence = p_fence
    AND claim_row.lease_until = v_execution.lease_until
    AND claim_row.lease_until > v_now
  ORDER BY claim_row.resource_claim_id
  LIMIT 1
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Execution has no matching active ResourceClaim for the target repository ref'
      USING ERRCODE = '55000';
  END IF;

  v_branch := 'work/' || p_work_id::text || '/execution/' || p_execution_id::text;
  SELECT * INTO v_existing
  FROM aep.execution_deliveries
  WHERE execution_id = p_execution_id
  FOR UPDATE;
  IF FOUND THEN
    IF v_existing.work_id <> p_work_id OR v_existing.fence <> p_fence
       OR v_existing.resource_id <> p_resource_id OR v_existing.host <> p_host
       OR v_existing.repository_id <> p_repository_id
       OR v_existing.repository_full_name <> p_repository_full_name
       OR v_existing.base_ref <> p_base_ref OR v_existing.base_sha <> p_base_sha
       OR v_existing.delivery_branch <> v_branch THEN
      RAISE EXCEPTION 'Execution delivery identity key reused with a different payload'
        USING ERRCODE = '23505';
    END IF;
    RETURN jsonb_build_object(
      'delivery_id', v_existing.delivery_id,
      'execution_id', v_existing.execution_id,
      'delivery_branch', v_existing.delivery_branch,
      'replayed', true
    );
  END IF;

  INSERT INTO aep.execution_deliveries(
    work_id, execution_id, fence, resource_id, provider, host, repository_id,
    repository_full_name, base_ref, base_sha, delivery_branch
  ) VALUES (
    p_work_id, p_execution_id, p_fence, p_resource_id, 'github', p_host,
    p_repository_id, p_repository_full_name, p_base_ref, p_base_sha, v_branch
  )
  RETURNING * INTO v_existing;

  UPDATE aep.executions
  SET base_sha = p_base_sha,
      delivery_branch = v_branch,
      updated_at = v_now
  WHERE execution_id = p_execution_id
    AND work_id = p_work_id
    AND fence = p_fence;

  RETURN jsonb_build_object(
    'delivery_id', v_existing.delivery_id,
    'execution_id', v_existing.execution_id,
    'delivery_branch', v_existing.delivery_branch,
    'replayed', false
  );
END
$function$;

ALTER FUNCTION aep.allocate_execution_delivery(
  uuid,uuid,bigint,uuid,text,text,text,text,text
) OWNER TO aep_owner;
REVOKE ALL ON FUNCTION aep.allocate_execution_delivery(
  uuid,uuid,bigint,uuid,text,text,text,text,text
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION aep.allocate_execution_delivery(
  uuid,uuid,bigint,uuid,text,text,text,text,text
) TO aep_runtime;

COMMIT;
