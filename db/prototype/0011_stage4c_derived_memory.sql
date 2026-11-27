-- Stage 4C: deterministic, source-pinned derived memory.
-- Disposable PostgreSQL prototype only. Raw Evidence remains authoritative.
BEGIN;

-- Keep the Stage 4B source snapshot implementation intact. The logical builder
-- name becomes a wrapper that adds only currently-valid derived memory.
ALTER FUNCTION aep.build_context_pack_snapshot(uuid,uuid,uuid,text)
  RENAME TO build_context_pack_snapshot_stage4b;

CREATE TABLE aep.derived_memories (
  derived_memory_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id uuid NOT NULL,
  work_id uuid NOT NULL,
  resource_id uuid NOT NULL,
  resource_ref text NOT NULL CHECK (length(btrim(resource_ref)) BETWEEN 1 AND 255),
  source_snapshot_sha256 text NOT NULL CHECK (source_snapshot_sha256 ~ '^[0-9a-f]{64}$'),
  source_snapshot jsonb NOT NULL CHECK (jsonb_typeof(source_snapshot) = 'object'),
  source_evidence_ids uuid[] NOT NULL CHECK (cardinality(source_evidence_ids) > 0),
  source_work_ids uuid[] NOT NULL CHECK (cardinality(source_work_ids) > 0),
  source_evidence_manifest jsonb NOT NULL CHECK (jsonb_typeof(source_evidence_manifest) = 'array'),
  memory_content jsonb NOT NULL CHECK (jsonb_typeof(memory_content) = 'object'),
  memory_text text NOT NULL,
  search_vector tsvector GENERATED ALWAYS AS (
    to_tsvector('simple'::regconfig, memory_text)
  ) STORED,
  observed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  valid_at timestamptz,
  extractor_version text NOT NULL CHECK (length(btrim(extractor_version)) BETWEEN 1 AND 100),
  model_version text NOT NULL CHECK (length(btrim(model_version)) BETWEEN 1 AND 100),
  schema_version text NOT NULL CHECK (length(btrim(schema_version)) BETWEEN 1 AND 100),
  status text NOT NULL DEFAULT 'ready' CHECK (status IN ('ready','invalidated')),
  invalidated_at timestamptz,
  invalidation_reason text,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  FOREIGN KEY (project_id,work_id) REFERENCES aep.works(project_id,work_id),
  FOREIGN KEY (project_id,resource_id) REFERENCES aep.project_resources(project_id,resource_id),
  CHECK (
    (status = 'ready' AND invalidated_at IS NULL AND invalidation_reason IS NULL)
    OR (status = 'invalidated' AND invalidated_at IS NOT NULL
        AND length(btrim(invalidation_reason)) > 0)
  )
);

-- Only one current projection per project/work/repository ref. Invalidated rows
-- remain available as provenance history and can never be reactivated.
CREATE UNIQUE INDEX derived_memories_one_ready_per_scope_uq
  ON aep.derived_memories(project_id,work_id,resource_id,resource_ref)
  WHERE status = 'ready';
CREATE INDEX derived_memories_project_work_idx
  ON aep.derived_memories(project_id,work_id,observed_at DESC);
CREATE INDEX derived_memories_search_idx
  ON aep.derived_memories USING gin(search_vector);

CREATE FUNCTION aep.reject_derived_memory_content_mutation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, aep
AS $function$
BEGIN
  IF (to_jsonb(NEW) - 'status' - 'invalidated_at' - 'invalidation_reason')
       IS DISTINCT FROM
     (to_jsonb(OLD) - 'status' - 'invalidated_at' - 'invalidation_reason') THEN
    RAISE EXCEPTION 'Derived memory content and provenance are immutable'
      USING ERRCODE = '55000';
  END IF;
  IF OLD.status <> 'ready' OR NEW.status <> 'invalidated'
     OR NEW.invalidated_at IS NULL
     OR NEW.invalidation_reason IS NULL
     OR length(btrim(NEW.invalidation_reason)) = 0 THEN
    RAISE EXCEPTION 'Derived memory lifecycle only permits ready -> invalidated'
      USING ERRCODE = '55000';
  END IF;
  RETURN NEW;
END
$function$;

CREATE TRIGGER derived_memories_content_immutable
BEFORE UPDATE ON aep.derived_memories
FOR EACH ROW EXECUTE FUNCTION aep.reject_derived_memory_content_mutation();

