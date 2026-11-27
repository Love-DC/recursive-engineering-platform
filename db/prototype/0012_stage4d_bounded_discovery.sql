-- Stage 4D: active-session-only evidence discovery and bounded decomposition.
-- Disposable PostgreSQL 17.12 prototype. No scheduler, background worker, or LLM runtime.
-- Canonical Work registration reuses aep.register_work; this migration adds no second Work registry.
BEGIN;

CREATE TABLE aep.discovery_passes (
  pass_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id uuid NOT NULL REFERENCES aep.projects(project_id),
  resource_id uuid NOT NULL REFERENCES aep.resources(resource_id),
  session_id uuid NOT NULL,
  request_key text NOT NULL CHECK (length(btrim(request_key)) BETWEEN 1 AND 200),
  request_payload jsonb NOT NULL CHECK (jsonb_typeof(request_payload) = 'object'),
  source_list jsonb NOT NULL CHECK (jsonb_typeof(source_list) = 'array' AND jsonb_array_length(source_list) BETWEEN 1 AND 64),
  current_cursor jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(current_cursor) = 'object'),
  watermark jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(watermark) = 'object'),
  resume_cursor jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(resume_cursor) = 'object'),
  max_depth smallint NOT NULL CHECK (max_depth BETWEEN 0 AND 8),
  max_fanout smallint NOT NULL CHECK (max_fanout BETWEEN 1 AND 32),
  max_tool_calls smallint NOT NULL CHECK (max_tool_calls BETWEEN 1 AND 100),
  max_elapsed_ms integer NOT NULL CHECK (max_elapsed_ms BETWEEN 1000 AND 3600000),
  max_tokens bigint NOT NULL CHECK (max_tokens BETWEEN 128 AND 500000),
  max_cost_micros bigint NOT NULL CHECK (max_cost_micros BETWEEN 1 AND 100000000),
  max_no_progress smallint NOT NULL CHECK (max_no_progress BETWEEN 1 AND 20),
  tool_calls_used smallint NOT NULL DEFAULT 0 CHECK (tool_calls_used BETWEEN 0 AND 100),
  tokens_reserved bigint NOT NULL DEFAULT 0 CHECK (tokens_reserved >= 0),
  tokens_used bigint NOT NULL DEFAULT 0 CHECK (tokens_used >= 0),
  cost_reserved_micros bigint NOT NULL DEFAULT 0 CHECK (cost_reserved_micros >= 0),
  cost_used_micros bigint NOT NULL DEFAULT 0 CHECK (cost_used_micros >= 0),
  no_progress_count smallint NOT NULL DEFAULT 0 CHECK (no_progress_count >= 0),
  resume_from_pass_id uuid REFERENCES aep.discovery_passes(pass_id),
  status text NOT NULL DEFAULT 'running' CHECK (status IN ('running','stopped','completed')),
  stop_reason text CHECK (stop_reason IS NULL OR stop_reason IN (
    'tool_call_budget','token_budget','cost_budget','elapsed_budget',
    'depth_budget','fanout_budget','no_progress','session_yield','queue_ready'
  )),
  started_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  stopped_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE(project_id, resource_id, request_key),
  CHECK (
    (status = 'running' AND stop_reason IS NULL AND stopped_at IS NULL AND completed_at IS NULL)
    OR (status = 'stopped' AND stop_reason IS NOT NULL AND stopped_at IS NOT NULL AND completed_at IS NULL)
    OR (status = 'completed' AND stop_reason IS NULL AND stopped_at IS NULL AND completed_at IS NOT NULL)
  ),
  CHECK (tokens_reserved + tokens_used <= 1000000000),
  CHECK (cost_reserved_micros + cost_used_micros <= 1000000000000)
);

CREATE INDEX discovery_passes_scope_status_idx
  ON aep.discovery_passes(project_id, resource_id, status, started_at DESC);

CREATE TABLE aep.discovery_observations (
  observation_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pass_id uuid NOT NULL REFERENCES aep.discovery_passes(pass_id),
  project_id uuid NOT NULL REFERENCES aep.projects(project_id),
  resource_id uuid NOT NULL REFERENCES aep.resources(resource_id),
  call_key text NOT NULL CHECK (length(btrim(call_key)) BETWEEN 1 AND 160),
  reservation_payload jsonb NOT NULL CHECK (jsonb_typeof(reservation_payload) = 'object'),
  tool_name text NOT NULL CHECK (tool_name IN (
    'github_search','github_fetch','github_fetch_issue','github_fetch_pr',
    'github_fetch_commit','github_fetch_actions'
  )),
  source_kind text NOT NULL CHECK (length(btrim(source_kind)) BETWEEN 1 AND 80),
  source_ref text NOT NULL CHECK (length(btrim(source_ref)) BETWEEN 1 AND 2000),
  cursor_before jsonb NOT NULL CHECK (jsonb_typeof(cursor_before) = 'object'),
  cursor_after jsonb CHECK (cursor_after IS NULL OR jsonb_typeof(cursor_after) = 'object'),
  resume_cursor jsonb CHECK (resume_cursor IS NULL OR jsonb_typeof(resume_cursor) = 'object'),
  source_revision text,
  content_sha256 text CHECK (content_sha256 IS NULL OR content_sha256 ~ '^[0-9a-f]{64}$'),
  provenance jsonb CHECK (provenance IS NULL OR jsonb_typeof(provenance) = 'object'),
  raw_payload jsonb CHECK (raw_payload IS NULL OR jsonb_typeof(raw_payload) = 'object'),
  evidence_id uuid REFERENCES aep.evidence(evidence_id),
  result_sha256 text CHECK (result_sha256 IS NULL OR result_sha256 ~ '^[0-9a-f]{64}$'),
  result_payload jsonb CHECK (result_payload IS NULL OR jsonb_typeof(result_payload) = 'object'),
  estimated_tokens integer NOT NULL CHECK (estimated_tokens BETWEEN 0 AND 500000),
  estimated_cost_micros bigint NOT NULL CHECK (estimated_cost_micros BETWEEN 0 AND 100000000),
  actual_tokens integer CHECK (actual_tokens IS NULL OR actual_tokens BETWEEN 0 AND 1000000),
  actual_cost_micros bigint CHECK (actual_cost_micros IS NULL OR actual_cost_micros BETWEEN 0 AND 1000000000),
  status text NOT NULL DEFAULT 'reserved' CHECK (status IN ('reserved','completed')),
  decision text CHECK (decision IS NULL OR decision IN ('accepted','linked','skipped','approval_required','pending')),
  decision_reason text,
  candidate_payload jsonb CHECK (candidate_payload IS NULL OR jsonb_typeof(candidate_payload) = 'object'),
  candidate_fingerprint text CHECK (candidate_fingerprint IS NULL OR candidate_fingerprint ~ '^[0-9a-f]{64}$'),
  work_id uuid REFERENCES aep.works(work_id),
  parent_work_id uuid REFERENCES aep.works(work_id),
  parent_observation_id uuid REFERENCES aep.discovery_observations(observation_id),
  depth smallint CHECK (depth IS NULL OR depth BETWEEN 0 AND 16),
  required_child boolean,
  reserved_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  completed_at timestamptz,
  observed_at timestamptz,
  UNIQUE(pass_id, call_key),
  CHECK (
    (status = 'reserved' AND completed_at IS NULL AND observed_at IS NULL
      AND result_sha256 IS NULL AND evidence_id IS NULL AND decision IS NULL)
    OR
    (status = 'completed' AND completed_at IS NOT NULL AND observed_at IS NOT NULL
      AND result_sha256 IS NOT NULL AND evidence_id IS NOT NULL AND decision IS NOT NULL)
  ),
  CHECK (
    (status='reserved' AND parent_work_id IS NULL AND parent_observation_id IS NULL AND depth IS NULL)
    OR (status='completed' AND parent_work_id IS NULL AND parent_observation_id IS NULL AND depth=0)
    OR (status='completed' AND parent_work_id IS NOT NULL AND parent_observation_id IS NOT NULL AND depth>0)
  )
);

CREATE UNIQUE INDEX discovery_observations_one_reserved_per_pass_uq
  ON aep.discovery_observations(pass_id) WHERE status = 'reserved';
CREATE INDEX discovery_observations_project_created_idx
  ON aep.discovery_observations(project_id, resource_id, reserved_at DESC);
CREATE INDEX discovery_observations_parent_idx
  ON aep.discovery_observations(parent_work_id, decision) WHERE parent_work_id IS NOT NULL;

