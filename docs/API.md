# Noti Voice API V1.0

## 统一鉴权（所有 /api/* 接口）
所有接口共用**同一个** Bearer Token：`Authorization: Bearer <API_TOKEN>`。Token 由 `wrangler secret put API_TOKEN` 配置，全项目只此一个值，后台登录也用它。未带或错误的 Token 一律返回 `401 {"error":"unauthorized"}`。根页面 `/` 本身公开，但其中的数据请求与测试命令都需要 Token。

当前共用 Token（非机密，客户端默认值与本地 `.dev.vars` 已写入）：`6c8db15bf637cd0815f6551a54d18178015395912666cdd8`

## POST /api/notifications
请求：`Content-Type: application/json` + `Authorization: Bearer <API_TOKEN>`，`{"text":"BTC 现价 68,200 美元，触发止盈提醒","voice":2}`。

**体积限制（双层）**：
- `text` 字段：trim 后 **1 ～ 1000 字符**，空或超长返回 `400 invalid_text`。
- 整个请求体：`content-length` **≤ 8192 字节**，超出返回 `413 payload_too_large`。实际由 text 上限主导，正常不会触及 8KB。

`voice` 可选，取值 `1|2|3`（数字）或 `"#1"|"#2"|"#3"`，默认 `1`。它只是**音色槽位编号**，客户端把 #1/#2/#3 映射到本机设置里填的三个 Fish Audio `reference_id`；槽位没配 ID 会回退 #1，#1 也空则用模型默认音色。非法值返回 `400 invalid_voice`。

响应：`201 {"ok":true,"id":"uuid","seq":123,"created_at":"...","voice_slot":2}`。

## GET /api/notifications?after=0&limit=50
返回按 `seq` 升序的增量消息：
```json
{"messages":[{"seq":1,"id":"uuid","text":"BTC 现价 68,200 美元，触发止盈提醒","created_at":"2026-11-11T00:00:00.000Z"}],"next_cursor":1,"has_more":false}
```
`after` 为上次返回的 `next_cursor`。`limit` 1–100。`has_more` 为是否可能还有数据的提示（当返回量等于 limit 时为 true，可能下一页为空）。

可选 `status` 过滤（不影响默认行为）：`pending`（仅返回 `played_at` 为空，即待播报）、`played`（仅返回已播报）。不传或传其它值等同于原 `seq>after` 全量增量返回——客户端正常轮询只传 `after`，即可覆盖「崩溃重连重新拉取已取走未播报」的场景。

调用即视为「已被取走」：服务端会为返回的消息写入 `fetched_at`（首次取走时间，不覆盖）并把 `fetch_count` 加 1。`messages` 每项还带 `fetched_at / fetch_count / played_at` 三个状态字段。

## POST /api/notifications/ack
客户端播报成功后回执，请求：`{"seqs":[3,4]}`（1–100 个正整数），响应 `{"ok":true,"acked":2}`。
把对应消息的 `played_at` 写成当前时间（不覆盖已有值）。仅标记，不会重复投递或播报。同样需要共用 Token。

## GET /api/admin/notifications
`Authorization: Bearer <API_TOKEN>`，返回最近 200 条，字段为 `seq,id,text,created_at,fetched_at,fetch_count,played_at,voice_slot`。Web 后台页面在 `/`，据此显示三态标签：

| 状态 | 判定 | 含义 |
|---|---|---|
| 未读取 | `fetched_at` 为空 | POST 刚推入，还没有任何客户端取走 |
| 已读取 · 未播报 | `fetched_at` 有值、`played_at` 为空 | 已被 `/api/notifications` 返回；首次同步跳过历史、或客户端还没播完/回执失败 |
| 已播报 | `played_at` 有值 | 客户端播报成功并回执 |

后台每 5 秒自动刷新，并提供一条可复制的 POST 测试命令，便于观察状态流转。后台还提供「清空全部消息」按钮（需二次确认），调用下方接口。

## POST /api/admin/notifications/clear
`Authorization: Bearer <API_TOKEN>`，**删除 D1 中全部消息**（含已播报 / 未播报），不可恢复。返回 `{"ok":true,"deleted":N}`。无 Token 返回 401。仅建议测试或需重置时使用。

```bash
curl -X POST 'https://notivoice.laomo.app/api/admin/notifications/clear' \
  -H 'Authorization: Bearer 6c8db15bf637cd0815f6551a54d18178015395912666cdd8'
# => {"ok":true,"deleted":15}
```

## curl 测试
```bash
TOKEN='6c8db15bf637cd0815f6551a54d18178015395912666cdd8'
curl -X POST 'https://notivoice.laomo.app/api/notifications' \
  -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" \
  -d '{"text":"BTC 现价 68,200 美元，触发止盈提醒","voice":2}'
curl -H "Authorization: Bearer $TOKEN" \
  'https://notivoice.laomo.app/api/notifications?after=0&limit=10'
```
