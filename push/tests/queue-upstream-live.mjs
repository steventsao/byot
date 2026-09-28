import {test} from 'node:test';
import assert from 'node:assert/strict';
import {queueFixture} from './queue-fixture.mjs';
import {PromptRunner,queueUpstream} from '../public/byot-notify.mjs';
const root=process.env.BYOT_PUSH_LIVE_ROOT;
assert.ok(root,'Set BYOT_PUSH_LIVE_ROOT to the isolated fixture directory');
for(const version of [1,2]) test(`durable queue executes three ordered prompts after client departure on OpenCode ${version}`,{timeout:120000},async()=>{
 const f=queueFixture(); Object.assign(f.config,{server:`http://127.0.0.1:${version===1?4196:4197}`,username:'opencode',password:'byot-local-fixture-only'});
 const directory=root+`/v${version}/project`,prefix=version===2?'/api':'';
 const response=await fetch(f.config.server+prefix+'/session'+(version===1?'?directory='+encodeURIComponent(directory):''),{method:'POST',headers:{authorization:'Basic '+Buffer.from('opencode:byot-local-fixture-only').toString('base64'),'content-type':'application/json'},body:JSON.stringify(version===1?{title:'Durable queue acceptance'}:{title:'Durable queue acceptance',location:{directory},model:{providerID:'fixture',id:'test'}})});
 assert.ok(response.ok,await response.clone().text());const raw=await response.json(),session=version===2?raw.data:raw;
 const route={sessionID:session.id,directory,workspace:session.location?.workspaceID??session.workspaceID??null};
 const jobs=[];
 for(let i=0;i<3;i++)jobs.push((await f.enqueue({text:'Say BYOT upstream compatibility verified. Queue step '+i,agent:'build',variant:'byot-careful',model:{providerID:'fixture',modelID:'test',variants:['byot-careful']},attachments:i===1?[{filename:'context.txt',mimeType:'text/plain',data:Buffer.from('Queue attachment retained').toString('base64')}]:[]},{route})).job);
 // No client calls occur from here. Restart the runner each tick to exercise recovery.
 let failures=[];
 const upstream=async(...args)=>{try{return await queueUpstream(...args)}catch(e){failures.push(e.message);throw e}};
 for(let i=0;i<100;i++){
  await new PromptRunner(f.config,f.relay,upstream).tick(version);
  const states=f.db.prepare('SELECT state FROM prompt_jobs ORDER BY position').all().map(j=>j.state);
  if(states.every(s=>s==='completed'))break;
  if(states.includes('needsReview'))break;
  await new Promise(r=>setTimeout(r,500));
 }
 const states=f.db.prepare('SELECT state FROM prompt_jobs ORDER BY position').all().map(j=>j.state);
 assert.deepEqual(states,['completed','completed','completed'],JSON.stringify({states,failures}));
 const snapshot=await queueUpstream(f.config,version,{...route,serverID:f.config.serverID},'snapshot');
 const users=snapshot.messages.map(m=>m.info??m).filter(m=>(m.role??m.type)==='user');
 for(const job of jobs)assert.equal(users.filter(m=>m.id==='msg_'+job.id.replaceAll('-','')).length,1);
});