CREATE TABLE aep.discovery_pass_events (
  event_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pass_id uuid NOT NULL REFERENCES aep.discovery_passes(pass_id),
  project_id uuid NOT NULL REFERENCES aep.projects(project_id),
  resource_id uuid NOT NULL REFERENCES aep.resources(resource_id),
  session_id uuid NOT NULL,
  event_type text NOT NULL CHECK (event_type IN (
    'pass_started','pass_resumed','call_reserved','observation_recorded',
    'candidate_created','candidate_linked','candidate_skipped',
    'approval_required','candidate_pending','budget_stopped',
    'no_progress_stopped','pass_completed','pass_yielded'
  )),
  event_payload jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(event_payload) = 'object'),
  occurred_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX discovery_pass_events_scope_idx
  ON aep.discovery_pass_events(project_id, pass_id, occurred_at);

CREATE FUNCTION aep.reject_discovery_event_mutation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, aep
AS $function$
BEGIN
  RAISE EXCEPTION '% is append-only; % is forbidden', TG_TABLE_NAME, TG_OP
    USING ERRCODE = '55000';
END
$function$;

CREATE TRIGGER discovery_pass_events_append_only
BEFORE UPDATE OR DELETE ON aep.discovery_pass_events
FOR EACH ROW EXECUTE FUNCTION aep.reject_discovery_event_mutation();

CREATE FUNCTION aep.guard_discovery_observation_mutation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, aep
AS $function$
BEGIN
  IF TG_OP = 'DELETE' OR OLD.status <> 'reserved' OR NEW.status <> 'completed' THEN
    RAISE EXCEPTION 'Discovery observations are immutable after their single reserved-to-completed transition'
      USING ERRCODE = '55000';
  END IF;
  IF (to_jsonb(NEW) - ARRAY[
      'cursor_after','resume_cursor','source_revision','content_sha256','provenance',
      'raw_payload','evidence_id','result_sha256','result_payload','actual_tokens',
      'actual_cost_micros','status','decision','decision_reason','candidate_payload',
      'candidate_fingerprint','work_id','parent_work_id','parent_observation_id',
      'depth','required_child','completed_at','observed_at'
    ]) IS DISTINCT FROM
     (to_jsonb(OLD) - ARRAY[
      'cursor_after','resume_cursor','source_revision','content_sha256','provenance',
      'raw_payload','evidence_id','result_sha256','result_payload','actual_tokens',
      'actual_cost_micros','status','decision','decision_reason','candidate_payload',
      'candidate_fingerprint','work_id','parent_work_id','parent_observation_id',
      'depth','required_child','completed_at','observed_at'
    ]) THEN
    RAISE EXCEPTION 'Discovery reservation identity and budget estimate are immutable'
      USING ERRCODE = '55000';
  END IF;
  RETURN NEW;
END
$function$;

CREATE TRIGGER discovery_observations_single_completion
BEFORE UPDATE OR DELETE ON aep.discovery_observations
FOR EACH ROW EXECUTE FUNCTION aep.guard_discovery_observation_mutation();