CREATE TRIGGER derived_memories_no_delete
BEFORE DELETE ON aep.derived_memories
FOR EACH ROW EXECUTE FUNCTION aep.reject_context_record_mutation();

CREATE FUNCTION aep.invalidate_derived_memory_scope(p_scope_type text,p_scope_key text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, aep
AS $function$
DECLARE
  v_scope_id uuid;
BEGIN
  IF p_scope_key !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
    RETURN;
  END IF;
  v_scope_id := p_scope_key::uuid;

  IF p_scope_type = 'project' THEN
    UPDATE aep.derived_memories
    SET status='invalidated',invalidated_at=clock_timestamp(),
        invalidation_reason='owner_decision_changed'
    WHERE project_id=v_scope_id AND status='ready';
  ELSIF p_scope_type = 'resource' THEN
    UPDATE aep.derived_memories
    SET status='invalidated',invalidated_at=clock_timestamp(),
        invalidation_reason='owner_decision_changed'
    WHERE resource_id=v_scope_id AND status='ready';
  ELSIF p_scope_type = 'work' THEN
    UPDATE aep.derived_memories
    SET status='invalidated',invalidated_at=clock_timestamp(),
        invalidation_reason='owner_decision_changed'
    WHERE source_work_ids @> ARRAY[v_scope_id] AND status='ready';
  END IF;
END
$function$;

CREATE FUNCTION aep.invalidate_derived_memory_on_evidence_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, aep
AS $function$
BEGIN
  IF NEW.work_id IS NOT NULL THEN
    UPDATE aep.derived_memories
    SET status='invalidated',invalidated_at=clock_timestamp(),
        invalidation_reason='source_evidence_appended'
    WHERE project_id=NEW.project_id
      AND source_work_ids @> ARRAY[NEW.work_id]
      AND status='ready';
  END IF;
  RETURN NEW;
END
$function$;

CREATE TRIGGER derived_memory_evidence_invalidation
AFTER INSERT ON aep.evidence
FOR EACH ROW EXECUTE FUNCTION aep.invalidate_derived_memory_on_evidence_insert();

CREATE FUNCTION aep.invalidate_derived_memory_on_decision_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, aep
AS $function$
BEGIN
  IF TG_OP <> 'INSERT' THEN
    PERFORM aep.invalidate_derived_memory_scope(OLD.scope_type,OLD.scope_key);
  END IF;
  IF TG_OP <> 'DELETE' THEN
    PERFORM aep.invalidate_derived_memory_scope(NEW.scope_type,NEW.scope_key);
  END IF;
  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END
$function$;

CREATE TRIGGER derived_memory_decision_invalidation
AFTER INSERT OR UPDATE OR DELETE ON aep.owner_decisions
FOR EACH ROW EXECUTE FUNCTION aep.invalidate_derived_memory_on_decision_change();

CREATE FUNCTION aep.invalidate_derived_memory_on_source_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, aep
AS $function$
DECLARE
  v_project_id uuid;
  v_work_id uuid;
  v_resource_id uuid;
  v_resource_ref text;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_project_id := OLD.project_id;
    v_work_id := OLD.work_id;
    v_resource_id := OLD.resource_id;
    v_resource_ref := OLD.resource_ref;
  ELSE
    v_project_id := NEW.project_id;
    v_work_id := NEW.work_id;
    v_resource_id := NEW.resource_id;
    v_resource_ref := NEW.resource_ref;
  END IF;

  UPDATE aep.derived_memories
  SET status='invalidated',invalidated_at=clock_timestamp(),
      invalidation_reason='repository_source_revision_changed'
  WHERE project_id=v_project_id AND work_id=v_work_id
    AND resource_id=v_resource_id AND resource_ref=v_resource_ref
    AND status='ready';

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END
$function$;

CREATE TRIGGER derived_memory_source_head_invalidation
AFTER INSERT OR UPDATE OR DELETE ON aep.context_source_heads
FOR EACH ROW EXECUTE FUNCTION aep.invalidate_derived_memory_on_source_change();

CREATE FUNCTION aep.invalidate_derived_memory_on_dependency_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, aep
AS $function$
DECLARE
  v_work_id uuid;
BEGIN
  IF TG_OP <> 'INSERT' THEN
    v_work_id := OLD.source_work_id;
    UPDATE aep.derived_memories
    SET status='invalidated',invalidated_at=clock_timestamp(),
        invalidation_reason='dependency_source_set_changed'
    WHERE source_work_ids @> ARRAY[v_work_id] AND status='ready';
  END IF;
  IF TG_OP <> 'DELETE' THEN
    v_work_id := NEW.source_work_id;
    UPDATE aep.derived_memories
    SET status='invalidated',invalidated_at=clock_timestamp(),
        invalidation_reason='dependency_source_set_changed'
    WHERE source_work_ids @> ARRAY[v_work_id] AND status='ready';
  END IF;
  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END
$function$;

CREATE TRIGGER derived_memory_dependency_invalidation
AFTER INSERT OR UPDATE OR DELETE ON aep.work_relations
FOR EACH ROW EXECUTE FUNCTION aep.invalidate_derived_memory_on_dependency_change();

CREATE FUNCTION aep.build_context_pack_snapshot(
  p_project_id uuid,p_work_id uuid,p_resource_id uuid,p_resource_ref text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, aep
AS $function$
DECLARE
  v_snapshot jsonb;
  v_memory jsonb;
BEGIN
  v_snapshot := aep.build_context_pack_snapshot_stage4b(
    p_project_id,p_work_id,p_resource_id,p_resource_ref
  );

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'derived_memory_id',memory_row.derived_memory_id,
    'source_snapshot_sha256',memory_row.source_snapshot_sha256,
    'source_count',cardinality(memory_row.source_evidence_ids),
    'observed_at',memory_row.observed_at,
    'valid_at',memory_row.valid_at,
    'extractor_version',memory_row.extractor_version,
    'model_version',memory_row.model_version,
    'schema_version',memory_row.schema_version,
    'memory_content',memory_row.memory_content
  ) ORDER BY memory_row.observed_at DESC,memory_row.derived_memory_id),'[]'::jsonb)
  INTO v_memory
  FROM aep.derived_memories AS memory_row
  WHERE memory_row.project_id=p_project_id
    AND memory_row.work_id=p_work_id
    AND memory_row.resource_id=p_resource_id
    AND memory_row.resource_ref=p_resource_ref
    AND memory_row.status='ready';

  RETURN v_snapshot || jsonb_build_object('derived_memory',v_memory);
