# Noti Voice

macOS 菜单栏语音播报客户端 + Cloudflare Worker/D1 后端。把任意系统的文本通知（交易提醒、监控告警、定时播报等）通过简单的 HTTP 接口推送到 Mac，由菜单栏 App 自动朗读出来。后端无服务器、零运维；客户端纯 SwiftUI，自托管可控。

- 后端：Cloudflare Workers + D1（SQLite），统一 Bearer Token 鉴权。
- 客户端：SwiftUI `MenuBarExtra` 菜单栏 App（无 Dock 图标），Fish Audio TTS，可选音色，本机音频缓存。
- 设计原型：`design/approved-concept.png`、`design/interactive-mock.html`（可离线打开的交互 Mock）。

## 功能特性

- **增量拉取**：客户端按 `seq` 游标增量获取，首次同步只建立游标、不播放历史消息。
- **消息三态追踪**：`未读取 → 已读取·未播报 → 已播报`。`/api/notifications` 取走即标记「已读取」，`/api/notifications/ack` 播报成功后回执升级为「已播报」，后台页面据此验证链路是否走通。
- **三音色槽位**：`#1 / #2 / #3`，POST 时通过 `voice` 指定槽位，默认 `#1`；槽位映射到本机设置的三个 Fish Audio `reference_id`，未配置则回退 `#1`。
- **本机音频缓存**：按 `sha256(模型 + 音色 + 文本)` 缓存，上限 **100 条**，重播命中直接播放、不再调用 API；超出按最旧淘汰。
- **Fish Audio TTS + 模型探测**：设置页「检测可用模型」逐个探测候选模型并标注「免费 / 已弃用」；生成失败自动降级 macOS 系统语音，并写 `diagnostic.log`。
- **统一 Token 鉴权**：所有 `/api/*` 接口与后台登录共用**同一个** Bearer Token，缺失或错误一律 `401`。
- **后台测试指令门槛**：后台页面的「音色下拉 + curl 命令 + 复制按钮」默认隐藏，仅当 Token 经 `/api/admin/notifications` 验证成功后才显示；改动 Token 立即隐藏并清空命令（命令含明文 Token，勿外发）。
- **可选运行时间窗口**：默认 `08:30–23:00`，关闭则全天运行；窗口外不拉取，恢复后补拉。
- **推送体积限制**：每条消息 `text` ≤ **1000 字符**，请求体 ≤ **8 KB**（否则 `400 invalid_text` / `413 payload_too_large`）。

## 项目结构

```
noti-voice/
├── README.md                 # 本文件
├── LICENSE                   # MIT
├── .gitignore
├── design/                   # 视觉基准图与交互原型（非代码）
│   ├── approved-concept.png
│   └── interactive-mock.html
├── docs/
│   ├── API.md                # 接口契约（鉴权 / post / play / ack / admin）
│   ├── TESTING.md            # 本地联调验收清单
│   └── ARCHITECTURE.md       # 组件、数据流、状态机、鉴权设计
├── cloudflare/               # 后端：Worker + D1
│   ├── src/index.js          # Worker 全部逻辑（含后台页面）
│   ├── wrangler.toml         # 名称 / 路由 / D1 绑定
│   ├── schema.sql            # 新建库完整表结构
│   ├── migrations/           # 已有库增量补齐列
│   │   ├── 001_play_status.sql
│   │   └── 002_voice_slot.sql
│   ├── package.json          # dev / deploy / db:* 脚本
│   ├── .dev.vars.example     # 本地开发变量模板（复制为 .dev.vars）
│   └── node_modules/         # 依赖（gitignore）
├── mac/                      # 客户端：SwiftUI 菜单栏 App
│   ├── Package.swift
│   ├── NotiVoice/main.swift  # 客户端全部逻辑
│   ├── build-app.command     # 生成 NotiVoice.app（默认正式版，--local 本地版）
│   ├── dist/                 # 构建产物（gitignore）
│   └── .build/               # SwiftPM 中间产物（gitignore）
└── assets/logo/              # 图标源（SVG）+ 生成物（PNG / icns / iconset）
    ├── notivoice-release.*   # 安装/正式版（蓝，无 LOCAL 角标）
    ├── NotiVoice-release.icns
    ├── notivoice-local.*     # 本地开发版（紫 + LOCAL 角标）
    ├── NotiVoice-local.icns
    └── menubar-template.*    # 菜单栏模板（单色）
```

## 后端部署（Cloudflare）

```bash
cd cloudflare
npm install
npx wrangler login
npx wrangler d1 create noti-voice        # 把返回的 database_id 填进 wrangler.toml
# 新库：直接用 schema.sql 建全量结构
npm run db:remote
# 已有库（仅补齐列）：依次执行
npm run db:migrate                        # 001：fetched_at / fetch_count / played_at
npm run db:migrate:voice                  # 002：voice_slot
npx wrangler secret put API_TOKEN         # 全项目唯一 Bearer Token（所有接口与后台登录共用）
npm run deploy
```

