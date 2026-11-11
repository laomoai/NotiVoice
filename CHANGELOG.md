# 更新日志

## V1.1.3（2026-11-12）

增量静态审查（`a231652..d0a4107`）发现的 3 项 P1 + 1 项 P2 缺陷修复；不改 V1.1.2 架构与接口契约。

| 项 | 修复 | 验证证据 |
| --- | --- | --- |
| P1-A 409/404 被当 ACK 成功 | `postReceipt` 只接受 2xx + `{"ok":true}`；409/404 落库隔离（`ack_outbox` 新增 `quarantined_at`/`quarantine_reason`，本地 `user_version=2`），不标记 delivered、不自动重试；菜单显示隔离条与「解除隔离并重试」 | `AckClassifier` 分类测试（200/409/404/500/超时/坏响应体）+ 隔离跨重启与恢复测试 |
| P1-B SQLite 文本绑定生命周期 | `sqlite3_bind_text` 改 `withCString` + `SQLITE_TRANSIENT`，由 SQLite 立即复制 | 中文 / Emoji / 约 1 万字符 / 引号换行 + 100 次 statement 复用，逐字一致 |
| P2-C completed 重入生成新事件 | 幂等查询改为查全部 played 事件（含已送达），重入返回原 `event_id` | 已送达后重入，全表仍只有 1 条 played 事件 |
| P1-D storageFault 状态被覆盖 | `migrateHistoryJSON`/`loadHistoryFromDB` 改 `throws` 上抛；失败时 `db=nil`、停定时器；`startIfNeeded`/`resetTimer`/`flushAcks` 只在 `storageOK` 运行；`retryStorage` 全部成功才恢复 | 损坏库 + 故意缺历史表两个 VoiceStore 实例级故障注入用例 |

- 新增 `mac/Tests/NotiVoiceTests/ReliabilityFixTests.swift`（7 例）；`swift test --disable-sandbox` **28/28，0 failures**（含原有 21 例）。测试进程不再调 `SMAppService`，耗时从 40s 降到 0.8s。
- 本地库 `user_version` 1→2：新库建表即带隔离列；老库条件 `ALTER TABLE` 补齐，重复打开安全（已用例验证）。
- 版本发布按全局规则全量同步：`VERSION=1.1.3`、页面 `{{APP_VERSION}}` 自动注入、README / API / ARCHITECTURE / TESTING / CHANGELOG 同步，并执行 `scripts/check-version.py` 门禁。
- **未验证**：GUI 实机长时挂机；真实 Worker 对隔离回执的端到端 GUI 联调（本次仅 Swift 单测 + 分类纯函数，Worker 代码未改）；真实 D1 故障注入未在本次复跑，沿用 V1.1.2 的 19/19 证据。不得据此宣称完成长期无人值守验收。


## V1.1.2（2026-11-12）

四项可靠性修复（基准 `a231652`，不改界面布局、不改双 Token 方案、不改公开 API 的成功语义）。

### FIX-01（P0）SQLite 关键写入严格检查返回码 — `mac/NotiVoice/Persistence.swift`

- 新增 `prepareChecked` / `bindChecked` / `stepDoneChecked` / `stepRowChecked`，记录 SQLite 错误码与 `sqlite3_errmsg`；写操作要求 `SQLITE_DONE`，读操作显式区分 `ROW` / `DONE` / 错误。
- `setStateNow` / `setCursorNow` / `userVersion` setter / Outbox / 消息 / 历史写入改为 `throws`，删除关键写路径的 `try?` / `try!`。
- `transaction<T>` 泛型化：`BEGIN IMMEDIATE` → 事务体 → `COMMIT`（失败上抛）→ 任一步失败 `ROLLBACK`；事务体内不再嵌套 `queue.sync`（原死锁点）。
- 迁移与 `PRAGMA user_version` 原子完成；`deviceId` 首次创建失败不得返回未持久化的随机 ID。
- 效果：任何写入失败都不会产生「游标前进而消息未落库」的状态，也不会被上层误判为网络错误。

### FIX-02（P0）播放完成与 Played Outbox 同事务 — `Persistence.swift` / `App.swift`

- 新增 `completeAndEnqueuePlayed(_:deviceId:) throws -> String`：单笔事务内校验任务状态 → 标记 `completed` → 插入 `played` Outbox → 提交。
- `event_id` 稳定复用：同一任务重复完成时读取已存在且未送达的 played 事件，不生成第二个有效事件。
- 仅音频 delegate 真正完成回调才调用；播放失败 / 取消不写 Played。ACK 由独立 Outbox worker 发送，服务端确认后才写 `delivered_at`。

