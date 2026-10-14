const fs=require('node:fs'),path=require('node:path');
const root=path.resolve(__dirname,'..');
const productionRefs=new Set(['oslkpuqkppxvbyvegvkn','pziazogdzjzrixhiqmwm','vqsyaeqrmxkgeuqgazzd','bzqbmgctjnbynudwrmaq']);
function previewConfig(env){
 const ref=env.TID_TEST_PROJECT_REF||'',key=env.TID_TEST_PUBLISHABLE_KEY||'';
 if(!ref&&!key)return {mode:'preview',configured:false,supabaseUrl:'',publishableKey:''};
 if(!/^[a-z]{20}$/.test(ref)||productionRefs.has(ref))throw Error('Use a dedicated, isolated test database. Production projects are forbidden.');
 if(!/^sb_publishable_[A-Za-z0-9_-]+$/.test(key))throw Error('Use the test project publishable key; secret and service keys are forbidden.');
 return {mode:'preview',configured:true,supabaseUrl:`https://${ref}.supabase.co`,publishableKey:key};
}
function build(env=process.env){
 const config=previewConfig(env),out=path.join(root,'dist');
 fs.rmSync(out,{recursive:true,force:true});fs.mkdirSync(out,{recursive:true});
 for(const file of ['index.html','app.js','styles.css','weekly-review.js','payroll-dashboard.js','control-assistant.js','admin-app.html','admin-app.js','admin-app.css','manifest.webmanifest','admin-manifest.webmanifest','offline.html','sw.js'])fs.copyFileSync(path.join(root,file),path.join(out,file));
 fs.cpSync(path.join(root,'icons'),path.join(out,'icons'),{recursive:true});
 fs.writeFileSync(path.join(out,'runtime-config.js'),'window.TID_CONFIG=Object.freeze('+JSON.stringify(config)+');\n');
 console.log(config.configured?'Built isolated test frontend.':'Built preview shell; database and login are disabled.');
}
if(require.main===module)build();module.exports={previewConfig,build};