END
$function$;

CREATE FUNCTION aep.rebuild_derived_memory(
  p_project_id uuid,
  p_work_id uuid,
  p_resource_id uuid,
  p_resource_ref text,
  p_session_id uuid,
  p_extractor_version text,
  p_model_version text,
  p_schema_version text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, aep, public
AS $function$
DECLARE
  v_snapshot jsonb;
  v_source_work_ids uuid[];
  v_source_evidence_ids uuid[];
  v_evidence_manifest jsonb;
  v_memory_content jsonb;
  v_memory_text text;
  v_source_snapshot jsonb;
  v_snapshot_sha256 text;
  v_valid_at timestamptz;
  v_observed_at timestamptz := clock_timestamp();
  v_existing aep.derived_memories%ROWTYPE;
  v_memory_id uuid;
  v_count integer;
BEGIN
  IF p_project_id IS NULL OR p_work_id IS NULL OR p_resource_id IS NULL OR p_session_id IS NULL THEN
    RAISE EXCEPTION 'Project, Work, Resource and session provenance are required'
      USING ERRCODE='22004';
  END IF;
  IF p_resource_ref IS NULL OR NOT aep.is_canonical_github_branch_ref(p_resource_ref) THEN
    RAISE EXCEPTION 'A canonical GitHub branch ref is required' USING ERRCODE='22023';
  END IF;
  IF p_extractor_version IS NULL OR length(btrim(p_extractor_version)) NOT BETWEEN 1 AND 100
     OR p_model_version IS NULL OR length(btrim(p_model_version)) NOT BETWEEN 1 AND 100
     OR p_schema_version IS NULL OR length(btrim(p_schema_version)) NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'Extractor, model and schema versions are required'
      USING ERRCODE='22023';
  END IF;

  -- Authorization precedes the first Work/Evidence/Decision/Memory read.
  -- The shared gate also enforces the READ COMMITTED transaction contract.
  IF NOT aep.context_project_resource_allowed(p_project_id,p_resource_id) THEN
    RETURN jsonb_build_object('status','denied','reason','project_scope_unavailable','source_count',0);
  END IF;

  -- Reuse the existing bounded Evidence selection and provenance rules.
  v_snapshot := aep.build_context_pack_snapshot_stage4b(
    p_project_id,p_work_id,p_resource_id,p_resource_ref
  );

  -- Rebuilds for this exact scope serialize after authorization. Source writers
  -- already hold the exclusive Resource/Project lock before their row changes.
  PERFORM pg_advisory_xact_lock(hashtextextended(
    'aep.derived-memory:' || p_project_id::text || ':' || p_work_id::text
      || ':' || p_resource_id::text || ':' || p_resource_ref,0
  ));

  SELECT ARRAY(
    SELECT DISTINCT source_work_id
    FROM (
      SELECT p_work_id AS source_work_id
      UNION ALL
      SELECT (dependency_row.value->>'target_work_id')::uuid
      FROM jsonb_array_elements(COALESCE(v_snapshot->'dependencies','[]'::jsonb))
        AS dependency_row(value)
    ) AS source_work_rows
    ORDER BY source_work_id
  ) INTO v_source_work_ids;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'evidence_id',evidence_row.value->'evidence_id',
    'work_id',evidence_row.value->'work_id',
    'evidence_type',evidence_row.value->'evidence_type',
    'source_ref',evidence_row.value->'source_ref',
    'source_revision',evidence_row.value->'source_revision',
    'content_sha256',evidence_row.value->'content_sha256',
    'payload_sha256',evidence_row.value->'payload_sha256',
    'observed_at',evidence_row.value->'observed_at',
    'valid_at',evidence_row.value->'valid_at'
  ) ORDER BY evidence_row.value->>'observed_at' DESC,
             evidence_row.value->>'evidence_id' DESC),'[]'::jsonb)
  INTO v_evidence_manifest
  FROM jsonb_array_elements(COALESCE(v_snapshot->'evidence','[]'::jsonb))
    AS evidence_row(value);

  v_count := jsonb_array_length(v_evidence_manifest);
  IF v_count=0 THEN
    RETURN jsonb_build_object('status','empty','source_count',0);
  END IF;

  SELECT
    array_agg((evidence_row.value->>'evidence_id')::uuid
      ORDER BY evidence_row.value->>'observed_at' DESC,
               evidence_row.value->>'evidence_id' DESC),
    jsonb_build_object(
      'kind','evidence-derived-memory',
      'source_count',v_count,
      'included_count',least(v_count,16),
      'truncated_count',greatest(v_count-16,0),
      'items',(
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
          'evidence_id',selected.value->'evidence_id',
          'evidence_type',selected.value->'evidence_type',
          'source_ref',selected.value->'source_ref',
          'content_sha256',selected.value->'content_sha256',
          'text',left(COALESCE(
            NULLIF(selected.value->'payload'->>'text',''),
            NULLIF(selected.value->'payload'->>'summary',''),
            NULLIF(selected.value->'payload'->>'statement',''),
            NULLIF(selected.value->'payload'->>'content',''),
            (selected.value->'payload')::text
          ),512)
        ) ORDER BY selected.value->>'observed_at' DESC,
                   selected.value->>'evidence_id' DESC),'[]'::jsonb)
        FROM (
          SELECT evidence_item.value
          FROM jsonb_array_elements(COALESCE(v_snapshot->'evidence','[]'::jsonb))
            AS evidence_item(value)
          ORDER BY evidence_item.value->>'observed_at' DESC,
                   evidence_item.value->>'evidence_id' DESC
          LIMIT 16
        ) AS selected
      )
    ),
    string_agg(
      concat_ws(' ',
        evidence_row.value->>'evidence_type',
        evidence_row.value->>'source_ref',
        COALESCE(
          evidence_row.value->'payload'->>'text',
          evidence_row.value->'payload'->>'summary',
          evidence_row.value->'payload'->>'statement',
          evidence_row.value->'payload'->>'content',
          (evidence_row.value->'payload')::text
        )
      ),
      E'\n' ORDER BY evidence_row.value->>'observed_at' DESC,
                 evidence_row.value->>'evidence_id' DESC
    )
  INTO v_source_evidence_ids,v_memory_content,v_memory_text
  FROM jsonb_array_elements(COALESCE(v_snapshot->'evidence','[]'::jsonb))
    AS evidence_row(value);

  SELECT CASE
    WHEN count(*)>0
     AND count(*) FILTER (WHERE evidence_row.value->>'valid_at' IS NULL)=0
     AND count(DISTINCT evidence_row.value->>'valid_at')=1
    THEN min((evidence_row.value->>'valid_at')::timestamptz)
    ELSE NULL
  END
  INTO v_valid_at
  FROM jsonb_array_elements(COALESCE(v_snapshot->'evidence','[]'::jsonb))
    AS evidence_row(value);

  v_source_snapshot := jsonb_build_object(
    'project_id',p_project_id,
    'work_id',p_work_id,
    'resource_id',p_resource_id,
    'resource_ref',p_resource_ref,
    'repository_revision',v_snapshot->'repository_revision',
    'source_work_ids',to_jsonb(v_source_work_ids),
    'decisions',v_snapshot->'decisions',
    'evidence_summary',v_snapshot->'evidence_summary',
    'source_evidence',v_evidence_manifest
  );
  v_snapshot_sha256 := encode(public.digest(convert_to(jsonb_build_object(
    'source_snapshot',v_source_snapshot,
    'extractor_version',p_extractor_version,
    'model_version',p_model_version,
    'schema_version',p_schema_version
  )::text,'UTF8'),'sha256'),'hex');

  SELECT memory_row.* INTO v_existing
  FROM aep.derived_memories AS memory_row
  WHERE memory_row.project_id=p_project_id
    AND memory_row.work_id=p_work_id
    AND memory_row.resource_id=p_resource_id
    AND memory_row.resource_ref=p_resource_ref
    AND memory_row.status='ready'
  FOR UPDATE;

  IF FOUND
     AND v_existing.source_snapshot_sha256=v_snapshot_sha256
     AND v_existing.extractor_version=p_extractor_version
     AND v_existing.model_version=p_model_version
     AND v_existing.schema_version=p_schema_version THEN
    RETURN jsonb_build_object(
      'status','ready','reused',true,
      'derived_memory_id',v_existing.derived_memory_id,
      'source_snapshot_sha256',v_existing.source_snapshot_sha256,
      'source_count',cardinality(v_existing.source_evidence_ids),
      'memory_content',v_existing.memory_content,
      'observed_at',v_existing.observed_at,
      'valid_at',v_existing.valid_at
    );
  END IF;

  UPDATE aep.derived_memories
  SET status='invalidated',invalidated_at=clock_timestamp(),
      invalidation_reason='source_snapshot_or_extractor_version_changed'
  WHERE project_id=p_project_id AND work_id=p_work_id
    AND resource_id=p_resource_id AND resource_ref=p_resource_ref
    AND status='ready';

  INSERT INTO aep.derived_memories(
    project_id,work_id,resource_id,resource_ref,
    source_snapshot_sha256,source_snapshot,
    source_evidence_ids,source_work_ids,source_evidence_manifest,
    memory_content,memory_text,observed_at,valid_at,
    extractor_version,model_version,schema_version,status
  ) VALUES (
    p_project_id,p_work_id,p_resource_id,p_resource_ref,
    v_snapshot_sha256,v_source_snapshot,
    v_source_evidence_ids,v_source_work_ids,v_evidence_manifest,
    v_memory_content,v_memory_text,v_observed_at,v_valid_at,
    p_extractor_version,p_model_version,p_schema_version,'ready'
  )
  RETURNING derived_memory_id INTO v_memory_id;

  RETURN jsonb_build_object(
    'status','ready','reused',false,
    'derived_memory_id',v_memory_id,
    'source_snapshot_sha256',v_snapshot_sha256,
    'source_count',v_count,
    'memory_content',v_memory_content,
    'observed_at',v_observed_at,
    'valid_at',v_valid_at
  );
