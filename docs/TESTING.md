# 本地联调验收清单

> 适用版本：**V1.1.3** —— 双 Token 鉴权（`API_TOKEN` / `ADMIN_TOKEN` 互相拒绝）、设备级回执（received / played，幂等、单调、多设备隔离）、客户端 SQLite 持久化与 At-Least-Once 投递、四项可靠性修复（FIX-01~04）、三音色槽位、本机音频缓存。
>
> 主验收已固化为四套可重复执行的测试：
> - **Worker 集成测试**：`bash cloudflare/test-worker.sh`（对本地 `wrangler dev`，覆盖 T01/T06/T12/T13/T14/T16/T19/T20/T21 + 旧接口兼容 + 错误码，**21/21 通过**）
> - **客户端单元测试**：`cd mac && swift test --disable-sandbox`（**28/28 通过** = `PersistenceTests` 14 例 + `FaultInjectionTests` 6 例 + `SoakTests` 1 例 + `ReliabilityFixTests` 7 例；覆盖事务原子性、COMMIT 回滚、完成与 Played Outbox 同事务、权限拒绝/损坏/SQLITE_FULL/COMMIT 失败故障注入、120 轮重开库循环）
> - **真实远程 D1 故障注入**：`bash scripts/fi-real-d1.sh <base_url> <api_token> <admin_token> <d1_name>`（隔离临时 Worker + 隔离临时 D1，**19/19 通过**，含 batch 中途 ABORT 整批回滚）
> - **协议层断网恢复 soak**：`python3 scripts/soak_regression.py 300 12`（真实启停 Worker 制造 2 次中断，验证补拉补发）
>
> 若 SwiftPM 在受限环境下报 `sandbox-exec: sandbox_apply: Operation not permitted`，加 `--disable-sandbox`（仅关闭 SwiftPM 自身沙箱，不改变测试语义）。本机为 **Mac mini M4 / 16GB**。

1. 在 macOS 执行 `bash mac/build-app.command`（或手动 `swift build -c release` 后打包），确认生成 `mac/dist/NotiVoice.app`。
2. 部署 Worker 与 D1：全新库用 `schema.sql`（V1.1.3 基线，已含 FIX-04 触发器）；已有库依次跑 `migrations/001~004`，其中 **004 必须在启用新 Worker 前执行**，否则异载荷 `event_id` 不会被 409 拦截。本地复测可用 `npx wrangler d1 execute noti-voice --local --file=./migrations/004_ack_event_conflict_trigger.sql`。
3. 配置**双 Token**（各填一个随机值，二者不同）：`wrangler secret put API_TOKEN`（业务接口，客户端用）、`wrangler secret put ADMIN_TOKEN`（后台 `/api/admin/*` 与 `/admin` 登录用）。**部署后必须 `wrangler secret list` 核对两个 secret 都在。**
4. 首次启动客户端，确认菜单栏有波形图标（无 Dock 图标）；**启动自检**：未填 Token 显示橙色「待配置」，填错显示红色「Token 无效」，连接正常显示绿色「运行中 · 已连接」。
5. 填写服务器地址、API Token、Fish Audio Key、模型与音色 ID，点击语音测试；确认能出声或正确降级系统语音。
6. POST 一条消息，观察自动播报与播放记录；重播同一条消息（应命中本机音频缓存，不再调用 API）。
7. 连续 POST 3 条消息，确认按 `seq` 顺序**串行**播放而不是互相打断。
8. 暂停时 POST 新消息，恢复后确认补播；运行时间限制为可选开关（默认 08:30–23:00），开启时测试窗口外不拉取、恢复后补拉。
9. 断网再恢复，确认增量消息补拉、ACK Outbox 自动补发；退出重启，确认记录与待播队列从 SQLite 恢复（playing → 重新排队）。
10. 验证后台设备回执：POST 后「未送达」→ 客户端拉取落库后「已送达·未播报」（received）→ 播报完成后「已播报 · 任一设备」（played，含设备短 ID 与两个时间戳）。旧版客户端（仅 `{"seqs":[...]}`）显示「已播报 · 旧版回执」。
11. 验证后台测试命令门槛：未填 API Token 时给提示不生成命令；填对后命令使用 **API_TOKEN**（绝不能是登录用的 ADMIN_TOKEN）。
12. 验证异常：API 502、Fish Audio 401/429、静音、睡眠、连续 100+ 条消息、单条 >1000 字符（`400 invalid_text`）、请求体 >8KB（`413 payload_too_large`）、推送限流（60 次/分钟/IP，超出 `429 rate_limited`）。

### V1.1 四项修复的补充验收

