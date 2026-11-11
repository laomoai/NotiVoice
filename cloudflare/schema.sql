-- NotiVoice V1.1 完整基线（全新建库用；已有库请改跑 migrations/001~003）
CREATE TABLE IF NOT EXISTS messages (
 seq INTEGER PRIMARY KEY AUTOINCREMENT,
 id TEXT NOT NULL UNIQUE,
 text TEXT NOT NULL,
 created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
 fetched_at TEXT,
 fetch_count INTEGER NOT NULL DEFAULT 0,
 played_at TEXT,
 voice_slot INTEGER NOT NULL DEFAULT 1,
 source TEXT,
 external_id TEXT,
 title TEXT,
 content TEXT,
 priority TEXT
);
CREATE INDEX IF NOT EXISTS idx_messages_created ON messages(created_at DESC);

CREATE TABLE IF NOT EXISTS device_receipts (
 message_id TEXT NOT NULL,
 device_id TEXT NOT NULL,
 status TEXT NOT NULL,             -- received / played（单调：received < played，不倒退）
 received_at TEXT,
 played_at TEXT,
 PRIMARY KEY (message_id, device_id)
);

CREATE TABLE IF NOT EXISTS ack_events (
 event_id TEXT PRIMARY KEY,         -- 回执幂等键：同一 event_id 只生效一次
 message_id TEXT NOT NULL,
 device_id TEXT NOT NULL,
 status TEXT NOT NULL,
 created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

CREATE TABLE IF NOT EXISTS admin_audit (
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 action TEXT NOT NULL,
 created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
 result TEXT,
 metadata TEXT
);
