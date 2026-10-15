-- Only the selected company's administrator can see the current attendance list.
CREATE FUNCTION public.company_live_attendance(p_actor uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE org uuid; result jsonb; at_time timestamptz:=now(); local_day date:=(now() AT TIME ZONE 'Europe/Oslo')::date;
BEGIN
 SELECT organization_id INTO org FROM public.employees WHERE auth_user_id=p_actor AND active AND role='admin';
 IF org IS NULL THEN RAISE EXCEPTION 'Kun administrator har tilgang.' USING ERRCODE='42501'; END IF;
 WITH latest AS (
  SELECT DISTINCT ON(t.employee_id) t.employee_id,e.full_name,e.employee_number,t.started_at,t.ended_at
  FROM public.time_entries t JOIN public.employees e ON e.id=t.employee_id AND e.organization_id=t.organization_id
  WHERE t.organization_id=org AND t.kind='work' AND NOT e.portal_actor_only
   AND t.started_at<=at_time AND (t.ended_at IS NULL OR t.ended_at>=local_day::timestamp AT TIME ZONE 'Europe/Oslo')
  ORDER BY t.employee_id,(t.ended_at IS NULL OR t.ended_at>at_time) DESC,t.started_at DESC,t.id DESC
 ), rows AS (
  SELECT employee_id,full_name,employee_number,started_at,
   CASE WHEN ended_at>at_time THEN NULL ELSE ended_at END AS ended_at,
   ended_at IS NULL OR ended_at>at_time AS present FROM latest
 )
 SELECT jsonb_build_object('date',local_day,'updated_at',at_time,
  'present_count',count(*) FILTER(WHERE present),'out_count',count(*) FILTER(WHERE NOT present),
  'employees',coalesce(jsonb_agg(jsonb_build_object('employee_id',employee_id,'full_name',full_name,'employee_number',employee_number,'started_at',started_at,'ended_at',ended_at,'status',CASE WHEN present THEN 'in' ELSE 'out' END)
   ORDER BY present DESC,CASE WHEN present THEN started_at END,CASE WHEN NOT present THEN ended_at END DESC,full_name,employee_id),'[]'::jsonb)) INTO result FROM rows;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.company_live_attendance(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.company_live_attendance(uuid) TO service_role;
