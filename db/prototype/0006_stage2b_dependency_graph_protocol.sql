-- Stage 2B: atomic dependency graph membership, DAG mutation, READY eligibility,
-- graph-wide serialization and parent/required-child completion.
-- Additive only. Migrations 0001-0005 remain unchanged.
-- Prototype-only PostgreSQL; never apply to production Supabase or legacy RAE.

BEGIN;

ALTER TABLE aep.dependency_graphs
  ADD COLUMN is_default boolean NOT NULL DEFAULT false,
  ADD CONSTRAINT dependency_graphs_default_scope_ck
    CHECK (NOT is_default OR graph_scope = 'project');

CREATE UNIQUE INDEX dependency_graphs_one_default_per_project_uq
  ON aep.dependency_graphs(owner_project_id)
  WHERE is_default;

ALTER TABLE aep.dependency_graph_members
  ADD COLUMN member_status text NOT NULL DEFAULT 'active',
  ADD COLUMN revoked_at timestamptz,
  ADD CONSTRAINT dependency_graph_members_status_ck
    CHECK (member_status IN ('active', 'revoked')),
  ADD CONSTRAINT dependency_graph_members_status_time_ck
    CHECK (
      (member_status = 'active' AND revoked_at IS NULL)
      OR (member_status = 'revoked' AND revoked_at IS NOT NULL)
    ),
  ADD CONSTRAINT dependency_graph_members_active_grant_ck
    CHECK (
      member_status = 'revoked'
      OR (access_mode = 'owner' AND grant_decision_id IS NULL)
      OR (access_mode IN ('read', 'write') AND grant_decision_id IS NOT NULL)
    );

ALTER TABLE aep.works
  ADD COLUMN dependency_blocked boolean NOT NULL DEFAULT false;

CREATE TABLE aep.dependency_graph_works (
  graph_id uuid NOT NULL REFERENCES aep.dependency_graphs(graph_id),
  work_id uuid NOT NULL REFERENCES aep.works(work_id),
  membership_status text NOT NULL DEFAULT 'active'
    CHECK (membership_status IN ('active', 'removed')),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  removed_at timestamptz,
  PRIMARY KEY (graph_id, work_id),
  UNIQUE (work_id, graph_id),
  CHECK (
    (membership_status = 'active' AND removed_at IS NULL)
    OR (membership_status = 'removed' AND removed_at IS NOT NULL)
  )
);

CREATE INDEX dependency_graph_works_work_idx
  ON aep.dependency_graph_works(work_id, graph_id, membership_status);

CREATE TABLE aep.dependency_graph_operations (
  operation_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  graph_id uuid NOT NULL REFERENCES aep.dependency_graphs(graph_id),
  request_key text NOT NULL CHECK (length(btrim(request_key)) BETWEEN 1 AND 160),
  request_payload jsonb NOT NULL CHECK (jsonb_typeof(request_payload) = 'array'),
  result_payload jsonb NOT NULL CHECK (jsonb_typeof(result_payload) = 'object'),
  graph_version bigint NOT NULL CHECK (graph_version > 0),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE (graph_id, request_key)
);

CREATE INDEX dependency_graph_operations_created_idx
  ON aep.dependency_graph_operations(graph_id, created_at DESC);

-- One default project graph exists for every project. This is a project-local
-- namespace; shared graphs remain explicit and may contain several projects.
INSERT INTO aep.dependency_graphs(graph_scope, owner_project_id, status, is_default)
SELECT 'project', project_row.project_id, 'active', true
FROM aep.projects AS project_row
WHERE NOT EXISTS (
  SELECT 1 FROM aep.dependency_graphs AS graph_row
  WHERE graph_row.owner_project_id = project_row.project_id
    AND graph_row.is_default
);

INSERT INTO aep.dependency_graph_members(graph_id, project_id, access_mode, member_status)
SELECT graph_row.graph_id, graph_row.owner_project_id, 'owner', 'active'
FROM aep.dependency_graphs AS graph_row
WHERE graph_row.is_default
ON CONFLICT (graph_id, project_id) DO NOTHING;

INSERT INTO aep.dependency_graph_works(graph_id, work_id, membership_status)
SELECT member_row.graph_id, work_row.work_id, 'active'
FROM aep.dependency_graph_members AS member_row
JOIN aep.works AS work_row
  ON work_row.project_id = member_row.project_id
WHERE member_row.member_status = 'active'
ON CONFLICT (graph_id, work_id) DO NOTHING;

-- Preserve referential integrity for pre-existing dependency rows. These
-- fallback mappings do not grant project authorization; the runtime eligibility
-- check still requires an active graph member plus approved access.
INSERT INTO aep.dependency_graph_works(graph_id, work_id, membership_status)
SELECT relation_row.dependency_graph_id, endpoint.work_id, 'active'
FROM aep.work_relations AS relation_row
CROSS JOIN LATERAL (
  VALUES (relation_row.source_work_id), (relation_row.target_work_id)
) AS endpoint(work_id)
WHERE relation_row.relation_type = 'depends_on'
  AND relation_row.status = 'active'
ON CONFLICT (graph_id, work_id) DO NOTHING;

ALTER TABLE aep.work_relations
  ADD CONSTRAINT work_relations_source_graph_member_fk
    FOREIGN KEY (source_work_id, dependency_graph_id)
    REFERENCES aep.dependency_graph_works(work_id, graph_id),
  ADD CONSTRAINT work_relations_target_graph_member_fk
    FOREIGN KEY (target_work_id, dependency_graph_id)
    REFERENCES aep.dependency_graph_works(work_id, graph_id);

-- Dependency edges are unique within a graph namespace; the same Work pair
-- may be related independently in two distinct shared graphs.
DROP INDEX aep.work_relations_active_exact_uq;

CREATE UNIQUE INDEX work_relations_active_exact_uq
  ON aep.work_relations(source_work_id, target_work_id, relation_type)
  WHERE status = 'active' AND relation_type <> 'depends_on';

