import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createDecipheriv } from 'node:crypto';
import {
  EventTracker,
  encryptRoute,
  parseSSE,
  serverURL,
  detect,
  PendingNotifications,
} from '../public/byot-notify.mjs';
const v1 = (type, properties) => ({
  directory: '/project',
  payload: { type, properties },
});
test('initial idle is silent and each busy-to-idle transition notifies once', () => {
  const t = new EventTracker();
  assert.equal(t.accept(v1('session.idle', { sessionID: 'ses_1' })), null);
  for (let i = 0; i < 2; i++) {
    t.accept(
      v1('session.status', { sessionID: 'ses_1', status: { type: 'busy' } }),
    );
    assert.equal(
      t.accept(v1('session.idle', { sessionID: 'ses_1' })).kind,
      'complete',
    );
    assert.equal(
      t.accept(
        v1('session.status', { sessionID: 'ses_1', status: { type: 'idle' } }),
      ),
      null,
    );
  }
});
test('terminal errors suppress completion until the next turn', () => {
  const t = new EventTracker();
  t.accept(
    v1('session.status', { sessionID: 'ses_1', status: { type: 'busy' } }),
  );
  assert.equal(
    t.accept(v1('session.error', { sessionID: 'ses_1' })).kind,
    'error',
  );
  assert.equal(t.accept(v1('session.idle', { sessionID: 'ses_1' })), null);
  t.accept({
    type: 'session.execution.started',
    id: 'start',
    data: { sessionID: 'ses_1' },
  });
  assert.equal(
    t.accept({
      type: 'session.execution.succeeded',
      id: 'end',
      data: { sessionID: 'ses_1' },
    }).kind,
    'complete',
  );
});
test('v1/v2 permissions, questions, forms, duplicate events and nonterminal tool errors', () => {
  const t = new EventTracker();
  for (const type of [
    'permission.asked',
    'permission.v2.asked',
    'question.asked',
    'question.v2.asked',
  ]) {
    const e = {
      id: type,
      type,
      data: { sessionID: 'ses_1', id: 'req_' + type },
    };
    assert.equal(
      t.accept(e).kind,
      type.startsWith('permission') ? 'permission' : 'question',
    );
    assert.equal(t.accept(e), null);
  }
  assert.equal(
    t.accept({
      type: 'form.created',
      id: 'form',
      data: { form: { id: 'form1', sessionID: 'ses_2' } },
    }).sessionID,
    'ses_2',
  );
  assert.equal(
    t.accept({
      type: 'session.tool.failed',
      id: 'tool',
      data: { sessionID: 'ses_1' },
    }),
    null,
  );
});
test('AES-GCM uses CryptoKit combined format and conceals directory metadata', () => {
  const key = Buffer.alloc(32, 9),
    route = {
      serverID: 's',
      sessionID: 'ses_1',
      directory: '/private/project',
      workspace: null,
    };
  const sealed = Buffer.from(
    encryptRoute(route, key.toString('base64')),
    'base64',
  );
  assert.ok(!sealed.includes(Buffer.from('/private/project')));
  const d = createDecipheriv('aes-256-gcm', key, sealed.subarray(0, 12));
  d.setAuthTag(sealed.subarray(-16));
  assert.deepEqual(
    JSON.parse(
      Buffer.concat([d.update(sealed.subarray(12, -16)), d.final()]).toString(),
    ),
    route,
  );
});
test('SSE chunks, CRLF, comments and oversized records', async () => {
  async function* chunks() {
    yield Buffer.from(':keepalive\r\ndata: {"type":');
    yield Buffer.from('"permission.asked"}\r\n\r\n');
  }
  const events = [];
  for await (const e of parseSSE(chunks())) events.push(e);
  assert.equal(events[0].type, 'permission.asked');
  async function* large() {
    yield Buffer.alloc(3 * 1024 * 1024, 97);
  }
  await assert.rejects(async () => {
    for await (const e of parseSSE(large())) {
    }
  }, /too large/);
});
test('connection URL enforces HTTPS except loopback and rejects credentials in URLs', () => {
  assert.equal(serverURL('http://127.0.0.1:4096/'), 'http://127.0.0.1:4096');
  for (const url of [
    'http://192.168.1.3:4096',
    'https://user:password@host.test',
    'https://host.test/?key=secret',
  ])
    assert.throws(() => serverURL(url));
});
test('v2 discovery rejects HTML legacy fallback and validates advertised routes', async (t) => {
  t.mock.method(globalThis, 'fetch', async (url) =>
    String(url).endsWith('/global/health')
      ? new Response('<html>', { headers: { 'content-type': 'text/html' } })
      : String(url).endsWith('/api/health')
        ? Response.json({ data: { healthy: true, pid: 1 } })
        : Response.json({
            paths: {
              '/api/event': { get: {} },
              '/api/session/{sessionID}': { get: {} },
            },
          }),
  );
  assert.equal(
    await detect({
      server: 'http://localhost:4096',
      username: 'opencode',
      password: 'fixture',
    }),
    2,
  );
});

test('outbox serializes concurrent arrivals and acknowledgements without losing events', async () => {
  let disk = [],
    writes = 0;
  const queue = new PendingNotifications([], async (items) => {
    await new Promise((resolve) =>
      setTimeout(resolve, writes++ === 0 ? 20 : 1),
    );
    disk = structuredClone(items);
  });
  const first = { eventID: 'one', createdAt: Date.now() },
    second = { eventID: 'two', createdAt: Date.now() };
  await Promise.all([
    queue.put(first, 1),
    queue.put(second, 2),
    queue.remove('one'),
  ]);
  assert.deepEqual(disk, [{ event: second, version: 2 }]);
  assert.deepEqual(queue.snapshot(), disk);
  const restored = new PendingNotifications(disk, async () => {});
  assert.deepEqual(restored.snapshot(), disk);
});
test('outbox retries failed persistence, deduplicates and expires pending events', async () => {
  let fail = true;
  const queue = new PendingNotifications(
    [{ event: { eventID: 'expired', createdAt: 0 }, version: 1 }],
    async () => {
      if (fail) {
        fail = false;
        throw new Error('disk unavailable');
      }
    },
  );
  const event = { eventID: 'pending', createdAt: Date.now() };
  await assert.rejects(queue.put(event, 1));
  await queue.put(event, 1);
  await queue.put(event, 1);
  assert.equal(queue.snapshot().length, 1);
});
test('legacy completed turns get different event IDs across companion restarts', () => {
  const finish = () => {
    const tracker = new EventTracker();
    tracker.accept(
      v1('session.status', { sessionID: 'ses_1', status: { type: 'busy' } }),
    );
    return tracker.accept(v1('session.idle', { sessionID: 'ses_1' })).eventID;
  };
  assert.notEqual(finish(), finish());
});
