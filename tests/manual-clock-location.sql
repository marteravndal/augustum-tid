begin;
do $test$
declare actor uuid; org uuid; data jsonb; other_before jsonb; other_after jsonb; source text; rejected boolean:=false;
begin
 select auth_user_id,organization_id into strict actor,org from public.employees where active and role='admin' and portal_actor_only limit 1;
 select jsonb_agg(to_jsonb(w) order by id) into other_before from public.worksites w where organization_id<>org;
 data:=public.save_company_clock_location(actor,'Map fixture',58.81275,5.70189,'map');
 if (data->>'radius_meters')::int<>200 or (data->>'position_required')::boolean is not true or (data->>'latitude')::float8<>58.81275 then raise exception 'Manual coordinates/radius/control failed'; end if;
 if not exists(select 1 from public.worksites where id=(data->>'id')::uuid and organization_id=org and active) then raise exception 'Wrong organization'; end if;
 if (select count(*) from public.worksites where organization_id=org and active)<>1 then raise exception 'More than one current site'; end if;
 if not exists(select 1 from public.audit_logs where organization_id=org and actor_id=actor and entity_id=data->>'id' and details->>'source'='map' and details->'after'->>'address'='Map fixture') then raise exception 'Missing map audit source'; end if;
 data:=public.save_company_clock_location(actor,'Position fixture',59,6,'geolocation');
 if not exists(select 1 from public.audit_logs where actor_id=actor and details->>'source'='geolocation' and details->'after'->>'address'='Position fixture') then raise exception 'Missing GPS audit source'; end if;
 data:=public.save_company_clock_location(actor,'Address fixture',59,6);
 if not exists(select 1 from public.audit_logs where actor_id=actor and details->>'source'='Kartverket' and details->'after'->>'address'='Address fixture') then raise exception 'Legacy address save incompatible'; end if;
 select jsonb_agg(to_jsonb(w) order by id) into other_after from public.worksites w where organization_id<>org;
 if other_before is distinct from other_after then raise exception 'Other organization changed'; end if;
 begin perform public.save_company_clock_location(gen_random_uuid(),'Bad actor',59,6,'map'); exception when others then if SQLERRM='Kun administrator kan endre stemplingssted.' then rejected:=true; else raise; end if; end;
 if not rejected then raise exception 'Invalid actor accepted'; end if;
 rejected:=false;
 begin perform public.save_company_clock_location(actor,'Bad coords','NaN'::float8,6,'map'); exception when others then if SQLERRM='Ugyldig adresse eller posisjon.' then rejected:=true; else raise; end if; end;
 if not rejected then raise exception 'NaN accepted'; end if;
 if has_function_privilege('authenticated','public.save_company_clock_location(uuid,text,double precision,double precision,text)','execute') or has_function_privilege('anon','public.save_company_clock_location(uuid,text,double precision,double precision,text)','execute') then raise exception 'Browser RPC access'; end if;
end $test$;
rollback;
select 'PASS: manual/GPS/legacy saves, 200m, company isolation, audit provenance, permissions and invalid coordinates; all changes rolled back' as result;
