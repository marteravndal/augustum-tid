begin;
do $test$
declare actor uuid; org uuid; emp uuid; cid uuid; stamp timestamptz; lease uuid:=gen_random_uuid(); r jsonb; s jsonb; rejected boolean; other uuid:=gen_random_uuid();
begin
 select auth_user_id,organization_id into strict actor,org from public.employees where active and role='admin' and not portal_actor_only and portal_employee_id is not null limit 1;
 insert into public.employees(organization_id,employee_number,full_name,email,portal_employee_id)
 values(org,'SIGN-EMP-FIXTURE','Employee fixture','signing-fixture@example.com',gen_random_uuid()) returning id into emp;
 insert into public.hr_contracts(organization_id,employee_id,title,modules,created_by)
 values(org,emp,'Signing fixture','[{"id":"one","title":"Work","body":"Test only","active":true}]',actor) returning id,updated_at into cid,stamp;
 perform public.hr_contract_draft_action(org,actor,cid,stamp,'prepare_signing');select updated_at into stamp from public.hr_contracts where id=cid;
 rejected:=false;begin perform public.hr_signing_acquire(org,gen_random_uuid(),cid,stamp,lease,'{}');exception when others then rejected:=true;end;if not rejected then raise exception 'Nonadmin allowed';end if;
 rejected:=false;begin perform public.hr_signing_acquire(org,actor,cid,stamp,lease,'{}');exception when others then rejected:=true;end;if not rejected then raise exception 'Missing test identities allowed';end if;
 r:=public.hr_signing_acquire(org,actor,cid,stamp,lease,'{"employee_nin":"11111111111","admin_nin":"22222222222","test_confirmed":true,"client_id":"sandbox-test","notify":false,"email":"attacker@example.com"}');
 if r->'state'->'signers'->0->>'email'<>'signing-fixture@example.com' then raise exception 'Forged recipient accepted';end if;
 if (select status from public.hr_contracts where id=cid)<>'pending_signature' then raise exception 'Contract not locked';end if;
 rejected:=false;begin perform public.hr_signing_acquire(org,actor,cid,stamp,other,'{}');exception when others then rejected:=true;end;if not rejected then raise exception 'Concurrent acquire allowed';end if;
 select updated_at into stamp from public.hr_contracts where id=cid;
 rejected:=false;begin perform public.hr_contract_draft_action(org,actor,cid,stamp,'return_to_draft');exception when others then rejected:=true;end;if not rejected then raise exception 'Signing snapshot editable';end if;
 rejected:=false;begin perform public.hr_signing_checkpoint(org,(r->>'id')::uuid,other,r->'state');exception when others then rejected:=true;end;if not rejected then raise exception 'Wrong lease allowed';end if;
 s:=(r->'state')||'{"phase":"signed","sessions":[{"state":"SIGNED"},{"state":"READY"}]}';
 rejected:=false;begin perform public.hr_signing_checkpoint(org,(r->>'id')::uuid,lease,s,null,'fixture.pdf');exception when others then rejected:=true;end;if not rejected then raise exception 'Partial signing accepted';end if;
 rejected:=false;begin perform public.hr_signing_checkpoint(org,(r->>'id')::uuid,lease,'{"phase":"signed"}',null,'fixture.pdf');exception when others then rejected:=true;end;if not rejected then raise exception 'Missing signature array accepted';end if;
 s:=jsonb_set(s,'{sessions}','[{"state":"SIGNED"},{"state":"SIGNED"}]');
 rejected:=false;begin perform public.hr_signing_checkpoint(org,(r->>'id')::uuid,lease,s);exception when others then rejected:=true;end;if not rejected then raise exception 'Signed without archive';end if;
 perform public.hr_signing_checkpoint(org,(r->>'id')::uuid,lease,s,null,'fixture.pdf',true);
 if (select status from public.hr_contracts where id=cid)<>'signed' then raise exception 'Completion failed';end if;
 if has_table_privilege('authenticated','public.hr_signing_requests','select') or has_function_privilege('authenticated','public.hr_signing_acquire(uuid,uuid,uuid,timestamptz,uuid,jsonb)','execute') or has_function_privilege('anon','public.hr_signing_checkpoint(uuid,uuid,uuid,jsonb,text,text,boolean)','execute') then raise exception 'Browser bypass';end if;
end $test$;
rollback;
select 'PASS: server-only storage, trusted recipients, test confirmation, lease, locked snapshot, two signatures and archived PDF' as result;
