# 架构设计

## 组件

```
                  POST /api/notifications (text, voice)
  外部系统 ───────────────────────────────┐
                                          ▼
   Cloudflare Worker (src/index.js + src/views/*.html)  + D1 (SQLite `messages`)
        │  GET /api/notifications?after=&limit=    │  POST /api/notifications/ack {seqs}
        ▼                                 │
   macOS 菜单栏客户端 (mac/NotiVoice/main.swift)
        │  Fish Audio TTS（或 macOS 系统语音兜底）
        ▼
   朗读 + 本机音频缓存 + history.json
```

- **后端**：Worker（`cloudflare/src/index.js`）无框架，直接处理路由；状态存 D1。页面模板抽离到 `cloudflare/src/views/*.html`，由 `build.mjs` 在构建时注入 `index.js` 的占位符并输出 `dist/worker.js`（`wrangler.toml` 的 `main` 指向 dist）。零运行时依赖。
- **客户端**：SwiftUI `MenuBarExtra` 常驻菜单栏；`VoiceStore` 在 `init()` 主动启动轮询，不依赖面板是否展开。

## 消息状态机（三态）

`messages` 表字段：`seq`（自增主键）、`text`、`created_at`、`fetched_at`、`fetch_count`、`played_at`、`voice_slot`。

| 状态 | 判定 | 触发 |
|---|---|---|
| 未读取 | `fetched_at` 为空 | POST 推入后 |
| 已读取·未播报 | `fetched_at` 有值、`played_at` 为空 | 被 `/api/notifications` 返回（`fetch_count+1`，首次时间不覆盖） |
| 已播报 | `played_at` 有值 | 客户端播报成功后 `/api/notifications/ack` 回执 |

设计取舍：服务端游标只代表「已被取走」，不保证「已播报」。用 ACK 显式升级状态，使「取走但未播报」在后台可见，便于人工核对漏播。

## 数据流

1. 外部系统 `POST /api/notifications` 推送一条文本（≤1000 字符），返回 `seq`。
2. 客户端按本地游标 `GET /api/notifications?after=<cursor>&limit=50` 增量拉取；服务端标记 `fetched_at` 并返回 `next_cursor`。
3. 客户端逐条朗读（Fish Audio TTS 或系统语音），成功后 `POST /api/notifications/ack {"seqs":[...]}` 回执。
4. 后台 `/api/admin/notifications` 拉最近 200 条，渲染三态标签与统计。

首次同步：客户端以「当前最大 seq」为初始游标，**跳过历史消息**，只从之后开始播报。

## 鉴权模型

- 所有 `/api/*`（notifications / ack / admin）与后台登录共用**同一个** `API_TOKEN`（Cloudflare Secret）。
- 校验：`Authorization: Bearer <token>` 与 `env.API_TOKEN` 字符串相等；缺失/错误返回 `401`。`/` 根页面公开，但页面内的数据请求与测试命令仍需 Token。
- 后台测试指令门槛：curl 命令区默认 `display:none`，仅当 `load()` 用输入的 Token 调 `/api/admin/notifications` 返回 200 后才显示；Token 改动/401 立即隐藏并清空命令。
- Fish Audio Key **只在客户端 Keychain**，绝不经过 Worker。

## 客户端缓存

- **音频缓存**：键 `sha256(model | 音色ID | text)`，落 `~/Library/Application Support/NotiVoice/audio-cache/<hash>.mp3`；命中直接播放不再调 API；上限 100 条，按修改时间淘汰；切换模型/音色自动重新生成（键变化即未命中）。
- **播放记录**：`history.json` 保留最近 500 条，含文本、音色槽位、结果。
- **配置**：`UserDefaults` 域 `cn.lemoai.notivoice`（端点、Token、Fish Key、模型、三个 `reference_id`、默认音色、运行时间窗口）。

## 部署拓扑

- 主入口：`notivoice.laomo.app`（custom domain，DNS/证书由 wrangler 自动创建）。
- 备用入口：`*.workers.dev`（`workers_dev = true` 保留）。
- D1 绑定 `DB`，`database_id` 写在 `wrangler.toml`；新库用 `schema.sql`，已有库用 `migrations/001`、`002` 增量补齐列。
