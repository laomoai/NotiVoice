# 更新日志

## V1.1.1（2026-11-11）

### 客户端（macOS）

- **启动自检状态机**：新增 `Health` 状态（checking / paused / offHours / unconfigured / invalidToken / unreachable / dbFallback / playing / ok）。启动即执行一次完整检查（配置 → 网络 → 鉴权），菜单栏状态灯与文案按真实结果渲染，不再以 enabled 开关冒充"运行中"。
  - 未填 API Token → 橙灯「待配置」；Token 无效(401) → 红灯；连不上服务器 → 红灯；连接正常 → 绿灯「运行中 · 已连接」。
  - 本地 SQLite 打开失败降级到临时目录库时 → 橙灯「本地库降级运行」。
  - 播放中 → 「播报中」；暂停 / 不在播报时段 → 灰灯。
- 构建修复：`health=.x`（`=` 紧跟点成员）触发 Swift 6 诊断，统一 `health = .x`。

## V1.1.0（2026-11-11）

可靠消息播报大版本：双 Token 鉴权、设备级回执、本地 SQLite 持久化、At-Least-Once 投递、崩溃恢复。

### 后端（Cloudflare Worker + D1）

- **双 Token**：`API_TOKEN`（提交/拉取/回执）与 `ADMIN_TOKEN`（后台）互相拒绝；校验改用常量时间比较。
- **消息模型扩展**：`messages` 新增 `source / external_id / title / content / priority`；`source + external_id` 提交幂等（重复返回 `duplicate:true`）。
- **设备级回执**：新表 `device_receipts`（按 `message_id + device_id` 记录 `received/played`）与 `ack_events`（`event_id` 幂等）。回执单调（`received < played`，不倒退）、多设备隔离；旧 `{"seqs":[...]}` 回执仍兼容。
- **GET 不再写 `fetched_at`**：「取走」不等于「收到」，`received` 只能由客户端显式回执确认。
- **审计**：新表 `admin_audit` 与 `GET /api/admin/audit`；清空消息一并删除回执与回执事件并写审计。
- **兼容别名**：`POST /api/post`、`GET /api/play` 保留，老客户端无缝升级。
- 迁移：`migrations/003_message_fields.sql`（增量、可重复执行校验，已应用到生产 D1）。

### 客户端（macOS）

- **本地 SQLite 持久化（系统 C API，无 GRDB）**：WAL + `busy_timeout` + `foreign_keys`，单一串行执行器，`user_version` 迁移；播放记录迁入 SQLite（替代 `history.json`）。
- **事务原子入库**：消息入库 + 建待播任务 + 游标推进 + 写 received Outbox 在**同一事务**；提交前崩溃不前进（T02），提交后可恢复（T03）。
- **串行播放协调器**：自动播报 / 手动重播 / 测试语音共用一个队列，互不抢占（T11）；播放完成以 delegate 回调为准（非轮询 `isPlaying`，T04）。
- **失败重试**：指数退避（封顶 60s），达阈值转 `needs_attention` 保留不删除，可手动重试（T08）；重启时 `playing` 重排为 `queued`（崩溃恢复，允许少量重复播报但绝不丢消息）。
- **ACK Outbox**：回执先落库再投递，每 5 秒重试未确认回执（T05）；Keychain 存 API Token 与 Fish Key 两个服务。
- **可靠性面板**：菜单栏显示待播 / 需人工处理 / 未确认回执计数与最近同步时间。

### 后台页面

- 登录改用 `ADMIN_TOKEN`（填 `API_TOKEN` 明确提示被拒）。
- 每条消息展示**设备级回执**（设备短 ID、received/played、时间戳）；状态判定改为「任一设备 played / received / 无回执」。
- 新增**操作审计日志**区块；清空操作二次确认文案升级。
- **修复**：状态判定补旧版兜底——V1.0 客户端只发 `{"seqs":[...]}`（仅写 `messages.played_at`，无 `device_receipts`），原逻辑只认设备回执会误判「未送达」。现按 `设备回执 > played_at(旧版) > fetched_at(旧版) > 无` 判定，徽章区分「已播报·任一设备 / 已播报·旧版回执 / 已送达·未播报 / 已拉取·未播报(旧版) / 未送达」，并在无设备回执时给出升级提示。
- **修复**：后台「复制测试命令」原先用登录的 `ADMIN_TOKEN` 拼 curl，打业务接口必然 401。现新增独立「API Token（推送用）」输入框（独立 `localStorage: nv_api_token`，带显示/隐藏切换），curl 只用它；未填时给出明确提示而非生成错误命令。

### 测试与验证

- Worker 集成测试 `cloudflare/test-worker.sh`：**16/16 通过**（本地 `wrangler dev`，覆盖 T01/T06/T12/T13/T14/T16 + 旧接口兼容 + 错误码）。
- 客户端单元测试 `mac/Tests/NotiVoiceTests/PersistenceTests.swift`：**8/8 通过**（覆盖入库+游标原子性、幂等计数、崩溃恢复重排、失败退避与人工重试、ACK Outbox 重试、重开库持久化、device_id 稳定、到期任务选取；T02/T03/T04/T05/T08/T17/T18 对应逻辑）。
- 单元测试捕获并修复三个关键缺陷：串行队列嵌套 `sync` 死锁（`transaction`/`markFailed` 路径，会卡死首次同步）、`jobs` 查询引用不存在的 `m.text` 列（播放循环永远取不到任务）、`ON CONFLICT DO NOTHING` 下用 `SQLITE_DONE` 误计新增数（幂等失效）。
- 已部署生产：`notivoice.laomo.app`（Version ID `85039e27`），迁移 003 已在生产 D1 生效（重复执行报 duplicate column 证实列已存在）。
