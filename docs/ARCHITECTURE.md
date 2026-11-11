# 架构设计（当前版本 V1.1.2）

## 组件

```
   外部系统 ──POST /api/notifications (source,external_id,title,content,priority,voice_slot)──┐
                                                                                              ▼
   Cloudflare Worker (src/index.js + src/views/*.html)  + D1 (messages / device_receipts / ack_events / admin_audit)
        │  GET /api/notifications?after=&limit=    │  POST /api/notifications/ack {device_id,message_id,status,event_id}
        ▼                                 │
   macOS 菜单栏客户端 (mac/NotiVoice/*.swift)
        │  Fish Audio TTS（或 macOS 系统语音兜底）
        ▼
   朗读 + 本机 SQLite 持久化（messages 入库 + 待播队列 + ACK Outbox）+ 音频缓存 + history（SQLite）
```

- **后端**：Worker（`cloudflare/src/index.js`）无框架，直接处理路由；状态存 D1。页面模板抽离到 `cloudflare/src/views/*.html`，由 `build.mjs` 在构建时注入 `index.js` 的占位符并输出 `dist/worker.js`（`wrangler.toml` 的 `main` 指向 dist）。零运行时依赖。
- **客户端**：SwiftUI `MenuBarExtra` 常驻菜单栏；`VoiceStore`（`App.swift`）在 `init()` 主动启动轮询，不依赖面板是否展开。持久层 `Persistence.swift` 用**系统 SQLite C API**（非 GRDB），单一串行执行器；`AudioCoordinator.swift` 串行调度播放。

## 鉴权模型（双 Token，V1.1）

- **`API_TOKEN`** 用于业务接口（提交 / 拉取 / 回执）；**`ADMIN_TOKEN`** 仅用于 `/api/admin/*`。两者互相拒绝（用错 → 401）。
- 校验用**常量时间比较**（`ctEq`），避免计时侧信道。后台网页只接受 `ADMIN_TOKEN`，填 `API_TOKEN` 会被明确拒绝。
- Fish Audio Key **只在客户端 Keychain**，绝不经过 Worker。客户端 `API_TOKEN` 存于 macOS Keychain（非 UserDefaults / 明文）。

## 可靠投递（At-Least-Once，V1.1 核心）

设计目标：**消息不丢、不把“音频播出来了”等同于“用户听到了”**。

- **取 ≠ 收到**：`GET /api/notifications` **不再写 `fetched_at`**。服务端游标只代表“已返回给客户端”，不证明客户端已落盘。
- **显式回执**：客户端在本地**持久化入库后**才发 `received`；播报完成才发 `played`。回执按 `device_id` 记录，幂等（`event_id`），单调（`received < played`），多设备隔离。
- **ACK Outbox 重试**：本地回执先写 `ack_outbox`（未投递），由独立定时器每 5 秒重试直到服务端确认；重试**不改变本地已播放事实**（失败消息不永久丢弃）。
- **崩溃恢复**：客户端重启时 `recoverInterrupted()` 把 `playing` 状态重排为 `queued`（允许少量重复播报，但绝不丢消息）。

## 消息状态机（客户端 SQLite）

`playback_jobs` 状态：`queued → playing → completed`；失败 `queued/retry_wait → retry_wait（退避）→ needs_attention（达阈值保留）`，`needs_attention` 可手动「重试」回到 `queued`。**失败消息永不删除**（T08）。

服务端 `messages` 表字段：`seq`、`text/title/content/priority`、`voice_slot`、`created_at`、`source`、`external_id`、`received_at`。设备回执在 `device_receipts`（`message_id,device_id,status,received_at,played_at`），回执幂等在 `ack_events`（`event_id`）。

## 数据流

1. 外部系统 `POST /api/notifications` 推送一条消息（≤1000 字符），返回 `seq`。`source+external_id` 幂等。
2. 客户端按本地游标 `GET /api/notifications?after=<cursor>&limit=50` 增量拉取；在**同一事务**内完成「入库 + 建待播任务 + 推进游标 + 写 received Outbox」——事务提交前崩溃则不前进（T02），提交后本地任务与 Outbox 一同落盘（T03）。
3. 串行播放协调器逐条朗读（Fish Audio TTS 或系统语音），以 delegate 回调判定完成（非轮询 `isPlaying`）；成功后发 `played` 回执。
4. ACK Outbox 定时器把未确认回执重试投递到服务端。
5. 后台 `GET /api/admin/notifications` 拉最近 200 条 + 设备回执，渲染状态与统计；`GET /api/admin/audit` 看操作日志。

首次同步：客户端以「当前最大 seq」为初始游标，**跳过历史消息**，只从之后开始播报。

## 客户端持久化（系统 SQLite C API）

- 单文件 WAL + `busy_timeout=5000` + `foreign_keys ON`；单一串行 `DispatchQueue` 执行器，所有访问经 `queue.sync` 进出，**严禁在 `queue.sync` 闭包内再 `queue.sync`**（会死锁，已由单元测试覆盖）。
- 用 `user_version` 做增量迁移（`migrations/003` 在 D1 端对应补齐列与新建表）。
- 播放记录 `playback_history` 也存 SQLite（替代旧 `history.json`）。

## 客户端音频缓存

- 键 `sha256(模型 | 音色ID | text)`，落 `~/Library/Application Support/NotiVoice/audio-cache/<hash>.mp3`；命中直接播放不再调 API；上限 100 条，按修改时间淘汰；切换模型/音色自动重新生成（键变化即未命中）。

## 部署拓扑

- 主入口：`notivoice.laomo.app`（custom domain，DNS/证书由 wrangler 自动创建）。
- 备用入口：`*.workers.dev`（`workers_dev = true` 保留）。
- D1 绑定 `DB`，`database_id` 写在 `wrangler.toml`；新库用 `schema.sql`，已有库用 `migrations/001`、`002`、`003` 增量补齐列与新建表。
- Token 通过 `wrangler secret put API_TOKEN` / `wrangler secret put ADMIN_TOKEN` 配置，不在仓库中。

## 回滚与备份

- 后端无状态计算，回滚 = `wrangler rollback`（回到上一个 Worker Version ID）。D1 数据不受 Worker 回滚影响；清空消息不可恢复，需事先备份（见 `wrangler d1 export`）。
- 客户端回滚 = 发布上一个 `.app` 版本。
- D1 备份：`npx wrangler d1 export noti-voice --remote --output dump.sql`（或周期性定时导出）。
