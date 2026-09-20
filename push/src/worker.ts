import {
  hash,
  kinds,
  parseEvent,
  randomSecret,
  secretPattern,
  uuid,
} from './protocol.ts';
import { sendAPNS, type APNSSecrets } from './apns.ts';

type Row = {
  id: string;
  owner_hash: string;
  sender_hash: string | null;
  device_token: string;
  environment: string;
  server_id: string;
  enabled: number;
  kinds: string;
  muted_threads: string;
  pair_key: string | null;
  paired_at: number | null;
  last_seen: number | null;
};
const json = (body: unknown, status = 200) =>
  Response.json(body, { status, headers: { 'cache-control': 'no-store' } });
class HTTPError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}
async function body(request: Request): Promise<Record<string, unknown>> {
  if (
    !(request.headers.get('content-type') ?? '').startsWith('application/json')
  )
    throw new HTTPError(415, 'JSON required');
  if (Number(request.headers.get('content-length') ?? 0) > 8192)
    throw new HTTPError(413, 'Request too large');
  const reader = request.body?.getReader();
  if (!reader) throw new HTTPError(400, 'Body required');
  const parts: Uint8Array[] = [];
  let size = 0;
  try {
    while (true) {
      const chunk = await reader.read();
      if (chunk.done) break;
      size += chunk.value.length;
      if (size > 8192) throw new HTTPError(413, 'Request too large');
      parts.push(chunk.value);
    }
  } finally {
    await reader.cancel();
  }
  try {
    const v = JSON.parse(Buffer.concat(parts).toString());
    if (v && typeof v === 'object' && !Array.isArray(v)) return v;
  } catch {}
  throw new HTTPError(400, 'Invalid JSON');
}
async function authorization(request: Request) {
  const bearer = request.headers
    .get('authorization')
    ?.match(/^Bearer ([A-Za-z0-9_-]+)$/)?.[1];
  if (!bearer || !secretPattern.test(bearer))
    throw new HTTPError(401, 'Unauthorized');
  return hash(bearer);
}
function status(row: Row) {
  return {
    paired: !!row.paired_at,
    enabled: !!row.enabled,
    kinds: JSON.parse(row.kinds),
    mutedThreads: JSON.parse(row.muted_threads),
    lastSeen: row.last_seen,
  };
}