END
$function$;

-- The Context Pack snapshot fingerprint now includes valid derived memory.
CREATE FUNCTION aep.build_context_pack_snapshot(
  p_project_id uuid,p_work_id uuid,p_resource_id uuid,p_resource_ref text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, aep
AS $function$
DECLARE
  v_snapshot jsonb;
  v_memory jsonb;
BEGIN
  v_snapshot := aep.build_context_pack_snapshot_stage4b(
    p_project_id,p_work_id,p_resource_id,p_resource_ref
  );

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'derived_memory_id',memory_row.derived_memory_id,
    'source_snapshot_sha256',memory_row.source_snapshot_sha256,
    'source_count',cardinality(memory_row.source_evidence_ids),
    'observed_at',memory_row.observed_at,
    'valid_at',memory_row.valid_at,
    'extractor_version',memory_row.extractor_version,
    'model_version',memory_row.model_version,
    'schema_version',memory_row.schema_version,
    'memory_content',memory_row.memory_content
  ) ORDER BY memory_row.observed_at DESC,memory_row.derived_memory_id),'[]'::jsonb)
  INTO v_memory
  FROM aep.derived_memories AS memory_row
  WHERE memory_row.project_id=p_project_id
    AND memory_row.work_id=p_work_id
    AND memory_row.resource_id=p_resource_id
    AND memory_row.resource_ref=p_resource_ref
    AND memory_row.status='ready';

  RETURN v_snapshot || jsonb_build_object('derived_memory',v_memory);
