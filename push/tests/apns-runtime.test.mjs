import { test } from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, verify } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';

// Exercise fetch and WebCrypto inside workerd, not Node's more permissive fetch.
// Apple is the only mocked boundary; no production credentials are used.
test('Workers runtime sends valid APNs authentication and never follows redirects', async (t) => {
  const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' });
  const bundle = await build({
    stdin: {
      contents: `import { sendAPNS } from './src/apns.ts';
        export default { async fetch(request, env) {
          try {
            return Response.json(await sendAPNS(env, 'a'.repeat(64), 'production',
              '11111111-1111-4111-8111-111111111111', {
                eventID: 'runtime-check', kind: 'test', route: 'A'.repeat(80),
                thread: 'b'.repeat(64), createdAt: Date.now()
              }));
          } catch { return new Response('APNs transport failed', {status: 503}); }
        }};`,
      resolveDir: fileURLToPath(new URL('../', import.meta.url)),
    },
    bundle: true,
    write: false,
    format: 'esm',
    platform: 'neutral',
  });
  let redirect = false, calls = 0;
  const mf = new Miniflare(convertV4MiniflareOptions({
    modules: true,
    script: bundle.outputFiles[0].text,
    compatibilityDate: '2026-09-19',
    compatibilityFlags: ['nodejs_compat'],
    bindings: {
      APNS_KEY_ID: 'TESTKEY123',
      APNS_TEAM_ID: 'TESTTEAM12',
      APNS_TOPIC: 'com.example.byot',
      APNS_PRIVATE_KEY: privateKey.export({ type: 'pkcs8', format: 'pem' }),
    },
    outboundService: async (request) => {
      calls++;
      assert.equal(request.url, 'https://api.push.apple.com/3/device/' + 'a'.repeat(64));
      assert.equal(request.method, 'POST');
      assert.equal(request.headers.get('apns-topic'), 'com.example.byot');
      const [header, claims, signature] = request.headers.get('authorization').slice(7).split('.');
      assert.deepEqual(JSON.parse(Buffer.from(header, 'base64url')), { alg: 'ES256', kid: 'TESTKEY123' });
      const decoded = JSON.parse(Buffer.from(claims, 'base64url'));
      assert.equal(decoded.iss, 'TESTTEAM12');
      assert.ok(Math.abs(decoded.iat - Date.now() / 1000) < 60);
      assert.equal(verify('sha256', Buffer.from(`${header}.${claims}`), {
        key: publicKey, dsaEncoding: 'ieee-p1363',
      }, Buffer.from(signature, 'base64url')), true);
      assert.equal((await request.json()).aps.alert.title, 'Push notifications are working');
      return redirect
        ? new Response(null, { status: 307, headers: { location: 'https://must-not-follow.invalid/' } })
        : new Response(null, { status: 200 });
    },
  }));
  t.after(() => mf.dispose());
  const accepted = await mf.dispatchFetch('https://runtime.test/');
  assert.equal(accepted.status, 200);
  assert.deepEqual(await accepted.json(), { status: 200, reason: '' });
  redirect = true;
  assert.equal((await mf.dispatchFetch('https://runtime.test/')).status, 503);
  assert.equal(calls, 2, 'the redirect must not trigger another request with credentials');
});
