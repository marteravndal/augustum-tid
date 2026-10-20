-- Isolated Augustum Tid test project only; provider state is writable only by the signed server bridge.
create table public.hr_signing_requests (
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null references public.organizations(id),
 contract_id uuid not null unique references public.hr_contracts(id),
 actor_id uuid not null references auth.users(id),
 state jsonb not null default '{}'::jsonb,
 lease uuid, lease_until timestamptz,
 original_path text, signed_path text,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create index hr_signing_requests_org on public.hr_signing_requests(organization_id);
create index hr_signing_requests_actor on public.hr_signing_requests(actor_id);
alter table public.hr_signing_requests enable row level security;
revoke all on public.hr_signing_requests from public,anon,authenticated;
grant all on public.hr_signing_requests to service_role;

create function public.hr_signing_acquire(p_org uuid,p_actor uuid,p_contract uuid,p_expected timestamptz,p_lease uuid,p_input jsonb)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare c public.hr_contracts; r public.hr_signing_requests; e public.employees; a public.employees; me public.employees; n integer;
begin
 select * into me from public.employees where organization_id=p_org and auth_user_id=p_actor and active and role='admin';
 if not found then raise exception 'Ingen tilgang.'; end if;
 select * into c from public.hr_contracts where id=p_contract and organization_id=p_org for update;
 if not found then raise exception 'Kontrakten finnes ikke.'; end if;
 select * into r from public.hr_signing_requests where contract_id=c.id;
 if found then
  if r.lease_until>clock_timestamp() then raise exception 'Signeringen behandles. Vent litt og oppdater status.';end if;
 else
  if c.status<>'signing_ready' or c.updated_at is distinct from p_expected then raise exception 'Oppdater kontraktlisten før du starter signering.';end if;
  if coalesce(p_input->>'employee_nin','')!~'^\d{11}$' or coalesce(p_input->>'admin_nin','')!~'^\d{11}$' or p_input->>'employee_nin'=p_input->>'admin_nin' or p_input->>'test_confirmed' is distinct from 'true' then raise exception 'Oppgi to forskjellige BankID-testpersoner og bekreft test.';end if;
  select * into e from public.employees where id=c.employee_id and organization_id=p_org and active and not portal_actor_only and portal_employee_id is not null;
  if not found then raise exception 'Ansatt må være aktiv i ansattregisteret.';end if;
  select count(*) into n from public.employees where organization_id=p_org and active and not portal_actor_only and portal_employee_id is not null and (case when me.portal_employee_id is not null then id=me.id else lower(email)=lower(me.email) end);
  if n<>1 then raise exception 'Administrator må ha én aktiv kobling i ansattregisteret.';end if;
  select * into a from public.employees where organization_id=p_org and active and not portal_actor_only and portal_employee_id is not null and (case when me.portal_employee_id is not null then id=me.id else lower(email)=lower(me.email) end);
  if e.id=a.id or lower(e.email)=lower(a.email) then raise exception 'Velg to forskjellige mottakere i ansattregisteret.';end if;
  if coalesce(e.email,'')!~'^[^\s@]+@[^\s@]+\.[^\s@]+$' or coalesce(a.email,'')!~'^[^\s@]+@[^\s@]+\.[^\s@]+$' or e.email like '%.invalid' or a.email like '%.invalid' then raise exception 'Begge mottakere må ha gyldig e-post i ansattregisteret.';end if;
  insert into public.hr_signing_requests(organization_id,contract_id,actor_id,state)
  values(p_org,c.id,p_actor,jsonb_build_object('phase','reserved','clientId',p_input->>'client_id','notify',coalesce((p_input->>'notify')::boolean,false),'signers',jsonb_build_array(
   jsonb_build_object('role','employee','employeeId',e.id,'name',e.full_name,'email',e.email,'nin',p_input->>'employee_nin'),
   jsonb_build_object('role','admin','employeeId',a.id,'name',a.full_name,'email',a.email,'nin',p_input->>'admin_nin')))) returning * into r;
  update public.hr_contracts set status='pending_signature',provider='signicat_sandbox',provider_reference=r.id::text,updated_at=clock_timestamp(),updated_by=p_actor where id=c.id;
  insert into public.audit_logs(organization_id,actor_id,action,entity_type,entity_id) values(p_org,p_actor,'start_sandbox_signing','hr_contract',c.id::text);
 end if;
 update public.hr_signing_requests set lease=p_lease,lease_until=clock_timestamp()+interval '3 minutes' where id=r.id returning * into r;
 return to_jsonb(r)||jsonb_build_object('contract',to_jsonb(c));
end $$;
revoke all on function public.hr_signing_acquire(uuid,uuid,uuid,timestamptz,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.hr_signing_acquire(uuid,uuid,uuid,timestamptz,uuid,jsonb) to service_role;

create function public.hr_signing_checkpoint(p_org uuid,p_id uuid,p_lease uuid,p_state jsonb,p_original text default null,p_signed text default null,p_release boolean default false)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare r public.hr_signing_requests;
begin
 select * into r from public.hr_signing_requests where id=p_id and organization_id=p_org for update;
 if not found or r.lease is distinct from p_lease or r.lease_until<clock_timestamp() then raise exception 'Signeringen er endret. Oppdater status.';end if;
 if p_state->>'phase'='signed' and (coalesce(p_signed,r.signed_path) is null or jsonb_array_length(p_state->'sessions')<>2 or exists(select 1 from jsonb_array_elements(p_state->'sessions') s where s->>'state' is distinct from 'SIGNED')) then raise exception 'Begge signaturer og arkivert PDF kreves.';end if;
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