### FIX-03（P1）主库失败即停机，禁止临时库降级 — `mac/NotiVoice/App.swift`

- 删除 `NSTemporaryDirectory()` 临时库自动降级逻辑；主库打开 / 迁移 / 持久化失败进入 `StorageFault`，暂停拉取、游标推进、自动播报与 ACK，保留原文件不自动重建删除。
- 拉取 / 播报 / ACK 各路径的持久化异常统一进入 `StorageFault`（此前会被吞成网络重试）。
- 菜单栏红灯显示可读错误，提供「重新连接数据库」；恢复时先重建本地任务与 Outbox，再启动网络拉取。

### FIX-04（P1）Worker ACK 原子幂等与状态单调 — `cloudflare/src/index.js` / `schema.sql` / `migrations/004`

- 事件落库 + 设备回执推进改为 `env.DB.batch([...])` 单事务，移除 JS 层「先 SELECT 判重再 INSERT」竞态窗口与 `RANK` 常量。
- 新增迁移 `004_ack_event_conflict_trigger.sql`（并写入 `schema.sql` 基线）：触发器 `trg_ack_events_payload_conflict` 对同 `event_id` 异载荷 `RAISE(ABORT,'event_conflict')`，Worker 捕获后返回 **409** `event_conflict`，整批回滚无半提交；同载荷重试由主键 `ON CONFLICT DO NOTHING` 幂等吸收。
- 条件 UPSERT 保证 `received → played` 单调、乱序不倒退、`received_at` 保留最早值、多设备隔离。
- `POST /api/notifications/ack` 成功语义不变；409 说明见 `docs/API.md`。

### 测试与验证（实际执行）

| 项目 | 命令 | 结果 |
| --- | --- | --- |
| 客户端单测 | `cd mac && swift test --disable-sandbox` | **14/14 通过**（`Executed 14 tests, with 0 failures`；含 FIX-02 新增的 `testCompleteAndEnqueuePlayedAtomic` / `testCompleteTwiceYieldsSingleEvent` / `testCompleteRejectsNonPlaying` / `testCompleteUnknownJobThrows` / `testCompletionInvariantsAcrossReopen`，以及 `testTransactionRollbackOnBodyError` 等严格返回码回滚路径） |
| Worker 集成测试 | `NO_PROXY=localhost,127.0.0.1 no_proxy=localhost,127.0.0.1 bash cloudflare/test-worker.sh`（本地 `wrangler dev` + 本地 D1，已应用 004） | **21/21 通过**，`ALL PASS`（新增 T19 异载荷 409 + 整批回滚、T20 同 event_id 并发 20 次仅 1 行、T21 received_at 单调保留） |
| 生产迁移 | `wrangler d1 execute ... --file=migrations/004_...sql --remote` | 已应用，生产 Worker Version `b6f495ee` |
| 生产冒烟 | 对生产 ACK 接口四项语义核对 | 幂等 / 409 / 单调 / 设备隔离均正确 |
| 客户端构建 | `mac/dist/NotiVoice.app` | `CFBundleShortVersionString = 1.1.2` |

### 补充演练（2026-11-12，用户指定）

**① 真实远程 D1 故障注入（非本地 miniflare）** — `scripts/fi-real-d1.sh`

隔离资源：临时 Worker `notivoice-fi-20261112`（独立 `workers.dev` 子域）+ 临时远程 D1 `notivoice-fi-20261112`（APAC / HKG），执行 `schema.sql`（含 004）。生产 Worker 与生产 D1 全程未改动；演练后临时 Worker 已删除（回访 404）、临时 D1 已删除（含误建的 `...b` 副本）、本地临时配置已清理。结果 **19/19 ALL PASS**：

- FI-02 同 `event_id` 异载荷 → 409，冲突批次不产生新设备回执、既有回执不变（真实 D1 整批回滚）。
- FI-03 同 `event_id` 并发 20 次跨请求 → `ack_events` 与 `device_receipts` 各恰好 1 行。
- FI-04 乱序 `played → received` 不倒退、双时间戳保留、设备隔离。
- FI-05 **batch 中途失败注入**：在 `device_receipts` 建仅命中哨兵 `device_id` 的 `RAISE(ABORT)` 触发器 → ACK 返回 500；直查真实 D1，第①条 `ack_events` 0 行、第②条回执 0 行 → 证明 `DB.batch()` 整批回滚、无半提交。DROP 触发器后同一 `event_id` 重试成功且幂等（FI-06）。

**② 客户端 SQLite 物理/引擎级故障注入 + 长循环（Mac mini M4 本机）** — `mac/Tests/NotiVoiceTests/FaultInjectionTests.swift`、`SoakTests.swift`

