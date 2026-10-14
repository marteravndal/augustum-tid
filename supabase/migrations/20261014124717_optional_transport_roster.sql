-- Transport companies opt in to shift planning. Existing schedules are preserved.
ALTER TABLE public.organizations ADD COLUMN roster_enabled boolean NOT NULL DEFAULT false;
CREATE FUNCTION public.set_roster_enabled(p_actor uuid,p_enabled boolean,p_expected boolean) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE employee public.employees%ROWTYPE; previous boolean;
BEGIN
 SELECT * INTO employee FROM public.employees WHERE auth_user_id=p_actor AND active AND role='admin';
 IF NOT FOUND THEN RAISE EXCEPTION 'Kun administrator har tilgang.'; END IF;
 IF p_enabled IS NULL OR p_expected IS NULL THEN RAISE EXCEPTION 'Velg aktiv eller inaktiv.'; END IF;
 SELECT roster_enabled INTO STRICT previous FROM public.organizations WHERE id=employee.organization_id FOR UPDATE;
 IF previous<>p_expected THEN RAISE EXCEPTION 'Innstillingen er endret. Last siden på nytt.'; END IF;
 UPDATE public.organizations SET roster_enabled=p_enabled WHERE id=employee.organization_id;
 INSERT INTO public.audit_logs(organization_id,actor_id,action,entity_type,entity_id,details)
 VALUES(employee.organization_id,p_actor,'set_roster_enabled','organization',employee.organization_id::text,jsonb_build_object('before',previous,'after',p_enabled));
 RETURN jsonb_build_object('roster_enabled',p_enabled);
END $$;
REVOKE ALL ON FUNCTION public.set_roster_enabled(uuid,boolean,boolean) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.set_roster_enabled(uuid,boolean,boolean) TO service_role;

-- Read-only gate used by the UI and checked again atomically on insert.
CREATE OR REPLACE FUNCTION public.clock_in_gate(p_employee_id uuid, p_organization_id uuid, p_at timestamptz DEFAULT clock_timestamp())
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path = public, pg_temp AS $$
DECLARE enabled boolean; last_end timestamptz; local_day date := (p_at AT TIME ZONE 'Europe/Oslo')::date; shift_row record; next_start timestamptz;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.employees WHERE id=p_employee_id AND organization_id=p_organization_id AND active) THEN
    RETURN jsonb_build_object('allowed',false,'code','inactive','message','Brukeren er ikke aktiv. Kontakt ADMIN.');
  END IF;
  SELECT roster_enabled INTO STRICT enabled FROM public.organizations WHERE id=p_organization_id;
  SELECT max(ended_at) INTO last_end FROM public.time_entries WHERE employee_id=p_employee_id AND organization_id=p_organization_id;
  IF last_end IS NOT NULL AND p_at < last_end + interval '2 minutes' THEN
    RETURN jsonb_build_object('allowed',false,'code','cooldown','roster_enabled',enabled,'available_at',last_end + interval '2 minutes','message','Du har nettopp stemplet ut. Vent to minutter før du kan stemple inn igjen.');
  END IF;
  IF NOT enabled THEN RETURN jsonb_build_object('allowed',true,'roster_enabled',false,'code','roster_disabled'); END IF;
  FOR shift_row IN
    SELECT ((x->>'work_date')::date + (x->>'start_time')::time) AT TIME ZONE 'Europe/Oslo' AS starts_at,
      (((x->>'work_date')::date + CASE WHEN (x->>'end_time')::time <= (x->>'start_time')::time THEN 1 ELSE 0 END) + (x->>'end_time')::time) AT TIME ZONE 'Europe/Oslo' AS ends_at
    FROM public.shift_schedules s CROSS JOIN LATERAL jsonb_array_elements(s.published_snapshot) x
    WHERE s.organization_id=p_organization_id AND s.status='published'
      AND s.week_start BETWEEN local_day-8 AND local_day+7 AND x->>'employee_id'=p_employee_id::text
    ORDER BY starts_at
  LOOP
    IF p_at >= shift_row.starts_at - interval '1 hour' AND p_at < shift_row.ends_at THEN
      RETURN jsonb_build_object('allowed',true,'shift_start',shift_row.starts_at,'shift_end',shift_row.ends_at);
    END IF;
    IF shift_row.starts_at > p_at AND next_start IS NULL THEN next_start:=shift_row.starts_at; END IF;
  END LOOP;
  RETURN jsonb_build_object('allowed',false,'code','no_shift','next_shift',next_start,'message','Du har ikke et publisert skift å stemple inn på nå. Du kan stemple inn fra én time før skiftstart. Kontakt ADMIN hvis du skal jobbe utenfor vaktlisten.');
END;
$$;
REVOKE ALL ON FUNCTION public.clock_in_gate(uuid,uuid,timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.clock_in_gate(uuid,uuid,timestamptz) TO service_role;


-- Disabled rosters must not cause missing-shift alerts or feed payroll forecasts.
DO $migration$
DECLARE signature text; definition text; changed text;
BEGIN
 FOREACH signature IN ARRAY ARRAY['public.control_candidates(uuid)','public.payroll_day_plan(uuid,date,boolean)','public.payroll_dashboard(uuid,uuid,date,text,jsonb)'] LOOP
  definition:=pg_get_functiondef(signature::regprocedure);
  changed:=definition;
  IF signature='public.control_candidates(uuid)' THEN
   changed:=replace(changed,'WHERE ss.organization_id=p_org AND ss.status=', 'WHERE (SELECT roster_enabled FROM public.organizations WHERE id=p_org) AND ss.organization_id=p_org AND ss.status=');
   changed:=replace(changed,'WHERE s.organization_id=p_org AND ss.status', 'WHERE (SELECT roster_enabled FROM public.organizations WHERE id=p_org) AND s.organization_id=p_org AND ss.status');
  ELSIF signature='public.payroll_day_plan(uuid,date,boolean)' THEN
   changed:=replace(changed,'WHERE organization_id=p_org AND week_start=', 'WHERE (SELECT roster_enabled FROM public.organizations WHERE id=p_org) AND organization_id=p_org AND week_start=');
  ELSE
   changed:=replace(changed,'WHERE ss.organization_id=p_org AND ss.status=', 'WHERE (SELECT roster_enabled FROM public.organizations WHERE id=p_org) AND ss.organization_id=p_org AND ss.status=');
  END IF;
  IF changed=definition THEN RAISE EXCEPTION 'Expected roster predicate missing in %',signature; END IF;
  EXECUTE changed;
 END LOOP;
END $migration$;
