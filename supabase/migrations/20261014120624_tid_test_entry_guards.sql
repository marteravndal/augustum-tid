-- Resolve retries/concurrent first opens without creating multiple local identities.
create function public.resolve_tid_actor(p_company uuid,p_actor uuid) returns uuid
language plpgsql security definer set search_path='' as $$
declare local_id uuid;shadow_email text;
begin
 select local_user_id into local_id from public.portal_actors where company_id=p_company and actor_id=p_actor;
 if local_id is not null then return local_id;end if;
 shadow_email:=encode(extensions.digest(p_company::text||':'||p_actor::text,'sha256'),'hex')||'@tid-preview.invalid';
 select id into local_id from auth.users where lower(email)=shadow_email;
 if local_id is not null then
  insert into public.portal_actors(company_id,actor_id,local_user_id) values(p_company,p_actor,local_id) on conflict(company_id,actor_id) do nothing;
 end if;
 return local_id;
end;$$;
revoke all on function public.resolve_tid_actor(uuid,uuid) from public,anon,authenticated;
grant execute on function public.resolve_tid_actor(uuid,uuid) to service_role;

CREATE OR REPLACE FUNCTION public.enforce_clock_in_gate()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path = public, pg_temp AS $$
DECLARE gate jsonb;
BEGIN
  -- Serialize clock-in and clock-out for one employee, including manual actions.
  PERFORM pg_advisory_xact_lock(hashtextextended(NEW.employee_id::text, 73421));
  IF NEW.kind='work' AND EXISTS (
    SELECT 1 FROM public.time_entries t WHERE t.employee_id=NEW.employee_id AND t.id<>NEW.id AND t.kind='work'
    AND t.started_at<coalesce(NEW.ended_at,'infinity'::timestamptz)
    AND coalesce(t.ended_at,'infinity'::timestamptz)>NEW.started_at
  ) THEN RAISE EXCEPTION 'Timene overlapper en registrering.' USING ERRCODE='P0001';END IF;
  IF TG_OP='INSERT' AND NEW.source IN ('location','qr') THEN
    gate := public.clock_in_gate(NEW.employee_id,NEW.organization_id);
    IF NOT (gate->>'allowed')::boolean THEN RAISE EXCEPTION '%', gate->>'message' USING ERRCODE='P0001'; END IF;
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.enforce_clock_in_gate() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.enforce_clock_in_gate() TO service_role;
