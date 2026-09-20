import { payload, type Event } from './protocol.ts';
export type APNSSecrets = { APNS_KEY_ID: string; APNS_PRIVATE_KEY: string };
// Reuse the provider token for 50 minutes; Apple rejects excessive token updates.
// This cache contains only service credentials, never request/user state.
let cached:
  | { identity: string; expires: number; token: Promise<string> }
  | undefined;
async function providerToken(env: Env & APNSSecrets): Promise<string> {
  const identity = `${env.APNS_TEAM_ID}:${env.APNS_KEY_ID}:${env.APNS_PRIVATE_KEY}`;
  if (cached?.identity === identity && cached.expires > Date.now())
    return cached.token;
  const token = (async () => {
    const encode = (v: unknown) =>
      Buffer.from(JSON.stringify(v)).toString('base64url');
    const header = encode({ alg: 'ES256', kid: env.APNS_KEY_ID });
    const claims = encode({
      iss: env.APNS_TEAM_ID,
      iat: Math.floor(Date.now() / 1000),
    });
    const pem = env.APNS_PRIVATE_KEY.replace(/-----[^-]+-----|\s/g, '');
    const key = await crypto.subtle.importKey(
      'pkcs8',
      Buffer.from(pem, 'base64'),
      { name: 'ECDSA', namedCurve: 'P-256' },
      false,
      ['sign'],
    );
    const signature = await crypto.subtle.sign(
      { name: 'ECDSA', hash: 'SHA-256' },
      key,
      new TextEncoder().encode(`${header}.${claims}`),
    );
    return `${header}.${claims}.${Buffer.from(signature).toString('base64url')}`;
  })();
  cached = { identity, expires: Date.now() + 50 * 60_000, token };
  try {
    return await token;
  } catch (error) {
    if (cached?.token === token) cached = undefined;
    throw error;
  }
}
export async function sendAPNS(
  env: Env & APNSSecrets,
  token: string,
  environment: string,
  subscriptionID: string,
  event: Event,
) {
  const jwt = await providerToken(env);
  const host =
    environment === 'sandbox'
      ? 'api.sandbox.push.apple.com'
      : 'api.push.apple.com';
  const response = await fetch(`https://${host}/3/device/${token}`, {
    method: 'POST',
    // Workers does not implement redirect: 'error'. Manual mode keeps the
    // provider JWT and device token on the fixed Apple endpoint.
    redirect: 'manual',
    signal: AbortSignal.timeout(15000),
    headers: {
      authorization: `bearer ${jwt}`,
      'apns-topic': env.APNS_TOPIC,
      'apns-push-type': 'alert',
      'apns-priority': '10',
      'apns-expiration': String(Math.floor(event.createdAt / 1000) + 3600),
      'apns-collapse-id': event.thread.slice(0, 32) + event.kind,
      'content-type': 'application/json',
    },
    body: JSON.stringify(payload(subscriptionID, event)),
  });
  if (response.status >= 300 && response.status < 400) {
    await response.body?.cancel();
    throw new Error('APNs redirects are not allowed');
  }
  // Apple error responses are tiny; do not log token, JWT or payload.
  const body = await response.text();
  let reason = '';
  try {
    reason = JSON.parse(body).reason ?? '';
  } catch {
    /* no response body on success */
  }
  return { status: response.status, reason };
}