- **自定义域名**：`wrangler.toml` 已配置 `[[routes]] pattern="notivoice.laomo.app" custom_domain=true`（要求 `laomo.app` 的权威 NS 在 Cloudflare）。`npm run deploy` 会自动创建 DNS 记录与证书。`workers_dev = true` 保留 `*.workers.dev` 作为备用入口。
- 访问 `https://notivoice.laomo.app/` 查看消息记录；备用 `https://noti-voice.algerchen.workers.dev/`。

## 客户端构建与安装（macOS）

要求 **macOS 13+**，安装 Xcode 或 Xcode Command Line Tools（需要 `swift` 命令）。

```bash
cd mac
bash build-app.command            # 生成 mac/dist/NotiVoice.app（装入蓝色安装版图标，并尝试打开）
bash build-app.command --local    # 装入紫色带 LOCAL 角标的本地开发版图标，便于区分环境
```

构建脚本在受限/嵌套沙箱下会自动降级为 `swift build --disable-sandbox`。

**安装到本机**：把 `mac/dist/NotiVoice.app` 拖到 `/Applications` 即可。该二进制只依赖系统框架与 `/usr/lib/swift`，移动到任何位置都能运行。

- **首次启动会被 Gatekeeper 拦截**（adhoc 自签、未公证）：右键（或 Control+点击）→ 打开，或在 **系统设置 → 隐私与安全性** 点「仍要打开」。首次放行后不再拦截。
- **菜单栏 App，无 Dock 图标**：启动后只在顶部菜单栏出现波形图标，属正常。
- **不会开机自启**：未注册 Login Item；如需开机启动，自行在 **系统设置 → 通用 → 登录项** 添加。
- **数据随用户走，不随 App 走**：音频缓存/历史在 `~/Library/Application Support/NotiVoice/`，Fish Key 在 Keychain，端点/Token 在 `~/Library/Preferences/cn.lemoai.notivoice.plist`。从 `dist` 移到 `/Applications` 不影响这些数据。

## 客户端配置

菜单栏点击波形图标 → 右上角齿轮进入设置，四个分区：

| 分区 | 关键配置 |
|---|---|
| 通用设置 | 服务器地址（如 `https://notivoice.laomo.app`，接口路径自动拼接）、API Token（Bearer，读取/提交/回执共用） |
| 语音设置 | Fish Audio API Key（存 Keychain）、模型（可「检测可用模型」）、音色 `#1/#2/#3` 的 `reference_id`、默认音色、语音缓存 `N/100`、音量 |
| 运行时间 | 可选开关，默认 `08:30–23:00`，支持跨午夜，窗口外不拉取 |
| 关于 | 版本与说明 |

客户端默认值已指向 `https://notivoice.laomo.app/api/...` 与共用 Token，开箱即连已部署服务；如需自建后端，在通用设置改端点与 Token 即可。

## API 概览

完整契约见 [`docs/API.md`](docs/API.md)。要点：

| 接口 | 方法 | 说明 |
|---|---|---|
| `/api/notifications` | POST | 推送一条通知，`{"text":"...","voice":1}`；`text`≤1000 字符，请求体≤8KB |
| `/api/notifications` | GET | 按 `seq` 增量拉取，`after`/`limit`(1–100)；取走即标记「已读取」 |
| `/api/notifications/ack` | POST | 播报成功回执，`{"seqs":[...]}`（1–100 个正整数），升级为「已播报」 |
| `/api/admin/notifications` | GET | 最近 200 条，含三态字段，供后台页面展示 |
| `/` | GET | 公开后台页面（数据请求需 Token） |

## 安全

- 所有 `/api/*` 与后台登录共用**唯一** `API_TOKEN`，缺失/错误返回 `401 {"error":"unauthorized"}`，不存在第二个可用口令。
- 本项目 Token 由所有者定为**非机密**（与客户端默认值、文档一致），便于自部署与开源；如你另行部署，请改用随机值并同步 wrangler secret、客户端、文档。
- Fish Audio Key **只存本机 Keychain**，不上传 Worker。
- **尚未实现**：限流、审计、配额。当前仅靠 Token 鉴权，公开部署前建议补充上述能力。

## 已知限制

- 单条 `text` ≤ 1000 字符；请求体 ≤ 8 KB，超出分别返回 `400 invalid_text` / `413 payload_too_large`。
- 后台 `/api/admin/notifications` 仅返回最近 200 条。
- 客户端本地 `history.json` 保留最近 500 条；音频缓存最多 100 条。
- 运行时间限制为**可选开关**（默认开启 08:30–23:00），关闭即全天运行。
- 无登录项自启；崩溃/网络抖动可能漏播，依赖 `/api/notifications/ack` 在三态中暴露「已读取未播报」以便人工核对。
- Fish Audio 免费模型档（如 `s2.1-pro-free`）以官方账单/配额页为准，无 SLA。

## 文档索引

- [接口契约](docs/API.md)
- [本地联调验收清单](docs/TESTING.md)
- [架构设计](docs/ARCHITECTURE.md)

## License

[MIT](LICENSE)
