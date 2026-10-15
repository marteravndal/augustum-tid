import { premiumHoursBetween } from './payroll-premiums.ts';
const round=(n:number)=>Math.round((n+Number.EPSILON)*100)/100;
const addDays=(d:string,n:number)=>{const date=new Date(d+'T12:00:00Z');date.setUTCDate(date.getUTCDate()+n);return date.toISOString().slice(0,10)};
export function payrollSummaryPeriods(now:string){
 const today=new Intl.DateTimeFormat('sv-SE',{timeZone:'Europe/Oslo'}).format(new Date(now));
 const monday=addDays(today,-((new Date(today+'T12:00:00Z').getUTCDay()+6)%7));
 return [{key:'yesterday',label:'I går',from:addDays(today,-1),to:addDays(today,-1)},
  {key:'last_week',label:'Sist uke',from:addDays(monday,-7),to:addDays(monday,-1)},
  {key:'month_to_date',label:'Hittil denne måneden',from:today.slice(0,7)+'-01',to:today}];
}
export function payrollSummaryMonths(now:string){
 const periods=payrollSummaryPeriods(now),months=new Set<string>();
 for(const p of periods)for(let date=p.from;date<=p.to;date=addDays(date,1))months.add(date.slice(0,7)+'-01');
 return [...months].sort();
}
// Match payroll reports: overnight work belongs to its start date. Locked weeks
// retain frozen rates. Only recorded work and registered overtime supplements count.
export function payrollSummary(datasets:any[],now:string){
 const entries=new Map<string,any>(),adjustments=new Map<string,any>();
 for(const data of datasets)for(const week of data.weeks||[])for(const person of week.employees||[]){
  for(const entry of person.entries||[])if(entry.kind==='work')entries.set(entry.id,{...entry,person});
  for(const adjustment of person.adjustments||[])if(['overtime_40','overtime_100'].includes(adjustment.category))adjustments.set(adjustment.id,{...adjustment,person});
 }
 const timestamp=Date.parse(now),validRate=(r:any)=>r!==null&&r!==undefined&&Number.isFinite(Number(r))&&Number(r)>=0;
 const periods=payrollSummaryPeriods(now).map(period=>{
  let cost=0,hours=0,open=0,unapproved=0,missing=0,excluded=0;const employees=new Set<string>();
  for(const entry of entries.values()){
   if(entry.work_date<period.from||entry.work_date>period.to)continue;
   const start=Date.parse(entry.started_at),end=Math.min(entry.ended_at?Date.parse(entry.ended_at):timestamp,timestamp);
   if(start>timestamp)continue;
   if(!Number.isFinite(start)||!Number.isFinite(end)||end<start||(!entry.ended_at&&timestamp-start>20*3600000)){excluded++;continue}
   const h=(end-start)/3600000;if(!h)continue;
   hours+=h;employees.add(entry.person.employee.id);if(!entry.ended_at)open++;
   if(!entry.approved&&!entry.person.locked)unapproved++;
   const rate=entry.person.summary.hourly_rate,rates=entry.person.summary.payroll_codes||{};
   let incomplete=!validRate(rate);if(validRate(rate))cost+=h*Number(rate);
   const premiums=premiumHoursBetween(new Date(start).toISOString(),new Date(end).toISOString());
   for(const key of ['evening','night','weekend'] as const){if(premiums[key]>0){if(validRate(rates[key]?.hourly_rate))cost+=premiums[key]*Number(rates[key].hourly_rate);else incomplete=true}}
   if(incomplete)missing++;
  }
  for(const adjustment of adjustments.values()){
   if(adjustment.work_date<period.from||adjustment.work_date>period.to)continue;
   const rate=adjustment.person.summary.hourly_rate,h=Number(adjustment.hours),factor=adjustment.category==='overtime_40'?.4:1;
   if(!h)continue;
   if(!Number.isFinite(h)){excluded++;continue}
   if(validRate(rate))cost+=h*factor*Number(rate);else missing++;
   if(!adjustment.approved&&!adjustment.person.locked)unapproved++;
  }
  return {...period,cost:round(cost),hours:round(hours),employees:employees.size,open_count:open,unapproved_count:unapproved,missing_rate_count:missing,excluded_count:excluded,incomplete:missing>0||excluded>0};
 });
 return {updated_at:now,periods};
}
