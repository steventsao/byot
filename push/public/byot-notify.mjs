#!/usr/bin/env node
// BYOT notification companion. Node.js 22+. Credentials stay on this computer.
import {
  createHash,
  randomBytes,
  randomUUID,
  createCipheriv,
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
async function runServer(config) {
  const tracker = new EventTracker();
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
        {},
      );
    } catch {}
  };
  const heartbeatTimer = setInterval(() => void heartbeat(), 60000);
  let backoff = 1000;
  try {
    while (true) {
      try {
        const version = await detect(config);
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