-- Start a fresh bounded pass. A stopped pass is resumed by creating a new pass
-- with a new active-session ID; the old pass remains immutable history.
CREATE FUNCTION aep.start_discovery_pass(
  p_project_id uuid,
  p_resource_id uuid,
  p_session_id uuid,
  p_request_key text,
  p_source_list jsonb,
  p_cursor jsonb DEFAULT '{}'::jsonb,
  p_watermark jsonb DEFAULT '{}'::jsonb,
  p_limits jsonb DEFAULT '{}'::jsonb,
  p_resume_from_pass_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, aep, public
AS $function$
DECLARE
  v_resource aep.resources%ROWTYPE;
  v_prior aep.discovery_passes%ROWTYPE;
  v_existing aep.discovery_passes%ROWTYPE;
  v_source_list jsonb;
  v_cursor jsonb;
  v_watermark jsonb;
  v_limits jsonb;
  v_request_payload jsonb;
  v_root text;
  v_prefix text;
  v_kind text;
  v_source record;
  v_reserved_observation aep.discovery_observations%ROWTYPE;
  v_has_reserved_observation boolean := false;
  v_max_depth integer;
  v_max_fanout integer;
  v_max_tool_calls integer;
  v_max_elapsed_ms integer;
  v_max_tokens bigint;
  v_max_cost_micros bigint;
  v_max_no_progress integer;
  v_pass_id uuid;
  v_row_count integer;
BEGIN
  IF p_project_id IS NULL OR p_resource_id IS NULL OR p_session_id IS NULL THEN
    RAISE EXCEPTION 'Project, Resource and active session provenance are required'
      USING ERRCODE = '22004';
  END IF;
  IF p_request_key IS NULL OR length(btrim(p_request_key)) NOT BETWEEN 1 AND 200 THEN
    RAISE EXCEPTION 'Discovery request key must contain 1..200 characters'
      USING ERRCODE = '22023';
  END IF;
  IF p_limits IS NULL OR jsonb_typeof(p_limits) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'Discovery limits must be a JSON object' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_object_keys(p_limits) AS item(key)
    WHERE key NOT IN ('max_depth','max_fanout','max_tool_calls','max_elapsed_ms',
                      'max_tokens','max_cost_micros','max_no_progress')
  ) THEN
    RAISE EXCEPTION 'Unknown discovery budget key' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_each(p_limits) AS item(key,value)
    WHERE jsonb_typeof(value) IS DISTINCT FROM 'number'
       OR value::text !~ '^[0-9]+$'
  ) THEN
    RAISE EXCEPTION 'Discovery budget values must be non-negative integers'
      USING ERRCODE = '22023';
  END IF;

  v_max_depth := COALESCE((p_limits->>'max_depth')::integer, 2);
  v_max_fanout := COALESCE((p_limits->>'max_fanout')::integer, 8);
  v_max_tool_calls := COALESCE((p_limits->>'max_tool_calls')::integer, 20);
  v_max_elapsed_ms := COALESCE((p_limits->>'max_elapsed_ms')::integer, 600000);
  v_max_tokens := COALESCE((p_limits->>'max_tokens')::bigint, 20000);
  v_max_cost_micros := COALESCE((p_limits->>'max_cost_micros')::bigint, 1000000);
  v_max_no_progress := COALESCE((p_limits->>'max_no_progress')::integer, 4);

  IF v_max_depth NOT BETWEEN 0 AND 8
     OR v_max_fanout NOT BETWEEN 1 AND 32
     OR v_max_tool_calls NOT BETWEEN 1 AND 100
     OR v_max_elapsed_ms NOT BETWEEN 1000 AND 3600000
     OR v_max_tokens NOT BETWEEN 128 AND 500000
     OR v_max_cost_micros NOT BETWEEN 1 AND 100000000
     OR v_max_no_progress NOT BETWEEN 1 AND 20 THEN
    RAISE EXCEPTION 'Discovery budget exceeds the prototype hard ceiling'
      USING ERRCODE = '22023';
  END IF;
  v_limits := jsonb_build_object(
    'max_depth',v_max_depth,'max_fanout',v_max_fanout,
    'max_tool_calls',v_max_tool_calls,'max_elapsed_ms',v_max_elapsed_ms,
    'max_tokens',v_max_tokens,'max_cost_micros',v_max_cost_micros,
    'max_no_progress',v_max_no_progress
  );

  -- Authorization is checked before loading the Resource, previous pass, or any
  -- discovery observations. This is an active-session RPC, never a scheduled job.
  IF NOT aep.context_project_resource_allowed(p_project_id,p_resource_id,true) THEN
    RETURN jsonb_build_object('status','denied','reason','project_scope_unavailable');
  END IF;

  SELECT project_row.status INTO v_kind
  FROM aep.projects AS project_row
  WHERE project_row.project_id=p_project_id;
  IF NOT FOUND OR v_kind <> 'active' THEN
    RAISE EXCEPTION 'Discovery requires an active project' USING ERRCODE = '42501';
  END IF;
  IF EXISTS (SELECT 1 FROM aep.works WHERE project_id=p_project_id AND status='ready') THEN
    RETURN jsonb_build_object('status','queue_not_empty','ready_work_count',
      (SELECT count(*) FROM aep.works WHERE project_id=p_project_id AND status='ready'));
  END IF;
  SELECT * INTO v_resource FROM aep.resources
  WHERE resource_id=p_resource_id AND provider='github'
    AND resource_type='repository' AND status='active';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Discovery source must be an active GitHub repository Resource'
      USING ERRCODE = '42501';
  END IF;
  v_root := 'github://' || v_resource.host || '/' || v_resource.stable_resource_id;

  IF p_resume_from_pass_id IS NOT NULL THEN
    SELECT * INTO v_prior FROM aep.discovery_passes
    WHERE pass_id=p_resume_from_pass_id
    FOR UPDATE;
    IF NOT FOUND OR v_prior.project_id<>p_project_id
       OR v_prior.resource_id<>p_resource_id
       OR v_prior.status NOT IN ('running','stopped') THEN
      RAISE EXCEPTION 'Resume requires a running/stopped pass for the same project and Resource'
        USING ERRCODE = '22023';
    END IF;
    IF p_session_id=v_prior.session_id THEN
      RAISE EXCEPTION 'A resumed pass requires a new active-session ID'
        USING ERRCODE = '22023';
    END IF;
    SELECT * INTO v_reserved_observation
    FROM aep.discovery_observations
    WHERE pass_id=v_prior.pass_id AND status='reserved'
    FOR UPDATE;
    v_has_reserved_observation := FOUND;
    IF v_prior.status='running' AND NOT v_has_reserved_observation THEN
      RETURN jsonb_build_object(
        'status','active_session_may_still_be_running',
        'pass_id',v_prior.pass_id,
        'current_cursor',v_prior.current_cursor
      );
    END IF;
    IF v_prior.status='stopped' AND v_has_reserved_observation THEN
      RAISE EXCEPTION 'Stopped pass contains an unexpected reserved discovery call'
        USING ERRCODE = '55000';
    END IF;
    IF v_has_reserved_observation THEN
      -- A new session explicitly supersedes the old read reservation. The old
      -- model session may still return, but the stopped-pass check in
      -- complete_discovery_call fences that late result before Evidence/Work writes.
      -- Reads are side-effect-free, so the new pass retries from the pre-read cursor.
      UPDATE aep.discovery_passes SET
        status='stopped',stop_reason='session_yield',stopped_at=clock_timestamp(),
        resume_cursor=current_cursor,
        tokens_used=tokens_used+tokens_reserved,tokens_reserved=0,
        cost_used_micros=cost_used_micros+cost_reserved_micros,
        cost_reserved_micros=0,updated_at=clock_timestamp()
      WHERE pass_id=v_prior.pass_id
      RETURNING * INTO v_prior;
      INSERT INTO aep.discovery_pass_events(
        pass_id,project_id,resource_id,session_id,event_type,event_payload
      ) VALUES (
        v_prior.pass_id,p_project_id,p_resource_id,p_session_id,'pass_yielded',
        jsonb_build_object(
          'reason','superseded_inflight_read',
          'old_session_id',v_reserved_observation.pass_id,
          'observation_id',v_reserved_observation.observation_id,
          'late_result_disposition','ignored',
          'resume_cursor',v_prior.resume_cursor
        )
      );
      v_cursor := v_prior.resume_cursor;
      v_source_list := v_prior.source_list;
      v_watermark := v_prior.watermark;
    END IF;
    IF p_source_list IS NOT NULL AND p_source_list IS DISTINCT FROM v_prior.source_list THEN
      RAISE EXCEPTION 'A resumed pass must preserve its authorized source list'
        USING ERRCODE = '22023';
    END IF;
    v_source_list := v_prior.source_list;
    v_cursor := v_prior.resume_cursor;
    v_watermark := v_prior.watermark;
  ELSE
    IF p_source_list IS NULL OR jsonb_typeof(p_source_list) IS DISTINCT FROM 'array' THEN
      RAISE EXCEPTION 'Source list must be a JSON array' USING ERRCODE = '22023';
    END IF;
    IF jsonb_array_length(p_source_list) NOT BETWEEN 1 AND 64 THEN
      RAISE EXCEPTION 'Source list must contain 1..64 authorized source prefixes'
        USING ERRCODE = '22023';
    END IF;
    IF p_cursor IS NULL OR jsonb_typeof(p_cursor) IS DISTINCT FROM 'object'
       OR p_watermark IS NULL OR jsonb_typeof(p_watermark) IS DISTINCT FROM 'object' THEN
      RAISE EXCEPTION 'Cursor and watermark must be JSON objects' USING ERRCODE = '22023';
    END IF;
    FOR v_source IN
      SELECT item.value AS source,
             item.value->>'source_kind' AS source_kind,
             item.value->>'source_prefix' AS source_prefix
      FROM jsonb_array_elements(p_source_list) AS item(value)
    LOOP
      v_kind := v_source.source_kind;
      v_prefix := v_source.source_prefix;
      IF jsonb_typeof(v_source.source) IS DISTINCT FROM 'object'
         OR NOT (v_source.source ?& ARRAY['source_kind','source_prefix'])
         OR v_kind IS NULL OR length(btrim(v_kind)) NOT BETWEEN 1 AND 80
         OR v_prefix IS NULL OR length(btrim(v_prefix)) NOT BETWEEN length(v_root) AND 2000
         OR left(v_prefix,length(v_root)) <> v_root
         OR (length(v_prefix)>length(v_root)
             AND substring(v_prefix,length(v_root)+1,1) NOT IN ('/','?')) THEN
        RAISE EXCEPTION 'Each source prefix must be inside the authorized GitHub repository Resource'
          USING ERRCODE = '42501';
      END IF;
    END LOOP;
    IF (SELECT count(*) FROM jsonb_array_elements(p_source_list)) <>
       (SELECT count(DISTINCT (value->>'source_kind') || '|' || (value->>'source_prefix'))
        FROM jsonb_array_elements(p_source_list)) THEN
      RAISE EXCEPTION 'Duplicate source declarations are not allowed' USING ERRCODE = '22023';
    END IF;
    v_source_list := p_source_list;
    v_cursor := p_cursor;
    v_watermark := p_watermark;
  END IF;

  v_request_payload := jsonb_build_object(
    'session_id',p_session_id,
    'source_list',v_source_list,'cursor',v_cursor,'watermark',v_watermark,
    'limits',v_limits,'resume_from_pass_id',p_resume_from_pass_id
  );

  SELECT * INTO v_existing FROM aep.discovery_passes
  WHERE project_id=p_project_id AND resource_id=p_resource_id AND request_key=p_request_key
  FOR UPDATE;
  IF FOUND THEN
    IF v_existing.request_payload IS DISTINCT FROM v_request_payload THEN
      RAISE EXCEPTION 'Discovery request key reused with a different payload'
        USING ERRCODE = '22000';
    END IF;
    RETURN jsonb_build_object(
      'status',v_existing.status,'pass_id',v_existing.pass_id,
      'resume_cursor',v_existing.resume_cursor,'tool_calls_used',v_existing.tool_calls_used,
      'tokens_used',v_existing.tokens_used,'cost_used_micros',v_existing.cost_used_micros,
      'no_progress_count',v_existing.no_progress_count,'idempotent_replay',true
    );
  END IF;

  -- Independent active sessions may scan concurrently. The existing Work Registry's
  -- canonical identity constraint serializes duplicate candidates at commit time.

  INSERT INTO aep.discovery_passes(
    project_id,resource_id,session_id,request_key,request_payload,
    source_list,current_cursor,watermark,resume_cursor,
    max_depth,max_fanout,max_tool_calls,max_elapsed_ms,max_tokens,
    max_cost_micros,max_no_progress,resume_from_pass_id,
    tool_calls_used,tokens_used,cost_used_micros,no_progress_count
  ) VALUES (
    p_project_id,p_resource_id,p_session_id,p_request_key,v_request_payload,
    v_source_list,v_cursor,v_watermark,v_cursor,
    v_max_depth,v_max_fanout,v_max_tool_calls,v_max_elapsed_ms,v_max_tokens,
    v_max_cost_micros,v_max_no_progress,p_resume_from_pass_id,
    CASE WHEN v_prior.pass_id IS NULL THEN 0 ELSE v_prior.tool_calls_used END,
    CASE WHEN v_prior.pass_id IS NULL THEN 0 ELSE v_prior.tokens_used+v_prior.tokens_reserved END,
    CASE WHEN v_prior.pass_id IS NULL THEN 0 ELSE v_prior.cost_used_micros+v_prior.cost_reserved_micros END,
    CASE WHEN v_prior.pass_id IS NULL THEN 0 ELSE v_prior.no_progress_count END
  )
  ON CONFLICT(project_id,resource_id,request_key) DO NOTHING;
  GET DIAGNOSTICS v_row_count = ROW_COUNT;

  SELECT * INTO v_existing FROM aep.discovery_passes
  WHERE project_id=p_project_id AND resource_id=p_resource_id AND request_key=p_request_key
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Discovery pass registration could not be reconciled'
      USING ERRCODE = '40001';
  END IF;
  IF v_existing.request_payload IS DISTINCT FROM v_request_payload THEN
    RAISE EXCEPTION 'Discovery request key reused with a different payload'
      USING ERRCODE = '22000';
  END IF;
  IF v_row_count=1 THEN
    INSERT INTO aep.discovery_pass_events(pass_id,project_id,resource_id,session_id,event_type,event_payload)
    VALUES(v_existing.pass_id,p_project_id,p_resource_id,p_session_id,
      CASE WHEN p_resume_from_pass_id IS NULL THEN 'pass_started' ELSE 'pass_resumed' END,
      jsonb_build_object('resume_from_pass_id',p_resume_from_pass_id,'limits',v_limits));
  END IF;

  RETURN jsonb_build_object(
    'status',v_existing.status,'pass_id',v_existing.pass_id,
    'resume_cursor',v_existing.resume_cursor,'tool_calls_used',v_existing.tool_calls_used,
    'tokens_used',v_existing.tokens_used,'cost_used_micros',v_existing.cost_used_micros,
    'no_progress_count',v_existing.no_progress_count,'idempotent_replay',v_row_count=0
  );
