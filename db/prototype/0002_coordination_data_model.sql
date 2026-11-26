-- Stage 1B additive schema: physical resources, execution attempts, relations,
-- OwnerDecision provenance, evidence ledger, and external operation receipts.
-- Prototype-only PostgreSQL; see db/prototype/README.md for trust/deployment limits.

CREATE TABLE aep.owner_decisions (
  decision_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  scope_type text NOT NULL CHECK (scope_type IN ('platform','project','resource','work')),
  scope_key text NOT NULL CHECK (length(btrim(scope_key)) BETWEEN 1 AND 500),
  decision_key text NOT NULL CHECK (length(btrim(decision_key)) BETWEEN 1 AND 160),
  statement text NOT NULL CHECK (length(btrim(statement)) BETWEEN 1 AND 4000),
  decision_version integer NOT NULL CHECK (decision_version > 0),
  status text NOT NULL DEFAULT 'proposed'
    CHECK (status IN ('proposed','approved','rejected','revoked','superseded')),
  proposed_by_session_id uuid,
  approval_source_kind text,
  approval_source_ref text,
  approval_source_hash text,
  approver_principal text,
  approval_provenance jsonb NOT NULL DEFAULT '{}'::jsonb
    CHECK (jsonb_typeof(approval_provenance) = 'object'),
  approved_at timestamptz,
  supersedes_decision_id uuid REFERENCES aep.owner_decisions(decision_id),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CHECK (supersedes_decision_id IS NULL OR supersedes_decision_id <> decision_id),
  CHECK (
    status <> 'approved'
    OR (
      approval_source_kind = 'direct_owner_message'
      AND approval_source_ref IS NOT NULL
      AND length(btrim(approval_source_ref)) > 0
      AND approver_principal IS NOT NULL
      AND length(btrim(approver_principal)) > 0
      AND approved_at IS NOT NULL
      AND approval_provenance ? 'direct_owner_confirmation'
      AND approval_provenance->>'direct_owner_confirmation' = 'true'
    )
  ),
  UNIQUE (scope_type, scope_key, decision_key, decision_version)
);

CREATE UNIQUE INDEX owner_decisions_one_current_approval_uq
  ON aep.owner_decisions(scope_type, scope_key, decision_key)
  WHERE status = 'approved';

CREATE INDEX owner_decisions_scope_status_idx
  ON aep.owner_decisions(scope_type, scope_key, status, decision_key);

CREATE TABLE aep.resources (
  resource_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider text NOT NULL CHECK (length(btrim(provider)) BETWEEN 1 AND 80),
  host text NOT NULL CHECK (length(btrim(host)) BETWEEN 1 AND 255),
  resource_type text NOT NULL CHECK (length(btrim(resource_type)) BETWEEN 1 AND 80),
  stable_resource_id text NOT NULL CHECK (length(btrim(stable_resource_id)) BETWEEN 1 AND 255),
  canonical_key text NOT NULL CHECK (length(btrim(canonical_key)) BETWEEN 1 AND 500),
  display_name text,
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','archived')),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE (provider, host, resource_type, stable_resource_id),
  UNIQUE (provider, host, canonical_key)
);

CREATE TABLE aep.project_resources (
  project_id uuid NOT NULL REFERENCES aep.projects(project_id),
  resource_id uuid NOT NULL REFERENCES aep.resources(resource_id),
  access_mode text NOT NULL CHECK (access_mode IN ('read','write','read_write')),
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','revoked')),
  grant_version integer NOT NULL DEFAULT 1 CHECK (grant_version > 0),
  grant_decision_id uuid REFERENCES aep.owner_decisions(decision_id),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  revoked_at timestamptz,
  PRIMARY KEY (project_id, resource_id),
  CHECK (
    (status = 'active' AND revoked_at IS NULL)
    OR (status = 'revoked' AND revoked_at IS NOT NULL)
  ),
  CHECK (
    (access_mode = 'read' AND grant_decision_id IS NULL)
    OR (access_mode IN ('write','read_write') AND grant_decision_id IS NOT NULL)
  )
);

CREATE INDEX project_resources_resource_idx ON aep.project_resources(resource_id, status);

