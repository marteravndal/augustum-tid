-- One current company clock-in location, preserving historical worksite references.
CREATE FUNCTION public.save_company_clock_location(p_actor uuid,p_address text,p_latitude double precision,p_longitude double precision)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE actor public.employees%ROWTYPE; site public.worksites%ROWTYPE; old_site jsonb;
BEGIN
 SELECT * INTO actor FROM public.employees WHERE auth_user_id=p_actor AND active AND role='admin';
 IF NOT FOUND THEN RAISE EXCEPTION 'Kun administrator kan endre stemplingssted.'; END IF;
 IF p_address IS NULL OR length(trim(p_address)) NOT BETWEEN 3 AND 300 OR p_latitude IS NULL OR p_longitude IS NULL OR NOT(p_latitude BETWEEN -90 AND 90) OR NOT(p_longitude BETWEEN -180 AND 180) THEN RAISE EXCEPTION 'Ugyldig adresse eller posisjon.'; END IF;
 PERFORM 1 FROM public.organizations WHERE id=actor.organization_id FOR UPDATE;
 SELECT * INTO site FROM public.worksites WHERE organization_id=actor.organization_id AND active ORDER BY created_at,id LIMIT 1 FOR UPDATE;
 old_site:=to_jsonb(site);
 IF site.id IS NULL THEN
  INSERT INTO public.worksites(organization_id,name,address,latitude,longitude,radius_meters,position_required)
  VALUES(actor.organization_id,'Bedriftens stemplingssted',trim(p_address),p_latitude,p_longitude,200,true) RETURNING * INTO site;
 ELSE
  UPDATE public.worksites SET name='Bedriftens stemplingssted',address=trim(p_address),latitude=p_latitude,longitude=p_longitude,radius_meters=200,position_required=true WHERE id=site.id RETURNING * INTO site;
 END IF;
 UPDATE public.worksites SET active=false WHERE organization_id=actor.organization_id AND active AND id<>site.id;
 INSERT INTO public.audit_logs(organization_id,actor_id,action,entity_type,entity_id,details)
 VALUES(actor.organization_id,p_actor,'set_clock_location','worksite',site.id::text,jsonb_build_object('before',old_site,'after',to_jsonb(site),'source','Kartverket'));
 RETURN jsonb_build_object('id',site.id,'name',site.name,'address',site.address,'latitude',site.latitude,'longitude',site.longitude,'radius_meters',site.radius_meters,'position_required',site.position_required);
END $$;
REVOKE ALL ON FUNCTION public.save_company_clock_location(uuid,text,double precision,double precision) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.save_company_clock_location(uuid,text,double precision,double precision) TO service_role;