END
$function$;

-- Reserve exactly one read-only tool call before the session invokes GitHub.
-- Estimates are reserved under a row lock, so concurrent sessions cannot overspend
-- the same pass. There are no external write operations in the discovery adapter.
CREATE FUNCTION aep.reserve_discovery_call(
  p_project_id uuid,
  p_resource_id uuid,
  p_pass_id uuid,
  p_session_id uuid,
  p_call_key text,
  p_tool_name text,
  p_source_kind text,
  p_source_ref text,
  p_cursor_before jsonb,
  p_estimated_tokens integer,
  p_estimated_cost_micros bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, aep, public
AS $function$
DECLARE
  v_pass aep.discovery_passes%ROWTYPE;
  v_existing aep.discovery_observations%ROWTYPE;
  v_resource aep.resources%ROWTYPE;
  v_reservation jsonb;
  v_prefix text;
  v_allowed boolean;
  v_elapsed bigint;
BEGIN
  IF NOT aep.context_project_resource_allowed(p_project_id,p_resource_id,true) THEN
    RETURN jsonb_build_object('status','denied','reason','project_scope_unavailable');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM aep.projects WHERE project_id=p_project_id AND status='active') THEN
    RETURN jsonb_build_object('status','denied','reason','project_inactive');
  END IF;
  IF p_call_key IS NULL OR length(btrim(p_call_key)) NOT BETWEEN 1 AND 160
     OR p_tool_name NOT IN ('github_search','github_fetch','github_fetch_issue','github_fetch_pr',
                            'github_fetch_commit','github_fetch_actions')
     OR p_source_kind IS NULL OR p_source_ref IS NULL OR length(btrim(p_source_ref)) NOT BETWEEN 1 AND 2000
     OR p_cursor_before IS NULL OR jsonb_typeof(p_cursor_before) IS DISTINCT FROM 'object'
     OR p_estimated_tokens IS NULL OR p_estimated_tokens NOT BETWEEN 0 AND 500000
     OR p_estimated_cost_micros IS NULL OR p_estimated_cost_micros NOT BETWEEN 0 AND 100000000 THEN
    RAISE EXCEPTION 'Discovery tool reservation fields are invalid' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_pass FROM aep.discovery_passes
  WHERE pass_id=p_pass_id AND project_id=p_project_id AND resource_id=p_resource_id
  FOR UPDATE;
  IF NOT FOUND OR v_pass.session_id<>p_session_id THEN
    RETURN jsonb_build_object('status','stopped','reason','pass_unavailable');
  END IF;

  v_reservation := jsonb_build_object(
    'tool_name',p_tool_name,'source_kind',p_source_kind,'source_ref',p_source_ref,
    'cursor_before',p_cursor_before,'estimated_tokens',p_estimated_tokens,
    'estimated_cost_micros',p_estimated_cost_micros
  );
  SELECT * INTO v_existing FROM aep.discovery_observations
  WHERE pass_id=p_pass_id AND call_key=p_call_key
  FOR UPDATE;
  IF FOUND THEN
    IF v_existing.reservation_payload IS DISTINCT FROM v_reservation THEN
      RAISE EXCEPTION 'Discovery call key reused with a different reservation payload'
        USING ERRCODE = '22000';
    END IF;
    RETURN jsonb_build_object(
      'status',v_existing.status,'observation_id',v_existing.observation_id,
      'idempotent_replay',true,'decision',v_existing.decision,
      'result',v_existing.result_payload
    );
  END IF;

  IF v_pass.status<>'running' THEN
    RETURN jsonb_build_object('status','stopped','reason','pass_unavailable');
  END IF;
  IF p_cursor_before IS DISTINCT FROM v_pass.current_cursor THEN
    RAISE EXCEPTION 'Discovery cursor is stale; resume from the persisted current cursor'
      USING ERRCODE = '40001';
  END IF;
  IF EXISTS (
    SELECT 1 FROM aep.discovery_observations
    WHERE pass_id=p_pass_id AND status='reserved'
  ) THEN
    RAISE EXCEPTION 'A discovery pass may have only one in-flight read tool call'
      USING ERRCODE = '55000';
  END IF;

  SELECT * INTO v_resource FROM aep.resources
  WHERE resource_id=p_resource_id AND status='active';
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status','denied','reason','resource_unavailable');
  END IF;
  SELECT EXISTS (
    SELECT 1
    FROM jsonb_array_elements(v_pass.source_list) AS source(value)
    WHERE source.value->>'source_kind'=p_source_kind
      AND left(p_source_ref,length(source.value->>'source_prefix'))=source.value->>'source_prefix'
      AND (
        right(source.value->>'source_prefix',1)='/'
        OR length(p_source_ref)=length(source.value->>'source_prefix')
        OR substring(p_source_ref,length(source.value->>'source_prefix')+1,1) IN ('/','?','#')
      )
  ) INTO v_allowed;
  IF NOT v_allowed THEN
    RAISE EXCEPTION 'Discovery source is outside the declared authorized source list'
      USING ERRCODE = '42501';
  END IF;
  IF EXISTS (SELECT 1 FROM aep.works WHERE project_id=p_project_id AND status='ready') THEN
    UPDATE aep.discovery_passes SET status='stopped',stop_reason='queue_ready',
      stopped_at=clock_timestamp(),resume_cursor=current_cursor,updated_at=clock_timestamp()
    WHERE pass_id=p_pass_id;
    INSERT INTO aep.discovery_pass_events(pass_id,project_id,resource_id,session_id,event_type,event_payload)
    VALUES(p_pass_id,p_project_id,p_resource_id,p_session_id,'budget_stopped',
      jsonb_build_object('reason','queue_ready','resume_cursor',v_pass.current_cursor));
    RETURN jsonb_build_object('status','stopped','reason','queue_not_empty',
      'resume_cursor',v_pass.current_cursor);
  END IF;

  IF v_pass.no_progress_count >= v_pass.max_no_progress THEN
    UPDATE aep.discovery_passes SET status='stopped',stop_reason='no_progress',
      stopped_at=clock_timestamp(),resume_cursor=current_cursor,updated_at=clock_timestamp()
    WHERE pass_id=p_pass_id;
    INSERT INTO aep.discovery_pass_events(pass_id,project_id,resource_id,session_id,event_type,event_payload)
    VALUES(p_pass_id,p_project_id,p_resource_id,p_session_id,'no_progress_stopped',
      jsonb_build_object('reason','no_progress','no_progress_count',v_pass.no_progress_count,
        'resume_cursor',v_pass.current_cursor));
    RETURN jsonb_build_object('status','stopped','reason','no_progress',
      'resume_cursor',v_pass.current_cursor,'no_progress_count',v_pass.no_progress_count);
  END IF;

  v_elapsed := floor(extract(epoch FROM (clock_timestamp()-v_pass.started_at))*1000)::bigint;
  IF v_elapsed >= v_pass.max_elapsed_ms THEN
    UPDATE aep.discovery_passes SET status='stopped',stop_reason='elapsed_budget',
      stopped_at=clock_timestamp(),resume_cursor=current_cursor,updated_at=clock_timestamp()
    WHERE pass_id=p_pass_id;
    INSERT INTO aep.discovery_pass_events(pass_id,project_id,resource_id,session_id,event_type,event_payload)
    VALUES(p_pass_id,p_project_id,p_resource_id,p_session_id,'budget_stopped',
      jsonb_build_object('reason','elapsed_budget','resume_cursor',v_pass.current_cursor));
    RETURN jsonb_build_object('status','stopped','reason','elapsed_budget',
      'resume_cursor',v_pass.current_cursor);
  END IF;
  IF v_pass.tool_calls_used >= v_pass.max_tool_calls THEN
    UPDATE aep.discovery_passes SET status='stopped',stop_reason='tool_call_budget',
      stopped_at=clock_timestamp(),resume_cursor=current_cursor,updated_at=clock_timestamp()
    WHERE pass_id=p_pass_id;
    INSERT INTO aep.discovery_pass_events(pass_id,project_id,resource_id,session_id,event_type,event_payload)
    VALUES(p_pass_id,p_project_id,p_resource_id,p_session_id,'budget_stopped',
      jsonb_build_object('reason','tool_call_budget','resume_cursor',v_pass.current_cursor));
    RETURN jsonb_build_object('status','stopped','reason','tool_call_budget',
      'resume_cursor',v_pass.current_cursor);
  END IF;
  IF v_pass.tokens_used+v_pass.tokens_reserved+p_estimated_tokens > v_pass.max_tokens THEN
    UPDATE aep.discovery_passes SET status='stopped',stop_reason='token_budget',
      stopped_at=clock_timestamp(),resume_cursor=current_cursor,updated_at=clock_timestamp()
    WHERE pass_id=p_pass_id;
    INSERT INTO aep.discovery_pass_events(pass_id,project_id,resource_id,session_id,event_type,event_payload)
    VALUES(p_pass_id,p_project_id,p_resource_id,p_session_id,'budget_stopped',
      jsonb_build_object('reason','token_budget','resume_cursor',v_pass.current_cursor));
    RETURN jsonb_build_object('status','stopped','reason','token_budget',
      'resume_cursor',v_pass.current_cursor);
  END IF;
  IF v_pass.cost_used_micros+v_pass.cost_reserved_micros+p_estimated_cost_micros > v_pass.max_cost_micros THEN
    UPDATE aep.discovery_passes SET status='stopped',stop_reason='cost_budget',
      stopped_at=clock_timestamp(),resume_cursor=current_cursor,updated_at=clock_timestamp()
    WHERE pass_id=p_pass_id;
    INSERT INTO aep.discovery_pass_events(pass_id,project_id,resource_id,session_id,event_type,event_payload)
    VALUES(p_pass_id,p_project_id,p_resource_id,p_session_id,'budget_stopped',
      jsonb_build_object('reason','cost_budget','resume_cursor',v_pass.current_cursor));
    RETURN jsonb_build_object('status','stopped','reason','cost_budget',
      'resume_cursor',v_pass.current_cursor);
  END IF;

  INSERT INTO aep.discovery_observations(
    pass_id,project_id,resource_id,call_key,reservation_payload,tool_name,
    source_kind,source_ref,cursor_before,estimated_tokens,estimated_cost_micros
  ) VALUES (
    p_pass_id,p_project_id,p_resource_id,p_call_key,v_reservation,p_tool_name,
    p_source_kind,p_source_ref,p_cursor_before,p_estimated_tokens,p_estimated_cost_micros
  ) RETURNING * INTO v_existing;

  UPDATE aep.discovery_passes SET
    tool_calls_used=tool_calls_used+1,
    tokens_reserved=tokens_reserved+p_estimated_tokens,
    cost_reserved_micros=cost_reserved_micros+p_estimated_cost_micros,
    updated_at=clock_timestamp()
  WHERE pass_id=p_pass_id;

  INSERT INTO aep.discovery_pass_events(pass_id,project_id,resource_id,session_id,event_type,event_payload)
  VALUES(p_pass_id,p_project_id,p_resource_id,p_session_id,'call_reserved',
    jsonb_build_object('observation_id',v_existing.observation_id,'call_key',p_call_key,
      'tool_name',p_tool_name,'estimated_tokens',p_estimated_tokens,
      'estimated_cost_micros',p_estimated_cost_micros));

  RETURN jsonb_build_object('status','reserved','observation_id',v_existing.observation_id,
    'tool_calls_used',v_pass.tool_calls_used+1,'tokens_reserved',v_pass.tokens_reserved+p_estimated_tokens,
    'cost_reserved_micros',v_pass.cost_reserved_micros+p_estimated_cost_micros);
