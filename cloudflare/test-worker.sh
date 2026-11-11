#!/usr/bin/env bash
# NotiVoice V1.1 Worker 本地集成测试（wrangler dev @ localhost:8787 + 本地 D1）
# 覆盖：T01 连续提交/顺序、T06 回执幂等/乱序不倒退、T12 多设备隔离、T13 Token 分离拒绝、T14 后台允许、T16 幂等提交、旧 seqs 兼容、GET 不写 fetched_at
set -u
B=http://localhost:8787
API=test_api_token_123
ADM=test_admin_token_456
pass=0; fail=0
jget(){ python3 -c "import sys,json;d=json.load(sys.stdin);print($1)" 2>/dev/null; }
ok(){ if [ "$2" = "$3" ]; then echo "PASS $1"; pass=$((pass+1)); else echo "FAIL $1 (期望 $3, 实际 $2)"; fail=$((fail+1)); fi; }

echo "===== 准备：清空本地库 ====="
curl -s -X POST "$B/api/admin/notifications/clear" -H "Authorization: Bearer $ADM" >/dev/null

echo "===== T16 幂等提交（source+external_id 重复） ====="
R1=$(curl -s -X POST "$B/api/notifications" -H "Authorization: Bearer $API" -H 'Content-Type: application/json' -d '{"source":"t","external_id":"e1","title":"标题A","content":"正文A","priority":"high","voice":2}')
R2=$(curl -s -X POST "$B/api/notifications" -H "Authorization: Bearer $API" -H 'Content-Type: application/json' -d '{"source":"t","external_id":"e1","title":"标题A","content":"正文A","priority":"high","voice":2}')
ok "T16 首次 201" "$(echo "$R1"|jget '1 if d.get("ok") and d.get("seq") else 0')" "1"
ok "T16 重复 200+duplicate" "$(echo "$R2"|jget '1 if d.get("ok") and d.get("duplicate") else 0')" "1"

echo "===== T01 连续提交 5 条 + 顺序拉取 ====="
for i in 1 2 3 4 5; do curl -s -X POST "$B/api/notifications" -H "Authorization: Bearer $API" -H 'Content-Type: application/json' -d "{\"text\":\"消息$i\",\"voice\":1}" >/dev/null; done
POLL=$(curl -s "$B/api/notifications?after=0&limit=50" -H "Authorization: Bearer $API")
# 含前面 T16 幂等测试建的 1 条，共 6
N=$(echo "$POLL"|jget 'len(d["messages"])')
ok "T01 拉取条数=6(含T16的1条)" "$N" "6"
SEQASC=$(echo "$POLL"|python3 -c "import sys,json;m=json.load(sys.stdin)['messages'];print(1 if m==sorted(m,key=lambda x:x['seq']) else 0)")
ok "T01 seq 升序" "$SEQASC" "1"

echo "===== GET 不写 fetched_at（T02/3 前置：服务端不证明已收） ====="
FA=$(echo "$POLL"|jget '1 if d["messages"][0]["fetched_at"] is None else 0')
ok "GET 后 fetched_at 仍为空" "$FA" "1"

echo "===== T13 Token 分离：API_TOKEN 调后台被拒 ====="
C1=$(curl -s -o /dev/null -w '%{http_code}' "$B/api/admin/notifications" -H "Authorization: Bearer $API")
ok "T13 API_TOKEN→后台 401" "$C1" "401"

echo "===== T14 后台：ADMIN_TOKEN 允许 / API_TOKEN 拒绝 ====="
C2=$(curl -s -o /dev/null -w '%{http_code}' "$B/api/admin/notifications" -H "Authorization: Bearer $ADM")
C3=$(curl -s -o /dev/null -w '%{http_code}' "$B/api/admin/notifications/clear" -H "Authorization: Bearer $API")
ok "T14 ADMIN_TOKEN→后台 200" "$C2" "200"
ok "T14 API_TOKEN→清库 401" "$C3" "401"

echo "===== 取一条 message_id 做回执测试 ====="
MID=$(echo "$POLL"|jget 'd["messages"][0]["id"]')

