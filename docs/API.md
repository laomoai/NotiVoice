# Noti Voice API V1.1

> **接口根地址（Base URL）**：`https://notivoice.laomo.app`。下文所有 `/api/...` 路径均为相对该根地址，实际请求需拼接完整 URL，例如 `https://notivoice.laomo.app/api/notifications`。切勿只写 `/api/notifications`（curl 会报 `No host part in the URL`）。

## 鉴权模型（双 Token，V1.1 变更）

V1.1 把 Token 拆成两个，互相拒绝：

- **`API_TOKEN`**：业务接口用（提交 / 拉取 / 回执）。配置：`wrangler secret put API_TOKEN`。
- **`ADMIN_TOKEN`**：后台管理接口专用。配置：`wrangler secret put ADMIN_TOKEN`。

| 接口 | 所需 Token |
|---|---|
| `POST /api/notifications`、`POST /api/post` | `API_TOKEN` |
| `GET /api/notifications`、`GET /api/play` | `API_TOKEN` |
| `POST /api/notifications/ack` | `API_TOKEN` |
| `GET/POST /api/admin/*` | `ADMIN_TOKEN` |

规则：用 `API_TOKEN` 调后台接口 → **401**；用 `ADMIN_TOKEN` 调业务接口 → **401**。后台登录页只接受 `ADMIN_TOKEN`，填 `API_TOKEN` 会被明确拒绝并提示。根页面 `/` 与 `/admin` 公开，但其中的数据请求仍需对应 Token。

> 客户端在「通用设置」中填写 `API_TOKEN`，存于 **macOS Keychain**（非 UserDefaults / 明文）；`ADMIN_TOKEN` 仅供后台网页使用，不进客户端。

## POST /api/notifications（提交消息）

请求：`Content-Type: application/json` + `Authorization: Bearer <API_TOKEN>`。

**新字段（推荐）**：
```json
{"source":"github","external_id":"issue-123","title":"标题","content":"正文内容","priority":"high","voice_slot":2}
```
- `source` + `external_id` 组合**幂等**：重复提交同一对不生成新消息，返回 `{"ok":true,"duplicate":true,...}`。用于外部系统重试不重复播报。
- `title` / `content` / `priority`（`low|normal|high`，默认 `normal`）/ `voice_slot`（`1|2|3`，默认 `1`）。播报文本取 `content || title || text`。
- 未带 `external_id` 则按 UUID 生成新消息（非幂等）。

**旧字段（兼容，V1.1 仍支持）**：
```json
{"text":"会议将在 10 分钟后开始，请做好准备","voice":2}
```
`text` 与 `voice` 自动映射到 `content` / `voice_slot`。**别名**：`POST /api/post` 等价，便于老客户端无缝升级。

**体积限制（双层）**：
- 播报文本（trim 后）：**1 ～ 1000 字符**，空或超长 → `400 invalid_text`。
- 整个请求体：`content-length` **≤ 8192 字节**，超出 → `413 payload_too_large`。
- 速率：`60 次 / 分钟 / IP`，超出 → `429 rate_limited`。

响应（新）：`201 {"ok":true,"id":"uuid","seq":123,"created_at":"...","voice_slot":2,"text":"正文内容"}`。
响应（旧，幂等重复）：`200 {"ok":true,"id":...,"seq":...,"duplicate":true}`。

## GET /api/notifications（增量拉取）

`GET /api/notifications?after=<cursor>&limit=50`。返回按 `seq` 升序的增量消息：
```json
{"messages":[{"seq":1,"id":"uuid","text":"...","title":"...","content":"...","priority":"normal","voice_slot":1,"created_at":"...","source":"github","external_id":"issue-123"}],"next_cursor":1,"has_more":false}
```
- `after` 为上次返回的 `next_cursor`；`limit` 1–200；`has_more` 为是否可能还有数据的提示。
- **V1.1 关键变更**：GET **不再写入 `fetched_at`**（GET 不能证明客户端已收到）。「已接收」只能由客户端显式回执（`/ack`）确认。后台状态判定以设备回执为准；旧版客户端（仅发 `{"seqs":[...]}`，只写 `messages.played_at`）会兜底显示「已播报 · 旧版回执」，不会被误判为未送达。
- **别名**：`GET /api/play` 等价。