`cd mac && swift test --disable-sandbox` → **21/21 通过**（原 14 + 故障注入 6 + 长循环 1）：

- 权限拒绝：目录 `0555` + 库文件 `0444` → 抛 `NVError.execFailed("attempt to write a readonly database")`，恢复权限后同文件正常打开。
- 库文件损坏：4096 字节垃圾覆盖库头 → 初始化抛 `NVError`，原文件保留、不自动重建、不生成降级库。
- 磁盘满等价：切 rollback journal + `PRAGMA max_page_count = page_count+1`，写入 1.5MB 消息触发真实 `SQLITE_FULL` → 整事务回滚（游标 0 / 消息 0 / 任务 0 / 回执 0），放宽限制后同批次重放成功。
- COMMIT 阶段失败：延迟外键约束 → `COMMIT` 抛 `execFailed`，`fi_child` 0 行。
- 事务中途 ABORT、device_id 写入失败不得返回未持久化 ID。
- 120 轮「重开库 → 入库 → 播放完成 → 部分回执留待补发」→ 游标/消息 120、`ack_outbox` 240 行且 `event_id` 全不重复、无残留任务、最后 2 条未送达回执跨重启保留。

**③ 协议层断网恢复 soak** — `scripts/soak_regression.py`（Mac mini M4 本机，真实启停本地 Worker 制造服务中断）

`python3 scripts/soak_regression.py 300 12` 实跑 **301.6 秒 / 2 次中断**（每次 12s，含重启约 15.6–15.7s）：创建 142 条、恢复后拉取 142 条、`missing_after_recovery = []`、284 个 `event_id`（= 142 × received+played）全不重复、待发 POST / 待发 ACK 均清零、12 次拉取失败与 42 次 POST 失败全部发生在中断窗口并由恢复后重放吸收、`server_5xx = 0` → **ALL PASS**。先用 `30 4` 短窗口自检过脚本，再跑正式窗口。

### 演练后的证据汇总

| 验证 | 结果 |
| --- | --- |
| 客户端单测（含 6 例物理故障注入 + 120 轮重开库） | **21/21** |
| Worker 集成测试 | **21/21** |
| 真实远程 D1 故障注入（隔离资源） | **19/19** |
| 5 分钟协议 soak（2 次真实中断） | **ALL PASS**（142/142） |

### 未验证与剩余风险（明确标注）

- **未**让 GUI 客户端 `.app` 连续挂机数小时；已跑的是协议层 soak（启停 Worker + 游标补拉 + 稳定 `event_id` 补发）+ 持久层 120 轮重开库循环，两者都不等于真实 GUI 长时挂机回归。
- **未**在真实生产 D1 上注入故障（刻意用隔离临时 D1，避免影响线上 ACK）；生产端仍只有部署后冒烟证据。
- **未**做真实磁盘写满（用 `PRAGMA max_page_count` 触发等价的 `SQLITE_FULL`）、真实硬件权限故障（用临时目录 chmod 等价注入）。
- **未**在真实 D1 做跨地域/多实例并发压测；并发证据为 20 次跨请求。
- `source + external_id` 提交幂等仍是「先查后插」，存在并发竞态（本轮范围外，P2）。
- Worker 内存 Map 限流跨实例不共享（P2）。
- 回滚方案：Worker 可用 Cloudflare Versions 回滚到 `479c6c8f`；D1 侧 004 仅新增触发器，`DROP TRIGGER IF EXISTS trg_ack_events_payload_conflict` 即可退回（旧代码不依赖它，但会退回「先查后插」竞态）。

### 版本一致性规则落地（2026-11-12）

- 新增根目录 `VERSION` 作为全仓唯一版本源；`mac/build-app.command` 与 `cloudflare/build.mjs` 均从它读取，页面强制使用 `{{APP_VERSION}}` 占位符（缺失即构建失败）。
- 新增 `scripts/check-version.py` 门禁：校验 README / API / ARCHITECTURE / TESTING / CHANGELOG 锚点、页面占位符、全仓旧精确版本残留、客户端 `Info.plist` 与 Worker 产物版本；非零退出即禁止宣称发布完成。
- 修正既有不一致：落地页页脚 `v1.1.1`、后台页页脚 `v1.1` 统一为当前版本；文档头部补「当前版本 V1.1.2」声明；`App.swift` 历史注释收敛为里程碑标记。
- 生产 Worker 已按新构建重新部署（仅页面版本文案变化，接口与 secrets 不变）；客户端重新出包后覆盖安装才能看到新构建标识。

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