END
$function$;

-- Commit one read result, its immutable raw Evidence, and (when allowed) canonical
-- Work registration in the same database transaction. The external read itself
-- has already happened in the active session; this RPC performs no provider writes.
CREATE FUNCTION aep.complete_discovery_call(
  p_project_id uuid,
  p_resource_id uuid,
  p_pass_id uuid,
  p_session_id uuid,
  p_call_key text,
  p_source_revision text,
  p_content_sha256 text,
  p_provenance jsonb,
  p_raw_payload jsonb,
  p_actual_tokens integer,
  p_actual_cost_micros bigint,
  p_cursor_after jsonb,
  p_resume_cursor jsonb,
  p_candidate jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, aep, public
AS $function$
DECLARE
  v_pass aep.discovery_passes%ROWTYPE;
  v_observation aep.discovery_observations%ROWTYPE;
  v_resource aep.resources%ROWTYPE;
  v_project_resource aep.project_resources%ROWTYPE;
  v_result jsonb;
  v_result_sha256 text;
  v_decision text;
  v_reason text;
  v_action text;
  v_candidate_key text;
  v_candidate_fingerprint text;
  v_candidate_title text;
  v_candidate_work_type text;
  v_acceptance jsonb;
  v_parent_observation_id uuid;
  v_parent_observation aep.discovery_observations%ROWTYPE;
  v_parent_work_id uuid;
  v_depth integer := 0;
  v_children integer := 0;
  v_required_child boolean := true;
  v_possible_duplicate_work_id uuid;
  v_work_id uuid;
  v_register_outcome text;
  v_evidence_id uuid;
  v_tokens_reserved bigint;
  v_cost_reserved bigint;
  v_tokens_used bigint;
  v_cost_used bigint;
  v_no_progress integer;
  v_stop_reason text;
  v_resume_cursor jsonb;
  v_source_allowed boolean;
  v_observed_at timestamptz;
BEGIN
  IF p_project_id IS NULL OR p_resource_id IS NULL OR p_pass_id IS NULL OR p_session_id IS NULL
     OR p_call_key IS NULL OR length(btrim(p_call_key)) NOT BETWEEN 1 AND 160
     OR p_content_sha256 IS NULL OR p_content_sha256 !~ '^[0-9a-f]{64}$'
     OR p_provenance IS NULL OR jsonb_typeof(p_provenance) IS DISTINCT FROM 'object'
     OR octet_length(p_provenance::text)>8192
     OR p_raw_payload IS NULL OR jsonb_typeof(p_raw_payload) IS DISTINCT FROM 'object'
     OR octet_length(p_raw_payload::text)>262144
     OR p_actual_tokens IS NULL OR p_actual_tokens NOT BETWEEN 0 AND 1000000
     OR p_actual_cost_micros IS NULL OR p_actual_cost_micros NOT BETWEEN 0 AND 1000000000
     OR p_cursor_after IS NULL OR jsonb_typeof(p_cursor_after) IS DISTINCT FROM 'object'
     OR p_resume_cursor IS NULL OR jsonb_typeof(p_resume_cursor) IS DISTINCT FROM 'object'
     OR (p_candidate IS NOT NULL AND jsonb_typeof(p_candidate) IS DISTINCT FROM 'object') THEN
    RAISE EXCEPTION 'Discovery result fields are invalid or exceed bounded payload sizes'
      USING ERRCODE = '22023';
  END IF;

  -- Exclusive Project lock is acquired before any pass/Evidence/Work reads.
  -- It serializes evidence insertion, Work registration, and grant revocation.
  IF NOT aep.context_project_resource_allowed(p_project_id,p_resource_id,true) THEN
    RETURN jsonb_build_object('status','denied','reason','project_scope_unavailable');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM aep.projects WHERE project_id=p_project_id AND status='active') THEN
    RETURN jsonb_build_object('status','denied','reason','project_inactive');
  END IF;

  SELECT * INTO v_pass FROM aep.discovery_passes
  WHERE pass_id=p_pass_id AND project_id=p_project_id AND resource_id=p_resource_id
  FOR UPDATE;
  IF NOT FOUND OR v_pass.session_id<>p_session_id THEN
    RETURN jsonb_build_object('status','stopped','reason','pass_unavailable');
  END IF;
  SELECT * INTO v_observation FROM aep.discovery_observations
  WHERE pass_id=p_pass_id AND call_key=p_call_key
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No reserved discovery call exists for this key' USING ERRCODE = '22023';
  END IF;

  v_result := jsonb_build_object(
    'source_revision',p_source_revision,'content_sha256',p_content_sha256,
    'provenance',p_provenance,'raw_payload',p_raw_payload,
    'actual_tokens',p_actual_tokens,'actual_cost_micros',p_actual_cost_micros,
    'cursor_after',p_cursor_after,'resume_cursor',p_resume_cursor,'candidate',p_candidate
  );
  v_result_sha256 := encode(public.digest(convert_to(v_result::text,'UTF8'),'sha256'),'hex');
  IF v_observation.status='completed' THEN
    IF v_observation.result_sha256<>v_result_sha256 THEN
      RAISE EXCEPTION 'Completed discovery call key was replayed with different evidence'
        USING ERRCODE = '22000';
    END IF;
    RETURN v_observation.result_payload || jsonb_build_object('idempotent_replay',true);
  END IF;
  IF v_pass.status<>'running' THEN
    RETURN jsonb_build_object('status','stopped','reason','pass_unavailable');
  END IF;
  IF p_source_revision IS NOT NULL AND length(p_source_revision)>1000 THEN
    RAISE EXCEPTION 'Source revision exceeds 1000 characters' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_resource FROM aep.resources
  WHERE resource_id=p_resource_id AND provider='github'
    AND resource_type='repository' AND status='active';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Discovery repository Resource is not active' USING ERRCODE = '42501';
  END IF;
  SELECT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_pass.source_list) AS source(value)
    WHERE source.value->>'source_kind'=v_observation.source_kind
      AND left(v_observation.source_ref,length(source.value->>'source_prefix'))=source.value->>'source_prefix'
      AND (
        right(source.value->>'source_prefix',1)='/'
        OR length(v_observation.source_ref)=length(source.value->>'source_prefix')
        OR substring(v_observation.source_ref,length(source.value->>'source_prefix')+1,1) IN ('/','?','#')
      )
  ) INTO v_source_allowed;
  IF NOT v_source_allowed THEN
    RAISE EXCEPTION 'Reserved source no longer matches the authorized source list'
      USING ERRCODE = '42501';
  END IF;

  v_action := COALESCE(p_candidate->>'action','skip');
  v_decision := 'skipped';
  v_reason := COALESCE(NULLIF(p_candidate->>'reason',''),'no_candidate');
  IF EXISTS (SELECT 1 FROM aep.works WHERE project_id=p_project_id AND status='ready') THEN
    v_action := 'skip';
    v_reason := 'queue_ready';
  END IF;
  v_acceptance := COALESCE(p_candidate->'acceptance','{}'::jsonb);
  IF jsonb_typeof(v_acceptance) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'Candidate acceptance must be a JSON object' USING ERRCODE = '22023';
  END IF;

  IF v_action NOT IN ('accept','skip','approval_required') THEN
    RAISE EXCEPTION 'Candidate action must be accept, skip, or approval_required'
      USING ERRCODE = '22023';
  END IF;

  IF v_action IN ('accept','approval_required') THEN
    v_candidate_key := NULLIF(btrim(p_candidate->>'candidate_key'),'');
    IF v_candidate_key IS NULL OR length(v_candidate_key)>500 THEN
      RAISE EXCEPTION 'Accepted/approval-required candidate requires a stable candidate_key'
        USING ERRCODE = '22023';
    END IF;
    v_candidate_fingerprint := encode(public.digest(convert_to(
      p_project_id::text || '|discovery_candidate_v1|' || v_candidate_key,
      'UTF8'),'sha256'),'hex');
  END IF;

  IF v_action='approval_required' THEN
    v_decision := 'approval_required';
    v_reason := COALESCE(NULLIF(p_candidate->>'reason',''),'owner_decision_required');
  ELSIF v_action='accept' THEN
    v_candidate_title := NULLIF(btrim(p_candidate->>'title'),'');
    v_candidate_work_type := p_candidate->>'work_type';
    IF v_candidate_title IS NULL OR length(v_candidate_title)>500
       OR v_candidate_work_type IS NULL OR v_candidate_work_type NOT IN ('initiative','discovery','implementation','review','fix') THEN
      RAISE EXCEPTION 'Accepted candidate requires title and valid work_type'
        USING ERRCODE = '22023';
    END IF;

    SELECT * INTO v_project_resource FROM aep.project_resources
    WHERE project_id=p_project_id AND resource_id=p_resource_id AND status='active';
    IF NOT FOUND OR v_project_resource.access_mode='read' THEN
      v_decision := 'approval_required';
      v_reason := 'write_scope_required';
    ELSE
      v_parent_observation_id := NULLIF(p_candidate->>'parent_observation_id','')::uuid;
      v_possible_duplicate_work_id := NULLIF(p_candidate->>'possible_duplicate_work_id','')::uuid;
      v_required_child := COALESCE((p_candidate->>'required_child')::boolean,true);
      IF v_parent_observation_id IS NOT NULL THEN
        SELECT * INTO v_parent_observation
        FROM aep.discovery_observations
        WHERE observation_id=v_parent_observation_id
          AND project_id=p_project_id AND resource_id=p_resource_id
          AND status='completed' AND decision IN ('accepted','linked')
          AND work_id IS NOT NULL
        FOR KEY SHARE;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'Parent observation must be an accepted/linked observation in this project scope'
            USING ERRCODE = '22023';
        END IF;
        v_parent_work_id := v_parent_observation.work_id;
        v_depth := v_parent_observation.depth+1;
        SELECT count(*) INTO v_children FROM aep.work_relations
        WHERE source_work_id=v_parent_work_id AND relation_type='parent_child' AND status='active';
        IF v_depth>v_pass.max_depth THEN
          v_decision := 'pending';
          v_reason := 'max_depth';
        ELSIF v_children>=v_pass.max_fanout THEN
          v_decision := 'pending';
          v_reason := 'max_fanout';
        END IF;
      END IF;

      IF v_decision<>'pending' THEN
        SELECT registered.work_id,registered.outcome
        INTO v_work_id,v_register_outcome
        FROM aep.register_work(
          p_project_id,
          'discovery:' || encode(public.digest(convert_to(p_pass_id::text || '|' || p_call_key,'UTF8'),'sha256'),'hex'),
          p_session_id,
          'discovery_candidate_v1',
          v_candidate_fingerprint,
          1,
          v_candidate_work_type,
          v_candidate_title,
          v_acceptance || jsonb_build_object('discovery_fingerprint',v_candidate_fingerprint),
          NULL
        ) AS registered;

        v_decision := CASE WHEN v_register_outcome='created' THEN 'accepted' ELSE 'linked' END;
        v_reason := CASE WHEN v_decision='accepted' THEN 'canonical_work_created' ELSE 'canonical_work_linked' END;

        IF v_parent_work_id IS NOT NULL AND v_parent_work_id<>v_work_id THEN
          INSERT INTO aep.work_relations(
            source_work_id,target_work_id,relation_type,required,status
          ) VALUES(v_parent_work_id,v_work_id,'parent_child',v_required_child,'active')
          ON CONFLICT DO NOTHING;
        END IF;

        IF v_possible_duplicate_work_id IS NOT NULL THEN
          IF v_possible_duplicate_work_id=v_work_id THEN
            RAISE EXCEPTION 'A possible-duplicate relation cannot target the canonical Work itself'
              USING ERRCODE = '22023';
          END IF;
          IF NOT EXISTS (
            SELECT 1 FROM aep.works
            WHERE project_id=p_project_id AND work_id=v_possible_duplicate_work_id
          ) THEN
            RAISE EXCEPTION 'Possible duplicate target must be a Work in the same project'
              USING ERRCODE = '42501';
          END IF;
          INSERT INTO aep.work_relations(source_work_id,target_work_id,relation_type,required,status)
          VALUES(LEAST(v_work_id,v_possible_duplicate_work_id),
                 GREATEST(v_work_id,v_possible_duplicate_work_id),
                 'possible_duplicate',NULL,'active')
          ON CONFLICT DO NOTHING;
        END IF;
      END IF;
    END IF;
  END IF;

  v_observed_at := clock_timestamp();
  INSERT INTO aep.evidence(
    project_id,work_id,evidence_type,source_ref,source_revision,
    content_sha256,provenance,payload,observed_at
  ) VALUES (
    p_project_id,v_work_id,'discovery_observation',v_observation.source_ref,
    p_source_revision,p_content_sha256,
    p_provenance || jsonb_build_object(
      'discovery_pass_id',p_pass_id,'observation_id',v_observation.observation_id,
      'resource_id',p_resource_id,'source_kind',v_observation.source_kind,
      'session_id',p_session_id,'candidate_fingerprint',v_candidate_fingerprint
    ),
    p_raw_payload,v_observed_at
  ) RETURNING evidence_id INTO v_evidence_id;

  v_tokens_reserved := v_pass.tokens_reserved-v_observation.estimated_tokens;
  v_cost_reserved := v_pass.cost_reserved_micros-v_observation.estimated_cost_micros;
  v_tokens_used := v_pass.tokens_used+p_actual_tokens;
  v_cost_used := v_pass.cost_used_micros+p_actual_cost_micros;
  v_no_progress := CASE WHEN v_decision='accepted' THEN 0 ELSE v_pass.no_progress_count+1 END;
  v_resume_cursor := CASE WHEN v_decision='pending'
    THEN v_observation.cursor_before ELSE p_resume_cursor END;

  IF v_reason='queue_ready' THEN
    v_stop_reason := 'queue_ready';
  ELSIF v_decision='pending' THEN
    v_stop_reason := CASE WHEN v_reason='max_depth' THEN 'depth_budget' ELSE 'fanout_budget' END;
  ELSIF v_tokens_used+v_tokens_reserved>v_pass.max_tokens THEN
    v_stop_reason := 'token_budget';
  ELSIF v_cost_used+v_cost_reserved>v_pass.max_cost_micros THEN
    v_stop_reason := 'cost_budget';
  ELSIF v_pass.tool_calls_used>=v_pass.max_tool_calls THEN
    v_stop_reason := 'tool_call_budget';
  ELSIF v_no_progress>=v_pass.max_no_progress THEN
    v_stop_reason := 'no_progress';
  ELSIF floor(extract(epoch FROM (clock_timestamp()-v_pass.started_at))*1000)>=v_pass.max_elapsed_ms THEN
    v_stop_reason := 'elapsed_budget';
  END IF;

  v_result := jsonb_build_object(
    'status',CASE WHEN v_stop_reason IS NULL THEN 'recorded' ELSE 'stopped' END,
    'decision',v_decision,'reason',v_reason,'work_id',v_work_id,
    'evidence_id',v_evidence_id,'observed_at',v_observed_at,
    'candidate_fingerprint',v_candidate_fingerprint,
    'resume_cursor',v_resume_cursor,'stop_reason',v_stop_reason,
    'tokens_used',v_tokens_used,'cost_used_micros',v_cost_used,
    'no_progress_count',v_no_progress
  );

  UPDATE aep.discovery_observations SET
    cursor_after=p_cursor_after,resume_cursor=v_resume_cursor,
    source_revision=p_source_revision,content_sha256=p_content_sha256,
    provenance=p_provenance,raw_payload=p_raw_payload,evidence_id=v_evidence_id,
    result_sha256=v_result_sha256,result_payload=v_result,
    actual_tokens=p_actual_tokens,actual_cost_micros=p_actual_cost_micros,
    status='completed',decision=v_decision,decision_reason=v_reason,
    candidate_payload=p_candidate,candidate_fingerprint=v_candidate_fingerprint,
    work_id=v_work_id,parent_work_id=v_parent_work_id,
    parent_observation_id=v_parent_observation_id,depth=v_depth,
    required_child=CASE WHEN v_parent_work_id IS NULL THEN NULL ELSE v_required_child END,
    completed_at=v_observed_at,observed_at=v_observed_at
  WHERE observation_id=v_observation.observation_id;

  UPDATE aep.discovery_passes SET
    current_cursor=p_cursor_after,resume_cursor=v_resume_cursor,
    tokens_reserved=v_tokens_reserved,tokens_used=v_tokens_used,
    cost_reserved_micros=v_cost_reserved,cost_used_micros=v_cost_used,
    no_progress_count=v_no_progress,
    status=CASE WHEN v_stop_reason IS NULL THEN 'running' ELSE 'stopped' END,
    stop_reason=v_stop_reason,
    stopped_at=CASE WHEN v_stop_reason IS NULL THEN NULL ELSE clock_timestamp() END,
    updated_at=clock_timestamp()
  WHERE pass_id=p_pass_id;

  INSERT INTO aep.discovery_pass_events(pass_id,project_id,resource_id,session_id,event_type,event_payload)
  VALUES(p_pass_id,p_project_id,p_resource_id,p_session_id,
    CASE
      WHEN v_stop_reason='no_progress' THEN 'no_progress_stopped'
      WHEN v_stop_reason IN ('token_budget','cost_budget','tool_call_budget','elapsed_budget','depth_budget','fanout_budget')
        THEN 'budget_stopped'
      WHEN v_decision='accepted' THEN 'candidate_created'
      WHEN v_decision='linked' THEN 'candidate_linked'
      WHEN v_decision='skipped' THEN 'candidate_skipped'
      WHEN v_decision='approval_required' THEN 'approval_required'
      WHEN v_decision='pending' THEN 'candidate_pending'
      ELSE 'observation_recorded'
    END,
    v_result
  );

  RETURN v_result;
