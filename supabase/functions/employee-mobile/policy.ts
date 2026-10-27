type Shared={case_id:string;employee_shared_at:string|null};
export function visibleCases<T extends {id:string}>(cases:T[],plans:Shared[],activities:Shared[]){
 const shared=new Set([...plans,...activities].filter(r=>r.employee_shared_at).map(r=>r.case_id));return cases.filter(c=>shared.has(c.id));
}
export function latestSharedPlans<T extends Shared & {version:number}>(plans:T[]){
 const result=new Map<string,T>();for(const plan of plans){if(plan.employee_shared_at&&(!result.has(plan.case_id)||result.get(plan.case_id)!.version<plan.version))result.set(plan.case_id,plan);}return [...result.values()];
}
export function validReply(body:Record<string,unknown>){
 const uuid=(v:unknown)=>typeof v==='string'&&/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(v);
 if(!uuid(body?.case_id)||!uuid(body?.request_id)||typeof body?.message!=='string'||body.message.trim().length<2||body.message.trim().length>2000)throw Error('Invalid reply');
 return {case_id:body.case_id as string,request_id:body.request_id as string,message:body.message.trim()};
}
