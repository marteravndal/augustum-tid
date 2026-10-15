import {createClient} from 'npm:@supabase/supabase-js@2.116.0';
const osloStart=(day:string)=>{const wanted=Date.parse(day+'T00:00:00Z');let t=wanted;for(let i=0;i<3;i++){const wall=new Intl.DateTimeFormat('sv-SE',{timeZone:'Europe/Oslo',year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',hourCycle:'h23'}).format(new Date(t)).replace(' ','T');t+=wanted-Date.parse(wall+'Z');}return new Date(t).toISOString()};
const json=(data:unknown,status=200)=>new Response(JSON.stringify(data),{status,headers:{'content-type':'application/json','cache-control':'no-store'}});
Deno.serve(async(req:Request)=>{
 const token=req.headers.get('authorization')?.replace(/^Bearer /,'');if(!token)return json({error:'Mangler innlogging.'},401);
 const admin=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false}});
 const {data:auth,error}=await admin.auth.getUser(token);if(error||!auth.user)return json({error:'Ugyldig innlogging.'},401);
 const {data:me}=await admin.from('employees').select('organization_id,role,active').eq('auth_user_id',auth.user.id).maybeSingle();if(!me?.active||me.role!=='admin')return json({error:'Kun administrator har tilgang.'},403);
 const date=new URL(req.url).searchParams.get('date');
 if(req.method==='GET'){
  if(!date||!/^\d{4}-\d{2}-\d{2}$/.test(date)||(!Number.isFinite(Date.parse(date))||new Date(date).toISOString().slice(0,10)!==date))return json({error:'Velg dato.'},400);
  const [entries,employees,allocations]=await Promise.all([
   admin.from('time_entries').select('id,employee_id,kind,started_at,ended_at,updated_at,source,note').eq('organization_id',me.organization_id).gte('started_at',osloStart(date)).lt('started_at',osloStart(new Date(Date.parse(date+'T00:00:00Z')+86400000).toISOString().slice(0,10))).order('started_at'),
   admin.from('employees').select('id,portal_employee_id,employee_number,full_name,active').eq('organization_id',me.organization_id).eq('portal_actor_only',false).order('full_name'),
   admin.from('transport_allocations').select('*').eq('organization_id',me.organization_id).gte('started_at',osloStart(date)).lt('started_at',osloStart(new Date(Date.parse(date+'T00:00:00Z')+86400000).toISOString().slice(0,10))).order('started_at')
  ]);
  if(entries.error||employees.error||allocations.error)return json({error:'Kunne ikke hente testtimene.'},503);
  if(entries.data.length>=1000||employees.data.length>=1000||allocations.data.length>=1000)return json({error:'For mange registreringer for denne visningen. Kontakt administrator.'},409);
  return json({entries:entries.data,employees:employees.data,allocations:allocations.data.filter(a=>entries.data.some(e=>e.id===a.entry_id))});
 }
 if(req.method!=='POST')return json({error:'Ukjent handling.'},405);
 try{
  const body=await req.json();
  if(body.action==='create'){
   const a=Date.parse(body.started_at),b=Date.parse(body.ended_at);
   if(!Number.isFinite(a)||!Number.isFinite(b)||b<=a||b-a>24*3600000||b>Date.now()||typeof body.reason!=='string'||body.reason.trim().length<3)return json({error:'Velg avsluttede timer, maks 24 timer, og oppgi begrunnelse.'},400);
   const employee=await admin.from('employees').select('id').eq('id',body.employee_id).eq('organization_id',me.organization_id).eq('active',true).eq('portal_actor_only',false).maybeSingle();if(!employee.data)return json({error:'Velg aktiv ansatt fra fellesregisteret.'},400);
   const overlap=await admin.from('time_entries').select('id').eq('employee_id',body.employee_id).lt('started_at',new Date(b).toISOString()).or(`ended_at.is.null,ended_at.gt.${new Date(a).toISOString()}`).limit(1);if(overlap.error)throw overlap.error;if(overlap.data?.length)return json({error:'Timene overlapper en registrering.'},409);
   const saved=await admin.from('time_entries').insert({organization_id:me.organization_id,employee_id:body.employee_id,kind:'work',source:'manual',started_at:new Date(a).toISOString(),ended_at:new Date(b).toISOString(),note:'TEST: '+body.reason.trim().slice(0,500),created_by:auth.user.id}).select().single();if(saved.error)throw saved.error;
   return json({entry:saved.data});
  }
  if(body.action==='allocate'){
   const result=await admin.rpc('save_transport_allocations',{p_org:me.organization_id,p_actor:auth.user.id,p_entry:body.entry_id,p_expected:body.expected_updated_at,p_rows:body.rows});if(result.error)throw result.error;return json(result.data);
  }
  return json({error:'Ukjent handling.'},400);
 }catch(error){return json({error:(error as {message?:string}).message||'Kunne ikke lagre.'},409);}
});
