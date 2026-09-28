// Explicit, isolated acceptance against the deployed relay and local upstream fixtures.
// Creates temporary subscriptions and deletes them in finally; sends no APNs alerts.
import assert from 'node:assert/strict';
import {randomUUID,randomBytes} from 'node:crypto';
import {writeFile} from 'node:fs/promises';
import {PromptRunner,queueAPI,queueUpstream,encryptRoute,digest,RELAY} from '../public/byot-notify.mjs';
assert.equal(process.env.BYOT_QUEUE_PRODUCTION_ACCEPTANCE,'1');
const root=process.env.BYOT_PUSH_LIVE_ROOT;assert.ok(root);
const receipts=[];
for(const version of [1,2]) {
 const owner=randomBytes(32).toString('base64url'),subscriptionID=randomUUID(),serverID=randomUUID(),routeKey=randomBytes(32).toString('base64');
 const call=async(method,path,body,key=owner)=>{
  const r=await fetch(RELAY+path,{method,redirect:'error',signal:AbortSignal.timeout(30000),headers:{authorization:'Bearer '+key,'content-type':'application/json'},...(body?{body:JSON.stringify(body)}:{})});
  const result=await r.json();if(!r.ok)throw new Error('Relay HTTP '+r.status+': '+JSON.stringify(result));return result;
 };
 const base='/v1/subscriptions/'+subscriptionID;
 await call('PUT',base,{deviceToken:'b'.repeat(64),environment:'production',serverID});
 try {
  const {code}=await call('POST',base+'/pair',{routeKey});
  const pair=await call('POST','/v1/pair',{code});
  const config={...pair,server:`http://127.0.0.1:${version===1?4196:4197}`,username:'opencode',password:'byot-local-fixture-only'};
  await call('POST',base+'/heartbeat',{queueVersion:1},config.senderKey);
  assert.equal((await call('GET',base)).queueVersion,1);
  const directory=root+`/v${version}/project`;
  const response=await fetch(config.server+(version===2?'/api':'')+'/session'+(version===1?'?directory='+encodeURIComponent(directory):''),{method:'POST',headers:{authorization:'Basic '+Buffer.from('opencode:byot-local-fixture-only').toString('base64'),'content-type':'application/json'},body:JSON.stringify(version===1?{title:'Production queue acceptance'}:{title:'Production queue acceptance',location:{directory},model:{providerID:'fixture',id:'test'}})});
  assert.ok(response.ok);const raw=await response.json(),session=version===2?raw.data:raw;
  const route={serverID,sessionID:session.id,directory,workspace:session.location?.workspaceID??session.workspaceID??null},thread=digest(subscriptionID+':'+session.id),ids=[];
  for(let i=0;i<3;i++){
   const id=randomUUID();ids.push(id);
   const prompt={id,text:'Say BYOT upstream compatibility verified. Production queue step '+i,attachments:[],remoteReferences:[],agent:'build',variant:'byot-careful',model:{providerID:'fixture',modelID:'test',variants:['byot-careful']}};
   const ciphertext=encryptRoute({version:1,subscriptionID,revision:1,route,prompt,references:[]},routeKey),hash=digest(ciphertext);
   await call('PUT',base+'/queue/'+id,{thread,chunks:1,digest:hash});
   await call('PUT',base+`/queue/${id}/chunks/0?revision=1`,{content:ciphertext});
   await call('POST',base+`/queue/${id}/commit`,{revision:1,chunks:1,digest:hash});
  }
  // Client is now absent. Only the companion accesses the relay.
  let states=[];
  for(let i=0;i<100;i++){
   await new PromptRunner(config).tick(version);
   const snapshot=await queueAPI(config,'GET','');states=snapshot.jobs.filter(j=>ids.includes(j.id)).map(j=>j.state);
   if(states.length===3&&states.every(s=>s==='completed'))break;
   if(states.includes('needsReview'))break;
   await new Promise(r=>setTimeout(r,500));
  }
  assert.deepEqual(states,['completed','completed','completed']);
  const snapshot=await queueUpstream(config,version,route,'snapshot');
  const users=snapshot.messages.map(m=>m.info??m).filter(m=>(m.role??m.type)==='user');
  for(const id of ids)assert.equal(users.filter(m=>m.id==='msg_'+id.replaceAll('-','')).length,1);
  receipts.push({version,orderedPrompts:3,states,duplicateAdmissions:0,companionRestartedBetweenTicks:true});
 } finally { await call('DELETE',base); }
}
const receipt={checkedAt:new Date().toISOString(),relay:RELAY,syntheticSubscriptionsDeleted:true,physicalDevice:false,results:receipts};
if(process.env.BYOT_QUEUE_RECEIPT)await writeFile(process.env.BYOT_QUEUE_RECEIPT,JSON.stringify(receipt,null,2)+'\n');
console.log(JSON.stringify(receipt,null,2));
