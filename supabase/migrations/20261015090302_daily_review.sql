-- Daily control in the isolated Tid project. All access through authenticated admin services.
CREATE TABLE public.daily_review_locks (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), organization_id uuid NOT NULL REFERENCES public.organizations(id), work_date date NOT NULL,
 revision int NOT NULL, snapshot jsonb NOT NULL, locked_by uuid NOT NULL REFERENCES auth.users(id), locked_at timestamptz NOT NULL DEFAULT now(),
 superseded_at timestamptz, reopened_by uuid REFERENCES auth.users(id), reopen_reason text, UNIQUE(organization_id,work_date,revision)
);
CREATE UNIQUE INDEX daily_review_active ON public.daily_review_locks(organization_id,work_date) WHERE superseded_at IS NULL;
CREATE TABLE public.daily_review_notes (
 entry_id uuid PRIMARY KEY REFERENCES public.time_entries(id) ON DELETE CASCADE, organization_id uuid NOT NULL REFERENCES public.organizations(id), note text NOT NULL
);
CREATE TABLE public.daily_review_transfers (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), organization_id uuid NOT NULL REFERENCES public.organizations(id), work_date date NOT NULL, client_id uuid NOT NULL,
 lock_id uuid NOT NULL REFERENCES public.daily_review_locks(id), status text NOT NULL CHECK(status IN ('pending','transferred','failed')),
 report_id text, message text, updated_at timestamptz NOT NULL DEFAULT now(), UNIQUE(organization_id,work_date,client_id)
);
DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['daily_review_locks','daily_review_notes','daily_review_transfers'] LOOP
  EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',t);
  EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC,anon,authenticated',t);
  EXECUTE format('GRANT ALL ON public.%I TO service_role',t);
  EXECUTE format('CREATE POLICY "Daily control service only" ON public.%I TO authenticated USING(false) WITH CHECK(false)',t);
 END LOOP;
END $$;
CREATE TRIGGER immutable_daily_snapshot BEFORE UPDATE OR DELETE ON public.daily_review_locks FOR EACH ROW EXECUTE FUNCTION public.guard_weekly_snapshots();

CREATE FUNCTION public.daily_review_data(p_org uuid,p_day date) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE result jsonb;
BEGIN
 SELECT jsonb_build_object(
 'entries',coalesce((SELECT jsonb_agg(to_jsonb(t)||jsonb_build_object('allocation_note',coalesce(n.note,'')) ORDER BY t.started_at,t.id) FROM public.time_entries t LEFT JOIN public.daily_review_notes n ON n.entry_id=t.id WHERE t.organization_id=p_org AND (t.started_at AT TIME ZONE 'Europe/Oslo')::date=p_day),'[]'),
 'adjustments',coalesce((SELECT jsonb_agg(to_jsonb(a) ORDER BY a.id) FROM public.payroll_adjustments a WHERE a.organization_id=p_org AND a.work_date=p_day),'[]'),
 'allocations',coalesce((SELECT jsonb_agg(to_jsonb(a) ORDER BY a.entry_id,a.started_at,a.id) FROM public.transport_allocations a JOIN public.time_entries t ON t.id=a.entry_id WHERE t.organization_id=p_org AND (t.started_at AT TIME ZONE 'Europe/Oslo')::date=p_day),'[]')
 ) INTO result;
 RETURN result||jsonb_build_object('fingerprint',md5(result::text));
