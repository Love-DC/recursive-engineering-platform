-- Stage 4B: authorized, source-pinned Context Compiler and disposable Context Packs.
-- Prototype-only PostgreSQL. Never apply to production Supabase or legacy RAE.
BEGIN;

-- Store only bounded-size metadata beside the append-only Evidence Ledger.
-- The Context Compiler can select eligible IDs without deserializing payload JSON.
CREATE TABLE aep.context_evidence_sizes (
  evidence_id uuid PRIMARY KEY REFERENCES aep.evidence(evidence_id),
  project_id uuid NOT NULL REFERENCES aep.projects(project_id),
  work_id uuid,
  evidence_type text NOT NULL,
  observed_at timestamptz NOT NULL,
  payload_bytes bigint NOT NULL CHECK (payload_bytes >= 0),
  provenance_bytes bigint NOT NULL CHECK (provenance_bytes >= 0),
  evidence_type_bytes bigint NOT NULL CHECK (evidence_type_bytes >= 0),
  source_ref_bytes bigint NOT NULL CHECK (source_ref_bytes >= 0),
  source_revision_bytes bigint NOT NULL CHECK (source_revision_bytes >= 0)
);

INSERT INTO aep.context_evidence_sizes(
  evidence_id,project_id,work_id,evidence_type,observed_at,payload_bytes,provenance_bytes,
  evidence_type_bytes,source_ref_bytes,source_revision_bytes
)
SELECT evidence_id,project_id,work_id,evidence_type,observed_at,
       octet_length(payload::text),octet_length(provenance::text),
       octet_length(to_jsonb(evidence_type)::text),
       octet_length(to_jsonb(source_ref)::text),
       COALESCE(octet_length(to_jsonb(source_revision)::text),4)
FROM aep.evidence;

CREATE INDEX evidence_context_snapshot_idx
  ON aep.context_evidence_sizes(project_id, work_id, observed_at DESC, evidence_id)
  INCLUDE (evidence_type, payload_bytes, provenance_bytes,
           evidence_type_bytes, source_ref_bytes, source_revision_bytes);

CREATE FUNCTION aep.capture_context_evidence_sizes()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, aep
AS $function$
BEGIN
  INSERT INTO aep.context_evidence_sizes(
    evidence_id,project_id,work_id,evidence_type,observed_at,payload_bytes,provenance_bytes,
    evidence_type_bytes,source_ref_bytes,source_revision_bytes
  ) VALUES (
    NEW.evidence_id,NEW.project_id,NEW.work_id,NEW.evidence_type,NEW.observed_at,
    octet_length(NEW.payload::text),octet_length(NEW.provenance::text),
    octet_length(to_jsonb(NEW.evidence_type)::text),
    octet_length(to_jsonb(NEW.source_ref)::text),
    COALESCE(octet_length(to_jsonb(NEW.source_revision)::text),4)
  );
  RETURN NEW;
END
$function$;

CREATE TRIGGER evidence_context_size_after_insert
AFTER INSERT ON aep.evidence
FOR EACH ROW EXECUTE FUNCTION aep.capture_context_evidence_sizes();

-- A mutable latest-observation pointer is derived from append-only Evidence rows.
-- It is scoped by Work, physical repository and branch ref, not by a session label.
CREATE TABLE aep.context_source_heads (
  project_id uuid NOT NULL,
  work_id uuid NOT NULL,
  resource_id uuid NOT NULL,
  resource_ref text NOT NULL CHECK (length(btrim(resource_ref)) BETWEEN 1 AND 255),
  source_version bigint NOT NULL CHECK (source_version > 0),
  commit_sha text NOT NULL CHECK (commit_sha ~ '^([0-9a-f]{40}|[0-9a-f]{64})$'),
  tree_sha text NOT NULL CHECK (tree_sha ~ '^([0-9a-f]{40}|[0-9a-f]{64})$'),
  content_sha256 text NOT NULL CHECK (content_sha256 ~ '^[0-9a-f]{64}$'),
  provenance jsonb NOT NULL CHECK (jsonb_typeof(provenance) = 'object'),
  evidence_id uuid NOT NULL REFERENCES aep.evidence(evidence_id),
  observed_by_session_id uuid NOT NULL,
  observed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (project_id, work_id, resource_id, resource_ref),
  FOREIGN KEY (project_id, work_id) REFERENCES aep.works(project_id, work_id),
  FOREIGN KEY (project_id, resource_id) REFERENCES aep.project_resources(project_id, resource_id)
);

CREATE INDEX context_source_heads_work_idx
  ON aep.context_source_heads(work_id, observed_at DESC);

CREATE TABLE aep.context_packs (
  pack_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  cache_key text NOT NULL UNIQUE CHECK (cache_key ~ '^[0-9a-f]{64}$'),
  project_id uuid NOT NULL,
  work_id uuid NOT NULL,
  resource_id uuid NOT NULL,
  resource_ref text NOT NULL,
  source_version bigint NOT NULL CHECK (source_version > 0),
  work_version bigint NOT NULL CHECK (work_version > 0),
  grant_version bigint NOT NULL CHECK (grant_version > 0),
  source_fingerprint text NOT NULL CHECK (source_fingerprint ~ '^[0-9a-f]{64}$'),
  compiler_version text NOT NULL CHECK (length(btrim(compiler_version)) BETWEEN 1 AND 100),
  indexer_version text NOT NULL CHECK (length(btrim(indexer_version)) BETWEEN 1 AND 100),
  config_version text NOT NULL CHECK (length(btrim(config_version)) BETWEEN 1 AND 100),
  token_budget integer NOT NULL CHECK (token_budget BETWEEN 128 AND 100000),
  estimated_tokens integer NOT NULL CHECK (estimated_tokens >= 0 AND estimated_tokens <= token_budget),
  payload_sha256 text NOT NULL CHECK (payload_sha256 ~ '^[0-9a-f]{64}$'),
  payload jsonb NOT NULL CHECK (jsonb_typeof(payload) = 'object'),
  created_by_session_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  FOREIGN KEY (project_id, work_id) REFERENCES aep.works(project_id, work_id),
  FOREIGN KEY (project_id, resource_id) REFERENCES aep.project_resources(project_id, resource_id),
  FOREIGN KEY (project_id, work_id, resource_id, resource_ref)
    REFERENCES aep.context_source_heads(project_id, work_id, resource_id, resource_ref)
);

CREATE INDEX context_packs_work_created_idx
  ON aep.context_packs(project_id, work_id, created_at DESC);

