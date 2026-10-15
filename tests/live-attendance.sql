begin;
do $test$
declare actor uuid; org uuid; other_org uuid; night uuid; gone uuid; again uuid; old uuid; outsider uuid; untouched uuid; data jsonb; row_data jsonb; d timestamptz:=((now() at time zone 'Europe/Oslo')::date)::timestamp at time zone 'Europe/Oslo'; rejected boolean:=false; first_out int;
begin
 select auth_user_id,organization_id into strict actor,org from public.employees where active and role='admin' and portal_actor_only limit 1;
 insert into public.organizations(name) values('Attendance isolation test') returning id into other_org;
 insert into public.employees(organization_id,employee_number,full_name,email) values(org,'LIVE-NIGHT','Night fixture','live-night@example.invalid') returning id into night;
 insert into public.employees(organization_id,employee_number,full_name,email) values(org,'LIVE-OUT','Out fixture','live-out@example.invalid') returning id into gone;
 insert into public.employees(organization_id,employee_number,full_name,email) values(org,'LIVE-AGAIN','Again fixture','live-again@example.invalid') returning id into again;
 insert into public.employees(organization_id,employee_number,full_name,email) values(org,'LIVE-OLD','Old fixture','live-old@example.invalid') returning id into old;
 insert into public.employees(organization_id,employee_number,full_name,email) values(org,'LIVE-NONE','No attendance fixture','live-none@example.invalid') returning id into untouched;
 insert into public.employees(organization_id,employee_number,full_name,email) values(other_org,'LIVE-OTHER','Other company fixture','live-other@example.invalid') returning id into outsider;
 insert into public.time_entries(organization_id,employee_id,started_at,ended_at,source,created_by) values
 (org,night,d-interval '2 hours',null,'manual',actor),
 (org,gone,d-interval '3 hours',d+interval '1 minute','manual',actor),
 (org,again,d-interval '1 hour',d+interval '2 minutes','manual',actor),
 (org,again,now()-interval '5 minutes',null,'manual',actor),
 (org,old,d-interval '4 hours',d-interval '2 hours','manual',actor),
 (other_org,outsider,d-interval '1 hour',null,'manual',actor);
 data:=public.company_live_attendance(actor);
 if exists(select 1 from jsonb_array_elements(data->'employees') e where (e->>'employee_id')::uuid in (old,outsider,untouched)) then raise exception 'Past/other company/nonattending employee leaked'; end if;
 if (select count(*) from jsonb_array_elements(data->'employees') e where (e->>'employee_id')::uuid=again)<>1 then raise exception 'Repeated shifts duplicated'; end if;
 select e into row_data from jsonb_array_elements(data->'employees') e where (e->>'employee_id')::uuid=again;
 if row_data->>'status'<>'in' or row_data->>'ended_at' is not null then raise exception 'Latest re-entry did not win'; end if;
 if not exists(select 1 from jsonb_array_elements(data->'employees') e where (e->>'employee_id')::uuid=night and e->>'status'='in') then raise exception 'Overnight open missing'; end if;
 if not exists(select 1 from jsonb_array_elements(data->'employees') e where (e->>'employee_id')::uuid=gone and e->>'status'='out') then raise exception 'Overnight ending today missing'; end if;
 select min(n) into first_out from jsonb_array_elements(data->'employees') with ordinality e(value,n) where value->>'status'='out';
 if exists(select 1 from jsonb_array_elements(data->'employees') with ordinality e(value,n) where n>first_out and value->>'status'='in') then raise exception 'Closed employees not last'; end if;
 if (data->>'present_count')::int+(data->>'out_count')::int<>jsonb_array_length(data->'employees') then raise exception 'Count mismatch'; end if;
 update public.employees set role='employee' where auth_user_id=actor;
 begin perform public.company_live_attendance(actor); exception when insufficient_privilege then rejected:=true; end;
 if not rejected then raise exception 'Non-admin granted access'; end if;
 if has_function_privilege('authenticated','public.company_live_attendance(uuid)','execute') then raise exception 'Browser can bypass edge authentication'; end if;
end $test$;
rollback;
select 'PASS: latest shift, overnight in/out, current-day filter, status order, counts, company isolation and admin authorization; rolled back' as result;