END $$;
CREATE FUNCTION public.daily_review_state(p_org uuid,p_day date) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE data jsonb; l public.daily_review_locks%ROWTYPE;
BEGIN
 SELECT * INTO l FROM public.daily_review_locks WHERE organization_id=p_org AND work_date=p_day AND superseded_at IS NULL;
 data:=public.daily_review_data(p_org,p_day);
 RETURN coalesce(l.snapshot,data)||jsonb_build_object('fingerprint',md5((data||jsonb_build_object('lock_id',l.id))::text),'work_date',p_day,
 'locked',l.id IS NOT NULL,'lock_id',l.id,'revision',l.revision,'locked_at',l.locked_at,
 'can_lock',p_day<(now() AT TIME ZONE 'Europe/Oslo')::date,
 'employees',coalesce((SELECT jsonb_agg(jsonb_build_object('id',id,'portal_employee_id',portal_employee_id,'full_name',full_name,'active',active) ORDER BY full_name,id) FROM public.employees WHERE organization_id=p_org AND NOT portal_actor_only),'[]'),
 'transfers',coalesce((SELECT jsonb_agg(to_jsonb(t)||jsonb_build_object('stale',l.id IS NULL OR l.id<>t.lock_id) ORDER BY client_id) FROM public.daily_review_transfers t WHERE organization_id=p_org AND work_date=p_day),'[]'),
 'history',coalesce((SELECT jsonb_agg(jsonb_build_object('revision',revision,'locked_at',locked_at,'superseded_at',superseded_at,'reopen_reason',reopen_reason) ORDER BY revision DESC) FROM public.daily_review_locks WHERE organization_id=p_org AND work_date=p_day),'[]'));
END $$;

CREATE FUNCTION public.guard_daily_changes() RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE r jsonb; d date; org uuid;
BEGIN
 FOREACH r IN ARRAY ARRAY[CASE WHEN TG_OP<>'INSERT' THEN to_jsonb(OLD) END,CASE WHEN TG_OP<>'DELETE' THEN to_jsonb(NEW) END] LOOP
  IF r IS NULL THEN CONTINUE; END IF;
  org:=(r->>'organization_id')::uuid;
  IF TG_TABLE_NAME='time_entries' THEN d:=((r->>'started_at')::timestamptz AT TIME ZONE 'Europe/Oslo')::date;
  ELSIF TG_TABLE_NAME='payroll_adjustments' THEN d:=(r->>'work_date')::date;
  ELSE SELECT (started_at AT TIME ZONE 'Europe/Oslo')::date INTO d FROM public.time_entries WHERE id=(r->>'entry_id')::uuid AND organization_id=org; END IF;
  IF EXISTS(SELECT 1 FROM public.daily_review_locks WHERE organization_id=org AND work_date=d AND superseded_at IS NULL) THEN RAISE EXCEPTION 'Dagen er låst. Åpne dagen i Dagskontroll før du endrer timer eller fordeling.'; END IF;
 END LOOP;
 IF TG_OP='DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
END $$;
CREATE TRIGGER ab_daily_guard BEFORE INSERT OR UPDATE OR DELETE ON public.time_entries FOR EACH ROW EXECUTE FUNCTION public.guard_daily_changes();
CREATE TRIGGER ab_daily_guard BEFORE INSERT OR UPDATE OR DELETE ON public.payroll_adjustments FOR EACH ROW EXECUTE FUNCTION public.guard_daily_changes();
CREATE TRIGGER daily_allocation_guard BEFORE INSERT OR UPDATE OR DELETE ON public.transport_allocations FOR EACH ROW EXECUTE FUNCTION public.guard_daily_changes();
CREATE TRIGGER daily_note_guard BEFORE INSERT OR UPDATE OR DELETE ON public.daily_review_notes FOR EACH ROW EXECUTE FUNCTION public.guard_daily_changes();