export default {
  async fetch(request: Request, env: Env & APNSSecrets): Promise<Response> {
    try {
      const url = new URL(request.url);
      if (request.method === 'GET' && url.pathname === '/health')
        return json({
          service: 'byot-push',
          ready: !!env.APNS_KEY_ID && !!env.APNS_PRIVATE_KEY,
        });
      if (request.method === 'GET' && url.pathname === '/byot-notify.mjs')
        return env.ASSETS.fetch(request);
      if (!url.pathname.startsWith('/v1/'))
        return json({ error: 'Not found' }, 404);
      const limit = await env.RATE_LIMITER.limit({
        key: request.headers.get('cf-connecting-ip') ?? 'local',
      });
      if (!limit.success) return json({ error: 'Too many requests' }, 429);
      const now = Date.now();
      if (url.pathname === '/v1/pair' && request.method === 'POST') {
        const input = await body(request);
        const code = String(input.code ?? '')
          .replace(/-/g, '')
          .toUpperCase();
        if (!/^[A-F0-9]{24}$/.test(code))
          throw new HTTPError(400, 'Invalid pairing code');
        const sender = randomSecret();
        // Atomic consume: only one caller can exchange this code.
        const row = await env.DB.prepare(
          'UPDATE subscriptions SET sender_hash=?, paired_at=?, pair_hash=NULL, pair_expires=NULL WHERE pair_hash=? AND pair_expires>? RETURNING *',
        )
          .bind(await hash(sender), now, await hash(code), now)
          .first<Row>();
        if (!row)
          throw new HTTPError(410, 'Pairing code expired or already used');
        await env.DB.prepare(
          'UPDATE subscriptions SET pair_key=NULL WHERE id=?',
        )
          .bind(row.id)
          .run();
        return json({
          subscriptionID: row.id,
          senderKey: sender,
          routeKey: row.pair_key,
          serverID: row.server_id,
        });
      }
      const match = url.pathname.match(
        /^\/v1\/subscriptions\/([0-9a-f-]+)(?:\/(pair|events|test|heartbeat))?$/i,
      );
      if (!match || !uuid.test(match[1])) throw new HTTPError(404, 'Not found');
      const [, id, action] = match;
      const auth = await authorization(request);
      if (!action && request.method === 'PUT') {
        const input = await body(request);
        if (
          typeof input.deviceToken !== 'string' ||
          !/^[a-f0-9]{32,512}$/.test(input.deviceToken) ||
          !['production', 'sandbox'].includes(String(input.environment)) ||
          !uuid.test(String(input.serverID))
        )
          throw new HTTPError(400, 'Invalid registration');
        await env.DB.prepare(
          'INSERT OR IGNORE INTO subscriptions (id,owner_hash,device_token,environment,server_id,created_at,updated_at) VALUES (?,?,?,?,?,?,?)',
        )
          .bind(
            id,
            auth,
            input.deviceToken,
            input.environment,
            input.serverID,
            now,
            now,
          )
          .run();
        const result = await env.DB.prepare(
          'UPDATE subscriptions SET device_token=?,environment=?,updated_at=? WHERE id=? AND owner_hash=? AND server_id=? RETURNING *',
        )
          .bind(
            input.deviceToken,
            input.environment,
            now,
            id,
            auth,
            input.serverID,
          )
          .first<Row>();
        if (!result) throw new HTTPError(403, 'Forbidden');
        return json(status(result));
      }
      const row = await env.DB.prepare('SELECT * FROM subscriptions WHERE id=?')
        .bind(id)
        .first<Row>();
      if (!row) throw new HTTPError(404, 'Subscription not found');
      const senderAction = action === 'events' || action === 'heartbeat';
      // Compare hashes in SQL rather than comparing untrusted secrets in JavaScript.
      const authorized = await env.DB.prepare(
        `SELECT id FROM subscriptions WHERE id=? AND ${senderAction ? 'sender_hash' : 'owner_hash'}=?`,
      )
        .bind(id, auth)
        .first();
      if (!authorized) throw new HTTPError(403, 'Forbidden');
      if (!action && request.method === 'GET') return json(status(row));
      if (!action && request.method === 'DELETE') {
        await env.DB.prepare('DELETE FROM subscriptions WHERE id=?')
          .bind(id)
          .run();
        return json({ deleted: true });
      }
      if (!action && request.method === 'PATCH') {
        const input = await body(request);
        if (
          typeof input.enabled !== 'boolean' ||
          !Array.isArray(input.kinds) ||
          input.kinds.length > 4 ||
          !input.kinds.every((k) => kinds.includes(k) && k !== 'test') ||
          !Array.isArray(input.mutedThreads) ||
          input.mutedThreads.length > 100 ||
          !input.mutedThreads.every(
            (t) => typeof t === 'string' && /^[a-f0-9]{64}$/.test(t),
          )
        )
          throw new HTTPError(400, 'Invalid preferences');
        await env.DB.prepare(
          'UPDATE subscriptions SET enabled=?,kinds=?,muted_threads=?,updated_at=? WHERE id=?',
        )
          .bind(
            input.enabled ? 1 : 0,
            JSON.stringify(input.kinds),
            JSON.stringify(input.mutedThreads),
            now,
            id,
          )
          .run();
        return json({ updated: true });
      }
      if (action === 'pair' && request.method === 'POST') {
        const input = await body(request);
        if (
          typeof input.routeKey !== 'string' ||
          !/^[A-Za-z0-9+/]{43}=$/.test(input.routeKey)
        )
          throw new HTTPError(400, 'Invalid route key');
        const code = Buffer.from(crypto.getRandomValues(new Uint8Array(12)))
          .toString('hex')
          .toUpperCase();
        await env.DB.prepare(
          'UPDATE subscriptions SET pair_hash=?,pair_expires=?,pair_key=? WHERE id=?',
        )
          .bind(await hash(code), now + 600000, input.routeKey, id)
          .run();
        return json({
          code: code.match(/.{4}/g)!.join('-'),
          expiresAt: now + 600000,
        });
      }
      if (action === 'heartbeat' && request.method === 'POST') {
        await env.DB.prepare('UPDATE subscriptions SET last_seen=? WHERE id=?')
          .bind(now, id)
          .run();
        return json({ ok: true });
      }
      if (
        (action === 'events' || action === 'test') &&
        request.method === 'POST'
      ) {
        let event;
        try {
          event = parseEvent(await body(request), now);
        } catch {
          throw new HTTPError(400, 'Invalid or expired event');
        }
        if ((action === 'test') !== (event.kind === 'test'))
          throw new HTTPError(400, 'Invalid event kind');
        if (
          !row.enabled ||
          (action !== 'test' &&
            (!JSON.parse(row.kinds).includes(event.kind) ||
              JSON.parse(row.muted_threads).includes(event.thread)))
        )
          return json({ delivery: 'muted' });
        if (!env.APNS_KEY_ID || !env.APNS_PRIVATE_KEY)
          throw new HTTPError(503, 'Push delivery is not configured');
        const claimed = await env.DB.prepare(
          "INSERT INTO deliveries (subscription_id,event_id,state,lease_until,expires_at) VALUES (?,?,'pending',?,?) ON CONFLICT(subscription_id,event_id) DO UPDATE SET lease_until=excluded.lease_until WHERE state='pending' AND lease_until<? RETURNING event_id",
        )
          .bind(id, event.eventID, now + 30000, now + 86400000, now)
          .first();
        if (!claimed) {
          const existing = await env.DB.prepare(
            'SELECT state FROM deliveries WHERE subscription_id=? AND event_id=?',
          )
            .bind(id, event.eventID)
            .first<{ state: string }>();
          return json(
            { delivery: existing?.state === 'sent' ? 'duplicate' : 'retry' },
            existing?.state === 'sent' ? 200 : 503,
          );
        }
        try {
          const result = await sendAPNS(
            env,
            row.device_token,
            row.environment,
            id,
            event,
          );
          if (result.status === 200) {
            await env.DB.prepare(
              "UPDATE deliveries SET state='sent' WHERE subscription_id=? AND event_id=?",
            )
              .bind(id, event.eventID)
              .run();
            return json({ delivery: 'accepted' });
          }
          if (
            result.status === 410 ||
            result.reason === 'BadDeviceToken' ||
            result.reason === 'DeviceTokenNotForTopic'
          ) {
            await env.DB.prepare(
              'UPDATE subscriptions SET enabled=0 WHERE id=? AND device_token=?',
            )
              .bind(id, row.device_token)
              .run();
            throw new HTTPError(410, 'Device must register again');
          }
          throw new HTTPError(503, 'Apple did not accept the notification');
        } finally {
          await env.DB.prepare(
            "UPDATE deliveries SET lease_until=0 WHERE subscription_id=? AND event_id=? AND state='pending'",
          )
            .bind(id, event.eventID)
            .run();
        }
      }
      throw new HTTPError(405, 'Method not allowed');
    } catch (error) {
      return json(
        {
          error:
            error instanceof HTTPError
              ? error.message
              : 'Push service unavailable',
        },
        error instanceof HTTPError ? error.status : 503,
      );
    }
  },
  async scheduled(_controller: ScheduledController, env: Env) {
    await env.DB.batch([
      env.DB.prepare('DELETE FROM deliveries WHERE expires_at<?').bind(
        Date.now(),
      ),
      env.DB.prepare(
        'UPDATE subscriptions SET pair_hash=NULL,pair_expires=NULL,pair_key=NULL WHERE pair_expires<?',
      ).bind(Date.now()),
      env.DB.prepare(
        'DELETE FROM subscriptions WHERE paired_at IS NULL AND created_at<?',
      ).bind(Date.now() - 86400000),
    ]);
  },
} satisfies ExportedHandler<Env & APNSSecrets>;
