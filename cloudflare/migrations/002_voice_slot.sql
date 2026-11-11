-- 消息可指定音色槽位 #1 / #2 / #3（默认 1）；已有行默认落 #1。
-- 重复执行会报 duplicate column name，属预期。
ALTER TABLE messages ADD COLUMN voice_slot INTEGER NOT NULL DEFAULT 1;