CREATE TABLE aep.dependency_graphs (
  graph_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  graph_scope text NOT NULL CHECK (graph_scope IN ('project','shared')),
  owner_project_id uuid NOT NULL REFERENCES aep.projects(project_id),
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','archived')),
  graph_version bigint NOT NULL DEFAULT 1 CHECK (graph_version > 0),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE aep.dependency_graph_members (
  graph_id uuid NOT NULL REFERENCES aep.dependency_graphs(graph_id),
  project_id uuid NOT NULL REFERENCES aep.projects(project_id),
  access_mode text NOT NULL CHECK (access_mode IN ('owner','read','write')),
  grant_decision_id uuid REFERENCES aep.owner_decisions(decision_id),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (graph_id, project_id),
  CHECK (
    (access_mode = 'owner' AND grant_decision_id IS NULL)
    OR (access_mode = 'read')
    OR (access_mode = 'write' AND grant_decision_id IS NOT NULL)
  )
);

CREATE INDEX dependency_graph_members_project_idx
  ON aep.dependency_graph_members(project_id, graph_id);

CREATE UNIQUE INDEX dependency_graph_one_owner_uq
  ON aep.dependency_graph_members(graph_id)
  WHERE access_mode = 'owner';

CREATE TABLE aep.executions (
  execution_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  work_id uuid NOT NULL REFERENCES aep.works(work_id),
  session_id uuid NOT NULL,
  attempt_no integer NOT NULL CHECK (attempt_no > 0),
  status text NOT NULL DEFAULT 'claimed'
    CHECK (status IN ('claimed','running','succeeded','failed','cancelled','superseded','expired','interrupted')),
  lease_until timestamptz,
  fence bigint NOT NULL CHECK (fence > 0),
  base_sha text,
  head_sha text,
  delivery_branch text,
  pull_request_number bigint CHECK (pull_request_number IS NULL OR pull_request_number > 0),
  result jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(result) = 'object'),
  started_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  finished_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE (work_id, attempt_no),
  UNIQUE (work_id, fence),
  UNIQUE (work_id, execution_id),
  CHECK (
    (status IN ('claimed','running') AND finished_at IS NULL)
    OR status NOT IN ('claimed','running')
  )
);

CREATE UNIQUE INDEX executions_one_active_per_work_uq
  ON aep.executions(work_id)
  WHERE status IN ('claimed','running');

CREATE INDEX executions_work_created_idx ON aep.executions(work_id, created_at DESC);
CREATE INDEX executions_session_idx ON aep.executions(session_id, created_at DESC);

ALTER TABLE aep.works
  ADD COLUMN current_execution_id uuid,
  ADD COLUMN fence_generation bigint NOT NULL DEFAULT 0 CHECK (fence_generation >= 0),
  ADD COLUMN owner_decision_id uuid REFERENCES aep.owner_decisions(decision_id),
  ADD CONSTRAINT works_project_work_uq UNIQUE (project_id, work_id);

ALTER TABLE aep.work_requests
  ADD CONSTRAINT work_requests_project_work_fk
  FOREIGN KEY (project_id, work_id)
  REFERENCES aep.works(project_id, work_id);

ALTER TABLE aep.work_events
  ADD CONSTRAINT work_events_project_work_fk
  FOREIGN KEY (project_id, work_id)
  REFERENCES aep.works(project_id, work_id);

ALTER TABLE aep.works
  ADD CONSTRAINT works_current_execution_same_work_fk
  FOREIGN KEY (work_id, current_execution_id)
  REFERENCES aep.executions(work_id, execution_id)
  DEFERRABLE INITIALLY DEFERRED;

CREATE TABLE aep.resource_claims (
  resource_claim_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id uuid NOT NULL,
  resource_id uuid NOT NULL,
  work_id uuid NOT NULL,
  execution_id uuid NOT NULL,
  resource_ref text NOT NULL CHECK (length(btrim(resource_ref)) BETWEEN 1 AND 255),
  write_set_kind text NOT NULL CHECK (write_set_kind IN ('repository_ref','path_set')),
  conflict_key text NOT NULL CHECK (length(btrim(conflict_key)) BETWEEN 1 AND 500),
  normalized_write_set jsonb NOT NULL DEFAULT '[]'::jsonb
    CHECK (jsonb_typeof(normalized_write_set) = 'array'),
  status text NOT NULL DEFAULT 'reserved'
    CHECK (status IN ('reserved','active','released','expired','superseded')),
  lease_until timestamptz,
  fence bigint NOT NULL CHECK (fence > 0),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  released_at timestamptz,
  FOREIGN KEY (project_id, resource_id)
    REFERENCES aep.project_resources(project_id, resource_id),
  FOREIGN KEY (project_id, work_id)
    REFERENCES aep.works(project_id, work_id),
  FOREIGN KEY (work_id, execution_id)
    REFERENCES aep.executions(work_id, execution_id),
  CHECK (
    (status IN ('reserved','active') AND released_at IS NULL)
    OR (status IN ('released','expired','superseded') AND released_at IS NOT NULL)
  )
);