CREATE UNIQUE INDEX work_relations_active_dependency_graph_uq
  ON aep.work_relations(
    source_work_id, target_work_id, relation_type, dependency_graph_id
  )
  WHERE status = 'active' AND relation_type = 'depends_on';

CREATE FUNCTION aep.current_work_dependency_graphs(p_work_id uuid)
RETURNS uuid[]
LANGUAGE sql
STABLE
SET search_path = pg_catalog, aep
AS $function$
  SELECT COALESCE(
    array_agg(membership.graph_id ORDER BY membership.graph_id),
    ARRAY[]::uuid[]
  )
  FROM aep.dependency_graph_works AS membership
  WHERE membership.work_id = p_work_id
$function$;

CREATE FUNCTION aep.lock_work_dependency_graphs(
  p_work_id uuid,
  p_lock_mode text
)
RETURNS uuid[]
LANGUAGE plpgsql
SET search_path = pg_catalog, aep
AS $function$
DECLARE
  v_graph_ids uuid[];
  v_graph_id uuid;
BEGIN
  IF p_lock_mode NOT IN ('share', 'update') THEN
    RAISE EXCEPTION 'dependency graph lock mode must be share or update'
      USING ERRCODE = '22023';
  END IF;

  v_graph_ids := aep.current_work_dependency_graphs(p_work_id);
  IF cardinality(v_graph_ids) = 0 THEN
    RAISE EXCEPTION 'Work has no active dependency graph membership'
      USING ERRCODE = '55000';
  END IF;

  FOR v_graph_id IN
    SELECT unnest(v_graph_ids) AS graph_id
    ORDER BY graph_id
  LOOP
    IF p_lock_mode = 'share' THEN
      PERFORM 1
      FROM aep.dependency_graphs AS graph_row
      WHERE graph_row.graph_id = v_graph_id
      FOR SHARE;
    ELSE
      PERFORM 1
      FROM aep.dependency_graphs AS graph_row
      WHERE graph_row.graph_id = v_graph_id
      FOR UPDATE;
    END IF;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Dependency graph disappeared while locking'
        USING ERRCODE = '40001';
    END IF;
  END LOOP;

  RETURN v_graph_ids;
END
$function$;

CREATE FUNCTION aep.dependency_graph_member_allows(
  p_graph_id uuid,
  p_project_id uuid,
  p_access text
)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = pg_catalog, aep
AS $function$
  SELECT COALESCE(bool_or(
    graph_row.status = 'active'
    AND member_row.member_status = 'active'
    AND (
      (
        member_row.access_mode = 'owner'
        AND member_row.project_id = graph_row.owner_project_id
        AND member_row.grant_decision_id IS NULL
      )
      OR
      (
        graph_row.graph_scope = 'shared'
        AND member_row.access_mode IN ('read', 'write')
        AND decision.status = 'approved'
        AND decision.scope_type = 'project'
        AND decision.scope_key = member_row.project_id::text
        AND decision.decision_key =
          'dependency_graph:' || member_row.graph_id::text || ':' || member_row.access_mode
        AND (
          (p_access = 'read' AND member_row.access_mode IN ('read', 'write'))
          OR (p_access = 'write' AND member_row.access_mode = 'write')
        )
      )
    )
    AND (
      member_row.access_mode = 'owner'
      OR (
        graph_row.graph_scope = 'shared'
        AND member_row.access_mode IN ('read', 'write')
        AND decision.status = 'approved'
        AND decision.scope_type = 'project'
        AND decision.scope_key = member_row.project_id::text
        AND decision.decision_key =
          'dependency_graph:' || member_row.graph_id::text || ':' || member_row.access_mode
      )
    )
  ), false)
  FROM aep.dependency_graphs AS graph_row
  JOIN aep.dependency_graph_members AS member_row
    ON member_row.graph_id = graph_row.graph_id
   AND member_row.project_id = p_project_id
  LEFT JOIN aep.owner_decisions AS decision
    ON decision.decision_id = member_row.grant_decision_id
  WHERE graph_row.graph_id = p_graph_id
    AND (
      (p_access = 'read' AND member_row.access_mode IN ('owner', 'read', 'write'))
      OR (p_access = 'write' AND member_row.access_mode IN ('owner', 'write'))
    )
$function$;

