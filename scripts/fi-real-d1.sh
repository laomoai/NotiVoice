#!/usr/bin/env bash
# NotiVoice V1.1.2 真实远程 D1 故障注入演练
# 目标：在真实 Cloudflare D1（非 miniflare 本地模拟）上验证 FIX-04 的 batch 原子性、
#       幂等、409 冲突、状态单调与并发，并注入 batch 中途失败验证整批回滚。
# 前提：一个隔离的临时 Worker（独立 workers.dev 子域）+ 隔离的临时 D1（已跑 schema.sql）。
# 用法：bash scripts/fi-real-d1.sh <base_url> <api_token> <admin_token> <d1_name>
set -u
B=${1:?base_url}
API=${2:?api_token}
ADM=${3:?admin_token}
DB=${4:?d1_name}
CF_DIR="$(cd "$(dirname "$0")/../cloudflare" && pwd)"
TRIG_SQL="$CF_DIR/tmp/fi_abort_trigger.sql"
DROP_SQL="$CF_DIR/tmp/fi_drop_trigger.sql"
pass=0; fail=0

ok(){ if [ "$2" = "$3" ]; then echo "PASS $1"; pass=$((pass+1)); else echo "FAIL $1 (期望 $3, 实际 $2)"; fail=$((fail+1)); fi; }
jget(){ python3 -c "import sys,json;d=json.load(sys.stdin);print($1)" 2>/dev/null; }
sql_json(){ (cd "$CF_DIR" && npx wrangler d1 execute "$DB" --remote --json --command "$1" 2>/dev/null); }
sql_file(){ (cd "$CF_DIR" && npx wrangler d1 execute "$DB" --remote --json --file="$1" 2>/dev/null); }
scalar(){ python3 -c "import sys,json;d=json.load(sys.stdin);r=d[0]['results'];print(r[0][list(r[0].keys())[0]] if r else 'NO_ROWS')" 2>/dev/null; }
qv(){ sql_json "$1" | scalar; }
qv_file(){ sql_file "$1" | scalar; }
ack_body(){ printf '{"device_id":"%s","message_id":"%s","status":"%s","event_id":"%s"}' "$1" "$MID" "$2" "$3"; }
ack(){ curl -s -X POST "$B/api/notifications/ack" -H "Authorization: Bearer $API" -H 'Content-Type: application/json' -d "$(ack_body "$1" "$2" "$3")"; }
ack_code(){ curl -s -o /dev/null -w '%{http_code}' -X POST "$B/api/notifications/ack" -H "Authorization: Bearer $API" -H 'Content-Type: application/json' -d "$(ack_body "$1" "$2" "$3")"; }

echo "===== FI-00 建立隔离测试消息 ====="
MSG=$(curl -s -X POST "$B/api/notifications" -H "Authorization: Bearer $API" -H 'Content-Type: application/json' \
  -d '{"source":"fi","external_id":"fi-20261112-1","title":"FI","content":"fault injection","priority":"normal"}')
MID=$(echo "$MSG" | jget 'd.get("id","")')
ok "FI-00 测试消息创建成功" "$([ -n "$MID" ] && echo 1 || echo 0)" "1"

echo "===== FI-01 正常回执推进 + 双时间戳 ====="
R1=$(ack "fiDevA" "received" "fi-ev-1")
ok "FI-01 received 200" "$(echo "$R1" | jget '1 if d.get("ok") else 0')" "1"
R2=$(ack "fiDevA" "played" "fi-ev-2")
ok "FI-01 played 200" "$(echo "$R2" | jget '1 if d.get("ok") else 0')" "1"
ok "FI-01 状态推进到 played" "$(qv "SELECT status FROM device_receipts WHERE message_id='$MID' AND device_id='fiDevA';")" "played"
ok "FI-01 received_at/played_at 均保留" "$(qv "SELECT COUNT(*) FROM device_receipts WHERE message_id='$MID' AND device_id='fiDevA' AND received_at IS NOT NULL AND played_at IS NOT NULL;")" "1"

