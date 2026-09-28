ALTER TABLE subscriptions ADD COLUMN queue_version INTEGER NOT NULL DEFAULT 0;
CREATE TABLE prompt_sessions (
 subscription_id TEXT NOT NULL REFERENCES subscriptions(id) ON DELETE CASCADE,
 thread TEXT NOT NULL,
 paused INTEGER NOT NULL DEFAULT 0,
 PRIMARY KEY(subscription_id,thread)
);
CREATE TABLE prompt_jobs (
 subscription_id TEXT NOT NULL REFERENCES subscriptions(id) ON DELETE CASCADE,
 id TEXT NOT NULL,
 thread TEXT NOT NULL,
 state TEXT NOT NULL DEFAULT 'uploading',
 revision INTEGER NOT NULL DEFAULT 0,
 chunks INTEGER NOT NULL,
 digest TEXT NOT NULL,
 position INTEGER NOT NULL,
 created_at INTEGER NOT NULL,
 updated_at INTEGER NOT NULL,
 PRIMARY KEY(subscription_id,id)
);
CREATE UNIQUE INDEX prompt_one_running ON prompt_jobs(subscription_id,thread)
 WHERE state IN ('claimed','submitted','needsReview');
CREATE TABLE prompt_chunks (
 subscription_id TEXT NOT NULL,
 job_id TEXT NOT NULL,
 revision INTEGER NOT NULL,
 ordinal INTEGER NOT NULL,
 content TEXT NOT NULL,
 PRIMARY KEY(subscription_id,job_id,revision,ordinal),
 FOREIGN KEY(subscription_id,job_id) REFERENCES prompt_jobs(subscription_id,id) ON DELETE CASCADE
);
CREATE INDEX prompt_job_order ON prompt_jobs(subscription_id,thread,position);
