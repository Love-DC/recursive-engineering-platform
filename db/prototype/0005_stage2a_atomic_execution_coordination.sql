-- Stage 2A: atomic Work claim, physical resource reservation, lease/fence lifecycle.
-- Additive only. Migrations 0001-0004 remain unchanged.
-- Prototype-only PostgreSQL; never apply to production Supabase or legacy RAE.

BEGIN;

CREATE TABLE aep.work_resource_requirements (
  requirement_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id uuid NOT NULL,
  work_id uuid NOT NULL,
  resource_id uuid NOT NULL,
  resource_ref text NOT NULL
    CHECK (length(btrim(resource_ref)) BETWEEN 1 AND 255),
  write_set_kind text NOT NULL DEFAULT 'repository_ref'
    CHECK (write_set_kind = 'repository_ref'),
  conflict_key text NOT NULL DEFAULT '*'
    CHECK (conflict_key = '*'),
  normalized_write_set jsonb NOT NULL DEFAULT '[]'::jsonb
    CHECK (jsonb_typeof(normalized_write_set) = 'array'
           AND normalized_write_set = '[]'::jsonb),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  FOREIGN KEY (project_id, work_id)
    REFERENCES aep.works(project_id, work_id),
  FOREIGN KEY (project_id, resource_id)
    REFERENCES aep.project_resources(project_id, resource_id),
  UNIQUE (work_id, resource_id, resource_ref, conflict_key)
);

CREATE INDEX work_resource_requirements_work_idx
  ON aep.work_resource_requirements(work_id, resource_id, resource_ref);

-- Requirement rows are mutable only before the first execution attempt. The
-- Work row is the serialization point: claim locks it before reading this set,
-- and every requirement mutation locks it before changing the set.
CREATE FUNCTION aep.guard_work_resource_requirement()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, aep
AS $function$
DECLARE
  v_work_id uuid;
  v_project_id uuid;
  v_resource_id uuid;
  v_resource_ref text;
  v_work aep.works%ROWTYPE;
  v_resource aep.resources%ROWTYPE;
BEGIN
  IF TG_OP = 'UPDATE'
     AND (
       NEW.work_id IS DISTINCT FROM OLD.work_id
       OR NEW.project_id IS DISTINCT FROM OLD.project_id
     ) THEN
    RAISE EXCEPTION 'WorkResourceRequirement cannot move between Works or projects'
      USING ERRCODE = '55000';
  END IF;

  IF TG_OP = 'DELETE' THEN
    v_work_id := OLD.work_id;
  ELSE
    v_work_id := NEW.work_id;
    v_project_id := NEW.project_id;
    v_resource_id := NEW.resource_id;
    v_resource_ref := NEW.resource_ref;
  END IF;

  SELECT work_row.* INTO v_work
  FROM aep.works AS work_row
  WHERE work_row.work_id = v_work_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'WorkResourceRequirement references an unknown Work'
      USING ERRCODE = '23503';
  END IF;

  IF v_work.fence_generation <> 0
     OR v_work.current_execution_id IS NOT NULL
     OR v_work.status NOT IN ('proposed', 'ready') THEN
    RAISE EXCEPTION 'WorkResourceRequirement is immutable after execution begins'
      USING ERRCODE = '55000';
  END IF;

  IF TG_OP <> 'DELETE' THEN
    IF v_work.project_id <> v_project_id THEN
      RAISE EXCEPTION 'WorkResourceRequirement project must match its Work'
        USING ERRCODE = '23503';
    END IF;

    SELECT resource_row.* INTO v_resource
    FROM aep.resources AS resource_row
    WHERE resource_row.resource_id = v_resource_id
    FOR SHARE;

    IF NOT FOUND OR v_resource.status <> 'active'
       OR v_resource.provider <> 'github'
       OR v_resource.resource_type <> 'repository'
       OR NOT aep.is_canonical_github_branch_ref(v_resource_ref) THEN
      RAISE EXCEPTION 'WorkResourceRequirement requires an active GitHub repository and canonical fully-qualified branch ref'
        USING ERRCODE = '23514',
              CONSTRAINT = 'work_resource_requirements_github_branch_ref_ck';
    END IF;
    RETURN NEW;
  END IF;

  RETURN OLD;
END
$function$;

CREATE TRIGGER work_resource_requirements_guard
BEFORE INSERT OR UPDATE OR DELETE ON aep.work_resource_requirements
FOR EACH ROW EXECUTE FUNCTION aep.guard_work_resource_requirement();

