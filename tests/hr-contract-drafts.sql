begin;
do $test$
declare actor uuid; org uuid; emp uuid; cid uuid; stamp timestamptz; result jsonb; rejected boolean;
begin
 select auth_user_id,organization_id into strict actor,org from public.employees where active and role='admin' and portal_actor_only limit 1;
 insert into public.employees(organization_id,employee_number,full_name,email,portal_employee_id)
 values(org,'CONTRACT-FIXTURE','Contract fixture','contract@example.invalid',gen_random_uuid()) returning id into emp;
 insert into public.hr_contracts(organization_id,employee_id,title,modules,created_by)
 values(org,emp,'Fixture agreement','[{"id":"one","title":"Work","body":"Original","active":true}]',actor) returning id,updated_at into cid,stamp;
 rejected:=false;begin perform public.hr_contract_draft_action(org,gen_random_uuid(),cid,stamp,'delete_contract');exception when others then if SQLERRM='Kun administrator har tilgang.' then rejected:=true;else raise;end if;end;if not rejected then raise exception 'Nonadmin allowed';end if;
 rejected:=false;begin perform public.hr_contract_draft_action(gen_random_uuid(),actor,cid,stamp,'delete_contract');exception when others then rejected:=true;end;if not rejected then raise exception 'Cross-company allowed';end if;
 result:=public.hr_contract_draft_action(org,actor,cid,stamp,'update_contract','{"title":"Edited agreement","modules":[{"id":"one","title":"Work","body":"Edited","active":true}],"email":"forged@example.invalid"}');
 rejected:=false;begin perform public.hr_contract_draft_action(org,actor,cid,stamp,'delete_contract');exception when others then if SQLERRM like 'Kontrakten er endret%' then rejected:=true;else raise;end if;end;if not rejected then raise exception 'Stale delete allowed';end if;
 select updated_at into stamp from public.hr_contracts where id=cid;
 result:=public.hr_contract_draft_action(org,actor,cid,stamp,'prepare_signing','{"email":"forged@example.invalid"}');
 if result->>'email_sent'<>'false' or result->'contract'->>'status'<>'signing_ready' then raise exception 'Wrong preparation state';end if;
 if not exists(select 1 from public.hr_contracts where id=cid and locked_employee_snapshot->>'email'='contract@example.invalid' and locked_modules->0->>'body'='Edited' and provider_reference is null and signed_at is null and signing_method='bankid') then raise exception 'Snapshot or recipient wrong';end if;
 select updated_at into stamp from public.hr_contracts where id=cid;
 rejected:=false;begin perform public.hr_contract_draft_action(org,actor,cid,stamp,'delete_contract');exception when others then rejected:=true;end;if not rejected then raise exception 'Non-draft deleted';end if;
 rejected:=false;begin perform public.hr_contract_draft_action(org,actor,cid,stamp,'update_contract','{"title":"Bad"}');exception when others then rejected:=true;end;if not rejected then raise exception 'Prepared edited';end if;
 result:=public.hr_contract_draft_action(org,actor,cid,stamp,'return_to_draft');
 if not exists(select 1 from public.hr_contracts where id=cid and status='draft' and locked_modules is null and locked_at is null) then raise exception 'Return failed';end if;
 select updated_at into stamp from public.hr_contracts where id=cid;
 result:=public.hr_contract_draft_action(org,actor,cid,stamp,'prepare_signing');
 update public.hr_contracts set status='pending_signature',provider_reference='fixture' where id=cid;
 select updated_at into stamp from public.hr_contracts where id=cid;
 rejected:=false;begin perform public.hr_contract_draft_action(org,actor,cid,stamp,'return_to_draft');exception when others then rejected:=true;end;if not rejected then raise exception 'Sent contract reopened';end if;
 update public.hr_contracts set status='draft',provider_reference=null where id=cid;
 select updated_at into stamp from public.hr_contracts where id=cid;
 result:=public.hr_contract_draft_action(org,actor,cid,stamp,'delete_contract');
 if exists(select 1 from public.hr_contracts where id=cid) then raise exception 'Delete failed';end if;
 if not exists(select 1 from public.audit_logs where entity_id=cid::text and action='delete_contract') then raise exception 'Missing audit';end if;
 if has_function_privilege('authenticated','public.hr_contract_draft_action(uuid,uuid,uuid,timestamptz,text,jsonb)','execute') then raise exception 'Client bypass';end if;
end $test$;
rollback;
select 'PASS: contract lifecycle, stale writes, organization/admin boundaries, trusted recipient snapshot, audit, provider states protected' as result;