-- This audit contains counts only. It deliberately has no source refs, payloads,
-- snippets, hashes, or content columns; denied calls always record zero retrieval.
CREATE TABLE aep.context_retrieval_events (
  event_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  operation text NOT NULL CHECK (operation IN ('record_source','compile','fetch')),
  outcome text NOT NULL CHECK (outcome IN ('denied','recorded','unchanged','compiled','reused','stale')),
  project_id uuid,
  work_id uuid,
  resource_id uuid,
  pack_id uuid,
  session_id uuid,
  source_count integer NOT NULL DEFAULT 0 CHECK (source_count >= 0),
  source_bytes bigint NOT NULL DEFAULT 0 CHECK (source_bytes >= 0),
  occurred_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX context_retrieval_events_scope_idx
  ON aep.context_retrieval_events(project_id, occurred_at DESC);

CREATE FUNCTION aep.reject_context_record_mutation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, aep
AS $function$
BEGIN
  RAISE EXCEPTION '% is append-only; % is forbidden', TG_TABLE_NAME, TG_OP
    USING ERRCODE = '55000';
END
$function$;

CREATE TRIGGER context_evidence_sizes_append_only
BEFORE UPDATE OR DELETE ON aep.context_evidence_sizes
FOR EACH ROW EXECUTE FUNCTION aep.reject_context_record_mutation();


CREATE TRIGGER context_packs_append_only
BEFORE UPDATE OR DELETE ON aep.context_packs
FOR EACH ROW EXECUTE FUNCTION aep.reject_context_record_mutation();

CREATE TRIGGER context_retrieval_events_append_only
BEFORE UPDATE OR DELETE ON aep.context_retrieval_events
FOR EACH ROW EXECUTE FUNCTION aep.reject_context_record_mutation();

-- Resource association membership and resource-scoped decisions/status share a
-- stable resource lock. This lock is always acquired before project locks.
CREATE FUNCTION aep.lock_context_resource(
  p_resource_ids uuid[],
  p_exclusive boolean DEFAULT true
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, aep
AS $function$
DECLARE
  v_resource_id uuid;
BEGIN
  FOR v_resource_id IN
    SELECT DISTINCT resource_id
    FROM unnest(COALESCE(p_resource_ids, ARRAY[]::uuid[])) AS ids(resource_id)
    WHERE resource_id IS NOT NULL
    ORDER BY resource_id
  LOOP
    IF p_exclusive THEN
      PERFORM pg_advisory_xact_lock(
        hashtextextended('aep.context-resource:' || v_resource_id::text, 0)
      );
    ELSE
      PERFORM pg_advisory_xact_lock_shared(
        hashtextextended('aep.context-resource:' || v_resource_id::text, 0)
      );
    END IF;
  END LOOP;
END
$function$;

-- The trusted prototype gate is a persisted project/resource scope check only.
-- It does not authenticate a ChatGPT session or bind a native caller principal.
-- Global lock order is resource advisory lock(s), then sorted project advisory
-- lock(s). This closes association-set races for resource-scoped decisions and
-- Resource mutations while keeping Context readers ahead of all tuple reads.
CREATE FUNCTION aep.lock_context_project_write()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, aep
AS $function$
DECLARE
  v_project_ids uuid[];
  v_project_id uuid;
  v_resource_ids uuid[];
BEGIN
  -- Association writes, physical Resource updates and resource-scoped decisions
  -- serialize on the stable Resource ID before deriving the current project set.
  IF TG_TABLE_NAME IN ('project_resources','resources') THEN
    IF TG_OP <> 'DELETE' THEN
      v_resource_ids := array_append(v_resource_ids, NEW.resource_id);
    END IF;
    IF TG_OP <> 'INSERT' THEN
      v_resource_ids := array_append(v_resource_ids, OLD.resource_id);
    END IF;
  ELSIF TG_TABLE_NAME = 'owner_decisions' THEN
    SELECT array_agg(DISTINCT resource_id ORDER BY resource_id)
    INTO v_resource_ids
    FROM (
      SELECT CASE WHEN TG_OP <> 'INSERT'
        AND OLD.scope_type = 'resource'
        AND length(OLD.scope_key) = 36
        AND OLD.scope_key ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
        THEN OLD.scope_key::uuid END AS resource_id
      UNION
      SELECT CASE WHEN TG_OP <> 'DELETE'
        AND NEW.scope_type = 'resource'
        AND length(NEW.scope_key) = 36
        AND NEW.scope_key ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
        THEN NEW.scope_key::uuid END
    ) AS scoped_resources
    WHERE resource_id IS NOT NULL;
  END IF;

  PERFORM aep.lock_context_resource(v_resource_ids, true);

  IF TG_TABLE_NAME IN (
    'projects','works','evidence','project_resources',
    'context_source_heads'
  ) THEN
    IF TG_OP <> 'DELETE' THEN
      v_project_ids := array_append(v_project_ids, NEW.project_id);
    END IF;
    IF TG_OP <> 'INSERT' THEN
      v_project_ids := array_append(v_project_ids, OLD.project_id);
    END IF;

  ELSIF TG_TABLE_NAME = 'work_relations' THEN
    SELECT array_agg(DISTINCT work_row.project_id ORDER BY work_row.project_id)
    INTO v_project_ids
    FROM aep.works AS work_row
    WHERE work_row.work_id IN (
      SELECT relation_ids.work_id
      FROM unnest(ARRAY[
        CASE WHEN TG_OP <> 'INSERT' THEN OLD.source_work_id END,
        CASE WHEN TG_OP <> 'INSERT' THEN OLD.target_work_id END,
        CASE WHEN TG_OP <> 'DELETE' THEN NEW.source_work_id END,
        CASE WHEN TG_OP <> 'DELETE' THEN NEW.target_work_id END
      ]) AS relation_ids(work_id)
      WHERE relation_ids.work_id IS NOT NULL
    );

  ELSIF TG_TABLE_NAME = 'dependency_graphs' THEN
    SELECT array_agg(DISTINCT member_projects.project_id ORDER BY member_projects.project_id)
    INTO v_project_ids
    FROM (
      SELECT CASE WHEN TG_OP <> 'INSERT' THEN OLD.owner_project_id END AS project_id
      UNION
      SELECT CASE WHEN TG_OP <> 'DELETE' THEN NEW.owner_project_id END
      UNION
      SELECT member_row.project_id
      FROM aep.dependency_graph_members AS member_row
      WHERE member_row.graph_id IN (
        CASE WHEN TG_OP <> 'INSERT' THEN OLD.graph_id END,
        CASE WHEN TG_OP <> 'DELETE' THEN NEW.graph_id END
      )
    ) AS member_projects
    WHERE member_projects.project_id IS NOT NULL;

  ELSIF TG_TABLE_NAME = 'dependency_graph_members' THEN
    SELECT array_agg(DISTINCT member_projects.project_id ORDER BY member_projects.project_id)
    INTO v_project_ids
    FROM (
      SELECT CASE WHEN TG_OP <> 'INSERT' THEN OLD.project_id END AS project_id
      UNION
      SELECT CASE WHEN TG_OP <> 'DELETE' THEN NEW.project_id END
      UNION
      SELECT graph_row.owner_project_id
      FROM aep.dependency_graphs AS graph_row
      WHERE graph_row.graph_id IN (
        CASE WHEN TG_OP <> 'INSERT' THEN OLD.graph_id END,
        CASE WHEN TG_OP <> 'DELETE' THEN NEW.graph_id END
      )
    ) AS member_projects
    WHERE member_projects.project_id IS NOT NULL;

  ELSIF TG_TABLE_NAME = 'owner_decisions' THEN
    SELECT array_agg(DISTINCT scope_projects.project_id ORDER BY scope_projects.project_id)
    INTO v_project_ids
    FROM (
      SELECT project_row.project_id
      FROM aep.projects AS project_row
      WHERE (
        (TG_OP <> 'INSERT' AND OLD.scope_type = 'project'
          AND project_row.project_id::text = OLD.scope_key)
        OR
        (TG_OP <> 'DELETE' AND NEW.scope_type = 'project'
          AND project_row.project_id::text = NEW.scope_key)
      )
      UNION
      SELECT work_row.project_id
      FROM aep.works AS work_row
      WHERE (
        (TG_OP <> 'INSERT' AND OLD.scope_type = 'work'
          AND work_row.work_id::text = OLD.scope_key)
        OR
        (TG_OP <> 'DELETE' AND NEW.scope_type = 'work'
          AND work_row.work_id::text = NEW.scope_key)
      )
      UNION
      SELECT project_resource.project_id
      FROM aep.project_resources AS project_resource
      WHERE (
        (TG_OP <> 'INSERT' AND OLD.scope_type = 'resource'
          AND project_resource.resource_id::text = OLD.scope_key)
        OR
        (TG_OP <> 'DELETE' AND NEW.scope_type = 'resource'
          AND project_resource.resource_id::text = NEW.scope_key)
      )
    ) AS scope_projects;

  ELSIF TG_TABLE_NAME = 'resources' THEN
    SELECT array_agg(DISTINCT project_resource.project_id ORDER BY project_resource.project_id)
    INTO v_project_ids
    FROM aep.project_resources AS project_resource
    WHERE project_resource.resource_id IN (
      CASE WHEN TG_OP <> 'INSERT' THEN OLD.resource_id END,
      CASE WHEN TG_OP <> 'DELETE' THEN NEW.resource_id END
    );
  END IF;

  FOR v_project_id IN
    SELECT DISTINCT project_id
    FROM unnest(COALESCE(v_project_ids, ARRAY[]::uuid[])) AS item(project_id)
    WHERE project_id IS NOT NULL
    ORDER BY project_id
  LOOP
    PERFORM pg_advisory_xact_lock(
      hashtextextended('aep.context-project:' || v_project_id::text, 0)
    );
  END LOOP;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END
$function$;

DO $context_write_locks$
DECLARE
  table_name text;
BEGIN
  FOREACH table_name IN ARRAY ARRAY[
    'projects','works','work_relations','dependency_graphs',
    'dependency_graph_members','owner_decisions','resources',
    'project_resources','work_resource_requirements','evidence',
    'context_source_heads'
  ] LOOP
    EXECUTE format(
      'CREATE TRIGGER context_project_write_lock BEFORE INSERT OR UPDATE OR DELETE ON aep.%I FOR EACH ROW EXECUTE FUNCTION aep.lock_context_project_write()',
      table_name
    );
  END LOOP;
END
$context_write_locks$;

-- WorkResourceRequirement validation historically locked Work, then Resource.
-- Keep that tuple order explicit and acquire Context's Resource/Project advisory
-- locks only after Work is locked, avoiding a project-lock -> Work-tuple cycle.
DROP TRIGGER context_project_write_lock ON aep.work_resource_requirements;

-- ProjectResource writes hold Resource then Project advisory locks before this
-- grant check. Resource-scoped decisions and ProjectResource associations share
-- those locks, so a tuple lock on OwnerDecision is unnecessary and can invert
-- the order (association tuple/resource lock -> decision tuple vs revoker tuple
-- -> Resource lock).
CREATE OR REPLACE FUNCTION aep.guard_project_resource_write_grant()
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
    WHERE decision.decision_id = NEW.grant_decision_id;

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

ALTER FUNCTION aep.guard_project_resource_write_grant() OWNER TO aep_owner;

CREATE OR REPLACE FUNCTION aep.guard_work_resource_requirement()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, aep
AS $function$
DECLARE
  v_work_id uuid;
  v_work aep.works%ROWTYPE;
  v_resource aep.resources%ROWTYPE;
  v_resource_ids uuid[];
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
    v_resource_ids := ARRAY[OLD.resource_id];
  ELSE
    v_work_id := NEW.work_id;
    v_resource_ids := ARRAY[NEW.resource_id];
    IF TG_OP = 'UPDATE' THEN
      v_resource_ids := array_append(v_resource_ids, OLD.resource_id);
    END IF;
  END IF;

  SELECT work_row.* INTO v_work
  FROM aep.works AS work_row
  WHERE work_row.work_id = v_work_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'WorkResourceRequirement references an unknown Work'
      USING ERRCODE = '23503';
  END IF;

  -- Fixed order for this table: Work tuple -> sorted Resource lock(s) -> Project lock.
  PERFORM aep.lock_context_resource(v_resource_ids, true);
  PERFORM pg_advisory_xact_lock(
    hashtextextended('aep.context-project:' || v_work.project_id::text, 0)
  );

  IF v_work.fence_generation <> 0
     OR v_work.current_execution_id IS NOT NULL
     OR v_work.status NOT IN ('proposed', 'ready') THEN
    RAISE EXCEPTION 'WorkResourceRequirement is immutable after execution begins'
      USING ERRCODE = '55000';
  END IF;

  IF TG_OP <> 'DELETE' THEN
    IF v_work.project_id <> NEW.project_id THEN
      RAISE EXCEPTION 'WorkResourceRequirement project must match its Work'
        USING ERRCODE = '23503';
    END IF;

    -- Resource mutations use the matching advisory lock before changing status;
    -- use an MVCC read here rather than waiting on a tuple held by that writer.
    SELECT resource_row.* INTO v_resource
    FROM aep.resources AS resource_row
    WHERE resource_row.resource_id = NEW.resource_id;

    IF NOT FOUND OR v_resource.status <> 'active'
       OR v_resource.provider <> 'github'
       OR v_resource.resource_type <> 'repository'
       OR NOT aep.is_canonical_github_branch_ref(NEW.resource_ref) THEN
      RAISE EXCEPTION 'WorkResourceRequirement requires an active GitHub repository and canonical fully-qualified branch ref'
        USING ERRCODE = '23514',
              CONSTRAINT = 'work_resource_requirements_github_branch_ref_ck';
    END IF;
    RETURN NEW;
  END IF;

  RETURN OLD;
END
$function$;

-- The bulk replacement API owns the full lock set. It takes the Work tuple
-- first (as before), then all old/new Resource locks in sorted order, then the
-- Project lock, before issuing per-row DELETE/INSERT operations.
CREATE OR REPLACE FUNCTION aep.set_work_resource_requirements(
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
  v_resource_ids uuid[];
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

  SELECT COALESCE(array_agg(DISTINCT resource_id ORDER BY resource_id),
                  ARRAY[]::uuid[])
  INTO v_resource_ids
  FROM (
    SELECT requirement.resource_id
    FROM aep.work_resource_requirements AS requirement
    WHERE requirement.work_id = p_work_id
    UNION
    SELECT (item.value->>'resource_id')::uuid
    FROM jsonb_array_elements(p_requirements) AS item(value)
  ) AS resource_union;

  PERFORM aep.lock_context_resource(v_resource_ids, true);
  PERFORM pg_advisory_xact_lock(
    hashtextextended('aep.context-project:' || v_work.project_id::text, 0)
  );

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

ALTER FUNCTION aep.guard_work_resource_requirement() OWNER TO aep_owner;
ALTER FUNCTION aep.set_work_resource_requirements(uuid,jsonb) OWNER TO aep_owner;

CREATE FUNCTION aep.context_project_resource_allowed(
  p_project_id uuid,
  p_resource_id uuid,
  p_exclusive boolean DEFAULT false
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, aep
AS $function$
DECLARE
  v_project_status text;
  v_project_resource_status text;
  v_resource_status text;
  v_access_mode text;
  v_decision_id uuid;
  v_decision_status text;
  v_decision_scope_type text;
  v_decision_scope_key text;
BEGIN
  -- This MVCC gate depends on a fresh READ COMMITTED snapshot after advisory-lock
  -- waits. A REPEATABLE READ/SERIALIZABLE transaction could retain a pre-revocation
  -- snapshot even after the writer commits and releases the Resource/Project lock.
  -- Reject unsupported isolation before taking locks or reading authorization rows.
  IF current_setting('transaction_isolation') IS DISTINCT FROM 'read committed' THEN
    RAISE EXCEPTION
      'Context authorization requires READ COMMITTED isolation; current transaction uses %',
      current_setting('transaction_isolation')
      USING ERRCODE = '25001';
  END IF;

  -- Resource locks precede project locks for a globally consistent order.
  -- A resource-scoped decision or physical Resource update may affect every
  -- project linked to this Resource; association inserts/removals participate
  -- in the same Resource lock before their project lock.
  PERFORM aep.lock_context_resource(ARRAY[p_resource_id], false);

  -- Context snapshots and relevant writes share a project-scoped advisory lock.
  -- Source-revision recording requests an exclusive lock; compile/fetch request
  -- a shared lock. The lock remains held until the caller's transaction ends.
  IF p_exclusive THEN
    PERFORM pg_advisory_xact_lock(
      hashtextextended('aep.context-project:' || p_project_id::text, 0)
    );
  ELSE
    PERFORM pg_advisory_xact_lock_shared(
      hashtextextended('aep.context-project:' || p_project_id::text, 0)
    );
  END IF;

  -- Do not take row-level locks in the authorization gate. A writer can
  -- already hold its target tuple lock when its BEFORE ROW trigger requests the
  -- exclusive project advisory lock. If this reader then tried FOR SHARE, the
  -- reader and writer could deadlock (advisory -> tuple versus tuple -> advisory).
  -- Plain MVCC reads are stable here: every relevant writer must acquire the
  -- conflicting exclusive project lock before it can change/commit the row.
  SELECT project_row.status,project_resource.status,resource_row.status,
         project_resource.access_mode,project_resource.grant_decision_id
  INTO v_project_status,v_project_resource_status,v_resource_status,
       v_access_mode,v_decision_id
  FROM aep.projects AS project_row
  JOIN aep.project_resources AS project_resource
    ON project_resource.project_id = project_row.project_id
  JOIN aep.resources AS resource_row
    ON resource_row.resource_id = project_resource.resource_id
  WHERE project_row.project_id = p_project_id
    AND project_resource.resource_id = p_resource_id;

  IF NOT FOUND
     OR v_project_status NOT IN ('active','paused')
     OR v_project_resource_status <> 'active'
     OR v_resource_status <> 'active'
     OR v_access_mode NOT IN ('read','write','read_write') THEN
    RETURN false;
  END IF;

  IF v_access_mode = 'read' THEN
    RETURN true;
  END IF;

  IF v_decision_id IS NULL THEN
    RETURN false;
  END IF;

  -- The project advisory lock also serializes mutations to this decision.
  -- Keep this as an MVCC read (no tuple lock) to preserve the same lock order.
  SELECT decision_row.status,decision_row.scope_type,decision_row.scope_key
  INTO v_decision_status,v_decision_scope_type,v_decision_scope_key
  FROM aep.owner_decisions AS decision_row
  WHERE decision_row.decision_id = v_decision_id;

  IF NOT FOUND OR v_decision_status <> 'approved' THEN
    RETURN false;
  END IF;

  RETURN (
    (v_decision_scope_type = 'project' AND v_decision_scope_key = p_project_id::text)
    OR
    (v_decision_scope_type = 'resource' AND v_decision_scope_key = p_resource_id::text)
  );
END
$function$;

-- Internal snapshot builder. It must only be called after the project/resource
-- scope gate. Cross-project dependencies are rejected until a separate explicit
-- sharing grant is supported by the Context Compiler.
CREATE FUNCTION aep.build_context_pack_snapshot(
  p_project_id uuid,
  p_work_id uuid,
  p_resource_id uuid,
  p_resource_ref text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, aep
AS $function$
DECLARE
  v_project jsonb;
  v_work jsonb;
  v_resource jsonb;
  v_grant jsonb;
  v_repository jsonb;
  v_dependencies jsonb;
  v_decisions jsonb;
  v_evidence jsonb;
  v_evidence_summary jsonb;
  v_related_work_ids uuid[];
BEGIN
  SELECT jsonb_build_object(
    'project_id', project_row.project_id,
    'project_key', project_row.project_key,
    'name', project_row.name,
    'status', project_row.status
  )
  INTO v_project
  FROM aep.projects AS project_row
  WHERE project_row.project_id = p_project_id
    AND project_row.status IN ('active','paused');

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Context project is not available' USING ERRCODE = '23503';
  END IF;

  SELECT jsonb_build_object(
    'work_id', work_row.work_id,
    'project_id', work_row.project_id,
    'identity_kind', work_row.identity_kind,
    'identity_key', work_row.identity_key,
    'identity_version', work_row.identity_version,
    'work_type', work_row.work_type,
    'status', work_row.status,
    'title', work_row.title,
    'acceptance', work_row.acceptance,
    'owner_decision_id', work_row.owner_decision_id,
    'version', work_row.version,
    'dependencies_satisfied', aep.work_dependencies_satisfied(work_row.work_id)
  )
  INTO v_work
  FROM aep.works AS work_row
  WHERE work_row.project_id = p_project_id
    AND work_row.work_id = p_work_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Context Work does not belong to the authorized project' USING ERRCODE = '23503';
  END IF;

  SELECT jsonb_build_object(
    'resource_id', resource_row.resource_id,
    'provider', resource_row.provider,
    'host', resource_row.host,
    'resource_type', resource_row.resource_type,
    'stable_resource_id', resource_row.stable_resource_id,
    'canonical_key', resource_row.canonical_key,
    'display_name', resource_row.display_name,
    'status', resource_row.status
  )
  INTO v_resource
  FROM aep.resources AS resource_row
  WHERE resource_row.resource_id = p_resource_id
    AND resource_row.provider = 'github'
    AND resource_row.resource_type = 'repository'
    AND resource_row.status = 'active';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Context resource is not an active GitHub repository' USING ERRCODE = '23503';
  END IF;

  SELECT jsonb_build_object(
    'access_mode', project_resource.access_mode,
    'status', project_resource.status,
    'grant_version', project_resource.grant_version,
    'grant_decision_id', project_resource.grant_decision_id
  )
  INTO v_grant
  FROM aep.project_resources AS project_resource
  WHERE project_resource.project_id = p_project_id
    AND project_resource.resource_id = p_resource_id
    AND project_resource.status = 'active';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Context resource grant is no longer active' USING ERRCODE = '42501';
  END IF;

  PERFORM 1
  FROM aep.work_resource_requirements AS requirement
  WHERE requirement.project_id = p_project_id
    AND requirement.work_id = p_work_id
    AND requirement.resource_id = p_resource_id
    AND requirement.resource_ref = p_resource_ref;

  IF NOT FOUND OR NOT aep.is_canonical_github_branch_ref(p_resource_ref) THEN
    RAISE EXCEPTION 'Work does not declare the requested canonical repository ref'
      USING ERRCODE = '22023';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM aep.work_relations AS relation_row
    JOIN aep.works AS target_work
      ON target_work.work_id = relation_row.target_work_id
    WHERE relation_row.source_work_id = p_work_id
      AND relation_row.relation_type = 'depends_on'
      AND relation_row.status = 'active'
      AND target_work.project_id <> p_project_id
  ) THEN
    RAISE EXCEPTION 'Cross-project Context dependencies require an explicit sharing grant; this prototype fails closed'
      USING ERRCODE = '42501';
  END IF;

  SELECT ARRAY[p_work_id] || COALESCE(array_agg(relation_row.target_work_id), ARRAY[]::uuid[])
  INTO v_related_work_ids
  FROM aep.work_relations AS relation_row
  WHERE relation_row.source_work_id = p_work_id
    AND relation_row.relation_type = 'depends_on'
    AND relation_row.status = 'active';

  SELECT jsonb_build_object(
    'resource_ref', p_resource_ref,
    'source_version', source_head.source_version,
    'commit_sha', source_head.commit_sha,
    'tree_sha', source_head.tree_sha,
    'content_sha256', source_head.content_sha256,
    'evidence_id', source_head.evidence_id,
    'observed_at', source_head.observed_at,
    'provenance', source_head.provenance
  )
  INTO v_repository
  FROM aep.context_source_heads AS source_head
  WHERE source_head.project_id = p_project_id
    AND source_head.work_id = p_work_id
    AND source_head.resource_id = p_resource_id
    AND source_head.resource_ref = p_resource_ref;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No repository source revision has been recorded for this Work/ref'
      USING ERRCODE = 'P0002';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'relation_id', relation_row.relation_id,
    'relation_type', relation_row.relation_type,
    'dependency_graph_id', relation_row.dependency_graph_id,
    'graph_status', graph_row.status,
    'graph_version', graph_row.graph_version,
    'target_work_id', target_work.work_id,
    'target_status', target_work.status,
    'target_version', target_work.version,
    'target_title', target_work.title,
    'target_acceptance', target_work.acceptance,
    'required', relation_row.required
  ) ORDER BY relation_row.target_work_id, relation_row.relation_id), '[]'::jsonb)
  INTO v_dependencies
  FROM aep.work_relations AS relation_row
  JOIN aep.works AS target_work
    ON target_work.work_id = relation_row.target_work_id
  LEFT JOIN aep.dependency_graphs AS graph_row
    ON graph_row.graph_id = relation_row.dependency_graph_id
  WHERE relation_row.source_work_id = p_work_id
    AND relation_row.relation_type = 'depends_on'
    AND relation_row.status = 'active';

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'decision_id', decision_row.decision_id,
    'scope_type', decision_row.scope_type,
    'scope_key', decision_row.scope_key,
    'decision_key', decision_row.decision_key,
    'statement', decision_row.statement,
    'decision_version', decision_row.decision_version,
    'status', decision_row.status,
    'approval_source_kind', decision_row.approval_source_kind,
    'approval_source_ref', decision_row.approval_source_ref,
    'approval_source_hash', decision_row.approval_source_hash,
    'approver_principal', decision_row.approver_principal,
    'approval_provenance', decision_row.approval_provenance,
    'approved_at', decision_row.approved_at,
    'supersedes_decision_id', decision_row.supersedes_decision_id
  ) ORDER BY decision_row.scope_type, decision_row.scope_key,
             decision_row.decision_key, decision_row.decision_version), '[]'::jsonb)
  INTO v_decisions
  FROM aep.owner_decisions AS decision_row
  WHERE (decision_row.scope_type = 'project' AND decision_row.scope_key = p_project_id::text)
     OR (decision_row.scope_type = 'resource' AND decision_row.scope_key = p_resource_id::text)
     OR (decision_row.scope_type = 'work'
         AND decision_row.scope_key IN (SELECT unnest(v_related_work_ids)::text));

  -- Select bounded Evidence metadata first. Payload rows are fetched only after
  -- per-item and aggregate byte limits have been applied to persisted size fields.
  WITH total_evidence AS MATERIALIZED (
    SELECT
      count(*)::bigint AS total_count,
      count(*) FILTER (
        WHERE size_row.payload_bytes > 16384
           OR size_row.provenance_bytes > 8192
           OR size_row.evidence_type_bytes > 400
           OR size_row.source_ref_bytes > 8192
           OR size_row.source_revision_bytes > 8192
      )::bigint AS oversized_count
    FROM aep.context_evidence_sizes AS size_row
    WHERE size_row.project_id = p_project_id
      AND size_row.work_id = ANY(v_related_work_ids)
      AND size_row.evidence_type <> 'repository_revision'
  ),
  candidate_metadata AS MATERIALIZED (
    SELECT
      size_row.evidence_id,
      size_row.work_id,
      size_row.evidence_type,
      size_row.observed_at,
      size_row.payload_bytes,
      size_row.provenance_bytes,
      size_row.evidence_type_bytes,
      size_row.source_ref_bytes,
      size_row.source_revision_bytes
    FROM aep.context_evidence_sizes AS size_row
    WHERE size_row.project_id = p_project_id
      AND size_row.work_id = ANY(v_related_work_ids)
      AND size_row.evidence_type <> 'repository_revision'
      AND size_row.payload_bytes <= 16384
      AND size_row.provenance_bytes <= 8192
      AND size_row.evidence_type_bytes <= 400
      AND size_row.source_ref_bytes <= 8192
      AND size_row.source_revision_bytes <= 8192
    ORDER BY size_row.observed_at DESC, size_row.evidence_id DESC
    LIMIT 128
  ),
  bounded_metadata AS MATERIALIZED (
    SELECT candidate_metadata.*,
      sum(
        payload_bytes + provenance_bytes + evidence_type_bytes
        + source_ref_bytes + source_revision_bytes + 512
      ) OVER (
        ORDER BY observed_at DESC, evidence_id DESC
      ) AS cumulative_materialized_bytes
    FROM candidate_metadata
  ),
  selected_metadata AS MATERIALIZED (
    SELECT *
    FROM bounded_metadata
    WHERE cumulative_materialized_bytes <= 262144
  ),
  candidate_stats AS (
    SELECT count(*)::bigint AS candidate_count FROM candidate_metadata
  ),
  selected_evidence AS (
    SELECT
      COALESCE(jsonb_agg(jsonb_build_object(
        'evidence_id', evidence_row.evidence_id,
        'work_id', evidence_row.work_id,
        'evidence_type', evidence_row.evidence_type,
        'source_ref', evidence_row.source_ref,
        'source_revision', evidence_row.source_revision,
        'content_sha256', evidence_row.content_sha256,
        'evidence_type_bytes', selected.evidence_type_bytes,
        'source_ref_bytes', selected.source_ref_bytes,
        'source_revision_bytes', selected.source_revision_bytes,
        'materialized_bytes', (
          selected.payload_bytes + selected.provenance_bytes
          + selected.evidence_type_bytes + selected.source_ref_bytes
          + selected.source_revision_bytes + 512
        ),
        'payload_sha256', encode(
          public.digest(convert_to(evidence_row.payload::text, 'UTF8'), 'sha256'), 'hex'
        ),
        'payload_bytes', selected.payload_bytes,
        'provenance_bytes', selected.provenance_bytes,
        'observed_at', evidence_row.observed_at,
        'valid_at', evidence_row.valid_at,
        'provenance', evidence_row.provenance,
        'payload', evidence_row.payload
      ) ORDER BY evidence_row.observed_at DESC, evidence_row.evidence_id DESC), '[]'::jsonb)
        AS evidence_payload,
      count(*)::bigint AS selected_count,
      COALESCE(sum(
        selected.payload_bytes + selected.provenance_bytes
        + selected.evidence_type_bytes + selected.source_ref_bytes
        + selected.source_revision_bytes + 512
      ),0)::bigint AS selected_materialized_bytes
    FROM selected_metadata AS selected
    JOIN aep.evidence AS evidence_row
      ON evidence_row.evidence_id = selected.evidence_id
  )
  SELECT
    selected_evidence.evidence_payload,
    jsonb_build_object(
      'total_count', total_evidence.total_count,
      'oversized_count', total_evidence.oversized_count,
      'candidate_count', candidate_stats.candidate_count,
      'selected_count', selected_evidence.selected_count,
      'omitted_count', total_evidence.total_count - selected_evidence.selected_count,
      'selected_materialized_bytes', selected_evidence.selected_materialized_bytes,
      'max_payload_bytes_per_item', 16384,
      'max_provenance_bytes_per_item', 8192,
      'max_evidence_type_bytes_per_item', 400,
      'max_source_ref_bytes_per_item', 8192,
      'max_source_revision_bytes_per_item', 8192,
      'per_item_fixed_overhead_bytes', 512,
      'max_candidate_count', 128,
      'max_selected_materialized_bytes', 262144
    )
  INTO v_evidence, v_evidence_summary
  FROM total_evidence
  CROSS JOIN candidate_stats
  CROSS JOIN selected_evidence;

  RETURN jsonb_build_object(
    'project', v_project,
    'work', v_work,
    'dependencies', v_dependencies,
    'resource', v_resource,
    'project_resource_grant', v_grant,
    'repository_revision', v_repository,
    'decisions', v_decisions,
    'evidence_summary', v_evidence_summary,
    'evidence', v_evidence
  );