-- A write ProjectResource is usable only while its explicit OwnerDecision is
-- approved and scoped to this project or this physical resource. Revocation or
-- mutation is blocked while an active claim still relies on that grant.
CREATE FUNCTION aep.guard_project_resource_write_grant()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, aep
AS $function$
DECLARE
  v_decision aep.owner_decisions%ROWTYPE;
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF EXISTS (
      SELECT 1 FROM aep.resource_claims AS claim
      WHERE claim.project_id = OLD.project_id
        AND claim.resource_id = OLD.resource_id
        AND claim.status IN ('reserved', 'active')
    ) THEN
      RAISE EXCEPTION 'ProjectResource cannot be removed while active claims depend on it'
        USING ERRCODE = '55000';
    END IF;
    RETURN OLD;
  END IF;

  IF TG_OP = 'UPDATE'
     AND (
       NEW.project_id IS DISTINCT FROM OLD.project_id
       OR NEW.resource_id IS DISTINCT FROM OLD.resource_id
       OR NEW.access_mode IS DISTINCT FROM OLD.access_mode
       OR NEW.status IS DISTINCT FROM OLD.status
       OR NEW.grant_version IS DISTINCT FROM OLD.grant_version
       OR NEW.grant_decision_id IS DISTINCT FROM OLD.grant_decision_id
     )
     AND EXISTS (
       SELECT 1 FROM aep.resource_claims AS claim
       WHERE claim.project_id = OLD.project_id
         AND claim.resource_id = OLD.resource_id
         AND claim.status IN ('reserved', 'active')
     ) THEN
    RAISE EXCEPTION 'ProjectResource grant cannot change while active claims depend on it'
      USING ERRCODE = '55000';
  END IF;

  IF NEW.status = 'active' AND NEW.access_mode IN ('write', 'read_write') THEN
    SELECT decision.* INTO v_decision
    FROM aep.owner_decisions AS decision
    WHERE decision.decision_id = NEW.grant_decision_id
    FOR SHARE;

    IF NOT FOUND
       OR v_decision.status <> 'approved'
       OR NOT (
         (v_decision.scope_type = 'resource'
           AND v_decision.scope_key = NEW.resource_id::text)
         OR
         (v_decision.scope_type = 'project'
           AND v_decision.scope_key = NEW.project_id::text)
       ) THEN
      RAISE EXCEPTION 'Active write ProjectResource requires an approved, correctly-scoped OwnerDecision'
        USING ERRCODE = '23514',
              CONSTRAINT = 'project_resources_active_write_requires_approved_grant_ck';
    END IF;
  END IF;

  RETURN NEW;
END
$function$;

CREATE TRIGGER project_resources_write_grant_guard
BEFORE INSERT OR UPDATE OR DELETE ON aep.project_resources
FOR EACH ROW EXECUTE FUNCTION aep.guard_project_resource_write_grant();

CREATE FUNCTION aep.guard_approved_grant_decision_mutation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, aep
AS $function$
DECLARE
  v_decision_id uuid;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_decision_id := OLD.decision_id;
  ELSE
    v_decision_id := OLD.decision_id;
  END IF;

  IF OLD.status = 'approved' AND EXISTS (
    SELECT 1
    FROM aep.project_resources AS project_resource
    JOIN aep.resource_claims AS claim
      ON claim.project_id = project_resource.project_id
     AND claim.resource_id = project_resource.resource_id
    WHERE project_resource.grant_decision_id = v_decision_id
      AND claim.status IN ('reserved', 'active')
  ) THEN
    RAISE EXCEPTION 'Approved OwnerDecision cannot be changed while active claims depend on it'
      USING ERRCODE = '55000';
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END
$function$;

CREATE TRIGGER owner_decisions_active_grant_guard
BEFORE UPDATE OR DELETE ON aep.owner_decisions
FOR EACH ROW EXECUTE FUNCTION aep.guard_approved_grant_decision_mutation();

CREATE FUNCTION aep.guard_resource_archive()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, aep
AS $function$
BEGIN
  -- A Resource ID is a durable authorization/conflict identity. Retargeting
  -- it would silently carry existing ProjectResource grants and requirements
  -- to a different physical repository. Create a new resource_id instead.
  IF TG_OP = 'UPDATE'
     AND (
       NEW.provider IS DISTINCT FROM OLD.provider
       OR NEW.host IS DISTINCT FROM OLD.host
       OR NEW.resource_type IS DISTINCT FROM OLD.resource_type
       OR NEW.stable_resource_id IS DISTINCT FROM OLD.stable_resource_id
       OR NEW.canonical_key IS DISTINCT FROM OLD.canonical_key
     ) THEN
    RAISE EXCEPTION 'Physical Resource identity fields are immutable; create a new resource_id'
      USING ERRCODE = '55000';
  END IF;

  IF TG_OP = 'DELETE' THEN
    IF EXISTS (
      SELECT 1 FROM aep.resource_claims AS claim
      WHERE claim.resource_id = OLD.resource_id
        AND claim.status IN ('reserved', 'active')
    ) THEN
      RAISE EXCEPTION 'Physical Resource cannot be removed while active claims exist'
        USING ERRCODE = '55000';
    END IF;
    RETURN OLD;
  END IF;

  IF NEW.status <> 'active' AND OLD.status = 'active'
     AND EXISTS (
       SELECT 1 FROM aep.resource_claims AS claim
       WHERE claim.resource_id = OLD.resource_id
         AND claim.status IN ('reserved', 'active')
     ) THEN
    RAISE EXCEPTION 'Physical Resource cannot be archived while active claims exist'
      USING ERRCODE = '55000';
  END IF;
  RETURN NEW;
