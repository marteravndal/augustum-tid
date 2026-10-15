-- Isolated test project only. No grants to browser roles for bridge material.
create schema if not exists private;
create table private.tid_bridge_keys(id boolean primary key default true check(id),secret text not null check(length(secret)=64));
create table private.tid_bridge_nonces(nonce uuid primary key,expires_at timestamptz not null);
revoke all on private.tid_bridge_keys,private.tid_bridge_nonces from public,anon,authenticated;
alter table private.tid_bridge_keys enable row level security;
alter table private.tid_bridge_nonces enable row level security;
create function public.verify_tid_bridge(p_token text,p_body text,p_method text,p_path text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare payload text;sig text;expected text;c jsonb;k text;
begin
 if length(p_token)>6000 or length(p_body)>2000000 or array_length(string_to_array(p_token,'.'),1)<>2 then return null;end if;
 payload:=split_part(p_token,'.',1);sig:=split_part(p_token,'.',2);
 select secret into k from private.tid_bridge_keys where id;
 if k is null then return null;end if;
 expected:=rtrim(translate(encode(extensions.hmac(payload,k,'sha256'),'base64'),'+/','-_'),'=');
 if sig<>expected then return null;end if;
 c:=convert_from(decode(translate(payload,'-_','+/')||repeat('=',(4-length(payload)%4)%4),'base64'),'UTF8')::jsonb;
 if (c->>'v')::int<>1 or c->>'method'<>p_method or c->>'path'<>p_path or c->>'bodyHash'<>encode(extensions.digest(p_body,'sha256'),'hex') or (c->>'exp')::numeric<extract(epoch from clock_timestamp()) or (c->>'exp')::numeric>extract(epoch from clock_timestamp())+32 or c->>'role' not in ('admin','viewer') then return null;end if;
 perform (c->>'companyId')::uuid,(c->>'actorId')::uuid,(c->>'nonce')::uuid;
 if coalesce(length(c->>'companyName'),0) not between 1 and 200 or coalesce(length(c->>'email'),0) not between 3 and 254 then return null;end if;
 delete from private.tid_bridge_nonces where expires_at<now();
 insert into private.tid_bridge_nonces values((c->>'nonce')::uuid,to_timestamp((c->>'exp')::numeric));
 return c;
exception when others then return null;
end;$$;
revoke all on function public.verify_tid_bridge(text,text,text,text) from public,anon,authenticated;
grant execute on function public.verify_tid_bridge(text,text,text,text) to service_role;
alter table public.organizations add column portal_company_id uuid unique,add column settlement_company_id uuid not null default gen_random_uuid();
alter table public.employees add column portal_employee_id uuid unique,add column portal_actor_only boolean not null default false;
create table public.portal_actors(company_id uuid not null,actor_id uuid not null,local_user_id uuid not null references auth.users(id),primary key(company_id,actor_id),unique(local_user_id));
alter table public.portal_actors enable row level security;
revoke all on public.portal_actors from anon,authenticated;
grant all on public.portal_actors to service_role;
alter table public.worksites add column position_required boolean not null default true;
create table public.transport_allocations(
 id uuid primary key default gen_random_uuid(),organization_id uuid not null references public.organizations(id),entry_id uuid not null references public.time_entries(id),
 employee_id uuid not null references public.employees(id),client_id uuid not null,client_name text not null,
 started_at timestamptz not null,ended_at timestamptz not null,source_updated_at timestamptz not null,
 revision integer not null default 1,approved_by uuid not null references auth.users(id),created_at timestamptz not null default now(),
 check(ended_at>started_at)
);
create index transport_allocations_entry on public.transport_allocations(entry_id);
create index transport_allocations_org_date on public.transport_allocations(organization_id,started_at);
alter table public.transport_allocations enable row level security;
revoke all on public.transport_allocations from anon,authenticated;
grant all on public.transport_allocations to service_role;
create function public.save_transport_allocations(p_org uuid,p_actor uuid,p_entry uuid,p_expected timestamptz,p_rows jsonb) returns jsonb
language plpgsql security invoker set search_path='' as $$
declare e public.time_entries;r jsonb;a timestamptz;b timestamptz;previous_end timestamptz;total interval:=interval '0';rev integer;out_rows jsonb;
begin
 if not exists(select 1 from public.employees where organization_id=p_org and auth_user_id=p_actor and active and role='admin') then raise exception 'Ingen tilgang';end if;
 select * into e from public.time_entries where id=p_entry and organization_id=p_org for update;
 if not found or e.kind<>'work' or e.ended_at is null or e.updated_at<>p_expected then raise exception 'Timene er endret eller ikke avsluttet. Last på nytt.';end if;
 if jsonb_typeof(p_rows)<>'array' or jsonb_array_length(p_rows) not between 1 and 20 then raise exception 'Fordel timene på minst én oppdragsgiver.';end if;
 for r in select value from jsonb_array_elements(p_rows) order by (value->>'started_at')::timestamptz loop
  a:=(r->>'started_at')::timestamptz;b:=(r->>'ended_at')::timestamptz;
  if a is null or b is null or b<=a or a<e.started_at or b>e.ended_at or (previous_end is not null and a<previous_end) then raise exception 'Fordelingen har overlapp eller ligger utenfor registrert arbeidstid.';end if;
  if (a at time zone 'Europe/Oslo')::date<>(b at time zone 'Europe/Oslo')::date then raise exception 'Del arbeid over midnatt på dato før overføring.';end if;
  if date_trunc('minute',a)<>a or date_trunc('minute',b)<>b then raise exception 'Bruk hele minutter.';end if;
  perform (r->>'client_id')::uuid;
  if coalesce(length(r->>'client_name'),0) not between 1 and 160 then raise exception 'Velg oppdragsgiver.';end if;
  previous_end:=b;total:=total+(b-a);
 end loop;
 select coalesce(max(revision),0)+1 into rev from public.transport_allocations where entry_id=p_entry;
 delete from public.transport_allocations where entry_id=p_entry;
 insert into public.transport_allocations(organization_id,entry_id,employee_id,client_id,client_name,started_at,ended_at,source_updated_at,revision,approved_by)
 select p_org,p_entry,e.employee_id,(value->>'client_id')::uuid,value->>'client_name',(value->>'started_at')::timestamptz,(value->>'ended_at')::timestamptz,e.updated_at,rev,p_actor from jsonb_array_elements(p_rows);
 insert into public.audit_logs(organization_id,actor_id,action,entity_type,entity_id,details)values(p_org,p_actor,'approve_transport_allocation','time_entry',p_entry,jsonb_build_object('revision',rev,'allocated_minutes',extract(epoch from total)/60,'rows',p_rows));
 select jsonb_agg(to_jsonb(x)) into out_rows from public.transport_allocations x where entry_id=p_entry;
 return jsonb_build_object('allocations',out_rows);
end;$$;
revoke all on function public.save_transport_allocations(uuid,uuid,uuid,timestamptz,jsonb) from public,anon,authenticated;
grant execute on function public.save_transport_allocations(uuid,uuid,uuid,timestamptz,jsonb) to service_role;
-- Transport working hours must be confirmed before enabling Apart's 12-hour stop rule.
select cron.unschedule(jobid) from cron.job where jobname='augustum-auto-clock-out';
