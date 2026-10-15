-- Preparation is not delivery. Only the future verified provider flow may set pending_signature/signed.
alter table public.hr_contracts drop constraint hr_contracts_status_check;
alter table public.hr_contracts add constraint hr_contracts_status_check
  check (status in ('draft','signing_ready','locked','pending_signature','signed','cancelled'));
alter table public.hr_contracts
  add column signing_method text check (signing_method in ('bankid')),
  add column locked_employer_name text;

create or replace function public.hr_contract_draft_action(
  p_org uuid, p_actor uuid, p_id uuid, p_expected timestamptz,
  p_action text, p_body jsonb default '{}'::jsonb
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare c public.hr_contracts; e public.employees; details jsonb; result jsonb;
begin
  if not exists(select 1 from public.employees where organization_id=p_org
    and auth_user_id=p_actor and active and role='admin') then
    raise exception 'Kun administrator har tilgang.';
  end if;
  select * into c from public.hr_contracts where id=p_id and organization_id=p_org for update;
  if not found then raise exception 'Kontrakten finnes ikke.'; end if;
  if p_expected is null or c.updated_at <> p_expected then
    raise exception 'Kontrakten er endret. Oppdater listen før du prøver igjen.';
  end if;
  if p_action in ('update_contract','delete_contract','prepare_signing') and c.status<>'draft' then
    raise exception 'Bare lagrede utkast kan redigeres, slettes eller klargjøres.';
  end if;
  if p_action='delete_contract' then
    delete from public.hr_contracts where id=c.id;
  elsif p_action='update_contract' then
    if coalesce(length(trim(p_body->>'title')),0) not between 2 and 200 or jsonb_typeof(p_body->'modules') is distinct from 'array' then
      raise exception 'Oppgi tittel og kontraktspunkter.';
    end if;
    if not exists(select 1 from jsonb_array_elements(p_body->'modules') m where m->>'active'='true') then
      raise exception 'Behold minst ett aktivt kontraktspunkt.';
    end if;
    update public.hr_contracts set title=trim(p_body->>'title'),modules=p_body->'modules',
      updated_by=p_actor,updated_at=clock_timestamp() where id=c.id;
  elsif p_action='prepare_signing' then
    select * into e from public.employees where id=c.employee_id and organization_id=p_org
      and active and not portal_actor_only and portal_employee_id is not null;
    if not found then raise exception 'Velg en aktiv ansatt fra felles ansattregister.'; end if;
    if not exists(select 1 from jsonb_array_elements(c.modules) m where m->>'active'='true') then
      raise exception 'Behold minst ett aktivt kontraktspunkt.';
    end if;
    select jsonb_build_object('address',address,'postal_code',postal_code,'city',city,
      'employed_from',employed_from,'position_percent',position_percent,'salary_type',salary_type,'salary_rate',salary_rate)
      into details from public.employee_private_details where employee_id=e.id and organization_id=p_org;
    update public.hr_contracts set status='signing_ready',signing_method='bankid',
      locked_content=content,locked_modules=modules,
      locked_employee_snapshot=jsonb_build_object('full_name',e.full_name,'email',e.email,'phone_number',e.phone_number)||coalesce(details,'{}'::jsonb),
      locked_employer_name=(select name from public.organizations where id=p_org),
      locked_at=clock_timestamp(),updated_at=clock_timestamp(),updated_by=p_actor where id=c.id;
  elsif p_action='return_to_draft' then
    if c.status<>'signing_ready' or c.provider_reference is not null or c.signed_at is not null then
      raise exception 'Bare kontrakter som ikke er sendt kan flyttes tilbake til utkast.';
    end if;
    update public.hr_contracts set status='draft',signing_method=null,locked_content=null,locked_modules=null,
      locked_employee_snapshot=null,locked_employer_name=null,locked_at=null,
      updated_at=clock_timestamp(),updated_by=p_actor where id=c.id;
  else raise exception 'Handling støttes ikke.';
  end if;
  insert into public.audit_logs(organization_id,actor_id,action,entity_type,entity_id,details)
    values(p_org,p_actor,p_action,'hr_contract',c.id::text,jsonb_build_object('previous_status',c.status));
  select jsonb_build_object('id',id,'status',status,'updated_at',updated_at) into result from public.hr_contracts where id=c.id;
  return jsonb_build_object('ok',true,'contract',result,'email_sent',false);
end $$;
revoke all on function public.hr_contract_draft_action(uuid,uuid,uuid,timestamptz,text,jsonb) from public,anon,authenticated;
grant execute on function public.hr_contract_draft_action(uuid,uuid,uuid,timestamptz,text,jsonb) to service_role;
