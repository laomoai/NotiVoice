-- V1.1 增量迁移：在现有 messages 表上新增字段，并新建设备级回执相关表。
-- 原则：仅 ALTER 加列 + 新建表，绝不 DROP / 重建现有生产表，避免破坏已有数据。
-- 重复执行安全：加列重复报 "duplicate column name" 属预期；建表用 IF NOT EXISTS。
-- 迁移前请先备份：wrangler d1 execute noti-voice --remote --command ".dump messages" > backup_messages.sql

-- 消息支持来源/幂等键/标题/正文/优先级（旧 {text,voice} 调用方仍兼容，text 字段保留）
ALTER TABLE messages ADD COLUMN source TEXT;
ALTER TABLE messages ADD COLUMN external_id TEXT;
ALTER TABLE messages ADD COLUMN title TEXT;
ALTER TABLE messages ADD COLUMN content TEXT;
ALTER TABLE messages ADD COLUMN priority TEXT;

-- 设备级回执：同一消息按设备分别记录状态，互不覆盖
CREATE TABLE IF NOT EXISTS device_receipts (
  message_id  TEXT    NOT NULL,
  device_id   TEXT    NOT NULL,
  status      TEXT    NOT NULL,            -- received | played
  received_at TEXT,
  played_at   TEXT,
  PRIMARY KEY (message_id, device_id)
);

-- 回执事件幂等键：相同 event_id 重试返回成功，不重复副作用
CREATE TABLE IF NOT EXISTS ack_events (
  event_id    TEXT    NOT NULL PRIMARY KEY,
  message_id  TEXT    NOT NULL,
  device_id   TEXT,
  status      TEXT,
  created_at  TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

-- 后台管理审计（清库等敏感操作留痕）
CREATE TABLE IF NOT EXISTS admin_audit (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  action      TEXT    NOT NULL,
  created_at  TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  result      TEXT,
  metadata    TEXT
);
