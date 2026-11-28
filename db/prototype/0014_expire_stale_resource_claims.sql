-- Stage 2A follow-up: expire stale cross-Work resource reservations atomically.
-- A live Execution/ResourceClaim lease still excludes competing Work. A stale
-- claim from another Work must not hold the physical Resource/ref forever.
BEGIN;

CREATE OR REPLACE FUNCTION aep.claim_work(
  p_work_id uuid,
  p_session_id uuid,
  p_lease_seconds integer DEFAULT 300
)
RETURNS TABLE (
  execution_id uuid,
  attempt_no integer,
  fence bigint,
  lease_until timestamptz,
  work_version bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, aep
AS $function$
DECLARE
  v_work aep.works%ROWTYPE;
  v_project_status text;
  v_previous aep.executions%ROWTYPE;
  v_previous_execution_id uuid;
  v_has_previous boolean := false;
  v_work_decision aep.owner_decisions%ROWTYPE;
  v_resource_id uuid;
  v_resource aep.resources%ROWTYPE;
  v_requirement aep.work_resource_requirements%ROWTYPE;
  v_project_resource aep.project_resources%ROWTYPE;
  v_grant_decision aep.owner_decisions%ROWTYPE;
  v_now timestamptz;
  v_execution_id uuid := gen_random_uuid();
  v_attempt_no integer;
  v_fence bigint;
  v_lease_until timestamptz;
  v_work_version bigint;
BEGIN
  IF p_work_id IS NULL OR p_session_id IS NULL THEN
    RAISE EXCEPTION 'work_id and session_id are required' USING ERRCODE = '22004';
  END IF;
  IF p_lease_seconds IS NULL OR p_lease_seconds NOT BETWEEN 1 AND 86400 THEN
    RAISE EXCEPTION 'lease_seconds must be between 1 and 86400'
      USING ERRCODE = '22023';
  END IF;

  SELECT work_row.* INTO v_work
  FROM aep.works AS work_row
  WHERE work_row.work_id = p_work_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Work does not exist' USING ERRCODE = '23503';
  END IF;

  SELECT project_row.status INTO v_project_status
  FROM aep.projects AS project_row
  WHERE project_row.project_id = v_work.project_id
  FOR SHARE;

  IF NOT FOUND OR v_project_status <> 'active' THEN
    RAISE EXCEPTION 'Work project is not active' USING ERRCODE = '55000';
  END IF;

  -- READY is a cached projection. Re-check every active prerequisite in the
  -- same claim transaction. Stage 2A deliberately accepts only an active,
  -- same-project graph owned by this project; shared/cross-project graph
  -- authorization and graph mutation coordination remain Stage 2B work.
  IF EXISTS (
    SELECT 1
    FROM aep.work_relations AS relation_row
    LEFT JOIN aep.works AS prerequisite
      ON prerequisite.work_id = relation_row.target_work_id
    LEFT JOIN aep.dependency_graphs AS graph_row
      ON graph_row.graph_id = relation_row.dependency_graph_id
    WHERE relation_row.source_work_id = p_work_id
      AND relation_row.relation_type = 'depends_on'
      AND relation_row.status = 'active'
      AND (
        prerequisite.status IS DISTINCT FROM 'delivered'
        OR prerequisite.project_id IS DISTINCT FROM v_work.project_id
        OR graph_row.status IS DISTINCT FROM 'active'
        OR graph_row.graph_scope IS DISTINCT FROM 'project'
        OR graph_row.owner_project_id IS DISTINCT FROM v_work.project_id
        OR NOT EXISTS (
          SELECT 1
          FROM aep.dependency_graph_members AS member_row
          WHERE member_row.graph_id = relation_row.dependency_graph_id
            AND member_row.project_id = v_work.project_id
            AND member_row.access_mode = 'owner'
        )
      )
  ) THEN
    RAISE EXCEPTION 'Work has an incomplete prerequisite or an inactive/unauthorized dependency graph'
      USING ERRCODE = '55000';
  END IF;

  IF v_work.status = 'running' THEN
    IF v_work.current_execution_id IS NULL THEN
      RAISE EXCEPTION 'Running Work has no current execution pointer'
        USING ERRCODE = '55000';
    END IF;

    SELECT execution_row.* INTO v_previous
    FROM aep.executions AS execution_row
    WHERE execution_row.work_id = p_work_id
      AND execution_row.execution_id = v_work.current_execution_id
    FOR UPDATE;

    IF NOT FOUND OR v_previous.status NOT IN ('claimed', 'running')
       OR v_previous.fence <> v_work.fence_generation
       OR v_previous.lease_until IS NULL THEN
      RAISE EXCEPTION 'Running Work current execution is inconsistent'
        USING ERRCODE = '55000';
    END IF;
    v_previous_execution_id := v_previous.execution_id;
    v_has_previous := true;
  ELSIF v_work.status <> 'ready' OR v_work.current_execution_id IS NOT NULL THEN
    RAISE EXCEPTION 'Work is not READY or eligible for expired-lease takeover'
      USING ERRCODE = '55000';
  END IF;

  IF v_work.owner_decision_id IS NOT NULL THEN
    SELECT decision.* INTO v_work_decision
    FROM aep.owner_decisions AS decision
    WHERE decision.decision_id = v_work.owner_decision_id
    FOR SHARE;

    IF NOT FOUND
       OR v_work_decision.status <> 'approved'
       OR NOT (
         (v_work_decision.scope_type = 'work'
           AND v_work_decision.scope_key = p_work_id::text)
         OR
         (v_work_decision.scope_type = 'project'
           AND v_work_decision.scope_key = v_work.project_id::text)
       ) THEN
      RAISE EXCEPTION 'Work OwnerDecision is not approved or is out of scope'
        USING ERRCODE = '55000';
    END IF;
  END IF;

  -- Acquire every physical-resource lock in a stable global order before any
  -- reservation write. This also serializes two aliases for one Resource row.
  FOR v_resource_id IN
    SELECT DISTINCT requirement.resource_id
    FROM aep.work_resource_requirements AS requirement
    WHERE requirement.work_id = p_work_id
    ORDER BY requirement.resource_id
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

  FOR v_requirement IN
    SELECT requirement.*
    FROM aep.work_resource_requirements AS requirement
    WHERE requirement.work_id = p_work_id
    ORDER BY requirement.resource_id, requirement.resource_ref, requirement.requirement_id
  LOOP
    IF NOT aep.is_canonical_github_branch_ref(v_requirement.resource_ref) THEN
      RAISE EXCEPTION 'Required Resource ref is not a canonical GitHub branch ref'
        USING ERRCODE = '55000';
    END IF;

    SELECT project_resource.* INTO v_project_resource
    FROM aep.project_resources AS project_resource
    WHERE project_resource.project_id = v_work.project_id
      AND project_resource.resource_id = v_requirement.resource_id
    FOR SHARE;

    IF NOT FOUND OR v_project_resource.status <> 'active'
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
           AND v_grant_decision.scope_key = v_work.project_id::text)
       ) THEN
      RAISE EXCEPTION 'Required Resource write grant is not approved or is out of scope'
        USING ERRCODE = '55000';
    END IF;
  END LOOP;

  -- Re-evaluate the lease boundary only after all locks have been acquired.
  -- Renewal and takeover serialize on the Work row, so exactly one observes
  -- the still-live/expired lease at this point.
  v_now := clock_timestamp();
  IF v_has_previous AND v_previous.lease_until > v_now THEN
    RAISE EXCEPTION 'Work already has a live execution lease'
      USING ERRCODE = '55000';
  END IF;

  -- A claim remains a conflict only while its lease is live. The physical
  -- Resource rows were locked above, so matching claim cleanup is serialized
  -- against every other runtime claim attempt for these Resources. NULL leases
  -- remain conservative conflicts; only an observed expired deadline is freed.
  UPDATE aep.resource_claims AS claim_row
  SET status = 'expired',
      lease_until = NULL,
      released_at = v_now
  WHERE claim_row.status IN ('reserved', 'active')
    AND claim_row.lease_until IS NOT NULL
    AND claim_row.lease_until <= v_now
    AND EXISTS (
      SELECT 1
      FROM aep.work_resource_requirements AS requirement
      WHERE requirement.work_id = p_work_id
        AND requirement.resource_id = claim_row.resource_id
        AND requirement.resource_ref = claim_row.resource_ref
        AND requirement.conflict_key = claim_row.conflict_key
    );

  IF EXISTS (
    SELECT 1
    FROM aep.work_resource_requirements AS requirement
    JOIN aep.resource_claims AS claim
      ON claim.resource_id = requirement.resource_id
     AND claim.resource_ref = requirement.resource_ref
     AND claim.conflict_key = requirement.conflict_key
     AND claim.status IN ('reserved', 'active')
    WHERE requirement.work_id = p_work_id
      AND (v_previous_execution_id IS NULL
           OR claim.execution_id <> v_previous_execution_id)
  ) THEN
    RAISE EXCEPTION 'One or more required physical resource refs are already reserved'
      USING ERRCODE = '55P03';
  END IF;

  -- No protocol state is modified until the complete requirement/grant set
  -- and all physical conflicts have passed validation.
  IF v_has_previous THEN
    UPDATE aep.executions AS execution_row
    SET status = 'expired',
        finished_at = v_now,
        updated_at = v_now
    WHERE execution_row.execution_id = v_previous_execution_id
      AND execution_row.work_id = p_work_id
      AND execution_row.status IN ('claimed', 'running');

    UPDATE aep.resource_claims AS claim_row
    SET status = 'expired',
        lease_until = NULL,
        released_at = v_now
    WHERE claim_row.execution_id = v_previous_execution_id
      AND claim_row.status IN ('reserved', 'active');
  END IF;

  SELECT COALESCE(max(execution_row.attempt_no), 0) + 1
    INTO v_attempt_no
  FROM aep.executions AS execution_row
  WHERE execution_row.work_id = p_work_id;

  v_fence := v_work.fence_generation + 1;
  v_lease_until := v_now + make_interval(secs => p_lease_seconds);

  INSERT INTO aep.executions(
    execution_id, work_id, session_id, attempt_no, status,
    lease_until, fence
  ) VALUES (
    v_execution_id, p_work_id, p_session_id, v_attempt_no, 'running',
    v_lease_until, v_fence
  );

  UPDATE aep.works
  SET status = 'running',
      current_execution_id = v_execution_id,
      fence_generation = v_fence,
      version = version + 1,
      updated_at = v_now
  WHERE work_id = p_work_id
  RETURNING version INTO v_work_version;

  INSERT INTO aep.resource_claims(
    project_id, resource_id, work_id, execution_id, resource_ref,
    write_set_kind, conflict_key, normalized_write_set, status,
    lease_until, fence
  )
  SELECT
    requirement.project_id, requirement.resource_id, requirement.work_id,
    v_execution_id, requirement.resource_ref, requirement.write_set_kind,
    requirement.conflict_key, requirement.normalized_write_set, 'active',
    v_lease_until, v_fence
  FROM aep.work_resource_requirements AS requirement
  WHERE requirement.work_id = p_work_id
  ORDER BY requirement.resource_id, requirement.resource_ref, requirement.requirement_id;

  RETURN QUERY SELECT v_execution_id, v_attempt_no, v_fence, v_lease_until, v_work_version;