## POST /api/notifications/ack（设备回执，V1.1 重写）

客户端持久化本地后发 `received`、播报完成后发 `played`。**按设备、幂等、单调、多设备隔离**。

**新回执**：
```json
{"device_id":"<uuid>","message_id":"<uuid>","status":"received","event_id":"<uuid>"}
```
- `status`：`received` 或 `played`。
- `event_id`：**客户端生成的幂等键**，重复提交同一 `event_id` 直接成功（`{"ok":true,"duplicate":true,"applied":false}`），不重复副作用。
- 状态单调：`pending < received < played`。迟到 `received` 不覆盖已有的 `played`；`played` 先于 `received` 到达视为已 `received`。**状态不允许倒退**。
- 多设备隔离：每台设备的回执独立记录。

**旧回执（兼容）**：`{"seqs":[3,4]}` → 直接把对应 `seq` 的 `played_at` 写成当前时间（按 `seq` 标记播放）。仍支持。

响应：`{"ok":true,"status":"played","applied":true}`。

**409 冲突响应**：`{"error":"event_conflict","existing":{...},"submitted":{...}}`。

**并发与幂等语义（V1.1.2 加固，FIX-04）**：
- 事件写入与设备回执推进在 **D1 batch 同一事务**内完成，无"先查后插"竞态窗口。
- 同一 `event_id` 重复提交（相同载荷）→ 幂等成功 `{"duplicate":true,"applied":false}`。
- 同一 `event_id` 携带不同载荷（`message_id`/`device_id`/`status` 任一不同）→ **HTTP 409** `{"error":"event_conflict",...}`，整批回滚，不产生半提交。
- 设备状态只允许 `received → played` 单调推进（条件 UPSERT），乱序/迟到不倒退；`received_at` 保留最早值。

## GET /api/admin/notifications（后台查询，含设备回执）

`Authorization: Bearer <ADMIN_TOKEN>`，返回最近 200 条，每条带 `receipts` 数组：
```json
{"messages":[{"seq":1,"id":"uuid","text":"...","voice_slot":1,"created_at":"...",
  "receipts":[{"message_id":"uuid","device_id":"<uuid>","status":"played","received_at":"...","played_at":"..."}]}]}
```
后台据此按设备渲染回执，并以「任一设备 played / 任一设备 received / 无回执」判定单条消息状态。

## GET /api/admin/audit（操作审计日志，V1.1 新增）

`Authorization: Bearer <ADMIN_TOKEN>`，返回最近 100 条后台操作（如 `clear`）：
```json
{"audit":[{"id":1,"action":"clear","created_at":"...","result":"ok","metadata":"{\"deleted\":6,\"by\":\"::1\"}"}]}
```

## POST /api/admin/notifications/clear（清空全部消息）

`Authorization: Bearer <ADMIN_TOKEN>`，**删除 D1 中全部消息 + 设备回执 + 回执事件**（一并清理，避免孤儿数据），不可恢复，并写入审计日志。返回 `{"ok":true,"deleted":N}`。

```bash
curl -X POST 'https://notivoice.laomo.app/api/admin/notifications/clear' \
  -H 'Authorization: Bearer 你的ADMIN_TOKEN'
```

## curl 测试

```bash
API='你的API_TOKEN'; ADM='你的ADMIN_TOKEN'
# 提交（新字段）
curl -X POST 'https://notivoice.laomo.app/api/notifications' \
  -H 'Content-Type: application/json' -H "Authorization: Bearer $API" \
  -d '{"source":"test","external_id":"x1","content":"会议将在 10 分钟后开始","priority":"high","voice_slot":2}'
# 拉取
curl -H "Authorization: Bearer $API" 'https://notivoice.laomo.app/api/notifications?after=0&limit=10'
# 回执（新）
curl -X POST 'https://notivoice.laomo.app/api/notifications/ack' \
  -H 'Content-Type: application/json' -H "Authorization: Bearer $API" \
  -d '{"device_id":"dev-uuid","message_id":"<上一步返回的id>","status":"played","event_id":"ev-uuid"}'
# 后台（需 ADMIN_TOKEN）
curl -H "Authorization: Bearer $ADM" 'https://notivoice.laomo.app/api/admin/notifications'
```