END
$function$;

ALTER TABLE aep.derived_memories OWNER TO aep_owner;
ALTER FUNCTION aep.reject_derived_memory_content_mutation() OWNER TO aep_owner;
ALTER FUNCTION aep.invalidate_derived_memory_scope(text,text) OWNER TO aep_owner;
ALTER FUNCTION aep.invalidate_derived_memory_on_evidence_insert() OWNER TO aep_owner;
ALTER FUNCTION aep.invalidate_derived_memory_on_decision_change() OWNER TO aep_owner;
ALTER FUNCTION aep.invalidate_derived_memory_on_source_change() OWNER TO aep_owner;
ALTER FUNCTION aep.invalidate_derived_memory_on_dependency_change() OWNER TO aep_owner;
ALTER FUNCTION aep.build_context_pack_snapshot(uuid,uuid,uuid,text) OWNER TO aep_owner;
ALTER FUNCTION aep.rebuild_derived_memory(uuid,uuid,uuid,text,uuid,text,text,text) OWNER TO aep_owner;

ALTER TABLE aep.derived_memories ENABLE ROW LEVEL SECURITY;
ALTER TABLE aep.derived_memories FORCE ROW LEVEL SECURITY;
CREATE POLICY owner_full_access ON aep.derived_memories
  FOR ALL TO aep_owner USING (true) WITH CHECK (true);

