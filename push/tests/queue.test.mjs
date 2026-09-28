import {test} from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {queueFixture} from './queue-fixture.mjs';
import {PromptRunner,promptBody,encryptRoute,digest} from '../public/byot-notify.mjs';
import {randomSecret} from '../src/protocol.ts';

test('encrypted upload commits atomically, retries idempotently, and isolates sender and owner',async()=>{
 const f=queueFixture(),{job,content}=await f.enqueue();
 assert.equal((await f.call('GET','',null,randomSecret())).status,403);
 assert.equal((await f.call('POST',`/${job.id}/claim`,{revision:1})).status,405);
 assert.equal((await f.call('DELETE',`/${job.id}`,null,f.config.senderKey)).status,405);
 assert.equal((await f.call('POST',`/${job.id}/commit`,{revision:1,chunks:1,digest:digest(content)})).status,200);
 assert.equal(f.db.prepare('SELECT COUNT(*) AS n FROM prompt_jobs').get().n,1);
 assert.ok(!JSON.stringify(f.db.prepare('SELECT * FROM prompt_jobs').all()).includes('Test queued work'));
 assert.equal((await f.call('POST',`/${job.id}/commit`,{revision:2,chunks:1,digest:'a'.repeat(64)})).status,409);
 assert.equal((await f.call('PUT',`/${job.id}/chunks/0?revision=1`,{content})).status,409);
});
test('pause, optimistic editing, strict ordering, single claim, and cancellation races',async()=>{
 const f=queueFixture(),a=await f.enqueue(),b=await f.enqueue();
 const claim=(job)=>f.call('POST',`/${job.id}/claim`,{revision:job.revision},f.config.senderKey);
 assert.equal((await claim(b.job)).status,409);
 await f.call('PATCH','/sessions',{thread:a.job.thread,paused:true});
 assert.equal((await claim(a.job)).status,409);
 const edit=await f.enqueue({text:'Edited safely'},{id:a.job.id,revision:2});
 assert.equal(edit.job.revision,2);
 await f.call('PATCH','/order',{thread:a.job.thread,ids:[b.job.id,a.job.id]});
 await f.call('PATCH','/sessions',{thread:a.job.thread,paused:false});
 assert.equal((await claim(edit.job)).status,409);
 const attempts=await Promise.all([claim(b.job),claim(b.job)]);
 assert.deepEqual(attempts.map(r=>r.status).sort(),[200,409]);
 assert.equal((await claim(edit.job)).status,409);
 assert.equal((await f.call('DELETE','/'+b.job.id)).status,409);
 await f.call('PATCH',`/${b.job.id}/state`,{state:'needsReview'},f.config.senderKey);
 assert.equal((await claim(edit.job)).status,409);
 await f.call('DELETE','/'+b.job.id);
 assert.equal((await claim(edit.job)).status,200);
 assert.equal((await f.call('PUT',`/${a.job.id}/chunks/0?revision=3`,{content:a.content})).status,409);
});
test('three prompts execute in order without a phone, including companion restart',async()=>{
 const f=queueFixture(); for(let i=0;i<3;i++) await f.enqueue({text:'step '+i});
 const messages=[],sent=[];
 const upstream=async(c,v,r,op,prepared)=>{
  if(op==='send') {
   sent.push(prepared.prompt.text);
   messages.push({info:{id:prepared.messageID,role:'user'}},{info:{id:randomUUID(),role:'assistant',time:{completed:Date.now()},finish:'stop'}});
  }
  return {active:false,blocked:false,messages};
 };
 for(let i=0;i<6;i++) await new PromptRunner(f.config,f.relay,upstream).tick(1);
 assert.deepEqual(sent,['step 0','step 1','step 2']);
 assert.deepEqual(f.db.prepare('SELECT state FROM prompt_jobs ORDER BY position').all().map(j=>j.state),['completed','completed','completed']);
});
test('lost send acknowledgement reconciles existing turn; killed claim never resends',async()=>{
 const f=queueFixture(),a=await f.enqueue(); let sends=0;const messages=[];
 const upstream=async(c,v,r,op,p)=>{
  if(op==='send') {sends++;messages.push({info:{id:p.messageID,role:'user'}},{info:{role:'assistant',time:{completed:Date.now()},finish:'stop'}});throw new Error('Lost acknowledgement');}
  return {active:false,blocked:false,messages};
 };
 await new PromptRunner(f.config,f.relay,upstream).tick(1);
 await new PromptRunner(f.config,f.relay,upstream).tick(1);
 assert.equal(sends,1);assert.equal(f.db.prepare('SELECT state FROM prompt_jobs').get().state,'completed');
 const b=await f.enqueue();
 await f.call('POST',`/${b.job.id}/claim`,{revision:1},f.config.senderKey);
 f.db.prepare('UPDATE prompt_jobs SET updated_at=0 WHERE id=?').run(b.job.id);
 await new PromptRunner(f.config,f.relay,upstream).tick(1);
 assert.equal(sends,1);assert.equal(f.db.prepare('SELECT state FROM prompt_jobs WHERE id=?').get(b.job.id).state,'needsReview');
});
test('busy sessions, unresolved approvals, and failed turns prevent follow-up dispatch',async()=>{
 const f=queueFixture(),a=await f.enqueue();let state={active:true,blocked:false,messages:[]};let sends=0;
 const upstream=async(c,v,r,op,p)=>{if(op==='send')sends++;return state;};
 const runner=new PromptRunner(f.config,f.relay,upstream);
 await runner.tick(1);state={...state,active:false,blocked:true};await runner.tick(1);assert.equal(sends,0);
 state={active:false,blocked:false,messages:[]};await runner.tick(1);assert.equal(sends,1);
 state.messages=[{info:{id:'msg_'+a.job.id.replaceAll('-',''),role:'user'}},{info:{role:'assistant',error:{name:'failed'},time:{completed:Date.now()}}}];
 await runner.tick(1);assert.equal(f.db.prepare('SELECT state FROM prompt_jobs').get().state,'needsReview');
});
test('tampering and cross-session ciphertext cannot run; preserved settings and file context',async()=>{
 const f=queueFixture(),p={text:'hello',agent:'plan',variant:'careful',attachments:[{filename:'a.png',mimeType:'image/png',data:Buffer.from('image').toString('base64')} ]};
 const a=await f.enqueue(p,{references:[{uri:'file:///fixture/code.swift?start=2&end=5',name:'code.swift',mime:'text/plain'}]});
 const body=promptBody(a.envelope,1).body;
 assert.equal(body.agent,'plan');assert.equal(body.variant,'careful');assert.equal(body.model.providerID,'fixture');assert.equal(body.parts.length,3);assert.match(body.parts[2].url,/start=2/);
 const wrong={...a.envelope,route:{...a.envelope.route,sessionID:'ses_wrong'}};
 const content=encryptRoute(wrong,f.config.routeKey);
 f.db.prepare('UPDATE prompt_chunks SET content=?').run(content);f.db.prepare('UPDATE prompt_jobs SET digest=?').run(digest(content));
 let sends=0;await new PromptRunner(f.config,f.relay,async()=>{sends++;}).tick(1);assert.equal(sends,0);
});
test('uncertain jobs send one attention alert after reconnecting, without resending work',async()=>{
 const f=queueFixture(),a=await f.enqueue();
 await f.call('POST',`/${a.job.id}/claim`,{revision:1},f.config.senderKey);
 await f.call('PATCH',`/${a.job.id}/state`,{state:'needsReview'},f.config.senderKey);
 let alerts=0;
 const runner=new PromptRunner(f.config,f.relay,async()=>assert.fail('must not run'),async envelope=>{alerts++;assert.equal(envelope.prompt.id,a.job.id)});
 await runner.tick(1);await runner.tick(1);assert.equal(alerts,1);
});
