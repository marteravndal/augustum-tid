import {createClient} from 'npm:@supabase/supabase-js@2.116.0';
const json=(data:unknown,status=200)=>new Response(JSON.stringify(data),{status,headers:{'Content-Type':'application/json','Cache-Control':'no-store'}});
Deno.serve(async(req:Request)=>{
 if(req.method!=='POST')return json({error:'Ingen tilgang.'},405);
 const admin=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false,autoRefreshToken:false}});
 const raw=await req.text();if(raw.length>2000000)return json({error:'For stor forespørsel.'},413);
 const {data:claims,error:verifyError}=await admin.rpc('verify_tid_bridge',{p_token:req.headers.get('x-tid-bridge')||'',p_body:raw,p_method:'POST',p_path:'/portal-session'});
 if(verifyError||!claims)return json({error:'Ugyldig portalkobling.'},401);
 try{
  const body=JSON.parse(raw),role=claims.role==='admin'?'admin':body.role==='leder'?'manager':'employee';
  if(role!=='admin'&&!body.identity?.id)return json({error:'Brukeren mangler aktiv tilknytning til ansattregisteret.'},403);
  let {data:org}=await admin.from('organizations').select('*').eq('portal_company_id',claims.companyId).maybeSingle();
  if(!org){const created=await admin.from('organizations').upsert({portal_company_id:claims.companyId,name:claims.companyName},{onConflict:'portal_company_id'}).select().single();if(created.error)throw created.error;org=created.data;}
  const email=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(claims.companyId+':'+claims.actorId)))).map(b=>b.toString(16).padStart(2,'0')).join('')+'@tid-preview.invalid';
  const resolveActor=()=>admin.rpc('resolve_tid_actor',{p_company:claims.companyId,p_actor:claims.actorId});
  let resolved=await resolveActor();if(resolved.error)throw resolved.error;
  if(!resolved.data){
   const created=await admin.auth.admin.createUser({email,email_confirm:true,password:crypto.randomUUID()+crypto.randomUUID(),app_metadata:{role}});
   resolved=await resolveActor();if(resolved.error||!resolved.data)throw created.error||resolved.error||Error('Kunne ikke opprette testbruker.');
  }
  const actor={local_user_id:resolved.data};
  const source=role==='admin'&&Array.isArray(body.employees)?body.employees:body.identity?[body.identity]:[];
  if(source.length>2000)throw Error('For mange ansatte.');
  if(source.length){
   const previous=await admin.from('employees').select('id,role,portal_employee_id').eq('organization_id',org.id).in('portal_employee_id',source.map((e:any)=>e.id));
   if(previous.error)throw previous.error;
   const old=new Map((previous.data||[]).map(e=>[e.portal_employee_id,e]));
   const rows=source.map((e:any)=>({id:old.get(e.id)?.id||e.id,portal_employee_id:e.id,organization_id:org.id,employee_number:e.employee_number||`P-${e.id.slice(0,8)}`,full_name:e.name,email:e.email||`${e.id}@employee.invalid`,phone_number:e.phone||null,active:e.active===true,role:old.get(e.id)?.role||'employee'}));
   const saved=await admin.from('employees').upsert(rows,{onConflict:'id'});if(saved.error)throw saved.error;
  }
  const identity=body.identity?.id;
  let {data:me}=identity?await admin.from('employees').select('*').eq('portal_employee_id',identity).eq('organization_id',org.id).maybeSingle():await admin.from('employees').select('*').eq('auth_user_id',actor.local_user_id).maybeSingle();
  if(!me){const saved=await admin.from('employees').insert({organization_id:org.id,employee_number:`ADMIN-${claims.actorId.slice(0,8)}`,full_name:body.displayName||claims.email,email:claims.email,role,active:true,portal_actor_only:true,auth_user_id:actor.local_user_id}).select().single();if(saved.error){const retry=await admin.from('employees').select('*').eq('auth_user_id',actor.local_user_id).eq('organization_id',org.id).maybeSingle();if(!retry.data)throw saved.error;me=retry.data;}else me=saved.data;}
  const update=await admin.from('employees').update({auth_user_id:actor.local_user_id,role,active:true}).eq('id',me.id);if(update.error)throw update.error;me={...me,auth_user_id:actor.local_user_id,role,active:true};
  const site=await admin.from('worksites').select('id').eq('organization_id',org.id).eq('active',true).limit(1).maybeSingle();
  if(!site.data){const saved=await admin.from('worksites').insert({organization_id:org.id,name:'Transport – test',address:'Mobilt arbeid',position_required:false});if(saved.error)throw saved.error;}
  // generateLink creates a server-side token. It does not send an email.
  const auth=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false,autoRefreshToken:false}});
  let session;
  for(let attempt=0;attempt<3&&!session;attempt++){
   const link=await admin.auth.admin.generateLink({type:'magiclink',email});if(link.error)throw link.error;
   const verified=await auth.auth.verifyOtp({token_hash:link.data.properties.hashed_token,type:'email'});
   session=verified.data.session;
  }
  if(!session)throw Error('Kunne ikke opprette testøkt.');
  return json({access_token:session.access_token,expires_at:session.expires_at,user_id:actor.local_user_id,employee:me,organization:org});
 }catch(error){console.error('Portal session failed',error instanceof Error?error.message:'database error');return json({error:'Kunne ikke klargjøre tidsmodulen. Prøv igjen.'},503);}
});