-- The MVP conflict_key for write_set_kind=repository_ref is '*', conservatively
-- excluding the whole repository/ref. Path overlap semantics are a later protocol.
CREATE UNIQUE INDEX resource_claims_active_exact_conflict_uq
  ON aep.resource_claims(resource_id, resource_ref, conflict_key)
  WHERE status IN ('reserved','active');

CREATE INDEX resource_claims_execution_idx ON aep.resource_claims(execution_id, status);

CREATE TABLE aep.work_relations (
  relation_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_work_id uuid NOT NULL REFERENCES aep.works(work_id),
  target_work_id uuid NOT NULL REFERENCES aep.works(work_id),
  relation_type text NOT NULL CHECK (relation_type IN ('parent_child','depends_on','possible_duplicate')),
  required boolean,
  dependency_graph_id uuid REFERENCES aep.dependency_graphs(graph_id),
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','removed')),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  removed_at timestamptz,
  CHECK (source_work_id <> target_work_id),
  CHECK (
    (relation_type = 'parent_child' AND required IS NOT NULL AND dependency_graph_id IS NULL)
    OR (relation_type = 'depends_on' AND required IS NULL AND dependency_graph_id IS NOT NULL)
    OR (relation_type = 'possible_duplicate' AND required IS NULL AND dependency_graph_id IS NULL
        AND source_work_id < target_work_id)
  ),
  CHECK (
    (status = 'active' AND removed_at IS NULL)
    OR (status = 'removed' AND removed_at IS NOT NULL)
  )
);

CREATE UNIQUE INDEX work_relations_active_exact_uq
  ON aep.work_relations(source_work_id, target_work_id, relation_type)
  WHERE status = 'active';

CREATE INDEX work_relations_source_idx ON aep.work_relations(source_work_id, relation_type, status);
CREATE INDEX work_relations_target_idx ON aep.work_relations(target_work_id, relation_type, status);

CREATE TABLE aep.evidence (
  evidence_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id uuid NOT NULL REFERENCES aep.projects(project_id),
  work_id uuid,
  execution_id uuid,
  evidence_type text NOT NULL CHECK (length(btrim(evidence_type)) BETWEEN 1 AND 100),
  source_ref text NOT NULL CHECK (length(btrim(source_ref)) BETWEEN 1 AND 2000),
  source_revision text,
  content_sha256 text CHECK (content_sha256 IS NULL OR content_sha256 ~ '^[0-9a-f]{64}$'),
  observed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  valid_at timestamptz,
  provenance jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(provenance) = 'object'),
  payload jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(payload) = 'object'),
  FOREIGN KEY (project_id, work_id) REFERENCES aep.works(project_id, work_id),
  FOREIGN KEY (work_id, execution_id) REFERENCES aep.executions(work_id, execution_id),
  CHECK (execution_id IS NULL OR work_id IS NOT NULL)
);

CREATE INDEX evidence_project_observed_idx ON aep.evidence(project_id, observed_at DESC);
CREATE INDEX evidence_work_observed_idx ON aep.evidence(work_id, observed_at DESC);