echo "===== FI-02 同 event_id 异载荷 → 409 + 整批回滚（真实 D1） ====="
ok "FI-02 异载荷返回 409" "$(ack_code "fiDevX" "received" "fi-ev-1")" "409"
ok "FI-02 冲突批次未产生新设备回执" "$(qv "SELECT COUNT(*) FROM device_receipts WHERE device_id='fiDevX';")" "0"
ok "FI-02 既有回执未被改动" "$(qv "SELECT status FROM device_receipts WHERE message_id='$MID' AND device_id='fiDevA';")" "played"

echo "===== FI-03 同一 event_id 并发 20 次（真实 D1 跨请求） ====="
for i in $(seq 1 20); do
  curl -s -X POST "$B/api/notifications/ack" -H "Authorization: Bearer $API" -H 'Content-Type: application/json' \
    -d "$(ack_body "fiDevP" "received" "fi-ev-par")" >/dev/null &
done
wait
ok "FI-03 ack_events 恰好 1 行" "$(qv "SELECT COUNT(*) FROM ack_events WHERE event_id='fi-ev-par';")" "1"
ok "FI-03 device_receipts 恰好 1 行" "$(qv "SELECT COUNT(*) FROM device_receipts WHERE message_id='$MID' AND device_id='fiDevP';")" "1"

echo "===== FI-04 乱序 played→received 不倒退 + 设备隔离 ====="
ack "fiDevO" "played" "fi-ev-o1" >/dev/null
ack "fiDevO" "received" "fi-ev-o2" >/dev/null
ok "FI-04 乱序后仍 played" "$(qv "SELECT status FROM device_receipts WHERE message_id='$MID' AND device_id='fiDevO';")" "played"
ok "FI-04 乱序后双时间戳均在" "$(qv "SELECT COUNT(*) FROM device_receipts WHERE message_id='$MID' AND device_id='fiDevO' AND received_at IS NOT NULL AND played_at IS NOT NULL;")" "1"
ok "FI-04 设备隔离：fiDevP 仍 received" "$(qv "SELECT status FROM device_receipts WHERE message_id='$MID' AND device_id='fiDevP';")" "received"

echo "===== FI-05 batch 中途失败注入（真实 D1 触发器 ABORT） ====="
cat > "$TRIG_SQL" <<'SQL'
CREATE TRIGGER IF NOT EXISTS trg_fi_abort
BEFORE INSERT ON device_receipts
WHEN NEW.device_id = 'FI_ABORT_SENTINEL'
BEGIN
  SELECT RAISE(ABORT, 'fi_injected_abort');
END;
SQL
printf 'DROP TRIGGER IF EXISTS trg_fi_abort;\n' > "$DROP_SQL"
sql_file "$TRIG_SQL" >/dev/null
C=$(ack_code "FI_ABORT_SENTINEL" "received" "fi-ev-abort-1")
CFIRST=$(printf '%s' "${C}" | cut -c1)
ok "FI-05 注入失败返回非 2xx（实际 ${C}）" "$([ "$CFIRST" = "2" ] && echo 0 || echo 1)" "1"
ok "FI-05 第①条 ack_events 一并回滚（无半提交）" "$(qv "SELECT COUNT(*) FROM ack_events WHERE event_id='fi-ev-abort-1';")" "0"
ok "FI-05 第②条 device_receipts 未落库" "$(qv "SELECT COUNT(*) FROM device_receipts WHERE device_id='FI_ABORT_SENTINEL';")" "0"
sql_file "$DROP_SQL" >/dev/null

echo "===== FI-06 故障恢复后同一 event_id 重试成功 ====="
R6=$(ack "FI_ABORT_SENTINEL" "received" "fi-ev-abort-1")
ok "FI-06 重试成功" "$(echo "$R6" | jget '1 if d.get("ok") else 0')" "1"
ok "FI-06 重试后恰好 1 个事件" "$(qv "SELECT COUNT(*) FROM ack_events WHERE event_id='fi-ev-abort-1';")" "1"
ok "FI-06 重试幂等（duplicate）" "$(ack "FI_ABORT_SENTINEL" "received" "fi-ev-abort-1" | jget '1 if d.get("duplicate") else 0')" "1"

echo ""
echo "===== 结果：$pass 通过 / $fail 失败 ====="
[ "$fail" = "0" ] && echo "ALL PASS" || echo "HAS FAILURES"
rm -f "$TRIG_SQL" "$DROP_SQL"
