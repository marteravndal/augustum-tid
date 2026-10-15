begin;
do $test$
declare actor uuid; org uuid; emp uuid; eid uuid; day date:=date '2020-01-08'; w date:=date '2020-01-06'; c1 uuid:=gen_random_uuid(); c2 uuid:=gen_random_uuid(); state jsonb; week jsonb; body jsonb; reservation jsonb; prior text; rejected boolean; locked_id text;
begin
 select auth_user_id,organization_id into strict actor,org from public.employees where active and role='admin' and portal_actor_only limit 1;
 insert into public.employees(organization_id,employee_number,full_name,email,portal_employee_id) values(org,'DAILY-FIXTURE','Daily test fixture','daily-fixture@example.invalid',gen_random_uuid()) returning id into emp;
 insert into public.time_entries(organization_id,employee_id,started_at,ended_at,source,created_by) values(org,emp,'2020-01-08 07:00Z','2020-01-08 15:00Z','manual',actor) returning id into eid;
 state:=public.daily_review(org,actor,day,'load');
 body:=jsonb_build_object('expected',state->>'fingerprint','confirmed',true,'entries',jsonb_build_array(jsonb_build_object('id',eid,'started_at','2020-01-08T07:00:00Z','ended_at','2020-01-08T15:00:00Z','rows',jsonb_build_array(jsonb_build_object('client_id',c1,'client_name','First','started_at','2020-01-08T07:00:00Z','ended_at','2020-01-08T12:00:00Z'),jsonb_build_object('client_id',c2,'client_name','Second','started_at','2020-01-08T12:00:00Z','ended_at','2020-01-08T15:00:00Z')))));
 rejected:=false;begin perform public.daily_review(org,gen_random_uuid(),day,'lock',body);exception when others then if SQLERRM='Kun administrator har tilgang.' then rejected:=true;else raise;end if;end;if not rejected then raise exception 'Non-admin accepted';end if;
 rejected:=false;begin perform public.daily_review(org,actor,day,'begin_transfer',jsonb_build_object('client_id',c1));exception when others then rejected:=true;end;if not rejected then raise exception 'Unlocked transfer accepted';end if;
 -- The save is optimistic; a stale client cannot close a changed day.
 state:=public.daily_review(org,actor,day,'save',body);
 rejected:=false;begin perform public.daily_review(org,actor,day,'lock',body);exception when others then if SQLERRM like 'Grunnlaget er endret%' then rejected:=true;else raise;end if;end;if not rejected then raise exception 'Stale save accepted';end if;
 body:=jsonb_set(body,'{expected}',state->'fingerprint');state:=public.daily_review(org,actor,day,'lock',body);locked_id:=state->>'lock_id';
 if not (state->>'locked')::boolean or jsonb_array_length(state->'allocations')<>2 then raise exception 'Lock or allocation failed';end if;
 if not exists(select 1 from public.weekly_item_approvals where item_id=eid) then raise exception 'Daily approval not reflected in week';end if;
 rejected:=false;begin update public.time_entries set ended_at=ended_at-interval '5 minutes' where id=eid;exception when others then if SQLERRM like 'Dagen er låst%' then rejected:=true;else raise;end if;end;if not rejected then raise exception 'Locked source edited';end if;
 rejected:=false;begin delete from public.transport_allocations where entry_id=eid;exception when others then rejected:=true;end;if not rejected then raise exception 'Locked allocation deleted';end if;
 rejected:=false;begin insert into public.time_entries(organization_id,employee_id,started_at,ended_at,source,created_by) values(org,emp,'2020-01-08 16:00Z','2020-01-08 17:00Z','manual',actor);exception when others then rejected:=true;end;if not rejected then raise exception 'New entry slipped into locked day';end if;
 reservation:=public.daily_review(org,actor,day,'begin_transfer',jsonb_build_object('lock_id',locked_id,'client_id',c1));
 rejected:=false;begin perform public.daily_review(org,actor,day,'begin_transfer',jsonb_build_object('lock_id',locked_id,'client_id',c1));exception when others then rejected:=true;end;if not rejected then raise exception 'Concurrent transfer accepted';end if;
 rejected:=false;begin perform public.daily_review(org,actor,day,'reopen',jsonb_build_object('expected',state->>'fingerprint','reason','Correction'));exception when others then rejected:=true;end;if not rejected then raise exception 'Reopen during transfer accepted';end if;
 state:=public.daily_review(org,actor,day,'finish_transfer',jsonb_build_object('transfer_id',reservation->>'transfer_id','report_id','fixture-report'));
 rejected:=false;begin perform public.daily_review(org,actor,day,'begin_transfer',jsonb_build_object('lock_id',locked_id,'client_id',c1));exception when others then rejected:=true;end;if not rejected then raise exception 'Duplicate transfer accepted';end if;
 week:=public.weekly_review(org,actor,w,'load');week:=public.weekly_review(org,actor,w,'lock_employee',jsonb_build_object('expected',week->>'fingerprint','employee_id',emp));week:=public.weekly_review(org,actor,w,'lock_week',jsonb_build_object('expected',week->>'fingerprint'));
 if not (week->>'locked')::boolean then raise exception 'Week not locked';end if;
 state:=public.daily_review(org,actor,day,'reopen',jsonb_build_object('expected',state->>'fingerprint','reason','Correct a shift'));
 if (state->>'locked')::boolean or not (state->'transfers'->0->>'stale')::boolean then raise exception 'Reopen/transfer warning failed';end if;
 if exists(select 1 from public.weekly_period_locks where organization_id=org and week_start=w and superseded_at is null) or exists(select 1 from public.weekly_employee_locks where organization_id=org and week_start=w and superseded_at is null) then raise exception 'Week locks not invalidated';end if;
 week:=public.weekly_review(org,actor,w,'load');rejected:=false;begin perform public.weekly_review(org,actor,w,'lock_employee',jsonb_build_object('expected',week->>'fingerprint','employee_id',emp));exception when others then if SQLERRM like 'Godkjenn og lås dager%' then rejected:=true;else raise;end if;end;if not rejected then raise exception 'Week locked before daily review';end if;
 body:=jsonb_set(body,'{expected}',state->'fingerprint');state:=public.daily_review(org,actor,day,'lock',body);
 if (state->>'revision')::int<>2 then raise exception 'Revision missing';end if;
 rejected:=false;begin perform public.daily_review(org,actor,day,'begin_transfer',jsonb_build_object('lock_id',state->>'lock_id','client_id',c1));exception when others then rejected:=true;end;if not rejected then raise exception 'Revised day duplicated destination';end if;
 if has_function_privilege('authenticated','public.daily_review(uuid,uuid,date,text,jsonb)','execute') then raise exception 'Browser role can bypass edge';end if;
 if (select count(*) from public.daily_review_locks where organization_id=org and work_date=day)<>2 then raise exception 'History not preserved';end if;
