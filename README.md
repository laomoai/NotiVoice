# Noti Voice

> 当前版本：**V1.1.4**（唯一版本源：根目录 `VERSION` 文件）。改版本号必须同步全部文档与页面，并执行 `python3 scripts/check-version.py`；见下方「版本发布规则」。

macOS 菜单栏语音播报客户端 + Cloudflare Worker/D1 后端。把任意系统的文本通知（交易提醒、监控告警、定时播报等）通过简单的 HTTP 接口推送到 Mac，由菜单栏 App 自动朗读出来。后端无服务器、零运维；客户端纯 SwiftUI，自托管可控。

- 后端：Cloudflare Workers + D1（SQLite），**双 Token 鉴权**（`API_TOKEN` 业务接口 / `ADMIN_TOKEN` 后台接口，互相拒绝）。
- 客户端：SwiftUI `MenuBarExtra` 菜单栏 App（无 Dock 图标），Fish Audio TTS，可选音色，本机音频缓存。
- 设计原型：`design/approved-concept.png`、`design/interactive-mock.html`（可离线打开的交互 Mock）。
- 源码仓库：[github.com/laomoai/NotiVoice](https://github.com/laomoai/NotiVoice)

## 功能特性

- **增量拉取**：客户端按 `seq` 游标增量获取，首次同步只建立游标、不播放历史消息。
- **可靠投递（At-Least-Once）**：客户端本地 SQLite 持久化，消息入库与游标推进在同一事务；`GET` 不再写「已读取」，改为客户端显式 `received` / `played` **设备级回执**（幂等、单调、多设备隔离）。失败消息不永久丢弃，自动重播 + 手动重播 + ACK Outbox 重试，崩溃恢复把 `playing` 重排为 `queued`。
- **三音色槽位**：`#1 / #2 / #3`，POST 时通过 `voice` 指定槽位，默认 `#1`；槽位映射到本机设置的三个 Fish Audio `reference_id`，未配置则回退 `#1`。
- **本机音频缓存**：按 `sha256(模型 + 音色 + 文本)` 缓存，上限 **100 条**，重播命中直接播放、不再调用 API；超出按最旧淘汰。
- **Fish Audio TTS + 模型列表**：语音设置**列出全部候选模型**，绿色「免费」标签标明无费用的模型（如 `s2.1-pro-free`），「检测可用模型」用当前 Key 验证可用性并标注「可用 / 当前 Key 不可用」；付费模型也可手动选择（需账户有 credit）。生成失败自动降级 macOS 系统语音，并写 `diagnostic.log`。
- **双 Token 鉴权（V1.1）**：`API_TOKEN` 用于业务接口（提交 / 拉取 / 回执），`ADMIN_TOKEN` 专用于后台 `/api/admin/*`，两者互相拒绝（用错一律 `401`）。客户端 `API_TOKEN` 存于 macOS **Keychain**，绝不落在 UserDefaults / 明文。
- **后台测试指令门槛**：后台页面的「音色下拉 + curl 命令 + 复制按钮」默认隐藏，仅当 Token 经 `/api/admin/notifications` 验证成功后才显示；改动 Token 立即隐藏并清空命令（命令含明文 Token，勿外发）。
- **清空消息**：后台页面提供「清空全部消息」按钮（二次确认），调用 `POST /api/admin/notifications/clear` 删除 D1 全部消息；客户端菜单面板提供「清空记录」仅清除本机播放历史（不影响服务器）。
- **可选运行时间窗口**：默认 `08:30–23:00`，关闭则全天运行；窗口外不拉取，恢复后补拉。
- **推送体积限制**：每条消息 `text` ≤ **1000 字符**，请求体 ≤ **8 KB**（否则 `400 invalid_text` / `413 payload_too_large`）。

## 版本发布规则（全局约定：改版本号必须全量同步）

**唯一版本源**：仓库根目录 `VERSION`（如 `1.1.4`）。升版本时按下面顺序执行，缺一不可：

1. **只改 `VERSION` 一处**。禁止在 UI、HTML 页脚、文档里写死精确版本号（`V1.1` 这类里程碑标记可保留）。
2. **自动注入**（无需手改）：
   - `mac/build-app.command` 读 `VERSION` → 写入 `Info.plist`（`CFBundleShortVersionString`、`CFBundleVersion` UTC 时间戳、`NVGitCommit`、`NVBuildTime`、`NVBuildVariant`、`NVGitDirty`）；「设置 → 关于」页动态显示 `V版本 · build · 标识 · 渠道 · 构建时间`，带「复制版本信息」按钮；出包时**图标源文件缺失直接构建失败**，并在构建后重新注册 LaunchServices（避免 Finder 缓存把图标显示成默认白方块）。
   - `cloudflare/build.mjs` 读 `VERSION` → 把页面里的 `{{APP_VERSION}}` 替换成当前版本；**新增页面必须带该占位符**，否则构建直接失败。
3. **手工同步**（校验脚本会卡住漏改）：`README.md` 头部「当前版本」、`docs/API.md` / `docs/ARCHITECTURE.md` 标题、`docs/TESTING.md` 首行「适用版本」、`CHANGELOG.md` 新增 `## Vx.y.z（日期）` 条目（历史条目保留）、源码/脚本头部的精确版本注释、所有页面可见版本。
4. **重新构建并部署**：`bash mac/build-app.command --no-open` → `cd cloudflare && npm run build && npm run deploy` → `wrangler secret list` 核对 secrets 未被部署覆盖。
5. **门禁**：`python3 scripts/check-version.py`。锚点不一致、页面残留旧精确版本、或 `dist/Info.plist` / `dist/worker.js` 与 `VERSION` 不符，一律非零退出，不得宣称发布完成。

排查「实际跑的是哪版」一律以客户端「设置 → 关于」页为准；Finder 显示的是 `.app` 目录 mtime，构建脚本干净重建保证其更新。

关于页的 `标识 xxxxxxx` 是**构建那一刻的源码 commit**，不等于仓库当前 HEAD——之后只改文档或构建脚本时，客户端二进制没变，标识自然保持原值（这是预期行为，不是漏同步）；`NVGitDirty=yes` 才表示构建时源码存在未提交改动。判断「客户端代码是否是最新」应比对 `git diff <标识>..HEAD -- mac/NotiVoice/`，为空即源码一致。

## 时间与时区（统一显示规则）

- **数据层一律 UTC**：D1 / API 的 `created_at`、`received_at`、`played_at`、`fetched_at`、`admin_audit.created_at` 都是 ISO 8601 UTC（带 `Z`）；客户端本地 SQLite 存 `timeIntervalSince1970`（UTC 绝对时刻）。这是接口契约，不随时区配置改变，已有数据无需迁移。
- **展示层一律按 `TIMEZONE`**：后台的投递 / 接收 / 播放 / 审计时间，客户端的播放记录 / 最近同步 / 运行时间窗口 / 诊断日志 / 关于页，全部按同一时区渲染为 `YYYY-MM-DD HH:mm:ss`。后台提示条与客户端「关于」页会显示当前时区及动态 UTC 偏移（如 `Asia/Shanghai（UTC+8）`）。
- **改时区只改一处**：编辑根目录 `TIMEZONE`（IANA 时区名，默认 `Asia/Shanghai` = 北京时间），然后重新构建两端并部署：
  ```bash
  cd cloudflare && npm run build && npm run deploy
  bash mac/build-app.command --no-open
  ```
  改完必须跑 `node scripts/test-timezone.mjs` 与 `python3 scripts/check-version.py`（含时区一致性检查）。
- 禁止在 UI / 页面里写死 `+8` 或把「北京时间」当换算依据；UTC 偏移由 `Intl` / `TimeZone` 按当前日期动态计算，夏令时时区自动跟随。页面新增时间显示必须复用注入的 `fmt()`，否则 `npm run build` 直接失败。

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
│   ├── API.md                # 接口契约（鉴权 / notifications / ack / admin）
│   ├── TESTING.md            # 本地联调验收清单
│   └── ARCHITECTURE.md       # 组件、数据流、状态机、鉴权设计
├── cloudflare/               # 后端：Worker + D1
│   ├── src/index.js          # Worker 路由与全部接口逻辑（含占位符）
│   ├── src/views/            # 抽离的 HTML 页面模板（构建时注入）
│   │   ├── landing.html      # 公开首页（无需 Token）
│   │   └── admin.html        # 后台页面（数据请求需 Token）
│   ├── build.mjs             # 读 views → 注入 index.js 占位符 → dist/worker.js
│   ├── wrangler.toml         # 名称 / 路由 / D1 绑定（main = dist/worker.js）
│   ├── schema.sql            # 新建库完整表结构
│   ├── migrations/           # 已有库增量补齐列
│   │   ├── 001_play_status.sql
│   │   ├── 002_voice_slot.sql
│   │   ├── 003_message_fields.sql   # V1.1：新字段 + device_receipts/ack_events/admin_audit 表
│   │   └── 004_ack_event_conflict_trigger.sql # V1.1：同 event_id 异载荷 → 409 的触发器
│   ├── package.json          # build / dev / deploy / db:* 脚本
│   ├── .dev.vars.example     # 本地开发变量模板（复制为 .dev.vars，含双 Token）
│   ├── .dev.vars             # 本地开发密钥（gitignore）
│   └── node_modules/         # 依赖（gitignore）
├── mac/                      # 客户端：SwiftUI 菜单栏 App
│   ├── Package.swift
│   ├── NotiVoice/
│   │   ├── App.swift         # SwiftUI 入口 + VoiceStore + UI
│   │   ├── Persistence.swift # V1.1 本地 SQLite 持久层（C API，串行队列，WAL）
│   │   └── AudioCoordinator.swift # V1.1 串行播放协调器（完成以 delegate 回调为准）
│   ├── Tests/NotiVoiceTests/ # V1.1 持久层单元测试（状态机/事务/恢复/重试）
│   ├── build-app.command     # 生成 NotiVoice.app（默认正式版，--local 本地版）
│   ├── dist/                 # 构建产物（gitignore）
│   └── .build/               # SwiftPM 中间产物（gitignore）
├── scripts/                  # 可复现验证脚本
│   ├── fi-real-d1.sh         # 真实远程 D1 故障注入（需隔离临时 Worker + 临时 D1）
│   └── soak_regression.py    # 断网恢复 soak（真实启停本地 Worker）
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
npx wrangler d1 execute noti-voice --remote --file=./migrations/003_message_fields.sql  # V1.1：新字段 + 回执/审计表
npx wrangler d1 execute noti-voice --remote --file=./migrations/004_ack_event_conflict_trigger.sql  # V1.1：ACK 载荷冲突触发器（启用新 Worker 前必跑）
# 双 Token（V1.1）：业务接口与后台互相隔离，用错一律 401
npx wrangler secret put API_TOKEN         # 业务接口（提交 / 拉取 / 回执）
npx wrangler secret put ADMIN_TOKEN       # 后台管理接口专用
npx wrangler secret list                  # 部署后必查：两个 secret 都必须在列
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
- **数据随用户走，不随 App 走**：音频缓存/播放记录（SQLite）在 `~/Library/Application Support/NotiVoice/`，API Token 与 Fish Key 在 Keychain，其余配置（端点/模型/音色）在 `~/Library/Preferences/cn.lemoai.notivoice.plist`。从 `dist` 移到 `/Applications` 不影响这些数据。

## 客户端配置

菜单栏点击波形图标 → 右上角齿轮进入设置，四个分区：

| 分区 | 关键配置 |
|---|---|
| 通用设置 | 服务器地址（如 `https://notivoice.laomo.app`，接口路径自动拼接）、API Token（Bearer，业务接口用，**存于 Keychain**；后台网页需另行使用 ADMIN_TOKEN） |
| 语音设置 | Fish Audio API Key（存 Keychain）、模型（可「检测可用模型」）、音色 `#1/#2/#3` 的 `reference_id`、默认音色、语音缓存 `N/100`、音量 |
| 运行时间 | 可选开关，默认 `08:30–23:00`，支持跨午夜，窗口外不拉取 |
| 关于 | 版本与说明 |

客户端服务器地址默认指向 `https://notivoice.laomo.app/api/...`；但 **API Token 不内置默认值**，首次使用须在「通用设置」手动填写后再连；如需自建后端，在通用设置改端点与 Token 即可。

## API 概览

完整契约见 [`docs/API.md`](docs/API.md)。所有接口根地址为 `https://notivoice.laomo.app`，下表路径为相对该根地址（实际请求须拼接完整 URL，例如 `https://notivoice.laomo.app/api/notifications`）。要点：

| 接口 | 方法 | 鉴权 | 说明 |
|---|---|---|---|
| `/api/notifications` | POST | `API_TOKEN` | 推送通知；新字段 `source/external_id/title/content/priority/voice_slot`（`source+external_id` 幂等），兼容旧 `{"text","voice"}`；文本≤1000 字符，请求体≤8KB |
| `/api/post` | POST | `API_TOKEN` | 上接口的旧别名（老客户端无缝升级） |
| `/api/notifications` | GET | `API_TOKEN` | 按 `seq` 增量拉取，`after`/`limit`(1–200)；**不再写「已读取」**（取 ≠ 收到） |
| `/api/play` | GET | `API_TOKEN` | 上接口的旧别名 |
| `/api/notifications/ack` | POST | `API_TOKEN` | 设备回执 `{"device_id","message_id","status":"received|played","event_id"}`（幂等/单调/多设备）；兼容旧 `{"seqs":[...]}` |
| `/api/admin/notifications` | GET | `ADMIN_TOKEN` | 最近 200 条 + **每条消息的设备回执数组**，供后台展示 |
| `/api/admin/audit` | GET | `ADMIN_TOKEN` | 后台操作审计日志（最近 100 条，V1.1 新增） |
| `/api/admin/notifications/clear` | POST | `ADMIN_TOKEN` | 清空全部消息 + 回执 + 回执事件（写审计日志） |
| `/`、`/admin` | GET | 公开 | 首页 / 后台页面（页面内数据请求需对应 Token） |

## 安全

- **双 Token（V1.1）**：业务接口用 `API_TOKEN`，后台 `/api/admin/*` 用 `ADMIN_TOKEN`，两者互相拒绝（用错 → `401 {"error":"unauthorized"}`）。校验用常量时间比较，防计时侧信道。
- 客户端**不内置 Token 默认值**（开源会暴露生产库）。首次使用须在「通用设置」填写 `API_TOKEN`（存 Keychain）；自行部署请用随机值 `wrangler secret put API_TOKEN` / `ADMIN_TOKEN` 并同步客户端。
- 后台网页仅接受 `ADMIN_TOKEN`，误填 `API_TOKEN` 会被明确拒绝并提示。
- Fish Audio Key 与 API Token **只存本机 Keychain**，不上传 Worker、不落 UserDefaults。
- 已内置：提交限流（60 次/分钟/IP）、审计日志、体积双层限制；配额暂未实现。

## 已知限制

- 单条播报文本 ≤ 1000 字符；请求体 ≤ 8 KB，超出分别返回 `400 invalid_text` / `413 payload_too_large`。
- 后台 `/api/admin/notifications` 仅返回最近 200 条；审计日志保留最近 100 条。
- 客户端本地 SQLite 保留最近 500 条播放记录；音频缓存最多 100 条。
- 运行时间限制为**可选开关**（默认开启 08:30–23:00），关闭即全天运行。
- 无登录项自启；At-Least-Once 投递下崩溃恢复可能**重复播报**少量消息（`playing` 重排为 `queued`），但不会丢消息；未确认回执由 ACK Outbox 持续重试。
- Fish Audio 免费模型档（如 `s2.1-pro-free`）以官方账单/配额页为准，无 SLA。

## 文档索引

- [接口契约](docs/API.md)
- [本地联调验收清单](docs/TESTING.md)
- [架构设计](docs/ARCHITECTURE.md)

## License

[MIT](LICENSE)
