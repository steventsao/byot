import { uuid } from './protocol.ts';

// Ciphertext only. Neither upstream credentials nor prompt plaintext enter this service.
export const CHUNK_SIZE = 512 * 1024;
const MAX_CHUNKS = 80;
const threadPattern = /^[a-f0-9]{64}$/;
type Job = { id: string; thread: string; state: string; revision: number; chunks: number;
  digest: string; position: number; created_at: number; updated_at: number };
const json = (v: unknown, status = 200) => Response.json(v, { status, headers: { 'cache-control': 'no-store' } });
export async function queueRequest(request: Request, db: D1Database, id: string, sender: boolean,
  parts: string[], readBody: (request: Request, limit?: number) => Promise<Record<string, unknown>>) {
  const now = Date.now(), method = request.method;
  const [jobID, action, ordinal] = parts;
  const get = () => db.prepare('SELECT * FROM prompt_jobs WHERE subscription_id=? AND id=?').bind(id, jobID).first<Job>();
  if (!jobID && method === 'GET') {
    const jobs = await db.prepare("SELECT * FROM prompt_jobs WHERE subscription_id=? ORDER BY CASE WHEN state IN ('completed','cancelled') THEN 1 ELSE 0 END,CASE WHEN state IN ('completed','cancelled') THEN -updated_at ELSE position END,id LIMIT 200").bind(id).all<Job>();
    const sessions = await db.prepare('SELECT thread,paused FROM prompt_sessions WHERE subscription_id=?').bind(id).all();
    return json({ jobs: jobs.results, sessions: sessions.results });
  }
  if (jobID === 'sessions' && method === 'PATCH' && !sender) {
    const input = await readBody(request);
    if (!threadPattern.test(String(input.thread)) || typeof input.paused !== 'boolean') return json({ error: 'Invalid session' }, 400);
    await db.prepare('INSERT INTO prompt_sessions(subscription_id,thread,paused) VALUES(?,?,?) ON CONFLICT(subscription_id,thread) DO UPDATE SET paused=excluded.paused')
      .bind(id, input.thread, input.paused ? 1 : 0).run();
    return json({ ok: true });
  }
  if (jobID === 'order' && method === 'PATCH' && !sender) {
    const input = await readBody(request);
    const ids = input.ids;
    if (!threadPattern.test(String(input.thread)) || !Array.isArray(ids) || ids.length > 20 || !ids.every(v => typeof v === 'string' && uuid.test(v)) || new Set(ids).size !== ids.length)
      return json({ error: 'Invalid order' }, 400);
    const current = await db.prepare("SELECT id FROM prompt_jobs WHERE subscription_id=? AND thread=? AND state='queued'").bind(id, input.thread).all<{ id: string }>();
    if (current.results.length !== ids.length || !current.results.every(j => ids.includes(j.id))) return json({ error: 'Queue changed; refresh' }, 409);
    if (ids.length) await db.prepare(`UPDATE prompt_jobs SET position=CASE id ${ids.map(() => 'WHEN ? THEN ?').join(' ')} END,updated_at=? WHERE subscription_id=? AND thread=? AND state='queued'`)
      .bind(...ids.flatMap((v, n) => [v, n]), now, id, input.thread).run();
    return json({ ok: true });
  }
  if (!jobID || !uuid.test(jobID)) return json({ error: 'Not found' }, 404);
  if (!action && method === 'PUT' && !sender) {
    const input = await readBody(request);
    if (!threadPattern.test(String(input.thread)) || !Number.isInteger(input.chunks) || Number(input.chunks) < 1 || Number(input.chunks) > MAX_CHUNKS || !threadPattern.test(String(input.digest)))
      return json({ error: 'Invalid upload' }, 400);
    const existing = await get();
    if (existing) {
      if (existing.thread !== input.thread || (existing.revision === 0 && existing.digest !== input.digest)) return json({ error: 'Prompt ID conflict' }, 409);
      return json(existing);
    }
    // Admission and quota check happen in the same SQLite statement.
    const added = await db.prepare("INSERT INTO prompt_jobs(subscription_id,id,thread,chunks,digest,position,created_at,updated_at) SELECT ?,?,?,?,?,COALESCE(MAX(position),0)+1,?,? FROM prompt_jobs WHERE subscription_id=? HAVING SUM(CASE WHEN state NOT IN ('completed','cancelled') THEN 1 ELSE 0 END)<20 OR COUNT(*)=0 RETURNING *")
      .bind(id, jobID, input.thread, input.chunks, input.digest, now, now, id).first<Job>();
    if (!added) return json({ error: 'Queue is full; remove finished items or wait' }, 409);
    await db.prepare('INSERT OR IGNORE INTO prompt_sessions(subscription_id,thread) VALUES(?,?)').bind(id, input.thread).run();
    return json(added);
  }
  const job = await get();
  if (!job) return json({ error: 'Prompt not found' }, 404);
  if (action === 'chunks') {
    const index = Number(ordinal), revision = Number(new URL(request.url).searchParams.get('revision'));
    if (!Number.isInteger(index) || index < 0 || index >= MAX_CHUNKS || !Number.isInteger(revision) || revision < 1) return json({ error: 'Invalid chunk' }, 400);
    if (method === 'GET') {
      if (revision !== job.revision) return json({ error: 'Revision changed' }, 409);
      const chunk = await db.prepare('SELECT content FROM prompt_chunks WHERE subscription_id=? AND job_id=? AND revision=? AND ordinal=?').bind(id, jobID, revision, index).first();
      return chunk ? json(chunk) : json({ error: 'Chunk not found' }, 404);
    }
    if (method === 'PUT' && !sender) {
      const input = await readBody(request, CHUNK_SIZE + 100);
      if (typeof input.content !== 'string' || input.content.length < 1 || input.content.length > CHUNK_SIZE || !/^[A-Za-z0-9+/=]+$/.test(input.content)) return json({ error: 'Invalid chunk' }, 400);
      const inserted = await db.prepare("INSERT INTO prompt_chunks(subscription_id,job_id,revision,ordinal,content) SELECT ?,?,?,?,? WHERE EXISTS(SELECT 1 FROM prompt_jobs WHERE subscription_id=? AND id=? AND revision=? AND state IN ('uploading','queued')) ON CONFLICT(subscription_id,job_id,revision,ordinal) DO UPDATE SET content=excluded.content RETURNING ordinal")
        .bind(id, jobID, revision, index, input.content, id, jobID, revision - 1).first();
      return inserted ? json({ ok: true }) : json({ error: 'Prompt already started or changed' }, 409);
    }
  }
  if (action === 'commit' && method === 'POST' && !sender) {
    const input = await readBody(request), revision = Number(input.revision), count = Number(input.chunks);
    if (job.revision === revision && job.digest === input.digest) return json(job);
    if (revision !== job.revision + 1 || !Number.isInteger(count) || count < 1 || count > MAX_CHUNKS || !threadPattern.test(String(input.digest))) return json({ error: 'Invalid revision' }, 409);
    const chunks = await db.prepare('SELECT ordinal FROM prompt_chunks WHERE subscription_id=? AND job_id=? AND revision=? ORDER BY ordinal').bind(id, jobID, revision).all<{ordinal:number}>();
    if (chunks.results.length !== count || chunks.results.some((c,i) => c.ordinal !== i)) return json({ error: 'Upload incomplete' }, 409);
    const changed = await db.prepare("UPDATE prompt_jobs SET state='queued',revision=?,chunks=?,digest=?,updated_at=? WHERE subscription_id=? AND id=? AND revision=? AND state IN ('uploading','queued') RETURNING *")
      .bind(revision, count, input.digest, now, id, jobID, revision - 1).first();
    if (!changed) return json({ error: 'Prompt already started or changed' }, 409);
    await db.prepare('DELETE FROM prompt_chunks WHERE subscription_id=? AND job_id=? AND revision<?').bind(id, jobID, revision).run();
    return json(changed);
  }
  if (action === 'claim' && method === 'POST' && sender) {
    const input = await readBody(request);
    const changed = await db.prepare("UPDATE prompt_jobs SET state='claimed',updated_at=? WHERE subscription_id=? AND id=? AND revision=? AND state='queued' AND NOT EXISTS(SELECT 1 FROM prompt_sessions WHERE subscription_id=? AND thread=? AND paused=1) AND NOT EXISTS(SELECT 1 FROM prompt_jobs WHERE subscription_id=? AND thread=? AND state IN ('claimed','submitted','needsReview')) AND id=(SELECT id FROM prompt_jobs WHERE subscription_id=? AND thread=? AND state='queued' ORDER BY position,id LIMIT 1) RETURNING *")
      .bind(now, id, jobID, input.revision, id, job.thread, id, job.thread, id, job.thread).first();
    return changed ? json(changed) : json({ error: 'Queue changed or paused' }, 409);
  }
  if (action === 'state' && method === 'PATCH' && sender) {
    const input = await readBody(request);
    if (!['submitted','completed','needsReview'].includes(String(input.state))) return json({ error: 'Invalid state' }, 400);
    if (job.state === input.state) return json(job);
    const allowed = input.state === 'submitted' ? ['claimed'] : ['claimed','submitted'];
    if (!allowed.includes(job.state)) return json({ error: 'Invalid transition' }, 409);
    const changed = await db.prepare('UPDATE prompt_jobs SET state=?,updated_at=? WHERE subscription_id=? AND id=? AND state=? RETURNING *').bind(input.state, now, id, jobID, job.state).first();
    return changed ? json(changed) : json({ error: 'Queue changed' }, 409);
  }
  if (!action && method === 'DELETE' && !sender) {
    // Never turn a possibly executing job back into queued work.
    if (['claimed','submitted'].includes(job.state)) return json({ error: 'Prompt is running; stop the session first' }, 409);
    const cancelled = await db.prepare("UPDATE prompt_jobs SET state='cancelled',updated_at=? WHERE subscription_id=? AND id=? AND state NOT IN ('claimed','submitted') RETURNING id").bind(now, id, jobID).first();
    return cancelled ? json({ ok: true }) : json({ error: 'Prompt just started; refresh' }, 409);
  }
  return json({ error: 'Method not allowed' }, 405);
}

export async function cleanQueue(db: D1Database, now: number) {
  await db.batch([
    db.prepare("DELETE FROM prompt_jobs WHERE state IN ('completed','cancelled') AND updated_at<?").bind(now - 7 * 86400000),
    db.prepare("DELETE FROM prompt_jobs WHERE state='uploading' AND updated_at<?").bind(now - 7 * 86400000),
    db.prepare('DELETE FROM prompt_chunks WHERE NOT EXISTS(SELECT 1 FROM prompt_jobs WHERE subscription_id=prompt_chunks.subscription_id AND id=prompt_chunks.job_id)'),
  ]);
}
