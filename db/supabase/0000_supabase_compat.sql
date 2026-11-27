-- Supabase compatibility bootstrap for the trusted single-Owner A0 pilot only.
-- Apply once to a clean, isolated, NON-PRODUCTION Supabase PostgreSQL 17 project
-- before applying db/prototype/0001_work_registry.sql through 0012.
-- Never apply this to the retired RAE project or a production database.

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'aep_owner') THEN
    CREATE ROLE aep_owner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'aep_runtime') THEN
    CREATE ROLE aep_runtime NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS;
  END IF;
END
$$;

-- Supabase's postgres connection must be able to SET ROLE for owner transfers
-- during installation and for explicit runtime-role validation. Do not grant
-- aep_runtime to anon, authenticated, or service_role.
GRANT aep_owner TO postgres;
GRANT aep_runtime TO postgres;

-- Supabase installs pgcrypto in the extensions schema. The prototype SQL uses
-- public.digest; keep pgcrypto in extensions and provide only the required
-- digest(bytea,text) compatibility function in public.
DO $$
BEGIN
  IF to_regprocedure('extensions.digest(bytea,text)') IS NULL THEN
    RAISE EXCEPTION
      'pgcrypto digest(bytea,text) is missing from schema extensions; enable pgcrypto there before continuing';
  END IF;
END
$$;

GRANT USAGE ON SCHEMA extensions TO aep_owner;
GRANT EXECUTE ON FUNCTION extensions.digest(bytea, text) TO aep_owner;

CREATE OR REPLACE FUNCTION public.digest(bytea, text)
RETURNS bytea
LANGUAGE sql
IMMUTABLE
STRICT
PARALLEL SAFE
SET search_path = pg_catalog
AS $function$
  SELECT extensions.digest($1, $2)
$function$;

REVOKE ALL ON FUNCTION public.digest(bytea, text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.digest(bytea, text) TO aep_owner;
