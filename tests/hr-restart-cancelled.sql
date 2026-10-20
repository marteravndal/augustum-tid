begin;
do $test$
declare actor uuid; org uuid; emp uuid; source uuid; stamp timestamptz; r jsonb; again jsonb; child public.hr_contracts; rejected boolean; invalid_state text;
begin
 select auth_user_id,organization_id into strict actor,org from public.employees where active and role='admin' and not portal_actor_only and portal_employee_id is not null limit 1;
 insert into public.employees(organization_id,employee_number,full_name,email,portal_employee_id)
 values(org,'RESTART-FIXTURE','Restart fixture','restart-fixture@example.com',gen_random_uuid()) returning id into emp;
 insert into public.hr_contracts(organization_id,employee_id,title,content,modules,locked_content,locked_modules,status,provider,created_by)
 values(org,emp,'Cancelled fixture','Editable text','[]','Frozen text','[{"id":"one","title":"Work","body":"Frozen body","active":true}]','cancelled','signicat_sandbox',actor) returning id,updated_at into source,stamp;
 -- Local status alone must not allow a retry before provider cancellation is confirmed.
 rejected:=false;begin perform public.hr_restart_cancelled_contract(org,actor,source,stamp);exception when others then rejected:=true;end;if not rejected then raise exception 'Missing cancellation accepted';end if;
 insert into public.hr_signing_requests(organization_id,contract_id,actor_id,state) values(org,source,actor,'{"phase":"cancelled"}');
 rejected:=false;begin perform public.hr_restart_cancelled_contract(org,gen_random_uuid(),source,stamp);exception when others then rejected:=true;end;if not rejected then raise exception 'Nonadmin allowed';end if;
 rejected:=false;begin perform public.hr_restart_cancelled_contract(gen_random_uuid(),actor,source,stamp);exception when others then rejected:=true;end;if not rejected then raise exception 'Other tenant allowed';end if;
 rejected:=false;begin perform public.hr_restart_cancelled_contract(org,actor,source,stamp-interval '1 second');exception when others then rejected:=true;end;if not rejected then raise exception 'Stale revision allowed';end if;
 foreach invalid_state in array array['draft','signing_ready','pending_signature','signed'] loop
  update public.hr_contracts set status=invalid_state where id=source;
  rejected:=false;begin perform public.hr_restart_cancelled_contract(org,actor,source,stamp);exception when others then rejected:=true;end;if not rejected then raise exception 'Active or signed contract allowed';end if;
 end loop;
 update public.hr_contracts set status='cancelled' where id=source;
 update public.employees set active=false where id=emp;
 rejected:=false;begin perform public.hr_restart_cancelled_contract(org,actor,source,stamp);exception when others then rejected:=true;end;if not rejected then raise exception 'Inactive recipient allowed';end if;
 update public.employees set active=true where id=emp;
 r:=public.hr_restart_cancelled_contract(org,actor,source,stamp);
 again:=public.hr_restart_cancelled_contract(org,actor,source,stamp);
 if r->'contract'->>'id' is distinct from again->'contract'->>'id' or again->>'existing'<>'true' then raise exception 'Duplicate retry created';end if;
 select * into strict child from public.hr_contracts where id=(r->'contract'->>'id')::uuid;
 if child.status<>'draft' or child.version<>2 or child.content<>'Frozen text' or child.modules->0->>'body'<>'Frozen body' or child.restarted_from_id<>source then raise exception 'Wrong copy';end if;
 if child.provider is not null or child.provider_reference is not null or child.signed_at is not null or child.locked_modules is not null or exists(select 1 from public.hr_signing_requests where contract_id=child.id) then raise exception 'Copied signing state';end if;
 if (select status from public.hr_contracts where id=source)<>'cancelled' or (select state->>'phase' from public.hr_signing_requests where contract_id=source)<>'cancelled' then raise exception 'Original modified';end if;
 -- New draft follows the ordinary review/preparation path and resolves the current register again.
 perform public.hr_contract_draft_action(org,actor,child.id,child.updated_at,'prepare_signing');
 if (select status from public.hr_contracts where id=child.id)<>'signing_ready' then raise exception 'Cannot prepare new draft';end if;
 if has_function_privilege('anon','public.hr_restart_cancelled_contract(uuid,uuid,uuid,timestamptz)','execute') or has_function_privilege('authenticated','public.hr_restart_cancelled_contract(uuid,uuid,uuid,timestamptz)','execute') then raise exception 'Browser bypass';end if;
end $test$;
rollback;
select 'PASS: authorized confirmed cancellation, immutable original, single new draft, fresh review, no signing request created' as result;
