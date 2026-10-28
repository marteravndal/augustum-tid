const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),{stripTypeScriptTypes}=require('node:module');
const compile=p=>stripTypeScriptTypes(fs.readFileSync(p,'utf8').replace(/^import .*;\n/gm,'').replace(/^export /gm,''));
const premium=new Function(compile('supabase/functions/_shared/payroll-premiums.ts')+';return premiumHoursBetween')();
const {payrollSummary,payrollSummaryPeriods,payrollSummaryMonths}=new Function('premiumHoursBetween',compile('supabase/functions/_shared/payroll-summary.ts')+';return {payrollSummary,payrollSummaryPeriods,payrollSummaryMonths}')(premium);
const now='2026-10-14T10:00:00Z',rates={evening:{hourly_rate:10},night:{hourly_rate:20},weekend:{hourly_rate:30}};
const entry=(patch={})=>({id:'one',kind:'work',work_date:'2026-10-13',started_at:'2026-10-13T06:00:00Z',ended_at:'2026-10-13T14:00:00Z',approved:false,...patch});
const person=(patch={})=>({employee:{id:'emp'},summary:{hourly_rate:200,payroll_codes:rates},entries:[entry()],adjustments:[],locked:false,...patch});
const data=p=>({weeks:[{week_start:'2026-10-12',employees:[p||person()]}]});
test('Oslo calendar boundaries: yesterday, previous Monday-Sunday, month and year changes',()=>{
 assert.deepEqual(payrollSummaryPeriods('2027-01-01T00:30:00Z').map(p=>[p.from,p.to]),[['2026-12-31','2026-12-31'],['2026-12-21','2026-12-27'],['2027-01-01','2027-01-01']]);
 assert.deepEqual(payrollSummaryMonths('2027-01-01T00:30:00Z'),['2026-12-01','2027-01-01']);assert.equal(payrollSummaryPeriods('2026-10-13T22:30:00Z')[0].from,'2026-10-13');
});
test('unapproved recorded hours counted once; sick pay and plans excluded',()=>{
 const d=data();d.weeks[0].employees[0].entries.push(entry({id:'sick',kind:'sick_pay'}));const p=payrollSummary([d,d],now).periods;assert.equal(p[0].cost,1600);assert.equal(p[0].hours,8);assert.equal(p[0].unapproved_count,1);assert.equal(p[1].cost,0);assert.equal(p[2].cost,1600);
});
test('locked rates and overtime supplement without duplicate ordinary pay',()=>{
 const d=data(person({locked:true,adjustments:[{id:'adj',work_date:'2026-10-13',category:'overtime_40',hours:2}]}));d.employees=[{id:'emp',hourly_rate:999}];const p=payrollSummary([d,d],now).periods[0];assert.equal(p.cost,1760);assert.equal(p.unapproved_count,0);
});
test('ongoing hours up to now, missing rates and stale punches',()=>{
 const d=data(person({entries:[entry({work_date:'2026-10-14',started_at:'2026-10-14T06:00:00Z',ended_at:null})]}));let p=payrollSummary([d],now).periods[2];assert.equal(p.cost,800);assert.equal(p.open_count,1);assert.equal(p.hours,4);
 d.weeks[0].employees[0].summary.hourly_rate=null;p=payrollSummary([d],now).periods[2];assert.equal(p.incomplete,true);assert.equal(p.missing_rate_count,1);
 d.weeks[0].employees[0].entries[0].started_at='2026-10-12T06:00:00Z';p=payrollSummary([d],now).periods[2];assert.equal(p.excluded_count,1);assert.equal(p.cost,0);
});
test('night shifts use start date and DST elapsed hours with premiums',()=>{
 const d=data(person({entries:[entry({work_date:'2026-10-25',started_at:'2026-10-24T22:00:00Z',ended_at:'2026-10-25T05:00:00Z'})]}));const p=payrollSummary([d],'2026-10-26T12:00:00Z').periods[0];assert.equal(p.hours,7);assert.equal(p.cost,1540);
});
test('summary API requires admin and uses server-derived company and actor',async()=>{
 const calls=[];let handler,role='employee';const db={auth:{getUser:async()=>({data:{user:{id:'actor'}}})},from:()=>({select(){return this},eq(){return this},maybeSingle:async()=>({data:{organization_id:'own-org',role,active:true}})}),rpc:async(name,args)=>(calls.push(args),{data:data()})};
 vm.runInNewContext(compile('supabase/functions/payroll-dashboard/index.ts'),{Deno:{env:{get:()=>''},serve:f=>handler=f},createClient:()=>db,payrollSummary,payrollSummaryMonths,payrollForecast:()=>({}),Request,Response,console});
 const request=()=>new Request('https://test.invalid',{method:'POST',headers:{Authorization:'Bearer test'},body:JSON.stringify({action:'summary',organization_id:'other-org',now:'1900-01-01'})});assert.equal((await handler(request())).status,403);assert.equal(calls.length,0);role='admin';assert.equal((await handler(request())).status,200);assert.ok(calls.every(c=>c.p_org==='own-org'&&c.p_actor==='actor'&&c.p_action==='load'));
});
