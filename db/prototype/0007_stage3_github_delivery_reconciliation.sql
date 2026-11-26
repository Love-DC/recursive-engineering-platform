-- Stage 3: GitHub delivery identity, capability manifests, external-operation
-- reconciliation, and exact-SHA evidence lifecycle.
-- Additive prototype migration. Never apply to production Supabase or legacy RAE.

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE aep.delivery_adapter_manifests (
  resource_id uuid PRIMARY KEY REFERENCES aep.resources(resource_id),
  adapter_key text NOT NULL CHECK (adapter_key = 'github-session-tools'),
  schema_version integer NOT NULL CHECK (schema_version = 1),
  manifest jsonb NOT NULL CHECK (jsonb_typeof(manifest) = 'object'),
  declared_by_session_id uuid,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE aep.execution_deliveries (
  delivery_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  work_id uuid NOT NULL,
  execution_id uuid NOT NULL UNIQUE,
  fence bigint NOT NULL CHECK (fence > 0),
  resource_id uuid NOT NULL REFERENCES aep.resources(resource_id),
  provider text NOT NULL CHECK (provider = 'github'),
  host text NOT NULL CHECK (host = lower(host) AND length(btrim(host)) BETWEEN 1 AND 255),
  repository_id text NOT NULL CHECK (length(btrim(repository_id)) BETWEEN 1 AND 80),
  repository_full_name text NOT NULL CHECK (length(btrim(repository_full_name)) BETWEEN 3 AND 255),
  base_ref text NOT NULL CHECK (base_ref ~ '^refs/heads/[A-Za-z0-9._/-]+$'),
  base_sha text NOT NULL CHECK (base_sha ~ '^[0-9a-f]{40}$'),
  delivery_branch text NOT NULL,
  pull_request_number bigint CHECK (pull_request_number IS NULL OR pull_request_number > 0),
  pull_request_url text,
  pr_head_sha text CHECK (pr_head_sha IS NULL OR pr_head_sha ~ '^[0-9a-f]{40}$'),
  merge_sha text CHECK (merge_sha IS NULL OR merge_sha ~ '^[0-9a-f]{40}$'),
  stale_external_side_effect boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  FOREIGN KEY (work_id, execution_id) REFERENCES aep.executions(work_id, execution_id),
  CHECK (delivery_branch = 'work/' || work_id::text || '/execution/' || execution_id::text),
  CHECK (pull_request_number IS NULL OR pull_request_url IS NOT NULL)
);

CREATE UNIQUE INDEX execution_deliveries_repo_branch_uq
  ON aep.execution_deliveries(provider, host, repository_id, delivery_branch);
CREATE UNIQUE INDEX execution_deliveries_repo_pr_uq
  ON aep.execution_deliveries(provider, host, repository_id, pull_request_number)
  WHERE pull_request_number IS NOT NULL;
CREATE INDEX execution_deliveries_work_idx
  ON aep.execution_deliveries(work_id, created_at DESC);

ALTER TABLE aep.operation_receipts
  ADD COLUMN execution_fence bigint,
  ADD COLUMN target_host text,
  ADD COLUMN target_repository_id text,
  ADD COLUMN attempt_count integer NOT NULL DEFAULT 1 CHECK (attempt_count > 0),
  ADD COLUMN stale_execution_detected boolean NOT NULL DEFAULT false,
  ADD CONSTRAINT operation_receipts_execution_fence_ck
    CHECK (
      (execution_fence IS NULL AND target_host IS NULL AND target_repository_id IS NULL)
      OR (
        execution_fence > 0
        AND target_resource_id IS NOT NULL
        AND target_host IS NOT NULL
        AND target_repository_id IS NOT NULL
      )
    );

CREATE TABLE aep.execution_delivery_evidence (
  evidence_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  work_id uuid NOT NULL,
  execution_id uuid NOT NULL,
  fence bigint NOT NULL CHECK (fence > 0),
  evidence_kind text NOT NULL CHECK (evidence_kind IN (
    'pr_head','ci','process_review','native_approval','merge',
    'post_merge_ci','deployment','owner_acceptance'
  )),
  subject_sha text NOT NULL CHECK (subject_sha ~ '^[0-9a-f]{40}$'),
  source_ref text NOT NULL CHECK (length(btrim(source_ref)) BETWEEN 1 AND 2000),
  actor_principal text,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(payload) = 'object'),
  observed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  FOREIGN KEY (work_id, execution_id) REFERENCES aep.executions(work_id, execution_id),
  CHECK (
    evidence_kind NOT IN ('process_review','native_approval','owner_acceptance')
    OR (actor_principal IS NOT NULL AND length(btrim(actor_principal)) > 0)
  )
);

CREATE INDEX execution_delivery_evidence_execution_idx
  ON aep.execution_delivery_evidence(execution_id, evidence_kind, observed_at DESC);
CREATE INDEX execution_delivery_evidence_sha_idx
  ON aep.execution_delivery_evidence(execution_id, evidence_kind, subject_sha);

