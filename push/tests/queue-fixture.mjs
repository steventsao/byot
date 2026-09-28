import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import worker from '../src/worker.ts';
import { randomSecret } from '../src/protocol.ts';
import { encryptRoute, digest } from '../public/byot-notify.mjs';
export function queueFixture() {
  const db=new DatabaseSync(':memory:'); db.exec('PRAGMA foreign_keys=ON');
  for(const migration of ['0001_push.sql','0002_prompt_queue.sql']) db.exec(readFileSync(new URL('../migrations/'+migration,import.meta.url),'utf8'));
  const wrap=(sql,args=[])=>({bind(...values){return wrap(sql,values)},async first(){return db.prepare(sql).get(...args)??null},async run(){return db.prepare(sql).run(...args)},async all(){return {results:db.prepare(sql).all(...args)}}});
  const env={DB:{prepare:sql=>wrap(sql),batch:async list=>list.map(s=>s.run())},QUEUE_RATE_LIMITER:{limit:async()=>({success:true})},RATE_LIMITER:{limit:async()=>({success:true})}};
  const config={subscriptionID:randomUUID(),serverID:randomUUID(),ownerKey:randomSecret(),senderKey:randomSecret(),routeKey:Buffer.alloc(32,9).toString('base64')};
  db.prepare('INSERT INTO subscriptions(id,owner_hash,sender_hash,device_token,environment,server_id,paired_at,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?)').run(config.subscriptionID,digest(config.ownerKey),digest(config.senderKey),'a'.repeat(64),'production',config.serverID,Date.now(),Date.now(),Date.now());
  const call=(method,path='',body,key=config.ownerKey)=>worker.fetch(new Request(`https://queue.test/v1/subscriptions/${config.subscriptionID}/queue${path}`,{method,headers:{authorization:'Bearer '+key,'content-type':'application/json'},...(body?{body:JSON.stringify(body)}:{})}),env);
  const relay=async(c,method,path,body)=>{
    const response=await call(method,path,body,c.senderKey);
    const result=await response.json();
    if(!response.ok) throw Object.assign(new Error(JSON.stringify(result)),{status:response.status});
    return result;
  };
  const enqueue=async(overrides={},options={})=>{
    const id=options.id??randomUUID(),revision=options.revision??1;
    const route={serverID:config.serverID,sessionID:'ses_test',directory:'/fixture',workspace:null,...options.route};
    const prompt={id,text:'Test queued work',attachments:[],remoteReferences:[],model:{providerID:'fixture',modelID:'test',variants:['careful']},...overrides};
    const envelope={version:1,subscriptionID:config.subscriptionID,revision,route,prompt,references:options.references??[]};
    const content=encryptRoute(envelope,config.routeKey), hash=digest(content), thread=digest(config.subscriptionID+':'+route.sessionID);
    let response=await call('PUT','/'+id,{thread,chunks:1,digest:hash});
    if(!response.ok) throw new Error(await response.text());
    response=await call('PUT',`/${id}/chunks/0?revision=${revision}`,{content});
    if(!response.ok) throw new Error(await response.text());
    response=await call('POST',`/${id}/commit`,{revision,chunks:1,digest:hash});
    if(!response.ok) throw new Error(await response.text());
    return {job:await response.json(),envelope,content};
  };
  return {db,env,config,call,relay,enqueue};
}
