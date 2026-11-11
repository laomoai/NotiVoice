-- FIX-04：ack_events 载荷冲突触发器
-- 同一 event_id 重复提交（相同载荷）由主键 + ON CONFLICT DO NOTHING 幂等吸收；
-- 同一 event_id 但载荷不同（message_id/device_id/status 任一不同）→ RAISE(ABORT) 中止整批，
-- 由 Worker 捕获后返回 409，杜绝"先查后插"竞态下的静默吞并。
CREATE TRIGGER IF NOT EXISTS trg_ack_events_payload_conflict
BEFORE INSERT ON ack_events
WHEN EXISTS (
  SELECT 1 FROM ack_events
  WHERE event_id = NEW.event_id
    AND (message_id <> NEW.message_id OR device_id <> NEW.device_id OR status <> NEW.status)
)
BEGIN
  SELECT RAISE(ABORT, 'event_conflict');
END;
