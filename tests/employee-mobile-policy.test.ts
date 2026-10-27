import {strict as assert} from 'node:assert';
import {visibleCases,latestSharedPlans,validReply} from '../supabase/functions/employee-mobile/policy.ts';
const plans=[{case_id:'a',version:1,employee_shared_at:'2026-01-01'},{case_id:'a',version:2,employee_shared_at:null},{case_id:'b',version:1,employee_shared_at:null}];
assert.deepEqual(visibleCases([{id:'a'},{id:'b'},{id:'c'}],plans,[{case_id:'c',employee_shared_at:'2026-01-02'}]),[{id:'a'},{id:'c'}]);
assert.equal(latestSharedPlans(plans)[0].version,1);
assert.equal(latestSharedPlans([...plans,{case_id:'a',version:3,employee_shared_at:'2026-01-03'}])[0].version,3);
assert.throws(()=>validReply({case_id:'a',request_id:'b',message:'test'}));
console.log('Explicit sharing: private cases/versions excluded, latest shared version selected, reply IDs validated.');
