-- Prototype-only PostgreSQL migration. Not a production Supabase migration.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='aep_owner') THEN
    CREATE ROLE aep_owner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='aep_runtime') THEN
    CREATE ROLE aep_runtime NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS;
  END IF;
END $$;

CREATE SCHEMA aep AUTHORIZATION aep_owner;
REVOKE ALL ON SCHEMA aep FROM PUBLIC;
GRANT USAGE ON SCHEMA aep TO aep_runtime;

CREATE TABLE aep.projects (
  project_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_key text NOT NULL UNIQUE CHECK (length(btrim(project_key)) BETWEEN 1 AND 120),
  name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 200),
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','paused','archived')),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE aep.works (
  work_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id uuid NOT NULL REFERENCES aep.projects(project_id),
  identity_kind text NOT NULL CHECK (length(btrim(identity_kind)) BETWEEN 1 AND 80),
  identity_key text NOT NULL CHECK (length(btrim(identity_key)) BETWEEN 1 AND 500),
  identity_version integer NOT NULL CHECK (identity_version > 0),
  work_type text NOT NULL CHECK (work_type IN ('initiative','discovery','implementation','review','fix')),
  status text NOT NULL DEFAULT 'proposed'
    CHECK (status IN ('proposed','ready','running','blocked','in_review','delivered','accepted','completed','failed','cancelled','rejected')),
  title text NOT NULL CHECK (length(btrim(title)) BETWEEN 1 AND 500),
  acceptance jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(acceptance)='object'),
  owner_decision_ref text,
  version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE UNIQUE INDEX works_active_identity_uq
  ON aep.works(project_id,identity_kind,identity_key,identity_version)
  WHERE status NOT IN ('completed','cancelled','rejected');
CREATE INDEX works_project_status_idx ON aep.works(project_id,status,created_at);

CREATE TABLE aep.work_requests (
  request_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id uuid NOT NULL REFERENCES aep.projects(project_id),
  operation text NOT NULL CHECK (operation='register_work'),
  idempotency_key text NOT NULL CHECK (length(btrim(idempotency_key)) BETWEEN 1 AND 200),
  request_payload jsonb NOT NULL CHECK (jsonb_typeof(request_payload)='object'),
  work_id uuid REFERENCES aep.works(work_id),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE(project_id,operation,idempotency_key)
);

CREATE TABLE aep.external_refs (
  external_ref_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider text NOT NULL,
  host text NOT NULL,
  resource_key text NOT NULL,
  object_type text NOT NULL,
  external_id text NOT NULL,
  work_id uuid NOT NULL REFERENCES aep.works(work_id),
  observed_revision text,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CHECK (length(btrim(provider)) BETWEEN 1 AND 80),
  CHECK (length(btrim(host)) BETWEEN 1 AND 255),
  CHECK (length(btrim(resource_key)) BETWEEN 1 AND 255),
  CHECK (length(btrim(object_type)) BETWEEN 1 AND 80),
  CHECK (length(btrim(external_id)) BETWEEN 1 AND 255),
  UNIQUE(provider,host,resource_key,object_type,external_id)
);

CREATE TABLE aep.work_events (
  event_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id uuid NOT NULL REFERENCES aep.projects(project_id),
  work_id uuid NOT NULL REFERENCES aep.works(work_id),
  request_id uuid REFERENCES aep.work_requests(request_id),
  event_type text NOT NULL CHECK (event_type IN ('work_registered','work_identity_linked','request_replayed')),
  session_id uuid NOT NULL,
  event_payload jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(event_payload)='object'),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX work_events_work_created_idx ON aep.work_events(work_id,created_at);

CREATE FUNCTION aep.reject_work_event_mutation()
RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,aep
AS $$
BEGIN
  RAISE EXCEPTION 'work_events is append-only; % is forbidden',TG_OP USING ERRCODE='55000';
END $$;
CREATE TRIGGER work_events_append_only
BEFORE UPDATE OR DELETE ON aep.work_events
FOR EACH ROW EXECUTE FUNCTION aep.reject_work_event_mutation();

