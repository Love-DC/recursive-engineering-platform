-- Stage 3 follow-up: separate observed receipt persistence from reconciliation.
-- This migration closes the ambiguous-response window without making provider
-- calls inside PostgreSQL or implying that a fence revokes shared credentials.

BEGIN;

CREATE FUNCTION aep.record_external_operation_receipt(
  p_operation_receipt_id uuid,
  p_external_object_type text,
  p_external_id text,
  p_result_revision text,
  p_receipt_payload jsonb
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, aep
AS $function$
DECLARE
  v_receipt aep.operation_receipts%ROWTYPE;
  v_stale boolean;
BEGIN
  IF p_external_object_type IS NULL OR length(btrim(p_external_object_type)) = 0
     OR p_external_id IS NULL OR length(btrim(p_external_id)) = 0
     OR p_receipt_payload IS NULL OR jsonb_typeof(p_receipt_payload) <> 'object' THEN
    RAISE EXCEPTION 'Observed external receipt requires type, identifier, and object payload'
      USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_receipt
  FROM aep.operation_receipts
  WHERE operation_receipt_id = p_operation_receipt_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'External operation intent does not exist' USING ERRCODE = '23503';
  END IF;
  IF v_receipt.status = 'reconciled' THEN
    IF v_receipt.external_object_type = p_external_object_type
       AND v_receipt.external_id = p_external_id
       AND v_receipt.receipt_payload = p_receipt_payload THEN
      RETURN true;
    END IF;
    RAISE EXCEPTION 'External operation receipt changed after reconciliation'
      USING ERRCODE = '23505';
  END IF;
  IF v_receipt.external_id IS NOT NULL
     AND (v_receipt.external_id <> p_external_id
          OR v_receipt.external_object_type <> p_external_object_type) THEN
    RAISE EXCEPTION 'External operation returned a conflicting receipt identifier'
      USING ERRCODE = '23505';
  END IF;

  SELECT NOT EXISTS (
    SELECT 1
    FROM aep.works AS work_row
    JOIN aep.executions AS execution_row
      ON execution_row.work_id = work_row.work_id
     AND execution_row.execution_id = v_receipt.execution_id
    WHERE work_row.work_id = v_receipt.work_id
      AND work_row.status = 'running'
      AND work_row.current_execution_id = v_receipt.execution_id
      AND work_row.fence_generation = v_receipt.execution_fence
      AND execution_row.status = 'running'
      AND execution_row.fence = v_receipt.execution_fence
  ) INTO v_stale;

  UPDATE aep.operation_receipts
  SET status = 'succeeded',
      reconciliation_status = 'pending',
      external_object_type = p_external_object_type,
      external_id = p_external_id,
      result_revision = p_result_revision,
      receipt_payload = p_receipt_payload,
      stale_execution_detected = v_stale,
      updated_at = clock_timestamp()
  WHERE operation_receipt_id = p_operation_receipt_id;

  INSERT INTO aep.operation_receipt_events(
    operation_receipt_id, event_type, event_payload
  ) VALUES (
    p_operation_receipt_id, 'external_result_observed',
    jsonb_build_object(
      'external_object_type', p_external_object_type,
      'external_id', p_external_id,
      'revision', p_result_revision,
      'stale_execution', v_stale
    )
  );
  RETURN true;
END
$function$;

CREATE OR REPLACE FUNCTION aep.reconcile_external_operation(
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
    SELECT 1
    FROM aep.works AS work_row
    JOIN aep.executions AS execution_row
      ON execution_row.work_id = work_row.work_id
     AND execution_row.execution_id = v_receipt.execution_id
    WHERE work_row.work_id = v_receipt.work_id
      AND work_row.status = 'running'
      AND work_row.current_execution_id = v_receipt.execution_id
      AND work_row.fence_generation = v_receipt.execution_fence
      AND execution_row.status = 'running'
      AND execution_row.fence = v_receipt.execution_fence
  ) INTO v_stale;

  IF v_receipt.status = 'reconciled' THEN
    IF v_receipt.receipt_payload = p_observation THEN
      RETURN jsonb_build_object(
        'status','reconciled','retry_safe',false,
        'stale',v_receipt.stale_execution_detected,
        'external_id',v_receipt.external_id
      );
    END IF;
    RAISE EXCEPTION 'Reconciliation observation changed after completion'
      USING ERRCODE = '23505';
  END IF;

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
      jsonb_build_object(
        'authoritative_not_found', p_observation->>'authoritative' = 'true',
        'stale_execution', v_stale
      )
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
  IF v_receipt.external_id IS NOT NULL
     AND (v_receipt.external_id <> v_external_id
          OR v_receipt.external_object_type <> v_external_type) THEN
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
      jsonb_build_object('reason','provider returned a different external receipt identifier',
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

  IF v_receipt.status <> 'succeeded' THEN
    INSERT INTO aep.operation_receipt_events(
      operation_receipt_id, event_type, event_payload
    ) VALUES (
      p_operation_receipt_id, 'external_result_observed', p_observation
    );
  END IF;
  INSERT INTO aep.operation_receipt_events(
    operation_receipt_id, event_type, event_payload
  ) VALUES (
    p_operation_receipt_id, 'reconciled',
    jsonb_build_object('external_id',v_external_id,'revision',v_revision,'stale_execution',v_stale)
  );

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
      jsonb_build_object(
        'pr_number',v_delivery.pull_request_number,
        'merge_sha',v_merge_sha,
        'stale_execution',v_stale
      )
    );
  END IF;

  RETURN jsonb_build_object(
    'status','reconciled','retry_safe',false,'stale',v_stale,
    'external_id',v_external_id,'merge_sha',v_merge_sha
  );
END
$function$;

ALTER FUNCTION aep.record_external_operation_receipt(uuid,text,text,text,jsonb) OWNER TO aep_owner;
ALTER FUNCTION aep.reconcile_external_operation(uuid,jsonb) OWNER TO aep_owner;
REVOKE ALL ON FUNCTION aep.record_external_operation_receipt(uuid,text,text,text,jsonb),
  aep.reconcile_external_operation(uuid,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION aep.record_external_operation_receipt(uuid,text,text,text,jsonb),
  aep.reconcile_external_operation(uuid,jsonb) TO aep_runtime;

COMMIT;