CREATE TABLE aep.delivery_evidence_invalidations (
  invalidation_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  evidence_id uuid NOT NULL UNIQUE REFERENCES aep.execution_delivery_evidence(evidence_id),
  reason text NOT NULL CHECK (length(btrim(reason)) BETWEEN 1 AND 160),
  invalidated_by_ref text NOT NULL CHECK (length(btrim(invalidated_by_ref)) BETWEEN 1 AND 2000),
  invalidated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE VIEW aep.execution_delivery_evidence_current AS
SELECT evidence_row.*,
       NOT EXISTS (
         SELECT 1 FROM aep.delivery_evidence_invalidations AS invalidation
         WHERE invalidation.evidence_id = evidence_row.evidence_id
       ) AS is_valid
FROM aep.execution_delivery_evidence AS evidence_row;

ALTER VIEW aep.execution_delivery_evidence_current OWNER TO aep_owner;

CREATE FUNCTION aep.register_delivery_adapter_manifest(
  p_resource_id uuid,
  p_manifest jsonb,
  p_session_id uuid DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, aep, public
AS $function$
DECLARE
  v_required text[] := ARRAY[
    'branch_ref','pull_request','process_review','native_approval',
    'merge','ci_lookup','post_merge_verification','deployment'
  ];
  v_key text;
  v_value jsonb;
BEGIN
  IF p_manifest IS NULL OR jsonb_typeof(p_manifest) IS DISTINCT FROM 'object'
     OR jsonb_typeof(p_manifest->'operations') IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'Adapter manifest must contain an operations object'
      USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(p_manifest->'schema_version') IS DISTINCT FROM 'number'
     OR p_manifest->'schema_version' IS DISTINCT FROM '1'::jsonb THEN
    RAISE EXCEPTION 'Adapter manifest schema_version must be numeric 1'
      USING ERRCODE = '22023';
  END IF;
  IF NOT ((p_manifest->'operations') ?& v_required)
     OR (SELECT count(*) FROM jsonb_object_keys(p_manifest->'operations')) <> cardinality(v_required) THEN
    RAISE EXCEPTION 'Adapter manifest must declare exactly the required delivery operations'
      USING ERRCODE = '22023';
  END IF;
  FOR v_key, v_value IN
    SELECT key, value FROM jsonb_each(p_manifest->'operations')
  LOOP
    IF jsonb_typeof(v_value) IS DISTINCT FROM 'object' THEN
      RAISE EXCEPTION 'Capability % must be an object', v_key USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(v_value->'status') IS DISTINCT FROM 'string'
       OR v_value->>'status' NOT IN ('supported','unsupported','unavailable') THEN
      RAISE EXCEPTION 'Invalid capability status for %', v_key USING ERRCODE = '22023';
    END IF;
  END LOOP;
  IF jsonb_typeof(p_manifest#>'{operations,native_approval,independent_principal}') IS DISTINCT FROM 'string'
     OR p_manifest#>>'{operations,native_approval,independent_principal}' IS DISTINCT FROM 'unavailable' THEN
    RAISE EXCEPTION 'This adapter cannot claim an independently authenticated approval principal'
      USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(p_manifest#>'{operations,process_review,identity}') IS DISTINCT FROM 'string'
     OR p_manifest#>>'{operations,process_review,identity}' IS DISTINCT FROM 'same_authenticated_principal' THEN
    RAISE EXCEPTION 'Process review must disclose the authenticated principal model'
      USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM aep.resources
    WHERE resource_id = p_resource_id
      AND provider = 'github'
      AND resource_type = 'repository'
      AND status = 'active'
  ) THEN
    RAISE EXCEPTION 'Adapter manifest target must be an active GitHub repository resource'
      USING ERRCODE = '23503';
  END IF;
  INSERT INTO aep.delivery_adapter_manifests(
    resource_id, adapter_key, schema_version, manifest, declared_by_session_id
  ) VALUES (p_resource_id, 'github-session-tools', 1, p_manifest, p_session_id)
  ON CONFLICT (resource_id) DO UPDATE
    SET manifest = EXCLUDED.manifest,
        declared_by_session_id = EXCLUDED.declared_by_session_id,
        updated_at = clock_timestamp();
END
$function$;

CREATE FUNCTION aep.allocate_execution_delivery(
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
  v_branch text;
  v_existing aep.execution_deliveries%ROWTYPE;
BEGIN
  IF p_work_id IS NULL OR p_execution_id IS NULL OR p_fence IS NULL
     OR p_resource_id IS NULL OR p_host IS NULL OR p_repository_id IS NULL
     OR p_repository_full_name IS NULL OR p_base_ref IS NULL OR p_base_sha IS NULL THEN
    RAISE EXCEPTION 'Execution delivery identity fields are required' USING ERRCODE = '22004';
  END IF;
  IF p_host <> lower(p_host) OR p_base_sha !~ '^[0-9a-f]{40}$'
     OR p_base_ref !~ '^refs/heads/[A-Za-z0-9._/-]+$' THEN
    RAISE EXCEPTION 'Repository host, base ref, or exact base SHA is not canonical'
      USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM aep.works AS work_row
    JOIN aep.executions AS execution_row
      ON execution_row.work_id = work_row.work_id
     AND execution_row.execution_id = p_execution_id
    WHERE work_row.work_id = p_work_id
      AND work_row.status = 'running'
      AND work_row.current_execution_id = p_execution_id
      AND work_row.fence_generation = p_fence
      AND execution_row.fence = p_fence
      AND execution_row.status = 'running'
  ) THEN
    RAISE EXCEPTION 'Execution delivery requires the current running execution and fence'
      USING ERRCODE = '55000';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM aep.resources AS resource_row
    JOIN aep.works AS work_row ON work_row.work_id = p_work_id
    JOIN aep.project_resources AS project_resource
      ON project_resource.project_id = work_row.project_id
     AND project_resource.resource_id = resource_row.resource_id
    WHERE resource_row.resource_id = p_resource_id
      AND resource_row.provider = 'github'
      AND resource_row.resource_type = 'repository'
      AND resource_row.host = p_host
      AND resource_row.stable_resource_id = p_repository_id
      AND project_resource.status = 'active'
      AND project_resource.access_mode IN ('write','read_write')
  ) THEN
    RAISE EXCEPTION 'Work project has no active write grant for this physical GitHub repository'
      USING ERRCODE = '42501';
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
      updated_at = clock_timestamp()
  WHERE execution_id = p_execution_id;

  RETURN jsonb_build_object(
    'delivery_id', v_existing.delivery_id,
    'execution_id', v_existing.execution_id,
    'delivery_branch', v_existing.delivery_branch,
    'replayed', false
  );
END
$function$;

CREATE FUNCTION aep.record_delivery_pr_state(
  p_execution_id uuid,
  p_pull_request_number bigint,
  p_pull_request_url text,
  p_pr_head_sha text,
  p_source_ref text DEFAULT 'github://pull-request'
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, aep
AS $function$
DECLARE
  v_delivery aep.execution_deliveries%ROWTYPE;
  v_head_changed boolean;
BEGIN
  IF p_pull_request_number IS NULL OR p_pull_request_number < 1
     OR p_pull_request_url IS NULL OR length(btrim(p_pull_request_url)) = 0
     OR p_pr_head_sha IS NULL OR p_pr_head_sha !~ '^[0-9a-f]{40}$' THEN
    RAISE EXCEPTION 'PR identity and exact HEAD SHA are required' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO v_delivery
  FROM aep.execution_deliveries
  WHERE execution_id = p_execution_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Execution delivery identity does not exist' USING ERRCODE = '23503';
  END IF;
  IF v_delivery.pull_request_number IS NOT NULL
     AND v_delivery.pull_request_number <> p_pull_request_number THEN
    RAISE EXCEPTION 'Execution cannot change its pull request identity' USING ERRCODE = '23505';
  END IF;
  v_head_changed := v_delivery.pr_head_sha IS NOT NULL
                    AND v_delivery.pr_head_sha <> p_pr_head_sha;

  IF v_head_changed THEN
    INSERT INTO aep.delivery_evidence_invalidations(evidence_id, reason, invalidated_by_ref)
    SELECT evidence_row.evidence_id, 'pr_head_changed', p_source_ref
    FROM aep.execution_delivery_evidence AS evidence_row
    WHERE evidence_row.execution_id = p_execution_id
      AND evidence_row.evidence_kind IN ('ci','process_review','native_approval')
      AND evidence_row.subject_sha <> p_pr_head_sha
      AND NOT EXISTS (
        SELECT 1 FROM aep.delivery_evidence_invalidations AS prior
        WHERE prior.evidence_id = evidence_row.evidence_id
      );
  END IF;

  UPDATE aep.execution_deliveries
  SET pull_request_number = p_pull_request_number,
      pull_request_url = p_pull_request_url,
      pr_head_sha = p_pr_head_sha,
      updated_at = clock_timestamp()
  WHERE execution_id = p_execution_id;

  UPDATE aep.executions
  SET pull_request_number = p_pull_request_number,
      head_sha = p_pr_head_sha,
      updated_at = clock_timestamp()
  WHERE execution_id = p_execution_id;

  INSERT INTO aep.execution_delivery_evidence(
    work_id, execution_id, fence, evidence_kind, subject_sha, source_ref, payload
  ) VALUES (
    v_delivery.work_id, p_execution_id, v_delivery.fence,
    'pr_head', p_pr_head_sha, p_source_ref,
    jsonb_build_object('pull_request_number', p_pull_request_number)
  );
END
$function$;

CREATE FUNCTION aep.record_delivery_evidence(
  p_execution_id uuid,
  p_evidence_kind text,
  p_subject_sha text,
  p_source_ref text,
  p_actor_principal text,
  p_payload jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, aep
AS $function$
DECLARE
  v_delivery aep.execution_deliveries%ROWTYPE;
  v_capabilities jsonb;
  v_evidence_id uuid;
BEGIN
  SELECT * INTO v_delivery
  FROM aep.execution_deliveries
  WHERE execution_id = p_execution_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Execution delivery identity does not exist' USING ERRCODE = '23503';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM aep.works AS work_row
    JOIN aep.executions AS execution_row
      ON execution_row.work_id = work_row.work_id
     AND execution_row.execution_id = p_execution_id
    WHERE work_row.work_id = v_delivery.work_id
      AND work_row.current_execution_id = p_execution_id
      AND work_row.fence_generation = v_delivery.fence
      AND execution_row.fence = v_delivery.fence
      AND execution_row.status = 'running'
  ) THEN
    RAISE EXCEPTION 'Stale execution cannot create new delivery evidence'
      USING ERRCODE = '55000';
  END IF;
  IF p_subject_sha IS NULL OR p_subject_sha !~ '^[0-9a-f]{40}$'
     OR p_source_ref IS NULL OR length(btrim(p_source_ref)) = 0
     OR p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object' THEN
    RAISE EXCEPTION 'Evidence requires an exact SHA, source reference, and object payload'
      USING ERRCODE = '22023';
  END IF;

  SELECT manifest->'operations' INTO v_capabilities
  FROM aep.delivery_adapter_manifests
  WHERE resource_id = v_delivery.resource_id;
  IF v_capabilities IS NULL THEN
    RAISE EXCEPTION 'Repository adapter capability manifest is unavailable'
      USING ERRCODE = '55000';
  END IF;

  IF p_evidence_kind IN ('ci','process_review','native_approval')
     AND (v_delivery.pr_head_sha IS NULL OR p_subject_sha <> v_delivery.pr_head_sha) THEN
    RAISE EXCEPTION 'PR evidence must bind to the current exact PR HEAD SHA'
      USING ERRCODE = '22023';
  END IF;
  IF p_evidence_kind = 'post_merge_ci'
     AND (v_delivery.merge_sha IS NULL OR p_subject_sha <> v_delivery.merge_sha) THEN
    RAISE EXCEPTION 'Post-merge CI must bind to the exact merge SHA'
      USING ERRCODE = '22023';
  END IF;
  IF p_evidence_kind IN ('deployment','owner_acceptance')
     AND (v_delivery.merge_sha IS NULL OR p_subject_sha <> v_delivery.merge_sha) THEN
    RAISE EXCEPTION 'Deployment and Owner acceptance must bind to the exact merge SHA'
      USING ERRCODE = '22023';
  END IF;
  IF p_evidence_kind NOT IN (
    'ci','process_review','native_approval','post_merge_ci','deployment','owner_acceptance'
  ) THEN
    RAISE EXCEPTION 'Unsupported delivery evidence kind: %', p_evidence_kind
      USING ERRCODE = '22023';
  END IF;

  IF p_evidence_kind = 'ci'
     AND v_capabilities#>>'{ci_lookup,status}' IS DISTINCT FROM 'supported' THEN
    RAISE EXCEPTION 'CI lookup is not supported by the repository adapter'
      USING ERRCODE = '0A000';
  ELSIF p_evidence_kind = 'post_merge_ci'
     AND v_capabilities#>>'{post_merge_verification,status}' IS DISTINCT FROM 'supported' THEN
    RAISE EXCEPTION 'Post-merge verification is not supported by the repository adapter'
      USING ERRCODE = '0A000';
  END IF;

  IF p_evidence_kind = 'process_review' THEN
    IF v_capabilities#>>'{process_review,status}' IS DISTINCT FROM 'supported'
       OR p_payload->>'github_review_state' IS DISTINCT FROM 'COMMENTED' THEN
      RAISE EXCEPTION 'Process Review requires a supported COMMENTED event, not native approval'
        USING ERRCODE = '22023';
    END IF;
  ELSIF p_evidence_kind = 'native_approval' THEN
    IF v_capabilities#>>'{native_approval,status}' IS DISTINCT FROM 'supported'
       OR p_payload->>'github_review_state' IS DISTINCT FROM 'APPROVED'
       OR p_payload->>'native_event' IS DISTINCT FROM 'true' THEN
      RAISE EXCEPTION 'Native Approval requires an observed GitHub APPROVED review event'
        USING ERRCODE = '22023';
    END IF;
  ELSIF p_evidence_kind IN ('ci','post_merge_ci') THEN
    IF p_payload->>'tested_sha' IS DISTINCT FROM p_subject_sha
       OR p_payload->>'conclusion' IS NULL
       OR p_payload->>'conclusion' NOT IN ('success','failure','cancelled','neutral') THEN
      RAISE EXCEPTION 'CI evidence must state the exact tested SHA and conclusion'
        USING ERRCODE = '22023';
    END IF;
  ELSIF p_evidence_kind = 'deployment' THEN
    IF v_capabilities#>>'{deployment,status}' IS DISTINCT FROM 'supported' THEN
      RAISE EXCEPTION 'Deployment is unsupported by the repository adapter'
        USING ERRCODE = '0A000';
    END IF;
  ELSIF p_evidence_kind = 'owner_acceptance' THEN
    IF p_payload->>'direct_owner_confirmation' IS DISTINCT FROM 'true'
       OR NOT EXISTS (
         SELECT 1 FROM aep.execution_delivery_evidence_current AS evidence_row
         WHERE evidence_row.execution_id = p_execution_id
           AND evidence_row.evidence_kind = 'post_merge_ci'
           AND evidence_row.subject_sha = v_delivery.merge_sha
           AND evidence_row.is_valid
           AND evidence_row.payload->>'conclusion' = 'success'
       ) THEN
      RAISE EXCEPTION 'Owner acceptance requires direct confirmation after successful exact-merge-SHA CI'
        USING ERRCODE = '55000';
    END IF;
  END IF;

  INSERT INTO aep.execution_delivery_evidence(
    work_id, execution_id, fence, evidence_kind, subject_sha,
    source_ref, actor_principal, payload
  ) VALUES (
    v_delivery.work_id, p_execution_id, v_delivery.fence, p_evidence_kind,
    p_subject_sha, p_source_ref, p_actor_principal, p_payload
  ) RETURNING evidence_id INTO v_evidence_id;

  RETURN v_evidence_id;
END
$function$;

CREATE FUNCTION aep.create_external_operation_intent(
  p_work_id uuid,
  p_execution_id uuid,
  p_fence bigint,
  p_operation_key text,
  p_operation_type text,
  p_resource_id uuid,
  p_host text,
  p_repository_id text,
  p_target_ref text,
  p_payload jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, aep, public
AS $function$
DECLARE
  v_intent jsonb;
  v_hash text;
  v_existing aep.operation_receipts%ROWTYPE;
  v_capability_key text;
  v_capability_status text;
  v_receipt_id uuid;
BEGIN
  IF p_operation_key IS NULL OR length(btrim(p_operation_key)) NOT BETWEEN 1 AND 255
     OR p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object' THEN
    RAISE EXCEPTION 'Operation key and canonical object payload are required'
      USING ERRCODE = '22023';
  END IF;
  IF p_operation_type NOT IN (
    'branch_ref_create','pull_request_create','pull_request_update',
    'process_review','native_approval','merge','ci_lookup',
    'post_merge_verification','deployment'
  ) THEN
    RAISE EXCEPTION 'Unknown GitHub operation type: %', p_operation_type
      USING ERRCODE = '22023';
  END IF;
  v_capability_key := CASE p_operation_type
    WHEN 'branch_ref_create' THEN 'branch_ref'
    WHEN 'pull_request_create' THEN 'pull_request'
    WHEN 'pull_request_update' THEN 'pull_request'
    WHEN 'process_review' THEN 'process_review'
    WHEN 'native_approval' THEN 'native_approval'
    WHEN 'merge' THEN 'merge'
    WHEN 'ci_lookup' THEN 'ci_lookup'
    WHEN 'post_merge_verification' THEN 'post_merge_verification'
    WHEN 'deployment' THEN 'deployment'
  END;

  v_intent := jsonb_build_object(
    'work_id', p_work_id,
    'execution_id', p_execution_id,
    'fence', p_fence,
    'operation_key', p_operation_key,
    'operation_type', p_operation_type,
    'resource_id', p_resource_id,
    'host', p_host,
    'repository_id', p_repository_id,
    'target_ref', p_target_ref,
    'payload', p_payload
  );
  v_hash := encode(public.digest(convert_to(v_intent::text, 'UTF8'), 'sha256'), 'hex');

  -- Serialize the idempotency key even when no receipt row exists yet.
  -- Hash collisions only serialize unrelated keys; they cannot merge identities.
  PERFORM pg_advisory_xact_lock(
    hashtextextended('github-operation:' || p_operation_key, 0)
  );

  SELECT * INTO v_existing
  FROM aep.operation_receipts
  WHERE provider = 'github' AND operation_key = p_operation_key
  FOR UPDATE;
  IF FOUND THEN
    IF v_existing.request_payload_sha256 <> v_hash THEN
      RAISE EXCEPTION 'External operation idempotency key reused with a different payload'
        USING ERRCODE = '23505';
    END IF;
    RETURN v_existing.operation_receipt_id;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM aep.works AS work_row
    JOIN aep.executions AS execution_row
      ON execution_row.work_id = work_row.work_id
     AND execution_row.execution_id = p_execution_id
    JOIN aep.execution_deliveries AS delivery
      ON delivery.execution_id = p_execution_id
     AND delivery.work_id = p_work_id
    WHERE work_row.work_id = p_work_id
      AND work_row.status = 'running'
      AND work_row.current_execution_id = p_execution_id
      AND work_row.fence_generation = p_fence
      AND execution_row.fence = p_fence
      AND execution_row.status = 'running'
      AND delivery.resource_id = p_resource_id
      AND delivery.host = p_host
      AND delivery.repository_id = p_repository_id
  ) THEN
    RAISE EXCEPTION 'External operation intent requires the current execution fence and target repository'
      USING ERRCODE = '55000';
  END IF;

  SELECT manifest#>>ARRAY['operations',v_capability_key,'status']
  INTO v_capability_status
  FROM aep.delivery_adapter_manifests
  WHERE resource_id = p_resource_id;
  IF v_capability_status IS DISTINCT FROM 'supported' THEN
    IF v_capability_status = 'unavailable' THEN
      RAISE EXCEPTION 'External operation capability is temporarily unavailable: %', v_capability_key
        USING ERRCODE = '55000';
    END IF;
    RAISE EXCEPTION 'External operation capability is unsupported: %', v_capability_key
      USING ERRCODE = '0A000';
  END IF;

  INSERT INTO aep.operation_receipts(
    work_id, execution_id, provider, operation_key, operation_type,
    target_resource_id, target_ref, request_payload_sha256, intent_payload,
    execution_fence, target_host, target_repository_id, status,
    reconciliation_status
  ) VALUES (
    p_work_id, p_execution_id, 'github', p_operation_key, p_operation_type,
    p_resource_id, p_target_ref, v_hash, v_intent,
    p_fence, p_host, p_repository_id, 'intent_created', 'not_started'
  ) RETURNING operation_receipt_id INTO v_receipt_id;

  INSERT INTO aep.operation_receipt_events(
    operation_receipt_id, event_type, event_payload
  ) VALUES (
    v_receipt_id, 'intent_created',
    jsonb_build_object('intent_sha256', v_hash, 'execution_fence', p_fence)
  );
  RETURN v_receipt_id;
END
$function$;

CREATE FUNCTION aep.mark_external_operation_uncertain(
  p_operation_receipt_id uuid,
  p_reason text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, aep
AS $function$
DECLARE
  v_receipt aep.operation_receipts%ROWTYPE;
BEGIN
  SELECT * INTO v_receipt
  FROM aep.operation_receipts
  WHERE operation_receipt_id = p_operation_receipt_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'External operation intent does not exist' USING ERRCODE = '23503';
  END IF;
  IF v_receipt.status IN ('succeeded','reconciled') THEN
    RETURN;
  END IF;
  UPDATE aep.operation_receipts
  SET status = 'uncertain',
      reconciliation_status = 'pending',
      updated_at = clock_timestamp()
  WHERE operation_receipt_id = p_operation_receipt_id;
  INSERT INTO aep.operation_receipt_events(
    operation_receipt_id, event_type, event_payload
  ) VALUES (
    p_operation_receipt_id, 'reconciliation_started',
    jsonb_build_object('reason', COALESCE(p_reason,'external response was lost'))
  );
END
$function$;

CREATE FUNCTION aep.reconcile_external_operation(
  p_operation_receipt_id uuid,
  p_observation jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, aep
AS $function$
DECLARE
  v_receipt aep.operation_receipts%ROWTYPE;
  v_stale boolean;
  v_found boolean;
  v_delivery aep.execution_deliveries%ROWTYPE;
  v_merge_sha text;
  v_external_id text;
  v_external_type text;
  v_revision text;
BEGIN
  IF p_observation IS NULL OR jsonb_typeof(p_observation) <> 'object'
     OR NOT (p_observation ? 'found') THEN
    RAISE EXCEPTION 'Reconciliation requires an explicit provider observation'
      USING ERRCODE = '22023';
  END IF;
  SELECT * INTO v_receipt
  FROM aep.operation_receipts
  WHERE operation_receipt_id = p_operation_receipt_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'External operation intent does not exist' USING ERRCODE = '23503';
  END IF;

  v_found := p_observation->>'found' = 'true';
  SELECT NOT EXISTS (
    SELECT 1 FROM aep.works AS work_row
    WHERE work_row.work_id = v_receipt.work_id
      AND work_row.current_execution_id = v_receipt.execution_id
      AND work_row.fence_generation = v_receipt.execution_fence
  ) INTO v_stale;

  IF NOT v_found THEN
    IF p_observation->>'authoritative' = 'true' AND NOT v_stale
       AND v_receipt.status IN ('intent_created','submitted','uncertain','reconciling') THEN
      UPDATE aep.operation_receipts
      SET status = 'intent_created',
          reconciliation_status = 'not_started',
          receipt_payload = NULL,
          external_object_type = NULL,
          external_id = NULL,
          result_revision = NULL,
          reconciled_at = NULL,
          attempt_count = attempt_count + 1,
          stale_execution_detected = false,
          updated_at = clock_timestamp()
      WHERE operation_receipt_id = p_operation_receipt_id;
      INSERT INTO aep.operation_receipt_events(
        operation_receipt_id, event_type, event_payload
      ) VALUES (
        p_operation_receipt_id, 'reconciliation_failed',
        jsonb_build_object('authoritative_not_found', true, 'retry_safe', true)
      );
      RETURN jsonb_build_object('status','intent_created','retry_safe',true,'stale',false);
    END IF;

    UPDATE aep.operation_receipts
    SET status = 'manual_review_required',
        reconciliation_status = 'manual_review_required',
        stale_execution_detected = v_stale,
        updated_at = clock_timestamp()
    WHERE operation_receipt_id = p_operation_receipt_id;
    INSERT INTO aep.operation_receipt_events(
      operation_receipt_id, event_type, event_payload
    ) VALUES (
      p_operation_receipt_id, 'manual_review_required',
      jsonb_build_object('authoritative_not_found', p_observation->>'authoritative' = 'true',
                         'stale_execution', v_stale)
    );
    RETURN jsonb_build_object('status','manual_review_required','retry_safe',false,'stale',v_stale);
  END IF;

  v_external_id := NULLIF(p_observation->>'external_id','');
  v_external_type := NULLIF(p_observation->>'external_object_type','');
  v_revision := NULLIF(p_observation->>'revision','');
  IF v_external_id IS NULL OR v_external_type IS NULL THEN
    RAISE EXCEPTION 'Found provider observation must preserve external object type and identifier'
      USING ERRCODE = '22023';
  END IF;
  IF v_receipt.external_id IS NOT NULL AND v_receipt.external_id <> v_external_id THEN
    UPDATE aep.operation_receipts
    SET status = 'manual_review_required',
        reconciliation_status = 'manual_review_required',
        stale_execution_detected = v_stale,
        updated_at = clock_timestamp()
    WHERE operation_receipt_id = p_operation_receipt_id;
    INSERT INTO aep.operation_receipt_events(
      operation_receipt_id, event_type, event_payload
    ) VALUES (
      p_operation_receipt_id, 'manual_review_required',
      jsonb_build_object('reason','provider returned a different external identifier',
                         'previous_external_id',v_receipt.external_id,
                         'observed_external_id',v_external_id)
    );
    RETURN jsonb_build_object('status','manual_review_required','retry_safe',false,'stale',v_stale);
  END IF;

  UPDATE aep.operation_receipts
  SET status = 'reconciled',
      reconciliation_status = 'reconciled',
      external_object_type = v_external_type,
      external_id = v_external_id,
      result_revision = v_revision,
      receipt_payload = p_observation,
      stale_execution_detected = v_stale,
      reconciled_at = clock_timestamp(),
      updated_at = clock_timestamp()
  WHERE operation_receipt_id = p_operation_receipt_id;

  INSERT INTO aep.operation_receipt_events(
    operation_receipt_id, event_type, event_payload
  ) VALUES
    (p_operation_receipt_id, 'external_result_observed', p_observation),
    (p_operation_receipt_id, 'reconciled',
      jsonb_build_object('external_id',v_external_id,'revision',v_revision,'stale_execution',v_stale));

  IF v_receipt.operation_type IN ('pull_request_create','pull_request_update')
     AND p_observation ? 'pull_request_number'
     AND p_observation ? 'pr_head_sha' THEN
    PERFORM aep.record_delivery_pr_state(
      v_receipt.execution_id,
      (p_observation->>'pull_request_number')::bigint,
      p_observation->>'pull_request_url',
      p_observation->>'pr_head_sha',
      'github://reconciliation/' || v_external_id
    );
  END IF;

  IF v_receipt.operation_type = 'merge' THEN
    v_merge_sha := p_observation->>'merge_sha';
    IF v_merge_sha IS NULL OR v_merge_sha !~ '^[0-9a-f]{40}$' THEN
      RAISE EXCEPTION 'Merge reconciliation must include the exact merge SHA'
        USING ERRCODE = '22023';
    END IF;
    SELECT * INTO v_delivery
    FROM aep.execution_deliveries
    WHERE execution_id = v_receipt.execution_id
    FOR UPDATE;
    IF v_delivery.merge_sha IS NOT NULL AND v_delivery.merge_sha <> v_merge_sha THEN
      RAISE EXCEPTION 'Execution merge SHA changed after reconciliation'
        USING ERRCODE = '23505';
    END IF;
    UPDATE aep.execution_deliveries
    SET merge_sha = v_merge_sha,
        stale_external_side_effect = v_stale,
        updated_at = clock_timestamp()
    WHERE execution_id = v_receipt.execution_id;

    IF v_stale THEN
      INSERT INTO aep.delivery_evidence_invalidations(evidence_id, reason, invalidated_by_ref)
      SELECT evidence_row.evidence_id, 'stale_execution_external_merge',
             'github://merge/' || v_external_id
      FROM aep.execution_delivery_evidence AS evidence_row
      WHERE evidence_row.execution_id = v_receipt.execution_id
        AND evidence_row.evidence_kind IN ('ci','process_review','native_approval')
        AND NOT EXISTS (
          SELECT 1 FROM aep.delivery_evidence_invalidations AS prior
          WHERE prior.evidence_id = evidence_row.evidence_id
        );
    END IF;

    INSERT INTO aep.execution_delivery_evidence(
      work_id, execution_id, fence, evidence_kind, subject_sha, source_ref, payload
    ) VALUES (
      v_receipt.work_id, v_receipt.execution_id, v_receipt.execution_fence,
      'merge', v_merge_sha, 'github://merge/' || v_external_id,
      jsonb_build_object('pr_number',v_delivery.pull_request_number,
                         'merge_sha',v_merge_sha,'stale_execution',v_stale)
    );
  END IF;

  RETURN jsonb_build_object(
    'status','reconciled','retry_safe',false,'stale',v_stale,
    'external_id',v_external_id,'merge_sha',v_merge_sha
  );
END
$function$;

ALTER TABLE aep.delivery_adapter_manifests OWNER TO aep_owner;
ALTER TABLE aep.execution_deliveries OWNER TO aep_owner;
ALTER TABLE aep.execution_delivery_evidence OWNER TO aep_owner;
ALTER TABLE aep.delivery_evidence_invalidations OWNER TO aep_owner;

DO $aep$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'delivery_adapter_manifests','execution_deliveries',
    'execution_delivery_evidence','delivery_evidence_invalidations'
  ] LOOP
    EXECUTE format('ALTER TABLE aep.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE aep.%I FORCE ROW LEVEL SECURITY', t);
    EXECUTE format(
      'CREATE POLICY owner_full_access ON aep.%I FOR ALL TO aep_owner USING (true) WITH CHECK (true)',
      t
    );
  END LOOP;
END
$aep$;

CREATE TRIGGER execution_delivery_evidence_append_only
BEFORE UPDATE OR DELETE ON aep.execution_delivery_evidence
FOR EACH ROW EXECUTE FUNCTION aep.reject_work_event_mutation();

CREATE TRIGGER delivery_evidence_invalidations_append_only
BEFORE UPDATE OR DELETE ON aep.delivery_evidence_invalidations
FOR EACH ROW EXECUTE FUNCTION aep.reject_work_event_mutation();

REVOKE ALL ON aep.delivery_adapter_manifests,
  aep.execution_deliveries, aep.execution_delivery_evidence,
  aep.delivery_evidence_invalidations
FROM PUBLIC, aep_runtime;
REVOKE ALL ON aep.execution_delivery_evidence_current FROM PUBLIC, aep_runtime;

ALTER FUNCTION aep.register_delivery_adapter_manifest(uuid,jsonb,uuid) OWNER TO aep_owner;
ALTER FUNCTION aep.allocate_execution_delivery(uuid,uuid,bigint,uuid,text,text,text,text,text) OWNER TO aep_owner;
ALTER FUNCTION aep.record_delivery_pr_state(uuid,bigint,text,text,text) OWNER TO aep_owner;
ALTER FUNCTION aep.record_delivery_evidence(uuid,text,text,text,text,jsonb) OWNER TO aep_owner;
ALTER FUNCTION aep.create_external_operation_intent(uuid,uuid,bigint,text,text,uuid,text,text,text,jsonb) OWNER TO aep_owner;
ALTER FUNCTION aep.mark_external_operation_uncertain(uuid,text) OWNER TO aep_owner;
ALTER FUNCTION aep.reconcile_external_operation(uuid,jsonb) OWNER TO aep_owner;

REVOKE ALL ON FUNCTION aep.register_delivery_adapter_manifest(uuid,jsonb,uuid),
  aep.allocate_execution_delivery(uuid,uuid,bigint,uuid,text,text,text,text,text),
  aep.record_delivery_pr_state(uuid,bigint,text,text,text),
  aep.record_delivery_evidence(uuid,text,text,text,text,jsonb),
  aep.create_external_operation_intent(uuid,uuid,bigint,text,text,uuid,text,text,text,jsonb),
  aep.mark_external_operation_uncertain(uuid,text),
  aep.reconcile_external_operation(uuid,jsonb)
FROM PUBLIC;

GRANT EXECUTE ON FUNCTION aep.register_delivery_adapter_manifest(uuid,jsonb,uuid),
  aep.allocate_execution_delivery(uuid,uuid,bigint,uuid,text,text,text,text,text),
  aep.record_delivery_pr_state(uuid,bigint,text,text,text),
  aep.record_delivery_evidence(uuid,text,text,text,text,jsonb),
  aep.create_external_operation_intent(uuid,uuid,bigint,text,text,uuid,text,text,text,jsonb),
  aep.mark_external_operation_uncertain(uuid,text),
  aep.reconcile_external_operation(uuid,jsonb)
TO aep_runtime;

COMMIT;