END
$function$;

-- Records an externally observed repository pin only after the project/resource
-- scope gate. The adapter's observation provenance is retained as evidence; this
-- prototype cannot independently authenticate the GitHub observer.
CREATE FUNCTION aep.record_context_source_revision(
  p_project_id uuid,
  p_work_id uuid,
  p_resource_id uuid,
  p_resource_ref text,
  p_session_id uuid,
  p_commit_sha text,
  p_tree_sha text,
  p_content_sha256 text,
  p_provenance jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, aep, public
AS $function$
DECLARE
  v_resource aep.resources%ROWTYPE;
  v_head aep.context_source_heads%ROWTYPE;
  v_evidence_id uuid;
  v_next_version bigint;
  v_source_ref text;
  v_provenance jsonb;
BEGIN
  IF p_project_id IS NULL OR p_work_id IS NULL OR p_resource_id IS NULL
     OR p_session_id IS NULL THEN
    RAISE EXCEPTION 'Project, Work, Resource and session provenance are required'
      USING ERRCODE = '22004';
  END IF;
  IF p_resource_ref IS NULL OR NOT aep.is_canonical_github_branch_ref(p_resource_ref) THEN
    RAISE EXCEPTION 'A canonical GitHub branch ref is required' USING ERRCODE = '22023';
  END IF;
  IF p_commit_sha IS NULL OR p_commit_sha !~ '^([0-9a-f]{40}|[0-9a-f]{64})$'
     OR p_tree_sha IS NULL OR p_tree_sha !~ '^([0-9a-f]{40}|[0-9a-f]{64})$'
     OR p_content_sha256 IS NULL OR p_content_sha256 !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'Repository commit/tree SHA and content SHA-256 are required'
      USING ERRCODE = '22023';
  END IF;
  IF p_provenance IS NULL OR jsonb_typeof(p_provenance) IS DISTINCT FROM 'object'
     OR octet_length(p_provenance::text) > 8192 THEN
    RAISE EXCEPTION 'Source observation provenance must be an object up to 8192 bytes'
      USING ERRCODE = '22023';
  END IF;

  IF NOT aep.context_project_resource_allowed(p_project_id, p_resource_id, true) THEN
    INSERT INTO aep.context_retrieval_events(
      operation, outcome, project_id, work_id, resource_id, session_id,
      source_count, source_bytes
    ) VALUES ('record_source','denied',p_project_id,p_work_id,p_resource_id,p_session_id,0,0);
    RETURN jsonb_build_object('status','denied','reason','project_scope_unavailable');
  END IF;

  -- Project access has been checked before reading Work or source requirement data.
  PERFORM 1 FROM aep.works
  WHERE project_id = p_project_id AND work_id = p_work_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Source observation Work does not belong to the authorized project'
      USING ERRCODE = '23503';
  END IF;

  PERFORM 1 FROM aep.work_resource_requirements
  WHERE project_id = p_project_id AND work_id = p_work_id
    AND resource_id = p_resource_id AND resource_ref = p_resource_ref;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Work does not declare this repository resource/ref'
      USING ERRCODE = '22023';
  END IF;

  SELECT resource_row.* INTO v_resource
  FROM aep.resources AS resource_row
  WHERE resource_row.resource_id = p_resource_id
    AND resource_row.provider = 'github'
    AND resource_row.resource_type = 'repository'
    AND resource_row.status = 'active';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Source resource is not an active GitHub repository'
      USING ERRCODE = '22023';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(
    p_project_id::text || ':' || p_resource_id::text || ':' || p_resource_ref, 0
  ));

  SELECT source_head.* INTO v_head
  FROM aep.context_source_heads AS source_head
  WHERE source_head.project_id = p_project_id
    AND source_head.work_id = p_work_id
    AND source_head.resource_id = p_resource_id
    AND source_head.resource_ref = p_resource_ref
  FOR UPDATE;

  v_provenance := p_provenance || jsonb_build_object(
    'observation_kind','repository_revision'
  );

  IF FOUND
     AND v_head.commit_sha = p_commit_sha
     AND v_head.tree_sha = p_tree_sha
     AND v_head.content_sha256 = p_content_sha256
     AND v_head.provenance = v_provenance THEN
    INSERT INTO aep.context_retrieval_events(
      operation, outcome, project_id, work_id, resource_id, session_id,
      source_count, source_bytes
    ) VALUES ('record_source','unchanged',p_project_id,p_work_id,p_resource_id,p_session_id,0,0);
    RETURN jsonb_build_object(
      'status','unchanged',
      'source_version',v_head.source_version,
      'evidence_id',v_head.evidence_id
    );
  END IF;

  v_next_version := CASE WHEN v_head.source_version IS NULL THEN 1 ELSE v_head.source_version + 1 END;
  v_source_ref := 'github://' || v_resource.host || '/' || v_resource.stable_resource_id
    || '?ref=' || p_resource_ref;

  INSERT INTO aep.evidence(
    project_id, work_id, evidence_type, source_ref, source_revision,
    content_sha256, provenance, payload
  ) VALUES (
    p_project_id, p_work_id, 'repository_revision', v_source_ref, p_commit_sha,
    p_content_sha256, v_provenance,
    jsonb_build_object(
      'resource_id',p_resource_id,
      'resource_ref',p_resource_ref,
      'commit_sha',p_commit_sha,
      'tree_sha',p_tree_sha,
      'source_version',v_next_version
    )
  )
  RETURNING evidence_id INTO v_evidence_id;

  INSERT INTO aep.context_source_heads(
    project_id, work_id, resource_id, resource_ref, source_version,
    commit_sha, tree_sha, content_sha256, provenance, evidence_id,
    observed_by_session_id, observed_at
  ) VALUES (
    p_project_id, p_work_id, p_resource_id, p_resource_ref, v_next_version,
    p_commit_sha, p_tree_sha, p_content_sha256, v_provenance, v_evidence_id,
    p_session_id, clock_timestamp()
  )
  ON CONFLICT (project_id, work_id, resource_id, resource_ref) DO UPDATE SET
    source_version = EXCLUDED.source_version,
    commit_sha = EXCLUDED.commit_sha,
    tree_sha = EXCLUDED.tree_sha,
    content_sha256 = EXCLUDED.content_sha256,
    provenance = EXCLUDED.provenance,
    evidence_id = EXCLUDED.evidence_id,
    observed_by_session_id = EXCLUDED.observed_by_session_id,
    observed_at = EXCLUDED.observed_at;

  INSERT INTO aep.context_retrieval_events(
    operation, outcome, project_id, work_id, resource_id, session_id,
    source_count, source_bytes
  ) VALUES ('record_source','recorded',p_project_id,p_work_id,p_resource_id,p_session_id,0,0);

  RETURN jsonb_build_object(
    'status','recorded',
    'source_version',v_next_version,
    'evidence_id',v_evidence_id
  );