END
$function$;

-- Fresh sessions can recover recent pass IDs, budgets, cursors and candidate
-- dispositions without direct table reads. Content stays in Evidence and is
-- never included in this state summary.
CREATE FUNCTION aep.get_discovery_state(
  p_project_id uuid,
  p_resource_id uuid,
  p_limit integer DEFAULT 10
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, aep
AS $function$
DECLARE
  v_passes jsonb;
  v_observations jsonb;
  v_ready_count bigint;
BEGIN
  IF NOT aep.context_project_resource_allowed(p_project_id,p_resource_id,false) THEN
    RETURN jsonb_build_object('status','denied','reason','project_scope_unavailable');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM aep.projects WHERE project_id=p_project_id AND status='active') THEN
    RETURN jsonb_build_object('status','denied','reason','project_inactive');
  END IF;
  IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 20 THEN
    RAISE EXCEPTION 'Discovery state limit must be between 1 and 20' USING ERRCODE = '22023';
  END IF;

  SELECT count(*) INTO v_ready_count FROM aep.works
  WHERE project_id=p_project_id AND status='ready';

  SELECT COALESCE(jsonb_agg(item.value ORDER BY item.started_at DESC),'[]'::jsonb)
  INTO v_passes
  FROM (
    SELECT jsonb_build_object(
      'pass_id',pass_id,'request_key',request_key,'status',status,
      'stop_reason',stop_reason,'resume_from_pass_id',resume_from_pass_id,
      'source_list',source_list,'current_cursor',current_cursor,
      'watermark',watermark,'resume_cursor',resume_cursor,
      'limits',jsonb_build_object(
        'max_depth',max_depth,'max_fanout',max_fanout,
        'max_tool_calls',max_tool_calls,'max_elapsed_ms',max_elapsed_ms,
        'max_tokens',max_tokens,'max_cost_micros',max_cost_micros,
        'max_no_progress',max_no_progress
      ),
      'usage',jsonb_build_object(
        'tool_calls_used',tool_calls_used,'tokens_used',tokens_used,
        'tokens_reserved',tokens_reserved,'cost_used_micros',cost_used_micros,
        'cost_reserved_micros',cost_reserved_micros,'no_progress_count',no_progress_count
      ),
      'started_at',started_at,'stopped_at',stopped_at,'completed_at',completed_at
    ) AS value,started_at
    FROM aep.discovery_passes
    WHERE project_id=p_project_id AND resource_id=p_resource_id
    ORDER BY started_at DESC LIMIT p_limit
  ) AS item;

  SELECT COALESCE(jsonb_agg(item.value ORDER BY item.reserved_at DESC),'[]'::jsonb)
  INTO v_observations
  FROM (
    SELECT jsonb_build_object(
      'observation_id',observation_id,'pass_id',pass_id,'call_key',call_key,
      'tool_name',tool_name,'source_kind',source_kind,'source_ref',source_ref,
      'source_revision',source_revision,'content_sha256',content_sha256,
      'evidence_id',evidence_id,'status',status,'decision',decision,
      'decision_reason',decision_reason,'candidate_fingerprint',candidate_fingerprint,
      'work_id',work_id,'parent_work_id',parent_work_id,'depth',depth,
      'cursor_before',cursor_before,'cursor_after',cursor_after,
      'resume_cursor',resume_cursor,'actual_tokens',actual_tokens,
      'actual_cost_micros',actual_cost_micros,'reserved_at',reserved_at,
      'completed_at',completed_at,'observed_at',observed_at
    ) AS value,reserved_at
    FROM aep.discovery_observations
    WHERE project_id=p_project_id AND resource_id=p_resource_id
      AND pass_id IN (
        SELECT pass_id FROM aep.discovery_passes
        WHERE project_id=p_project_id AND resource_id=p_resource_id
        ORDER BY started_at DESC LIMIT p_limit
      )
    ORDER BY reserved_at DESC LIMIT 100
  ) AS item;

  RETURN jsonb_build_object(
    'status','ready','ready_work_count',v_ready_count,
    'passes',v_passes,'observations',v_observations
  );
