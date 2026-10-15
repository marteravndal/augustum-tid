import {createClient} from 'npm:@supabase/supabase-js@2.116.0';
const json=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{'content-type':'application/json','cache-control':'no-store'}});
Deno.serve(async(req:Request)=>{
 if(!['GET','POST'].includes(req.method))return json({error:'Ukjent handling.'},405);
 const token=req.headers.get('authorization')?.replace(/^Bearer /,'');if(!token)return json({error:'Mangler innlogging.'},401);
 const admin=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false}});
 const {data:auth,error:authError}=await admin.auth.getUser(token);if(authError||!auth.user)return json({error:'Ugyldig innlogging.'},401);
 const {data:me}=await admin.from('employees').select('organization_id,role,active').eq('auth_user_id',auth.user.id).maybeSingle();if(!me?.active||me.role!=='admin')return json({error:'Kun administrator har tilgang.'},403);
 try{
  const body=req.method==='GET'?{action:'load',date:new URL(req.url).searchParams.get('date')}:await req.json();
  if(!body||typeof body.date!=='string'||!/^\d{4}-\d{2}-\d{2}$/.test(body.date)||!Number.isFinite(Date.parse(body.date))||new Date(body.date).toISOString().slice(0,10)!==body.date)return json({error:'Velg gyldig dato.'},400);
  const {data,error}=await admin.rpc('daily_review',{p_org:me.organization_id,p_actor:auth.user.id,p_day:body.date,p_action:body.action,p_body:body});
  if(error)return json({error:error.code==='P0001'?error.message:'Dagskontrollen kunne ikke oppdateres. Kontroller valgene og prøv igjen.'},409);
  return json(data);
 }catch{return json({error:'Ugyldig forespørsel.'},400)}
});