CREATE FUNCTION public.daily_review(p_org uuid,p_actor uuid,p_day date,p_action text,p_body jsonb DEFAULT '{}') RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE state jsonb; row_input jsonb; e public.time_entries%ROWTYPE; a jsonb; rows jsonb; start_at timestamptz; end_at timestamptz; part_a timestamptz; part_b timestamptz;
 previous_end timestamptz; allocated interval; note text; reason text; w date; rev int; lock_id uuid; emp uuid; person jsonb; item jsonb;
 transfer public.daily_review_transfers%ROWTYPE;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.employees WHERE organization_id=p_org AND auth_user_id=p_actor AND active AND role='admin') THEN RAISE EXCEPTION 'Kun administrator har tilgang.'; END IF;
 IF p_day IS NULL OR p_day<date '2000-01-01' OR p_day>date '2100-01-01' THEN RAISE EXCEPTION 'Velg gyldig dato.'; END IF;
 IF p_action='load' THEN RETURN public.daily_review_state(p_org,p_day); END IF;
 IF p_action NOT IN ('save','lock','reopen','begin_transfer','finish_transfer','fail_transfer') THEN RAISE EXCEPTION 'Ukjent handling.'; END IF;
 -- Same lock order as weekly review; closes the race with all time-entry writers.
 LOCK TABLE public.time_entries,public.payroll_adjustments,public.shift_schedules,public.weekly_item_approvals,public.weekly_shift_resolutions,public.weekly_employee_locks,public.weekly_period_locks,public.transport_allocations,public.daily_review_locks,public.daily_review_notes,public.daily_review_transfers IN SHARE ROW EXCLUSIVE MODE;
 state:=public.daily_review_state(p_org,p_day);w:=date_trunc('week',p_day::timestamp)::date;
 IF p_action IN ('begin_transfer','finish_transfer','fail_transfer') THEN
  IF p_action='begin_transfer' THEN
   IF NOT (state->>'locked')::boolean OR p_body->>'lock_id' IS DISTINCT FROM state->>'lock_id' THEN RAISE EXCEPTION 'Godkjenn og lås dagen før overføring. Oppdater visningen hvis dagen er endret.'; END IF;
   IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(state->'allocations') x WHERE x->>'client_id'=p_body->>'client_id') THEN RAISE EXCEPTION 'Ingen fordelte timer for oppdragsgiveren.'; END IF;
   SELECT * INTO transfer FROM public.daily_review_transfers WHERE organization_id=p_org AND work_date=p_day AND client_id=(p_body->>'client_id')::uuid;
   IF transfer.id IS NOT NULL AND (transfer.lock_id<>(state->>'lock_id')::uuid OR transfer.status='transferred') THEN RAISE EXCEPTION 'Dagen er allerede overført. Kontroller eksisterende dagsoppgjør; det overskrives ikke.'; END IF;
   IF transfer.status='pending' AND transfer.updated_at>now()-interval '2 minutes' THEN RAISE EXCEPTION 'Overføring pågår. Vent litt og oppdater dagen.'; END IF;
   INSERT INTO public.daily_review_transfers(organization_id,work_date,client_id,lock_id,status) VALUES(p_org,p_day,(p_body->>'client_id')::uuid,(state->>'lock_id')::uuid,'pending')
   ON CONFLICT(organization_id,work_date,client_id) DO UPDATE SET status='pending',updated_at=now(),message=NULL RETURNING * INTO transfer;
   RETURN jsonb_build_object('transfer_id',transfer.id,'source',state);
  END IF;
  SELECT * INTO transfer FROM public.daily_review_transfers WHERE organization_id=p_org AND work_date=p_day AND id=(p_body->>'transfer_id')::uuid;
  IF transfer.id IS NULL THEN RAISE EXCEPTION 'Overføringen finnes ikke.'; END IF;
  IF transfer.status<>'transferred' THEN
   UPDATE public.daily_review_transfers SET status=CASE WHEN p_action='finish_transfer' THEN 'transferred' ELSE 'failed' END,report_id=coalesce(p_body->>'report_id',report_id),message=left(p_body->>'message',500),updated_at=now() WHERE id=transfer.id;
  END IF;
  RETURN public.daily_review_state(p_org,p_day);
 END IF;
 IF p_body->>'expected' IS DISTINCT FROM state->>'fingerprint' THEN RAISE EXCEPTION 'Grunnlaget er endret. Oppdater dagen og kontroller på nytt.'; END IF;
 IF p_action='reopen' THEN
  reason:=trim(coalesce(p_body->>'reason',''));IF length(reason) NOT BETWEEN 3 AND 1000 THEN RAISE EXCEPTION 'Oppgi begrunnelse for å åpne dagen.'; END IF;
  IF NOT (state->>'locked')::boolean THEN RAISE EXCEPTION 'Dagen er allerede åpen.'; END IF;
  IF EXISTS(SELECT 1 FROM public.daily_review_transfers WHERE organization_id=p_org AND work_date=p_day AND status='pending' AND updated_at>now()-interval '2 minutes') THEN RAISE EXCEPTION 'Vent til overføringen er ferdig før dagen åpnes.'; END IF;
  IF EXISTS(SELECT 1 FROM public.month_locks WHERE organization_id=p_org AND superseded_at IS NULL AND month_start BETWEEN date_trunc('month',w)::date AND date_trunc('month',w+6)::date)
   OR EXISTS(SELECT 1 FROM public.month_approvals WHERE organization_id=p_org AND status='locked' AND month_start BETWEEN date_trunc('month',w)::date AND date_trunc('month',w+6)::date) THEN RAISE EXCEPTION 'Måneden er låst og må åpnes først.'; END IF;
  UPDATE public.daily_review_locks SET superseded_at=now(),reopened_by=p_actor,reopen_reason=reason WHERE id=(state->>'lock_id')::uuid;
  UPDATE public.weekly_period_locks SET superseded_at=now(),reopened_by=p_actor,reopen_reason='Dagskontroll '||p_day||': '||reason WHERE organization_id=p_org AND week_start=w AND superseded_at IS NULL;
  UPDATE public.weekly_employee_locks SET superseded_at=now(),reopened_by=p_actor,reopen_reason='Dagskontroll '||p_day||': '||reason WHERE organization_id=p_org AND week_start=w AND superseded_at IS NULL;
  DELETE FROM public.weekly_item_approvals WHERE organization_id=p_org AND week_start=w;
  UPDATE public.month_approvals SET status='open',approved_at=NULL,approved_by=NULL WHERE organization_id=p_org AND status='approved' AND month_start BETWEEN date_trunc('month',w)::date AND date_trunc('month',w+6)::date;
 ELSE
  IF (state->>'locked')::boolean THEN RAISE EXCEPTION 'Åpne dagen før du gjør endringer.'; END IF;
  IF EXISTS(SELECT 1 FROM public.weekly_period_locks WHERE organization_id=p_org AND week_start=w AND superseded_at IS NULL) OR EXISTS(SELECT 1 FROM public.weekly_employee_locks WHERE organization_id=p_org AND week_start=w AND superseded_at IS NULL) THEN RAISE EXCEPTION 'Åpne uken i Ukesluttkontroll før du behandler dagen.'; END IF;
  IF p_action='lock' AND (NOT (state->>'can_lock')::boolean OR p_body->>'confirmed' IS DISTINCT FROM 'true') THEN RAISE EXCEPTION 'Dagen må være avsluttet og kontrollert før låsing.'; END IF;
  rows:=p_body->'entries';
  IF rows IS NULL OR jsonb_typeof(rows)<>'array' OR jsonb_array_length(rows)<>jsonb_array_length(state->'entries') OR jsonb_array_length(rows)>500 THEN RAISE EXCEPTION 'Alle dagens registreringer må følge med. Oppdater dagen.'; END IF;
  IF (SELECT count(DISTINCT x->>'id') FROM jsonb_array_elements(rows) x)<>jsonb_array_length(rows) THEN RAISE EXCEPTION 'Registreringen forekommer flere ganger.'; END IF;
  FOR row_input IN SELECT x FROM jsonb_array_elements(rows) x LOOP
   SELECT * INTO e FROM public.time_entries WHERE id=(row_input->>'id')::uuid AND organization_id=p_org AND (started_at AT TIME ZONE 'Europe/Oslo')::date=p_day;
   IF e.id IS NULL THEN RAISE EXCEPTION 'Registreringen finnes ikke på valgt dag.'; END IF;
   start_at:=(row_input->>'started_at')::timestamptz;end_at:=(row_input->>'ended_at')::timestamptz;
   IF start_at IS NULL OR NOT isfinite(start_at) OR (start_at AT TIME ZONE 'Europe/Oslo')::date<>p_day OR start_at>now() OR (end_at IS NOT NULL AND (NOT isfinite(end_at) OR end_at<=start_at OR end_at>now() OR end_at-start_at>interval '24 hours')) THEN RAISE EXCEPTION 'Kontroller tidene. Start må være på valgt dag, og avsluttede vakter må vare mellom 0 og 24 timer.'; END IF;
   IF (start_at,end_at) IS DISTINCT FROM (e.started_at,e.ended_at) THEN
    reason:=trim(coalesce(row_input->>'reason',''));IF length(reason) NOT BETWEEN 3 AND 1000 THEN RAISE EXCEPTION 'Oppgi begrunnelse for tidsendringen.'; END IF;
    IF EXISTS(SELECT 1 FROM public.time_entries WHERE organization_id=p_org AND employee_id=e.employee_id AND id<>e.id AND tstzrange(started_at,ended_at,'[)')&&tstzrange(start_at,end_at,'[)')) THEN RAISE EXCEPTION 'Tidene overlapper en annen registrering.'; END IF;
    UPDATE public.time_entries t SET started_at=start_at,ended_at=end_at,source='manual',note=concat_ws(E'\n',t.note,'Dagskontroll: '||reason),updated_at=clock_timestamp() WHERE t.id=e.id RETURNING t.* INTO e;
    INSERT INTO public.audit_logs(organization_id,actor_id,action,entity_type,entity_id,details) VALUES(p_org,p_actor,'daily_correct','time_entry',e.id::text,jsonb_build_object('reason',reason,'before',(SELECT x FROM jsonb_array_elements(state->'entries') x WHERE x->>'id'=e.id::text),'after',to_jsonb(e)));
   END IF;
   IF p_action='lock' AND e.ended_at IS NULL THEN RAISE EXCEPTION 'Avslutt alle åpne stemplinger før dagen låses.'; END IF;
   IF jsonb_typeof(row_input->'rows') IS DISTINCT FROM 'array' OR jsonb_array_length(row_input->'rows')>20 THEN RAISE EXCEPTION 'Kontroller fordelingen.'; END IF;
   previous_end:=NULL;allocated:=interval '0';note:=trim(coalesce(row_input->>'allocation_note',''));
   DELETE FROM public.transport_allocations WHERE entry_id=e.id;
   FOR a IN SELECT x FROM jsonb_array_elements(row_input->'rows') x ORDER BY (x->>'started_at')::timestamptz LOOP
    part_a:=(a->>'started_at')::timestamptz;part_b:=(a->>'ended_at')::timestamptz;
    IF e.kind<>'work' OR e.ended_at IS NULL OR part_a IS NULL OR part_b IS NULL OR NOT isfinite(part_a) OR NOT isfinite(part_b) OR part_b<=part_a OR part_a<e.started_at OR part_b>e.ended_at OR (previous_end IS NOT NULL AND part_a<previous_end) OR date_trunc('minute',part_a)<>part_a OR date_trunc('minute',part_b)<>part_b THEN RAISE EXCEPTION 'Fordel avsluttede arbeidstimer uten overlapp og innenfor stemplingen, i hele minutter.'; END IF;
    IF coalesce(length(a->>'client_name'),0) NOT BETWEEN 1 AND 160 OR a->>'client_id' IS NULL THEN RAISE EXCEPTION 'Velg oppdragsgiver.'; END IF;
    INSERT INTO public.transport_allocations(organization_id,entry_id,employee_id,client_id,client_name,started_at,ended_at,source_updated_at,approved_by) VALUES(p_org,e.id,e.employee_id,(a->>'client_id')::uuid,a->>'client_name',part_a,part_b,e.updated_at,p_actor);
    allocated:=allocated+(part_b-part_a);previous_end:=part_b;
   END LOOP;
   IF p_action='lock' AND e.kind='work' AND e.ended_at-e.started_at-allocated>interval '2 minutes' AND length(note)<3 THEN RAISE EXCEPTION 'Forklar timer som ikke skal overføres (for eksempel pause eller internt arbeid).'; END IF;
   IF length(note)>1000 THEN RAISE EXCEPTION 'Notatet er for langt.'; END IF;
   INSERT INTO public.daily_review_notes VALUES(e.id,p_org,note) ON CONFLICT(entry_id) DO UPDATE SET note=excluded.note;
  END LOOP;
  IF p_action='lock' THEN
   -- Daily approval also approves the same source items for weekly review.
   FOR emp IN SELECT DISTINCT employee_id FROM public.time_entries WHERE organization_id=p_org AND (started_at AT TIME ZONE 'Europe/Oslo')::date=p_day UNION SELECT employee_id FROM public.payroll_adjustments WHERE organization_id=p_org AND work_date=p_day LOOP
    person:=public.weekly_employee_data(p_org,emp,w);
    FOR item IN SELECT x||jsonb_build_object('item_type','entry') FROM jsonb_array_elements(person->'entries') x WHERE x->>'work_date'=p_day::text UNION ALL SELECT x||jsonb_build_object('item_type','adjustment') FROM jsonb_array_elements(person->'adjustments') x WHERE x->>'work_date'=p_day::text LOOP
     INSERT INTO public.weekly_item_approvals(organization_id,employee_id,week_start,item_type,item_id,fingerprint,approved_by) VALUES(p_org,emp,w,item->>'item_type',(item->>'id')::uuid,item->>'fingerprint',p_actor) ON CONFLICT(item_type,item_id) DO UPDATE SET fingerprint=excluded.fingerprint,approved_by=excluded.approved_by,approved_at=now();
    END LOOP;
   END LOOP;
   SELECT coalesce(max(revision),0)+1 INTO rev FROM public.daily_review_locks WHERE organization_id=p_org AND work_date=p_day;
   INSERT INTO public.daily_review_locks(organization_id,work_date,revision,snapshot,locked_by) VALUES(p_org,p_day,rev,public.daily_review_data(p_org,p_day),p_actor) RETURNING id INTO lock_id;
  END IF;
 END IF;
 INSERT INTO public.audit_logs(organization_id,actor_id,action,entity_type,entity_id,details) VALUES(p_org,p_actor,'daily_'||p_action,'daily_review',p_day::text,jsonb_build_object('revision',rev,'reason',p_body->>'reason'));
 RETURN public.daily_review_state(p_org,p_day);
