import { test } from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';
import { generateKeyPairSync, randomUUID } from 'node:crypto';
import worker from '../src/worker.ts';
import { payload, randomSecret } from '../src/protocol.ts';
const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' });
function fixture() {
  const db = new DatabaseSync(':memory:');
  db.exec('PRAGMA foreign_keys=ON');
  db.exec(
    readFileSync(
      new URL('../migrations/0001_push.sql', import.meta.url),
      'utf8',
    ),
  );
  const wrap = (sql, args = []) => ({
    bind(...a) {
      return wrap(sql, a);
    },
    async first() {
      return db.prepare(sql).get(...args) ?? null;
    },
    async run() {
      return db.prepare(sql).run(...args);
    },
  });
  const env = {
    DB: {
      prepare: (sql) => wrap(sql),
      batch: async (l) => Promise.all(l.map((s) => s.run())),
    },
    RATE_LIMITER: { limit: async () => ({ success: true }) },
    APNS_TEAM_ID: '449BD89VDV',
    APNS_TOPIC: 'com.steventsao.byot',
    APNS_KEY_ID: 'TEST',
    APNS_PRIVATE_KEY: privateKey.export({ type: 'pkcs8', format: 'pem' }),
  };
  const id = randomUUID(),
    owner = randomSecret(),
    serverID = randomUUID();
  const call = (method, path = '', body, key = owner) =>
    worker.fetch(
      new Request('https://relay.test/v1/subscriptions/' + id + path, {
        method,
        headers: {
          authorization: 'Bearer ' + key,
          'content-type': 'application/json',
        },
        ...(body ? { body: JSON.stringify(body) } : {}),
      }),
      env,
    );
  const register = () =>
    call('PUT', '', {
      deviceToken: 'a'.repeat(64),
      environment: 'production',
      serverID,
    });
  const event = (kind = 'complete') => ({
    eventID: randomUUID(),
    kind,
    route: 'A'.repeat(80),
    thread: 'b'.repeat(64),
    createdAt: Date.now(),
  });
  const exchange = (code) =>
    worker.fetch(
      new Request('https://relay.test/v1/pair', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ code }),
      }),
      env,
    );
  const makeCode = async () =>
    (
      await (
        await call('POST', '/pair', {
          routeKey: Buffer.alloc(32, 9).toString('base64'),
        })
      ).json()
    ).code;
  const pair = async () => {
    await register();
    const code = await makeCode();
    return { ...(await (await exchange(code)).json()), code };
  };
  return {
    db,
    env,
    id,
    serverID,
    call,
    register,
    event,
    pair,
    makeCode,
    exchange,
  };
}
test('owner authentication, single-use pairing, expiry, sender separation and revocation', async () => {
  const f = fixture();
  await f.register();
  assert.equal((await f.call('GET', '', null, randomSecret())).status, 403);
  assert.equal(
    (
      await f.call(
        'PUT',
        '',
        {
          deviceToken: 'b'.repeat(64),
          environment: 'production',
          serverID: f.serverID,
        },
        randomSecret(),
      )
    ).status,
    403,
  );
  const p = await f.pair();
  assert.equal(p.serverID, f.serverID);
  assert.equal(Buffer.from(p.routeKey, 'base64').length, 32);
  assert.equal((await f.exchange(p.code)).status, 410);
  assert.equal(
    f.db.prepare('SELECT pair_key FROM subscriptions').get().pair_key,
    null,
  );
  assert.equal(
    (
      await f.call(
        'PATCH',
        '',
        { enabled: false, kinds: [], mutedThreads: [] },
        p.senderKey,
      )
    ).status,
    403,
  );
  const next = await f.pair();
  assert.equal(
    (await f.call('POST', '/heartbeat', {}, p.senderKey)).status,
    403,
  );
  assert.equal(
    (await f.call('POST', '/heartbeat', {}, next.senderKey)).status,
    200,
  );
  const code = await f.makeCode();
  f.db.exec('UPDATE subscriptions SET pair_expires=0');
  assert.equal((await f.exchange(code)).status, 410);
  await f.call('DELETE');
  assert.equal(
    (await f.call('POST', '/events', f.event(), next.senderKey)).status,
    404,
  );
});
test('muted subscriptions, kinds and sessions never call APNs', async (t) => {
  const f = fixture(),
    p = await f.pair();
  t.mock.method(globalThis, 'fetch', () => assert.fail('must not call Apple'));
  for (const settings of [
    { enabled: false, kinds: ['complete'], mutedThreads: [] },
    { enabled: true, kinds: ['error'], mutedThreads: [] },
    { enabled: true, kinds: ['complete'], mutedThreads: ['b'.repeat(64)] },
  ]) {
    await f.call('PATCH', '', settings);
    assert.equal(
      (await (await f.call('POST', '/events', f.event(), p.senderKey)).json())
        .delivery,
      'muted',
    );
  }
});
test('APNs headers, private payload, acceptance and duplicate delivery', async (t) => {
  const f = fixture(),
    p = await f.pair();
  let calls = 0,
    authorization;
  t.mock.method(globalThis, 'fetch', async (url, o) => {
    calls++;
    if (authorization) assert.equal(o.headers.authorization, authorization);
    authorization = o.headers.authorization;
    assert.match(url, /api.push.apple.com/);
    assert.equal(o.headers['apns-topic'], 'com.steventsao.byot');
    assert.equal(o.headers['apns-push-type'], 'alert');
    assert.equal(o.headers.authorization.split('.').length, 3);
    const data = JSON.parse(o.body);
    assert.equal(data.byot.subscriptionID, f.id);
    assert.equal(data.aps.alert.title, 'Turn finished');
    return new Response(null, { status: 200 });
  });
  const e = f.event();
  assert.equal(
    (await (await f.call('POST', '/events', e, p.senderKey)).json()).delivery,
    'accepted',
  );
  assert.equal(
    (await (await f.call('POST', '/events', e, p.senderKey)).json()).delivery,
    'duplicate',
  );
  assert.equal(calls, 1);
  assert.equal(
    (await f.call('POST', '/events', f.event(), p.senderKey)).status,
    200,
  );
  assert.equal(calls, 2);
  assert.doesNotMatch(
    JSON.stringify(
      payload(f.id, {
        ...e,
        title: 'secret',
        body: 'source code',
        password: 'password',
      }),
    ),
    /secret|source code|password/,
  );
});
test('APNs transient failures retry and invalid tokens disable further delivery', async (t) => {
  const f = fixture(),
    p = await f.pair();
  let status = 503;
  t.mock.method(
    globalThis,
    'fetch',
    async () =>
      new Response(
        JSON.stringify({
          reason: status === 410 ? 'Unregistered' : 'ServiceUnavailable',
        }),
        { status },
      ),
  );
  const e = f.event();
  assert.equal((await f.call('POST', '/events', e, p.senderKey)).status, 503);
  status = 200;
  assert.equal((await f.call('POST', '/events', e, p.senderKey)).status, 200);
  status = 410;
  assert.equal(
    (await f.call('POST', '/events', f.event(), p.senderKey)).status,
    410,
  );
  assert.equal((await (await f.call('GET')).json()).enabled, false);
});
test('bounds and schema validation, stale events, and missing APNs configuration', async () => {
  const f = fixture(),
    p = await f.pair();
  assert.equal(
    (
      await f.call(
        'POST',
        '/events',
        { ...f.event(), createdAt: 0 },
        p.senderKey,
      )
    ).status,
    400,
  );
  assert.equal(
    (await f.call('POST', '/events', f.event('test'), p.senderKey)).status,
    400,
  );
  assert.equal(
    (await f.call('POST', '/test', f.event('permission'))).status,
    400,
  );
  assert.equal(
    (await f.call('POST', '/pair', { padding: 'x'.repeat(9000) })).status,
    413,
  );
  delete f.env.APNS_PRIVATE_KEY;
  assert.equal(
    (await f.call('POST', '/events', f.event(), p.senderKey)).status,
    503,
  );
});