end $test$;
do $corrections$
declare actor uuid; org uuid; emp uuid; eid uuid; state jsonb; body jsonb; rejected boolean;
begin
 select auth_user_id,organization_id into strict actor,org from public.employees where active and role='admin' and portal_actor_only limit 1;
 insert into public.employees(organization_id,employee_number,full_name,email) values(org,'DAILY-OPEN','Open fixture','daily-open@example.invalid') returning id into emp;
 insert into public.time_entries(organization_id,employee_id,started_at,source,created_by) values(org,emp,'2020-01-09 07:00Z','manual',actor) returning id into eid;
 state:=public.daily_review(org,actor,'2020-01-09','load');
 body:=jsonb_build_object('expected',state->>'fingerprint','confirmed',true,'entries',jsonb_build_array(jsonb_build_object('id',eid,'started_at','2020-01-09T07:00:00Z','ended_at',null,'rows','[]'::jsonb)));
 rejected:=false;begin perform public.daily_review(org,actor,'2020-01-09','lock',body);exception when others then if SQLERRM like 'Avslutt alle%' then rejected:=true;else raise;end if;end;if not rejected then raise exception 'Open entry locked';end if;
 body:=jsonb_set(body,'{entries,0,ended_at}','"2020-01-09T15:00:00Z"');
 rejected:=false;begin perform public.daily_review(org,actor,'2020-01-09','lock',body);exception when others then if SQLERRM like 'Oppgi begrunnelse%' then rejected:=true;else raise;end if;end;if not rejected then raise exception 'Correction without reason';end if;
 body:=jsonb_set(body,'{entries,0,reason}','"Forgot clock out"');
 rejected:=false;begin perform public.daily_review(org,actor,'2020-01-09','lock',body);exception when others then if SQLERRM like 'Forklar timer%' then rejected:=true;else raise;end if;end;if not rejected then raise exception 'Unallocated work silently discarded';end if;
 body:=jsonb_set(body,'{entries,0,allocation_note}','"Internal training, not billable"');state:=public.daily_review(org,actor,'2020-01-09','lock',body);
 if not (state->>'locked')::boolean or not exists(select 1 from public.audit_logs where actor_id=actor and entity_id=eid::text and action='daily_correct') then raise exception 'Correct/approve audit failed';end if;
 rejected:=false;begin perform public.daily_review(gen_random_uuid(),actor,'2020-01-09','load');exception when others then if SQLERRM='Kun administrator har tilgang.' then rejected:=true;else raise;end if;end;if not rejected then raise exception 'Cross-company access';end if;
end $corrections$;
rollback;
select 'PASS: daily save/lock, multi-client allocation, optimistic concurrency, source guards, weekly approval and reopen, transfer reservation/idempotency, stale warning, revision history and permissions; rolled back' as result;