END
$function$;

CREATE TRIGGER resources_active_claim_guard
BEFORE UPDATE OR DELETE ON aep.resources
FOR EACH ROW EXECUTE FUNCTION aep.guard_resource_archive();

-- Runtime-only bulk declaration API. The Project ID is derived from the
-- canonical Work row, never accepted from the caller. Replacing the declared
-- set is atomic and allowed only before the first execution attempt.
CREATE FUNCTION aep.set_work_resource_requirements(
  p_work_id uuid,
  p_requirements jsonb
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, aep
AS $function$
DECLARE
  v_work aep.works%ROWTYPE;
  v_count integer;
BEGIN
  IF p_work_id IS NULL OR p_requirements IS NULL THEN
    RAISE EXCEPTION 'work_id and requirements array are required'
      USING ERRCODE = '22004';
  END IF;
  IF jsonb_typeof(p_requirements) <> 'array' THEN
    RAISE EXCEPTION 'requirements must be a JSON array'
      USING ERRCODE = '22023';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_requirements) AS item(value)
    WHERE jsonb_typeof(item.value) <> 'object'
       OR NOT (item.value ? 'resource_id')
       OR NOT (item.value ? 'resource_ref')
       OR jsonb_typeof(item.value->'resource_id') <> 'string'
       OR jsonb_typeof(item.value->'resource_ref') <> 'string'
       OR EXISTS (
         SELECT 1
         FROM jsonb_object_keys(item.value) AS field(key)
         WHERE field.key NOT IN ('resource_id', 'resource_ref')
       )
  ) THEN
    RAISE EXCEPTION 'each requirement must contain only string resource_id and resource_ref fields'
      USING ERRCODE = '22023';
  END IF;

  SELECT work_row.* INTO v_work
  FROM aep.works AS work_row
  WHERE work_row.work_id = p_work_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Work does not exist' USING ERRCODE = '23503';
  END IF;
  IF v_work.fence_generation <> 0
     OR v_work.current_execution_id IS NOT NULL
     OR v_work.status NOT IN ('proposed', 'ready') THEN
    RAISE EXCEPTION 'Work resource requirements are immutable after execution begins'
      USING ERRCODE = '55000';
  END IF;

  DELETE FROM aep.work_resource_requirements AS requirement
  WHERE requirement.work_id = p_work_id;

  INSERT INTO aep.work_resource_requirements(
    project_id, work_id, resource_id, resource_ref,
    write_set_kind, conflict_key, normalized_write_set
  )
  SELECT
    v_work.project_id,
    p_work_id,
    requirement.resource_id,
    requirement.resource_ref,
    'repository_ref',
    '*',
    '[]'::jsonb
  FROM jsonb_to_recordset(p_requirements)
    AS requirement(resource_id uuid, resource_ref text)
  ORDER BY requirement.resource_id, requirement.resource_ref;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END
$function$;