13. **FIX-04 冲突语义**：用同一 `event_id` 先提交 `{device_id:"A",status:"received"}`，再换成 `{device_id:"B"}` 提交 → 必须 `409 event_conflict`；随后查后台，A 状态未被改动、B 未产生回执（整批回滚）。同 `event_id` 同载荷并发 20 次 → 后台只有 1 行回执。
14. **FIX-04 状态单调**：`played` 先到、`received` 后到，断言 `received_at` 与 `played_at` 均在且状态仍为 `played`；两台设备对同一消息分别回执，断言互不覆盖。
15. **FIX-01/02 事务**：`swift test` 覆盖 COMMIT 前抛错回滚、播放完成与 Played Outbox 同生同灭、重复完成只产生一个 `event_id`、重开库不变量。跑法：`cd mac && swift test --disable-sandbox`。
16. **FIX-03 存储故障**：把 `~/Library/Application Support/NotiVoice/` 下的 SQLite 主库设为只读或损坏后重启客户端，断言菜单栏红灯「本地数据库故障」、不拉取不播报不前进游标、不生成新设备 ID；恢复权限后点「重新连接数据库」，断言原队列与未送达 Outbox 继续补发。
17. **Worker 集成测试复跑**：先 `cd cloudflare && npm run build && npx wrangler dev --port 8787`（`.dev.vars` 需含 `API_TOKEN=test_api_token_123` / `ADMIN_TOKEN=test_admin_token_456`），并先对本地库执行 004；再在仓库根执行 `NO_PROXY=localhost,127.0.0.1 no_proxy=localhost,127.0.0.1 bash cloudflare/test-worker.sh`。若环境有全局 HTTP 代理，不加 `NO_PROXY` 会让 curl 打到代理返回 502，属环境问题而非测试失败。末尾应输出 `===== 结果：21 通过 / 0 失败 =====` 与 `ALL PASS`。

### 2026-11-12 补充演练（真实 D1 / 物理故障 / soak）

18. **真实远程 D1 故障注入**：不要在已部署的生产 D1 上注入。新建隔离 D1（`npx wrangler d1 create notivoice-fi-<日期>`）→ 跑 `schema.sql` → 用 `tmp/fi-worker.toml` 绑定该 D1 与明文测试 Token 部署独立 Worker → 执行 `scripts/fi-real-d1.sh`。期望 19/19，尤其 FI-05：哨兵触发器令 `batch()` 第二条 ABORT 后，直查 D1 断言 `ack_events` 与 `device_receipts` 都是 0 行。结束后 `wrangler delete --config ... --force` 与 `wrangler d1 delete ... --skip-confirmation`，确认无残留资源。
    - 坑：`wrangler d1 create` 偶发 `Authentication error [code: 10000]`（瞬时鉴权故障），重试即可；多建的副本要删。`wrangler delete` 用 `--force`，没有 `--yes`。
19. **客户端物理故障注入**：`cd mac && swift test --disable-sandbox --filter FaultInjectionTests`。用例在临时目录用真实 SQLite 文件做 chmod 只读、覆盖库头制造损坏、`PRAGMA max_page_count` 触发 SQLITE_FULL、延迟外键令 COMMIT 失败、事务中触发器 ABORT；全部断言整事务回滚且原文件保留、不生成降级库。
20. **持久层长循环**：`swift test --disable-sandbox --filter SoakTests`，120 轮重开库，断言 240 个 `event_id` 全不重复、无残留任务、未送达回执跨重启保留。
21. **协议层 soak**：`python3 scripts/soak_regression.py 30 4` 先做短窗口自检，再跑 `300 12` 正式窗口。脚本真实启停本地 Worker，中断期间消息入待发队列，恢复后按原 `external_id` / `event_id` 补发；断言 `missing_after_recovery` 为空、待办清空、无 5xx、事件数 = 拉取数 × 2。

## 发布阻断项（按 V1.1.3 实现更新）

**已完成并验证**：
- Mac mini M4 本机编译与 `.app` 打包（v1.1.3，`CFBundleShortVersionString=1.1.3`）；`swift test --disable-sandbox` **28/28**（含 7 例审查缺陷回归 + 6 例物理故障注入 + 120 轮重开库 soak）。
- Worker 集成测试 `cloudflare/test-worker.sh` **21/21**（含 T19/T20/T21）。
- 真实远程 D1 故障注入 `scripts/fi-real-d1.sh` **19/19**（隔离临时 Worker + 临时 D1，资源已清理；含 batch 中途 ABORT 整批回滚）。
- 协议层 soak `python3 scripts/soak_regression.py 300 12`：**301.6 秒 / 2 次中断 / ALL PASS**（142 条创建 = 142 条补拉、284 个不重复 `event_id`、待办清零、0 个 5xx）。
- 客户端 SQLite 持久化（WAL、串行执行器、同事务入库+游标+received Outbox）+ ACK Outbox 网络重试；关键写入严格返回码（FIX-01）；播放完成与 Played Outbox 同事务（FIX-02）；主库故障停机不降级（FIX-03）。
- 设备级回执 D1 `batch()` 原子幂等 + 409 冲突 + 状态单调（FIX-04）；迁移 004 已应用到生产 D1，生产 Worker Version `b6f495ee`。
- 设备级回执 + 后台审计（`admin_audit`：清空操作留痕）。
- 双 Token 鉴权（常量时间比较，互相拒绝）；推送限流（60 次/分钟/IP）。
- 三音色槽位、本机音频缓存（100 条）、开机自启（SMAppService）。

**未验证 / 仍待补充（不得宣称已完成）**：
- GUI 客户端 `.app` 连续挂机数小时的真实回归；已跑的是协议层 soak + 持久层 120 轮重开库循环，二者均不等于 GUI 长时挂机。
- 在**生产** D1 上注入故障（刻意改用隔离临时 D1，避免影响线上 ACK）；生产端仍只有部署后冒烟证据。
- 真实磁盘写满 / 硬件级权限故障（用 `SQLITE_FULL` 与临时目录 chmod 做等价注入）。
- 跨地域 / 多实例并发压测；并发证据为同 `event_id` 20 次跨请求。
- 拉取 / 回执接口的配额与限流（当前仅推送侧有限流）。
- `source + external_id` 提交幂等仍为「先查后插」，存在并发竞态（P2）。
- Worker 内存 Map 限流跨实例不共享（P2）。
- 紧急报警场景仍不建议依赖本系统（无 SLA）。
