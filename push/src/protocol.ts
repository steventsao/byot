export const kinds = [
  'permission',
  'question',
  'complete',
  'error',
  'test',
] as const;
export type Kind = (typeof kinds)[number];
export type Event = {
  eventID: string;
  kind: Kind;
  route: string;
  thread: string;
  createdAt: number;
};
export const uuid =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const secretPattern = /^[A-Za-z0-9_-]{43}$/;
export function parseEvent(value: unknown, now = Date.now()): Event {
  if (!value || typeof value !== 'object') throw new Error('Invalid event');
  const e = value as Record<string, unknown>;
  if (
    typeof e.eventID !== 'string' ||
    !/^[a-zA-Z0-9_-]{1,128}$/.test(e.eventID) ||
    !kinds.includes(e.kind as Kind) ||
    typeof e.route !== 'string' ||
    !/^[A-Za-z0-9+/=]{40,2800}$/.test(e.route) ||
    typeof e.thread !== 'string' ||
    !/^[a-f0-9]{64}$/.test(e.thread) ||
    typeof e.createdAt !== 'number' ||
    !Number.isFinite(e.createdAt) ||
    e.createdAt < now - 3600_000 ||
    e.createdAt > now + 60_000
  ) {
    throw new Error('Invalid or expired event');
  }
  return {
    eventID: e.eventID,
    kind: e.kind as Kind,
    route: e.route,
    thread: e.thread,
    createdAt: e.createdAt,
  };
}
export function payload(subscriptionID: string, event: Event) {
  const copy: Record<Kind, [string, string]> = {
    permission: [
      'Approval needed',
      'Open byot to review an OpenCode permission request.',
    ],
    question: [
      'OpenCode has a question',
      'Open byot to answer and continue the session.',
    ],
    complete: ['Turn finished', 'Your OpenCode session is ready to review.'],
    error: [
      'Session needs attention',
      'Open byot to review an OpenCode error.',
    ],
    test: [
      'Push notifications are working',
      'byot can now notify you while the app is closed.',
    ],
  };
  const [title, body] = copy[event.kind];
  return {
    aps: {
      alert: { title, body },
      sound: 'default',
      'thread-id': event.thread,
    },
    byot: { version: 1, subscriptionID, kind: event.kind, route: event.route },
  };
}
export async function hash(value: string) {
  return Buffer.from(
    await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value)),
  ).toString('hex');
}
export function randomSecret() {
  return Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString(
    'base64url',
  );
}