CREATE FUNCTION aep.register_work(
  p_project_id uuid,
  p_request_key text,
  p_session_id uuid,
  p_identity_kind text,
  p_identity_key text,
  p_identity_version integer,
  p_work_type text,
  p_title text,
  p_acceptance jsonb DEFAULT '{}'::jsonb,
  p_external_ref jsonb DEFAULT NULL
)
RETURNS TABLE(work_id uuid,outcome text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,aep
AS $$
DECLARE
  v_payload jsonb;
  v_request aep.work_requests%ROWTYPE;
  v_work_id uuid;
  v_external_work_id uuid;
  v_created boolean := false;
  v_provider text;
  v_host text;
  v_resource_key text;
  v_object_type text;
  v_external_id text;
  v_revision text;
BEGIN
  IF p_project_id IS NULL OR p_session_id IS NULL THEN
    RAISE EXCEPTION 'project_id and session_id are required' USING ERRCODE='22004';
  END IF;
  IF p_request_key IS NULL OR length(btrim(p_request_key)) NOT BETWEEN 1 AND 200 THEN
    RAISE EXCEPTION 'request key must contain 1..200 characters' USING ERRCODE='22023';
  END IF;
  IF p_identity_kind IS NULL OR length(btrim(p_identity_kind)) NOT BETWEEN 1 AND 80
     OR p_identity_key IS NULL OR length(btrim(p_identity_key)) NOT BETWEEN 1 AND 500
     OR p_identity_version IS NULL OR p_identity_version < 1 THEN
    RAISE EXCEPTION 'canonical identity is invalid' USING ERRCODE='22023';
  END IF;
  IF p_work_type IS NULL OR p_work_type NOT IN ('initiative','discovery','implementation','review','fix') THEN
    RAISE EXCEPTION 'unsupported work_type' USING ERRCODE='22023';
  END IF;
  IF p_title IS NULL OR length(btrim(p_title)) NOT BETWEEN 1 AND 500 THEN
    RAISE EXCEPTION 'title must contain 1..500 characters' USING ERRCODE='22023';
  END IF;
  IF p_external_ref IS NOT NULL AND jsonb_typeof(p_external_ref)<>'object' THEN
    RAISE EXCEPTION 'external_ref must be a JSON object' USING ERRCODE='22023';
  END IF;

  PERFORM 1 FROM aep.projects p
  WHERE p.project_id=p_project_id AND p.status='active';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'project does not exist or is not active' USING ERRCODE='22023';
  END IF;

  -- session_id is provenance only: it must not prevent retry from a fresh session.
  v_payload := jsonb_build_object(
    'project_id',p_project_id,
    'identity_kind',p_identity_kind,
    'identity_key',p_identity_key,
    'identity_version',p_identity_version,
    'work_type',p_work_type,
    'title',p_title,
    'acceptance',COALESCE(p_acceptance,'{}'::jsonb),
    'external_ref',p_external_ref
  );

  -- The unique request row serializes same-key callers. The row is completed in this
  -- transaction; a null work_id is never committed by this function.
  INSERT INTO aep.work_requests(project_id,operation,idempotency_key,request_payload)
  VALUES(p_project_id,'register_work',p_request_key,v_payload)
  ON CONFLICT(project_id,operation,idempotency_key) DO NOTHING;

  SELECT r.* INTO v_request
  FROM aep.work_requests r
  WHERE r.project_id=p_project_id AND r.operation='register_work'
    AND r.idempotency_key=p_request_key
  FOR UPDATE;

  IF v_request.request_payload IS DISTINCT FROM v_payload THEN
    RAISE EXCEPTION 'idempotency key reused with different payload' USING ERRCODE='22000';
  END IF;

  IF v_request.work_id IS NOT NULL THEN
    INSERT INTO aep.work_events(project_id,work_id,request_id,event_type,session_id,event_payload)
    VALUES(p_project_id,v_request.work_id,v_request.request_id,'request_replayed',p_session_id,
           jsonb_build_object('request_key',p_request_key));
    RETURN QUERY SELECT v_request.work_id,'replayed'::text;
    RETURN;
  END IF;

  INSERT INTO aep.works(project_id,identity_kind,identity_key,identity_version,work_type,title,acceptance)
  VALUES(p_project_id,p_identity_kind,p_identity_key,p_identity_version,p_work_type,p_title,COALESCE(p_acceptance,'{}'::jsonb))
  ON CONFLICT(project_id,identity_kind,identity_key,identity_version)
    WHERE status NOT IN ('completed','cancelled','rejected')
  DO NOTHING
  RETURNING aep.works.work_id INTO v_work_id;

  IF v_work_id IS NULL THEN
    SELECT w.work_id INTO v_work_id
    FROM aep.works w
    WHERE w.project_id=p_project_id AND w.identity_kind=p_identity_kind
      AND w.identity_key=p_identity_key AND w.identity_version=p_identity_version
      AND w.status NOT IN ('completed','cancelled','rejected')
    FOR KEY SHARE;
    IF v_work_id IS NULL THEN
      RAISE EXCEPTION 'canonical identity conflict could not be reconciled' USING ERRCODE='40001';
    END IF;
  ELSE
    v_created := true;
  END IF;

  IF p_external_ref IS NOT NULL THEN
    v_provider := NULLIF(btrim(p_external_ref->>'provider'),'');
    v_host := NULLIF(btrim(p_external_ref->>'host'),'');
    v_resource_key := NULLIF(btrim(p_external_ref->>'resource_key'),'');
    v_object_type := NULLIF(btrim(p_external_ref->>'object_type'),'');
    v_external_id := NULLIF(btrim(p_external_ref->>'external_id'),'');
    v_revision := NULLIF(btrim(p_external_ref->>'observed_revision'),'');
    IF v_provider IS NULL OR v_host IS NULL OR v_resource_key IS NULL
       OR v_object_type IS NULL OR v_external_id IS NULL THEN
      RAISE EXCEPTION 'external_ref requires provider, host, resource_key, object_type, and external_id'
        USING ERRCODE='22023';
    END IF;

    INSERT INTO aep.external_refs(provider,host,resource_key,object_type,external_id,work_id,observed_revision)
    VALUES(v_provider,v_host,v_resource_key,v_object_type,v_external_id,v_work_id,v_revision)
    ON CONFLICT(provider,host,resource_key,object_type,external_id) DO NOTHING;

    SELECT er.work_id INTO v_external_work_id
    FROM aep.external_refs er
    WHERE er.provider=v_provider AND er.host=v_host AND er.resource_key=v_resource_key
      AND er.object_type=v_object_type AND er.external_id=v_external_id
    FOR KEY SHARE;

    IF v_external_work_id IS DISTINCT FROM v_work_id THEN
      RAISE EXCEPTION 'external reference is already linked to a different canonical work'
        USING ERRCODE='23505';
    END IF;
  END IF;

  UPDATE aep.work_requests SET work_id=v_work_id WHERE request_id=v_request.request_id;
  INSERT INTO aep.work_events(project_id,work_id,request_id,event_type,session_id,event_payload)
  VALUES(
    p_project_id,v_work_id,v_request.request_id,
    CASE WHEN v_created THEN 'work_registered' ELSE 'work_identity_linked' END,
    p_session_id,
    jsonb_build_object('request_key',p_request_key,'identity_kind',p_identity_kind,'identity_version',p_identity_version)
  );

  RETURN QUERY SELECT v_work_id,CASE WHEN v_created THEN 'created' ELSE 'linked' END::text;
END $$;

ALTER TABLE aep.projects OWNER TO aep_owner;
ALTER TABLE aep.works OWNER TO aep_owner;
ALTER TABLE aep.work_requests OWNER TO aep_owner;
ALTER TABLE aep.external_refs OWNER TO aep_owner;
ALTER TABLE aep.work_events OWNER TO aep_owner;
ALTER FUNCTION aep.reject_work_event_mutation() OWNER TO aep_owner;
ALTER FUNCTION aep.register_work(uuid,text,uuid,text,text,integer,text,text,jsonb,jsonb) OWNER TO aep_owner;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['projects','works','work_requests','external_refs','work_events'] LOOP
    EXECUTE format('ALTER TABLE aep.%I ENABLE ROW LEVEL SECURITY',t);
    EXECUTE format('ALTER TABLE aep.%I FORCE ROW LEVEL SECURITY',t);
    EXECUTE format('CREATE POLICY owner_full_access ON aep.%I FOR ALL TO aep_owner USING (true) WITH CHECK (true)',t);
  END LOOP;
END $$;

REVOKE ALL ON ALL TABLES IN SCHEMA aep FROM PUBLIC,aep_runtime;
REVOKE ALL ON FUNCTION aep.reject_work_event_mutation() FROM PUBLIC;
REVOKE ALL ON FUNCTION aep.register_work(uuid,text,uuid,text,text,integer,text,text,jsonb,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION aep.register_work(uuid,text,uuid,text,text,integer,text,text,jsonb,jsonb) TO aep_runtime;
