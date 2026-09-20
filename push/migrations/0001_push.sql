CREATE TABLE subscriptions (
 id TEXT PRIMARY KEY,
 owner_hash TEXT NOT NULL,
 sender_hash TEXT,
 device_token TEXT NOT NULL,
 environment TEXT NOT NULL CHECK(environment IN ('sandbox','production')),
 server_id TEXT NOT NULL,
 enabled INTEGER NOT NULL DEFAULT 1,
 kinds TEXT NOT NULL DEFAULT '["permission","question","complete","error"]',
 muted_threads TEXT NOT NULL DEFAULT '[]',
 pair_hash TEXT UNIQUE,
 pair_expires INTEGER,
 pair_key TEXT,
 paired_at INTEGER,
 last_seen INTEGER,
 created_at INTEGER NOT NULL,
 updated_at INTEGER NOT NULL
);
CREATE TABLE deliveries (
 subscription_id TEXT NOT NULL REFERENCES subscriptions(id) ON DELETE CASCADE,
 event_id TEXT NOT NULL,
 state TEXT NOT NULL,
 lease_until INTEGER NOT NULL,
 expires_at INTEGER NOT NULL,
 PRIMARY KEY(subscription_id,event_id)
);
CREATE INDEX deliveries_expiry ON deliveries(expires_at);
