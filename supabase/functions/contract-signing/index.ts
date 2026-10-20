import {createClient} from 'npm:@supabase/supabase-js@2.116.0';
import {contractPdf} from '../_shared/contract-pdf.ts';
const json=(data:unknown,status=200)=>new Response(JSON.stringify(data),{status,headers:{'Content-Type':'application/json','Cache-Control':'no-store'}});
const uuid=(v:unknown)=>typeof v==='string'&&/^[a-f0-9-]{36}$/.test(v);
Deno.serve(async(req:Request)=>{
 if(req.method!=='POST')return json({error:'Ingen tilgang.'},405);
 const admin=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false,autoRefreshToken:false}});
 const raw=await req.text();if(raw.length>1900000)return json({error:'PDF-en er for stor for testoverføringen.'},413);
 const {data:claims,error:verifyError}=await admin.rpc('verify_tid_bridge',{p_token:req.headers.get('x-tid-bridge')||'',p_body:raw,p_method:'POST',p_path:'/contract-signing'});
 if(verifyError||claims?.role!=='admin')return json({error:'Ugyldig portalkobling.'},401);
 // This sandbox feature is available only in the operator's workspace.
 if(claims.companyId!=='368991ee-41c6-4417-8d61-53d8072820b2')return json({error:'Testsignering er ikke tilgjengelig her.'},403);
 try{
  const body=JSON.parse(raw);
  const {data:org}=await admin.from('organizations').select('id,name').eq('portal_company_id',claims.companyId).single();
  const {data:actor}=await admin.rpc('resolve_tid_actor',{p_company:claims.companyId,p_actor:claims.actorId});
  if(!org||!actor)return json({error:'Ingen tilgang.'},403);
  const {data:me}=await admin.from('employees').select('id').eq('organization_id',org.id).eq('auth_user_id',actor).eq('role','admin').eq('active',true).maybeSingle();
  if(!me)return json({error:'Ingen tilgang.'},403);
  if(body.action==='list'){
   const {data,error}=await admin.from('hr_signing_requests').select('id,contract_id,state,created_at,updated_at,signed_path').eq('organization_id',org.id).order('created_at',{ascending:false}).limit(500);
   if(error)throw Error('Kunne ikke hente signeringsstatus.');return json({requests:data});
  }
  if(body.action==='acquire'){
   if(!uuid(body.contract_id)||!uuid(body.lease))return json({error:'Ugyldig kontrakt.'},400);
   const {data:r,error}=await admin.rpc('hr_signing_acquire',{p_org:org.id,p_actor:actor,p_contract:body.contract_id,p_expected:body.expected||null,p_lease:body.lease,p_input:body.input||{}});
   if(error)throw Error(error.message);
   // Persist exactly one immutable, visibly marked sandbox PDF before uploading to Signicat.
   if(!r.original_path){
    const pdf=await contractPdf(r.contract,r.contract.locked_employee_snapshot,r.contract.locked_employer_name||org.name,true);
    const path=`${org.id}/signicat-sandbox/${r.id}/original.pdf`;
    const bytes=Uint8Array.from(atob(pdf),c=>c.charCodeAt(0));
    const upload=await admin.storage.from('hr-documents').upload(path,bytes,{contentType:'application/pdf',upsert:true});if(upload.error)throw Error('Kunne ikke arkivere testkontrakten.');
    const saved=await admin.rpc('hr_signing_checkpoint',{p_org:org.id,p_id:r.id,p_lease:body.lease,p_state:r.state,p_original:path});if(saved.error)throw Error('Kunne ikke lagre PDF-referansen.');
    r.original_path=path;
   }
   const {data:file,error:downloadError}=await admin.storage.from('hr-documents').download(r.original_path);if(downloadError||!file)throw Error('Kunne ikke hente testkontrakten.');
   const bytes=new Uint8Array(await file.arrayBuffer());let binary='';for(let i=0;i<bytes.length;i+=8192)binary+=String.fromCharCode(...bytes.slice(i,i+8192));
   return json({...r,contract:undefined,pdf_base64:btoa(binary),title:r.contract.title});
  }
  if(body.action==='checkpoint'){
   if(!uuid(body.id)||!uuid(body.lease)||!body.state)return json({error:'Ugyldig signeringsstatus.'},400);
   let signedPath:string|undefined;
   if(body.signed_pdf){
    // Verify the lease before any storage write; only the authenticated bridge may submit provider output.
    const {data:r}=await admin.from('hr_signing_requests').select('id').eq('id',body.id).eq('organization_id',org.id).eq('lease',body.lease).gt('lease_until',new Date().toISOString()).maybeSingle();if(!r)throw Error('Signeringen er endret. Oppdater status.');
    const bytes=Uint8Array.from(atob(body.signed_pdf),c=>c.charCodeAt(0));
    if(bytes.length<5||bytes.length>1300000||new TextDecoder().decode(bytes.slice(0,5))!=='%PDF-')throw Error('Signert PDF kunne ikke valideres.');
    signedPath=`${org.id}/signicat-sandbox/${body.id}/signed.pdf`;
    const upload=await admin.storage.from('hr-documents').upload(signedPath,bytes,{contentType:'application/pdf',upsert:true});if(upload.error)throw Error('Kunne ikke arkivere signert PDF.');
   }
   const {data,error}=await admin.rpc('hr_signing_checkpoint',{p_org:org.id,p_id:body.id,p_lease:body.lease,p_state:body.state,p_signed:signedPath||null,p_release:body.release===true});
   if(error)throw Error('Signeringen er endret. Oppdater status.');return json(data);
  }
  return json({error:'Ukjent handling.'},400);
 }catch(error){return json({error:error instanceof Error?error.message:'Kunne ikke behandle signeringen.'},409);}
});