CREATE FUNCTION aep.work_dependencies_satisfied(p_work_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SET search_path = pg_catalog, aep
AS $function$
DECLARE
  v_decision_id uuid;
BEGIN
  -- Lock every grant row after the graph and Work locks. OwnerDecision changes
  -- cannot race an eligibility decision; its guard rejects changes still in use.
  FOR v_decision_id IN
    SELECT DISTINCT member_row.grant_decision_id
    FROM aep.work_relations AS relation_row
    JOIN aep.works AS source_work
      ON source_work.work_id = relation_row.source_work_id
    JOIN aep.works AS target_work
      ON target_work.work_id = relation_row.target_work_id
    JOIN aep.dependency_graph_members AS member_row
      ON member_row.graph_id = relation_row.dependency_graph_id
     AND member_row.project_id IN (source_work.project_id, target_work.project_id)
     AND member_row.member_status = 'active'
    WHERE relation_row.source_work_id = p_work_id
      AND relation_row.relation_type = 'depends_on'
      AND relation_row.status = 'active'
      AND member_row.grant_decision_id IS NOT NULL
    ORDER BY member_row.grant_decision_id
  LOOP
    PERFORM 1
    FROM aep.owner_decisions AS decision
    WHERE decision.decision_id = v_decision_id
    FOR SHARE;
  END LOOP;

  RETURN NOT EXISTS (
    SELECT 1
    FROM aep.work_relations AS relation_row
    JOIN aep.works AS source_work
      ON source_work.work_id = relation_row.source_work_id
    JOIN aep.works AS target_work
      ON target_work.work_id = relation_row.target_work_id
    LEFT JOIN aep.dependency_graph_works AS source_membership
      ON source_membership.graph_id = relation_row.dependency_graph_id
     AND source_membership.work_id = relation_row.source_work_id
    LEFT JOIN aep.dependency_graph_works AS target_membership
      ON target_membership.graph_id = relation_row.dependency_graph_id
     AND target_membership.work_id = relation_row.target_work_id
    WHERE relation_row.source_work_id = p_work_id
      AND relation_row.relation_type = 'depends_on'
      AND relation_row.status = 'active'
      AND (
        target_work.status NOT IN ('delivered', 'accepted', 'completed')
        OR source_membership.membership_status IS DISTINCT FROM 'active'
        OR target_membership.membership_status IS DISTINCT FROM 'active'
        OR NOT aep.dependency_graph_member_allows(
          relation_row.dependency_graph_id, source_work.project_id, 'write'
        )
        OR NOT aep.dependency_graph_member_allows(
          relation_row.dependency_graph_id, target_work.project_id, 'read'
        )
      )
  );
END
$function$;

CREATE FUNCTION aep.refresh_dependency_readiness(p_source_work_ids uuid[])
RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog, aep
AS $function$
DECLARE
  v_work_id uuid;
  v_status text;
  v_dependency_blocked boolean;
  v_satisfied boolean;
  v_now timestamptz;
BEGIN
  IF p_source_work_ids IS NULL OR cardinality(p_source_work_ids) = 0 THEN
    RETURN;
  END IF;

  v_now := clock_timestamp();
  FOR v_work_id IN
    SELECT DISTINCT unnest(p_source_work_ids) AS work_id
    ORDER BY work_id
  LOOP
    SELECT work_row.status, work_row.dependency_blocked
      INTO v_status, v_dependency_blocked
    FROM aep.works AS work_row
    WHERE work_row.work_id = v_work_id;

    IF NOT FOUND THEN
      CONTINUE;
    END IF;

    v_satisfied := aep.work_dependencies_satisfied(v_work_id);

    IF v_status = 'ready' AND NOT v_satisfied THEN
      UPDATE aep.works
      SET status = 'blocked',
          dependency_blocked = true,
          version = version + 1,
          updated_at = v_now
      WHERE work_id = v_work_id
        AND status = 'ready';
    ELSIF v_status = 'blocked'
       AND v_dependency_blocked
       AND v_satisfied THEN
      UPDATE aep.works
      SET status = 'ready',
          dependency_blocked = false,
          version = version + 1,
          updated_at = v_now
      WHERE work_id = v_work_id
        AND status = 'blocked'
        AND dependency_blocked;
    END IF;
  END LOOP;
END
$function$;

CREATE FUNCTION aep.create_project_default_dependency_graph()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, aep
AS $function$
DECLARE
  v_graph_id uuid;
BEGIN
  INSERT INTO aep.dependency_graphs(graph_scope, owner_project_id, status, is_default)
  VALUES ('project', NEW.project_id, 'active', true)
  RETURNING graph_id INTO v_graph_id;

  INSERT INTO aep.dependency_graph_members(
    graph_id, project_id, access_mode, member_status
  ) VALUES (v_graph_id, NEW.project_id, 'owner', 'active');

  RETURN NEW;
END
$function$;

CREATE TRIGGER projects_default_dependency_graph
AFTER INSERT ON aep.projects
FOR EACH ROW EXECUTE FUNCTION aep.create_project_default_dependency_graph();

CREATE FUNCTION aep.attach_work_dependency_graph_memberships()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, aep
AS $function$
BEGIN
  -- Membership changes take the Project row FOR UPDATE. A new Work takes it
  -- FOR SHARE before reading memberships, closing the insert-vs-join race.
  PERFORM 1
  FROM aep.projects AS project_row
  WHERE project_row.project_id = NEW.project_id
  FOR SHARE;

  INSERT INTO aep.dependency_graph_works(graph_id, work_id, membership_status)
  SELECT member_row.graph_id, NEW.work_id, 'active'
  FROM aep.dependency_graph_members AS member_row
  WHERE member_row.project_id = NEW.project_id
    AND member_row.member_status = 'active'
  ON CONFLICT (graph_id, work_id) DO UPDATE
    SET membership_status = 'active',
        removed_at = NULL;

  RETURN NEW;
END
$function$;

CREATE TRIGGER works_dependency_graph_memberships
AFTER INSERT ON aep.works
FOR EACH ROW EXECUTE FUNCTION aep.attach_work_dependency_graph_memberships();

CREATE FUNCTION aep.sync_dependency_graph_member_works()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, aep
AS $function$
BEGIN
  IF NEW.member_status = 'active' THEN
    INSERT INTO aep.dependency_graph_works(graph_id, work_id, membership_status)
    SELECT NEW.graph_id, work_row.work_id, 'active'
    FROM aep.works AS work_row
    WHERE work_row.project_id = NEW.project_id
    ON CONFLICT (graph_id, work_id) DO UPDATE
      SET membership_status = 'active',
          removed_at = NULL;
  ELSE
    UPDATE aep.dependency_graph_works
    SET membership_status = 'removed',
        removed_at = COALESCE(removed_at, clock_timestamp())
    WHERE graph_id = NEW.graph_id
      AND work_id IN (
        SELECT work_row.work_id FROM aep.works AS work_row
        WHERE work_row.project_id = NEW.project_id
      )
      AND membership_status = 'active';
  END IF;
  RETURN NEW;
END
$function$;

CREATE TRIGGER dependency_graph_members_sync_works
AFTER INSERT OR UPDATE OF member_status ON aep.dependency_graph_members
FOR EACH ROW EXECUTE FUNCTION aep.sync_dependency_graph_member_works();

CREATE FUNCTION aep.create_dependency_graph(p_owner_project_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, aep
AS $function$
DECLARE
  v_project_status text;
  v_graph_id uuid;
BEGIN
  SELECT project_row.status INTO v_project_status
  FROM aep.projects AS project_row
  WHERE project_row.project_id = p_owner_project_id
  FOR UPDATE;

  IF NOT FOUND OR v_project_status <> 'active' THEN
    RAISE EXCEPTION 'Shared graph owner project must be active'
      USING ERRCODE = '55000';
  END IF;

  INSERT INTO aep.dependency_graphs(graph_scope, owner_project_id, status, is_default)
  VALUES ('shared', p_owner_project_id, 'active', false)
  RETURNING graph_id INTO v_graph_id;

  INSERT INTO aep.dependency_graph_members(
    graph_id, project_id, access_mode, member_status
  ) VALUES (v_graph_id, p_owner_project_id, 'owner', 'active');

  RETURN v_graph_id;
END
$function$;

CREATE FUNCTION aep.set_dependency_graph_member(
  p_graph_id uuid,
  p_project_id uuid,
  p_access_mode text,
  p_grant_decision_id uuid DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, aep
AS $function$
DECLARE
  v_graph aep.dependency_graphs%ROWTYPE;
  v_member aep.dependency_graph_members%ROWTYPE;
  v_project_status text;
  v_decision aep.owner_decisions%ROWTYPE;
  v_source_ids uuid[];
  v_lock_ids uuid[];
  v_work_id uuid;
  v_graph_version bigint;
  v_member_exists boolean := false;
  v_now timestamptz := clock_timestamp();
BEGIN
  IF p_graph_id IS NULL OR p_project_id IS NULL THEN
    RAISE EXCEPTION 'graph_id and project_id are required' USING ERRCODE = '22004';
  END IF;
  IF p_access_mode IS NOT NULL AND p_access_mode NOT IN ('read', 'write') THEN
    RAISE EXCEPTION 'external graph membership access must be read, write, or NULL to revoke'
      USING ERRCODE = '22023';
  END IF;

  SELECT graph_row.* INTO v_graph
  FROM aep.dependency_graphs AS graph_row
  WHERE graph_row.graph_id = p_graph_id
  FOR UPDATE;

  IF NOT FOUND OR v_graph.status <> 'active' OR v_graph.graph_scope <> 'shared' THEN
    RAISE EXCEPTION 'Only an active shared graph accepts external project membership'
      USING ERRCODE = '55000';
  END IF;
  IF p_project_id = v_graph.owner_project_id THEN
    RAISE EXCEPTION 'Shared graph owner membership is immutable'
      USING ERRCODE = '55000';
  END IF;

  SELECT project_row.status INTO v_project_status
  FROM aep.projects AS project_row
  WHERE project_row.project_id = p_project_id
  FOR UPDATE;
  IF NOT FOUND OR v_project_status <> 'active' THEN
    RAISE EXCEPTION 'Shared graph member project must be active'
      USING ERRCODE = '55000';
  END IF;

  SELECT COALESCE(array_agg(DISTINCT relation_row.source_work_id
                            ORDER BY relation_row.source_work_id), ARRAY[]::uuid[])
  INTO v_source_ids
  FROM aep.work_relations AS relation_row
  JOIN aep.works AS source_work
    ON source_work.work_id = relation_row.source_work_id
  JOIN aep.works AS target_work
    ON target_work.work_id = relation_row.target_work_id
  WHERE relation_row.dependency_graph_id = p_graph_id
    AND relation_row.relation_type = 'depends_on'
    AND relation_row.status = 'active'
    AND (
      source_work.project_id = p_project_id
      OR target_work.project_id = p_project_id
    );

  IF EXISTS (
    SELECT 1 FROM aep.works AS source_work
    WHERE source_work.work_id = ANY(v_source_ids)
      AND source_work.status = 'running'
  ) THEN
    RAISE EXCEPTION 'Cannot change shared graph authority while an affected source Work is running'
      USING ERRCODE = '55000';
  END IF;

  SELECT COALESCE(array_agg(work_id ORDER BY work_id), ARRAY[]::uuid[])
  INTO v_lock_ids
  FROM (
    SELECT work_row.work_id
    FROM aep.works AS work_row
    WHERE work_row.project_id = p_project_id
    UNION
    SELECT unnest(v_source_ids)
  ) AS affected;

  FOR v_work_id IN
    SELECT unnest(v_lock_ids) AS work_id
    ORDER BY work_id
  LOOP
    PERFORM 1 FROM aep.works AS work_row
    WHERE work_row.work_id = v_work_id
    FOR UPDATE;
  END LOOP;

  SELECT member_row.* INTO v_member
  FROM aep.dependency_graph_members AS member_row
  WHERE member_row.graph_id = p_graph_id
    AND member_row.project_id = p_project_id
  FOR UPDATE;

  v_member_exists := FOUND;

  IF p_access_mode IS NULL THEN
    IF NOT v_member_exists OR v_member.member_status = 'revoked' THEN
      RAISE EXCEPTION 'Shared graph project is not an active member'
        USING ERRCODE = '55000';
    END IF;
    UPDATE aep.dependency_graph_members
    SET member_status = 'revoked',
        revoked_at = v_now
    WHERE graph_id = p_graph_id
      AND project_id = p_project_id;
  ELSE
    IF p_grant_decision_id IS NULL THEN
      RAISE EXCEPTION 'Shared graph read/write access requires an approved OwnerDecision'
        USING ERRCODE = '55000';
    END IF;

    SELECT decision.* INTO v_decision
    FROM aep.owner_decisions AS decision
    WHERE decision.decision_id = p_grant_decision_id
    FOR SHARE;

    IF NOT FOUND
       OR v_decision.status <> 'approved'
       OR v_decision.scope_type <> 'project'
       OR v_decision.scope_key <> p_project_id::text
       OR v_decision.decision_key <>
          'dependency_graph:' || p_graph_id::text || ':' || p_access_mode THEN
      RAISE EXCEPTION 'Shared graph OwnerDecision must be approved and scoped to this project, graph, and access mode'
        USING ERRCODE = '55000';
    END IF;

    IF v_member_exists
       AND v_member.member_status = 'active'
       AND v_member.access_mode = p_access_mode
       AND v_member.grant_decision_id = p_grant_decision_id THEN
      SELECT graph_row.graph_version INTO v_graph_version
      FROM aep.dependency_graphs AS graph_row
      WHERE graph_row.graph_id = p_graph_id;
      RETURN v_graph_version;
    END IF;

    INSERT INTO aep.dependency_graph_members(
      graph_id, project_id, access_mode, grant_decision_id, member_status, revoked_at
    ) VALUES (
      p_graph_id, p_project_id, p_access_mode, p_grant_decision_id, 'active', NULL
    )
    ON CONFLICT (graph_id, project_id) DO UPDATE
      SET access_mode = EXCLUDED.access_mode,
          grant_decision_id = EXCLUDED.grant_decision_id,
          member_status = 'active',
          revoked_at = NULL;
  END IF;

  UPDATE aep.dependency_graphs
  SET graph_version = graph_version + 1
  WHERE graph_id = p_graph_id
  RETURNING graph_version INTO v_graph_version;

  PERFORM aep.refresh_dependency_readiness(v_source_ids);
  RETURN v_graph_version;
END
$function$;

CREATE FUNCTION aep.mutate_dependencies(
  p_graph_id uuid,
  p_request_key text,
  p_operations jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, aep
AS $function$
DECLARE
  v_graph aep.dependency_graphs%ROWTYPE;
  v_saved aep.dependency_graph_operations%ROWTYPE;
  v_item jsonb;
  v_action text;
  v_source_id uuid;
  v_target_id uuid;
  v_source_project uuid;
  v_target_project uuid;
  v_source_status text;
  v_work_id uuid;
  v_work_ids uuid[];
  v_source_ids uuid[];
  v_changed boolean := false;
  v_added integer := 0;
  v_removed integer := 0;
  v_rows integer;
  v_version bigint;
  v_result jsonb;
  v_cycle boolean;
  v_now timestamptz := clock_timestamp();
BEGIN
  IF p_graph_id IS NULL OR p_request_key IS NULL
     OR length(btrim(p_request_key)) NOT BETWEEN 1 AND 160
     OR p_operations IS NULL OR jsonb_typeof(p_operations) <> 'array'
     OR jsonb_array_length(p_operations) NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'graph_id, request key and 1..100 dependency operations are required'
      USING ERRCODE = '22023';
  END IF;

  SELECT graph_row.* INTO v_graph
  FROM aep.dependency_graphs AS graph_row
  WHERE graph_row.graph_id = p_graph_id
  FOR UPDATE;

  IF NOT FOUND OR v_graph.status <> 'active' THEN
    RAISE EXCEPTION 'Dependency graph is not active'
      USING ERRCODE = '55000';
  END IF;

  SELECT operation_row.* INTO v_saved
  FROM aep.dependency_graph_operations AS operation_row
  WHERE operation_row.graph_id = p_graph_id
    AND operation_row.request_key = p_request_key
  FOR UPDATE;

  IF FOUND THEN
    IF v_saved.request_payload IS DISTINCT FROM p_operations THEN
      RAISE EXCEPTION 'Dependency operation request key was reused with a different payload'
        USING ERRCODE = '22000';
    END IF;
    RETURN v_saved.result_payload;
  END IF;

  SELECT COALESCE(array_agg(work_id ORDER BY work_id), ARRAY[]::uuid[])
  INTO v_work_ids
  FROM (
    SELECT DISTINCT endpoint.work_id
    FROM jsonb_array_elements(p_operations) AS element(value)
    CROSS JOIN LATERAL (
      VALUES ((element.value->>'source_work_id')::uuid),
             ((element.value->>'target_work_id')::uuid)
    ) AS endpoint(work_id)
  ) AS endpoints;

  FOR v_work_id IN
    SELECT unnest(v_work_ids) AS work_id
    ORDER BY work_id
  LOOP
    PERFORM 1
    FROM aep.works AS work_row
    WHERE work_row.work_id = v_work_id
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Dependency operation references an unknown Work'
        USING ERRCODE = '23503';
    END IF;
  END LOOP;

  FOR v_item IN SELECT element.value FROM jsonb_array_elements(p_operations) AS element(value)
  LOOP
    IF jsonb_typeof(v_item) <> 'object' THEN
      RAISE EXCEPTION 'Every dependency operation must be a JSON object'
        USING ERRCODE = '22023';
    END IF;

    v_action := v_item->>'op';
    v_source_id := NULLIF(v_item->>'source_work_id', '')::uuid;
    v_target_id := NULLIF(v_item->>'target_work_id', '')::uuid;

    IF v_action IS NULL OR v_action NOT IN ('add', 'remove')
       OR v_source_id IS NULL OR v_target_id IS NULL
       OR v_source_id = v_target_id THEN
      RAISE EXCEPTION 'Dependency operation requires op=add/remove and distinct source/target Work IDs'
        USING ERRCODE = '22023';
    END IF;

    SELECT source_work.project_id, target_work.project_id,
           source_work.status
      INTO v_source_project, v_target_project, v_source_status
    FROM aep.works AS source_work
    JOIN aep.works AS target_work ON target_work.work_id = v_target_id
    WHERE source_work.work_id = v_source_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Dependency operation endpoint disappeared'
        USING ERRCODE = '40001';
    END IF;

    IF v_source_status IS NULL THEN
      RAISE EXCEPTION 'Dependency source Work state could not be read'
        USING ERRCODE = '40001';
    END IF;

    -- A dependency set is immutable after execution begins. Otherwise a Work
    -- could be made RUNNING while its active attempt is acquiring new blockers.
    IF v_source_status NOT IN ('proposed', 'ready', 'blocked') THEN
      RAISE EXCEPTION 'Cannot mutate dependencies unless the source Work is proposed, READY, or blocked'
        USING ERRCODE = '55000';
    END IF;

    IF v_action = 'add' THEN
      IF NOT EXISTS (
        SELECT 1 FROM aep.dependency_graph_works AS membership
        WHERE membership.graph_id = p_graph_id
          AND membership.work_id = v_source_id
          AND membership.membership_status = 'active'
      ) OR NOT EXISTS (
        SELECT 1 FROM aep.dependency_graph_works AS membership
        WHERE membership.graph_id = p_graph_id
          AND membership.work_id = v_target_id
          AND membership.membership_status = 'active'
      ) THEN
        RAISE EXCEPTION 'Both dependency endpoints must actively belong to the graph'
          USING ERRCODE = '55000';
      END IF;


      IF NOT aep.dependency_graph_member_allows(p_graph_id, v_source_project, 'write')
         OR NOT aep.dependency_graph_member_allows(p_graph_id, v_target_project, 'read') THEN
        RAISE EXCEPTION 'Dependency graph membership or approved OwnerDecision does not authorize this edge'
          USING ERRCODE = '42501';
      END IF;

      WITH RECURSIVE reachable(work_id) AS (
        SELECT v_target_id
        UNION
        SELECT relation_row.target_work_id
        FROM reachable
        JOIN aep.work_relations AS relation_row
          ON relation_row.source_work_id = reachable.work_id
        WHERE relation_row.dependency_graph_id = p_graph_id
          AND relation_row.relation_type = 'depends_on'
          AND relation_row.status = 'active'
      )
      SELECT EXISTS (
        SELECT 1 FROM reachable WHERE work_id = v_source_id
      ) INTO v_cycle;

      IF v_cycle THEN
        RAISE EXCEPTION 'Dependency edge would create a directed cycle'
          USING ERRCODE = '23514';
      END IF;

      INSERT INTO aep.work_relations(
        source_work_id, target_work_id, relation_type, dependency_graph_id, status
      ) VALUES (
        v_source_id, v_target_id, 'depends_on', p_graph_id, 'active'
      )
      ON CONFLICT (
        source_work_id, target_work_id, relation_type, dependency_graph_id
      ) WHERE status = 'active' AND relation_type = 'depends_on'
      DO NOTHING;

      GET DIAGNOSTICS v_rows = ROW_COUNT;
      IF v_rows > 0 THEN
        v_changed := true;
        v_added := v_added + 1;
      END IF;
    ELSE
      -- Graph owner or the source project's current write membership may
      -- remove an edge. A revoked source remains cleanable by the graph owner.
      IF NOT EXISTS (
        SELECT 1 FROM aep.dependency_graph_works AS membership
        WHERE membership.graph_id = p_graph_id
          AND membership.work_id = v_source_id
      ) OR NOT EXISTS (
        SELECT 1 FROM aep.dependency_graph_works AS membership
        WHERE membership.graph_id = p_graph_id
          AND membership.work_id = v_target_id
      ) THEN
        RAISE EXCEPTION 'Dependency removal endpoints have no graph membership history'
          USING ERRCODE = '55000';
      END IF;

      IF NOT aep.dependency_graph_member_allows(
        p_graph_id, v_source_project, 'write'
      ) AND NOT aep.dependency_graph_member_allows(
        p_graph_id, v_graph.owner_project_id, 'write'
      ) THEN
        RAISE EXCEPTION 'Dependency removal requires source write or graph-owner authority'
          USING ERRCODE = '42501';
      END IF;

      UPDATE aep.work_relations
      SET status = 'removed',
          removed_at = v_now
      WHERE source_work_id = v_source_id
        AND target_work_id = v_target_id
        AND relation_type = 'depends_on'
        AND dependency_graph_id = p_graph_id
        AND status = 'active';

      GET DIAGNOSTICS v_rows = ROW_COUNT;
      IF v_rows > 0 THEN
        v_changed := true;
        v_removed := v_removed + v_rows;
      END IF;
    END IF;
  END LOOP;

  SELECT COALESCE(array_agg(DISTINCT (element.value->>'source_work_id')::uuid
                            ORDER BY (element.value->>'source_work_id')::uuid),
                  ARRAY[]::uuid[])
  INTO v_source_ids
  FROM jsonb_array_elements(p_operations) AS element(value);

  IF v_changed THEN
    UPDATE aep.dependency_graphs
    SET graph_version = graph_version + 1
    WHERE graph_id = p_graph_id
    RETURNING graph_version INTO v_version;

    PERFORM aep.refresh_dependency_readiness(v_source_ids);
  ELSE
    v_version := v_graph.graph_version;
  END IF;

  v_result := jsonb_build_object(
    'graph_id', p_graph_id,
    'graph_version', v_version,
    'changed', v_changed,
    'added', v_added,
    'removed', v_removed
  );

  INSERT INTO aep.dependency_graph_operations(
    graph_id, request_key, request_payload, result_payload, graph_version
  ) VALUES (
    p_graph_id, p_request_key, p_operations, v_result, v_version
  );

  RETURN v_result;
END
$function$;

CREATE FUNCTION aep.set_work_ready(p_work_id uuid)
RETURNS TABLE(work_status text, work_version bigint)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, aep
AS $function$
DECLARE
  v_graph_ids uuid[];
  v_current_graph_ids uuid[];
  v_work aep.works%ROWTYPE;
  v_status text;
  v_version bigint;
  v_now timestamptz := clock_timestamp();
BEGIN
  IF p_work_id IS NULL THEN
    RAISE EXCEPTION 'work_id is required' USING ERRCODE = '22004';
  END IF;

  v_graph_ids := aep.lock_work_dependency_graphs(p_work_id, 'share');

  SELECT work_row.* INTO v_work
  FROM aep.works AS work_row
  WHERE work_row.work_id = p_work_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Work does not exist' USING ERRCODE = '23503';
  END IF;

  v_current_graph_ids := aep.current_work_dependency_graphs(p_work_id);
  IF v_current_graph_ids IS DISTINCT FROM v_graph_ids THEN
    RAISE EXCEPTION 'Work dependency graph membership changed; retry the transaction'
      USING ERRCODE = '40001';
  END IF;

  IF v_work.status NOT IN ('proposed', 'ready')
     AND NOT (v_work.status = 'blocked' AND v_work.dependency_blocked) THEN
    RAISE EXCEPTION 'Only proposed, READY, or dependency-blocked Work can be made READY'
      USING ERRCODE = '55000';
  END IF;

  IF aep.work_dependencies_satisfied(p_work_id) THEN
    v_status := 'ready';
    UPDATE aep.works
    SET status = 'ready',
        dependency_blocked = false,
        version = version + 1,
        updated_at = v_now
    WHERE work_id = p_work_id
    RETURNING version INTO v_version;
  ELSE
    v_status := 'blocked';
    UPDATE aep.works
    SET status = 'blocked',
        dependency_blocked = true,
        version = version + 1,
        updated_at = v_now
    WHERE work_id = p_work_id
    RETURNING version INTO v_version;
  END IF;

  RETURN QUERY SELECT v_status, v_version;
END
$function$;

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
  v_graph_ids uuid[];
  v_current_graph_ids uuid[];
BEGIN
  IF p_work_id IS NULL OR p_session_id IS NULL THEN
    RAISE EXCEPTION 'work_id and session_id are required' USING ERRCODE = '22004';
  END IF;
  IF p_lease_seconds IS NULL OR p_lease_seconds NOT BETWEEN 1 AND 86400 THEN
    RAISE EXCEPTION 'lease_seconds must be between 1 and 86400'
      USING ERRCODE = '22023';
  END IF;

  v_graph_ids := aep.lock_work_dependency_graphs(p_work_id, 'share');

  SELECT work_row.* INTO v_work
  FROM aep.works AS work_row
  WHERE work_row.work_id = p_work_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Work does not exist' USING ERRCODE = '23503';
  END IF;

  v_current_graph_ids := aep.current_work_dependency_graphs(p_work_id);
  IF v_current_graph_ids IS DISTINCT FROM v_graph_ids THEN
    RAISE EXCEPTION 'Work dependency graph membership changed; retry the transaction'
      USING ERRCODE = '40001';
  END IF;

  SELECT project_row.status INTO v_project_status
  FROM aep.projects AS project_row
  WHERE project_row.project_id = v_work.project_id
  FOR SHARE;

  IF NOT FOUND OR v_project_status <> 'active' THEN
    RAISE EXCEPTION 'Work project is not active' USING ERRCODE = '55000';
  END IF;

  -- READY is a projection. The graph SHARE locks above are the same
  -- serialization boundary used by graph mutation and prerequisite completion.
  IF NOT aep.work_dependencies_satisfied(p_work_id) THEN
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
  v_graph_ids uuid[];
  v_current_graph_ids uuid[];
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

  v_graph_ids := aep.lock_work_dependency_graphs(p_work_id, 'share');

  SELECT work_row.* INTO v_work
  FROM aep.works AS work_row
  WHERE work_row.work_id = p_work_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Work does not exist' USING ERRCODE = '23503';
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
  v_graph_ids uuid[];
  v_current_graph_ids uuid[];
  v_dependent_ids uuid[];
  v_lock_ids uuid[];
  v_lock_work_id uuid;
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

  v_graph_ids := aep.lock_work_dependency_graphs(p_work_id, 'update');

  SELECT COALESCE(array_agg(DISTINCT relation_row.source_work_id ORDER BY relation_row.source_work_id),
                  ARRAY[]::uuid[])
  INTO v_dependent_ids
  FROM aep.work_relations AS relation_row
  WHERE relation_row.relation_type = 'depends_on'
    AND relation_row.status = 'active'
    AND relation_row.target_work_id = p_work_id
    AND relation_row.dependency_graph_id = ANY(v_graph_ids);

  SELECT COALESCE(array_agg(work_id ORDER BY work_id), ARRAY[]::uuid[])
  INTO v_lock_ids
  FROM (
    SELECT p_work_id AS work_id
    UNION
    SELECT unnest(v_dependent_ids)
    UNION
    SELECT relation_row.target_work_id AS work_id
    FROM aep.work_relations AS relation_row
    WHERE relation_row.source_work_id = p_work_id
      AND relation_row.relation_type = 'parent_child'
      AND relation_row.required IS TRUE
      AND relation_row.status = 'active'
  ) AS affected;

  -- Graph rows are already locked. All affected Work rows are then acquired
  -- in UUID order before the Execution row, preserving one global lock order.
  FOR v_lock_work_id IN
    SELECT unnest(v_lock_ids) AS work_id
    ORDER BY work_id
  LOOP
    PERFORM 1
    FROM aep.works AS work_row
    WHERE work_row.work_id = v_lock_work_id
    FOR UPDATE;
  END LOOP;

  SELECT work_row.* INTO v_work
  FROM aep.works AS work_row
  WHERE work_row.work_id = p_work_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Work does not exist' USING ERRCODE = '23503';
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

  IF p_outcome = 'succeeded' AND EXISTS (
    SELECT 1
    FROM aep.work_relations AS child_relation
    JOIN aep.works AS child_work
      ON child_work.work_id = child_relation.target_work_id
    WHERE child_relation.source_work_id = p_work_id
      AND child_relation.relation_type = 'parent_child'
      AND child_relation.required IS TRUE
      AND child_relation.status = 'active'
      AND child_work.status NOT IN ('delivered', 'accepted', 'completed')
  ) THEN
    RAISE EXCEPTION 'Parent Work has an unfinished required child'
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

  IF cardinality(v_dependent_ids) > 0 THEN
    PERFORM aep.refresh_dependency_readiness(v_dependent_ids);
  END IF;

  RETURN QUERY SELECT v_work_status, v_work_version;
END
$function$;

-- Extend the Stage 2A OwnerDecision guard. An approved decision remains
-- immutable while any active graph membership references it. Revoke/change
-- graph membership first through set_dependency_graph_member(), which uses
-- the graph lock boundary and updates dependency eligibility.
CREATE OR REPLACE FUNCTION aep.guard_approved_grant_decision_mutation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, aep
AS $function$
DECLARE
  v_decision_id uuid;
BEGIN
  v_decision_id := OLD.decision_id;

  IF OLD.status = 'approved' AND (
    EXISTS (
      SELECT 1
      FROM aep.project_resources AS project_resource
      JOIN aep.resource_claims AS claim
        ON claim.project_id = project_resource.project_id
       AND claim.resource_id = project_resource.resource_id
      WHERE project_resource.grant_decision_id = v_decision_id
        AND claim.status IN ('reserved', 'active')
    )
    OR EXISTS (
      SELECT 1
      FROM aep.dependency_graph_members AS member_row
      WHERE member_row.grant_decision_id = v_decision_id
        AND member_row.member_status = 'active'
    )
  ) THEN
    RAISE EXCEPTION 'Approved OwnerDecision cannot be changed while active resource claims or dependency graph memberships depend on it'
      USING ERRCODE = '55000';
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END
$function$;

-- All new canonical tables are owned by the non-bypass owner role and forced
-- through RLS. Runtime workers receive RPC EXECUTE only, never table DML.
ALTER TABLE aep.dependency_graph_works OWNER TO aep_owner;
ALTER TABLE aep.dependency_graph_operations OWNER TO aep_owner;

DO $aep$
BEGIN
  ALTER TABLE aep.dependency_graph_works ENABLE ROW LEVEL SECURITY;
  ALTER TABLE aep.dependency_graph_works FORCE ROW LEVEL SECURITY;
  CREATE POLICY owner_full_access ON aep.dependency_graph_works
    FOR ALL TO aep_owner USING (true) WITH CHECK (true);

  ALTER TABLE aep.dependency_graph_operations ENABLE ROW LEVEL SECURITY;
  ALTER TABLE aep.dependency_graph_operations FORCE ROW LEVEL SECURITY;
  CREATE POLICY owner_full_access ON aep.dependency_graph_operations
    FOR ALL TO aep_owner USING (true) WITH CHECK (true);
END
$aep$;

ALTER FUNCTION aep.current_work_dependency_graphs(uuid) OWNER TO aep_owner;
ALTER FUNCTION aep.lock_work_dependency_graphs(uuid, text) OWNER TO aep_owner;
ALTER FUNCTION aep.dependency_graph_member_allows(uuid, uuid, text) OWNER TO aep_owner;
ALTER FUNCTION aep.work_dependencies_satisfied(uuid) OWNER TO aep_owner;
ALTER FUNCTION aep.refresh_dependency_readiness(uuid[]) OWNER TO aep_owner;
ALTER FUNCTION aep.create_project_default_dependency_graph() OWNER TO aep_owner;
ALTER FUNCTION aep.attach_work_dependency_graph_memberships() OWNER TO aep_owner;
ALTER FUNCTION aep.sync_dependency_graph_member_works() OWNER TO aep_owner;
ALTER FUNCTION aep.create_dependency_graph(uuid) OWNER TO aep_owner;
ALTER FUNCTION aep.set_dependency_graph_member(uuid, uuid, text, uuid) OWNER TO aep_owner;
ALTER FUNCTION aep.mutate_dependencies(uuid, text, jsonb) OWNER TO aep_owner;
ALTER FUNCTION aep.set_work_ready(uuid) OWNER TO aep_owner;
ALTER FUNCTION aep.claim_work(uuid, uuid, integer) OWNER TO aep_owner;
ALTER FUNCTION aep.renew_execution(uuid, uuid, bigint, bigint, integer) OWNER TO aep_owner;
ALTER FUNCTION aep.finish_execution(uuid, uuid, bigint, bigint, text, jsonb) OWNER TO aep_owner;

REVOKE ALL ON TABLE aep.dependency_graph_works FROM PUBLIC, aep_runtime;
REVOKE ALL ON TABLE aep.dependency_graph_operations FROM PUBLIC, aep_runtime;

REVOKE ALL ON FUNCTION aep.current_work_dependency_graphs(uuid) FROM PUBLIC, aep_runtime;
REVOKE ALL ON FUNCTION aep.lock_work_dependency_graphs(uuid, text) FROM PUBLIC, aep_runtime;
REVOKE ALL ON FUNCTION aep.dependency_graph_member_allows(uuid, uuid, text) FROM PUBLIC, aep_runtime;
REVOKE ALL ON FUNCTION aep.work_dependencies_satisfied(uuid) FROM PUBLIC, aep_runtime;
REVOKE ALL ON FUNCTION aep.refresh_dependency_readiness(uuid[]) FROM PUBLIC, aep_runtime;

REVOKE ALL ON FUNCTION aep.create_project_default_dependency_graph() FROM PUBLIC, aep_runtime;
REVOKE ALL ON FUNCTION aep.attach_work_dependency_graph_memberships() FROM PUBLIC, aep_runtime;
REVOKE ALL ON FUNCTION aep.sync_dependency_graph_member_works() FROM PUBLIC, aep_runtime;

REVOKE ALL ON FUNCTION aep.create_dependency_graph(uuid) FROM PUBLIC, aep_runtime;
REVOKE ALL ON FUNCTION aep.set_dependency_graph_member(uuid, uuid, text, uuid) FROM PUBLIC, aep_runtime;
REVOKE ALL ON FUNCTION aep.mutate_dependencies(uuid, text, jsonb) FROM PUBLIC, aep_runtime;
REVOKE ALL ON FUNCTION aep.set_work_ready(uuid) FROM PUBLIC, aep_runtime;

REVOKE ALL ON FUNCTION aep.claim_work(uuid, uuid, integer) FROM PUBLIC, aep_runtime;
REVOKE ALL ON FUNCTION aep.renew_execution(uuid, uuid, bigint, bigint, integer) FROM PUBLIC, aep_runtime;
REVOKE ALL ON FUNCTION aep.finish_execution(uuid, uuid, bigint, bigint, text, jsonb) FROM PUBLIC, aep_runtime;

GRANT EXECUTE ON FUNCTION aep.create_dependency_graph(uuid) TO aep_runtime;
GRANT EXECUTE ON FUNCTION aep.set_dependency_graph_member(uuid, uuid, text, uuid) TO aep_runtime;
GRANT EXECUTE ON FUNCTION aep.mutate_dependencies(uuid, text, jsonb) TO aep_runtime;
GRANT EXECUTE ON FUNCTION aep.set_work_ready(uuid) TO aep_runtime;
GRANT EXECUTE ON FUNCTION aep.claim_work(uuid, uuid, integer) TO aep_runtime;
GRANT EXECUTE ON FUNCTION aep.renew_execution(uuid, uuid, bigint, bigint, integer) TO aep_runtime;
GRANT EXECUTE ON FUNCTION aep.finish_execution(uuid, uuid, bigint, bigint, text, jsonb) TO aep_runtime;

COMMIT;
