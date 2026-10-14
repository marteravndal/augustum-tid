import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.116.0";
const cors={"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, apikey, content-type","Access-Control-Allow-Methods":"GET, POST, OPTIONS","Content-Type":"application/json","Cache-Control":"no-store"};
const json=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:cors});
export async function findAddresses(query:string){
 const url=new URL('https://api.kartverket.no/adresser/v1/sok');
 url.search=new URLSearchParams({sok:query,treffPerSide:'10',utkoordsys:'4258'}).toString();
 const response=await fetch(url,{signal:AbortSignal.timeout(10000)});
 if(!response.ok)throw new Error('Adresseoppslaget er utilgjengelig. Prøv igjen.');
 const data=await response.json();
 return (data.adresser||[]).filter((a:any)=>Number.isFinite(a.representasjonspunkt?.lat)&&Number.isFinite(a.representasjonspunkt?.lon)).map((a:any)=>({
  id:[a.kommunenummer,a.adressekode,a.nummer,a.bokstav||'',a.undernummer||''].join(':'),
  address:`${a.adressetekst}, ${a.postnummer} ${a.poststed}`,
  latitude:a.representasjonspunkt.lat,longitude:a.representasjonspunkt.lon,
 }));
}
Deno.serve(async(req:Request)=>{
 if(req.method==='OPTIONS')return new Response('ok',{headers:cors});
 if(!['GET','POST'].includes(req.method))return json({error:'Handling støttes ikke.'},405);
 const auth=req.headers.get('Authorization');if(!auth?.startsWith('Bearer '))return json({error:'Mangler innlogging.'},401);
 const admin=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false}});
 const {data:user,error:authError}=await admin.auth.getUser(auth.slice(7));if(authError||!user.user)return json({error:'Ugyldig innlogging.'},401);
 const {data:me}=await admin.from('employees').select('organization_id,role,active').eq('auth_user_id',user.user.id).maybeSingle();
 if(!me?.active||me.role!=='admin')return json({error:'Kun administrator kan endre stemplingssted.'},403);
 if(req.method==='GET'){
  const {data,error}=await admin.from('worksites').select('id,name,address,latitude,longitude,radius_meters,position_required').eq('organization_id',me.organization_id).eq('active',true).order('created_at').order('id').limit(1).maybeSingle();
  return error?json({error:'Stemplingsstedet kunne ikke hentes.'},503):json({worksite:data});
 }
 let body:any;try{body=await req.json()}catch{return json({error:'Ugyldig forespørsel.'},400)}
 if(!body||!['search','save'].includes(body.action)||typeof body.query!=='string'||body.query.trim().length<3||body.query.length>200)return json({error:'Skriv gateadresse, husnummer og poststed.'},400);
 try{
  // Resolve again on save: never accept browser-provided coordinates, radius or company.
  const addresses=await findAddresses(body.query.trim());
  if(body.action==='search')return json({addresses});
  const selected=addresses.find((address:any)=>address.id===body.address_id);
  if(!selected)return json({error:'Velg en adresse fra søkeresultatene. Søk på nytt hvis adressen er endret.'},409);
  const {data,error}=await admin.rpc('save_company_clock_location',{p_actor:user.user.id,p_address:selected.address,p_latitude:selected.latitude,p_longitude:selected.longitude});
  if(error)return json({error:'Stemplingsstedet kunne ikke lagres. Prøv igjen.'},409);
  return json({worksite:data});
 }catch{return json({error:'Adresseoppslaget er utilgjengelig. Prøv igjen om litt.'},503)}
});
