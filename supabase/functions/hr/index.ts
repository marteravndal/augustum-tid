import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.116.0";

const cors={"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, apikey, content-type","Access-Control-Allow-Methods":"GET, POST, PATCH, OPTIONS","Content-Type":"application/json"};
const json=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:cors});
const esc=(value:unknown)=>String(value??"").replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]!));
const sendEmail=async(to:string,subject:string,html:string)=>{const key=Deno.env.get("RESEND_API_KEY");if(!key)return false;try{return (await fetch("https://api.resend.com/emails",{method:"POST",headers:{Authorization:`Bearer ${key}`,"Content-Type":"application/json"},body:JSON.stringify({from:"Augustum Tid <post@apartstavanger.no>",to:[to],subject,html})})).ok}catch{return false}};

Deno.serve(async(req:Request)=>{
  if(req.method==="OPTIONS")return new Response("ok",{headers:cors});
  const auth=req.headers.get("Authorization");if(!auth?.startsWith("Bearer "))return json({error:"Mangler innlogging."},401);
  const admin=createClient(Deno.env.get("SUPABASE_URL")!,Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,{auth:{persistSession:false}});
  const {data:authData,error:authError}=await admin.auth.getUser(auth.slice(7));if(authError||!authData.user)return json({error:"Ugyldig innlogging."},401);
  const {data:me}=await admin.from("employees").select("id,organization_id,role,active,full_name,email").eq("auth_user_id",authData.user.id).maybeSingle();if(!me?.active)return json({error:"Brukeren er ikke aktiv."},403);

  if(req.method==="GET"){
    let docs=admin.from("hr_documents").select("id,employee_id,batch_id,title,document_type,original_name,mime_type,size_bytes,requires_signature,signature_status,read_at,signed_at,created_at,storage_path,employees(employee_number,full_name,email)").eq("organization_id",me.organization_id).order("created_at",{ascending:false});
    let contracts=admin.from("hr_contracts").select("id,employee_id,title,content,locked_content,status,version,locked_at,signed_at,created_at,updated_at,employees(employee_number,full_name,email)").eq("organization_id",me.organization_id).order("updated_at",{ascending:false});
    if(me.role!=="admin"){docs=docs.eq("employee_id",me.id);contracts=contracts.eq("employee_id",me.id).neq("status","draft")}
    const [{data:docRows,error:docError},{data:contractRows,error:contractError},{data:staff,error:staffError}]=await Promise.all([docs,contracts,me.role==="admin"?admin.from("employees").select("id,employee_number,full_name,email").eq("organization_id",me.organization_id).eq("active",true).order("full_name"):Promise.resolve({data:[],error:null})]);
    if(docError||contractError||staffError)return json({error:docError?.message||contractError?.message||staffError?.message},400);
    const documents=await Promise.all((docRows||[]).map(async(row:any)=>{const {data}=await admin.storage.from("hr-documents").createSignedUrl(row.storage_path,900);const {storage_path,...safe}=row;return{...safe,url:data?.signedUrl||null}}));
    return json({documents,contracts:contractRows||[],employees:staff||[],is_admin:me.role==="admin",signing_provider_configured:Boolean(Deno.env.get("SIGNICAT_CLIENT_ID"))});
  }

  let body:Record<string,unknown>;try{body=await req.json()}catch{return json({error:"Ugyldig forespørsel."},400)}const action=String(body.action||"");
  if(req.method==="PATCH"&&action==="mark_read"){
    const id=String(body.id||"");const result=await admin.from("hr_documents").update({read_at:new Date().toISOString(),updated_at:new Date().toISOString()}).eq("id",id).eq("employee_id",me.id).eq("organization_id",me.organization_id).select("id").maybeSingle();if(result.error||!result.data)return json({error:"Dokumentet finnes ikke."},404);
    await admin.from("audit_logs").insert({organization_id:me.organization_id,actor_id:authData.user.id,action:"read_hr_document",entity_type:"hr_document",entity_id:id});return json({ok:true});
  }
  if(me.role!=="admin")return json({error:"Kun administrator har tilgang."},403);

  if(req.method==="POST"&&action==="upload_document"){
    const title=String(body.title||"").trim(),name=String(body.file_name||"").trim(),mime=String(body.mime_type||""),encoded=String(body.content_base64||""),target=String(body.employee_id||""),requiresSignature=Boolean(body.requires_signature);
    if(title.length<2||!name||mime!=="application/pdf"||!encoded)return json({error:"Velg en PDF-fil, mottaker og navn på dokumentet."},400);if(encoded.length>14000000)return json({error:"Dokumentet er for stort. Maksimum er 10 MB."},400);
    let bytes:Uint8Array;try{bytes=Uint8Array.from(atob(encoded),c=>c.charCodeAt(0))}catch{return json({error:"Dokumentet kunne ikke leses."},400)}if(bytes.length>10485760)return json({error:"Dokumentet er for stort. Maksimum er 10 MB."},400);
    let employeesQuery=admin.from("employees").select("id,full_name,email").eq("organization_id",me.organization_id).eq("active",true);if(target!=="all")employeesQuery=employeesQuery.eq("id",target);
    const {data:recipients,error:recipientError}=await employeesQuery;if(recipientError||!recipients?.length)return json({error:"Velg minst én aktiv ansatt."},400);
    const safe=name.replace(/[^a-zA-Z0-9._-]/g,"_").slice(-100),path=`${me.organization_id}/${crypto.randomUUID()}-${safe}`,batchId=crypto.randomUUID();const upload=await admin.storage.from("hr-documents").upload(path,bytes,{contentType:mime,upsert:false});if(upload.error)return json({error:upload.error.message},400);
    const rows=recipients.map((employee:any)=>({organization_id:me.organization_id,employee_id:employee.id,batch_id:batchId,title,document_type:"general",storage_path:path,original_name:name,mime_type:mime,size_bytes:bytes.length,requires_signature:requiresSignature,signature_status:requiresSignature?"pending":"not_required",uploaded_by:authData.user.id}));
    const result=await admin.from("hr_documents").insert(rows).select("id");if(result.error){await admin.storage.from("hr-documents").remove([path]);return json({error:result.error.message},400)}
    await admin.from("audit_logs").insert({organization_id:me.organization_id,actor_id:authData.user.id,action:"upload_hr_document",entity_type:"hr_document_batch",entity_id:batchId,details:{title,recipient_count:recipients.length,requires_signature:requiresSignature}});
    const notices=await Promise.all(recipients.map((employee:any)=>sendEmail(employee.email,"Nytt dokument i HR-arkivet",`<h2>Nytt HR-dokument</h2><p>Hei ${esc(employee.full_name)}.</p><p><strong>${esc(title)}</strong> er lagt i HR-arkivet ditt i Augustum Tid.</p><p>Logg inn for å lese dokumentet.</p>`)));
    return json({documents:result.data,recipient_count:recipients.length,email_sent:notices.filter(Boolean).length},201);
  }
  if(req.method==="POST"&&action==="create_contract"){
    const employeeId=String(body.employee_id||""),title=String(body.title||"").trim(),content=String(body.content||"").trim();if(!employeeId||title.length<2||content.length<20)return json({error:"Velg ansatt og fyll inn kontraktstittel og innhold."},400);
    const {data:employee}=await admin.from("employees").select("id").eq("id",employeeId).eq("organization_id",me.organization_id).eq("active",true).maybeSingle();if(!employee)return json({error:"Ansatt finnes ikke."},404);
    const result=await admin.from("hr_contracts").insert({organization_id:me.organization_id,employee_id:employeeId,title,content,created_by:authData.user.id,updated_by:authData.user.id}).select("id,status,version").single();if(result.error)return json({error:result.error.message},400);
    await admin.from("audit_logs").insert({organization_id:me.organization_id,actor_id:authData.user.id,action:"create_hr_contract",entity_type:"hr_contract",entity_id:result.data.id});return json({contract:result.data},201);
  }
  if(req.method==="PATCH"&&action==="update_contract"){
    const id=String(body.id||""),title=String(body.title||"").trim(),content=String(body.content||"").trim();if(title.length<2||content.length<20)return json({error:"Kontrakten må ha tittel og innhold."},400);
    const result=await admin.from("hr_contracts").update({title,content,updated_by:authData.user.id,updated_at:new Date().toISOString()}).eq("id",id).eq("organization_id",me.organization_id).eq("status","draft").select("id").maybeSingle();if(result.error||!result.data)return json({error:"Bare kontrakter med status utkast kan redigeres."},409);
    await admin.from("audit_logs").insert({organization_id:me.organization_id,actor_id:authData.user.id,action:"update_hr_contract",entity_type:"hr_contract",entity_id:id});return json({ok:true});
  }
  if(req.method==="PATCH"&&action==="lock_contract"){
    const id=String(body.id||"");const {data:contract}=await admin.from("hr_contracts").select("id,title,content,employee_id,employees(full_name,email)").eq("id",id).eq("organization_id",me.organization_id).eq("status","draft").maybeSingle();if(!contract)return json({error:"Bare et utkast kan låses."},409);
    const now=new Date().toISOString(),result=await admin.from("hr_contracts").update({locked_content:contract.content,status:"locked",locked_at:now,updated_by:authData.user.id,updated_at:now}).eq("id",id).eq("status","draft").select("id").maybeSingle();if(result.error||!result.data)return json({error:"Kontrakten kunne ikke låses."},409);
    await admin.from("audit_logs").insert({organization_id:me.organization_id,actor_id:authData.user.id,action:"lock_hr_contract",entity_type:"hr_contract",entity_id:id});
    const emailSent=await sendEmail((contract.employees as any).email,"Arbeidskontrakt klargjort",`<h2>Arbeidskontrakt klargjort</h2><p>Hei ${esc((contract.employees as any).full_name)}.</p><p><strong>${esc(contract.title)}</strong> er låst og klargjort for signering i Augustum Tid. Du får ny beskjed når BankID-signering er aktivert.</p>`);
    return json({ok:true,email_sent:emailSent});
  }
  if(req.method==="POST"&&action==="start_signing")return json({error:"Signicat er ikke konfigurert ennå. Kontrakten er låst og klar for tilkobling."},409);
  return json({error:"Handling støttes ikke."},405);
});