END $$;

ALTER FUNCTION public.weekly_review(uuid,uuid,date,text,jsonb) RENAME TO weekly_review_before_daily;
CREATE FUNCTION public.weekly_review(p_org uuid,p_actor uuid,p_week date,p_action text,p_body jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE result jsonb; days jsonb;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.employees WHERE organization_id=p_org AND auth_user_id=p_actor AND active AND role='admin') THEN RAISE EXCEPTION 'Kun administrator har tilgang.'; END IF;
 IF p_action IN ('lock_employee','lock_week') THEN
  LOCK TABLE public.time_entries,public.payroll_adjustments,public.shift_schedules,public.weekly_item_approvals,public.weekly_shift_resolutions,public.weekly_employee_locks,public.weekly_period_locks IN SHARE ROW EXCLUSIVE MODE;
  IF EXISTS(SELECT 1 FROM (SELECT (started_at AT TIME ZONE 'Europe/Oslo')::date AS d FROM public.time_entries WHERE organization_id=p_org AND public.review_week(started_at)=p_week UNION SELECT work_date FROM public.payroll_adjustments WHERE organization_id=p_org AND work_date>=p_week AND work_date<p_week+7) dates WHERE NOT EXISTS(SELECT 1 FROM public.daily_review_locks WHERE organization_id=p_org AND work_date=dates.d AND superseded_at IS NULL)) THEN RAISE EXCEPTION 'Godkjenn og lås dager med registreringer i Dagskontroll før uken låses.'; END IF;
 END IF;
 result:=public.weekly_review_before_daily(p_org,p_actor,p_week,p_action,p_body);
 IF p_action='report' THEN RETURN result; END IF;
 SELECT jsonb_agg(jsonb_build_object('date',d::date,'locked',l.id IS NOT NULL,'revision',l.revision) ORDER BY d) INTO days FROM generate_series(p_week::timestamp,(p_week+6)::timestamp,interval '1 day') d LEFT JOIN public.daily_review_locks l ON l.organization_id=p_org AND l.work_date=d::date AND l.superseded_at IS NULL;
 RETURN result||jsonb_build_object('daily_status',days);
END $$;
DO $$ DECLARE f record; BEGIN
 FOR f IN SELECT p.oid::regprocedure AS signature FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname IN ('daily_review_data','daily_review_state','daily_review','guard_daily_changes','weekly_review') LOOP
  EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,anon,authenticated',f.signature);EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role',f.signature);
 END LOOP;
END $$;
