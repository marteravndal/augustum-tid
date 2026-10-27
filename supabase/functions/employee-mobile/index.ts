import {createClient} from 'npm:@supabase/supabase-js@2.116.0';
import {validReply,visibleCases,latestSharedPlans} from './policy.ts';
const json=(body:unknown,status=200)=>Response.json(body,{status,headers:{'Cache-Control':'private, no-store'}});
Deno.serve(async(req:Request)=>{
 if(!['GET','POST'].includes(req.method))return json({error:'Ugyldig handling.'},405);
 const token=req.headers.get('authorization');if(!token?.startsWith('Bearer '))return json({error:'Logg inn på nytt.'},401);
 const admin=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false,autoRefreshToken:false}});
 const {data:auth,error:authError}=await admin.auth.getUser(token.slice(7));
 if(authError||!auth.user)return json({error:'Ugyldig innlogging.'},401);
 const {data:me,error:meError}=await admin.from('employees').select('id,organization_id,active,portal_actor_only').eq('auth_user_id',auth.user.id).maybeSingle();
 if(meError||!me?.active||me.portal_actor_only)return json({error:'Ingen aktiv ansattprofil.'},403);
 try{
  const section=new URL(req.url).searchParams.get('section');
  if(req.method==='GET'&&section==='absence'){
   const {data,error}=await admin.from('sick_leave_requests').select('id,absence_type,start_date,end_date,status,created_at').eq('organization_id',me.organization_id).eq('employee_id',me.id).is('cancelled_at',null).order('created_at',{ascending:false}).limit(500);
   if(error)throw error;return json({requests:data||[]});
  }
  if(req.method==='GET'&&section==='followup'){
   const {data:cases,error:caseError}=await admin.from('sick_followup_cases').select('id,start_date,current_end_date,status').eq('organization_id',me.organization_id).eq('employee_id',me.id).order('start_date',{ascending:false});
   if(caseError)throw caseError;
   const ids=(cases||[]).map(c=>c.id);if(!ids.length)return json({cases:[],plans:[],activities:[]});
   const [plans,activities]=await Promise.all([
    admin.from('sick_followup_plans').select('id,case_id,version,ordinary_tasks,work_ability,accommodation_options,agreed_measures,external_assistance,return_goal,next_review_date,employee_shared_at').eq('organization_id',me.organization_id).in('case_id',ids).not('employee_shared_at','is',null).order('version',{ascending:false}),
    admin.from('sick_followup_activities').select('id,case_id,activity_type,occurred_on,title,summary,employee_shared_at').eq('organization_id',me.organization_id).in('case_id',ids).not('employee_shared_at','is',null).order('created_at',{ascending:true})
   ]);
   if(plans.error||activities.error)throw plans.error||activities.error;
   return json({cases:visibleCases(cases||[],plans.data||[],activities.data||[]),plans:latestSharedPlans(plans.data||[]),activities:activities.data||[]});
  }
  if(req.method==='POST'&&section==='reply'){
   const raw=await req.text();if(raw.length>12000)return json({error:'Svaret er for langt.'},413);
   let body;try{body=validReply(JSON.parse(raw));}catch{return json({error:'Kontroller oppfølgingssak og svar.'},400);}
   const {data:ownCase,error:ownError}=await admin.from('sick_followup_cases').select('id,status').eq('id',body.case_id).eq('organization_id',me.organization_id).eq('employee_id',me.id).maybeSingle();
   if(ownError)throw ownError;if(!ownCase||ownCase.status!=='active')return json({error:'Denne oppfølgingssaken er ikke tilgjengelig for svar.'},403);
   const [plan,message]=await Promise.all([
    admin.from('sick_followup_plans').select('id').eq('organization_id',me.organization_id).eq('case_id',ownCase.id).not('employee_shared_at','is',null).limit(1),
    admin.from('sick_followup_activities').select('id').eq('organization_id',me.organization_id).eq('case_id',ownCase.id).not('employee_shared_at','is',null).limit(1)
   ]);
   if(plan.error||message.error)throw plan.error||message.error;
   if(!plan.data?.length&&!message.data?.length)return json({error:'Leder må dele oppfølgingen med deg først.'},403);
   const existing=await admin.from('sick_followup_activities').select('id,summary').eq('id',body.request_id).eq('organization_id',me.organization_id).eq('case_id',ownCase.id).eq('created_by',auth.user.id).eq('activity_type','employee_response').maybeSingle();
   if(existing.error)throw existing.error;
   if(existing.data)return existing.data.summary===body.message?json({saved:true,id:existing.data.id}):json({error:'Denne forespørselen er allerede brukt.'},409);
   const now=new Date(),today=new Intl.DateTimeFormat('sv-SE',{timeZone:'Europe/Oslo'}).format(now);
   const saved=await admin.from('sick_followup_activities').insert({id:body.request_id,organization_id:me.organization_id,case_id:ownCase.id,activity_type:'employee_response',occurred_on:today,title:'Tilbakemelding fra ansatt',summary:body.message,created_by:auth.user.id,employee_shared_at:now.toISOString()}).select('id').single();
   if(saved.error){if(saved.error.code==='23505')return json({error:'Svaret kan allerede være lagret. Oppdater oppfølgingen før du prøver igjen.'},409);throw saved.error;}
   await admin.from('audit_logs').insert({organization_id:me.organization_id,actor_id:auth.user.id,action:'employee_followup_reply',entity_type:'sick_followup_case',entity_id:ownCase.id,details:{activity_id:saved.data.id}});
   return json({saved:true,id:saved.data.id},201);
  }
  return json({error:'Ugyldig handling.'},404);
 }catch{return json({error:'Kunne ikke hente eller lagre opplysningene. Oppdater siden før du prøver igjen.'},503);}
});
