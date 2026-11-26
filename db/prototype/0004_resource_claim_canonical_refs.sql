-- Stage 1 follow-up: enforce provider-specific canonical repository refs.
-- GitHub repository branch claims use fully-qualified Git refs only. Other
-- providers must receive their own explicit canonical-ref contract before
-- repository_ref claims are enabled; no universal provider normalizer is used.
-- Prototype-only PostgreSQL. This is schema integrity, not a claim protocol.

BEGIN;

CREATE FUNCTION aep.is_canonical_github_branch_ref(p_resource_ref text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
SET search_path = pg_catalog
AS $function$
  SELECT p_resource_ref IS NOT NULL
     AND length(p_resource_ref) BETWEEN 12 AND 255
     AND left(p_resource_ref, 11) = 'refs/heads/'
     AND position('//' IN p_resource_ref) = 0
     AND position('..' IN p_resource_ref) = 0
     AND position('@{' IN p_resource_ref) = 0
     AND p_resource_ref !~ '[[:cntrl:]]'
     AND NOT EXISTS (
       SELECT 1
       FROM unnest(ARRAY[' ', '~', '^', ':', '?', '*', '[', chr(92)]) AS forbidden(character)
       WHERE strpos(p_resource_ref, forbidden.character) > 0
     )
     AND NOT EXISTS (
       SELECT 1
       FROM unnest(string_to_array(p_resource_ref, '/')) AS component(value)
       WHERE component.value = ''
          OR left(component.value, 1) = '.'
          OR right(component.value, 1) = '.'
          OR right(component.value, 5) = '.lock'
     )
$function$;

ALTER FUNCTION aep.is_canonical_github_branch_ref(text) OWNER TO aep_owner;
REVOKE ALL ON FUNCTION aep.is_canonical_github_branch_ref(text) FROM PUBLIC, aep_runtime;

-- The current prototype has a defined ref contract only for GitHub repositories.
-- Validate existing live reservations before enabling the guard. Lock both
-- identity tables so no writer can slip an unvalidated live claim between the
-- preflight and trigger installation. Inactive historical rows remain untouched.
LOCK TABLE aep.resources, aep.resource_claims IN SHARE ROW EXCLUSIVE MODE;

DO $preflight$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM aep.resource_claims AS claim
    JOIN aep.resources AS resource USING (resource_id)
    WHERE claim.status IN ('reserved', 'active')
      AND claim.write_set_kind = 'repository_ref'
      AND (
        resource.provider <> 'github'
        OR resource.resource_type <> 'repository'
        OR NOT aep.is_canonical_github_branch_ref(claim.resource_ref)
      )
  ) THEN
    RAISE EXCEPTION
      'resource_claims_github_branch_ref_canonical_ck: live repository_ref claims must use canonical GitHub refs before migration'
      USING ERRCODE = '23514',
            CONSTRAINT = 'resource_claims_github_branch_ref_canonical_ck';
  END IF;
END
$preflight$;

CREATE FUNCTION aep.enforce_resource_claim_canonical_ref()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, aep
AS $function$
DECLARE
  v_provider text;
  v_resource_type text;
BEGIN
  IF NEW.write_set_kind <> 'repository_ref' THEN
    RETURN NEW;
  END IF;

  SELECT resource.provider, resource.resource_type
    INTO v_provider, v_resource_type
  FROM aep.resources AS resource
  WHERE resource.resource_id = NEW.resource_id;

  -- Leave missing-resource handling to the declared foreign key.
  IF NOT FOUND THEN
    RETURN NEW;
  END IF;

  IF v_provider <> 'github' OR v_resource_type <> 'repository' THEN
    RAISE EXCEPTION
      'resource_claims_repository_ref_provider_supported_ck: repository_ref claims currently require provider=github and resource_type=repository'
      USING ERRCODE = '23514',
            CONSTRAINT = 'resource_claims_repository_ref_provider_supported_ck';
  END IF;

  IF NOT aep.is_canonical_github_branch_ref(NEW.resource_ref) THEN
    RAISE EXCEPTION
      'resource_claims_github_branch_ref_canonical_ck: use a valid fully-qualified refs/heads/<branch> name; shorthand and symbolic aliases are rejected'
      USING ERRCODE = '23514',
            CONSTRAINT = 'resource_claims_github_branch_ref_canonical_ck';
  END IF;

  RETURN NEW;
END
$function$;

ALTER FUNCTION aep.enforce_resource_claim_canonical_ref() OWNER TO aep_owner;
REVOKE ALL ON FUNCTION aep.enforce_resource_claim_canonical_ref() FROM PUBLIC, aep_runtime;

CREATE TRIGGER resource_claims_canonical_ref_guard
BEFORE INSERT OR UPDATE ON aep.resource_claims
FOR EACH ROW
EXECUTE FUNCTION aep.enforce_resource_claim_canonical_ref();

COMMIT;
