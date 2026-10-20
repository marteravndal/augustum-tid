-- A cancelled request remains immutable; retry starts from a separately reviewed draft.
alter table public.hr_contracts add column restarted_from_id uuid unique references public.hr_contracts(id);

create function public.hr_restart_cancelled_contract(p_org uuid,p_actor uuid,p_id uuid,p_expected timestamptz)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare c public.hr_contracts; child public.hr_contracts; request public.hr_signing_requests;
begin
 if not exists(select 1 from public.employees where organization_id=p_org and auth_user_id=p_actor and active and role='admin') then
  raise exception 'Kun administrator har tilgang.';
 end if;
 select * into c from public.hr_contracts where id=p_id and organization_id=p_org for update;
 if not found then raise exception 'Kontrakten finnes ikke.';end if;
 if p_expected is null or c.updated_at<>p_expected then raise exception 'Kontrakten er endret. Oppdater listen før du prøver igjen.';end if;
 if c.status<>'cancelled' or c.signed_at is not null or c.provider is distinct from 'signicat_sandbox' then
  raise exception 'Bare en avbrutt testsignering kan få et nytt utkast.';
 end if;
 select * into request from public.hr_signing_requests where contract_id=c.id and organization_id=p_org;
 if not found or request.state->>'phase' is distinct from 'cancelled' or request.signed_path is not null then
  raise exception 'Avbrytelsen må være bekreftet før et nytt utkast kan opprettes.';
 end if;
 -- Locking the source and a unique source reference also protect against double clicks/retries.
 select * into child from public.hr_contracts where restarted_from_id=c.id and organization_id=p_org;
 if found then
  return jsonb_build_object('ok',true,'existing',true,'contract',jsonb_build_object('id',child.id,'status',child.status,'version',child.version),'email_sent',false);
 end if;
 if not exists(select 1 from public.employees where id=c.employee_id and organization_id=p_org and active and not portal_actor_only and portal_employee_id is not null) then
  raise exception 'Ansatt må være aktiv i felles ansattregister før du oppretter et nytt utkast.';
 end if;
 insert into public.hr_contracts(organization_id,employee_id,title,content,modules,version,restarted_from_id,created_by,updated_by)
 values(p_org,c.employee_id,c.title,coalesce(c.locked_content,c.content),coalesce(c.locked_modules,c.modules),c.version+1,c.id,p_actor,p_actor)
 returning * into child;
 insert into public.audit_logs(organization_id,actor_id,action,entity_type,entity_id,details)
 values(p_org,p_actor,'restart_cancelled_contract','hr_contract',child.id::text,jsonb_build_object('source_contract_id',c.id,'source_version',c.version));
 return jsonb_build_object('ok',true,'existing',false,'contract',jsonb_build_object('id',child.id,'status',child.status,'version',child.version),'email_sent',false);
end $$;
revoke all on function public.hr_restart_cancelled_contract(uuid,uuid,uuid,timestamptz) from public,anon,authenticated;
grant execute on function public.hr_restart_cancelled_contract(uuid,uuid,uuid,timestamptz) to service_role;