END
$function$;

CREATE FUNCTION aep.finish_discovery_pass(
  p_project_id uuid,p_resource_id uuid,p_pass_id uuid,p_session_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, aep
AS $function$
DECLARE
  v_pass aep.discovery_passes%ROWTYPE;
BEGIN
  IF NOT aep.context_project_resource_allowed(p_project_id,p_resource_id,true) THEN
    RETURN jsonb_build_object('status','denied','reason','project_scope_unavailable');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM aep.projects WHERE project_id=p_project_id AND status='active') THEN
    RETURN jsonb_build_object('status','denied','reason','project_inactive');
  END IF;
  SELECT * INTO v_pass FROM aep.discovery_passes
  WHERE pass_id=p_pass_id AND project_id=p_project_id AND resource_id=p_resource_id
  FOR UPDATE;
  IF NOT FOUND OR v_pass.session_id<>p_session_id OR v_pass.status<>'running' THEN
    RETURN jsonb_build_object('status','stopped','reason','pass_unavailable');
  END IF;
  IF EXISTS (SELECT 1 FROM aep.discovery_observations WHERE pass_id=p_pass_id AND status='reserved') THEN
    RAISE EXCEPTION 'Cannot complete a pass with an in-flight reserved tool call'
      USING ERRCODE = '55000';
  END IF;
  UPDATE aep.discovery_passes SET status='completed',completed_at=clock_timestamp(),
    resume_cursor=current_cursor,updated_at=clock_timestamp()
  WHERE pass_id=p_pass_id;
  INSERT INTO aep.discovery_pass_events(pass_id,project_id,resource_id,session_id,event_type,event_payload)
  VALUES(p_pass_id,p_project_id,p_resource_id,p_session_id,'pass_completed',
    jsonb_build_object('cursor',v_pass.current_cursor,'tool_calls_used',v_pass.tool_calls_used,
      'tokens_used',v_pass.tokens_used,'cost_used_micros',v_pass.cost_used_micros));
  RETURN jsonb_build_object('status','completed','pass_id',p_pass_id,'cursor',v_pass.current_cursor);