END
$function$;

ALTER FUNCTION aep.claim_work(uuid, uuid, integer) OWNER TO aep_owner;
REVOKE ALL ON FUNCTION aep.claim_work(uuid, uuid, integer) FROM PUBLIC, aep_runtime;
GRANT EXECUTE ON FUNCTION aep.claim_work(uuid, uuid, integer) TO aep_runtime;
COMMENT ON FUNCTION aep.claim_work(uuid, uuid, integer) IS
  'Atomically claims READY Work and expires only matching ResourceClaims whose non-null lease has elapsed before conflict validation.';

CREATE OR REPLACE FUNCTION aep.renew_execution(
  p_work_id uuid,
  p_execution_id uuid,
  p_fence bigint,
  p_expected_work_version bigint,
  p_lease_seconds integer DEFAULT 300
)
RETURNS TABLE (
  lease_until timestamptz,
  work_version bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, aep
AS $function$
DECLARE
  v_work aep.works%ROWTYPE;
  v_execution aep.executions%ROWTYPE;
  v_now timestamptz;
  v_lease_until timestamptz;
  v_work_version bigint;
  v_expected_claims bigint;
  v_active_claims bigint;
  v_resource_id uuid;
BEGIN
  IF p_work_id IS NULL OR p_execution_id IS NULL OR p_fence IS NULL
     OR p_expected_work_version IS NULL THEN
    RAISE EXCEPTION 'work_id, execution_id, fence and expected work version are required'
      USING ERRCODE = '22004';
  END IF;
  IF p_lease_seconds IS NULL OR p_lease_seconds NOT BETWEEN 1 AND 86400 THEN
    RAISE EXCEPTION 'lease_seconds must be between 1 and 86400'
      USING ERRCODE = '22023';
  END IF;

  SELECT work_row.* INTO v_work
  FROM aep.works AS work_row
  WHERE work_row.work_id = p_work_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Work does not exist' USING ERRCODE = '23503';
  END IF;

  -- Serialize lease renewal with claim_work's physical-resource locks.
  -- Both paths lock Work first, then Resource rows in the same global order,
  -- before either path can change or reclaim ResourceClaims.
  FOR v_resource_id IN
    SELECT DISTINCT requirement.resource_id
    FROM aep.work_resource_requirements AS requirement
    WHERE requirement.work_id = p_work_id
    ORDER BY requirement.resource_id
  LOOP
    PERFORM 1
    FROM aep.resources AS resource_row
    WHERE resource_row.resource_id = v_resource_id
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Execution physical Resource no longer exists'
        USING ERRCODE = '55000';
    END IF;
  END LOOP;

  SELECT execution_row.* INTO v_execution
  FROM aep.executions AS execution_row
  WHERE execution_row.work_id = p_work_id
    AND execution_row.execution_id = p_execution_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Execution does not belong to Work'
      USING ERRCODE = '23503';
  END IF;

  v_now := clock_timestamp();
  IF v_work.version <> p_expected_work_version THEN
    RAISE EXCEPTION 'Work version changed; refresh before retrying'
      USING ERRCODE = '40001';
  END IF;
  IF v_work.status <> 'running'
     OR v_work.current_execution_id <> p_execution_id
     OR v_work.fence_generation <> p_fence
     OR v_execution.fence <> p_fence
     OR v_execution.status NOT IN ('claimed', 'running')
     OR v_execution.lease_until IS NULL
     OR v_execution.lease_until <= v_now THEN
    RAISE EXCEPTION 'Execution is stale, superseded, or has an expired lease'
      USING ERRCODE = '55000';
  END IF;

  SELECT count(*) INTO v_expected_claims
  FROM aep.work_resource_requirements AS requirement
  WHERE requirement.work_id = p_work_id;

  SELECT count(*) INTO v_active_claims
  FROM aep.resource_claims AS claim
  WHERE claim.execution_id = p_execution_id
    AND claim.status = 'active';

  IF v_expected_claims <> v_active_claims THEN
    RAISE EXCEPTION 'Execution resource reservation set is incomplete'
      USING ERRCODE = '55000';
  END IF;

  v_lease_until := v_now + make_interval(secs => p_lease_seconds);
  UPDATE aep.executions
  SET lease_until = v_lease_until,
      updated_at = v_now
  WHERE execution_id = p_execution_id
    AND work_id = p_work_id;

  UPDATE aep.resource_claims
  SET lease_until = v_lease_until
  WHERE execution_id = p_execution_id
    AND status = 'active';

  UPDATE aep.works
  SET version = version + 1,
      updated_at = v_now
  WHERE work_id = p_work_id
    AND version = p_expected_work_version
  RETURNING version INTO v_work_version;

  RETURN QUERY SELECT v_lease_until, v_work_version;
END
$function$;

ALTER FUNCTION aep.renew_execution(uuid, uuid, bigint, bigint, integer) OWNER TO aep_owner;
REVOKE ALL ON FUNCTION aep.renew_execution(uuid, uuid, bigint, bigint, integer) FROM PUBLIC, aep_runtime;
GRANT EXECUTE ON FUNCTION aep.renew_execution(uuid, uuid, bigint, bigint, integer) TO aep_runtime;
COMMENT ON FUNCTION aep.renew_execution(uuid, uuid, bigint, bigint, integer) IS
  'Renews only a current fenced Execution after locking its ordered physical Resources and validating the complete active ResourceClaim set.';

COMMIT;