echo "===== T06 回执单调：received→played 推进；乱序 played→received 不倒退 ====="
# 设备 A：先 received 再 played
curl -s -X POST "$B/api/notifications/ack" -H "Authorization: Bearer $API" -H 'Content-Type: application/json' -d "{\"device_id\":\"devA\",\"message_id\":\"$MID\",\"status\":\"received\",\"event_id\":\"ev-A-1\"}" >/dev/null
curl -s -X POST "$B/api/notifications/ack" -H "Authorization: Bearer $API" -H 'Content-Type: application/json' -d "{\"device_id\":\"devA\",\"message_id\":\"$MID\",\"status\":\"played\",\"event_id\":\"ev-A-2\"}" >/dev/null
# 设备 B：先 played（应视为已 received）再 received（迟到，不得倒退）
curl -s -X POST "$B/api/notifications/ack" -H "Authorization: Bearer $API" -H 'Content-Type: application/json' -d "{\"device_id\":\"devB\",\"message_id\":\"$MID\",\"status\":\"played\",\"event_id\":\"ev-B-1\"}" >/dev/null
curl -s -X POST "$B/api/notifications/ack" -H "Authorization: Bearer $API" -H 'Content-Type: application/json' -d "{\"device_id\":\"devB\",\"message_id\":\"$MID\",\"status\":\"received\",\"event_id\":\"ev-B-2\"}" >/dev/null
ADMJSON=$(curl -s "$B/api/admin/notifications" -H "Authorization: Bearer $ADM")
# 提取 devA / devB 的 status
STA=$(echo "$ADMJSON"|python3 -c "import sys,json;d=json.load(sys.stdin);m=[x for x in d['messages'] if x['id']=='$MID'][0];print([r['status'] for r in m['receipts'] if r['device_id']=='devA'][0])")
STB=$(echo "$ADMJSON"|python3 -c "import sys,json;d=json.load(sys.stdin);m=[x for x in d['messages'] if x['id']=='$MID'][0];print([r['status'] for r in m['receipts'] if r['device_id']=='devB'][0])")
ok "T06 设备A 最终 played" "$STA" "played"
ok "T12/T06 设备B 乱序后仍 played（不倒退）" "$STB" "played"

echo "===== T06 幂等 event_id：重复返回 duplicate ====="
DUP=$(curl -s -X POST "$B/api/notifications/ack" -H "Authorization: Bearer $API" -H 'Content-Type: application/json' -d "{\"device_id\":\"devA\",\"message_id\":\"$MID\",\"status\":\"played\",\"event_id\":\"ev-A-2\"}")
ok "T06 重复 event_id → duplicate" "$(echo "$DUP"|jget '1 if d.get("duplicate") else 0')" "1"

echo "===== T12 多设备隔离：devC 不继承 devA 的 played ====="
curl -s -X POST "$B/api/notifications/ack" -H "Authorization: Bearer $API" -H 'Content-Type: application/json' -d "{\"device_id\":\"devC\",\"message_id\":\"$MID\",\"status\":\"received\",\"event_id\":\"ev-C-1\"}" >/dev/null
STC=$(curl -s "$B/api/admin/notifications" -H "Authorization: Bearer $ADM"|python3 -c "import sys,json;d=json.load(sys.stdin);m=[x for x in d['messages'] if x['id']=='$MID'][0];print([r['status'] for r in m['receipts'] if r['device_id']=='devC'][0])")
ok "T12 设备C 仅 received（不被 A 覆盖）" "$STC" "received"

echo "===== 旧 seqs 回执兼容 ====="
SEQ1=$(echo "$POLL"|jget 'd["messages"][1]["seq"]')
OLD=$(curl -s -X POST "$B/api/notifications/ack" -H "Authorization: Bearer $API" -H 'Content-Type: application/json' -d "{\"seqs\":[$SEQ1]}")
ok "旧 seqs 回执 ok" "$(echo "$OLD"|jget '1 if d.get("ok") else 0')" "1"

echo "===== 未知 message_id 回执 → 404 ====="
UNK=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$B/api/notifications/ack" -H "Authorization: Bearer $API" -H 'Content-Type: application/json' -d '{"device_id":"dx","message_id":"nope","status":"received","event_id":"ev-x"}')
ok "未知 message_id → 404" "$UNK" "404"

echo "===== 非法 status → 400 ====="
BAD=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$B/api/notifications/ack" -H "Authorization: Bearer $API" -H 'Content-Type: application/json' -d "{\"device_id\":\"dx\",\"message_id\":\"$MID\",\"status\":\"bogus\",\"event_id\":\"ev-y\"}")
ok "非法 status → 400" "$BAD" "400"

echo "===== 限流/未授权 ====="
NOAUTH=$(curl -s -o /dev/null -w '%{http_code}' "$B/api/notifications")
ok "无 Token → 401" "$NOAUTH" "401"

echo ""
echo "===== 结果：$pass 通过 / $fail 失败 ====="
[ "$fail" = "0" ] && echo "ALL PASS" || echo "HAS FAILURES"