END
$function$;

CREATE FUNCTION aep.yield_discovery_pass(
  p_project_id uuid,p_resource_id uuid,p_pass_id uuid,p_session_id uuid,p_resume_cursor jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, aep
AS $function$
DECLARE
  v_pass aep.discovery_passes%ROWTYPE;
BEGIN
  IF p_resume_cursor IS NULL OR jsonb_typeof(p_resume_cursor) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'Resume cursor must be a JSON object' USING ERRCODE = '22023';
  END IF;
  IF NOT aep.context_project_resource_allowed(p_project_id,p_resource_id,true) THEN
    RETURN jsonb_build_object('status','denied','reason','project_scope_unavailable');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM aep.projects WHERE project_id=p_project_id AND status='active') THEN
    RETURN jsonb_build_object('status','denied','reason','project_inactive');
  END IF;
  SELECT * INTO v_pass FROM aep.discovery_passes
  WHERE pass_id=p_pass_id AND project_id=p_project_id AND resource_id=p_resource_id
  FOR UPDATE;
  IF NOT FOUND OR v_pass.session_id<>p_session_id OR v_pass.status<>'running' THEN
    RETURN jsonb_build_object('status','stopped','reason','pass_unavailable');
  END IF;
  IF EXISTS (SELECT 1 FROM aep.discovery_observations WHERE pass_id=p_pass_id AND status='reserved') THEN
    RAISE EXCEPTION 'Cannot yield while a discovery tool call is reserved; complete or explicitly wait for the read result'
      USING ERRCODE = '55000';
  END IF;
  UPDATE aep.discovery_passes SET status='stopped',stop_reason='session_yield',
    stopped_at=clock_timestamp(),resume_cursor=p_resume_cursor,updated_at=clock_timestamp()
  WHERE pass_id=p_pass_id;
  INSERT INTO aep.discovery_pass_events(pass_id,project_id,resource_id,session_id,event_type,event_payload)
  VALUES(p_pass_id,p_project_id,p_resource_id,p_session_id,'pass_yielded',
    jsonb_build_object('resume_cursor',p_resume_cursor));
  RETURN jsonb_build_object('status','stopped','reason','session_yield','resume_cursor',p_resume_cursor);
END
$function$;

-- The runtime can only enter through the authorization-checked RPCs. All direct
-- table access and helper/trigger execution remains unavailable.
ALTER TABLE aep.discovery_passes OWNER TO aep_owner;
ALTER TABLE aep.discovery_observations OWNER TO aep_owner;
ALTER TABLE aep.discovery_pass_events OWNER TO aep_owner;

DO $rls$
DECLARE table_name text;
BEGIN
  FOREACH table_name IN ARRAY ARRAY[
    'discovery_passes','discovery_observations','discovery_pass_events'
  ] LOOP
    EXECUTE format('ALTER TABLE aep.%I ENABLE ROW LEVEL SECURITY',table_name);
    EXECUTE format('ALTER TABLE aep.%I FORCE ROW LEVEL SECURITY',table_name);
    EXECUTE format(
      'CREATE POLICY owner_full_access ON aep.%I FOR ALL TO aep_owner USING (true) WITH CHECK (true)',
      table_name
    );
  END LOOP;
END
$rls$;

REVOKE ALL ON TABLE aep.discovery_passes,aep.discovery_observations,aep.discovery_pass_events
  FROM PUBLIC,aep_runtime;
ALTER FUNCTION aep.reject_discovery_event_mutation() OWNER TO aep_owner;
ALTER FUNCTION aep.guard_discovery_observation_mutation() OWNER TO aep_owner;
ALTER FUNCTION aep.start_discovery_pass(uuid,uuid,uuid,text,jsonb,jsonb,jsonb,jsonb,uuid)
  OWNER TO aep_owner;
ALTER FUNCTION aep.reserve_discovery_call(uuid,uuid,uuid,uuid,text,text,text,text,jsonb,integer,bigint)
  OWNER TO aep_owner;
ALTER FUNCTION aep.complete_discovery_call(uuid,uuid,uuid,uuid,text,text,text,jsonb,jsonb,integer,bigint,jsonb,jsonb,jsonb)
  OWNER TO aep_owner;
ALTER FUNCTION aep.get_discovery_state(uuid,uuid,integer) OWNER TO aep_owner;
ALTER FUNCTION aep.finish_discovery_pass(uuid,uuid,uuid,uuid) OWNER TO aep_owner;
ALTER FUNCTION aep.yield_discovery_pass(uuid,uuid,uuid,uuid,jsonb) OWNER TO aep_owner;

REVOKE ALL ON FUNCTION aep.reject_discovery_event_mutation() FROM PUBLIC,aep_runtime;
REVOKE ALL ON FUNCTION aep.guard_discovery_observation_mutation() FROM PUBLIC,aep_runtime;
REVOKE ALL ON FUNCTION aep.start_discovery_pass(uuid,uuid,uuid,text,jsonb,jsonb,jsonb,jsonb,uuid)
  FROM PUBLIC;
REVOKE ALL ON FUNCTION aep.reserve_discovery_call(uuid,uuid,uuid,uuid,text,text,text,text,jsonb,integer,bigint)
  FROM PUBLIC;
REVOKE ALL ON FUNCTION aep.complete_discovery_call(uuid,uuid,uuid,uuid,text,text,text,jsonb,jsonb,integer,bigint,jsonb,jsonb,jsonb)
  FROM PUBLIC;
REVOKE ALL ON FUNCTION aep.get_discovery_state(uuid,uuid,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION aep.finish_discovery_pass(uuid,uuid,uuid,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION aep.yield_discovery_pass(uuid,uuid,uuid,uuid,jsonb) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION aep.start_discovery_pass(uuid,uuid,uuid,text,jsonb,jsonb,jsonb,jsonb,uuid)
  TO aep_runtime;
GRANT EXECUTE ON FUNCTION aep.reserve_discovery_call(uuid,uuid,uuid,uuid,text,text,text,text,jsonb,integer,bigint)
  TO aep_runtime;
GRANT EXECUTE ON FUNCTION aep.complete_discovery_call(uuid,uuid,uuid,uuid,text,text,text,jsonb,jsonb,integer,bigint,jsonb,jsonb,jsonb)
  TO aep_runtime;
GRANT EXECUTE ON FUNCTION aep.get_discovery_state(uuid,uuid,integer) TO aep_runtime;
GRANT EXECUTE ON FUNCTION aep.finish_discovery_pass(uuid,uuid,uuid,uuid) TO aep_runtime;
GRANT EXECUTE ON FUNCTION aep.yield_discovery_pass(uuid,uuid,uuid,uuid,jsonb) TO aep_runtime;

COMMIT;
