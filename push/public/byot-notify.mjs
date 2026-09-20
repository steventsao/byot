#!/usr/bin/env node
// BYOT notification companion. Node.js 22+. Credentials stay on this computer.
import {
  createHash,
  randomBytes,
  randomUUID,
  createCipheriv,
  createDecipheriv,
} from 'node:crypto';
import {
  mkdir,
  readFile,
  writeFile,
  rename,
  chmod,
  copyFile,
  open,
  unlink,
} from 'node:fs/promises';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createInterface } from 'node:readline/promises';
import { spawnSync } from 'node:child_process';

export const RELAY = 'https://byot-push.steventsao.workers.dev';
const root = join(homedir(), '.config', 'byot-notify');
const configPath = join(root, 'config.json');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
export const digest = (value) =>
  createHash('sha256').update(value).digest('hex');
export function encryptRoute(route, key) {
  const nonce = randomBytes(12);
  const cipher = createCipheriv(
    'aes-256-gcm',
    Buffer.from(key, 'base64'),
    nonce,
  );
  const ciphertext = Buffer.concat([
    cipher.update(JSON.stringify(route)),
    cipher.final(),
  ]);
  return Buffer.concat([nonce, ciphertext, cipher.getAuthTag()]).toString(
    'base64',
  );
}
export function serverURL(input) {
  const url = new URL(input);
  if (url.username || url.password || url.hash || url.search)
    throw new Error(
      'Use a server URL without credentials, query, or fragment.',
    );
  if (
    url.protocol !== 'https:' &&
    !(
      url.protocol === 'http:' &&
      ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname)
    )
  )
    throw new Error(
      'Use HTTPS, or HTTP on localhost on the OpenCode computer.',
    );
  return url.toString().replace(/\/$/, '');
}
async function atomicJSON(path, value) {
  await mkdir(dirname(path), { recursive: true, mode: 0o700 });
  const temporary = path + '.' + randomUUID() + '.tmp';
  await writeFile(temporary, JSON.stringify(value, null, 2), { mode: 0o600 });
  await rename(temporary, path);
  await chmod(path, 0o600);
}
async function readJSON(path, fallback) {
  try {
    return JSON.parse(await readFile(path, 'utf8'));
  } catch (e) {
    if (e.code === 'ENOENT') return fallback;
    throw e;
  }
}
async function boundedJSON(response) {
  if (!response.headers.get('content-type')?.includes('application/json'))
    throw new Error('Server did not return JSON.');
  const decoder = new TextDecoder();
  let data = '',
    size = 0;
  for await (const chunk of response.body) {
    size += chunk.length;
    if (size > 4 * 1024 * 1024) throw new Error('Response too large.');
    data += decoder.decode(chunk, { stream: true });
  }
  return JSON.parse(data + decoder.decode());
}
async function api(path, key, body) {
  const r = await fetch(RELAY + path, {
    method: 'POST',
    redirect: 'error',
    signal: AbortSignal.timeout(25000),
    headers: {
      'content-type': 'application/json',
      ...(key ? { authorization: `Bearer ${key}` } : {}),
    },
    body: JSON.stringify(body),
  });
  if (!r.ok) {
    const error = new Error(`Notification service returned HTTP ${r.status}.`);
    error.status = r.status;
    throw error;
  }
  return boundedJSON(r);
}
export async function serverRequest(config, path, query = {}, stream = false) {
  const url = new URL(serverURL(config.server) + path);
  for (const [key, value] of Object.entries(query)) {
    if (value !== undefined && value !== null && value !== '')
      url.searchParams.set(key, value);
  }
  const response = await fetch(url, {
    redirect: 'error',
    signal: AbortSignal.timeout(stream ? 300000 : 15000),
    headers: {
      authorization:
        'Basic ' +
        Buffer.from(`${config.username}:${config.password}`).toString('base64'),
      accept: stream ? 'text/event-stream' : 'application/json',
    },
  });
  if (!response.ok)
    throw new Error(`OpenCode returned HTTP ${response.status}.`);
  if (stream) {
    if (!response.headers.get('content-type')?.includes('text/event-stream'))
      throw new Error('OpenCode did not return an event stream.');
    return response;
  }
  return boundedJSON(response);
}
export async function detect(config) {
  try {
    const v1 = await serverRequest(config, '/global/health');
    if (typeof v1.version === 'string' && v1.healthy) return 1;
  } catch {}
  const raw = await serverRequest(config, '/api/health');
  const v2 = raw.data ?? raw;
  if (v2.healthy !== true) throw new Error('OpenCode is not healthy.');
  const schema = await serverRequest(config, '/openapi.json');
  if (
    !schema.paths?.['/api/event']?.get ||
    !schema.paths?.['/api/session/{sessionID}']?.get
  )
    throw new Error(
      'This OpenCode 2 version does not expose the required notification routes.',
    );
  return 2;
}
// Only known attention events are admitted. Tool failures are not terminal session errors.
export class EventTracker {
  seen = new Map();
  states = new Map();
  accept(raw) {
    if (!raw || typeof raw !== 'object') return null;
    const event = raw.payload ?? raw;
    if (!event || typeof event !== 'object') return null;
    const data = event.data ?? event.properties ?? {};
    const sessionID = data.sessionID ?? data.form?.sessionID ?? data.info?.id;
    if (
      typeof sessionID !== 'string' ||
      !/^[a-zA-Z0-9_-]{1,200}$/.test(sessionID)
    )
      return null;
    const type = event.type;
    const state = this.states.get(sessionID) ?? {
      active: false,
      failed: false,
      turn: randomUUID(),
    };
    if (
      (type === 'session.status' &&
        ['busy', 'retry'].includes(data.status?.type)) ||
      type === 'session.execution.started'
    ) {
      if (!state.active) state.turn = randomUUID();
      state.active = true;
      state.failed = false;
      this.states.set(sessionID, state);
      return null;
    }
    let kind;
    if (['permission.asked', 'permission.v2.asked'].includes(type))
      kind = 'permission';
    if (['question.asked', 'question.v2.asked', 'form.created'].includes(type))
      kind = 'question';
    if (['session.error', 'session.execution.failed'].includes(type)) {
      kind = 'error';
      state.failed = true;
      state.active = false;
    }
    if (
      type === 'session.execution.succeeded' ||
      type === 'session.idle' ||
      (type === 'session.status' && data.status?.type === 'idle')
    ) {
      // Require observed activity for legacy idle events; initial snapshots are not completed turns.
      if (
        !state.failed &&
        (type === 'session.execution.succeeded' || state.active)
      )
        kind = 'complete';
      state.active = false;
    }
    if (type === 'session.execution.interrupted') {
      state.active = false;
      state.failed = false;
    }
    this.states.set(sessionID, state);
    if (this.states.size > 4096)
      this.states.delete(this.states.keys().next().value);
    if (!kind) return null;
    const requestID = data.id ?? data.requestID ?? data.form?.id;
    const eventID = digest(
      event.id ?? `${sessionID}:${kind}:${requestID ?? state.turn}`,
    );
    if (this.seen.has(eventID)) return null;
    this.seen.set(eventID, Date.now());
    if (this.seen.size > 4096) this.seen.delete(this.seen.keys().next().value);
    return {
      eventID,
      kind,
      sessionID,
      directory: raw.directory ?? data.directory ?? data.location?.directory,
      workspace: data.location?.workspaceID ?? data.workspaceID,
      createdAt: Date.now(),
    };
  }
}
export async function* parseSSE(body) {
  const decoder = new TextDecoder();
  let buffer = '',
    lines = [];
  let size = 0;
  for await (const chunk of body) {
    buffer += decoder.decode(chunk, { stream: true });
    if (buffer.length > 2 * 1024 * 1024)
      throw new Error('Event line too large.');
    let index;
    while ((index = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, index).replace(/\r$/, '');
      buffer = buffer.slice(index + 1);
      size += line.length;
      if (size > 4 * 1024 * 1024) throw new Error('Event too large.');
      if (!line) {
        if (lines.length) {
          const text = lines.join('\n');
          lines = [];
          size = 0;
          try {
            yield JSON.parse(text);
          } catch {}
        } else size = 0;
      } else if (line.startsWith('data:'))
        lines.push(line.slice(5).replace(/^ /, ''));
    }
  }
}
export async function notification(config, version, event) {
  const raw = await serverRequest(
    config,
    `${version === 2 ? '/api' : ''}/session/${encodeURIComponent(event.sessionID)}`,
    version === 1 ? { directory: event.directory ?? config.directory } : {},
  );
  const info = version === 2 ? raw.data : raw;
  if (!info || info.id !== event.sessionID)
    throw new Error('Session could not be resolved.');
  // Child completions are noisy; child permission/questions still require attention.
  if (info.parentID && event.kind === 'complete') return null;
  const route = {
    serverID: config.serverID,
    sessionID: info.id,
    directory:
      info.location?.directory ??
      info.directory ??
      event.directory ??
      config.directory ??
      '',
    workspace: info.location?.workspaceID ?? info.workspaceID ?? null,
  };
  if (Buffer.byteLength(route.directory) > 1024)
    throw new Error('Session directory is too long for a notification.');
  return {
    eventID: event.eventID,
    kind: event.kind,
    createdAt: event.createdAt,
    thread: digest(config.subscriptionID.toLowerCase() + ':' + info.id),
    route: encryptRoute(route, config.routeKey),
  };
}
// Serialize disk writes with mutations so a concurrent acknowledgement cannot overwrite a new event.
export class PendingNotifications {
  items;
  tail = Promise.resolve();
  constructor(items, save) {
    this.items = items;
    this.save = save;
  }
  mutate(change) {
    const operation = this.tail.then(async () => {
      const next = change(
        this.items.filter(
          (item) => Date.now() - item.event.createdAt < 3600000,
        ),
      ).slice(-256);
      await this.save(next);
      this.items = next;
    });
    this.tail = operation.catch(() => {});
    return operation;
  }
  put(event, version) {
    return this.mutate((items) =>
      items.some((item) => item.event.eventID === event.eventID)
        ? items
        : [...items, { event, version }],
    );
  }
  remove(id) {
    return this.mutate((items) =>
      items.filter((item) => item.event.eventID !== id),
    );
  }
  snapshot() {
    return this.items.filter(
      (item) => Date.now() - item.event.createdAt < 3600000,
    );
  }
}
// The relay owns admission and ordering. A claim is never replayed after an ambiguous
// failure: reconcile its stable message ID, or require human review.
export function decryptQueue(text, key) {
  const data = Buffer.from(text, 'base64');
  const decipher = createDecipheriv('aes-256-gcm', Buffer.from(key, 'base64'), data.subarray(0, 12));
  decipher.setAuthTag(data.subarray(-16));
  return JSON.parse(Buffer.concat([decipher.update(data.subarray(12, -16)), decipher.final()]));
}
export function promptBody(envelope, version, schema) {
  const p = envelope.prompt;
  const messageID = 'msg_' + p.id.replaceAll('-', '').toLowerCase();
  const files = [...(p.attachments ?? []).map(a => ({uri:`data:${a.mimeType};base64,${a.data}`, name:a.filename, mime:a.mimeType})), ...(envelope.references ?? [])];
  if (version === 1) {
    if (p.command?.kind === 'skill') throw new Error('Unsupported skill');
    const parts = files.map(f => ({type:'file',url:f.uri,filename:f.name,mime:f.mime}));
    if (!p.command && p.text) parts.unshift({type:'text',text:p.text});
    const body = {messageID,parts};
    if (p.agent) body.agent = p.agent;
    if (p.variant) body.variant = p.variant;
    if (p.command) {
      body.command=p.command.name; body.arguments=p.command.arguments;
      if(p.model) body.model=p.model.providerID+'/'+p.model.modelID;
    } else if (p.model) body.model={providerID:p.model.providerID,modelID:p.model.modelID};
    return {body, suffix:p.command ? 'command':'prompt_async', messageID};
  }
  const command = p.command?.kind === 'command';
  const suffix = command ? 'command':'prompt';
  const properties = schema?.paths?.[`/api/session/{sessionID}/${suffix}`]?.post?.requestBody?.content?.['application/json']?.schema?.properties;
  if (!properties) throw new Error('Unsupported prompt contract');
  const content = {text:p.command?.arguments ?? p.text};
  if (files.length) content.files=files.map(({uri,name})=>({uri,name}));
  if (p.command?.kind === 'skill') {
    if (!properties.skills) throw new Error('Unsupported skill');
    content.skills=[{id:p.command.name}];
  }
  const body = {delivery:'queue'};
  if (command) body.command=p.command.name;
  else {
    body.id=messageID;
    if(properties.metadata) {
      body.metadata={displayText:p.text};
      if(p.agent) body.metadata.agent=p.agent;
      if(p.model) body.metadata.model={providerID:p.model.providerID,modelID:p.model.modelID,...(p.variant?{variant:p.variant}:{})};
    }
  }
  if (properties.text) Object.assign(body,content);
  else if(properties.prompt) body.prompt=content;
  else throw new Error('Unsupported prompt contract');
  return {body,suffix,messageID};
}
export class PromptRunner {
  constructor(config, relayRequest = queueAPI, upstream = queueUpstream, notifyReview) {
    this.config=config; this.relay=relayRequest; this.upstream=upstream;
    this.running=false; this.cache=new Map(); this.notifyReview=notifyReview; this.reviewAlerts=new Set();
  }
  async envelope(job) {
    const key=job.id+':'+job.revision;
    if(this.cache.has(key)) return this.cache.get(key);
    let ciphertext='';
    for(let i=0;i<job.chunks;i++) ciphertext += (await this.relay(this.config,'GET',`/${job.id}/chunks/${i}?revision=${job.revision}`)).content;
    if(digest(ciphertext)!==job.digest) throw new Error('Invalid ciphertext digest');
    const value=decryptQueue(ciphertext,this.config.routeKey);
    if(value.version!==1 || value.subscriptionID.toLowerCase()!==this.config.subscriptionID.toLowerCase() || value.prompt.id.toLowerCase()!==job.id.toLowerCase() || value.revision!==job.revision || value.route.serverID.toLowerCase()!==this.config.serverID.toLowerCase() || digest(this.config.subscriptionID.toLowerCase()+':'+value.route.sessionID)!==job.thread || !/^[A-Za-z0-9_-]{1,200}$/.test(value.route.sessionID)) throw new Error('Queue context mismatch');
    if(!Array.isArray(value.prompt.attachments) || value.prompt.attachments.length>10 || value.prompt.attachments.reduce((n,a)=>n+Buffer.from(a.data,'base64').length,0)>20*1024*1024) throw new Error('Invalid attachments');
    if(value.prompt.variant && !value.prompt.model?.variants?.includes(value.prompt.variant)) throw new Error('Invalid model variant');
    this.cache.set(key,value);
    if(this.cache.size>20) this.cache.delete(this.cache.keys().next().value);
    return value;
  }
  async tick(version) {
    if(this.running) return;
    this.running=true;
    try {
      const snapshot=await this.relay(this.config,'GET','');
      const paused=new Set(snapshot.sessions.filter(s=>s.paused).map(s=>s.thread));
      const handled=new Set();
      for(const job of snapshot.jobs.filter(j=>!['completed','cancelled','uploading'].includes(j.state))) {
        if(handled.has(job.thread)) continue;
        // Resolve an in-flight job before any queued sibling, regardless of reordering.
        const active=snapshot.jobs.find(j=>j.thread===job.thread && ['claimed','submitted','needsReview'].includes(j.state));
        const current=active ?? job;
        handled.add(job.thread);
        if(current.state==='needsReview') {
          if(this.notifyReview && !this.reviewAlerts.has(current.id)) {
            try { await this.notifyReview(await this.envelope(current)); this.reviewAlerts.add(current.id); }
            catch { /* Retry notification after reconnecting; never retry the prompt. */ }
          }
          continue;
        }
        if(!active && paused.has(job.thread)) continue;
        try { await this.process(current,version); }
        catch { /* Offline upstream/relay: leave the authoritative job intact. */ }
      }
    } finally { this.running=false; }
  }
  async process(job,version) {
    const envelope=await this.envelope(job), route=envelope.route;
    const state=await this.upstream(this.config,version,route,'snapshot');
    const messageID='msg_'+job.id.replaceAll('-','').toLowerCase();
    const messages=state.messages.map(m=>m.info ?? m);
    const index=messages.findIndex(m=>m.id===messageID);
    const nextUser=messages.findIndex((m,i)=>i>index && (m.role ?? m.type)==='user');
    const response=index<0?[]:messages.slice(index+1,nextUser<0?undefined:nextUser).filter(m=>(m.role ?? m.type)==='assistant' && (!m.parentID || m.parentID===messageID));
    const complete=response.some(m=>m.time?.completed && !m.error && m.finish && !['tool-calls','unknown'].includes(m.finish));
    const failed=response.some(m=>m.error);
    if(['claimed','submitted'].includes(job.state)) {
      if(state.active || state.blocked) return;
      if(complete) return this.relay(this.config,'PATCH',`/${job.id}/state`,{state:'completed'});
      if(failed || Date.now()-job.updated_at>60000)
        return this.relay(this.config,'PATCH',`/${job.id}/state`,{state:'needsReview'});
      return;
    }
    if(state.active || state.blocked) return;
    if(index>=0) {
      // An admission ID already exists; never create another upstream request.
      await this.relay(this.config,'POST',`/${job.id}/claim`,{revision:job.revision});
      return this.relay(this.config,'PATCH',`/${job.id}/state`,{state:complete?'completed':'needsReview'});
    }
    // Construct/validate before claiming, so a schema error cannot mutate session settings.
    let prepared;
    try { prepared=promptBody(envelope,version,state.schema); }
    catch {
      await this.relay(this.config,'POST',`/${job.id}/claim`,{revision:job.revision});
      return this.relay(this.config,'PATCH',`/${job.id}/state`,{state:'needsReview'});
    }
    await this.relay(this.config,'POST',`/${job.id}/claim`,{revision:job.revision});
    // Only the caller receiving a successful one-time claim can enter this block.
    // A killed process or lost response leaves a claimed job for reconciliation.
    try {
      const queue=await this.relay(this.config,'GET','');
      if(queue.sessions.some(s=>s.thread===job.thread && s.paused)) throw new Error('Queue paused');
      const fresh=await this.upstream(this.config,version,route,'status');
      if(fresh.active || fresh.blocked) throw new Error('Session became active');
      await this.upstream(this.config,version,route,'send',{...prepared,prompt:envelope.prompt});
      await this.relay(this.config,'PATCH',`/${job.id}/state`,{state: version===2 && envelope.prompt.command?.kind==='command' ? 'completed' : 'submitted'});
    } catch {
      // Keep claimed: a later snapshot can prove completion, otherwise review is required.
    }
  }
}
export async function queueAPI(config,method,path,body) {
  const r=await fetch(RELAY+`/v1/subscriptions/${config.subscriptionID}/queue`+path,{
    method,redirect:'error',signal:AbortSignal.timeout(25000),
    headers:{authorization:`Bearer ${config.senderKey}`,'content-type':'application/json'},
    ...(body?{body:JSON.stringify(body)}:{})
  });
  if(!r.ok) throw new Error('Queue request failed: '+r.status);
  return boundedJSON(r);
}
export async function queueUpstream(config,version,route,operation,prepared) {
  const prefix=version===2?'/api':'', path=`${prefix}/session/${encodeURIComponent(route.sessionID)}`;
  const query=version===1?{directory:route.directory,workspace:route.workspace}:{};
  const get=(path,q=query)=>serverRequest(config,path,q);
  const post=async(suffix,body)=>{
    const url=new URL(serverURL(config.server)+path+'/'+suffix);
    for(const[k,v]of Object.entries(query)) if(v) url.searchParams.set(k,v);
    const r=await fetch(url,{method:'POST',redirect:'error',signal:AbortSignal.timeout(30000),headers:{authorization:'Basic '+Buffer.from(`${config.username}:${config.password}`).toString('base64'),'content-type':'application/json'},body:JSON.stringify(body)});
    if(!r.ok) throw new Error('OpenCode did not acknowledge the prompt');
    if(r.status!==204) { const result=await boundedJSON(r); if(version===2 && suffix==='prompt' && result.data?.sessionID!==route.sessionID) throw new Error('Invalid admission'); }
  };
  if(operation==='send') {
    if(version===2) {
      if(prepared.prompt.agent) await post('agent',{agent:prepared.prompt.agent});
      if(prepared.prompt.model) await post('model',{model:{id:prepared.prompt.model.modelID,providerID:prepared.prompt.model.providerID,...(prepared.prompt.variant?{variant:prepared.prompt.variant}:{})}});
    }
    return post(prepared.suffix,prepared.body);
  }
  // Resolve the session on the configured server. Do not trust a phone-supplied URL.
  const raw=await get(path), session=version===2?raw.data:raw;
  const directory=session?.location?.directory ?? session?.directory;
  const workspace=session?.location?.workspaceID ?? session?.workspaceID ?? null;
  if(session?.id!==route.sessionID || directory!==route.directory || workspace!==(route.workspace ?? null)) throw new Error('Session location changed');
  const states=await get(version===2?'/api/session/active':'/session/status',version===2?{}:query);
  const active=version===2?!!states.data?.[route.sessionID]:['busy','retry'].includes(states[route.sessionID]?.type);
  if(version===2 && (!states.data || typeof states.data!=='object')) throw new Error('Invalid active status');
  let blocked=false;
  if(version===1) {
    const [permissions,questions]=await Promise.all([get('/permission'),get('/question')]);
    if(!Array.isArray(permissions)||!Array.isArray(questions)) throw new Error('Invalid pending actions');
    blocked=[...permissions,...questions].some(p=>p.sessionID===route.sessionID);
  } else {
    const [permissions,forms]=await Promise.all([get(path+'/permission'),get(path+'/form')]);
    if(!Array.isArray(permissions.data)||!Array.isArray(forms.data)) throw new Error('Invalid pending actions');
    blocked=permissions.data.some(p=>!p.time?.replied && !p.reply) || forms.data.length > 0;
  }
  if(operation==='status') return {active,blocked};
  const messages=[];
  if(version===1) messages.push(...await get(path+'/message',{...query,limit:'200'}));
  else {
    let cursor; const seen=new Set();
    do {
      const result=await get(path+'/message',cursor?{limit:'200',cursor}:{limit:'200',order:'asc'});
      if(!Array.isArray(result.data)) throw new Error('Invalid transcript');
      messages.push(...result.data); cursor=result.cursor?.next;
      if(cursor && seen.has(cursor)) throw new Error('Repeated cursor');
      seen.add(cursor);
      if(messages.length>10000) throw new Error('Transcript too large');
    } while(cursor);
  }
  return {active,blocked,messages,schema:version===2?await get('/openapi.json',{}):undefined};
}

