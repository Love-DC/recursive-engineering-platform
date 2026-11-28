-- Stage 4A follow-up: recover bounded project/work-scoped ResourceClaims.
-- Prototype-only migration. Do not apply to production Supabase or legacy RAE.
-- The authorization gate remains before all Work, Execution, Claim and Evidence reads.

BEGIN;

CREATE OR REPLACE FUNCTION aep.recover_session_state(
  p_project_id uuid,
  p_recovery_session_id uuid,
  p_work_limit integer DEFAULT 100,
  p_related_limit integer DEFAULT 200
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, aep
AS $function$
DECLARE
  v_project aep.projects%ROWTYPE;
  v_work_ids uuid[];
  v_work_count integer;
  v_now timestamptz := clock_timestamp();
BEGIN
  IF p_project_id IS NULL OR p_recovery_session_id IS NULL THEN
    RAISE EXCEPTION 'Project and recovery-session identities are required'
      USING ERRCODE = '22004';
  END IF;
  IF p_work_limit IS NULL OR p_work_limit NOT BETWEEN 1 AND 100
     OR p_related_limit IS NULL OR p_related_limit NOT BETWEEN 1 AND 250 THEN
    RAISE EXCEPTION 'Recovery limits must be work=1..100 and related=1..250'
      USING ERRCODE = '22023';
  END IF;

  -- Authorization/scope gate occurs before reading Work, Execution, ResourceClaim,
  -- Evidence, Delivery or receipt content. Read grants are explicit ProjectResource rows;
  -- write grants additionally require their still-approved direct-Owner decision.
  SELECT project_row.* INTO v_project
  FROM aep.projects AS project_row
  WHERE project_row.project_id = p_project_id
    AND project_row.status IN ('active','paused')
    AND EXISTS (
      SELECT 1
      FROM aep.project_resources AS project_resource
      JOIN aep.resources AS resource_row
        ON resource_row.resource_id = project_resource.resource_id
      LEFT JOIN aep.owner_decisions AS decision
        ON decision.decision_id = project_resource.grant_decision_id
      WHERE project_resource.project_id = project_row.project_id
        AND project_resource.status = 'active'
        AND resource_row.status = 'active'
        AND (
          project_resource.access_mode = 'read'
          OR (
            project_resource.access_mode IN ('write','read_write')
            AND decision.status = 'approved'
            AND (
              (decision.scope_type = 'project'
                AND decision.scope_key = project_resource.project_id::text)
              OR
              (decision.scope_type = 'resource'
                AND decision.scope_key = project_resource.resource_id::text)
            )
          )
        )
    );

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Recovery denied: project has no active readable ProjectResource grant'
      USING ERRCODE = '42501';
  END IF;

  SELECT count(*)::integer INTO v_work_count
  FROM aep.works AS work_row
  WHERE work_row.project_id = p_project_id
    AND work_row.status NOT IN ('completed','cancelled','rejected');

  SELECT COALESCE(array_agg(selected.work_id), ARRAY[]::uuid[])
  INTO v_work_ids
  FROM (
    SELECT work_row.work_id
    FROM aep.works AS work_row
    WHERE work_row.project_id = p_project_id
      AND work_row.status NOT IN ('completed','cancelled','rejected')
    ORDER BY work_row.updated_at DESC, work_row.work_id
    LIMIT p_work_limit
  ) AS selected;

  RETURN jsonb_build_object(
    'schema_version', 1,
    'recovered_at', v_now,
    'recovery_session_id', p_recovery_session_id,
    'project', jsonb_build_object(
      'project_id', v_project.project_id,
      'project_key', v_project.project_key,
      'name', v_project.name,
      'status', v_project.status
    ),
    'authorization', jsonb_build_object(
      'scope_gate', 'active_project_resource_grant',
      'checked_before_work_and_evidence_retrieval', true,
      'checked_before_resource_claim_retrieval', true,
      'session_id_is_authentication', false,
      'prototype_boundary', 'trusted_single_owner; authenticated production principal binding remains open'
    ),
    'work_count', v_work_count,
    'work_list_truncated', v_work_count > p_work_limit,
    'work_items', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'work_id', work_row.work_id,
        'project_id', work_row.project_id,
        'identity_kind', work_row.identity_kind,
        'identity_key', work_row.identity_key,
        'identity_version', work_row.identity_version,
        'work_type', work_row.work_type,
        'status', work_row.status,
        'title', work_row.title,
        'acceptance', work_row.acceptance,
        'version', work_row.version,
        'current_execution_id', work_row.current_execution_id,
        'fence_generation', work_row.fence_generation,
        'dependency_blocked', work_row.dependency_blocked,
        'dependencies_satisfied', aep.work_dependencies_satisfied(work_row.work_id),
        'updated_at', work_row.updated_at,
        'created_at', work_row.created_at
      ) ORDER BY work_row.updated_at DESC, work_row.work_id)
      FROM aep.works AS work_row
      WHERE work_row.work_id = ANY(v_work_ids)
    ), '[]'::jsonb),
    'dependencies', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'source_work_id', relation_row.source_work_id,
        'target_work_id', relation_row.target_work_id,
        'relation_type', relation_row.relation_type,
        'required', relation_row.required,
        'status', relation_row.status,
        'dependency_graph_id', relation_row.dependency_graph_id,
        'graph_version', graph_row.graph_version,
        'target_status', target_work.status
      ) ORDER BY relation_row.source_work_id, relation_row.relation_type,
                 relation_row.target_work_id)
      FROM (
        SELECT relation_source.*
        FROM aep.work_relations AS relation_source
        WHERE relation_source.source_work_id = ANY(v_work_ids)
          AND relation_source.status = 'active'
        ORDER BY relation_source.source_work_id, relation_source.relation_type,
                 relation_source.target_work_id
        LIMIT p_related_limit
      ) AS relation_row
      JOIN aep.works AS target_work
        ON target_work.work_id = relation_row.target_work_id
      LEFT JOIN aep.dependency_graphs AS graph_row
        ON graph_row.graph_id = relation_row.dependency_graph_id
    ), '[]'::jsonb),
    'executions', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'execution_id', execution_row.execution_id,
        'work_id', execution_row.work_id,
        'session_id', execution_row.session_id,
        'attempt_no', execution_row.attempt_no,
        'status', execution_row.status,
        'fence', execution_row.fence,
        'lease_until', execution_row.lease_until,
        'lease_expired', execution_row.lease_until IS NOT NULL
                         AND execution_row.lease_until <= v_now,
        'is_current', work_row.current_execution_id = execution_row.execution_id,
        -- No persisted, trustworthy session-termination fact exists in this prototype.
        -- Execution expiry/completion fences database writes but cannot terminate a
        -- ChatGPT session or revoke its shared external credentials.
        'old_session_may_still_be_active', execution_row.session_id IS NOT NULL,
        'session_termination_observed', false,
        'started_at', execution_row.started_at,
        'finished_at', execution_row.finished_at,
        'base_sha', execution_row.base_sha,
        'head_sha', execution_row.head_sha,
        'delivery_branch', execution_row.delivery_branch,
        'pull_request_number', execution_row.pull_request_number,
        'result', execution_row.result
      ) ORDER BY execution_row.attempt_no DESC, execution_row.execution_id)
      FROM (
        SELECT execution_source.*
        FROM aep.executions AS execution_source
        WHERE execution_source.work_id = ANY(v_work_ids)
        ORDER BY execution_source.attempt_no DESC, execution_source.execution_id
        LIMIT p_related_limit
      ) AS execution_row
      JOIN aep.works AS work_row ON work_row.work_id = execution_row.work_id
    ), '[]'::jsonb),
    'resource_claims', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'resource_claim_id', claim_row.resource_claim_id,
        'project_id', claim_row.project_id,
        'work_id', claim_row.work_id,
        'execution_id', claim_row.execution_id,
        'resource_id', claim_row.resource_id,
        'resource_ref', claim_row.resource_ref,
        'write_set_kind', claim_row.write_set_kind,
        'conflict_key', claim_row.conflict_key,
        'normalized_write_set', claim_row.normalized_write_set,
        'status', claim_row.status,
        'lease_until', claim_row.lease_until,
        'lease_expired', claim_row.lease_until IS NOT NULL AND claim_row.lease_until <= v_now,
        'fence', claim_row.fence,
        'created_at', claim_row.created_at,
        'released_at', claim_row.released_at,
        'is_current_execution', work_row.current_execution_id = claim_row.execution_id
      ) ORDER BY claim_row.created_at DESC, claim_row.resource_claim_id)
      FROM (
        SELECT claim_source.*
        FROM aep.resource_claims AS claim_source
        WHERE claim_source.project_id = p_project_id
          AND claim_source.work_id = ANY(v_work_ids)
        ORDER BY claim_source.created_at DESC, claim_source.resource_claim_id
        LIMIT p_related_limit
      ) AS claim_row
      JOIN aep.works AS work_row
        ON work_row.work_id = claim_row.work_id
    ), '[]'::jsonb),
    'work_events', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'event_id', recent.event_id,
        'project_id', recent.project_id,
        'work_id', recent.work_id,
        'execution_id', recent.execution_id,
        'session_id', recent.session_id,
        'event_type', recent.event_type,
        'event_key', recent.event_key,
        'actor_key', recent.actor_key,
        'event_payload', recent.event_payload,
        'created_at', recent.created_at
      ) ORDER BY recent.created_at DESC, recent.event_id)
      FROM (
        SELECT event_row.*
        FROM aep.work_events AS event_row
        WHERE event_row.work_id = ANY(v_work_ids)
        ORDER BY event_row.created_at DESC, event_row.event_id
        LIMIT p_related_limit
      ) AS recent
    ), '[]'::jsonb),
    'evidence', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'evidence_id', evidence_row.evidence_id,
        'work_id', evidence_row.work_id,
        'execution_id', evidence_row.execution_id,
        'evidence_type', evidence_row.evidence_type,
        'source_ref', evidence_row.source_ref,
        'source_revision', evidence_row.source_revision,
        'content_sha256', evidence_row.content_sha256,
        'observed_at', evidence_row.observed_at,
        'valid_at', evidence_row.valid_at,
        'provenance', evidence_row.provenance,
        'payload', evidence_row.payload
      ) ORDER BY evidence_row.observed_at DESC, evidence_row.evidence_id)
      FROM (
        SELECT evidence_row.*
        FROM aep.evidence AS evidence_row
        WHERE evidence_row.project_id = p_project_id
          AND evidence_row.work_id = ANY(v_work_ids)
        ORDER BY evidence_row.observed_at DESC, evidence_row.evidence_id
        LIMIT p_related_limit
      ) AS evidence_row
    ), '[]'::jsonb),
    'deliveries', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'delivery_id', delivery_row.delivery_id,
        'work_id', delivery_row.work_id,
        'execution_id', delivery_row.execution_id,
        'fence', delivery_row.fence,
        'resource_id', delivery_row.resource_id,
        'provider', delivery_row.provider,
        'host', delivery_row.host,
        'repository_id', delivery_row.repository_id,
        'repository_full_name', delivery_row.repository_full_name,
        'base_ref', delivery_row.base_ref,
        'base_sha', delivery_row.base_sha,
        'delivery_branch', delivery_row.delivery_branch,
        'pull_request_number', delivery_row.pull_request_number,
        'pull_request_url', delivery_row.pull_request_url,
        'pr_head_sha', delivery_row.pr_head_sha,
        'merge_sha', delivery_row.merge_sha,
        'stale_external_side_effect', delivery_row.stale_external_side_effect,
        'updated_at', delivery_row.updated_at
      ) ORDER BY delivery_row.created_at DESC, delivery_row.delivery_id)
      FROM (
        SELECT delivery_source.*
        FROM aep.execution_deliveries AS delivery_source
        WHERE delivery_source.work_id = ANY(v_work_ids)
        ORDER BY delivery_source.created_at DESC, delivery_source.delivery_id
        LIMIT p_related_limit
      ) AS delivery_row
    ), '[]'::jsonb),
    'delivery_evidence', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'evidence_id', evidence_row.evidence_id,
        'work_id', evidence_row.work_id,
        'execution_id', evidence_row.execution_id,
        'fence', evidence_row.fence,
        'evidence_kind', evidence_row.evidence_kind,
        'subject_sha', evidence_row.subject_sha,
        'source_ref', evidence_row.source_ref,
        'actor_principal', evidence_row.actor_principal,
        'payload', evidence_row.payload,
        'observed_at', evidence_row.observed_at,
        'is_valid', invalidation.invalidation_id IS NULL,
        'invalidation_reason', invalidation.reason,
        'invalidated_by_ref', invalidation.invalidated_by_ref,
        'invalidated_at', invalidation.invalidated_at
      ) ORDER BY evidence_row.observed_at DESC, evidence_row.evidence_id)
      FROM (
        SELECT evidence_source.*
        FROM aep.execution_delivery_evidence AS evidence_source
        JOIN aep.execution_deliveries AS delivery_source
          ON delivery_source.execution_id = evidence_source.execution_id
        WHERE delivery_source.work_id = ANY(v_work_ids)
        ORDER BY evidence_source.observed_at DESC, evidence_source.evidence_id
        LIMIT p_related_limit
      ) AS evidence_row
      LEFT JOIN aep.delivery_evidence_invalidations AS invalidation
        ON invalidation.evidence_id = evidence_row.evidence_id
    ), '[]'::jsonb),
    'operation_receipts', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'operation_receipt_id', receipt_row.operation_receipt_id,
        'work_id', receipt_row.work_id,
        'execution_id', receipt_row.execution_id,
        'execution_fence', receipt_row.execution_fence,
        'provider', receipt_row.provider,
        'operation_key', receipt_row.operation_key,
        'operation_type', receipt_row.operation_type,
        'target_resource_id', receipt_row.target_resource_id,
        'target_ref', receipt_row.target_ref,
        'status', receipt_row.status,
        'reconciliation_status', receipt_row.reconciliation_status,
        'external_object_type', receipt_row.external_object_type,
        'external_id', receipt_row.external_id,
        'result_revision', receipt_row.result_revision,
        'receipt_payload', receipt_row.receipt_payload,
        'attempt_count', receipt_row.attempt_count,
        'stale_execution_detected', receipt_row.stale_execution_detected,
        'created_at', receipt_row.created_at,
        'updated_at', receipt_row.updated_at,
        'reconciled_at', receipt_row.reconciled_at
      ) ORDER BY receipt_row.created_at DESC, receipt_row.operation_receipt_id)
      FROM (
        SELECT receipt_source.*
        FROM aep.operation_receipts AS receipt_source
        WHERE receipt_source.work_id = ANY(v_work_ids)
        ORDER BY receipt_source.created_at DESC, receipt_source.operation_receipt_id
        LIMIT p_related_limit
      ) AS receipt_row
    ), '[]'::jsonb),
    'operation_receipt_events', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'receipt_event_id', recent.receipt_event_id,
        'operation_receipt_id', recent.operation_receipt_id,
        'event_type', recent.event_type,
        'observed_at', recent.observed_at,
        'event_payload', recent.event_payload
      ) ORDER BY recent.observed_at DESC, recent.receipt_event_id)
      FROM (
        SELECT event_row.*
        FROM aep.operation_receipt_events AS event_row
        JOIN aep.operation_receipts AS receipt_row
          ON receipt_row.operation_receipt_id = event_row.operation_receipt_id
        WHERE receipt_row.work_id = ANY(v_work_ids)
        ORDER BY event_row.observed_at DESC, event_row.receipt_event_id
        LIMIT p_related_limit
      ) AS recent
    ), '[]'::jsonb),
    'project_resources', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'resource_id', resource_row.resource_id,
        'provider', resource_row.provider,
        'host', resource_row.host,
        'resource_type', resource_row.resource_type,
        'stable_resource_id', resource_row.stable_resource_id,
        'canonical_key', resource_row.canonical_key,
        'display_name', resource_row.display_name,
        'resource_status', resource_row.status,
        'access_mode', project_resource.access_mode,
        'grant_status', project_resource.status,
        'grant_version', project_resource.grant_version,
        'grant_decision_id', project_resource.grant_decision_id
      ) ORDER BY resource_row.resource_id)
      FROM (
        SELECT resource_link.*
        FROM aep.project_resources AS resource_link
        WHERE resource_link.project_id = p_project_id
        ORDER BY resource_link.resource_id
        LIMIT p_related_limit
      ) AS project_resource
      JOIN aep.resources AS resource_row
        ON resource_row.resource_id = project_resource.resource_id
    ), '[]'::jsonb),
    'owner_decisions', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'decision_id', decision.decision_id,
        'scope_type', decision.scope_type,
        'scope_key', decision.scope_key,
        'decision_key', decision.decision_key,
        'statement', decision.statement,
        'decision_version', decision.decision_version,
        'status', decision.status,
        'approval_source_kind', decision.approval_source_kind,
        'approval_source_ref', decision.approval_source_ref,
        'approval_source_hash', decision.approval_source_hash,
        'approver_principal', decision.approver_principal,
        'approval_provenance', decision.approval_provenance,
        'approved_at', decision.approved_at,
        'supersedes_decision_id', decision.supersedes_decision_id
      ) ORDER BY decision.scope_type, decision.scope_key, decision.decision_key,
                 decision.decision_version)
      FROM (
        SELECT decision_source.*
        FROM aep.owner_decisions AS decision_source
        WHERE (decision_source.scope_type = 'project' AND decision_source.scope_key = p_project_id::text)
           OR (decision_source.scope_type = 'resource' AND decision_source.scope_key IN (
             SELECT project_resource.resource_id::text
             FROM aep.project_resources AS project_resource
             WHERE project_resource.project_id = p_project_id
           ))
           OR (decision_source.scope_type = 'work' AND decision_source.scope_key IN (
             SELECT unnest(v_work_ids)::text
           ))
        ORDER BY decision_source.scope_type, decision_source.scope_key,
                 decision_source.decision_key, decision_source.decision_version
        LIMIT p_related_limit
      ) AS decision
    ), '[]'::jsonb),
    'adapter_capabilities', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'resource_id', manifest_row.resource_id,
        'adapter_key', manifest_row.adapter_key,
        'schema_version', manifest_row.schema_version,
        'manifest', manifest_row.manifest,
        'updated_at', manifest_row.updated_at
      ) ORDER BY manifest_row.resource_id)
      FROM (
        SELECT manifest_source.*
        FROM aep.delivery_adapter_manifests AS manifest_source
        WHERE manifest_source.resource_id IN (
          SELECT project_resource.resource_id
          FROM aep.project_resources AS project_resource
          WHERE project_resource.project_id = p_project_id
            AND project_resource.status = 'active'
        )
        ORDER BY manifest_source.updated_at DESC, manifest_source.resource_id
        LIMIT p_related_limit
      ) AS manifest_row
    ), '[]'::jsonb),
    'related_data_truncated', jsonb_build_object(
      'dependencies', (
        SELECT count(*) > p_related_limit
        FROM aep.work_relations AS relation_row
        WHERE relation_row.source_work_id = ANY(v_work_ids)
          AND relation_row.status = 'active'
      ),
      'resource_claims', (
        SELECT count(*) > p_related_limit
        FROM aep.resource_claims AS claim_row
        WHERE claim_row.project_id = p_project_id
          AND claim_row.work_id = ANY(v_work_ids)
      ),
      'executions', (
        SELECT count(*) > p_related_limit
        FROM aep.executions AS execution_row
        WHERE execution_row.work_id = ANY(v_work_ids)
      ),
      'work_events', (
        SELECT count(*) > p_related_limit
        FROM aep.work_events AS event_row
        WHERE event_row.work_id = ANY(v_work_ids)
      ),
      'evidence', (
        SELECT count(*) > p_related_limit
        FROM aep.evidence AS evidence_row
        WHERE evidence_row.project_id = p_project_id
          AND evidence_row.work_id = ANY(v_work_ids)
      ),
      'deliveries', (
        SELECT count(*) > p_related_limit
        FROM aep.execution_deliveries AS delivery_row
        WHERE delivery_row.work_id = ANY(v_work_ids)
      ),
      'delivery_evidence', (
        SELECT count(*) > p_related_limit
        FROM aep.execution_delivery_evidence AS evidence_row
        JOIN aep.execution_deliveries AS delivery_row
          ON delivery_row.execution_id = evidence_row.execution_id
        WHERE delivery_row.work_id = ANY(v_work_ids)
      ),
      'operation_receipts', (
        SELECT count(*) > p_related_limit
        FROM aep.operation_receipts AS receipt_row
        WHERE receipt_row.work_id = ANY(v_work_ids)
      ),
      'operation_receipt_events', (
        SELECT count(*) > p_related_limit
        FROM aep.operation_receipt_events AS event_row
        JOIN aep.operation_receipts AS receipt_row
          ON receipt_row.operation_receipt_id = event_row.operation_receipt_id
        WHERE receipt_row.work_id = ANY(v_work_ids)
      ),
      'project_resources', (
        SELECT count(*) > p_related_limit
        FROM aep.project_resources AS project_resource
        WHERE project_resource.project_id = p_project_id
      ),
      'owner_decisions', (
        SELECT count(*) > p_related_limit
        FROM aep.owner_decisions AS decision
        WHERE (decision.scope_type = 'project' AND decision.scope_key = p_project_id::text)
           OR (decision.scope_type = 'resource' AND decision.scope_key IN (
             SELECT project_resource.resource_id::text
             FROM aep.project_resources AS project_resource
             WHERE project_resource.project_id = p_project_id
           ))
           OR (decision.scope_type = 'work' AND decision.scope_key IN (
             SELECT unnest(v_work_ids)::text
           ))
      ),
      'adapter_capabilities', (
        SELECT count(*) > p_related_limit
        FROM aep.delivery_adapter_manifests AS manifest_row
        WHERE manifest_row.resource_id IN (
          SELECT project_resource.resource_id
          FROM aep.project_resources AS project_resource
          WHERE project_resource.project_id = p_project_id
            AND project_resource.status = 'active'
        )
      )
    ),
    'lease_semantics', jsonb_build_object(
      'observed_at', v_now,
      'expired_lease_means_takeover_may_be_considered', true,
      'expired_lease_proves_old_session_stopped', false,
      'old_external_credentials_revoked_by_fence', false
    )
  );
END
$function$;

ALTER FUNCTION aep.recover_session_state(uuid,uuid,integer,integer)
  OWNER TO aep_owner;
REVOKE ALL ON FUNCTION aep.recover_session_state(uuid,uuid,integer,integer)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION aep.recover_session_state(uuid,uuid,integer,integer)
  TO aep_runtime;

COMMIT;
