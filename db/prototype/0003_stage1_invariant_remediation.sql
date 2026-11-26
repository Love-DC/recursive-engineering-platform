-- Stage 1 remediation A: close database invariant gaps identified in PR #9 review.
-- This migration is additive; 0001 and 0002 remain unchanged.
-- Prototype-only PostgreSQL. These constraints are not claim/lease/fencing protocols.

BEGIN;

-- Canonical Work identity version 1 is intentionally conservative:
-- identity_kind and identity_key are exact caller-supplied strings, without
-- case folding or Unicode normalization. PostgreSQL POSIX whitespace may not
-- appear at either edge. Only version 1 is defined by this migration.
ALTER TABLE aep.works
  ADD CONSTRAINT works_identity_version_supported_ck
    CHECK (identity_version = 1),
  ADD CONSTRAINT works_identity_kind_canonical_ck
    CHECK (identity_kind !~ '(^[[:space:]]|[[:space:]]$)'),
  ADD CONSTRAINT works_identity_key_canonical_ck
    CHECK (identity_key !~ '(^[[:space:]]|[[:space:]]$)');

-- Provider and resource_type are lowercase ASCII identifiers. Host is a
-- lowercase DNS A-label name (no scheme, port, or trailing root dot).
-- stable_resource_id remains opaque and case-sensitive: providers own its
-- semantics. canonical_key is a checked projection of resource_type + ID,
-- not an independent identity that callers can vary to bypass physical uniqueness.
CREATE FUNCTION aep.is_canonical_resource_host(p_host text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
SET search_path = pg_catalog
AS $function$
  SELECT p_host IS NOT NULL
     AND p_host = lower(p_host)
     AND length(p_host) BETWEEN 1 AND 253
     AND NOT EXISTS (
       SELECT 1
       FROM unnest(string_to_array(p_host, '.')) AS part(label)
       WHERE length(part.label) NOT BETWEEN 1 AND 63
          OR part.label !~ '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'
     )
$function$;

ALTER FUNCTION aep.is_canonical_resource_host(text) OWNER TO aep_owner;
REVOKE ALL ON FUNCTION aep.is_canonical_resource_host(text) FROM PUBLIC, aep_runtime;

-- Drop the caller-supplied canonical-key uniqueness before backfilling the
-- derived projection. Otherwise two pre-migration keys that collapse to the
-- same derived key could block the repair before the physical tuple is checked.
-- Provider/host aliases are deliberately rejected rather than silently rewritten
-- because merging physical Resource rows requires an explicit reference migration.
ALTER TABLE aep.resources
  DROP CONSTRAINT resources_provider_host_canonical_key_key;

UPDATE aep.resources
SET canonical_key = resource_type || ':' || stable_resource_id;

ALTER TABLE aep.resources
  DROP CONSTRAINT resources_provider_host_resource_type_stable_resource_id_key,
  ADD CONSTRAINT resources_provider_canonical_ck
    CHECK (
      provider = lower(provider)
      AND provider ~ '^[a-z0-9][a-z0-9._-]{0,79}$'
    ),
  ADD CONSTRAINT resources_host_canonical_ck
    CHECK (aep.is_canonical_resource_host(host)),
  ADD CONSTRAINT resources_type_canonical_ck
    CHECK (
      resource_type = lower(resource_type)
      AND resource_type ~ '^[a-z0-9][a-z0-9._-]{0,79}$'
    ),
  ADD CONSTRAINT resources_canonical_key_matches_identity_ck
    CHECK (canonical_key = resource_type || ':' || stable_resource_id);

-- Explicit normalized physical identity. Case folding applies only to the
-- provider/host/type identifiers; stable_resource_id is deliberately untouched.
CREATE UNIQUE INDEX resources_normalized_physical_identity_uq
  ON aep.resources (lower(provider), lower(host), lower(resource_type), stable_resource_id);

-- Until path-overlap semantics exist, only whole-ref claims can be reserved or
-- active. Every repository_ref key is forced to '*', so callers cannot invent
-- another conflict_key to escape the whole-ref unique index.
ALTER TABLE aep.resource_claims
  ADD CONSTRAINT resource_claims_repository_ref_whole_key_ck
    CHECK (write_set_kind <> 'repository_ref' OR conflict_key = '*'),
  ADD CONSTRAINT resource_claims_active_requires_repository_ref_ck
    CHECK (status NOT IN ('reserved', 'active') OR write_set_kind = 'repository_ref');

-- WorkEvent.request_id, when present, must be the request that registered this
-- exact project/work pair. request_id's global PK alone is not sufficient.
ALTER TABLE aep.work_requests
  ADD CONSTRAINT work_requests_project_work_request_uq
    UNIQUE (project_id, work_id, request_id);

ALTER TABLE aep.work_events
  ADD CONSTRAINT work_events_project_work_request_fk
    FOREIGN KEY (project_id, work_id, request_id)
    REFERENCES aep.work_requests(project_id, work_id, request_id);

-- A nullable execution_id causes MATCH SIMPLE to skip the composite FK. Keep
-- that same-Work execution FK and add an independent nullable Work FK.
ALTER TABLE aep.operation_receipts
  ADD CONSTRAINT operation_receipts_work_exists_fk
    FOREIGN KEY (work_id)
    REFERENCES aep.works(work_id);

COMMIT;
