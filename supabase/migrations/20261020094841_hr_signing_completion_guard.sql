create or replace function public.hr_signing_checkpoint(p_org uuid,p_id uuid,p_lease uuid,p_state jsonb,p_original text default null,p_signed text default null,p_release boolean default false)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare r public.hr_signing_requests;
begin
 select * into r from public.hr_signing_requests where id=p_id and organization_id=p_org for update;
 if not found or r.lease is distinct from p_lease or r.lease_until<clock_timestamp() then raise exception 'Signeringen er endret. Oppdater status.';end if;
 if r.state->>'phase' in ('signed','cancelled') and p_state->>'phase' is distinct from r.state->>'phase' then raise exception 'Avsluttet signering kan ikke endres.';end if;
 if p_state->>'phase'='signed' and (coalesce(p_signed,r.signed_path) is null or coalesce(jsonb_array_length(p_state->'sessions'),0)<>2 or exists(select 1 from jsonb_array_elements(p_state->'sessions') s where s->>'state' is distinct from 'SIGNED')) then raise exception 'Begge signaturer og arkivert PDF kreves.';end if;
 update public.hr_signing_requests set state=p_state,original_path=coalesce(p_original,original_path),signed_path=coalesce(p_signed,signed_path),lease=case when p_release then null else p_lease end,lease_until=case when p_release then null else clock_timestamp()+interval '3 minutes' end,updated_at=clock_timestamp() where id=r.id returning * into r;
 if p_state->>'phase'='signed' then
  update public.hr_contracts set status='signed',signed_at=coalesce(signed_at,clock_timestamp()),updated_at=clock_timestamp() where id=r.contract_id and status<>'signed';
 elsif p_state->>'phase'='cancelled' then
  update public.hr_contracts set status='cancelled',updated_at=clock_timestamp() where id=r.contract_id and status<>'signed';
 end if;
 if p_release then insert into public.audit_logs(organization_id,actor_id,action,entity_type,entity_id,details) values(p_org,r.actor_id,'sandbox_signing_status','hr_contract',r.contract_id::text,jsonb_build_object('phase',p_state->>'phase'));end if;
 return to_jsonb(r);
end $$;
revoke all on function public.hr_signing_checkpoint(uuid,uuid,uuid,jsonb,text,text,boolean) from public,anon,authenticated;
grant execute on function public.hr_signing_checkpoint(uuid,uuid,uuid,jsonb,text,text,boolean) to service_role;