CREATE TABLE aep.operation_receipts (
  operation_receipt_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  work_id uuid,
  execution_id uuid,
  provider text NOT NULL CHECK (length(btrim(provider)) BETWEEN 1 AND 80),
  operation_key text NOT NULL CHECK (length(btrim(operation_key)) BETWEEN 1 AND 255),
  operation_type text NOT NULL CHECK (length(btrim(operation_type)) BETWEEN 1 AND 120),
  target_resource_id uuid REFERENCES aep.resources(resource_id),
  target_ref text,
  request_payload_sha256 text NOT NULL CHECK (request_payload_sha256 ~ '^[0-9a-f]{64}$'),
  intent_payload jsonb NOT NULL CHECK (jsonb_typeof(intent_payload) = 'object'),
  status text NOT NULL DEFAULT 'intent_created'
    CHECK (status IN ('intent_created','submitted','succeeded','failed','uncertain','reconciling','reconciled','manual_review_required')),
  external_object_type text,
  external_id text,
  result_revision text,
  receipt_payload jsonb CHECK (receipt_payload IS NULL OR jsonb_typeof(receipt_payload) = 'object'),
  reconciliation_status text NOT NULL DEFAULT 'not_started'
    CHECK (reconciliation_status IN ('not_started','pending','reconciled','manual_review_required')),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  reconciled_at timestamptz,
  FOREIGN KEY (work_id, execution_id) REFERENCES aep.executions(work_id, execution_id),
  CHECK (execution_id IS NULL OR work_id IS NOT NULL),
  UNIQUE (provider, operation_key),
  CHECK (status <> 'reconciled' OR (reconciliation_status = 'reconciled' AND reconciled_at IS NOT NULL)),
  CHECK (status <> 'succeeded' OR receipt_payload IS NOT NULL)
);

CREATE INDEX operation_receipts_work_created_idx
  ON aep.operation_receipts(work_id, created_at DESC);

CREATE TABLE aep.operation_receipt_events (
  receipt_event_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  operation_receipt_id uuid NOT NULL REFERENCES aep.operation_receipts(operation_receipt_id),
  event_type text NOT NULL
    CHECK (event_type IN ('intent_created','external_result_observed','reconciliation_started','reconciled','reconciliation_failed','manual_review_required')),
  observed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  event_payload jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(event_payload) = 'object')
);

CREATE INDEX operation_receipt_events_created_idx
  ON aep.operation_receipt_events(operation_receipt_id, observed_at);

ALTER TABLE aep.work_events
  ADD COLUMN execution_id uuid,
  ADD COLUMN actor_key text,
  ADD CONSTRAINT work_events_execution_same_work_fk
    FOREIGN KEY (work_id, execution_id)
    REFERENCES aep.executions(work_id, execution_id);

-- Reuse the append-only mutation rejection function for immutable evidence/event ledgers.
CREATE TRIGGER evidence_append_only
BEFORE UPDATE OR DELETE ON aep.evidence
FOR EACH ROW EXECUTE FUNCTION aep.reject_work_event_mutation();

CREATE TRIGGER operation_receipt_events_append_only
BEFORE UPDATE OR DELETE ON aep.operation_receipt_events
FOR EACH ROW EXECUTE FUNCTION aep.reject_work_event_mutation();

ALTER TABLE aep.owner_decisions OWNER TO aep_owner;
ALTER TABLE aep.resources OWNER TO aep_owner;
ALTER TABLE aep.project_resources OWNER TO aep_owner;
ALTER TABLE aep.dependency_graphs OWNER TO aep_owner;
ALTER TABLE aep.dependency_graph_members OWNER TO aep_owner;
ALTER TABLE aep.executions OWNER TO aep_owner;
ALTER TABLE aep.resource_claims OWNER TO aep_owner;
ALTER TABLE aep.work_relations OWNER TO aep_owner;
ALTER TABLE aep.evidence OWNER TO aep_owner;
ALTER TABLE aep.operation_receipts OWNER TO aep_owner;
ALTER TABLE aep.operation_receipt_events OWNER TO aep_owner;

DO $
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'owner_decisions','resources','project_resources','dependency_graphs',
    'dependency_graph_members','executions','resource_claims','work_relations',
    'evidence','operation_receipts','operation_receipt_events'
  ] LOOP
    EXECUTE format('ALTER TABLE aep.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE aep.%I FORCE ROW LEVEL SECURITY', t);
    EXECUTE format(
      'CREATE POLICY owner_full_access ON aep.%I FOR ALL TO aep_owner USING (true) WITH CHECK (true)',
      t
    );
  END LOOP;
END $$;

REVOKE ALL ON ALL TABLES IN SCHEMA aep FROM PUBLIC, aep_runtime;
