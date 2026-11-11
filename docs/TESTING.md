# 本地联调验收清单

> 适用版本：**V1.1** —— 双 Token 鉴权（`API_TOKEN` / `ADMIN_TOKEN` 互相拒绝）、设备级回执（received / played，幂等、单调、多设备隔离）、客户端 SQLite 持久化与 At-Least-Once 投递、三音色槽位、本机音频缓存。
>
> V1.1 的主验收已固化为两套可重复执行的测试：
> - **Worker 集成测试**：`bash cloudflare/test-worker.sh`（对本地 `wrangler dev`，覆盖 T01/T06/T12/T13/T14/T16 + 旧接口兼容 + 错误码，**16/16 通过**）
> - **客户端单元测试**：`cd mac && swift test`（`PersistenceTests`，覆盖 T02/T03/T04/T05/T08/T17/T18 逻辑，**8/8 通过**）

1. 在 macOS 执行 `bash mac/build-app.command`（或手动 `swift build -c release` 后打包），确认生成 `mac/dist/NotiVoice.app`。
2. 部署 Worker 与 D1：全新库用 `schema.sql`（V1.1 基线）；已有库依次跑 `migrations/001~003`。
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

## 发布阻断项（按 V1.1 实现更新）

**已完成**：
- Mac 实机编译与 `.app` 打包（v1.1.1）。
- 客户端 SQLite 持久化（WAL、串行执行器、同事务入库+游标+received Outbox）+ ACK Outbox 网络重试。
- 设备级回执 + 后台审计（`admin_audit`：清空操作留痕）。
- 双 Token 鉴权（常量时间比较，互相拒绝）。
- 推送限流（60 次/分钟/IP）。
- 三音色槽位、本机音频缓存（100 条）、开机自启（SMAppService）。

**仍待补充（公开部署前）**：
- 拉取 / 回执接口的配额与限流（当前仅推送侧有限流）。
- 紧急报警场景仍不建议依赖本系统（无 SLA）。
