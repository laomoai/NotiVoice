# 本地联调验收清单

> 适用版本：已实现统一 Token 鉴权、`/api/notifications/ack` 回执、三音色槽位、本机音频缓存的当前状态。

1. 打开 `design/interactive-mock.html`，确认四个设置页、菜单栏弹窗、重播和暂停交互样式。
2. 在 macOS 执行 `bash mac/build-app.command`，确认生成 `mac/dist/NotiVoice.app`（已在本机实机编译验证）。
3. 部署 Worker 与 D1，配置**统一 API_TOKEN**（`wrangler secret put API_TOKEN`，所有接口与后台登录共用，无「管理员 Token」之分）。
4. 首次启动客户端，确认菜单栏有波形图标（无 Dock 图标），设置页四个分区可切换。
5. 填写消息读取地址、Fish Audio Key、模型与音色 ID，点击语音测试；确认能出声或正确降级系统语音。
6. POST 一条消息，观察下一轮自动播报和播放记录；重播同一条消息（应命中本机音频缓存，不再调用 API）。
7. 连续 POST 3 条消息，确认按 `seq` 顺序播放而不是互相打断。
8. 暂停时 POST 新消息，恢复后确认补播；**运行时间限制为可选开关**（默认 08:30–23:00），开启时测试窗口外不拉取、恢复后补拉。
9. 断网再恢复，确认增量消息补拉；退出重启，确认记录保存。
10. 验证后台页面三态：POST 后「未读取」→ 客户端 `/api/notifications` 取走后「已读取·未播报」→ 播报 `/api/notifications/ack` 回执后「已播报」。
11. 验证后台测试指令门槛：未输入/错误 Token 时 curl 命令区隐藏；输入正确 Token 后显示且命令含真实 Token。
12. 验证异常：API 502、Fish Audio 401/429、静音、睡眠、连续 100+ 条消息、单条 >1000 字符（`400 invalid_text`）、请求体 >8KB（`413 payload_too_large`）。

## 发布阻断项（按当前实现更新）

**已完成**：
- Mac 本机实机编译与 `.app` 打包。
- 持久化待播队列 + ACK（`/api/notifications/ack` 回执，三态追踪）。
- 统一 Bearer Token 鉴权（所有 `/api/*` + 后台登录）。
- 三音色槽位、本机音频缓存（100 条）。

**仍待补充（公开部署前）**：
- 限流（Rate limit）、审计（谁在何时调用）、配额。
- 登录项自启（当前需用户手动加入「登录项」）。
- 测试版不应用于必须送达的紧急报警。