async function runServer(config) {
  const tracker = new EventTracker();
  const prompts = new PromptRunner(config, queueAPI, queueUpstream, async envelope => {
    await api(`/v1/subscriptions/${config.subscriptionID}/events`, config.senderKey, {
      eventID: digest('queue-review:' + envelope.prompt.id), kind: 'error',
      createdAt: Date.now(), thread: digest(config.subscriptionID.toLowerCase() + ':' + envelope.route.sessionID),
      route: encryptRoute(envelope.route, config.routeKey),
    });
  });
  let queueVersion;
  const promptTimer = setInterval(() => { if (queueVersion) void prompts.tick(queueVersion).catch(() => {}); }, 5000);
  const queuePath = join(root, config.subscriptionID + '.pending.json');
  const queue = new PendingNotifications(
    await readJSON(queuePath, []),
    (items) => atomicJSON(queuePath, items),
  );
  let flushing = false;
  const flush = async () => {
    if (flushing) return;
    flushing = true;
    try {
      if (queue.items.length !== queue.snapshot().length)
        await queue.mutate((items) => items);
      for (const { event, version } of queue.snapshot()) {
        try {
          const item = await notification(config, version, event);
          if (item)
            await api(
              `/v1/subscriptions/${config.subscriptionID}/events`,
              config.senderKey,
              item,
            );
          await queue.remove(event.eventID);
        } catch (e) {
          if ([400, 404, 410].includes(e.status))
            await queue.remove(event.eventID);
          else break; // Keep unresolved sessions and transient delivery failures for retry.
        }
      }
    } finally {
      flushing = false;
    }
  };
  const flushTimer = setInterval(
    () =>
      void flush().catch(() =>
        console.error('Could not save pending notifications.'),
      ),
    5000,
  );
  const heartbeat = async () => {
    try {
      await api(
        `/v1/subscriptions/${config.subscriptionID}/heartbeat`,
        config.senderKey,
        { queueVersion: 1 },
      );
    } catch {}
  };
  const heartbeatTimer = setInterval(() => void heartbeat(), 60000);
  let backoff = 1000;
  try {
    while (true) {
      try {
        const version = await detect(config);
        queueVersion = version;
        void prompts.tick(version).catch(() => {});
        await heartbeat();
        await flush();
        const response = await serverRequest(
          config,
          version === 2 ? '/api/event' : '/global/event',
          {},
          true,
        );
        console.log('Connected to OpenCode; notifications are active.');
        backoff = 1000;
        for await (const raw of parseSSE(response.body)) {
          const event = tracker.accept(raw);
          if (!event) continue;
          await queue.put(event, version);
          void flush().catch(() =>
            console.error('Notification retry will continue.'),
          );
        }
      } catch {
        console.error('OpenCode connection interrupted; reconnecting.');
      }
      await sleep(backoff);
      backoff = Math.min(backoff * 2, 30000);
    }
  } finally {
    clearInterval(promptTimer);
    clearInterval(flushTimer);
    clearInterval(heartbeatTimer);
  }
}
async function hiddenPrompt(prompt) {
  process.stdout.write(prompt);
  if (!process.stdin.isTTY)
    throw new Error('Run setup in an interactive terminal.');
  process.stdin.setRawMode(true);
  process.stdin.resume();
  let value = '';
  return new Promise((resolve, reject) => {
    const onData = (chunk) => {
      for (const character of chunk.toString()) {
        if (character === '\r' || character === '\n') {
          cleanup();
          resolve(value);
          return;
        }
        if (character === '\u0003') {
          cleanup();
          reject(new Error('Cancelled.'));
          return;
        }
        if (character === '\u007f') {
          value = value.slice(0, -1);
        } else if (character >= ' ') value += character;
      }
    };
    function cleanup() {
      process.stdin.removeListener('data', onData);
      process.stdin.setRawMode(false);
      process.stdin.pause();
      process.stdout.write('\n');
    }
    process.stdin.on('data', onData);
  });
}
async function setup() {
  await mkdir(root, { recursive: true, mode: 0o700 });
  await chmod(root, 0o700);
  console.log('Pair this computer with byot → server menu → Notifications.');
  let rl = createInterface({ input: process.stdin, output: process.stdout });
  const code = (await rl.question('Pairing code: ')).trim();
  const server = serverURL(
    (await rl.question('OpenCode URL [http://127.0.0.1:4096]: ')).trim() ||
      'http://127.0.0.1:4096',
  );
  const username =
    (await rl.question('OpenCode username [opencode]: ')).trim() || 'opencode';
  rl.close();
  const password =
    process.env.OPENCODE_SERVER_PASSWORD ??
    (await hiddenPrompt(
      'OpenCode password (stored locally, never sent to byot): ',
    ));
  const local = { server, username, password };
  await detect(local);
  const pairing = await api('/v1/pair', null, { code });
  const config = await readJSON(configPath, { servers: [] });
  config.servers = config.servers.filter(
    (s) => s.subscriptionID !== pairing.subscriptionID,
  );
  config.servers.push({ ...pairing, ...local });
  await atomicJSON(configPath, config);
  const installed = join(root, 'byot-notify.mjs');
  if (resolve(fileURLToPath(import.meta.url)) !== installed)
    await copyFile(fileURLToPath(import.meta.url), installed);
  await chmod(installed, 0o700);
  console.log(
    'Paired. Server credentials are stored only in ' +
      configPath +
      ' (owner access only).',
  );
  if (process.platform === 'darwin') {
    rl = createInterface({ input: process.stdin, output: process.stdout });
    const answer = await rl.question(
      'Run automatically in the background on this Mac? [Y/n] ',
    );
    rl.close();
    if (answer.trim().toLowerCase() !== 'n') {
      const escape = (s) =>
        s
          .replaceAll('&', '&amp;')
          .replaceAll('<', '&lt;')
          .replaceAll('>', '&gt;')
          .replaceAll('"', '&quot;');
      const plist = join(
        homedir(),
        'Library',
        'LaunchAgents',
        'app.byot.notify.plist',
      );
      await mkdir(dirname(plist), { recursive: true });
      await writeFile(
        plist,
        `<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>Label</key><string>app.byot.notify</string><key>ProgramArguments</key><array><string>${escape(process.execPath)}</string><string>${escape(installed)}</string><string>run</string></array><key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ThrottleInterval</key><integer>30</integer><key>StandardOutPath</key><string>${escape(join(root, 'service.log'))}</string><key>StandardErrorPath</key><string>${escape(join(root, 'service.log'))}</string></dict></plist>`,
        { mode: 0o600 },
      );
      const target = `gui/${process.getuid()}`;
      spawnSync('launchctl', ['bootout', target, plist], { stdio: 'ignore' });
      const r = spawnSync('launchctl', ['bootstrap', target, plist], {
        stdio: 'inherit',
      });
      if (r.status !== 0)
        throw new Error(
          'Paired, but background service could not start. Run the companion manually.',
        );
      console.log(
        'Notification companion installed. Send a test notification in byot.',
      );
      return;
    }
  }
  console.log(
    `Keep this running while using OpenCode:\nnode "${installed}" run`,
  );
}
async function main() {
  if (process.argv[2] === 'setup') return setup();
  if (process.argv[2] !== 'run') {
    console.log('Usage: node byot-notify.mjs setup | run');
    return;
  }
  const config = await readJSON(configPath, { servers: [] });
  if (!config.servers.length) throw new Error('Run setup first.');
  const lock = join(root, 'service.lock');
  try {
    const file = await open(lock, 'wx', 0o600);
    await file.writeFile(String(process.pid));
    await file.close();
  } catch (e) {
    if (e.code !== 'EEXIST') throw e;
    const pid = Number(await readFile(lock, 'utf8'));
    let alive = true;
    try {
      process.kill(pid, 0);
    } catch {
      alive = false;
    }
    if (alive) throw new Error('A notification companion is already running.');
    await unlink(lock);
    const file = await open(lock, 'wx', 0o600);
    await file.writeFile(String(process.pid));
    await file.close();
  }
  try {
    await Promise.all(config.servers.map(runServer));
  } finally {
    await unlink(lock).catch(() => {});
  }
}
if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(resolve(process.argv[1])).href
)
  main().catch(() => {
    console.error(
      'Notification companion could not start. Check the server address, password and pairing code, then retry setup.',
    );
    process.exitCode = 1;
  });
