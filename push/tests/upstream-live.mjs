// Requires scripts/e2e/fixtures.py, with BYOT_PUSH_LIVE_ROOT pointing to its fresh root.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID, createDecipheriv } from 'node:crypto';
import {
  detect,
  parseSSE,
  EventTracker,
  notification,
} from '../public/byot-notify.mjs';
const root = process.env.BYOT_PUSH_LIVE_ROOT;
assert.ok(
  root,
  'Set BYOT_PUSH_LIVE_ROOT to an isolated upstream fixture directory',
);
for (const version of [1, 2])
  test(
    `real OpenCode ${version} stream produces routable alerts`,
    { timeout: 60000 },
    async () => {
      const config = {
        server: `http://127.0.0.1:${version === 1 ? 4196 : 4197}`,
        username: 'opencode',
        password: 'byot-local-fixture-only',
        serverID: randomUUID(),
        subscriptionID: randomUUID(),
        routeKey: Buffer.alloc(32, 9).toString('base64'),
      };
      assert.equal(await detect(config), version);
      const directory = `${root}/v${version}/project`,
        prefix = version === 2 ? '/api' : '';
      const headers = {
        authorization:
          'Basic ' +
          Buffer.from(`${config.username}:${config.password}`).toString(
            'base64',
          ),
        'content-type': 'application/json',
      };
      const post = async (path, body) => {
        const r = await fetch(config.server + path, {
          method: 'POST',
          headers,
          body: JSON.stringify(body),
          signal: AbortSignal.timeout(15000),
        });
        assert.ok(r.ok, `${r.status}: ${await r.clone().text()}`);
        return r.status === 204 ? null : r.json();
      };
      const abort = new AbortController();
      const timeout = setTimeout(() => abort.abort(), 50000);
      const stream = await fetch(
        config.server + (version === 2 ? '/api/event' : '/global/event'),
        { headers, signal: abort.signal },
      );
      assert.ok(stream.ok);
      const events = [],
        types = new Set(),
        tracker = new EventTracker();
      const collect = (async () => {
        try {
          for await (const raw of parseSSE(stream.body)) {
            types.add((raw.payload ?? raw).type);
            const event = tracker.accept(raw);
            if (event) events.push(event);
          }
        } catch (e) {
          if (!abort.signal.aborted) throw e;
        }
      })();
      try {
        const sessionRaw = await post(
          prefix +
            '/session' +
            (version === 1
              ? '?directory=' + encodeURIComponent(directory)
              : ''),
          version === 2
            ? {
                title: 'Push live fixture',
                location: { directory },
                model: { providerID: 'fixture', id: 'test' },
              }
            : { title: 'Push live fixture' },
        );
        const session = version === 2 ? sessionRaw.data : sessionRaw;
        if (version === 2) {
          await post(`${prefix}/session/${session.id}/form`, {
            title: 'Push form',
            fields: [{ key: 'speed', type: 'string', required: true }],
          });
          await post(`${prefix}/session/${session.id}/permission`, {
            action: 'byot_acceptance',
            resources: ['fixture.txt'],
            source: {
              type: 'tool',
              messageID: 'msg_' + randomUUID().replaceAll('-', ''),
              id: 'call_' + randomUUID(),
            },
          });
        }
        await post(
          `${prefix}/session/${session.id}/${version === 2 ? 'prompt' : 'prompt_async?directory=' + encodeURIComponent(directory)}`,
          version === 2
            ? { text: 'Say BYOT upstream compatibility verified.' }
            : {
                model: { providerID: 'fixture', modelID: 'test' },
                parts: [
                  {
                    type: 'text',
                    text: 'Say BYOT upstream compatibility verified.',
                  },
                ],
              },
        );
        const required =
          version === 2 ? ['complete', 'question', 'permission'] : ['complete'];
        for (
          let i = 0;
          i < 200 &&
          !required.every((kind) =>
            events.some((e) => e.kind === kind && e.sessionID === session.id),
          );
          i++
        )
          await new Promise((resolve) => setTimeout(resolve, 200));
        for (const kind of required) {
          const event = events.find(
            (e) => e.kind === kind && e.sessionID === session.id,
          );
          assert.ok(
            event,
            `Missing ${kind}; actual event types: ${[...types]}`,
          );
          const item = await notification(config, version, event);
          assert.equal(item.kind, kind);
          const bytes = Buffer.from(item.route, 'base64'),
            cipher = createDecipheriv(
              'aes-256-gcm',
              Buffer.alloc(32, 9),
              bytes.subarray(0, 12),
            );
          cipher.setAuthTag(bytes.subarray(-16));
          const route = JSON.parse(
            Buffer.concat([
              cipher.update(bytes.subarray(12, -16)),
              cipher.final(),
            ]),
          );
          assert.equal(route.serverID, config.serverID);
          assert.equal(route.sessionID, session.id);
          assert.equal(route.directory, directory);
        }
      } finally {
        clearTimeout(timeout);
        abort.abort();
        await collect;
      }
    },
  );
