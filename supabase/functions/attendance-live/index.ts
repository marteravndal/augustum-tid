import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.116.0";
const headers={"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, apikey, content-type","Access-Control-Allow-Methods":"GET, OPTIONS","Content-Type":"application/json","Cache-Control":"no-store"};
const json=(data:unknown,status=200)=>new Response(JSON.stringify(data),{status,headers});
Deno.serve(async(req:Request)=>{
 if(req.method==='OPTIONS')return new Response('ok',{headers});
 if(req.method!=='GET')return json({error:'Handling støttes ikke.'},405);
 const auth=req.headers.get('Authorization');if(!auth?.startsWith('Bearer '))return json({error:'Mangler innlogging.'},401);
 try{
  const admin=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false}});
  const {data:user,error:authError}=await admin.auth.getUser(auth.slice(7));if(authError||!user.user)return json({error:'Ugyldig innlogging.'},401);
  // The database derives company and verifies active administrator membership.
  const {data,error}=await admin.rpc('company_live_attendance',{p_actor:user.user.id});
  if(error)return json({error:error.code==='42501'?'Kun administrator har tilgang.':'Kunne ikke hente stemplinger.'},error.code==='42501'?403:503);
  return json(data);
 }catch{return json({error:'Kunne ikke hente stemplinger. Prøv igjen.'},503)}
});
