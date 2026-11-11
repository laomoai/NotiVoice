-- 为已存在的 D1 数据库补齐「读取 / 播报」状态列（新库由 schema.sql 直接建好）。
-- 重复执行会报 duplicate column name，属预期；先查 PRAGMA table_info(messages) 再执行更稳妥。
ALTER TABLE messages ADD COLUMN fetched_at TEXT;
ALTER TABLE messages ADD COLUMN fetch_count INTEGER NOT NULL DEFAULT 0;
ALTER TABLE messages ADD COLUMN played_at TEXT;
