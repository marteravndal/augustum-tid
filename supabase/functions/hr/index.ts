import { previewEmail } from "../_shared/preview-email.ts";
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { repairPendingDiplomas } from "../_shared/course-diplomas.ts";
import { createClient } from "npm:@supabase/supabase-js@2.116.0";
import {contractPdf} from "../_shared/contract-pdf.ts";

const cors={"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, apikey, content-type","Access-Control-Allow-Methods":"GET, POST, PATCH, DELETE, OPTIONS","Content-Type":"application/json"};
const json=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:cors});
const esc=(value:unknown)=>String(value??"").replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]!));
const sendEmail=async(to:string,subject:string,html:string)=>{const key=Deno.env.get("RESEND_API_KEY");if(!key)return false;try{return (await previewEmail("https://api.resend.com/emails",{method:"POST",headers:{Authorization:`Bearer ${key}`,"Content-Type":"application/json"},body:JSON.stringify({from:"Augustum Tid <post@augustum.no>",to:[to],subject,html})})).ok}catch{return false}};
type ContractModule={id:string;title:string;body:string;active:boolean};
const cleanModules=(value:unknown):ContractModule[]=>{if(!Array.isArray(value))return[];return value.slice(0,40).map((m:any)=>({id:String(m?.id||crypto.randomUUID()).slice(0,80),title:String(m?.title||"").trim().slice(0,200),body:String(m?.body||"").trim().slice(0,12000),active:m?.active!==false})).filter(m=>m.title.length>=1&&m.body.length>=1)};