REVOKE ALL ON TABLE aep.derived_memories FROM PUBLIC,aep_runtime;
REVOKE ALL ON FUNCTION aep.reject_derived_memory_content_mutation() FROM PUBLIC,aep_runtime;
REVOKE ALL ON FUNCTION aep.invalidate_derived_memory_scope(text,text) FROM PUBLIC,aep_runtime;
REVOKE ALL ON FUNCTION aep.invalidate_derived_memory_on_evidence_insert() FROM PUBLIC,aep_runtime;
REVOKE ALL ON FUNCTION aep.invalidate_derived_memory_on_decision_change() FROM PUBLIC,aep_runtime;
REVOKE ALL ON FUNCTION aep.invalidate_derived_memory_on_source_change() FROM PUBLIC,aep_runtime;
REVOKE ALL ON FUNCTION aep.invalidate_derived_memory_on_dependency_change() FROM PUBLIC,aep_runtime;
REVOKE ALL ON FUNCTION aep.build_context_pack_snapshot_stage4b(uuid,uuid,uuid,text)
  FROM PUBLIC,aep_runtime;
REVOKE ALL ON FUNCTION aep.build_context_pack_snapshot(uuid,uuid,uuid,text)
  FROM PUBLIC,aep_runtime;
REVOKE ALL ON FUNCTION aep.rebuild_derived_memory(uuid,uuid,uuid,text,uuid,text,text,text)
  FROM PUBLIC;
REVOKE ALL ON FUNCTION aep.compile_context_pack(uuid,uuid,uuid,text,uuid,integer,text,text,text)
  FROM PUBLIC;

GRANT EXECUTE ON FUNCTION aep.rebuild_derived_memory(uuid,uuid,uuid,text,uuid,text,text,text)
  TO aep_runtime;

COMMIT;

CREATE OR REPLACE FUNCTION aep.compile_context_pack(
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
    'pack_schema_version',2,
    'derived_memory',COALESCE(v_snapshot->'derived_memory','[]'::jsonb),
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