END
$function$;

-- Compiles and caches a bounded JSON Context Pack. The authorization gate runs
-- before build_context_pack_snapshot touches Work, dependencies, decisions or
-- Evidence. session_id is stored only as provenance, never as access proof.
CREATE FUNCTION aep.compile_context_pack(
  p_project_id uuid,
  p_work_id uuid,
  p_resource_id uuid,
  p_resource_ref text,
  p_session_id uuid,
  p_token_budget integer,
  p_compiler_version text,
  p_indexer_version text,
  p_config_version text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, aep, public
AS $function$
DECLARE
  v_snapshot jsonb;
  v_source_fingerprint text;
  v_cache_key text;
  v_payload_base jsonb;
  v_payload jsonb;
  v_candidate jsonb;
  v_evidence jsonb;
  v_selected jsonb := '[]'::jsonb;
  v_item jsonb;
  v_evidence_count bigint;
  v_selected_count integer := 0;
  v_estimated_tokens integer;
  v_rows integer;
  v_pack aep.context_packs%ROWTYPE;
BEGIN
  IF p_project_id IS NULL OR p_work_id IS NULL OR p_resource_id IS NULL
     OR p_session_id IS NULL THEN
    RAISE EXCEPTION 'Project, Work, Resource and session provenance are required'
      USING ERRCODE = '22004';
  END IF;
  IF p_resource_ref IS NULL OR NOT aep.is_canonical_github_branch_ref(p_resource_ref) THEN
    RAISE EXCEPTION 'A canonical GitHub branch ref is required' USING ERRCODE = '22023';
  END IF;
  IF p_token_budget IS NULL OR p_token_budget NOT BETWEEN 128 AND 100000 THEN
    RAISE EXCEPTION 'Context token budget must be between 128 and 100000'
      USING ERRCODE = '22023';
  END IF;
  IF p_compiler_version IS NULL OR length(btrim(p_compiler_version)) NOT BETWEEN 1 AND 100
     OR p_indexer_version IS NULL OR length(btrim(p_indexer_version)) NOT BETWEEN 1 AND 100
     OR p_config_version IS NULL OR length(btrim(p_config_version)) NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'Compiler, indexer and config versions are required'
      USING ERRCODE = '22023';
  END IF;

  IF NOT aep.context_project_resource_allowed(p_project_id, p_resource_id) THEN
    INSERT INTO aep.context_retrieval_events(
      operation, outcome, project_id, work_id, resource_id, session_id,
      source_count, source_bytes
    ) VALUES ('compile','denied',p_project_id,p_work_id,p_resource_id,p_session_id,0,0);
    RETURN jsonb_build_object('status','denied','reason','project_scope_unavailable');
  END IF;

  v_snapshot := aep.build_context_pack_snapshot(
    p_project_id,p_work_id,p_resource_id,p_resource_ref
  );
  v_source_fingerprint := encode(
    public.digest(convert_to(v_snapshot::text, 'UTF8'), 'sha256'), 'hex'
  );
  v_cache_key := encode(public.digest(convert_to(jsonb_build_object(
    'source_fingerprint',v_source_fingerprint,
    'compiler_version',p_compiler_version,
    'indexer_version',p_indexer_version,
    'config_version',p_config_version,
    'token_budget',p_token_budget
  )::text, 'UTF8'), 'sha256'), 'hex');

  v_evidence := v_snapshot->'evidence';
  v_evidence_count := COALESCE(
    (v_snapshot #>> '{evidence_summary,total_count}')::bigint, 0
  );
  v_payload_base := jsonb_build_object(
    'pack_schema_version',1,
    'project',v_snapshot->'project',
    'work',v_snapshot->'work',
    'dependencies',v_snapshot->'dependencies',
    'repository',jsonb_build_object(
      'resource',v_snapshot->'resource',
      'project_resource_grant',v_snapshot->'project_resource_grant',
      'repository_revision',v_snapshot->'repository_revision'
    ),
    'decisions',v_snapshot->'decisions',
    'compiler',jsonb_build_object(
      'compiler_version',p_compiler_version,
      'indexer_version',p_indexer_version,
      'config_version',p_config_version
    ),
    'token_budget',p_token_budget,
    'token_estimation_method','ceil_utf8_bytes_div_4',
    'source_evidence',v_selected,
    'source_evidence_count',v_evidence_count,
    'source_evidence_selection',v_snapshot->'evidence_summary',
    'source_evidence_included',0,
    'source_evidence_truncated_count',v_evidence_count,
    'truncated',v_evidence_count > 0,
    'estimated_tokens',0
  );

  v_estimated_tokens := ceil(octet_length(v_payload_base::text)::numeric / 4)::integer;
  IF v_estimated_tokens + 2 > p_token_budget THEN
    RAISE EXCEPTION 'Required Context metadata exceeds token budget'
      USING ERRCODE = '22023';
  END IF;

  FOR v_item IN
    SELECT entry.value
    FROM jsonb_array_elements(v_evidence)
      WITH ORDINALITY AS entry(value, ordinality)
    ORDER BY entry.ordinality
  LOOP
    v_candidate := v_selected || jsonb_build_array(v_item);
    v_payload := v_payload_base || jsonb_build_object(
      'source_evidence',v_candidate,
      'source_evidence_included',v_selected_count + 1,
      'source_evidence_truncated_count',v_evidence_count - v_selected_count - 1,
      'truncated',v_evidence_count > v_selected_count + 1
    );
    v_estimated_tokens := ceil(octet_length(v_payload::text)::numeric / 4)::integer;
    -- Leave room for the final estimated_tokens field so the returned payload
    -- never exceeds the declared byte-derived estimate budget.
    IF v_estimated_tokens + 2 > p_token_budget THEN
      EXIT;
    END IF;
    v_selected := v_candidate;
    v_selected_count := v_selected_count + 1;
  END LOOP;

  v_payload := v_payload_base || jsonb_build_object(
    'source_evidence',v_selected,
    'source_evidence_included',v_selected_count,
    'source_evidence_truncated_count',v_evidence_count - v_selected_count,
    'truncated',v_evidence_count > v_selected_count
  );
  v_estimated_tokens := ceil(octet_length(v_payload::text)::numeric / 4)::integer;
  v_payload := v_payload || jsonb_build_object('estimated_tokens',v_estimated_tokens);
  v_estimated_tokens := ceil(octet_length(v_payload::text)::numeric / 4)::integer;
  v_payload := v_payload || jsonb_build_object('estimated_tokens',v_estimated_tokens);

  IF v_estimated_tokens > p_token_budget THEN
    RAISE EXCEPTION 'Context token budget could not be satisfied' USING ERRCODE = '22023';
  END IF;

  INSERT INTO aep.context_packs(
    cache_key,project_id,work_id,resource_id,resource_ref,source_version,
    work_version,grant_version,source_fingerprint,compiler_version,indexer_version,
    config_version,token_budget,estimated_tokens,payload_sha256,payload,
    created_by_session_id
  ) VALUES (
    v_cache_key,p_project_id,p_work_id,p_resource_id,p_resource_ref,
    (v_snapshot #>> '{repository_revision,source_version}')::bigint,
    (v_snapshot #>> '{work,version}')::bigint,
    (v_snapshot #>> '{project_resource_grant,grant_version}')::bigint,
    v_source_fingerprint,p_compiler_version,p_indexer_version,p_config_version,
    p_token_budget,v_estimated_tokens,
    encode(public.digest(convert_to(v_payload::text,'UTF8'),'sha256'),'hex'),
    v_payload,p_session_id
  )
  ON CONFLICT (cache_key) DO NOTHING;

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  SELECT pack_row.* INTO v_pack
  FROM aep.context_packs AS pack_row
  WHERE pack_row.cache_key = v_cache_key;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Context Pack cache insert could not be reconciled'
      USING ERRCODE = '40001';
  END IF;

  IF v_pack.payload_sha256 <> encode(
    public.digest(convert_to(v_payload::text,'UTF8'),'sha256'),'hex'
  ) THEN
    RAISE EXCEPTION 'Context Pack cache key resolved to different content'
      USING ERRCODE = '40001';
  END IF;

  INSERT INTO aep.context_retrieval_events(
    operation,outcome,project_id,work_id,resource_id,pack_id,session_id,
    source_count,source_bytes
  ) VALUES (
    'compile',CASE WHEN v_rows = 1 THEN 'compiled' ELSE 'reused' END,
    p_project_id,p_work_id,p_resource_id,v_pack.pack_id,p_session_id,
    v_selected_count,octet_length(v_pack.payload::text)
  );

  RETURN jsonb_build_object(
    'status','ready',
    'cache_hit',v_rows = 0,
    'pack_id',v_pack.pack_id,
    'cache_key',v_pack.cache_key,
    'content_sha256',v_pack.payload_sha256,
    'source_fingerprint',v_pack.source_fingerprint,
    'token_budget',v_pack.token_budget,
    'estimated_tokens',v_pack.estimated_tokens,
    'truncated',v_pack.payload->'truncated',
    'payload',v_pack.payload
  );
END
$function$;

-- Cached content is returned only after current ProjectResource authorization
-- and a fresh comparison of source, Work, dependencies, decisions, grant and
-- compiler/indexer/config/budget dimensions. Metadata lookup alone never returns
-- the cached payload.
CREATE FUNCTION aep.get_context_pack(
  p_pack_id uuid,
  p_session_id uuid,
  p_token_budget integer,
  p_compiler_version text,
  p_indexer_version text,
  p_config_version text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, aep, public
AS $function$
DECLARE
  v_project_id uuid;
  v_work_id uuid;
  v_resource_id uuid;
  v_resource_ref text;
  v_source_fingerprint text;
  v_stored_compiler text;
  v_stored_indexer text;
  v_stored_config text;
  v_stored_budget integer;
  v_snapshot jsonb;
  v_current_fingerprint text;
  v_payload jsonb;
  v_payload_sha256 text;
BEGIN
  IF p_pack_id IS NULL OR p_session_id IS NULL THEN
    RAISE EXCEPTION 'Context Pack and session provenance are required'
      USING ERRCODE = '22004';
  END IF;
  IF p_token_budget IS NULL OR p_token_budget NOT BETWEEN 128 AND 100000
     OR p_compiler_version IS NULL OR length(btrim(p_compiler_version)) NOT BETWEEN 1 AND 100
     OR p_indexer_version IS NULL OR length(btrim(p_indexer_version)) NOT BETWEEN 1 AND 100
     OR p_config_version IS NULL OR length(btrim(p_config_version)) NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'Current Context compiler/indexer/config versions and token budget are required'
      USING ERRCODE = '22023';
  END IF;

  -- Read only the minimum routing metadata needed to check the scope grant.
  -- Work/ref/fingerprint/compiler metadata and payload are read only afterwards.
  SELECT pack_row.project_id,pack_row.resource_id
  INTO v_project_id,v_resource_id
  FROM aep.context_packs AS pack_row
  WHERE pack_row.pack_id = p_pack_id;

  IF NOT FOUND THEN
    INSERT INTO aep.context_retrieval_events(
      operation,outcome,pack_id,session_id,source_count,source_bytes
    ) VALUES ('fetch','denied',p_pack_id,p_session_id,0,0);
    RETURN jsonb_build_object('status','denied','reason','project_scope_unavailable');
  END IF;

  IF NOT aep.context_project_resource_allowed(v_project_id,v_resource_id) THEN
    INSERT INTO aep.context_retrieval_events(
      operation,outcome,project_id,resource_id,pack_id,session_id,
      source_count,source_bytes
    ) VALUES (
      'fetch','denied',v_project_id,v_resource_id,p_pack_id,p_session_id,0,0
    );
    RETURN jsonb_build_object('status','denied','reason','project_scope_unavailable');
  END IF;

  SELECT pack_row.work_id,pack_row.resource_ref,pack_row.source_fingerprint,
         pack_row.compiler_version,pack_row.indexer_version,pack_row.config_version,
         pack_row.token_budget
  INTO v_work_id,v_resource_ref,v_source_fingerprint,v_stored_compiler,
       v_stored_indexer,v_stored_config,v_stored_budget
  FROM aep.context_packs AS pack_row
  WHERE pack_row.pack_id = p_pack_id;

  v_snapshot := aep.build_context_pack_snapshot(
    v_project_id,v_work_id,v_resource_id,v_resource_ref
  );
  v_current_fingerprint := encode(
    public.digest(convert_to(v_snapshot::text,'UTF8'),'sha256'),'hex'
  );

  IF v_current_fingerprint IS DISTINCT FROM v_source_fingerprint
     OR p_token_budget IS DISTINCT FROM v_stored_budget
     OR p_compiler_version IS DISTINCT FROM v_stored_compiler
     OR p_indexer_version IS DISTINCT FROM v_stored_indexer
     OR p_config_version IS DISTINCT FROM v_stored_config THEN
    INSERT INTO aep.context_retrieval_events(
      operation,outcome,project_id,work_id,resource_id,pack_id,session_id,
      source_count,source_bytes
    ) VALUES (
      'fetch','stale',v_project_id,v_work_id,v_resource_id,p_pack_id,p_session_id,0,0
    );
    RETURN jsonb_build_object('status','stale','reason','source_or_compiler_state_changed');
  END IF;

  -- This is the first read of the cached content and is after both checks above.
  SELECT pack_row.payload,pack_row.payload_sha256
  INTO v_payload,v_payload_sha256
  FROM aep.context_packs AS pack_row
  WHERE pack_row.pack_id = p_pack_id;

  IF NOT FOUND OR v_payload_sha256 IS DISTINCT FROM encode(
    public.digest(convert_to(v_payload::text,'UTF8'),'sha256'),'hex'
  ) THEN
    INSERT INTO aep.context_retrieval_events(
      operation,outcome,project_id,work_id,resource_id,pack_id,session_id,
      source_count,source_bytes
    ) VALUES (
      'fetch','stale',v_project_id,v_work_id,v_resource_id,p_pack_id,p_session_id,0,0
    );
    RETURN jsonb_build_object('status','stale','reason','cached_content_integrity_mismatch');
  END IF;

  INSERT INTO aep.context_retrieval_events(
    operation,outcome,project_id,work_id,resource_id,pack_id,session_id,
    source_count,source_bytes
  ) VALUES (
    'fetch','reused',v_project_id,v_work_id,v_resource_id,p_pack_id,p_session_id,
    jsonb_array_length(v_payload->'source_evidence'),octet_length(v_payload::text)
  );

  RETURN jsonb_build_object(
    'status','ready',
    'pack_id',p_pack_id,
    'content_sha256',v_payload_sha256,
    'token_budget',v_stored_budget,
    'estimated_tokens',v_payload->'estimated_tokens',
    'truncated',v_payload->'truncated',
    'payload',v_payload
  );
END
$function$;

-- A batch can add/remove dependency edges across several projects. Per-edge
-- trigger locks are insufficient: two batches can visit the same projects in
-- reverse order and each retain a different project lock. Pre-lock all affected
-- Work tuples, then the complete sorted project union, before the first edge write.
ALTER FUNCTION aep.mutate_dependencies(uuid,text,jsonb)
  RENAME TO mutate_dependencies_unordered;

ALTER FUNCTION aep.mutate_dependencies_unordered(uuid,text,jsonb) OWNER TO aep_owner;
REVOKE ALL ON FUNCTION aep.mutate_dependencies_unordered(uuid,text,jsonb)
  FROM PUBLIC,aep_runtime;

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
  v_graph_status text;
  v_saved aep.dependency_graph_operations%ROWTYPE;
  v_item jsonb;
  v_source_id uuid;
  v_target_id uuid;
  v_work_ids uuid[];
  v_project_ids uuid[];
  v_work_id uuid;
  v_project_id uuid;
BEGIN
  IF p_graph_id IS NULL OR p_request_key IS NULL
     OR length(btrim(p_request_key)) NOT BETWEEN 1 AND 160
     OR p_operations IS NULL OR jsonb_typeof(p_operations) <> 'array'
     OR jsonb_array_length(p_operations) NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'graph_id, request key and 1..100 dependency operations are required'
      USING ERRCODE = '22023';
  END IF;

  SELECT graph_row.status INTO v_graph_status
  FROM aep.dependency_graphs AS graph_row
  WHERE graph_row.graph_id = p_graph_id
  FOR UPDATE;

  IF NOT FOUND OR v_graph_status <> 'active' THEN
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

  FOR v_item IN
    SELECT element.value FROM jsonb_array_elements(p_operations) AS element(value)
  LOOP
    IF jsonb_typeof(v_item) <> 'object' THEN
      RAISE EXCEPTION 'Every dependency operation must be a JSON object'
        USING ERRCODE = '22023';
    END IF;
    v_source_id := NULLIF(v_item->>'source_work_id','')::uuid;
    v_target_id := NULLIF(v_item->>'target_work_id','')::uuid;
    IF v_item->>'op' NOT IN ('add','remove')
       OR v_source_id IS NULL OR v_target_id IS NULL
       OR v_source_id = v_target_id THEN
      RAISE EXCEPTION 'Dependency operation requires op=add/remove and distinct source/target Work IDs'
        USING ERRCODE = '22023';
    END IF;
  END LOOP;

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

  SELECT COALESCE(array_agg(DISTINCT work_row.project_id ORDER BY work_row.project_id),
                  ARRAY[]::uuid[])
  INTO v_project_ids
  FROM aep.works AS work_row
  WHERE work_row.work_id = ANY(v_work_ids);

  FOR v_project_id IN
    SELECT unnest(v_project_ids) AS project_id
    ORDER BY project_id
  LOOP
    PERFORM pg_advisory_xact_lock(
      hashtextextended('aep.context-project:' || v_project_id::text, 0)
    );
  END LOOP;

  RETURN aep.mutate_dependencies_unordered(p_graph_id,p_request_key,p_operations);
END
$function$;

ALTER FUNCTION aep.mutate_dependencies(uuid,text,jsonb) OWNER TO aep_owner;
REVOKE ALL ON FUNCTION aep.mutate_dependencies(uuid,text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION aep.mutate_dependencies(uuid,text,jsonb) TO aep_runtime;

ALTER TABLE aep.context_source_heads OWNER TO aep_owner;
ALTER TABLE aep.context_evidence_sizes OWNER TO aep_owner;
ALTER TABLE aep.context_packs OWNER TO aep_owner;
ALTER TABLE aep.context_retrieval_events OWNER TO aep_owner;
ALTER FUNCTION aep.reject_context_record_mutation() OWNER TO aep_owner;
ALTER FUNCTION aep.lock_context_resource(uuid[],boolean) OWNER TO aep_owner;
REVOKE ALL ON FUNCTION aep.lock_context_resource(uuid[],boolean)
  FROM PUBLIC,aep_runtime;
ALTER FUNCTION aep.lock_context_project_write() OWNER TO aep_owner;
ALTER FUNCTION aep.capture_context_evidence_sizes() OWNER TO aep_owner;
ALTER FUNCTION aep.context_project_resource_allowed(uuid,uuid,boolean) OWNER TO aep_owner;
ALTER FUNCTION aep.build_context_pack_snapshot(uuid,uuid,uuid,text) OWNER TO aep_owner;
ALTER FUNCTION aep.record_context_source_revision(uuid,uuid,uuid,text,uuid,text,text,text,jsonb)
  OWNER TO aep_owner;
ALTER FUNCTION aep.compile_context_pack(uuid,uuid,uuid,text,uuid,integer,text,text,text)
  OWNER TO aep_owner;
ALTER FUNCTION aep.get_context_pack(uuid,uuid,integer,text,text,text) OWNER TO aep_owner;

DO $policy$
DECLARE
  table_name text;
BEGIN
  FOREACH table_name IN ARRAY ARRAY[
    'context_source_heads','context_evidence_sizes','context_packs','context_retrieval_events'
  ] LOOP
    EXECUTE format('ALTER TABLE aep.%I ENABLE ROW LEVEL SECURITY',table_name);
    EXECUTE format('ALTER TABLE aep.%I FORCE ROW LEVEL SECURITY',table_name);
    EXECUTE format(
      'CREATE POLICY owner_full_access ON aep.%I FOR ALL TO aep_owner USING (true) WITH CHECK (true)',
      table_name
    );
  END LOOP;
END
$policy$;

REVOKE ALL ON TABLE aep.context_source_heads,aep.context_evidence_sizes,aep.context_packs,aep.context_retrieval_events
  FROM PUBLIC,aep_runtime;
REVOKE ALL ON FUNCTION aep.reject_context_record_mutation() FROM PUBLIC,aep_runtime;
REVOKE ALL ON FUNCTION aep.lock_context_project_write() FROM PUBLIC,aep_runtime;
REVOKE ALL ON FUNCTION aep.capture_context_evidence_sizes() FROM PUBLIC,aep_runtime;
REVOKE ALL ON FUNCTION aep.context_project_resource_allowed(uuid,uuid,boolean) FROM PUBLIC,aep_runtime;
REVOKE ALL ON FUNCTION aep.build_context_pack_snapshot(uuid,uuid,uuid,text) FROM PUBLIC,aep_runtime;
REVOKE ALL ON FUNCTION aep.record_context_source_revision(uuid,uuid,uuid,text,uuid,text,text,text,jsonb)
  FROM PUBLIC;
REVOKE ALL ON FUNCTION aep.compile_context_pack(uuid,uuid,uuid,text,uuid,integer,text,text,text)
  FROM PUBLIC;
REVOKE ALL ON FUNCTION aep.get_context_pack(uuid,uuid,integer,text,text,text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION aep.record_context_source_revision(uuid,uuid,uuid,text,uuid,text,text,text,jsonb)
  TO aep_runtime;
GRANT EXECUTE ON FUNCTION aep.compile_context_pack(uuid,uuid,uuid,text,uuid,integer,text,text,text)
  TO aep_runtime;
GRANT EXECUTE ON FUNCTION aep.get_context_pack(uuid,uuid,integer,text,text,text)
  TO aep_runtime;

COMMIT;