-- Claim lock sequence:
--   Work -> project -> (current Execution, optional Work OwnerDecision)
--   -> physical Resources sorted by resource_id
--   -> ProjectResources sorted by resource_id -> grant OwnerDecisions
--   -> Execution and ResourceClaim writes.
-- Dependency eligibility is read in this transaction; atomic graph mutation,
-- cross-project sharing authorization, and graph-wide locks are Stage 2B.
CREATE FUNCTION aep.claim_work(
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

CREATE FUNCTION aep.renew_execution(
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

CREATE FUNCTION aep.finish_execution(
  p_work_id uuid,
  p_execution_id uuid,
  p_fence bigint,
  p_expected_work_version bigint,
  p_outcome text,
  p_result jsonb DEFAULT '{}'::jsonb
)
RETURNS TABLE (
  work_status text,
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
  v_work_status text;
  v_work_version bigint;
  v_expected_claims bigint;
  v_active_claims bigint;
BEGIN
  IF p_work_id IS NULL OR p_execution_id IS NULL OR p_fence IS NULL
     OR p_expected_work_version IS NULL OR p_outcome IS NULL THEN
    RAISE EXCEPTION 'work_id, execution_id, fence, expected version and outcome are required'
      USING ERRCODE = '22004';
  END IF;
  IF p_outcome NOT IN ('succeeded', 'failed') THEN
    RAISE EXCEPTION 'outcome must be succeeded or failed'
      USING ERRCODE = '22023';
  END IF;
  IF p_result IS NULL OR jsonb_typeof(p_result) <> 'object' THEN
    RAISE EXCEPTION 'result must be a JSON object' USING ERRCODE = '22023';
  END IF;

  SELECT work_row.* INTO v_work
  FROM aep.works AS work_row
  WHERE work_row.work_id = p_work_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Work does not exist' USING ERRCODE = '23503';
  END IF;

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

  v_work_status := CASE WHEN p_outcome = 'succeeded' THEN 'delivered' ELSE 'failed' END;

  UPDATE aep.executions
  SET status = p_outcome,
      result = p_result,
      finished_at = v_now,
      updated_at = v_now
  WHERE execution_id = p_execution_id
    AND work_id = p_work_id;

  UPDATE aep.resource_claims
  SET status = 'released',
      lease_until = NULL,
      released_at = v_now
  WHERE execution_id = p_execution_id
    AND status IN ('reserved', 'active');

  UPDATE aep.works
  SET status = v_work_status,
      current_execution_id = NULL,
      version = version + 1,
      updated_at = v_now
  WHERE work_id = p_work_id
    AND current_execution_id = p_execution_id
    AND fence_generation = p_fence
    AND version = p_expected_work_version
  RETURNING version INTO v_work_version;

  RETURN QUERY SELECT v_work_status, v_work_version;
END
$function$;

ALTER TABLE aep.work_resource_requirements OWNER TO aep_owner;

ALTER FUNCTION aep.guard_work_resource_requirement() OWNER TO aep_owner;
ALTER FUNCTION aep.guard_project_resource_write_grant() OWNER TO aep_owner;
ALTER FUNCTION aep.guard_approved_grant_decision_mutation() OWNER TO aep_owner;
ALTER FUNCTION aep.guard_resource_archive() OWNER TO aep_owner;
ALTER FUNCTION aep.set_work_resource_requirements(uuid, jsonb) OWNER TO aep_owner;
ALTER FUNCTION aep.claim_work(uuid, uuid, integer) OWNER TO aep_owner;
ALTER FUNCTION aep.renew_execution(uuid, uuid, bigint, bigint, integer) OWNER TO aep_owner;
ALTER FUNCTION aep.finish_execution(uuid, uuid, bigint, bigint, text, jsonb) OWNER TO aep_owner;

DO $aep$
BEGIN
  ALTER TABLE aep.work_resource_requirements ENABLE ROW LEVEL SECURITY;
  ALTER TABLE aep.work_resource_requirements FORCE ROW LEVEL SECURITY;
  CREATE POLICY owner_full_access ON aep.work_resource_requirements
    FOR ALL TO aep_owner USING (true) WITH CHECK (true);
END
$aep$;

REVOKE ALL ON TABLE aep.work_resource_requirements FROM PUBLIC, aep_runtime;

REVOKE ALL ON FUNCTION aep.guard_work_resource_requirement() FROM PUBLIC, aep_runtime;
REVOKE ALL ON FUNCTION aep.guard_project_resource_write_grant() FROM PUBLIC, aep_runtime;
REVOKE ALL ON FUNCTION aep.guard_approved_grant_decision_mutation() FROM PUBLIC, aep_runtime;
REVOKE ALL ON FUNCTION aep.guard_resource_archive() FROM PUBLIC, aep_runtime;

REVOKE ALL ON FUNCTION aep.set_work_resource_requirements(uuid, jsonb) FROM PUBLIC, aep_runtime;
REVOKE ALL ON FUNCTION aep.claim_work(uuid, uuid, integer) FROM PUBLIC, aep_runtime;
REVOKE ALL ON FUNCTION aep.renew_execution(uuid, uuid, bigint, bigint, integer) FROM PUBLIC, aep_runtime;
REVOKE ALL ON FUNCTION aep.finish_execution(uuid, uuid, bigint, bigint, text, jsonb) FROM PUBLIC, aep_runtime;

GRANT EXECUTE ON FUNCTION aep.set_work_resource_requirements(uuid, jsonb) TO aep_runtime;
GRANT EXECUTE ON FUNCTION aep.claim_work(uuid, uuid, integer) TO aep_runtime;
GRANT EXECUTE ON FUNCTION aep.renew_execution(uuid, uuid, bigint, bigint, integer) TO aep_runtime;
GRANT EXECUTE ON FUNCTION aep.finish_execution(uuid, uuid, bigint, bigint, text, jsonb) TO aep_runtime;

COMMIT;