Deno.serve(async(req:Request)=>{
  if(req.method==="OPTIONS")return new Response("ok",{headers:cors});
  const auth=req.headers.get("Authorization");if(!auth?.startsWith("Bearer "))return json({error:"Mangler innlogging."},401);
  const admin=createClient(Deno.env.get("SUPABASE_URL")!,Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,{auth:{persistSession:false}});
  const {data:authData,error:authError}=await admin.auth.getUser(auth.slice(7));if(authError||!authData.user)return json({error:"Ugyldig innlogging."},401);
  const {data:me}=await admin.from("employees").select("id,organization_id,role,active,full_name,email,portal_employee_id,portal_actor_only").eq("auth_user_id",authData.user.id).maybeSingle();if(!me?.active)return json({error:"Brukeren er ikke aktiv."},403);

  if(req.method==="GET"){
    await repairPendingDiplomas(admin,me);
    let docs=admin.from("hr_documents").select("id,employee_id,batch_id,title,document_type,original_name,mime_type,size_bytes,requires_signature,signature_status,read_at,signed_at,created_at,storage_path,employees(employee_number,full_name,email)").eq("organization_id",me.organization_id).order("created_at",{ascending:false});
    let contracts=admin.from("hr_contracts").select("id,employee_id,title,content,locked_content,modules,locked_modules,status,version,signing_method,locked_at,signed_at,created_at,updated_at,employees(employee_number,full_name,email,phone_number)").eq("organization_id",me.organization_id).order("updated_at",{ascending:false});
    if(me.role!=="admin"){docs=docs.eq("employee_id",me.id);contracts=contracts.eq("employee_id",me.id).in("status",["locked","pending_signature","signed","cancelled"])}
    const [{data:docRows,error:docError},{data:contractRows,error:contractError},{data:staff,error:staffError}]=await Promise.all([docs,contracts,me.role==="admin"?admin.from("employees").select("id,employee_number,full_name,email,phone_number").eq("organization_id",me.organization_id).eq("active",true).eq("portal_actor_only",false).not("portal_employee_id","is",null).order("full_name"):Promise.resolve({data:[],error:null})]);
    if(docError||contractError||staffError)return json({error:docError?.message||contractError?.message||staffError?.message},400);
    const documents=await Promise.all((docRows||[]).map(async(row:any)=>{const {data}=await admin.storage.from("hr-documents").createSignedUrl(row.storage_path,900);const {storage_path,...safe}=row;return{...safe,url:data?.signedUrl||null}}));
    // Recipients are resolved from the current shared register, never from browser-supplied names/emails.
    const matches=(staff||[]).filter((e:any)=>me.portal_employee_id?e.id===me.id:e.email?.toLowerCase()===me.email?.toLowerCase());
    const adminSigner=matches.length===1?matches[0]:null;
    return json({documents,contracts:contractRows||[],employees:staff||[],admin_signer:adminSigner,is_admin:me.role==="admin",signing_provider_configured:false,signing_available:false});
  }

  let body:Record<string,unknown>;try{body=await req.json()}catch{return json({error:"Ugyldig forespørsel."},400)}const action=String(body.action||"");
  if(req.method==="PATCH"&&action==="mark_read"){
    const id=String(body.id||"");const result=await admin.from("hr_documents").update({read_at:new Date().toISOString(),updated_at:new Date().toISOString()}).eq("id",id).eq("employee_id",me.id).eq("organization_id",me.organization_id).select("id").maybeSingle();if(result.error||!result.data)return json({error:"Dokumentet finnes ikke."},404);
    await admin.from("audit_logs").insert({organization_id:me.organization_id,actor_id:authData.user.id,action:"read_hr_document",entity_type:"hr_document",entity_id:id});return json({ok:true});
  }
  if(req.method==="POST"&&action==="download_contract_pdf"){
    const id=String(body.id||"");let query=admin.from("hr_contracts").select("*,employees(full_name,email,phone_number)").eq("id",id).eq("organization_id",me.organization_id).in("status",me.role==="admin"?["signing_ready","locked","pending_signature","signed"]:["locked","pending_signature","signed"]);if(me.role!=="admin")query=query.eq("employee_id",me.id);const {data:contract}=await query.maybeSingle();if(!contract)return json({error:"Bare en låst kontrakt kan lastes ned."},404);
    if(contract.provider==='signicat_sandbox'){
      const {data:signing}=await admin.from('hr_signing_requests').select('original_path,signed_path').eq('contract_id',id).eq('organization_id',me.organization_id).maybeSingle();
      const path=contract.status==='signed'?signing?.signed_path:signing?.original_path;
      if(path){const {data:file,error}=await admin.storage.from('hr-documents').download(path);if(error||!file)return json({error:'PDF-en kunne ikke hentes fra arkivet.'},503);const bytes=new Uint8Array(await file.arrayBuffer());let binary='';for(let i=0;i<bytes.length;i+=8192)binary+=String.fromCharCode(...bytes.slice(i,i+8192));return json({content_base64:btoa(binary),file_name:`TEST-${contract.status==='signed'?'signert-':''}arbeidsavtale-v${contract.version}.pdf`});}
      if(contract.status==='signed')return json({error:'Signert PDF mangler i arkivet.'},409);
    }
    let employee=contract.locked_employee_snapshot||contract.employees;if(!contract.locked_employee_snapshot){const {data:details}=await admin.from("employee_private_details").select("address,postal_code,city,employed_from,position_percent,salary_type,salary_rate").eq("employee_id",contract.employee_id).maybeSingle();employee={...employee,...(details||{})}}const {data:organization}=await admin.from("organizations").select("name").eq("id",me.organization_id).single();const content_base64=await contractPdf(contract,employee,contract.locked_employer_name||organization?.name||"Arbeidsgiver");
    await admin.from("audit_logs").insert({organization_id:me.organization_id,actor_id:authData.user.id,action:"download_locked_contract_pdf",entity_type:"hr_contract",entity_id:id});
    return json({content_base64,file_name:`${contract.title.replace(/[^a-zA-Z0-9æøåÆØÅ_-]/g,"_")}-v${contract.version}.pdf`});
  }
  if(me.role!=="admin")return json({error:"Kun administrator har tilgang."},403);

  if(req.method==="POST"&&action==="download_document"){
    const id=String(body.id||"");const {data:document,error:documentError}=await admin.from("hr_documents").select("id,storage_path,original_name").eq("id",id).eq("organization_id",me.organization_id).maybeSingle();if(documentError||!document)return json({error:"Dokumentet finnes ikke."},404);
    const {data:signed,error:signedError}=await admin.storage.from("hr-documents").createSignedUrl(document.storage_path,120,{download:document.original_name});if(signedError||!signed?.signedUrl)return json({error:"Dokumentet kunne ikke klargjøres for nedlasting."},500);
    await admin.from("audit_logs").insert({organization_id:me.organization_id,actor_id:authData.user.id,action:"download_hr_document",entity_type:"hr_document",entity_id:id});return json({url:signed.signedUrl,file_name:document.original_name});
  }
  if(req.method==="DELETE"&&action==="delete_document"){
    const id=String(body.id||"");const {data:document,error:documentError}=await admin.from("hr_documents").select("id,employee_id,title,original_name,storage_path").eq("id",id).eq("organization_id",me.organization_id).maybeSingle();if(documentError||!document)return json({error:"Dokumentet finnes ikke."},404);
    const deleted=await admin.from("hr_documents").delete().eq("id",id).eq("organization_id",me.organization_id).select("id").maybeSingle();if(deleted.error||!deleted.data)return json({error:"Dokumentet kunne ikke slettes."},400);
    const {data:remaining}=await admin.from("hr_documents").select("id").eq("organization_id",me.organization_id).eq("storage_path",document.storage_path).limit(1);let storageRemoved=false,warning:string|undefined;if(!remaining?.length){const storage=await admin.storage.from("hr-documents").remove([document.storage_path]);storageRemoved=!storage.error;if(storage.error)warning="Dokumentoppføringen er slettet, men filoppryddingen må prøves igjen senere."}
    await admin.from("audit_logs").insert({organization_id:me.organization_id,actor_id:authData.user.id,action:"delete_hr_document",entity_type:"hr_document",entity_id:id,details:{employee_id:document.employee_id,title:document.title,original_name:document.original_name,storage_removed:storageRemoved}});return json({ok:true,storage_removed:storageRemoved,...(warning?{warning}:{})});
  }

  if(req.method==="POST"&&action==="upload_document"){
    const title=String(body.title||"").trim(),name=String(body.file_name||"").trim(),mime=String(body.mime_type||""),encoded=String(body.content_base64||""),target=String(body.employee_id||""),requiresSignature=Boolean(body.requires_signature),sendNotification=body.send_notification!==false;
    if(title.length<2||!name||mime!=="application/pdf"||!encoded)return json({error:"Velg en PDF-fil, mottaker og navn på dokumentet."},400);if(encoded.length>14000000)return json({error:"Dokumentet er for stort. Maksimum er 10 MB."},400);
    let bytes:Uint8Array;try{bytes=Uint8Array.from(atob(encoded),c=>c.charCodeAt(0))}catch{return json({error:"Dokumentet kunne ikke leses."},400)}if(bytes.length>10485760)return json({error:"Dokumentet er for stort. Maksimum er 10 MB."},400);
    let employeesQuery=admin.from("employees").select("id,full_name,email").eq("organization_id",me.organization_id).eq("active",true);if(target!=="all")employeesQuery=employeesQuery.eq("id",target);
    const {data:recipients,error:recipientError}=await employeesQuery;if(recipientError||!recipients?.length)return json({error:"Velg minst én aktiv ansatt."},400);
    const safe=name.replace(/[^a-zA-Z0-9._-]/g,"_").slice(-100),path=`${me.organization_id}/${crypto.randomUUID()}-${safe}`,batchId=crypto.randomUUID();const upload=await admin.storage.from("hr-documents").upload(path,bytes,{contentType:mime,upsert:false});if(upload.error)return json({error:upload.error.message},400);
    const rows=recipients.map((employee:any)=>({organization_id:me.organization_id,employee_id:employee.id,batch_id:batchId,title,document_type:"general",storage_path:path,original_name:name,mime_type:mime,size_bytes:bytes.length,requires_signature:requiresSignature,signature_status:requiresSignature?"pending":"not_required",uploaded_by:authData.user.id}));
    const result=await admin.from("hr_documents").insert(rows).select("id");if(result.error){await admin.storage.from("hr-documents").remove([path]);return json({error:result.error.message},400)}
    await admin.from("audit_logs").insert({organization_id:me.organization_id,actor_id:authData.user.id,action:"upload_hr_document",entity_type:"hr_document_batch",entity_id:batchId,details:{title,recipient_count:recipients.length,requires_signature:requiresSignature,send_notification:sendNotification}});
    const notices=sendNotification?await Promise.all(recipients.map((employee:any)=>sendEmail(employee.email,"Nytt dokument i HR-arkivet",`<h2>Nytt HR-dokument</h2><p>Hei ${esc(employee.full_name)}.</p><p><strong>${esc(title)}</strong> er lagt i HR-arkivet ditt i Augustum Tid.</p><p>Logg inn for å lese dokumentet.</p>`))):[];
    return json({documents:result.data,recipient_count:recipients.length,notification_requested:sendNotification,email_sent:notices.filter(Boolean).length},201);
  }
  if(req.method==="POST"&&action==="create_contract"){
    const employeeId=String(body.employee_id||""),title=String(body.title||"").trim(),modules=cleanModules(body.modules);if(!employeeId||title.length<2||title.length>200||!modules.some(m=>m.active))return json({error:"Velg ansatt og behold minst én aktiv kontraktsmodul."},400);
    const {data:employee}=await admin.from("employees").select("id").eq("id",employeeId).eq("organization_id",me.organization_id).eq("active",true).eq("portal_actor_only",false).not("portal_employee_id","is",null).maybeSingle();if(!employee)return json({error:"Ansatt finnes ikke."},404);
    const result=await admin.from("hr_contracts").insert({organization_id:me.organization_id,employee_id:employeeId,title,content:"Modulbasert kontrakt",modules,created_by:authData.user.id,updated_by:authData.user.id}).select("id,status,version").single();if(result.error)return json({error:result.error.message},400);
    await admin.from("audit_logs").insert({organization_id:me.organization_id,actor_id:authData.user.id,action:"create_hr_contract",entity_type:"hr_contract",entity_id:result.data.id});return json({contract:result.data},201);
  }
  const draftActions:Record<string,string>={update_contract:"PATCH",delete_contract:"DELETE",prepare_signing:"PATCH",return_to_draft:"PATCH"};
  if(draftActions[action]===req.method){
    if(!body.id||!body.expected_updated_at||!Number.isFinite(Date.parse(String(body.expected_updated_at))))return json({error:"Oppdater kontraktlisten før du prøver igjen."},409);
    const payload=action==="update_contract"?{title:String(body.title||"").trim(),modules:cleanModules(body.modules)}:{};
    const {data,error}=await admin.rpc("hr_contract_draft_action",{p_org:me.organization_id,p_actor:authData.user.id,p_id:String(body.id),p_expected:String(body.expected_updated_at),p_action:action,p_body:payload});
    if(error)return json({error:error.message},409);return json(data);
  }
  // Never silently send a contract or advertise configuration based on a client ID alone.
  if(action==="lock_contract")return json({error:"Oppdater siden og bruk Send til signering fra lagrede utkast."},409);
  if(req.method==="POST"&&action==="start_signing")return json({error:"BankID-utsending er ikke aktivert. Ingen kontrakt eller e-post er sendt."},409);
  return json({error:"Handling støttes ikke."},405);
});

